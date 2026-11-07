import Foundation

/// What Murmur tells you without being asked, once each: a morning brief (what's due, what's coming up, where you left
/// off), an evening wrap-up (what you did, what's still open), and a reminder when something you promised is due
/// within the next few hours. Written by the screen-memory helper; shown by the app as notifications.
public enum Nudges {
    /// The facts a brief is made of, gathered without the model.
    public static func briefFacts(journal: Journal, brain: BrainStore, graph: MemoryGraph? = nil, now: Date = Date(),
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
        // Flights and bookings today, exactly as their pages had them.
        if let graph {
            let today = graph.upcoming(now: now).filter { ($0.item.when ?? .distantFuture) < endOfDay.addingTimeInterval(6 * 3600) }
            if !today.isEmpty { lines.append("Travel: " + today.map { $0.item.body.replacingOccurrences(of: "\n", with: ", ") }.joined(separator: "; ")) }
        }
        let yesterday = Journal.Level.day.period(of: now.addingTimeInterval(-86400), calendar: calendar)
        if let summary = journal.chronicle(.day, yesterday) { lines.append("Yesterday: \(Consolidator.clean(summary))") }
        // People: whose turn it is, who to follow up with, who you're waiting on (the most important first).
        if let graph {
            let open = graph.openThreads(now: now, limit: 8)
            func who(_ thread: MemoryThread) -> String { thread.person + (thread.organization.isEmpty ? "" : " (\(thread.organization))") }
            let turn = open.filter { $0.status == .yourTurn }.map { "\(who($0)): \($0.title)" }
            let nudge = open.filter { $0.status == .nudge }.map { "\(who($0)): \($0.title), no reply since \($0.lastAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" }
            let waiting = open.filter { $0.status == .waiting }.prefix(4).map { "\(who($0)): \($0.title)" }
            if !turn.isEmpty { lines.append("Your turn to reply: " + turn.joined(separator: "; ")) }
            if !nudge.isEmpty { lines.append("Follow up today: " + nudge.joined(separator: "; ")) }
            if !waiting.isEmpty { lines.append("Waiting on: " + waiting.joined(separator: "; ")) }
        }
        // Where you left off: the last real stretch of work before today.
        if let graph, let last = graph.episodes(from: calendar.startOfDay(for: now).addingTimeInterval(-3 * 86400),
                                                to: calendar.startOfDay(for: now))
            .filter({ $0.seconds >= 10 * 60 && !$0.title.isEmpty }).last {
            lines.append("Where you left off: \(last.title)" + (last.outcome.isEmpty ? "" : " (\(last.outcome))"))
        }
        return lines.joined(separator: "\n")
    }

    public static func wrapFacts(journal: Journal, graph: MemoryGraph? = nil, now: Date = Date(),
                                 calendar: Calendar = .current) -> String {
        var lines: [String] = []
        let today = Journal.Level.day.period(of: now, calendar: calendar)
        let start = calendar.startOfDay(for: now)
        // What you did, a stretch of work at a time (five minutes or more), else the hours' summaries.
        let worked = graph?.episodes(from: start, to: now).filter { $0.seconds >= 5 * 60 } ?? []
        if !worked.isEmpty {
            lines.append("What you did: " + worked.map { episode in
                episode.name + " (\(minutes(episode.seconds))" + (episode.outcome.isEmpty ? "" : ", \(episode.outcome)") + ")"
            }.joined(separator: "; "))
        } else {
            let hours = journal.chronicles(.hour, within: today)
            if !hours.isEmpty { lines.append("Your day: " + hours.map(\.summary).joined(separator: " ")) }
        }
        // Apps and sites used for a minute or more (a glance at Finder isn't "time").
        let time = journal.time(from: start, to: now).filter { $0.seconds >= 60 }.prefix(5)
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
    public static func make(journal: Journal, brain: BrainStore, graph: MemoryGraph? = nil, settings: ScreenMemorySettings,
                            model: String?, now: Date = Date(), calendar: Calendar = .current) async {
        let day = Journal.Level.day.period(of: now, calendar: calendar)
        // The brief from its time until the wrap-up's (or 17:00): a Mac first opened at noon still gets the day's,
        // and one opened at night doesn't get the morning's.
        let briefEnds = settings.wrap.isEmpty ? "17:00" : settings.wrap
        if !settings.brief.isEmpty, past(settings.brief, now: now, calendar: calendar),
           !past(briefEnds, now: now, calendar: calendar), !journal.nudged("brief:\(day)") {
            let facts = briefFacts(journal: journal, brain: brain, graph: graph, now: now, calendar: calendar)
            if !facts.isEmpty {
                let morning = calendar.component(.hour, from: now) < 12
                let body = await written(facts, "a brief for the day: what's due today, what's on, and where they left off yesterday",
                                         model: model)
                journal.nudge("brief:\(day)", kind: "brief", title: morning ? "Your morning" : "Your day", body: body, now: now)
                MemoryLog.write("wrote the brief for the day" + (model == nil ? " (from the facts, without the model)" : ""))
            } else {
                MemoryLog.write("no brief today: nothing due, nothing on, and no summary of yesterday yet")
                journal.nudge("brief:\(day)", kind: "none", title: "", body: "", now: now)
                journal.seen(nudge: "brief:\(day)", now: now)
            }
        }
        if !settings.wrap.isEmpty, past(settings.wrap, now: now, calendar: calendar), !journal.nudged("wrap:\(day)") {
            let facts = wrapFacts(journal: journal, graph: graph, now: now, calendar: calendar)
            if facts.isEmpty {
                MemoryLog.write("no wrap-up today: nothing from today to sum up")
            }
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
            plain, the most important first. Use only the facts given: say what's there, never what isn't ("you didn't \
            finish anything"), and never judge the day. Fewer facts, fewer sentences. No headings or lists.
            """
        let text = await Consolidator.chat(system, facts, schema: nil, model: model).map(Consolidator.clean) ?? ""
        return text.isEmpty ? facts : text
    }
}
