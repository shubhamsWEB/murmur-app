import AppKit
import EventKit

/// Reading what's inside apps, so "what's on my calendar tomorrow" gets an answer instead of an open app.
/// Calendars and reminders come straight from macOS (EventKit: every account, fast, no app to open). Other apps
/// that can be scripted describe themselves (their AppleScript dictionary), so a script that reads them uses the
/// right words.
@MainActor
enum AppData {
    private static let store = EKEventStore()

    // MARK: Calendar

    /// Events from `start` for `days` days, optionally only those mentioning `search`.
    static func events(start: String, days: Int, search: String) async -> String {
        guard await Permissions.events(.event, store: store) else { return noAccess("Calendars") }
        let calendar = Calendar.current
        let from = day(start)
        let span = min(max(days, 1), 62)
        guard let to = calendar.date(byAdding: .day, value: span, to: from) else { return "Couldn't work out those dates." }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        var events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        let wanted = search.lowercased().trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty {
            events = events.filter { event in
                [event.title, event.location, event.notes, event.calendar.title].compactMap { $0?.lowercased() }
                    .contains { $0.contains(wanted) }
            }
        }
        let range = span == 1 ? dayName(from) : "\(dayName(from)) to \(dayName(to.addingTimeInterval(-1)))"
        guard !events.isEmpty else {
            return "No events \(wanted.isEmpty ? "" : "about \"\(search)\" ")on \(range)."
        }
        var lines = ["Events, \(range) (\(events.count)):"]
        var lastDay = ""
        for event in events.prefix(80) {
            let heading = dayName(event.startDate)
            if span > 1, heading != lastDay { lines.append(heading + ":"); lastDay = heading }
            let when = event.isAllDay ? "all day" : "\(time(event.startDate))–\(time(event.endDate))"
            var line = "- \(when) \(event.title ?? "Untitled")"
            if let location = event.location, !location.isEmpty { line += " · \(location.prefix(80))" }
            line += " · \(event.calendar.title)"
            if let people = event.attendees, !people.isEmpty { line += " · \(people.count) people" }
            if let link = meetingLink(event) { line += " · \(link)" }
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                line += " · notes: \(notes.replacingOccurrences(of: "\n", with: " ").prefix(120))"
            }
            lines.append(line)
        }
        if events.count > 80 { lines.append("…and \(events.count - 80) more.") }
        return lines.joined(separator: "\n")
    }

    // MARK: Reminders

    /// Open reminders (or all, with `completed`), optionally only those mentioning `search`.
    static func reminders(search: String, completed: Bool) async -> String {
        guard await Permissions.events(.reminder, store: store) else { return noAccess("Reminders") }
        let predicate = completed ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let wanted = search.lowercased().trimmingCharacters(in: .whitespaces)
        let lines: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { @Sendable found in
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE d MMM, HH:mm"
                let rows = (found ?? [])
                    .filter { wanted.isEmpty || ($0.title ?? "").lowercased().contains(wanted)
                        || ($0.notes ?? "").lowercased().contains(wanted) || $0.calendar.title.lowercased().contains(wanted) }
                    .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                    .prefix(80)
                    .map { reminder -> String in
                        var line = "- \(reminder.isCompleted ? "[done] " : "")\(reminder.title ?? "Untitled")"
                        if let due = reminder.dueDateComponents?.date { line += " · due \(formatter.string(from: due))" }
                        line += " · \(reminder.calendar.title)"
                        if let notes = reminder.notes, !notes.isEmpty { line += " · \(notes.prefix(80))" }
                        return line
                    }
                continuation.resume(returning: Array(rows))
            }
        }
        guard !lines.isEmpty else { return wanted.isEmpty ? "No open reminders." : "No reminders about \"\(search)\"." }
        return "Reminders (\(lines.count)):\n" + lines.joined(separator: "\n")
    }

    // MARK: Any scriptable app

    /// An app's AppleScript dictionary, condensed: the things it has (with their properties and what they contain)
    /// and its commands. Nil-free: an app that can't be scripted says so, and to use its screen instead.
    static func scriptingDictionary(_ name: String) async -> String {
        guard let app = AppCatalog.shared.resolve(name) else { return "No app called \"\(name)\"." }
        let xml = await MacActions.run("/usr/bin/sdef", [app.url.path], timeout: 15)
        guard let document = try? XMLDocument(xmlString: xml, options: []), let root = document.rootElement(),
              root.name == "dictionary" else {
            return "\(app.name) can't be scripted (it has no AppleScript dictionary): open_app, then read_screen and click."
        }
        var lines = ["\(app.name)'s scripting terms (tell application \"\(app.name)\" to …):"]
        let basics: Set<String> = ["Standard Suite", "Text Suite", "Type Definitions", "Type Names Suite"]
        for suite in root.elements(forName: "suite") {
            let suiteName = suite.attribute(forName: "name")?.stringValue ?? ""
            if basics.contains(suiteName) { continue }
            for thing in suite.elements(forName: "class") + suite.elements(forName: "class-extension") {
                let name = thing.attribute(forName: "name")?.stringValue ?? thing.attribute(forName: "extends")?.stringValue ?? "?"
                let properties = thing.elements(forName: "property").compactMap { $0.attribute(forName: "name")?.stringValue }
                let contains = thing.elements(forName: "element").compactMap { $0.attribute(forName: "type")?.stringValue }
                var line = "- \(name)"
                if !properties.isEmpty { line += ": \(properties.joined(separator: ", "))" }
                if !contains.isEmpty { line += " (contains \(contains.joined(separator: ", ")))" }
                lines.append(line)
            }
            for command in suite.elements(forName: "command") {
                let name = command.attribute(forName: "name")?.stringValue ?? "?"
                let about = command.attribute(forName: "description")?.stringValue ?? ""
                lines.append("- command \(name)" + (about.isEmpty ? "" : ": \(about.prefix(90))"))
            }
        }
        return String(lines.joined(separator: "\n").prefix(7000))
    }

    // MARK: Helpers

    private static func noAccess(_ what: String) -> String {
        "Murmur isn't allowed to read \(what). The user can allow it in System Settings → Privacy & Security → \(what)."
    }

    /// "today", "tomorrow", "yesterday", a weekday ("monday": the next one), or 2026-10-20. Midnight that day.
    static func day(_ text: String) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let word = text.lowercased().trimmingCharacters(in: .whitespaces)
        switch word {
        case "", "today", "now": return today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today) ?? today
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today) ?? today
        default: break
        }
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let index = names.firstIndex(where: { word.hasPrefix($0) }) {
            let now = calendar.component(.weekday, from: today) - 1
            let ahead = (index - now + 7) % 7
            return calendar.date(byAdding: .day, value: ahead, to: today) ?? today
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: String(word.prefix(10))) { return calendar.startOfDay(for: date) }
        return today
    }

    private static func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: date)
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// A video call's address, from the event's link, location or notes.
    private static func meetingLink(_ event: EKEvent) -> String? {
        if let url = event.url?.absoluteString, url.hasPrefix("http") { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        guard let range = text.range(of: #"https://[^\s<>"]*(zoom\.us|meet\.google|teams\.microsoft|webex)[^\s<>"]*"#,
                                     options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
