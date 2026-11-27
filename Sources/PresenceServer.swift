import Foundation
import Network

/// Read-only HTTP API for other apps on this Mac (HeaterBar, scripts).
/// Listens on 127.0.0.1 only, so nothing outside this Mac can reach it.
///
///   GET /presence          the current state (same JSON as presence-state.json)
///   GET /events?limit=20   the latest changes, newest first
///
/// The data is only as fresh as the last check: compare `checked_at` with
/// the current time (the Mac may have slept, or PresenceBar may be paused).
final class PresenceServer {
    static let port: UInt16 = 8787
    static var url: String { "http://127.0.0.1:\(port)/presence" }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "presence.server")
    private(set) var error: String?

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] state in
                if case let .failed(e) = state { self?.error = "API not available: \(e)" }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            self.error = "API not available: \(error)"
        }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (status, body) = Self.respond(to: request)
            let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    static func respond(to request: String) -> (String, Data) {
        let parts = (request.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: String(parts[1])) else {
            return ("400 Bad Request", Data(#"{"error":"bad request"}"#.utf8))
        }
        switch comps.path {
        case "/presence", "/":
            let data = (try? Data(contentsOf: Detector.stateURL)) ?? Data(#"{"error":"no check yet"}"#.utf8)
            return ("200 OK", data)
        case "/events":
            let limit = comps.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 20
            let events = Array(Detector.loadEvents().reversed().prefix(max(0, limit)))
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            return ("200 OK", (try? enc.encode(events)) ?? Data("[]".utf8))
        default:
            return ("404 Not Found", Data(#"{"error":"use /presence or /events"}"#.utf8))
        }
    }
}
