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
    @NSApplicationDelegateAdaptor(ReopenDelegate.self) private var delegate
    @StateObject private var model = PresenceModel()

    var body: some Scene {
        MenuBarExtra {
            PresencePanel(model: model)
        } label: {
            MenuIcon(model: model)
        }
        .menuBarExtraStyle(.window)

        // The same panel in a normal window, for when the menu bar icon is hidden (behind the notch on the
        // laptop screen): opening PresenceBar again from Finder or Spotlight while it runs shows this window.
        Window("PresenceBar", id: "panel") {
            PresencePanel(model: model)
        }
        .windowResizability(.contentSize)
    }
}

extension Notification.Name { static let showPresencePanel = Notification.Name("PresenceBar.showPanel") }

/// Opening the app again while it runs (Finder, Spotlight, `open`) asks for the panel window.
final class ReopenDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .showPresencePanel, object: nil)
        return false
    }
}

/// The menu bar icon; it is always alive, so it is the view that opens the panel window on request.
struct MenuIcon: View {
    @ObservedObject var model: PresenceModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.menuIcon)
            .onReceive(NotificationCenter.default.publisher(for: .showPresencePanel)) { _ in
                openWindow(id: "panel")
                NSApp.activate()
            }
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

    private var timer: Timer?
    private var lastRun: Date?
    private var wakeObserver: NSObjectProtocol?

    init(startServer: Bool = true) {
        if startServer { startAppLink() }  // the API for the other apps (PresenceAPI.swift)
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

    /// Every phone in phones.json is on the Wi-Fi.
    var everyoneHome: Bool {
        let people = state.people ?? []
        return !people.isEmpty && people.allSatisfy(\.home)
    }

    static let familyIcon = "figure.2.and.child.holdinghands"

    var menuIcon: String {
        if paused { return "pause.circle" }
        if lastError != nil { return "exclamationmark.triangle" }
        if state.state == "away" { return "figure.walk.departure" }
        return everyoneHome ? Self.familyIcon : "house"
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
        let all = !away && model.everyoneHome
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("House").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: away ? "figure.walk.departure" : all ? PresenceModel.familyIcon : "house.fill")
                        .foregroundStyle(away ? .orange : all ? .green : .blue)
                    Text(away ? "Nobody home" : all ? "Everyone home" : "Someone home").font(.title3.weight(.medium))
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

    /// Who the Changes list shows: nil for everyone, "house" or a person.
    @State private var filter: String?

    private var changes: some View {
        let names = (model.state.people ?? []).map(\.who)
        let shown = model.events.reversed().filter { filter == nil || $0.who == filter }
        let days = Dictionary(grouping: shown, by: { String($0.time.prefix(10)) })
        let awayTimes = Self.awayDurations(model.events)
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Show", selection: $filter) {
                Text("All").tag(String?.none)
                Text("House").tag(String?.some("house"))
                ForEach(names, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            if shown.isEmpty {
                Text("No changes yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(days.keys.sorted(by: >), id: \.self) { day in
                            Section {
                                ForEach(days[day] ?? []) { e in changeRow(e, away: awayTimes[e.id]) }
                            } header: {
                                Text(dayTitle(day)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.top, day == days.keys.max() ? 0 : 4)
                            }
                        }
                    }
                    .padding(.trailing, 12)   // room for the scroll bar
                }
                .frame(height: min(220, CGFloat(shown.count + days.count) * 19))
                .scrollIndicators(.automatic)
            }
        }
    }

    /// For each "came home" event (a person, or "Someone home" for the
    /// house): how long since the matching "left" event, in seconds.
    static func awayDurations(_ events: [Detector.Event]) -> [Int: TimeInterval] {
        let p = DateFormatter(); p.dateFormat = "yyyy-MM-dd HH:mm"
        var left: [String: Date] = [:]
        var result: [Int: TimeInterval] = [:]
        for e in events {   // oldest first
            guard let t = p.date(from: e.time) else { continue }
            if e.event == "away" {
                left[e.who] = t
            } else if let l = left.removeValue(forKey: e.who) {
                result[e.id] = t.timeIntervalSince(l)
            }
        }
        return result
    }

    /// 2700 → "45 min", 12000 → "3 h 20", 190000 → "2 d 5 h"
    private func duration(_ d: TimeInterval) -> String {
        let m = Int(d / 60)
        if m < 60 { return "\(m) min" }
        if m < 24 * 60 { return m % 60 == 0 ? "\(m / 60) h" : String(format: "%d h %02d", m / 60, m % 60) }
        let h = m / 60
        return h % 24 == 0 ? "\(h / 24) d" : "\(h / 24) d \(h % 24) h"
    }

    private func changeRow(_ e: Detector.Event, away: TimeInterval?) -> some View {
        HStack(spacing: 8) {
            Text(String(e.time.suffix(5))).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Image(systemName: e.who == "house" ? (e.event == "away" ? "house" : "house.fill")
                                               : (e.event == "away" ? "figure.walk.departure" : "figure.walk.arrival"))
                .foregroundStyle(e.event == "away" ? .orange : .blue)
                .frame(width: 16)
            Text(text(for: e))
                .fontWeight(e.who == "house" ? .medium : .regular)
                .lineLimit(1).truncationMode(.tail)
            if let away {
                Text(e.who == "house" ? "empty for \(duration(away))" : "away for \(duration(away))")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
    }

    /// "2026-11-27" → "Today", "Yesterday", "Wed 26 Nov" or "Wed 26 Nov 2025"
    private func dayTitle(_ day: String) -> String {
        let p = DateFormatter(); p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: day) else { return day }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEE d MMM" : "EEE d MMM yyyy"
        return f.string(from: d)
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
                Text("Last check \(shortTime(checked))" + (model.state.routerOK == false ? " - router not readable, keeping the last state" + (model.state.routerError.map { " (\($0))" } ?? "") : ""))
                    .font(.caption).foregroundStyle(model.state.routerOK == false ? .orange : .secondary)
            }
            if let err = model.lastError {
                Text("Last check failed: \(err)").font(.caption).foregroundStyle(.red)
            }
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
