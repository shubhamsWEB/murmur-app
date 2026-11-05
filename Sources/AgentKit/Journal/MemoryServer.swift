import Foundation

/// Murmur's memory as an MCP server (stdio), for Claude Code, Claude Desktop, Cursor and other assistants:
/// `Murmur.app/Contents/Helpers/murmur-memory mcp`. Read-only: it answers from what Murmur knows (people, projects,
/// facts), what you promised, what you did and what you saw; it never changes anything. Nothing goes anywhere but to
/// the assistant that asked, on this Mac.
public final class MemoryServer {
    let brain: BrainStore
    let journal: Journal

    public init(brain: BrainStore = BrainStore(), journal: Journal = Journal()) {
        self.brain = brain
        self.journal = journal
    }

    static let tools: [[String: Any]] = [
        tool("search_memory", "Search what Murmur knows about the user's world: people (who they are, their work, how to "
             + "reach them), organizations, projects, facts and preferences, from their Contacts, Calendar, Reminders, "
             + "Notes, Mail, connected apps and screen. Each result says where it came from.",
             ["query": ["type": "string", "description": "a name, project, topic or question"]], required: ["query"]),
        tool("get_open_loops", "What the user promised to do, and what others promised them, still open, soonest due first.",
             [:]),
        tool("get_chronicle", "What the user worked on: a summary for an hour, a day, a month or a year.",
             ["period": ["type": "string", "description": "2026-11-05 (a day), 2026-11-05T14 (an hour), 2026-11 (a month), 2026 (a year); empty for today"]]),
        tool("get_time_report", "Where the user's time went (apps and sites) between two days.",
             ["from": ["type": "string", "description": "YYYY-MM-DD, default today"],
              "to": ["type": "string", "description": "YYYY-MM-DD, default today"]]),
        tool("search_screen", "Find windows the user had open: pages, documents, chats and email they saw, by their words.",
             ["query": ["type": "string", "description": "words from what they saw"]], required: ["query"]),
        tool("get_upcoming", "What's coming up for the user: events and things to do, soonest first.", [:]),
    ]

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "annotations": ["readOnlyHint": true],
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    /// Answers JSON-RPC lines on stdin until it closes.
    public func serve() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let reply = handle(message), let out = try? JSONSerialization.data(withJSONObject: reply) {
                FileHandle.standardOutput.write(out + Data("\n".utf8))
            }
        }
        exit(0)
    }

    /// One message's reply; nil for a notification.
    public func handle(_ message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch method {
        case "initialize":
            return result(["protocolVersion": params["protocolVersion"] as? String ?? MCPClient.protocolVersion,
                           "capabilities": ["tools": [:] as [String: Any]],
                           "serverInfo": ["name": "murmur-memory", "version": "1"],
                           "instructions": "The user's personal memory, kept by Murmur on their Mac. Search it before "
                               + "asking the user who someone is, what they're working on or what they promised."])
        case "ping": return result([:])
        case "tools/list": return result(["tools": Self.tools])
        case "tools/call":
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let text = call(params["name"] as? String ?? "", arguments)
            return result(["content": [["type": "text", "text": text]], "isError": false])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
    }

    func call(_ name: String, _ arguments: [String: Any]) -> String {
        func text(_ key: String) -> String { (arguments[key] as? String ?? "").trimmingCharacters(in: .whitespaces) }
        let now = Date()
        switch name {
        case "search_memory":
            let vector = LocalReader.embedderInstalled ? LocalReader.embedNow([text("query")], query: true)?.first : nil
            let hits = MemorySearch(store: brain, journal: journal, vectors: MemoryVectors()).memories(text("query"), vector: vector, limit: 20)
            let lines = hits.map { "- \($0.memory.text) [about \($0.about); from \($0.memory.origin.display)]" }
                + Recall.answer(journal, for: text("query"), now: now)
            return lines.isEmpty ? "Nothing known about \"\(text("query"))\"." : lines.joined(separator: "\n")
        case "get_open_loops":
            let loops = journal.loops(limit: 40)
            return loops.isEmpty ? "No open loops." : loops.map {
                "- \($0.label.replacingOccurrences(of: "you", with: "the user")): \(Nudges.describe($0, now: now))"
                    + ($0.person.isEmpty ? "" : " (with \($0.person))")
            }.joined(separator: "\n")
        case "get_chronicle":
            var period = text("period")
            if period.isEmpty { period = Journal.Level.day.period(of: now) }
            let level: Journal.Level = period.count == 4 ? .year : period.count == 7 ? .month : period.contains("T") ? .hour : .day
            var lines: [String] = []
            if let summary = journal.chronicle(level, period) { lines.append("\(period): \(summary)") }
            if let below = level.below {
                lines += journal.chronicles(below, within: period).map { "\($0.period): \($0.summary)" }
            }
            return lines.isEmpty ? "Nothing recorded for \(period)." : lines.joined(separator: "\n")
        case "get_time_report":
            let days = DateFormatter()
            days.dateFormat = "yyyy-MM-dd"
            let from = days.date(from: text("from")) ?? Calendar.current.startOfDay(for: now)
            let to = (days.date(from: text("to")) ?? from).addingTimeInterval(86400)
            let spent = journal.time(from: from, to: to)
            return spent.isEmpty ? "No time recorded." : spent.map { "- \($0.name): \(Nudges.minutes($0.seconds))" }.joined(separator: "\n")
        case "search_screen":
            let seen = journal.search(text("query"), limit: 8)
            return seen.isEmpty ? "Nothing seen matching \"\(text("query"))\"." : seen.map(Recall.seen).joined(separator: "\n")
        case "get_upcoming":
            let coming = brain.upcoming(limit: 15, now: now)
            return coming.isEmpty ? "Nothing coming up." : coming.map { "- \($0.memory.text)" }.joined(separator: "\n")
        default:
            return "Unknown tool \(name)."
        }
    }
}
