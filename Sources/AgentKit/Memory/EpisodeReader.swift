import Foundation

/// Reads a finished episode into the living memory: once, as a whole (what the user did across its windows, with the
/// items in it exactly as the windows had them), instead of one window at a time.
///
/// - What items say for certain goes in without the model: a release of the user's ("Released Murmur 1.6.0 on Fri 6
///   Nov 2026: …"), a flight they booked (a plan with its departure, and reminders for check-in), who they wrote to.
/// - The model writes the episode's title, what it was for, how it ended, and what's worth remembering from it; every
///   memory and promise comes with the words it was read from, and is kept only when those words are in the episode
///   and every number, time and day in it is too.
/// - The entities it touched are connected: the user worked on a project, released it, talked with someone, someone is
///   part of a project.
public enum EpisodeReader {
    public typealias Ask = @Sendable (_ system: String, _ user: String) async -> String?

    /// What came of reading one episode.
    public struct Result: Sendable, Equatable {
        public var title = ""
        public var summary = ""
        public var outcome = ""
        public var memories: [BrainModel.Candidate] = []
        public var promises: [Journal.Promise] = []
        /// Memories and promises the model wrote that their own words didn't support.
        public var unsupported = 0
    }

    // MARK: The episode as the model reads it

    /// The episode as text: when and where, the items in it, then its windows (most time first), each cut to what fits,
    /// and what the user sent. Also the windows, for checking what the model writes against them.
    public static func text(of episode: MemoryGraph.StoredEpisode, graph: MemoryGraph, journal: Journal,
                            budget: Int = 6500, calendar: Calendar = .current) -> (text: String, windows: [Journal.Snapshot], items: [MemoryGraph.StoredItem]) {
        let windows = graph.snapshots(ofEpisode: episode.id).compactMap { entry -> (Journal.Snapshot, Double)? in
            journal.snapshot(id: entry.snapshot).map { ($0, entry.seconds) }
        }
        // What happened in it: not the old rows a list also shows (last month's sent mail beside today's).
        let items = graph.items(ofEpisode: episode.id).filter { stored in
            stored.item.kind != .page
                && (![.email, .message].contains(stored.item.kind)
                    || (stored.item.when.map { $0 >= episode.start.addingTimeInterval(-86400) && $0 <= episode.end.addingTimeInterval(86400) } ?? true))
        }
        let minutes = max(1, Int((episode.seconds / 60).rounded()))
        let span = ScreenDates.formatter("EEE d MMM yyyy, HH:mm", calendar).string(from: episode.start) + "–"
            + ScreenDates.formatter("HH:mm", calendar).string(from: episode.end)
        var text = "[\(span), \(minutes) min; \(episode.apps.prefix(5).joined(separator: ", "))"
            + (episode.project.isEmpty ? "" : "; project \(episode.project)") + "]\n"
        if !items.isEmpty {
            text += "\nWhat the windows held, exactly:\n"
            for stored in items.prefix(8) {
                text += "- " + stored.item.body.replacingOccurrences(of: "\n", with: "; ") + "\n"
            }
        }
        text += "\nThe windows, most time first:\n"
        let left = max(1500, budget - text.count)
        let share = max(350, left / max(1, min(windows.count, 6)))
        for (window, seconds) in windows.prefix(8) {
            let kind = WindowKind.of(window)
            let place = window.domain.isEmpty ? window.app : "\(window.app), \(window.domain)"
            var body = BrainModel.redact(ScreenText.clean(window.text))
            // Code says little in words: a little of it.
            if ItemReader.editors.contains(window.app) || ItemReader.terminals.contains(window.app) { body = String(body.prefix(300)) }
            if !window.seenAs.isEmpty, window.seenAs != "-" { body = "Seen as: \(window.seenAs)\n" + body }
            var part = "\n[\(place), \(max(1, Int((seconds / 60).rounded()))) min, \(kind.label)] \(window.title)\n"
            part += String(body.prefix(share))
            if !window.authored.isEmpty {
                part += "\nThe user wrote and sent here: " + BrainModel.redact(String(window.authored.suffix(800)))
            }
            guard text.count + part.count <= budget + share else { break }
            text += part + "\n"
        }
        return (String(text.prefix(budget + 800)), windows.map(\.0), items)
    }

