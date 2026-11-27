// SPDX-License-Identifier: GPL-3.0-or-later
// Port of the TplinkRouterSG client of tplinkrouterc6u, by its authors
// (https://github.com/AlexandrErohin/TP-Link-Archer-C6U), GPL-3.0-or-later.

import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Read-only client for TP-Link Archer routers that use the "SG" sign-in
/// scheme (SHA-256 + RSA-OAEP + HMAC-SHA256, e.g. Archer BE550 / BE3600).
/// It signs in, reads the connected devices and always signs out: the
/// router allows a single admin session. It changes no router setting.
///
/// Ported from the TplinkRouterSG client of tplinkrouterc6u
/// (https://github.com/AlexandrErohin/TP-Link-Archer-C6U), which PresenceBar
/// used through a Python helper before.
///
/// Login file ~/.config/tplink/archer.json (keep it chmod 600):
///   {"host": "https://192.168.0.1", "username": "admin", "password": "..."}
struct RouterClient {
    struct Device {
        let mac: String       // lower case, colon separated
        let name: String
        let ip: String
        /// Locally administered address: phones' private (random) Wi-Fi addresses.
        var isPrivate: Bool { (UInt8(mac.prefix(2), radix: 16) ?? 0) & 2 != 0 }
    }

    enum Failure: Error, CustomStringConvertible {
        case login(String), request(String), response(String)
        var description: String {
            switch self {
            case .login(let s): return "router sign-in failed: \(s)"
            case .request(let s): return "router request failed: \(s)"
            case .response(let s): return "unexpected router answer: \(s)"
            }
        }
    }

    static let loginURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/tplink/archer.json")

    /// Signs in, reads every connected device, signs out.
    static func connectedDevices() async throws -> [Device] {
        guard let data = try? Data(contentsOf: loginURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = cfg["host"] as? String, let password = cfg["password"] as? String else {
            throw Failure.login("can't read \(loginURL.path)")
        }
        let session = Session(host: host.hasSuffix("/") ? String(host.dropLast()) : host,
                              username: cfg["username"] as? String ?? "admin", password: password)
        try await session.login()
        do {
            let devices = try await session.devices()
            await session.logout()
            return devices
        } catch {
            await session.logout()
            throw error
        }
    }
}

// MARK: - Session

private final class Session {
    let host, username, password: String
    private let http: URLSession
    private let trust: TrustRouterCertificate

    private var aesKey = "", aesIV = ""   // 16 random digits each, as the web page does
    private var hash = ""
    private var seq = 0
    private var authN = "", authE = ""
    private var stok = ""
    private var sysauth: String?

    private static let signatureOffset = 53

    init(host: String, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
        trust = TrustRouterCertificate(host: URL(string: host)?.host ?? "")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        http = URLSession(configuration: cfg, delegate: trust, delegateQueue: nil)
    }

    deinit { http.finishTasksAndInvalidate() }

    private var referer: String { host + "/webpages/index.html" }

    // MARK: Sign-in

