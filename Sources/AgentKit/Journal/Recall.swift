import Foundation

/// What screen memory adds to a command and to "what do you know…": open loops when it's about promises or what's
/// pending, the chronicle and the time ledger when it's about what you did, and the windows you saw that match.
public enum Recall {
    static func says(_ text: String, _ words: [String]) -> Bool {
        let lower = " " + text.lowercased() + " "
        return words.contains { lower.contains($0) }
    }

    static let aboutLoops = ["promise", "promised", "owe", "follow up", "follow-up", "pending", "waiting on", "to do", "todo",
                             "due", "deadline", "commit", "said i'd", "said i would", "open loops", "get back to"]
    static let aboutPast = ["what did i", "did i ", "worked on", "yesterday", "last week", "this week", "earlier today",
                            "today", "time spent", "how long", "where did my time", "last month", "on monday", "on tuesday",
                            "on wednesday", "on thursday", "on friday", "this morning", "this afternoon", "recap", "summary of my"]
    static let aboutSeen = ["i saw", "i read", "i was looking", "that page", "that doc", "that tab", "that email", "that message",
                            "on my screen", "was open", "i opened"]

    /// Lines for a command's context (empty when the command isn't about any of it).
    public static func context(_ journal: Journal, for utterance: String, now: Date = Date(),
                               calendar: Calendar = .current) -> [String] {
        var lines: [String] = []
        if says(utterance, aboutLoops) {
            for loop in journal.loops(limit: 8) {
                lines.append("- Open loop (\(loop.label.lowercased())): \(Nudges.describe(loop, now: now))"
                             + (loop.person.isEmpty ? "" : ", with \(loop.person)"))
            }
        }
        if says(utterance, aboutPast) {
            let today = Journal.Level.day.period(of: now, calendar: calendar)
            let yesterday = Journal.Level.day.period(of: now.addingTimeInterval(-86400), calendar: calendar)
            if let day = journal.chronicle(.day, yesterday) { lines.append("- Yesterday (\(yesterday)): \(day)") }
            for hour in journal.chronicles(.hour, within: today).suffix(6) {
                lines.append("- Today \(hour.period.suffix(2)):00: \(hour.summary)")
            }
            lines += journal.searchChronicle(utterance, limit: 3).map { "- \($0.period): \($0.summary)" }
            let time = journal.time(from: calendar.startOfDay(for: now), to: now).prefix(5)
            if !time.isEmpty {
                lines.append("- Time today: " + time.map { "\($0.name) \(Nudges.minutes($0.seconds))" }.joined(separator: ", "))
            }
        }
        if says(utterance, aboutSeen) {
            lines += journal.search(utterance, limit: 3).map(seen)
        }
        var unique: [String] = []
        for line in lines where !unique.contains(line) { unique.append(line) }
        return unique
    }

    /// Lines for "what do you know about…": promises, chronicle and windows that match.
    public static func answer(_ journal: Journal, for query: String, now: Date = Date()) -> [String] {
        let words = BrainModel.keywords(query)
        var lines: [String] = []
        for loop in journal.loops(limit: 60) where BrainModel.similarity(words, BrainModel.keywords(loop.summary + " " + loop.person)) > 0.15
            || words.contains(where: { loop.person.lowercased().contains($0) }) {
            lines.append("- \(loop.label): \(Nudges.describe(loop, now: now)) [open loop, seen on screen]")
        }
        lines += journal.searchChronicle(query, limit: 4).map { "- \($0.period): \($0.summary) [your \($0.level) summary]" }
        lines += journal.search(query, limit: 4).map(seen)
        return lines
    }

    static func seen(_ snapshot: Journal.Snapshot) -> String {
        let place = snapshot.domain.isEmpty ? snapshot.app : "\(snapshot.app), \(snapshot.url ?? snapshot.domain)"
        let text = snapshot.text.replacingOccurrences(of: "\n", with: " ").prefix(220)
        return "- Seen \(snapshot.first.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())) "
            + "in \(place), \"\(snapshot.title)\": \(text)"
    }
}
