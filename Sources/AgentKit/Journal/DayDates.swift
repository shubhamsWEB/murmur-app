import Foundation

/// The dates the "Your day" page is built around, kept apart from the stores so they can be tested.
public enum DayDates {
    /// The last day before `now` with work on it, looking back up to a week: Monday morning's overview shows Friday,
    /// not an empty Sunday. `hasWork` says whether a day (its start) had any.
    public static func lastWorkday(before now: Date, calendar: Calendar = .current,
                                   hasWork: (Date) -> Bool) -> Date? {
        let today = calendar.startOfDay(for: now)
        for back in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            if hasWork(day) { return day }
        }
        return nil
    }

    /// How a day is named on the page: "Today", "Yesterday", the weekday within the week ("Friday"), else the date
    /// ("Mon 3 Nov").
    public static func name(of day: Date, now: Date, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return start.formatted(.dateTime.weekday(.wide))
        default: return start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// A length of time as the page says it: "45 min", "2 h 5 min", "1 h".
    public static func length(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// When something's due, as the page says it: "overdue since Mon 9:00", "today 16:00", "tomorrow 10:00",
    /// "Thu 14:00", or a date further out.
    public static func due(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if date < now {
            return calendar.isDate(date, inSameDayAs: now) ? "was due \(time)"
                : "overdue since \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        return days < 7 ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Stretches of work split into sessions wherever nothing happened for `gap` (four hours): a night's work from
    /// 9 PM to 5 AM is one session, not two days. `spans` in time order; returns each session's index range.
    public static func sessions(_ spans: [(start: Date, end: Date)], gap: TimeInterval = 4 * 3600) -> [Range<Int>] {
        guard !spans.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var first = 0
        var latestEnd = spans[0].end
        for index in spans.indices.dropFirst() {
            if spans[index].start.timeIntervalSince(latestEnd) >= gap {
                ranges.append(first..<index)
                first = index
            }
            latestEnd = max(latestEnd, spans[index].end)
        }
        ranges.append(first..<spans.count)
        return ranges
    }

    /// What a session is called: the one still going (ended within four hours) is "Today so far" (or "Since 9:30 PM"
    /// when it began before today); an earlier one is "Last night" when it began in yesterday's evening or ran into
    /// today's early hours, "Earlier today", "Yesterday", or its weekday or date.
    public static func sessionName(start: Date, end: Date, now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        if now.timeIntervalSince(end) < 4 * 3600 {
            return start >= today ? "Today so far" : "Since \(start.formatted(.dateTime.hour().minute()))"
        }
        let evening = calendar.date(byAdding: .hour, value: -6, to: today) ?? today   // 18:00 yesterday
        let earlyHours = calendar.date(byAdding: .hour, value: 8, to: today) ?? today // 08:00 today
        if start >= evening && start < earlyHours { return "Last night" }
        if start >= today { return "Earlier today" }
        return name(of: start, now: now, calendar: calendar)
    }

    /// A session's hours: "9:33 PM – 5:29 AM".
    public static func span(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(.dateTime.hour().minute())) – \(end.formatted(.dateTime.hour().minute()))"
    }

    /// An outcome as a tag: "still open" → "Still open", "released" → "Released".
    public static func tag(_ outcome: String) -> String {
        let clean = outcome.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let first = clean.first else { return "" }
        return first.uppercased() + clean.dropFirst()
    }

    /// Whether an outcome says the thing got finished ("done", "released", "solved"), not that it's still going or
    /// didn't ("still open", "continued without resolution", "not sent").
    public static func isFinished(_ outcome: String) -> Bool {
        let words = Set(outcome.lowercased().split { !$0.isLetter }.map(String.init))
        guard words.isDisjoint(with: ["not", "without", "un", "unfinished", "unresolved", "still", "pending", "failed"])
        else { return false }
        return !words.isDisjoint(with: ["done", "released", "sent", "booked", "submitted", "finished", "merged",
                                        "deployed", "completed", "complete", "paid", "solved", "fixed", "shipped",
                                        "published", "resolved", "registered", "approved"])
    }

    /// Whether an outcome only says the thing is still going ("still open", "in progress"): nothing worth showing.
    public static func isStillGoing(_ outcome: String) -> Bool {
        let text = outcome.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.isEmpty || ["still open", "open", "in progress", "ongoing", "unfinished", "pending", "left open",
                                "not finished", "continuing"].contains(text)
    }
}
