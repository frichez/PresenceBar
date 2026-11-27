import Foundation

/// Home/away detector from the family phones on the Wi-Fi. It only reports
/// presence; what to do with it is up to the apps that read it
/// (user's choice, 2026-11-27: PresenceBar stays agnostic).
///
/// Rule: a person is home when their phone (~/.config/tplink/phones.json)
/// is on the TP-Link Archer at this check, away when it is not. No grace
/// period (user's choice, 2026-11-27: immediate status; a 30 min grace was
/// used before). The house is home while anyone is. When the router can't be
/// read, every decision is kept.
///
/// Files in ~/Projects/PresenceBar/data (private: gitignored, user's choice
/// 2026-11-27; the phones list and router login stay in ~/.config):
///   presence-state.json   current state, also served by PresenceServer
///   presence-events.csv   one row per change: a person or the house leaving / coming home
///   presence-log.csv      one row per check, for later analysis
///   presence-phones-seen.json  last time each device was on the Wi-Fi
///
/// History: the Netatmo noise detector was removed on 2026-11-26 (log kept in
/// presence-log-noise-2026-11-26.csv), the Nest Auto-Away column on
/// 2026-11-27 (Absence auto is off on purpose, so it always said home).
struct Detector {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let repo = home.appendingPathComponent("Projects/PresenceBar")
    static let dir = repo.appendingPathComponent("data")
    static let logURL = dir.appendingPathComponent("presence-log.csv")
    static let eventsURL = dir.appendingPathComponent("presence-events.csv")
    static let stateURL = dir.appendingPathComponent("presence-state.json")
    static let phonesURL = home.appendingPathComponent(".config/tplink/phones.json")
    static let seenURL = dir.appendingPathComponent("presence-phones-seen.json")
    static let helper = repo.appendingPathComponent("archer_presence.py")
    static let helperPython = repo.appendingPathComponent(".venv-tplink/bin/python")

    // MARK: State (presence-state.json)

    struct Person: Codable, Equatable {
        var who: String
        var home: Bool
        var since: Int          // unix time of the last change
        var lastSeen: Int?      // unix time the phone was last on the Wi-Fi

        enum CodingKeys: String, CodingKey { case who, home, since, lastSeen = "last_seen" }
    }

    struct State: Codable {
        var state: String       // "home" or "away": the whole house
        var since: Int
        var checkedAt: Int?     // last check, successful or not
        var routerOK: Bool?
        var people: [Person]?   // in phones.json order
        var home: [String]?     // who is home, for convenience

        enum CodingKeys: String, CodingKey {
            case state, since, checkedAt = "checked_at", routerOK = "router_ok", people, home
        }
    }