    func login() async throws {
        let pwdKey = try await keyPair(form: "keys", field: "password")
        let (authKey, authSeq) = try await authKeys()
        (authN, authE) = authKey
        seq = authSeq
        hash = sha256Hex(Data((username + password).utf8))
        aesKey = Self.randomDigits(16)
        aesIV = Self.randomDigits(16)

        let encryptedPassword = try RSA.encrypt(password, n: pwdKey.n, e: pwdKey.e, padding: .rsaEncryptionPKCS1)
        let encryptedData = try aesEncrypt("operation=login&password=\(encryptedPassword)&confirm=true")

        // RSA-OAEP signature, in chunks: at most 53 characters, less for small keys.
        let signText = "k=\(aesKey)&i=\(aesIV)&h=\(hash)&s=\(seq + encryptedData.count)"
        let step = min(Self.signatureOffset, authN.count / 2 - 2 * 20 - 2)
        guard step > 0 else { throw RouterClient.Failure.login("RSA key too small") }
        var sign = ""
        for chunk in signText.chunked(step) {
            sign += try RSA.encrypt(chunk, n: authN, e: authE, padding: .rsaEncryptionOAEPSHA1)
        }

        let (json, response) = try await post(
            "/cgi-bin/luci/;stok=/login?form=login",
            body: "sign=\(sign)&data=\(Self.quote(encryptedData, keepSlash: true))",
            headers: ["Referer": referer, "Content-Type": "application/x-www-form-urlencoded"])
        guard let reply = try decrypt(json) else { throw RouterClient.Failure.login("no data") }
        guard reply["success"] as? Bool == true else {
            let inner = reply["data"] as? [String: Any]
            let code = reply["errorcode"] ?? inner?["errorcode"] ?? "unknown"
            var detail = ""
            if let inner, inner["failureCount"] != nil || inner["attemptsAllowed"] != nil {
                detail = " (failureCount=\(inner["failureCount"] ?? "-"), attemptsAllowed=\(inner["attemptsAllowed"] ?? "-"))"
            }
            throw RouterClient.Failure.login("\(code)\(detail)")
        }
        guard let token = (reply["data"] as? [String: Any])?["stok"] as? String else {
            throw RouterClient.Failure.login("no session token")
        }
        stok = token
        if let cookie = response.value(forHTTPHeaderField: "Set-Cookie"),
           let r = cookie.range(of: #"sysauth=([^;]+)"#, options: .regularExpression) {
            sysauth = String(cookie[r].dropFirst("sysauth=".count))
        }
    }

    private func keyPair(form: String, field: String) async throws -> (n: String, e: String) {
        let (json, _) = try await post("/cgi-bin/luci/;stok=/login?form=\(form)&operation=read", body: "", headers: [:])
        guard let pair = (json["data"] as? [String: Any])?[field] as? [String], pair.count >= 2 else {
            throw RouterClient.Failure.login("no \(field) key")
        }
        return (pair[0], pair[1])
    }

    private func authKeys() async throws -> ((n: String, e: String), Int) {
        let (json, _) = try await post("/cgi-bin/luci/;stok=/login?form=auth&operation=read", body: "", headers: [:])
        guard let data = json["data"] as? [String: Any], let key = data["key"] as? [String], key.count >= 2,
              let seq = (data["seq"] as? NSNumber)?.intValue else {
            throw RouterClient.Failure.login("no auth key")
        }
        return ((key[0], key[1]), seq)
    }

    func logout() async {
        _ = try? await request("admin/system?form=logout", "operation=write", ignoreResponse: true)
        stok = ""
        sysauth = nil
    }

    // MARK: Device list (same sources as tplinkrouterc6u's get_status)

    func devices() async throws -> [RouterClient.Device] {
        var byMac: [String: RouterClient.Device] = [:]
        var order: [String] = []
        func add(_ mac: String?, _ name: String?, _ ip: String?) {
            guard let raw = mac, !raw.isEmpty else { return }
            let m = raw.replacingOccurrences(of: "-", with: ":").lowercased()
            if byMac[m] == nil { order.append(m) }
            byMac[m] = RouterClient.Device(mac: m, name: name ?? byMac[m]?.name ?? "", ip: ip ?? byMac[m]?.ip ?? "")
        }

        guard let status = try await request("admin/status?form=all&operation=read", "operation=read") as? [String: Any] else {
            throw RouterClient.Failure.response("status is not an object")
        }
        for key in ["access_devices_wired", "access_devices_wireless_host", "access_devices_wireless_guest"] {
            for item in status[key] as? [[String: Any]] ?? [] {
                add(item["macaddr"] as? String, item["hostname"] as? String ?? "", item["ipaddr"] as? String ?? "")
            }
        }
        // Clients only listed here (e.g. MLO / 6 GHz); history rows have onlineTime 0.
        if let smart = try? await request("admin/smart_network?form=game_accelerator&operation=loadDevice",
                                          "operation=loadDevice") as? [[String: Any]] {
            for item in smart {
                guard let mac = item["mac"] as? String else { continue }
                let known = byMac[mac.replacingOccurrences(of: "-", with: ":").lowercased()] != nil
                let online = item["onlineTime"] ?? item["online_time"]
                if !known, let t = online, "\(t)" == "0" || "\(t)" == "0.0" { continue }
                if !known { add(mac, item["deviceName"] as? String ?? "", item["ip"] as? String ?? "0.0.0.0") }
            }
        }
        // Wi-Fi clients without an address yet.
        if let stats = try? await request("admin/wireless?form=statistics", "operation=load") as? [[String: Any]] {
            for item in stats {
                guard let mac = item["mac"] as? String,
                      byMac[mac.replacingOccurrences(of: "-", with: ":").lowercased()] == nil else { continue }
                add(mac, "", "0.0.0.0")
            }
        }
        return order.compactMap { byMac[$0] }
    }