    static func system(today: Date, user: [String]) -> String {
        let day = today.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        let who = user.isEmpty ? "" : " The user is \(user.joined(separator: ", also called "))."
        return """
            You read one stretch of the user's work on their Mac (the windows they were in, one task: coding a \
            project, a conversation, booking a trip) and write what their assistant should know about it. Today is \
            \(day).\(who)

            JSON only: {"title": "...", "summary": "...", "outcome": "...", "memories": [...], "promises": [...]}.
            "title": what the user was doing, at most 8 words ("Releasing Murmur 1.6.0", "Booking a flight to Raipur").
            "summary": one or two sentences: what they did and what for, naming the project, people and documents.
            "outcome": how it ended in a few words, from the text ("released", "sent", "booked", "still open"), naming \
            only people the text names.
            "memories": what stays true after today, at most 5: {"about", "about_kind" (person, organization, \
            project, place, topic or me), "text" (one sentence, at most 20 words, naming who or what), "kind" (fact, \
            relationship, preference, event, task or status), "slot" (employer, role, city... or empty), "importance" \
            (0-10: 9-10 the user's own decisions, releases, deadlines; 7-8 people they work with, their plans; 4-6 \
            useful facts; 1-3 things only seen), "quote" (the words it comes from, copied exactly from the text)}.
            "promises": obligations from a conversation or the user's own work, at most 3: {"summary", "person", \
            "project", "kind" ("promised": the user said they'd do it; "asked": someone asked the user; "owed": \
            someone will do it for the user), "due" (YYYY-MM-DD or empty), "status" ("open" or "done"), "quote"}.

            Only what the text says: every name, number, time and date exactly as written there, and each "quote" \
            copied from it. "What the windows held, exactly" is already known: don't repeat flights or releases from \
            it as memories. Never what the user looked at ("Viewed…"), never builds, tests, CI, pull-request states or \
            commits, never anything from passwords or codes. A feed, ads or news: nothing unless it's about the user. \
            Empty lists when nothing is worth keeping.
            """
    }

