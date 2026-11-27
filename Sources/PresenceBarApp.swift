import AppKit
import SwiftUI

/// Menu bar app that runs the log-only presence detector (Detector.swift)
/// every 5 minutes while it is open, shows who is home and the latest
/// changes, and serves the state to other apps (PresenceServer.swift). It
/// only reports presence and controls nothing.
#if !SNAPSHOT
@main
#endif
struct PresenceBarApp: App {
    @StateObject private var model = PresenceModel()

    var body: some Scene {
        MenuBarExtra {
            PresencePanel(model: model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class PresenceModel: ObservableObject {
    static let interval: TimeInterval = 5 * 60   // user's choice, 2026-11-27 (was 10 min)
    private static let pausedKey = "paused"

    @Published var state = Detector.loadState()
    @Published var events: [Detector.Event] = []
    @Published var newDevices = "-"
    @Published var paused = UserDefaults.standard.bool(forKey: pausedKey)
    @Published var busy = false
    @Published var lastError: String?

    let server = PresenceServer()
    private var timer: Timer?
    private var lastRun: Date?
    private var wakeObserver: NSObjectProtocol?

    init(startServer: Bool = true) {
        if startServer { server.start() }
        refresh()
        // A 60 s tick rather than a 600 s timer: after the Mac sleeps, the
        // next check then comes within a minute of waking.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    var menuIcon: String {
        if paused { return "pause.circle" }
        if lastError != nil { return "exclamationmark.triangle" }
        return state.state == "away" ? "figure.walk.departure" : "house"
    }

    private func tick() {
        guard !paused, !busy else { return }
        if let last = lastRun, Date().timeIntervalSince(last) < Self.interval - 5 { return }
        runNow()
    }

    func runNow() {
        guard !busy else { return }
        busy = true
        lastRun = Date()
        Task {
            do {
                _ = try await Detector.runOnce()
                lastError = nil
            } catch {
                lastError = String(describing: error)
            }
            busy = false
            refresh()
        }
    }

    func setPaused(_ pause: Bool) {
        paused = pause
        UserDefaults.standard.set(pause, forKey: Self.pausedKey)
        if !pause { lastRun = nil; tick() }
    }

    func refresh() {
        state = Detector.loadState()
        events = Detector.loadEvents()
        newDevices = Detector.lastNewDevices()
    }

    func openEvents() { NSWorkspace.shared.open(Detector.eventsURL) }
}

/// "2026-11-27 08:05" → "Fri 08:05"
private func shortTime(_ s: String) -> String {
    let p = DateFormatter(); p.dateFormat = "yyyy-MM-dd HH:mm"
    guard let d = p.date(from: s) else { return s }
    let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: d)
}

private func shortTime(_ t: Int) -> String {
    let d = Date(timeIntervalSince1970: TimeInterval(t))
    let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: d)
}

struct PresencePanel: View {
    @ObservedObject var model: PresenceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            people
            Divider()
            changes
            Divider()
            controls
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        let away = model.state.state == "away"
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("House").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: away ? "figure.walk.departure" : "house.fill")
                        .foregroundStyle(away ? .orange : .blue)
                    Text(away ? "Nobody home" : "Someone home").font(.title3.weight(.medium))
                }
                Text("since \(shortTime(model.state.since))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(model.state.people ?? [], id: \.who) { p in
                HStack(spacing: 8) {
                    Image(systemName: p.home ? "iphone" : "iphone.slash")
                        .foregroundStyle(p.home ? .blue : .orange)
                        .frame(width: 16)
                    Text(p.who).frame(width: 60, alignment: .leading)
                    Text(p.home ? "home since \(shortTime(p.since))" : "away since \(shortTime(p.since))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !p.home, let seen = p.lastSeen {
                        Text("last seen \(shortTime(seen))").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
            }
            if model.state.people == nil {
                Text("Waiting for the first check.").font(.caption).foregroundStyle(.secondary)
            }
            if model.newDevices != "-" {
                Label("Not yet known: " + model.newDevices.replacingOccurrences(of: " ", with: ", "),
                      systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Phone-like devices on the Wi-Fi that are not in ~/.config/tplink/phones.json")
            }
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Changes").font(.caption).foregroundStyle(.secondary)
            ForEach(model.events.suffix(12).reversed()) { e in
                HStack(spacing: 8) {
                    Text(shortTime(e.time)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 66, alignment: .leading)
                    Image(systemName: e.who == "house" ? (e.event == "away" ? "house" : "house.fill")
                                                       : (e.event == "away" ? "figure.walk.departure" : "figure.walk.arrival"))
                        .foregroundStyle(e.event == "away" ? .orange : .blue)
                        .frame(width: 16)
                    Text(text(for: e))
                        .fontWeight(e.who == "house" ? .medium : .regular)
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.caption)
            }
            if model.events.isEmpty {
                Text("No changes yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func text(for e: Detector.Event) -> String {
        if e.who == "house" {
            return e.event == "away" ? "Nobody home" : "Someone home"
        }
        return e.event == "away" ? "\(e.who) left" : "\(e.who) came home"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(model.paused ? Color.gray : Color.green).frame(width: 8, height: 8)
                Text(model.paused ? "Paused" : "Checking every 5 minutes while PresenceBar is open")
                    .font(.caption)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let checked = model.state.checkedAt {
                Text("Last check \(shortTime(checked))" + (model.state.routerOK == false ? " - router not readable, keeping the last state" : ""))
                    .font(.caption).foregroundStyle(model.state.routerOK == false ? .orange : .secondary)
            }
            if let err = model.lastError {
                Text("Last check failed: \(err)").font(.caption).foregroundStyle(.red)
            }
            Text(model.server.error ?? "API for other apps: \(PresenceServer.url)")
                .font(.caption).foregroundStyle(model.server.error == nil ? Color.secondary : Color.red)
                .textSelection(.enabled)
            HStack {
                Button(model.paused ? "Resume" : "Pause") { model.setPaused(!model.paused) }
                Button("Check now") { model.runNow() }.disabled(model.busy)
                Button("Open log") { model.openEvents() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }
}