    // MARK: Signed requests

    /// One signed, encrypted request; returns the "data" block of the answer.
    func request(_ path: String, _ data: String, ignoreResponse: Bool = false) async throws -> Any? {
        let isWrite = ["operation=write", "operation=save", "operation=update"].contains { data.contains($0) }
        let (path, body) = Self.mergeParams(path: path, body: data)
        let encrypted = try aesEncrypt(body)
        hash = sha256Hex(Data(encrypted.utf8))
        let signText = "h=\(hash)&s=\(seq + encrypted.count)"
        let hmacKey = SymmetricKey(data: Data("k=\(aesKey)&i=\(aesIV)".utf8))
        let sign = signText.chunked(Self.signatureOffset).map {
            HMAC<SHA256>.authenticationCode(for: Data($0.utf8), using: hmacKey).map { String(format: "%02x", $0) }.joined()
        }.joined()

        var headers = ["Referer": referer, "Origin": host, "Content-Type": "application/x-www-form-urlencoded"]
        if let sysauth { headers["Cookie"] = "sysauth=\(sysauth)" }
        let (json, _) = try await post("/cgi-bin/luci/;stok=\(stok)/\(path)",
                                       body: "sign=\(sign)&data=\(Self.quote(encrypted, keepSlash: !isWrite))",
                                       headers: headers, ignoreResponse: ignoreResponse)
        if ignoreResponse { return nil }
        guard let reply = try decrypt(json), reply["success"] as? Bool == true else {
            throw RouterClient.Failure.response("\(path) was refused")
        }
        return reply["data"] ?? reply
    }

    /// Form keys present in both the path and the body: an identical pair is
    /// dropped from the body (the router rejects duplicates); a differing one
    /// keeps the body value and leaves the path.
    static func mergeParams(path: String, body: String) -> (String, String) {
        guard let q = path.firstIndex(of: "?") else { return (path, body) }
        let base = String(path[..<q])
        func pairs(_ s: Substring) -> [(String, String)] {
            s.split(separator: "&").map { p in
                let kv = p.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(kv[0]), kv.count > 1 ? String(kv[1]) : "")
            }
        }
        let pathPairs = pairs(path[path.index(after: q)...])
        let pathDict = Dictionary(pathPairs, uniquingKeysWith: { _, last in last })
        var newBody: [(String, String)] = []
        var conflicts = Set<String>()
        for (k, v) in pairs(Substring(body)) {
            if let pv = pathDict[k] {
                if pv == v { continue }
                conflicts.insert(k)
            }
            newBody.append((k, v))
        }
        let kept = pathPairs.filter { !conflicts.contains($0.0) }
        let newPath = kept.isEmpty ? base : base + "?" + kept.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        return (newPath, newBody.map { "\($0.0)=\($0.1)" }.joined(separator: "&"))
    }

    // MARK: HTTP

