import Foundation

/// Murmur's memory for other assistants (Claude Code, Claude Desktop, Cursor, Codex and the rest), read-only, as tools
/// that follow its layers: what the user did in the last minutes and hours, summaries of hours to years, the wiki of
/// people and projects, the profile and digest, promises, time, and search across everything, with every result saying
/// where it came from so the original window can be opened before anything is quoted.
///
/// Two ways in, the same tools: an MCP server on standard input and output (`Murmur.app/Contents/Helpers/murmur-memory
/// mcp`, which Murmur adds to the assistants it finds: `MCPRegistration`), and the local API of the screen-memory
/// helper (`MemoryAPI`), for an assistant that runs commands instead. Nothing goes anywhere but to the assistant that
/// asked, on this Mac.
public final class MemoryServer {
    let brain: BrainStore
    let journal: Journal
    let graph: MemoryGraph
    /// The one index over this memory, and its vectors (the same file as the journal).
    let index: MemoryIndex
    let vectors: MemoryVectors
    let wiki: Wiki
    let profile: Profile

    public init(brain: BrainStore = BrainStore(), journal: Journal = Journal()) {
        self.brain = brain
        self.journal = journal
        graph = MemoryGraph(url: journal.url)
        index = MemoryIndex(url: journal.url)
        vectors = MemoryVectors(url: journal.url)
        wiki = Wiki(url: journal.url)
        profile = Profile(url: journal.url)
    }

    /// How to use the tools, for the assistant (MCP's instructions, and the skill Murmur installs).
    public static let instructions = """
        The user's personal memory, kept by Murmur on their Mac: what they did, saw, wrote and promised, and what Murmur \
        knows about the people and projects in their life. Search it before asking the user who someone is, what they \
        are working on, what they decided or what they owe.

        Which tool:
        - "this", "that", or nothing named: get_recent_activity (the last 30 minutes) first.
        - The last few hours, in full: get_working_memory.
        - A day, a week, a month ("what did I do last Tuesday"): get_chronicle with that period.
        - A person, project, organization or topic ("who is Priya", "where is the launch"): get_wiki_page, then follow \
        the [[links]] on it.
        - A word, a name, a file, a site, or anything else: search_memory.
        - What they owe or were promised, and whether it was done: get_promises.
        - Who the user is and what's going on for them: get_profile.
        - Time spent: get_time_report (screen time, not a timesheet).

        Summaries, pages and search results are an index, not the evidence: a search result is cut short, and a chat \
        or an email shows mostly its sidebar there. Before quoting exact words, a number, a time or what a message \
        said, open the result's source with open_records ("snapshot:744"). If a search finds nothing, try other words \
        (a full name, a channel, a synonym) before saying it isn't there. Say only what memory holds; if it doesn't \
        hold the answer, say so. Don't show the user source ids unless they ask.
        """

