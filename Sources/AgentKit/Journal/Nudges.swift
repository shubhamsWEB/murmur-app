import Foundation

/// What Murmur tells you without being asked, once each: a morning brief (what's due, what's coming up, where you left
/// off), an evening wrap-up (what you did, what's still open), and a reminder when something you promised is due
/// within the next few hours. Written by the screen-memory helper; shown by the app as notifications.
public enum Nudges {
    /// The facts a brief is made of, gathered without the model.
    public static func briefFacts(journal: Journal, brain: BrainStore, now: Date = Date(),
                                  calendar: Calendar = .current) -> String {
        var lines: [String] = []
        let endOfDay = calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(86400)
        let loops = journal.loops(limit: 40)
        let due = loops.filter { ($0.due ?? .distantFuture) < endOfDay }
        if !due.isEmpty {
            lines.append("Due today or overdue: " + due.map { describe($0, now: now) }.joined(separator: "; "))
        }
        let waiting = loops.filter { !$0.mine && $0.due == nil }.prefix(5)
        if !waiting.isEmpty { lines.append("Waiting on others: " + waiting.map(\.summary).joined(separator: "; ")) }
        let coming = brain.upcoming(limit: 12, now: now).filter { ($0.memory.expires ?? .distantFuture) < endOfDay.addingTimeInterval(3600) }
        if !coming.isEmpty { lines.append("Today: " + coming.map(\.memory.text).joined(separator: "; ")) }
        let yesterday = Journal.Level.day.period(of: now.addingTimeInterval(-86400), calendar: calendar)
        if let summary = journal.chronicle(.day, yesterday) { lines.append("Yesterday: \(summary)") }
        return lines.joined(separator: "\n")
    }

    public static func wrapFacts(journal: Journal, now: Date = Date(), calendar: Calendar = .current) -> String {
        var lines: [String] = []
        let today = Journal.Level.day.period(of: now, calendar: calendar)
        let hours = journal.chronicles(.hour, within: today)
        if !hours.isEmpty { lines.append("Your day: " + hours.map(\.summary).joined(separator: " ")) }
        let start = calendar.startOfDay(for: now)
        let time = journal.time(from: start, to: now).prefix(5)
        if !time.isEmpty {
            lines.append("Time: " + time.map { "\($0.name) \(minutes($0.seconds))" }.joined(separator: ", "))
        }
        let done = journal.loops(status: "done", limit: 40).filter { $0.last >= start }
        if !done.isEmpty { lines.append("Done: " + done.map(\.summary).joined(separator: "; ")) }
        let open = journal.loops(limit: 40).filter(\.mine).prefix(6)
        if !open.isEmpty { lines.append("Still open: " + open.map { describe($0, now: now) }.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    static func describe(_ loop: Journal.Loop, now: Date) -> String {
        guard let due = loop.due else { return loop.summary }
        if loop.kind == "plan" { return "\(loop.summary), \(due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))" }
        return "\(loop.summary) (\(due < now ? "was due" : "due") \(due.formatted(.dateTime.weekday(.abbreviated).hour().minute())))"
    }

    static func minutes(_ seconds: Double) -> String {
        let total = Int(seconds / 60)
        return total >= 60 ? "\(total / 60) h \(total % 60) min" : "\(total) min"
    }

    /// Whether a "HH:mm" time has come today.
    static func past(_ time: String, now: Date, calendar: Calendar) -> Bool {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return minutes >= parts[0] * 60 + parts[1]
    }

    /// Makes whichever nudges are due now. Without a model the brief is the facts themselves.
    public static func make(journal: Journal, brain: BrainStore, settings: ScreenMemorySettings, model: String?,
                            now: Date = Date(), calendar: Calendar = .current) async {
        let day = Journal.Level.day.period(of: now, calendar: calendar)
        // A brief only within three hours of its time: a Mac opened at night doesn't get the morning's.
        if !settings.brief.isEmpty, past(settings.brief, now: now, calendar: calendar),
           !past(shifted(settings.brief, hours: 3), now: now, calendar: calendar), !journal.nudged("brief:\(day)") {
            let facts = briefFacts(journal: journal, brain: brain, now: now, calendar: calendar)
            if !facts.isEmpty {
                let body = await written(facts, "a morning brief: what's due today, what's on, and where they left off yesterday",
                                         model: model)
                journal.nudge("brief:\(day)", kind: "brief", title: "Your morning", body: body, now: now)
                MemoryLog.write("wrote the morning brief")
            }
        }
        if !settings.wrap.isEmpty, past(settings.wrap, now: now, calendar: calendar), !journal.nudged("wrap:\(day)") {
            let facts = wrapFacts(journal: journal, now: now, calendar: calendar)
            if !facts.isEmpty {
                let body = await written(facts, "an evening wrap-up: what they did today and what's still open for tomorrow",
                                         model: model)
                journal.nudge("wrap:\(day)", kind: "wrap", title: "Your day", body: body, now: now)
                MemoryLog.write("wrote the evening wrap-up")
            }
        }
        // Something you promised, due within three hours: once. A plan (a flight, an appointment) also the day before,
        // in the evening, so there's time to get ready.
        for loop in journal.loops(limit: 40) where loop.mine {
            guard let due = loop.due, due > now else { continue }
            if due < now.addingTimeInterval(3 * 3600), !journal.nudged("due:\(loop.id)") {
                journal.nudge("due:\(loop.id)", kind: "due", title: loop.kind == "plan" ? "Coming up" : "Due soon",
                              body: describe(loop, now: now), now: now)
            }
            if loop.kind == "plan", calendar.isDate(due, inSameDayAs: now.addingTimeInterval(86400)),
               calendar.component(.hour, from: now) >= 18, !journal.nudged("eve:\(loop.id)") {
                journal.nudge("eve:\(loop.id)", kind: "due", title: "Tomorrow", body: describe(loop, now: now), now: now)
            }
        }
    }

    static func shifted(_ time: String, hours: Int) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return time }
        return String(format: "%02d:%02d", min(23, parts[0] + hours), parts[1])
    }

    /// The facts, written as a short note to the user by the local model (or the facts as they are).
    static func written(_ facts: String, _ what: String, model: String?) async -> String {
        guard let model else { return facts }
        let system = """
            Write \(what), for the user, from these facts. Three to five short sentences in the second person, warm and \
            plain, the most important first. Use only the facts given. No headings or lists.
            """
        let text = await Consolidator.chat(system, facts, schema: nil, model: model).map(Consolidator.clean) ?? ""
        return text.isEmpty ? facts : text
    }
}
