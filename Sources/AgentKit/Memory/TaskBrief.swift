import Foundation

/// What a command should know before it's planned, put together in code for every request and every model alike (a
/// small local model doesn't reliably look things up for itself: on 7 Nov it searched the web instead). Short and
/// chosen, not a history: the brief for this one task. In order:
///
/// 1. What was most likely misheard, corrected from memory (Grounding).
/// 2. Who and what it names, and how the user reaches them: "AI Builders x Blr: a WhatsApp group; you last wrote
///    there Sat 7 Nov 17:35".
/// 3. What the user did that it touches: things they sent, posted, released or tagged, newest first, before
///    anything merely seen.
///
/// The rest of what memory knows (facts, open loops, what was seen) follows from `Brain.context`. The user's words
/// this turn win over all of it, then the screen, then memory.
public enum TaskBrief {
    public static func make(_ grounding: Grounding.Result, graph: MemoryGraph, brain: BrainStore,
                            prefs: CommandMemory.Preferences, now: Date = Date(), calendar: Calendar = .current,
                            limit: Int = 1000) -> String? {
        var parts: [String] = []
        if let note = grounding.note { parts.append(note) }
        let text = grounding.text
        func when(_ date: Date) -> String { ScreenDates.formatter("EEE d MMM HH:mm", calendar).string(from: date) }
        // What the user put out, the latest first: the ground for "who", "where" and "what was it".
        let mine = graph.items([.message, .email, .post, .release], limit: 300).filter(\.item.mine)
            .sorted { ($0.item.when ?? $0.first) > ($1.item.when ?? $1.first) }

        // 2. Who and what it names.
        var named: [String] = []
        var names = brain.entities(namedIn: text, limit: 4).map(\.name)
        // Conversations the user has written in, named by the request ("the AI Builders group").
        let lower = " " + text.lowercased() + " "
        for stored in mine where [.message, .email].contains(stored.item.kind) {
            for person in stored.item.people where person.count >= 3 && lower.contains(" " + person.lowercased() + " ")
                && !names.contains(person) {
                names.append(person)
            }
        }
        for name in names.prefix(5) {
            var line = "- \(name)"
            if let app = prefs.chatApp(for: name) { line += ": you message them on \(app)" }
            if let last = mine.first(where: { $0.item.people.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }) {
                let app = last.item.fields["app"] ?? last.item.kind.rawValue
                line += (line.contains(":") ? "; " : ": ") + "you last wrote to them on \(app), \(when(last.item.when ?? last.first))"
                line += ": \"\(last.item.title.prefix(70))\""
            }
            named.append(line)
        }
        if !named.isEmpty { parts.append("Who and what this names:\n" + named.joined(separator: "\n")) }

        // 3. What the user did that it touches: items whose words match, the user's own, newest first.
        let words = Set(BrainModel.keywords(text).filter { $0.count >= 3 })
        let touched = mine.filter { stored in
            let said = Set(BrainModel.keywords(stored.item.title + " " + stored.item.project + " " + stored.item.people.joined(separator: " ")))
            return !said.isDisjoint(with: words)
        }.prefix(5)
        if !touched.isEmpty {
            parts.append("What the user did that this touches (newest first):\n" + touched.map { stored -> String in
                let verb: String
                switch stored.item.kind {
                case .post: verb = "posted on \(stored.item.fields["platform"] ?? "a feed")"
                case .release: verb = stored.item.fields["status"] == "tagged" || stored.item.fields["source"] == "terminal" ? "tagged" : "released"
                case .email: verb = "emailed" + (stored.item.people.isEmpty ? "" : " \(stored.item.people.joined(separator: ", "))")
                default: verb = "sent" + (stored.item.people.isEmpty ? "" : " to \(stored.item.people.joined(separator: ", "))")
                    + (stored.item.fields["app"].map { " on \($0)" } ?? "")
                }
                return "- \(when(stored.item.when ?? stored.first)): you \(verb): \(stored.item.title.prefix(90))"
            }.joined(separator: "\n"))
        }
        guard !parts.isEmpty else { return nil }
        var brief = ""
        for part in parts where brief.count + part.count <= limit {
            brief += (brief.isEmpty ? "" : "\n") + part
        }
        return brief.isEmpty ? nil : brief
    }
}
