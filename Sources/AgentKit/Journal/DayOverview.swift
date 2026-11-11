import Foundation

/// Everything behind the morning brief and the evening wrap-up, in full, for the "Your day" page: the notification is
/// the short version; clicking it opens this. Built from the same stores the brief is written from (the journal's open
/// loops, the memory graph's stretches of work, threads and bookings, the brain's upcoming memories), with no model,
/// so it's there at once and says only what's recorded.
///
/// Laid out to be read top to bottom: what needs you, what's on today, where you left off, what you worked on (by
/// session, so a night's work isn't split at midnight), what's coming, and what's still open. Each line is one thing,
/// with one line of context and a tag saying where it stands.
public struct DayOverview: Sendable {
    /// How a tag reads: something late or owed (`urgent`), something finished (`done`), or plain.
    public enum Tone: Sendable { case plain, urgent, done }

    /// One thing on the page: what it is, one line of context, and where it stands.
    public struct Line: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var context: String
        public var tag: String
        public var tone: Tone
        /// A sentence more, shown under it (only where you left off).
        public var more: String

        public init(id: String, title: String, context: String = "", tag: String = "", tone: Tone = .plain, more: String = "") {
            self.id = id
            self.title = title
            self.context = context
            self.tag = tag
            self.tone = tone
            self.more = more
        }
    }

    /// One session of work (stretches with no four-hour break between them).
    public struct Session: Sendable, Identifiable {
        public var id: String { name + hours }
        public var name: String       // "Last night", "Today so far", "Yesterday"
        public var hours: String      // "9:33 PM – 5:29 AM"
        public var total: Double      // seconds of work in it
        public var stretches: [Line]  // ten minutes or more, in time order
        public var shorter: Int       // how many shorter ones
        public var shorterSeconds: Double
        public var finished: [Line]
    }

    /// The brief or wrap-up as it was sent today (the paragraph), oldest first.
    public var notes: [(title: String, body: String, created: Date)]
    public var needsYou: [Line]
    public var today: [Line]
    /// Reminders and to-dos from memory, each saying its own date ("Clean up my room (due Sun, 8 Nov)"): when they
    /// lapse isn't when they're due, so they aren't put on a day.
    public var reminders: [Line]
    public var leftOff: Line?
    public var sessions: [Session]
    public var comingUp: [Line]
    public var waitingOn: [Line]
    public var openPromises: [Line]

    public var isEmpty: Bool {
        notes.isEmpty && needsYou.isEmpty && today.isEmpty && reminders.isEmpty && leftOff == nil && sessions.isEmpty
            && comingUp.isEmpty && waitingOn.isEmpty && openPromises.isEmpty
    }

    public static func build(journal: Journal, brain: BrainStore, graph: MemoryGraph, now: Date = Date(),
                             calendar: Calendar = .current) -> DayOverview {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(86400)
        let weekAhead = endOfToday.addingTimeInterval(6 * 86400)

        let notes = journal.latestNudges(limit: 12)
            .filter { ($0.kind == "brief" || $0.kind == "wrap") && $0.created >= startOfToday }
            .reversed()
            .map { (title: $0.title, body: $0.body, created: $0.created) }

        // A promise or plan: what it is, who it's with, and when it's due.
        func line(_ loop: Journal.Loop) -> Line {
            let context = [loop.person, loop.project].filter { !$0.isEmpty }.joined(separator: " · ")
            var tag = loop.label
            var tone = Tone.plain
            if let due = loop.due {
                tag = DayDates.tag(DayDates.due(due, now: now, calendar: calendar))
                if due < now { tone = .urgent }
            }
            return Line(id: "loop:\(loop.id)", title: loop.summary, context: context, tag: tag, tone: tone)
        }
        // A conversation: who with, and where it stands.
        func thread(_ thread: MemoryThread, tag: String, tone: Tone) -> Line {
            var who = thread.person + (thread.organization.isEmpty || thread.person.contains(thread.organization)
                                       ? "" : " (\(thread.organization))")
            // "Chat with Mayur(Ford)" already says who.
            if let first = thread.person.split(whereSeparator: { !$0.isLetter }).first,
               thread.title.lowercased().contains(first.lowercased()) { who = "" }
            return Line(id: "thread:\(thread.id)", title: thread.title,
                        context: [who, thread.channel].filter { !$0.isEmpty }.joined(separator: " · "),
                        tag: tag, tone: tone)
        }
        func since(_ date: Date) -> String {
            let name = DayDates.name(of: date, now: now, calendar: calendar)
            switch name {
            case "Today": return "today"
            case "Yesterday": return "yesterday"
            default: return name
            }
        }

        // Needs you: overdue and due today, then whose turn it is, then who to chase.
        let open = journal.loops(limit: 60)
        let due = open.filter { ($0.due ?? .distantFuture) < endOfToday }
        let threads = graph.openThreads(now: now, limit: 20)
        let needsYou = due.map(line)
            + threads.filter { $0.status == .yourTurn }.map { thread($0, tag: "Your turn", tone: .urgent) }
            + threads.filter { $0.status == .nudge }.map {
                thread($0, tag: "No reply since \(since($0.lastAt))", tone: .plain)
            }

        // Today: events and bookings. Coming up: the rest of the week, promises included.
        var today: [Line] = []
        var comingUp: [Line] = open.filter {
            guard let due = $0.due else { return false }
            return due >= endOfToday && due < weekAhead
        }.map(line)
        let reminders = brain.upcoming(limit: 20, now: now).map { hit in
            Line(id: "memory:\(hit.memory.id)", title: hit.memory.text,
                 context: ["you", "me", "user"].contains(hit.about.lowercased()) ? "" : hit.about)
        }
        for booking in graph.upcoming(now: now, limit: 12) {
            guard let when = booking.item.when else { continue }
            let lines = booking.item.body.components(separatedBy: "\n").filter { !$0.isEmpty }
            let title = booking.item.title.isEmpty ? lines.first ?? "" : booking.item.title
            let entry = Line(id: "item:\(booking.id)", title: title,
                             context: lines.filter { $0 != title }.prefix(2).joined(separator: " · "),
                             tag: DayDates.tag(DayDates.due(when, now: now, calendar: calendar)))
            if when < endOfToday.addingTimeInterval(6 * 3600) { today.append(entry) }
            else if when < weekAhead { comingUp.append(entry) }
        }

        // Work, by session: the one going now, and the one before it.
        let episodes = graph.episodes(from: startOfToday.addingTimeInterval(-7 * 86400), to: now)
            .filter { $0.seconds >= 5 * 60 }
            .sorted { $0.start < $1.start }
        let ranges = DayDates.sessions(episodes.map { (start: $0.start, end: $0.end) })
        let done = journal.loops(status: "done", limit: 60)
        // What a stretch came to: a green tag when it got finished, nothing when it's only still going, else the
        // outcome as a line of its own (a sentence isn't a tag).
        func stretch(_ episode: MemoryGraph.StoredEpisode) -> Line {
            let outcome = episode.outcome
            let finished = DayDates.isFinished(outcome)
            let words = outcome.split(separator: " ").count
            return Line(id: "episode:\(episode.id)", title: episode.name,
                        context: DayDates.span(episode.start, episode.end) + " · " + DayDates.length(episode.seconds),
                        tag: finished ? (words <= 2 ? DayDates.tag(outcome) : "Done") : "",
                        tone: finished ? .done : .plain,
                        more: (finished && words <= 2) || DayDates.isStillGoing(outcome) ? "" : DayDates.tag(outcome))
        }
        func session(_ range: Range<Int>) -> Session? {
            let part = Array(episodes[range])
            guard let first = part.first, let last = part.max(by: { $0.end < $1.end }) else { return nil }
            let long = part.filter { $0.seconds >= 10 * 60 }
            let short = part.filter { $0.seconds < 10 * 60 }
            let stretches = long.map(stretch)
            let finished = done.filter { $0.last >= first.start && $0.last <= last.end.addingTimeInterval(3600) }
                .map { Line(id: "done:\($0.id)", title: $0.summary, context: $0.person, tag: "Done", tone: .done) }
            return Session(name: DayDates.sessionName(start: first.start, end: last.end, now: now, calendar: calendar),
                           hours: DayDates.span(first.start, last.end),
                           total: part.reduce(0) { $0 + $1.seconds },
                           stretches: stretches, shorter: short.count,
                           shorterSeconds: short.reduce(0) { $0 + $1.seconds }, finished: finished)
        }
        // The session going now (if any), and the last one before it: older ones are on the Memory page.
        var sessions: [Session] = []
        if let latest = ranges.last, let made = session(latest) {
            sessions.append(made)
            if made.name == "Today so far" || made.name.hasPrefix("Since"),
               ranges.count > 1, let before = session(ranges[ranges.count - 2]) {
                sessions.append(before)
            }
        }

        // Where you left off: the last real stretch (ten minutes or more), with what it came to.
        let leftOff = episodes.filter { $0.seconds >= 10 * 60 }.max(by: { $0.end < $1.end }).map { episode in
            Line(id: "left:\(episode.id)", title: episode.name,
                 context: DayDates.name(of: episode.end, now: now, calendar: calendar) + " at "
                    + episode.end.formatted(.dateTime.hour().minute()),
                 tag: DayDates.isFinished(episode.outcome) ? "Done" : "", tone: .done, more: episode.summary)
        }

        // Waiting on others: conversations they owe you, and what they promised.
        let listed = Set(due.map { "loop:\($0.id)" } + comingUp.map(\.id))
        let rest = open.filter { !listed.contains("loop:\($0.id)") }
        let waitingOn = threads.filter { $0.status == .waiting }.prefix(10).map {
            thread($0, tag: "Since \(since($0.lastAt))", tone: .plain)
        } + rest.filter { !$0.mine }.map(line)

        return DayOverview(notes: Array(notes), needsYou: needsYou, today: today, reminders: reminders, leftOff: leftOff,
                           sessions: sessions, comingUp: comingUp, waitingOn: Array(waitingOn),
                           openPromises: rest.filter(\.mine).map(line))
    }
}
