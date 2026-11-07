import Foundation

/// `murmur-memory report` and `murmur-memory ask "…"`, from Terminal: what screen memory has made of what you did, and
/// what it answers to a question, to check it against what really happened. Brings items and episodes up to date
/// first (by rules, the same as the helper does every few minutes); never runs the model, never sends anything.
public enum MemoryReport {
    public static func run(_ arguments: [String], brain: BrainStore = BrainStore(), journal: Journal = Journal(),
                           now: Date = Date()) -> Never {
        let graph = MemoryGraph(url: journal.url)
        let command = arguments.first ?? "report"
        graph.readItems(from: journal, me: brain.meNames(), now: now)
        graph.segment(now: now)
        switch command {
        case "ask":
            let question = arguments.dropFirst().joined(separator: " ")
            guard !question.isEmpty else { print("Usage: murmur-memory ask \"when is my flight?\""); exit(1) }
            print(MemoryServer(brain: brain, journal: journal).call("search_memory", ["query": question]))
        default:
            print(report(brain: brain, journal: journal, graph: graph, now: now))
        }
        exit(0)
    }

    public static func report(brain: BrainStore, journal: Journal, graph: MemoryGraph, now: Date = Date(),
                              calendar: Calendar = .current) -> String {
        var out: [String] = []
        let counts = graph.counts()
        let me = brain.meNames()
        out.append("Screen memory, \(ScreenDates.spoken(now, calendar: calendar))")
        out.append("You are: " + (me.isEmpty ? "(not known yet: add your own card in Contacts, or tell Murmur your name)" : me.joined(separator: ", ")))
        out.append("\(journal.counts().snapshots) windows kept, \(counts.sightings) stays in them, \(counts.items) things read from "
                   + "them, \(counts.episodes) episodes (\(counts.unread) still to read), \(counts.edges) connections")
        func section(_ title: String, _ lines: [String]) {
            out.append("")
            out.append(title)
            out += lines.isEmpty ? ["  (none)"] : lines.map { "  " + $0 }
        }
        section("Coming up (exact, from the windows):", graph.upcoming(now: now).map { $0.item.body.replacingOccurrences(of: "\n", with: "; ") })
        let releases = graph.items([.release], limit: 10)
        section("Releases:", releases.map { ($0.item.mine ? "yours: " : "") + $0.item.body.components(separatedBy: "\nNotes:").first!
            .replacingOccurrences(of: "\n", with: "; ") })
        section("Open promises and plans:", journal.loops(limit: 15).map { "\($0.label): \(Nudges.describe($0, now: now))" })
        section("Latest episodes (what you did):", graph.recentEpisodes(limit: 20).map {
            MemoryRecall.line($0, calendar: calendar).dropFirst(2) + ($0.read ? "" : " (not read yet)")
        })
        var projects: [String] = []
        for entity in brain.entities(kind: .project, limit: 12) {
            projects += MemoryRecall.connections(of: entity.id, name: entity.name, graph: graph, calendar: calendar).prefix(1)
        }
        section("Projects and how they connect:", projects.map { String($0.dropFirst(2)) })
        section("Memories from the screen (newest):", brain.fromScreen(limit: 15).map { "\($0.about): \($0.memory.text)" })
        return out.joined(separator: "\n")
    }
}
