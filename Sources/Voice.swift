import Foundation

/// "Alexa, qui est à la maison ?" through AlexaBridge (AlexaLink.swift). Read-only: it reports the last check,
/// it never starts one. Without AlexaBridge running, nothing.
extension PresenceModel {
    func whoIsHome() -> String {
        let people = state.people ?? []
        guard !people.isEmpty else { return "PresenceBar n'a pas encore de résultat." }
        let home = people.filter(\.home).map(\.who), away = people.filter { !$0.home }
        var text: String
        if home.isEmpty { text = "Personne n'est à la maison." }
        else if away.isEmpty { text = "Tout le monde est à la maison : \(Self.list(home))." }
        else {
            text = "À la maison : \(Self.list(home)). Absent\(away.count > 1 ? "s" : "") : "
                + Self.list(away.map { "\($0.who) depuis \(Self.spokenTime($0.since))" }) + "."
        }
        if let checked = state.checkedAt, Date().timeIntervalSince1970 - Double(checked) > 15 * 60 {
            text += " Dernière vérification à \(Self.spokenTime(checked))."
        }
        if paused { text += " PresenceBar est en pause." }
        return text
    }

    private static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " et " + items.last!
    }

    /// "9 heures 05", or "hier à 21 heures 30", or "le 26 à 8 heures".
    private static func spokenTime(_ t: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(t)), cal = Calendar.current
        let c = cal.dateComponents([.day, .hour, .minute], from: d)
        let hm = "\(c.hour!) heures" + (c.minute! == 0 ? "" : String(format: " %02d", c.minute!))
        if cal.isDateInToday(d) { return hm }
        if cal.isDateInYesterday(d) { return "hier à \(hm)" }
        return "le \(c.day!) à \(hm)"
    }
}