    static func loadState() -> State {
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: data) {
            return s
        }
        return State(state: "home", since: Int(Date().timeIntervalSince1970))
    }

    static func saveState(_ s: State) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: stateURL, options: .atomic)
    }

    // MARK: One check

    struct Outcome {
        let state: String
        let changed: Bool
        let summary: String
    }

    static func runOnce() async throws -> Outcome {
        let now = Date().timeIntervalSince1970
        let nowInt = Int(now)
        var s = loadState()
        let check = await phoneCheck(now: now)

        var events: [[String]] = []
        let wasHouse = s.state
        if check.ok {
            let before = Dictionary((s.people ?? []).map { ($0.who, $0) }, uniquingKeysWith: { a, _ in a })
            var people: [Person] = []
            for p in check.people {
                let home = p.lastSeen == now   // on the Wi-Fi at this check
                let seen = p.lastSeen.map { Int($0) }
                if let old = before[p.who] {
                    if old.home != home {
                        people.append(Person(who: p.who, home: home, since: nowInt, lastSeen: seen))
                        events.append([p.who, home ? "home" : "away", seen.map(stamp) ?? "-"])
                    } else {
                        people.append(Person(who: old.who, home: home, since: old.since, lastSeen: seen))
                    }
                } else {
                    // First time this person is tracked: no event, just a starting point.
                    people.append(Person(who: p.who, home: home, since: nowInt, lastSeen: seen))
                }
            }
            s.people = people
            s.home = people.filter(\.home).map(\.who)
            let house = people.contains(where: \.home) ? "home" : "away"
            if house != s.state {
                s.state = house
                s.since = nowInt
            }
        }
        s.checkedAt = nowInt
        s.routerOK = check.ok
        let changed = s.state != wasHouse
        if changed { events.append(["house", s.state, "-"]) }
        try saveState(s)

        for e in events { try append(eventsURL, eventsHeader, [stamp(nowInt)] + e) }
        let homeList = s.home ?? []
        try append(logURL, logHeader, [stamp(nowInt), s.state, changed ? "1" : "0",
                                       check.ok ? (homeList.isEmpty ? "none" : homeList.joined(separator: "+")) : "?",
                                       check.new.isEmpty ? "-" : check.new.joined(separator: " ")])
        let who = check.ok ? (homeList.isEmpty ? "no family phone" : homeList.joined(separator: ", ")) : "router not readable"
        return Outcome(state: s.state, changed: changed, summary: "\(s.state) | \(who)")
    }

    // MARK: Phones on the TP-Link Archer (read-only, via archer_presence.py)

    struct Check {
        var ok = false
        var people: [(who: String, lastSeen: Double?)] = []   // phones.json order
        var new: [String] = []    // name@mac of phone-like devices not in phones.json
    }

    /// Runs archer_presence.py (the TP-Link sign-in needs its crypto library).
    static func routerDevices() async -> [[String: Any]]? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = helperPython
                p.arguments = ["-I", helper.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      o["ok"] as? Bool == true else { cont.resume(returning: nil); return }
                cont.resume(returning: o["devices"] as? [[String: Any]])
            }
        }
    }

    static func phoneCheck(now: Double) async -> Check {
        guard let data = try? Data(contentsOf: phonesURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = await routerDevices() else { return Check() }
        let known = (cfg["phones"] as? [[String: Any]] ?? []).compactMap { p -> (mac: String, who: String)? in
            guard let mac = (p["mac"] as? String)?.lowercased(), let who = p["who"] as? String else { return nil }
            return (mac, who)
        }
        let ignore = Set((cfg["not_phones"] as? [String: Any] ?? [:]).keys.map { $0.lowercased() })
        var seen = (try? JSONSerialization.jsonObject(with: Data(contentsOf: seenURL))) as? [String: Double] ?? [:]
        var result = Check(ok: true)
        for d in devices {
            guard let mac = (d["mac"] as? String)?.lowercased() else { continue }
            seen[mac] = now
            let name = d["name"] as? String ?? ""
            let phoneLike = (d["private"] as? Bool ?? false) || name.lowercased().contains("phone")
            if phoneLike && !ignore.contains(mac) && !known.contains(where: { $0.mac == mac }) {
                result.new.append("\(name.isEmpty ? "unnamed" : name)@\(mac)")
            }
        }
        if let out = try? JSONSerialization.data(withJSONObject: seen) { try? out.write(to: seenURL, options: .atomic) }
        result.people = known.map { ($0.who, seen[$0.mac]) }
        return result
    }

    // MARK: CSV files

    static let eventsHeader = ["time", "who", "event", "last_seen"]
    static let logHeader = ["time", "house", "changed", "phones_home", "new_devices"]

    static func stamp(_ t: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    static func append(_ url: URL, _ header: [String], _ fields: [String]) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try (header.joined(separator: ",") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        // Commas would shift the columns; none are expected, but be safe.
        h.write((fields.map { $0.replacingOccurrences(of: ",", with: ";") }.joined(separator: ",") + "\n").data(using: .utf8)!)
    }

    struct Event: Identifiable, Codable {
        let id: Int
        let time, who, event, lastSeen: String

        enum CodingKeys: String, CodingKey { case id, time, who, event, lastSeen = "last_seen" }
    }

    /// Events, oldest first.
    static func loadEvents() -> [Event] {
        guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).filter { !$0.isEmpty }.dropFirst().enumerated().compactMap { i, line in
            let f = line.components(separatedBy: ",")
            guard f.count >= 4 else { return nil }
            return Event(id: i, time: f[0], who: f[1], event: f[2], lastSeen: f[3])
        }
    }

    /// Phone-like devices seen at the last check that are not in phones.json.
    static func lastNewDevices() -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8),
              let last = text.components(separatedBy: .newlines).last(where: { !$0.isEmpty }) else { return "-" }
        let f = last.components(separatedBy: ",")
        return f.count >= 5 ? f[4] : "-"
    }
}
