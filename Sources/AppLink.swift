import AppKit

/// AppLink: a small general-purpose API between the home apps on this Mac (CameraBar, PresenceBar, HeaterBar,
/// AlexaBridge). Same file in each app; the master copy is ~/Projects/AlexaBridge/Sources/AppLink.swift.
/// Distributed notifications only: no ports, no server. Nothing here knows about voice or French.
///
///   get     ask an app for its state         AppLink.get("PresenceBar")              -> JSON object
///   do      ask an app to do something       AppLink.perform("CameraBar", "pause")   -> JSON object
///   event   an app tells whoever listens     AppLink.send(event: "incident", [...])
///
/// Every answer carries "api": AppLink.version. If the other app isn't running, the call returns at once
/// with .failed("not running"); nothing waits and nothing breaks.
@MainActor
enum AppLink {
    nonisolated static let version = 1

    enum Response {
        case ok([String: Any])
        case failed(String)
        var body: [String: Any]? { if case let .ok(b) = self { return b }; return nil }
        var error: String? { if case let .failed(e) = self { return e }; return nil }
    }

    /// Server side. `get` gets the request's arguments (often empty) and returns the state.
    /// `perform` gets the action and its arguments and calls `reply` once, now or later.
    static func serve(get: @escaping @MainActor ([String: Any]) -> [String: Any],
                      perform: (@MainActor (String, [String: Any], @escaping @MainActor (Response) -> Void) -> Void)? = nil) {
        getHandler = get; doHandler = perform
        guard requestObserver == nil else { return }
        requestObserver = center.addObserver(forName: requestName, object: app, queue: .main) { n in
            let info = n.userInfo ?? [:]
            guard let id = info["id"] as? String, let from = info["from"] as? String, let kind = info["kind"] as? String
            else { return }
            let args = decode(info["args"] as? String) ?? [:]
            MainActor.assumeIsolated {
                let answer: @MainActor (Response) -> Void = { respond(to: from, id: id, $0) }
                switch kind {
                case "get": answer(.ok(getHandler?(args) ?? [:]))
                case "do":
                    guard let doHandler else { return answer(.failed("\(app) has no actions")) }
                    doHandler(info["action"] as? String ?? "", args, answer)
                default: answer(.failed("unknown request \(kind)"))
                }
            }
        }
    }

    /// Client side.
    static func get(_ target: String, _ args: [String: Any] = [:], timeout: TimeInterval = 3) async -> Response {
        await request(target, kind: "get", action: "", args: args, timeout: timeout)
    }

    static func perform(_ target: String, _ action: String, _ args: [String: Any] = [:],
                        timeout: TimeInterval = 15) async -> Response {
        await request(target, kind: "do", action: action, args: args, timeout: timeout)
    }

    /// Events: tell whoever listens (nobody, if no other app runs).
    static func send(event type: String, _ body: [String: Any] = [:]) {
        post(eventName, object: app, ["type": type, "body": encode(body)])
    }

    /// Events from one app (or from all, with nil).
    static func onEvent(from source: String?, _ handler: @escaping @MainActor (_ app: String, _ type: String, _ body: [String: Any]) -> Void) {
        eventObservers.append(center.addObserver(forName: eventName, object: source, queue: .main) { n in
            let from = n.object as? String ?? "?", type = n.userInfo?["type"] as? String ?? ""
            let body = decode(n.userInfo?["body"] as? String) ?? [:]
            MainActor.assumeIsolated { handler(from, type, body) }
        })
    }

    static func isRunning(_ target: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier != getpid()
                && ($0.localizedName == target || $0.bundleURL?.deletingPathExtension().lastPathComponent == target)
        }
    }

    // MARK: private

    nonisolated private static let requestName = Notification.Name("be.home.applink.request")    // object = target app
    nonisolated private static let responseName = Notification.Name("be.home.applink.response")  // object = requester (app.pid)
    nonisolated private static let eventName = Notification.Name("be.home.applink.event")        // object = source app
    nonisolated(unsafe) private static let center = DistributedNotificationCenter.default()
    nonisolated static let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    nonisolated private static let me = "\(app).\(getpid())"
    private static var getHandler: (@MainActor ([String: Any]) -> [String: Any])?
    private static var doHandler: (@MainActor (String, [String: Any], @escaping @MainActor (Response) -> Void) -> Void)?
    private static var requestObserver: NSObjectProtocol?
    private static var responseObserver: NSObjectProtocol?
    private static var eventObservers: [NSObjectProtocol] = []
    private static var waiting: [String: CheckedContinuation<Response, Never>] = [:]

    private static func request(_ target: String, kind: String, action: String, args: [String: Any],
                                timeout: TimeInterval) async -> Response {
        guard isRunning(target) else { return .failed("not running") }
        if responseObserver == nil {
            responseObserver = center.addObserver(forName: responseName, object: me, queue: .main) { n in
                let info = n.userInfo ?? [:]
                guard let id = info["id"] as? String else { return }
                let r: Response = info["ok"] as? String == "1" ? .ok(decode(info["body"] as? String) ?? [:])
                    : .failed(info["error"] as? String ?? "failed")
                MainActor.assumeIsolated { waiting.removeValue(forKey: id)?.resume(returning: r) }
            }
        }
        let id = UUID().uuidString
        return await withCheckedContinuation { cont in
            waiting[id] = cont
            post(requestName, object: target, ["id": id, "from": me, "kind": kind, "action": action, "args": encode(args)])
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated { waiting.removeValue(forKey: id)?.resume(returning: .failed("no answer")) }
            }
        }
    }

    private static func respond(to requester: String, id: String, _ r: Response) {
        switch r {
        case let .ok(body):
            var b = body; b["api"] = version
            post(responseName, object: requester, ["id": id, "ok": "1", "body": encode(b)])
        case let .failed(error):
            post(responseName, object: requester, ["id": id, "ok": "0", "error": error])
        }
    }

    nonisolated private static func post(_ name: Notification.Name, object: String, _ info: [String: String]) {
        center.postNotificationName(name, object: object, userInfo: info, deliverImmediately: true)
    }

    nonisolated private static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    nonisolated private static func decode(_ s: String?) -> [String: Any]? {
        s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}