    private func post(_ path: String, body: String, headers: [String: String],
                      ignoreResponse: Bool = false) async throws -> ([String: Any], HTTPURLResponse) {
        guard let url = URL(string: host + path) else { throw RouterClient.Failure.request("bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await http.data(for: req)
        } catch {
            throw RouterClient.Failure.request(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RouterClient.Failure.request("no HTTP answer") }
        if ignoreResponse { return ([:], http) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouterClient.Failure.response("HTTP \(http.statusCode), not JSON")
        }
        return (json, http)
    }

    /// Python's urllib.parse.quote: everything but unreserved characters (and "/" unless asked) is escaped.
    static func quote(_ s: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Crypto

    private func decrypt(_ json: [String: Any]) throws -> [String: Any]? {
        guard let data = json["data"] as? String else { return nil }
        let text = try aesDecrypt(data)
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private func aesEncrypt(_ text: String) throws -> String {
        try AES.cbc(CCOperation(kCCEncrypt), Data(text.utf8), key: aesKey, iv: aesIV).base64EncodedString()
    }

    private func aesDecrypt(_ b64: String) throws -> String {
        guard let data = Data(base64Encoded: b64) else { throw RouterClient.Failure.response("bad base64") }
        let plain = try AES.cbc(CCOperation(kCCDecrypt), data, key: aesKey, iv: aesIV)
        guard let text = String(data: plain, encoding: .utf8) else { throw RouterClient.Failure.response("bad text") }
        return text
    }

    static func randomDigits(_ n: Int) -> String {
        String((0..<n).map { _ in Character(String(Int.random(in: 0...9))) })
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            let a = index(startIndex, offsetBy: $0)
            return String(self[a..<(index(a, offsetBy: size, limitedBy: endIndex) ?? endIndex)])
        }
    }
}

// MARK: - AES-CBC with PKCS#7 padding

private enum AES {
    static func cbc(_ op: CCOperation, _ input: Data, key: String, iv: String) throws -> Data {
        let k = Data(key.utf8), v = Data(iv.utf8)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                k.withUnsafeBytes { kb in
                    v.withUnsafeBytes { vb in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kb.baseAddress, k.count, vb.baseAddress,
                                i.baseAddress, input.count, o.baseAddress, o.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw RouterClient.Failure.response("AES error \(status)") }
        return out.prefix(moved)
    }
}

// MARK: - RSA public-key encryption from a hex modulus and exponent

private enum RSA {
    static func encrypt(_ text: String, n: String, e: String, padding: SecKeyAlgorithm) throws -> String {
        guard let modulus = Data(hex: n), let exponent = Data(hex: e) else {
            throw RouterClient.Failure.login("bad RSA key")
        }
        let der = sequence(integer(modulus) + integer(exponent))   // PKCS#1 RSAPublicKey
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw RouterClient.Failure.login("RSA key: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let out = SecKeyCreateEncryptedData(key, padding, Data(text.utf8) as CFData, &error) as Data? else {
            throw RouterClient.Failure.login("RSA: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        let hex = out.map { String(format: "%02x", $0) }.joined()
        return hex.count < n.count ? String(repeating: "0", count: n.count - hex.count) + hex : hex
    }

    private static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func integer(_ raw: Data) -> Data {
        var v = Data(raw.drop(while: { $0 == 0 }))
        if v.isEmpty { v = Data([0]) }
        if v[v.startIndex] & 0x80 != 0 { v.insert(0, at: 0) }
        return Data([0x02]) + length(v.count) + v
    }

    private static func sequence(_ content: Data) -> Data { Data([0x30]) + length(content.count) + content }
}

private extension Data {
    init?(hex: String) {
        let s = hex.count % 2 == 1 ? "0" + hex : hex
        var d = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        self = d
    }
}

// MARK: - The router's self-signed certificate

/// Accepts the router's self-signed certificate, for the router's own
/// address only; every other host gets the normal system checks.
private final class TrustRouterCertificate: NSObject, URLSessionDelegate {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
