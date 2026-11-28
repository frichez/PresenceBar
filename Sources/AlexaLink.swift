import Foundation

/// Link to AlexaBridge (~/Projects/AlexaBridge), the one app that talks to the Echo. Same file in CameraBar,
/// PresenceBar and HeaterBar. Distributed notifications only: if AlexaBridge isn't running, nothing happens.
enum AlexaLink {
    private static let sayName = Notification.Name("be.home.alexa.say")
    private static let commandName = Notification.Name("be.home.alexa.command")
    private static let replyName = Notification.Name("be.home.alexa.reply")
    private static let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    /// A spoken alert in French. The bridge drops it in the quiet hours or within 30 s of the previous alert.
    static func say(_ text: String) { post(sayName, ["app": app, "text": text]) }

    /// Sentences the Echo heard for this app, lower case without accents ("quoi de neuf cameras").
    /// Return the French answer to speak, or nil to say nothing. Called on the main thread.
    static func onCommand(_ handler: @escaping @MainActor (String) -> String?) {
        observer = DistributedNotificationCenter.default().addObserver(forName: commandName, object: app, queue: .main) { n in
            guard let id = n.userInfo?["id"] as? String, let text = n.userInfo?["text"] as? String else { return }
            let answer = MainActor.assumeIsolated { handler(text) }
            post(replyName, ["app": app, "id": id, "text": answer ?? ""])
        }
    }

    private static func post(_ name: Notification.Name, _ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: app, userInfo: info, deliverImmediately: true)
    }
}
