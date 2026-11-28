import Foundation

/// PresenceBar's AppLink API (AppLink.swift), for the other apps on this Mac (CameraBar, HeaterBar, AlexaBridge).
/// It replaced the HTTP service on 127.0.0.1:8787. Read-only: PresenceBar reports, it controls nothing.
///
///   get PresenceBar                  the last check: presence-state.json plus "paused"
///   get PresenceBar {"events": 20}   the same plus the latest 20 changes, newest first
///
///   event change                     {"who", "event": "home"/"away", "time", "previous_seconds"}
///                                    for each person who came home or left, at the check that saw it
///
/// The data is only as fresh as the last check: compare "checked_at" with the current time.
extension PresenceModel {
    func startAppLink() {
        AppLink.serve(get: { [weak self] args in self?.apiState(args) ?? [:] })
    }

    func apiState(_ args: [String: Any]) -> [String: Any] {
        var state = (try? Data(contentsOf: Detector.stateURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? ["error": "no check yet"]
        state["paused"] = paused
        if let n = args["events"] as? Int {
            let latest = Array(Detector.loadEvents().reversed().prefix(max(0, n)))
            state["events"] = (try? JSONEncoder().encode(latest))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        }
        return state
    }
}