    /// What the answer has to look like (the local reader keeps to it).
    public static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"], "summary": ["type": "string"], "outcome": ["type": "string"],
            "memories": ["type": "array", "items": ["type": "object", "properties": [
                "about": ["type": "string"], "about_kind": ["type": "string"], "text": ["type": "string"],
                "kind": ["type": "string"], "slot": ["type": "string"], "importance": ["type": "number"],
                "quote": ["type": "string"]], "required": ["about", "text", "quote"]]],
            "promises": ["type": "array", "items": ["type": "object", "properties": [
                "summary": ["type": "string"], "person": ["type": "string"], "project": ["type": "string"],
                "kind": ["type": "string"], "due": ["type": "string"], "status": ["type": "string"],
                "quote": ["type": "string"]], "required": ["summary", "kind", "quote"]]],
        ],
        "required": ["title", "summary", "outcome", "memories", "promises"],
    ]

    // MARK: Checking what the model wrote

    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || ":.'".unicodeScalars.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:'")) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whether the words a memory came from are in the source: all of them in order, or nearly all of them with at
    /// least three in a row (a small model drops a word).
    static func quoteFound(_ quote: String, in source: String) -> Bool {
        let words = normalized(quote).split(separator: " ").map(String.init)
        guard words.count >= 2 else { return false }
        let haystack = " " + normalized(source) + " "
        if haystack.contains(" " + words.joined(separator: " ") + " ") { return true }
        let present = Set(haystack.split(separator: " ").map(String.init))
        let found = words.filter(present.contains).count
        guard Double(found) / Double(words.count) >= 0.8 else { return false }
        return (0..<max(0, words.count - 2)).contains { index in
            haystack.contains(" " + words[index..<index + 3].joined(separator: " ") + " ")
        }
    }

    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                             "october", "november", "december"]

    /// Whether every number, time, version and month in a claim is in the source: "departs 11:35" when the page says
    /// 10:15 is out.
    static func detailsFound(_ claim: String, in source: String) -> Bool {
        let haystack = " " + normalized(source) + " "
        let words = Set(haystack.split(separator: " ").map(String.init))
        for token in normalized(claim).split(separator: " ").map(String.init) where token.contains(where: \.isNumber) {
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let ordinal = bare.replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression)
            if words.contains(token) || words.contains(bare) || words.contains(ordinal) || words.contains("v" + bare) { continue }
            // "08" and "8" are the same day; "1.6" is in "1.6.0".
            if let number = Int(ordinal), words.contains(String(format: "%02d", number)) || words.contains(String(number)) { continue }
            if bare.contains("."), haystack.contains(" " + bare + ".") || haystack.contains(" v" + bare + ".") { continue }
            return false
        }
        for month in monthNames {
            let short = String(month.prefix(3))
            let claimed = normalized(claim).split(separator: " ").contains { $0 == month || $0 == short }
            if claimed, !words.contains(month), !words.contains(short), !words.contains("sept") || short != "sep" { return false }
        }
        return true
    }

    /// Field names as a subject ("about_kind"), a button's or a box's words as a fact ("Start video call with Archit",
    /// "What do you want to know?"), a commit's address ("murmur-app@a811f46"), a fragment of a few words.
    static func isJunk(about: String, text: String) -> Bool {
        let fields: Set<String> = ["about", "about_kind", "text", "kind", "slot", "importance", "quote", "email", "user", "page",
                                   "website", "app", "window", "screen", "memory", "project", "person", "topic"]
        if fields.contains(about.lowercased()) { return true }
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let interface = ["start video call", "start voice call", "start a call", "what do you want to know", "ask anything",
                         "type a message", "write a message", "search", "click ", "tap ", "press ", "open ", "sign in", "log in",
                         "new chat", "send message", "add files"]
        if interface.contains(where: lower.hasPrefix) { return true }
        if lower.hasSuffix("?") && lower.split(separator: " ").count <= 8 { return true }
        if lower.range(of: #"@[0-9a-f]{7,40}\b"#, options: .regularExpression) != nil { return true }
        return lower.split(separator: " ").count < 4
    }

    /// The model's answer, checked: memories and promises without their words in the source, or with a detail the
    /// source doesn't have, go.
    public static func parse(_ content: String, source: String, now: Date = Date()) -> Result {
        let answer = ModelOutput.answer(content)
        var result = Result()
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any] else { return result }
        func clean(_ key: String, _ limit: Int) -> String {
            BrainModel.redact((object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).prefix(limit)
                .trimmingCharacters(in: .whitespaces)
        }
        result.title = clean("title", 80)
        result.summary = clean("summary", 400)
        result.outcome = clean("outcome", 80)
        // The title and summary may only name what's there too.
        if !detailsFound(result.title, in: source) { result.title = "" }
        if !detailsFound(result.summary, in: source) { result.summary = "" }

        let memories = (object["memories"] as? [[String: Any]] ?? []).prefix(6)
        var supported: [[String: Any]] = []
        // Its words found where it says they are; without a quote (a reader trained before quotes), every detail in it
        // has to be in the source, and most of its words (`Consolidator.judge`, after).
        func supportedBy(_ quote: String, _ text: String) -> Bool {
            guard detailsFound(text, in: source) else { return false }
            return quote.trimmingCharacters(in: .whitespaces).isEmpty || quoteFound(quote, in: source)
        }
        for entry in memories {
            let text = entry["text"] as? String ?? "", quote = entry["quote"] as? String ?? ""
            let about = (entry["about"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if isJunk(about: about, text: text) { result.unsupported += 1; continue }
            if supportedBy(quote, text) { supported.append(entry) } else { result.unsupported += 1 }
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["memories": supported]),
           let json = String(data: data, encoding: .utf8) {
            result.memories = BrainDistiller.parse(json, origin: .screen, now: now)
        }
        let promises = (object["promises"] as? [[String: Any]] ?? []).prefix(4)
        var kept: [[String: Any]] = []
        for entry in promises {
            let summary = entry["summary"] as? String ?? "", quote = entry["quote"] as? String ?? ""
            if supportedBy(quote, summary) { kept.append(entry) } else { result.unsupported += 1 }
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["memories": [], "promises": kept]),
           let json = String(data: data, encoding: .utf8) {
            result.promises = Consolidator.parse(json, now: now).promises.filter { $0.kind != "plan" }
        }
        return result
    }

    // MARK: What items say for certain

    /// Memories, plans and connections that items give without the model: the user's releases and flights.
    static func certain(_ items: [MemoryGraph.StoredItem], now: Date, calendar: Calendar) -> (memories: [BrainModel.Candidate], plans: [Journal.Promise]) {
        var memories: [BrainModel.Candidate] = []
        var plans: [Journal.Promise] = []
        for stored in items {
            let item = stored.item
            switch item.kind {
            case .release where item.mine:
                let name = item.fields["name"] ?? item.project
                let version = item.fields["version"] ?? ""
                let day = item.when.map { " on " + ScreenDates.day($0, calendar: calendar) } ?? ""
                let notes = (item.fields["notes"] ?? "").split(separator: " ").prefix(22).joined(separator: " ")
                let text = "Released \(name) \(version)\(day)" + (notes.isEmpty ? "" : ": \(notes)")
                // A release stays part of the project's history: a fact, not an event that passes.
                memories.append(BrainModel.Candidate(about: name, aboutKind: .project, text: String(text.prefix(270)), kind: .fact,
                                                     confidence: 0.95, origin: .screen, importance: 0.9))
            case .email where item.mine && !item.people.isEmpty:
                // What the user wrote and to whom: a fact about that person, and a reply they're waiting on.
                let to = item.people.joined(separator: ", ")
                let when = item.when ?? stored.last
                guard when > now.addingTimeInterval(-3 * 86400) else { continue }
                let start = (item.fields["start"] ?? "").split(separator: " ").prefix(18).joined(separator: " ")
                let wrote = "You emailed \(to) on \(ScreenDates.day(when, calendar: calendar)): \"\(item.title)\""
                    + (start.isEmpty ? "" : ", \(start)…")
                memories.append(BrainModel.Candidate(about: item.people[0], aboutKind: .person, text: String(wrote.prefix(270)),
                                                     kind: .event, confidence: 0.95, origin: .screen, importance: 0.8))
            case .flight where item.mine:
                // A connecting flight is part of the journey it connects (its own plan would be a second trip).
                guard let departs = item.when, departs > now.addingTimeInterval(-3600),
                      !items.contains(where: { ($0.item.fields["connecting"] ?? "").contains(item.fields["number"] ?? "?") }) else { continue }
                let time = item.fields["departure time"] ?? ScreenDates.formatter("HH:mm", calendar).string(from: departs)
                let summary = "\(item.title), departs \(time)"
                plans.append(Journal.Promise(summary: summary, mine: true, due: departs, kind: "plan"))
                let number = item.fields["number"] ?? ""
                if let opens = item.fields["check-in opens"].flatMap({ ScreenDates.formatter("yyyy-MM-dd HH:mm", calendar).date(from: $0) }), opens > now {
                    plans.append(Journal.Promise(summary: "Web check-in opens for \(number)", mine: true, due: opens, kind: "plan"))
                }
                if let closes = item.fields["check-in closes"].flatMap({ ScreenDates.formatter("yyyy-MM-dd HH:mm", calendar).date(from: $0) }), closes > now {
                    plans.append(Journal.Promise(summary: "Check-in closes for \(number)", mine: true, due: closes, kind: "plan"))
                }
                memories.append(BrainModel.Candidate(about: "You", aboutKind: .me,
                                                     text: "\(item.title) on \(ScreenDates.spoken(departs, calendar: calendar))"
                                                         + (item.fields["reference"].map { ", booking \($0)" } ?? ""),
                                                     kind: .event, expires: departs.addingTimeInterval(86400), confidence: 0.95,
                                                     origin: .screen, importance: 0.85))
            default:
                continue
            }
        }
        return (memories, plans)
    }

    // MARK: Running

    /// Reads up to `limit` finished episodes, the latest first. Episodes about nothing the model can add (a feed, a video,
    /// a few seconds) are closed without it. Returns how many were read.
    @discardableResult
    /// `remote`: `ask` is Claude or OpenAI. Then what must stay on this Mac (money, health, identity: `CloudPrivacy`)
    /// isn't read here but marked for the local model, and what's sent is scrubbed first.
    public static func pass(graph: MemoryGraph, journal: Journal, brain: BrainStore, ask: Ask?, vectors: MemoryVectors? = nil,
                            limit: Int = 6, remote: Bool = false, now: Date = Date(), calendar: Calendar = .current,
                            keepGoing: () -> Bool = { true }) async -> Int {
        let me = brain.meNames()
        var read = 0
        journal.consolidated(graph.closeShort())
        Threads.update(graph: graph, now: now)
        var kept: [String] = []
        defer { if !kept.isEmpty { MemoryLog.write("kept \(kept.count) episodes on this Mac for the local model, never sent: " + kept.joined(separator: "; ")) } }
        for episode in graph.unread(limit: limit, includePrivate: !remote) {
            guard keepGoing() else { break }
            var (text, windows, items) = Self.text(of: episode, graph: graph, journal: journal, calendar: calendar)
            if remote {
                if let why = CloudPrivacy.sensitive(windows) {
                    graph.markPrivate(episode.id)
                    kept.append(why)
                    continue
                }
                text = CloudPrivacy.scrub(text)
            }
            let source = windows.map { $0.title + "\n" + $0.text + "\n" + $0.authored }.joined(separator: "\n")
                + "\n" + items.map(\.item.body).joined(separator: "\n")
            var certain = Self.certain(items, now: now, calendar: calendar)
            // A connecting flight seen on its own page is still part of its journey.
            certain.plans = certain.plans.filter { !graph.isConnectingFlight(in: $0.summary) }
            certain.memories = certain.memories.filter { !graph.isConnectingFlight(in: $0.text) }
            var result = Result()
            // Worth the model: some of it was work, a conversation, the user's own, or it lasted.
            let kinds = Set(windows.map { WindowKind.of($0) })
            let passive = kinds.isSubset(of: [.feed, .video, .search, .product, .article])
                && !windows.contains { Engagement.mentions($0.title + " " + $0.text, any: me) }
            // Watching, scrolling a feed, reading the news: what it was is already its name; the model adds nothing
            // about the user's world (and takes the most time on it).
            if let ask, !passive, episode.seconds >= 45 || !items.isEmpty {
                guard let content = await ask(system(today: now, user: me), text) else { break }   // the model isn't there
                result = parse(content, source: source, now: now)
                // A window's own title copied as the episode's ("murmur — ./build.sh — 213×59") names nothing.
                if episode.titles.contains(result.title) || result.title.contains("×") { result.title = "" }
                result.memories = Consolidator.judge(result.memories, seen: windows,
                                                     browsing: Set(windows.filter(Engagement.isBrowsing).map(\.id)), me: me) {
                    brain.knownPeople(in: $0)
                }.filter { $0.importance >= Consolidator.keepFrom }
                for index in result.memories.indices where !(result.memories[index].slot.map { Consolidator.singleValued.contains($0.lowercased()) } ?? true) {
                    result.memories[index].slot = nil
                }
                result.promises = Consolidator.judge(promises: result.promises, seen: windows, me: me) { brain.knownPeople(in: $0) }
                if let vectors {
                    let (fresh, repeated) = await Consolidator.repeats(result.memories, brain: brain, vectors: vectors, me: me)
                    brain.confirm(repeated, now: now)
                    result.memories = fresh
                }
            }
            if passive, result.title.isEmpty {
                // Named without the model: "Watching YouTube", "Browsing linkedin.com".
                let place = episode.context.hasPrefix("site:") ? String(episode.context.dropFirst(5)) : episode.apps.first ?? ""
                let site = place.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? place
                result.title = (kinds.contains(.video) ? "Watching " : kinds.contains(.feed) ? "Scrolling " : "Browsing ") + site
            }
            let applied = brain.apply(certain.memories + result.memories, item: "episode:\(episode.id)", now: now)
            let loops = journal.take(certain.plans + result.promises, evidence: windows.map(\.id), now: now)
            // Bookings that aren't flights (a train, a hotel, an appointment): their plans, asked of the model one page
            // at a time as before.
            if let ask, certain.plans.isEmpty {
                for window in windows.filter({ Consolidator.looksLikeBooking($0, me: me) }).prefix(1) {
                    var page = window.title + "\n" + String(window.text.prefix(3500))
                    if remote { page = CloudPrivacy.scrub(page) }
                    if let content = await ask(Consolidator.planSystem(today: now), page) {
                        let found = Consolidator.checkedPlans(content, page: page, now: now)
                        _ = journal.take(found, evidence: [window.id], now: now)
                    }
                }
            }
            connect(episode: episode, items: items, memories: certain.memories + result.memories, graph: graph, brain: brain, now: now)
            graph.setRead(episode.id, title: result.title, summary: result.summary, outcome: result.outcome, now: now)
            journal.consolidated(windows.map(\.id))
            if !result.title.isEmpty || applied.added > 0 || loops.opened > 0 {
                MemoryLog.write("read \"\(result.title.isEmpty ? episode.name : result.title)\" (\(Int(episode.seconds / 60)) min): "
                                + "\(applied.added) new memories, \(applied.confirmed) confirmed, \(loops.opened) promises or plans"
                                + (result.unsupported > 0 ? "; left out \(result.unsupported) the windows didn't say" : ""))
            }
            read += 1
        }
        // What the user sent, filled in for their assistant: who, what was asked, when to follow up.
        if let ask, keepGoing() {
            await Threads.enrich(graph: graph, journal: journal, brain: brain, ask: ask, remote: remote, limit: 3, now: now)
        }
        return read
    }

    /// The connections an episode shows: the user worked on its project (heavier the longer), released it, talked with
    /// the people in it; the people in it are part of its project.
    static func connect(episode: MemoryGraph.StoredEpisode, items: [MemoryGraph.StoredItem], memories: [BrainModel.Candidate],
                        graph: MemoryGraph, brain: BrainStore, now: Date) {
        guard let me = brain.entity(named: "You", kind: .me, now: now) else { return }
        let evidence = "episode:\(episode.id)"
        var project: Int64?
        let projectName = items.first { !$0.item.project.isEmpty && $0.item.kind != .page }?.item.project ?? episode.project
        if !projectName.isEmpty, let id = brain.entity(named: projectName, kind: .project, now: now) {
            project = id
            graph.connect(me, "worked_on", id, at: episode.end, weight: max(0.1, episode.seconds / 3600), evidence: evidence)
        }
        for stored in items {
            switch stored.item.kind {
            case .release where stored.item.mine:
                if let id = brain.entity(named: stored.item.fields["name"] ?? stored.item.project, kind: .project, now: now) {
                    graph.connect(me, "released", id, at: stored.item.when ?? episode.end, evidence: evidence)
                }
            case .message, .email:
                for person in stored.item.people + [stored.item.actor] where !person.isEmpty && person != "me" {
                    guard let id = brain.entity(named: person, kind: .person, now: now) else { continue }
                    graph.connect(me, "talked_with", id, at: episode.end, evidence: evidence)
                    if let project { graph.connect(id, "involved_in", project, at: episode.end, evidence: evidence) }
                }
            default:
                continue
            }
        }
        for memory in memories where memory.aboutKind == .person {
            guard let id = brain.entity(named: memory.about, kind: .person, now: now) else { continue }
            if let project { graph.connect(id, "involved_in", project, at: episode.end, weight: 0.5, evidence: evidence) }
        }
    }
}