    static let tools: [[String: Any]] = [
        tool("search_memory", "Search everything Murmur remembers about the user's world: what they did, sent and released, "
             + "people, projects and facts (from Contacts, Calendar, Notes, Mail and the screen), summaries of their time, "
             + "promises, the wiki, and windows they saw. Each result says what it is, when, and its source id.",
             ["query": ["type": "string", "description": "a name, project, topic or question"]], required: ["query"]),
        tool("get_recent_activity", "What the user did in the last minutes: each window they were in, oldest first, with its source id.",
             ["minutes": ["type": "integer", "description": "how far back, default 30"]]),
        tool("get_working_memory", "The windows of the last few hours with their full text, newest first.",
             ["hours": ["type": "integer", "description": "how far back, default 3"]]),
        tool("open_records", "The full text of results by their source ids (snapshot:744, episode:84, page:12, memory:3, "
             + "chronicle:5, item:40, thread:7, loop:9): read these before quoting.",
             ["ids": ["type": "string", "description": "source ids, separated by commas"]], required: ["ids"]),
        tool("get_chronicle", "What the user worked on in a period: its summary, and the summaries it's made of.",
             ["period": ["type": "string", "description": "2026-11-05 (a day), 2026-11-05T14 (an hour), 2026-W45 (a week), 2026-11 (a month), 2026 (a year), or today, yesterday, this week, last week, this month; default today"]]),
        tool("get_wiki_page", "Murmur's page about a person, project, organization, place or topic: a summary and claims, "
             + "each saying how it's known and its sources, and what an earlier version said.",
             ["name": ["type": "string", "description": "who or what; \"me\" for the user's own page"]], required: ["name"]),
        tool("search_wiki", "Find wiki pages by words.", ["query": ["type": "string"]], required: ["query"]),
        tool("list_wiki", "The wiki's pages, the most recently written first.",
             ["kind": ["type": "string", "description": "person, project, organization, place, topic or me; empty for all"]]),
        tool("get_profile", "Who the user is (role, focus, tools, habits, how they write) and today's digest of what's going on for them.", [:]),
        tool("get_promises", "What the user promised, was asked, or was promised, and conversations waiting on them; open "
             + "first, soonest due first. With include_closed, what was done or dropped too.",
             ["include_closed": ["type": "boolean"]]),
        tool("get_open_loops", "The same as get_promises, open only.", [:]),
        tool("get_time_report", "Where the user's time went (apps and sites) between two days.",
             ["from": ["type": "string", "description": "YYYY-MM-DD, default today"],
              "to": ["type": "string", "description": "YYYY-MM-DD, default today"]]),
        tool("search_screen", "Find windows the user had open (pages, documents, chats, email) by their words.",
             ["query": ["type": "string", "description": "words from what they saw"]], required: ["query"]),
        tool("get_upcoming", "What's coming up for the user: events, bookings and things to do, soonest first.", [:]),
        tool("get_work_history", "What the user worked on, as episodes (one task each: when, how long, which apps, what it "
             + "was for, how it ended), for a day or matching some words.",
             ["day": ["type": "string", "description": "YYYY-MM-DD, default today"],
              "query": ["type": "string", "description": "words about the work (a project, a person); optional"]]),
    ]

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "annotations": ["readOnlyHint": true],
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    public static var toolNames: [String] { tools.compactMap { $0["name"] as? String } }

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
                           "serverInfo": ["name": "murmur-memory", "version": "2"],
                           "instructions": Self.instructions])
        case "ping": return result([:])
        case "tools/list": return result(["tools": Self.tools])
        case "tools/call":
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let known = Self.toolNames.contains(name)
            let text = call(name, arguments)
            return result(["content": [["type": "text", "text": text]], "isError": !known])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
    }

    public func call(_ name: String, _ arguments: [String: Any]) -> String {
        func text(_ key: String) -> String {
            let value = arguments[key]
            return ((value as? String) ?? value.map { "\($0)" } ?? "").trimmingCharacters(in: .whitespaces)
        }
        func number(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            min(range.upperBound, max(range.lowerBound, (arguments[key] as? Int) ?? Int(text(key)) ?? fallback))
        }
        let now = Date()
        switch name {
        case "search_memory":
            // The same one way into memory the app uses (BrainRecall), so assistants get the same answers.
            let query = text("query")
            guard !query.isEmpty else { return "Say what to search for." }
            index.sync(now: now)
            // What Murmur did for the user lives with the app's own memory, not in a copy being searched.
            if journal.url == BrainStore.defaultURL { index.putMurmur(CommandMemory.actionsForIndex(days: 30)) }
            let parts = BrainRecall.parts(query)
            let embedded = LocalReader.embedderInstalled ? LocalReader.embedNow(parts, query: true) : nil
            let names = Grounding.vocabulary(brain: brain, graph: graph, prefs: CommandMemory.preferences()).map(\.name)
            let evidence = BrainRecall(index: index, vectors: vectors, graph: graph).recall(query, names: names, vectors: embedded,
                                                                                             now: now, limit: 14)
            return evidence.isEmpty ? "Nothing in memory about \"\(query)\"." : evidence.text(limit: 7000, sources: true)
        case "get_recent_activity":
            let minutes = number("minutes", 30, 1...720)
            let windows = journal.snapshots(from: now.addingTimeInterval(Double(-minutes) * 60), to: now, limit: 60)
            return windows.isEmpty ? "Nothing in the last \(minutes) minutes." : windows.map(Self.activityLine).joined(separator: "\n")
        case "get_working_memory":
            let hours = number("hours", 3, 1...24)
            let windows = journal.snapshots(from: now.addingTimeInterval(Double(-hours) * 3600), to: now, limit: 200)
                .sorted { $0.last > $1.last }
            var out: [String] = [], length = 0
            for window in windows {
                let block = Self.activityLine(window) + "\n" + BrainModel.redact(String(window.text.prefix(1500)))
                    + (window.authored.isEmpty ? "" : "\nThe user wrote and sent here: " + BrainModel.redact(String(window.authored.suffix(600))))
                guard length + block.count <= 16000 else { break }
                out.append(block)
                length += block.count
            }
            return out.isEmpty ? "Nothing in the last \(hours) hours." : out.joined(separator: "\n\n")
        case "open_records":
            let ids = text("ids").split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
            guard !ids.isEmpty else { return "Give source ids, such as snapshot:744." }
            var out: [String] = [], length = 0
            for id in ids.prefix(8) {
                let block = open(id)
                guard length + block.count <= 24000 else { out.append("(\(id): left out, too long; open it on its own)"); continue }
                out.append(block)
                length += block.count
            }
            return out.joined(separator: "\n\n")
        case "get_chronicle":
            let period = Self.period(text("period"), now: now)
            let level = Journal.Level.of(period)
            var lines: [String] = []
            if let summary = journal.chronicle(level, period) { lines.append("\(period): \(summary)") }
            if let below = level.below {
                lines += journal.chronicles(below, within: period).map { "\($0.period): \($0.summary)" }
            }
            return lines.isEmpty ? "Nothing recorded for \(period)." : lines.joined(separator: "\n")
        case "get_wiki_page":
            let asked = text("name")
            let page = ["me", "myself", "the user", "user", "you"].contains(asked.lowercased())
                ? wiki.list(kind: "me", limit: 1).first.flatMap { wiki.page(id: $0.id, history: true) }
                : wiki.page(named: asked, history: true)
            guard let page else {
                let similar = wiki.search(asked, limit: 5).map(\.title)
                return "No page about \"\(asked)\"." + (similar.isEmpty ? " Try search_memory." : " Close: " + similar.joined(separator: ", ") + ".")
            }
            return Self.pageText(page)
        case "search_wiki":
            let pages = wiki.search(text("query"), limit: 8)
            return pages.isEmpty ? "No pages match." : pages.map { "- \($0.title) (\($0.kind)): \($0.summary) [page:\($0.id)]" }.joined(separator: "\n")
        case "list_wiki":
            let kind = text("kind")
            let pages = wiki.list(kind: kind.isEmpty ? nil : kind, limit: 60)
            return pages.isEmpty ? "No pages yet." : pages.map { "- \($0.title) (\($0.kind)): \($0.summary) [page:\($0.id)]" }.joined(separator: "\n")
        case "get_profile":
            var parts: [String] = []
            if let written = profile.text("profile") {
                parts.append("PROFILE (written \(ProfileRules.day(written.generated))):\n\(written.text)")
            }
            if let digest = profile.text("digest") {
                parts.append("DIGEST (written \(ProfileRules.day(digest.generated))):\n\(digest.text)")
            }
            return parts.isEmpty ? "No profile yet: Murmur writes one once it has read a few days of the user's work." : parts.joined(separator: "\n\n")
        case "get_promises", "get_open_loops":
            let closed = name == "get_promises" && (arguments["include_closed"] as? Bool ?? (text("include_closed") == "true"))
            let threads = graph.openThreads(now: now, limit: 12).map { Threads.line($0, now: now) }
            var lines = threads + journal.loops(limit: 40).map { loop in
                "- \(loop.label): \(Nudges.describe(loop, now: now))" + (loop.person.isEmpty ? "" : " (with \(loop.person))") + " [loop:\(loop.id)]"
            }
            if closed {
                for status in ["done", "dropped"] {
                    lines += journal.loops(status: status, limit: 20).map { "- \(status == "done" ? "Done" : "Dropped"): \($0.summary) [loop:\($0.id)]" }
                }
            }
            return lines.isEmpty ? "Nothing open." : lines.joined(separator: "\n")
        case "get_time_report":
            let days = DateFormatter()
            days.dateFormat = "yyyy-MM-dd"
            let from = days.date(from: text("from")) ?? Calendar.current.startOfDay(for: now)
            let to = (days.date(from: text("to")) ?? from).addingTimeInterval(86400)
            let spent = journal.time(from: from, to: to)
            return spent.isEmpty ? "No time recorded." : spent.map { "- \($0.name): \(Nudges.minutes($0.seconds))" }.joined(separator: "\n")
        case "search_screen":
            let seen = journal.search(text("query"), limit: 8)
            return seen.isEmpty ? "Nothing seen matching \"\(text("query"))\"." : seen.map { Recall.seen($0) + " [snapshot:\($0.id)]" }.joined(separator: "\n")
        case "get_upcoming":
            let certain = graph.upcoming(now: now, limit: 6).map { "- " + $0.item.body.replacingOccurrences(of: "\n", with: "; ") }
            let coming = brain.upcoming(limit: 15, now: now).map { "- \($0.memory.text)" }
            let lines = certain + coming
            return lines.isEmpty ? "Nothing coming up." : lines.joined(separator: "\n")
        case "get_work_history":
            let query = text("query")
            var episodes: [MemoryGraph.StoredEpisode]
            if !query.isEmpty {
                episodes = graph.searchEpisodes(query, limit: 12)
            } else {
                let formatter = ScreenDates.formatter("yyyy-MM-dd", .current)
                let day = formatter.date(from: text("day")).map { Calendar.current.startOfDay(for: $0) } ?? Calendar.current.startOfDay(for: now)
                episodes = graph.episodes(from: day, to: day.addingTimeInterval(86400)).filter { $0.seconds >= 60 }
            }
            return episodes.isEmpty ? "No work found." : episodes.map { MemoryRecall.line($0) + " [episode:\($0.id)]" }.joined(separator: "\n")
        default:
            return "Unknown tool \(name). The tools: " + Self.toolNames.joined(separator: ", ") + "."
        }
    }

    /// One window as a line of activity: when, how long, where, what, and its source id.
    static func activityLine(_ window: Journal.Snapshot) -> String {
        let when = ScreenDates.formatter("EEE d MMM HH:mm", .current).string(from: window.first)
        let minutes = Int((window.seconds / 60).rounded())
        let place = window.domain.isEmpty ? window.app : "\(window.app), \(window.domain)"
        return "- \(when)\(minutes > 0 ? " (\(minutes) min)" : ""), \(place): \(window.title) [snapshot:\(window.id)]"
    }

    /// A page with what's true now, then what no longer is.
    static func pageText(_ page: Wiki.Page) -> String {
        let current = Wiki.Page(id: page.id, entity: page.entity, title: page.title, kind: page.kind, aliases: page.aliases,
                                summary: page.summary, links: page.links, updated: page.updated, model: page.model,
                                claims: page.claims.filter { $0.invalidAt == nil })
        var text = current.text(sources: true) + " [page:\(page.id)]"
        let old = page.claims.filter { $0.invalidAt != nil }
        if !old.isEmpty {
            text += "\nEarlier on this page (left out when it was last rewritten; may no longer hold):\n" + old.prefix(10).map { claim in
                "- \(claim.text) (until \(ProfileRules.day(claim.invalidAt ?? claim.confirmed)))"
            }.joined(separator: "\n")
        }
        if !page.aliases.isEmpty { text += "\nAlso called: " + page.aliases.joined(separator: ", ") }
        return text
    }

    /// A period as asked ("last week", "2026-W45", "") as kept.
    static func period(_ asked: String, now: Date, calendar: Calendar = .current) -> String {
        switch asked.lowercased() {
        case "", "today": return Journal.Level.day.period(of: now, calendar: calendar)
        case "yesterday": return Journal.Level.day.period(of: now.addingTimeInterval(-86400), calendar: calendar)
        case "this week", "this_week": return Journal.Level.week.period(of: now, calendar: calendar)
        case "last week", "last_week": return Journal.Level.week.period(of: now.addingTimeInterval(-7 * 86400), calendar: calendar)
        case "this month", "this_month": return Journal.Level.month.period(of: now, calendar: calendar)
        case "last month", "last_month":
            return Journal.Level.month.period(of: calendar.date(byAdding: .month, value: -1, to: now) ?? now, calendar: calendar)
        case "this year", "this_year": return Journal.Level.year.period(of: now, calendar: calendar)
        default: return asked
        }
    }

    /// One record in full, by its source id.
    func open(_ source: String) -> String {
        let parts = source.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = Int64(parts[1]) else { return "\(source): not a source id." }
        switch parts[0] {
        case "snapshot":
            guard let window = journal.snapshot(id: id) else { return "\(source): gone (windows are kept two weeks)." }
            var text = Self.activityLine(window) + (window.url.map { "\n" + $0 } ?? "") + "\n" + BrainModel.redact(String(window.text.prefix(12000)))
            if !window.authored.isEmpty { text += "\nThe user wrote and sent here: " + BrainModel.redact(String(window.authored.suffix(2000))) }
            return text
        case "episode":
            guard let episode = graph.episode(id: id) else { return "\(source): not found." }
            let windows = graph.snapshots(ofEpisode: id).prefix(12).compactMap { entry in
                journal.snapshot(id: entry.snapshot).map { "  " + Self.activityLine($0) }
            }
            return MemoryRecall.line(episode) + " [\(source)]" + (windows.isEmpty ? "" : "\nIts windows:\n" + windows.joined(separator: "\n"))
        case "page":
            return wiki.page(id: id, history: true).map(Self.pageText) ?? "\(source): not found."
        default:
            index.sync()
            guard let row = index.id(of: source), let record = index.records([row])[row] else { return "\(source): not found." }
            let when = record.at.map { ScreenDates.formatter("EEE d MMM yyyy HH:mm", .current).string(from: $0) } ?? "undated"
            return "\(record.title) (\(when)) [\(source)]\n\(record.text)"
        }
    }
}
