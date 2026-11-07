import Foundation

/// The user's open business with people, as an assistant keeps it: one thread per email or chat they started or
/// answered, with who it's with (and their organization and role when the screen said), what the user asked or offered,
/// the details that matter, whose turn it is, when to follow up, and how much it matters.
///
/// - Opened by rules from what the user sent (`ItemReader`: an email, a message), never by a model.
/// - Moved by rules: a reply seen makes it the user's turn; a follow-up day passed with no reply makes it time to nudge;
///   the user writing again makes it wait again.
/// - Filled in once by the model (`enrich`), from the email itself: every detail it keeps has to be in it.
public struct MemoryThread: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, CaseIterable {
        /// The user wrote; the other side hasn't answered.
        case waiting
        /// The other side answered (or asked): the user owes the next step.
        case yourTurn = "your_turn"
        /// Waiting past the follow-up day: time to nudge them.
        case nudge
        case done
    }

    public var id: Int64
    public var key: String
    public var title: String
    public var person: String
    public var organization: String
    public var role: String
    /// What the user asked or offered ("a 15-minute walkthrough of Murmur; to join Wispr as a product engineer").
    public var ask: String
    /// What an assistant needs to know about it, a line each ("Applied for Product Engineer, New Products and Design
    /// Engineer", "Happy to relocate to SF").
    public var details: [String]
    /// What it's for: "job search", "sales", "project", "personal", "other".
    public var goal: String
    public var status: Status
    /// "email", or the app ("WhatsApp").
    public var channel: String
    public var lastAction: String
    public var lastAt: Date
    public var followUp: Date?
    /// 0 to 10 as the model judged it (5 until it has).
    public var importance: Double
    public var enriched: Bool

    /// How much it needs the user now, 0 to 10: what's at stake, whose turn it is, how overdue.
    public func priority(now: Date = Date()) -> Double {
        var score = importance
        switch status {
        case .yourTurn: score += 2.5
        case .nudge: score += 1.5
        case .waiting: score -= 1
        case .done: return 0
        }
        if ["job search", "sales"].contains(goal) { score += 1 }
        let days = now.timeIntervalSince(lastAt) / 86400
        if status == .yourTurn { score += min(2, days / 2) }   // the longer they've waited on you, the more it matters
        if days > 21 { score -= 2 }                            // gone cold
        return min(10, max(0, score))
    }

    public var whose: String {
        switch status {
        case .waiting: return "waiting on \(person)"
        case .yourTurn: return "your turn"
        case .nudge: return "no reply yet: time to follow up"
        case .done: return "done"
        }
    }
}

public enum Threads {
    /// Days to wait for a reply before it's time to nudge.
    public static let followUpDays = 4.0
    /// Two weeks without a word either way: cold (kept, not pressed on the user).
    public static let coldAfter: TimeInterval = 14 * 86400

    /// A subject's key without "Re:", "Fwd:": a reply is the same thread.
    static func subjectKey(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while let range = text.range(of: #"^(?i)(re|fwd?|aw|sv)\s*:\s*"#, options: .regularExpression) { text.removeSubrange(range) }
        return BrainModel.nameKey(text)
    }

    // MARK: Opening and moving threads (rules)

    /// Brings threads up to date with what's been seen: one for each email or message the user sent in the last month,
    /// replies seen move them to the user's turn, and the follow-up day passing moves them to nudge. Returns how many
    /// were opened.
    @discardableResult
    public static func update(graph: MemoryGraph, now: Date = Date()) -> Int {
        let recent = graph.items([.email, .message], limit: 400).filter { ($0.item.when ?? $0.last) > now.addingTimeInterval(-30 * 86400) }
        var opened = 0
        // What the user sent, oldest first (a later email in the same thread moves it on).
        for stored in recent.filter({ $0.item.mine && !$0.item.people.isEmpty }).sorted(by: { ($0.item.when ?? $0.last) < ($1.item.when ?? $1.last) }) {
            let item = stored.item, person = item.people[0], at = item.when ?? stored.last
            let email = item.kind == .email
            let key = "thread|" + BrainModel.nameKey(person) + "|" + (email ? subjectKey(item.title) : "chat:" + (item.fields["app"] ?? "").lowercased())
            let action = email ? "You emailed \(person): \"\(item.title)\"" : "You wrote to \(person) on \(item.fields["app"] ?? "chat"): \"\(item.title)\""
            if graph.openThread(key: key, title: email ? item.title : "Chat with \(person)", person: person,
                                channel: email ? "email" : item.fields["app"] ?? "chat", action: action, at: at,
                                followUp: at.addingTimeInterval(followUpDays * 86400), item: stored.id) {
                opened += 1
            }
        }
        // Replies: an email from them with the thread's subject, seen after the user wrote.
        // A reply has a sender who isn't the user (the same email opened in another of the user's mailboxes has none).
        let me = Set(graph.meNames().map { BrainModel.nameKey($0) })
        for stored in recent where !stored.item.mine && stored.item.kind == .email {
            let subject = subjectKey(stored.item.title), from = BrainModel.nameKey(stored.item.actor)
            guard !subject.isEmpty, !from.isEmpty, !me.contains(from),
                  !me.contains(where: { from.hasPrefix($0) || $0.hasPrefix(from) }) else { continue }
            // The thread's own subject is in its key (its title may be the assistant's own words by now).
            for thread in graph.threads(limit: 200) where thread.status != .done && thread.key.hasSuffix("|" + subject)
                && stored.last > thread.lastAt.addingTimeInterval(60) {
                let from = stored.item.actor
                graph.moveThread(thread.id, status: .yourTurn, action: "\(from) replied", at: stored.last, item: stored.id)
            }
        }
        // No reply by the follow-up day: nudge (within two weeks of writing; after that it's gone cold, not urgent).
        for thread in graph.threads(limit: 200) where thread.status == .waiting && (thread.followUp ?? .distantFuture) < now
            && now.timeIntervalSince(thread.lastAt) < Threads.coldAfter {
            graph.moveThread(thread.id, status: .nudge, action: nil, at: nil, item: nil)
        }
        return opened
    }

    // MARK: Filling them in (the model, once)

    static func system(user: [String]) -> String {
        let who = user.isEmpty ? "the user" : user.joined(separator: ", also called ")
        return """
            You keep notes for the personal assistant of \(who). Below is something the user sent (an email or a \
            message), with who it went to. Write what an assistant needs to act on it later, as JSON only: \
            {"title": "...", "ask": "...", "details": ["..."], "organization": "...", "role": "...", "goal": "...", \
            "follow_up_days": 4, "importance": 0-10, "next_step": "..."}.
            "title": the thread in a few words ("Joining Wispr: pitch to Tanay").
            "ask": what the user asked for or offered, in one sentence, with its specifics.
            "details": up to 5 short facts that matter later (roles applied for, links, prices, dates, what was \
            promised), each copied in substance from the text.
            "organization" and "role": of the person written to, only if the text says them; else "".
            "goal": one of "job search", "sales", "project", "personal", "other".
            "follow_up_days": when to nudge if there's no reply (2 to 10).
            "importance": how much it matters to the user's life and work (job and money 8-10, a lead 6-8, routine 2-4).
            "next_step": what the user should do next, in a few words.
            Only what the text says: names, roles, numbers and links exactly as written. Nothing from passwords or codes.
            """
    }

    /// The thread's source as the model reads it: what was sent (its full text when the window had it), to whom.
    static func source(of thread: MemoryThread, graph: MemoryGraph, journal: Journal) -> (text: String, windows: [Journal.Snapshot]) {
        let items = graph.threadItems(thread.id)
        var text = "To: \(thread.person)\nSubject: \(thread.title)\n"
        var windows: [Journal.Snapshot] = []
        for stored in items.prefix(3) {
            let body = stored.item.fields["body"] ?? stored.item.fields["start"] ?? stored.item.fields["text"] ?? ""
            if let headline = stored.item.body.split(separator: "\n").first { text += "\n" + headline + "\n" }
            if !body.isEmpty { text += body + "\n" }
            for snapshot in graph.snapshots(ofItem: stored.id).prefix(1) {
                if let window = journal.snapshot(id: snapshot) { windows.append(window) }
            }
        }
        return (String(text.prefix(4000)), windows)
    }

    /// Fills in up to `limit` threads the model hasn't read yet. With Claude or OpenAI (`remote`), a thread whose window
    /// must stay on the Mac (`CloudPrivacy`) waits for the local model, and what's sent is scrubbed.
    @discardableResult
    public static func enrich(graph: MemoryGraph, journal: Journal, brain: BrainStore, ask: EpisodeReader.Ask,
                              remote: Bool = false, limit: Int = 3, now: Date = Date()) async -> Int {
        var done = 0
        for thread in graph.threads(limit: 50).filter({ !$0.enriched && $0.status != .done }).prefix(limit) {
            let (source, windows) = Self.source(of: thread, graph: graph, journal: journal)
            if remote, CloudPrivacy.sensitive(windows) != nil { continue }
            guard let content = await ask(system(user: brain.meNames()), remote ? CloudPrivacy.scrub(source) : source) else { break }
            let notes = parse(content, source: source)
            graph.enrichThread(thread.id, notes: notes, followUp: thread.lastAt.addingTimeInterval(notes.followUpDays * 86400))
            done += 1
        }
        if done > 0 { MemoryLog.write("filled in \(done) threads (who, what you asked, when to follow up)") }
        return done
    }

    public struct Notes: Sendable, Equatable {
        public var title = ""
        public var ask = ""
        public var details: [String] = []
        public var organization = ""
        public var role = ""
        public var goal = "other"
        public var followUpDays = Threads.followUpDays
        public var importance = 5.0
        public var nextStep = ""
    }

    /// The model's notes, checked: a detail, the ask, the organization or the role the text doesn't support goes.
    public static func parse(_ content: String, source: String) -> Notes {
        var notes = Notes()
        let answer = ModelOutput.answer(content)
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any] else { return notes }
        func text(_ key: String, _ limit: Int) -> String {
            BrainModel.redact((object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).prefix(limit)
                .trimmingCharacters(in: .whitespaces)
        }
        let lower = source.lowercased()
        let sourceWords = Set(BrainModel.keywords(source))
        func supported(_ claim: String) -> Bool {
            guard !claim.isEmpty, EpisodeReader.detailsFound(claim, in: source) else { return false }
            // Every name, title and acronym in it ("Tanay", "CEO", "Wispr Flow") is in the text.
            let proper = claim.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).dropFirst()
                .filter { $0.first?.isUppercase == true && $0.count >= 2 }.map { $0.lowercased() }
            if proper.contains(where: { !sourceWords.contains($0) && !lower.contains($0) }) { return false }
            // Most of its words are in the text (a small model rewords a little).
            let words = BrainModel.keywords(claim).filter { $0.count >= 4 }
            guard !words.isEmpty else { return true }
            return Double(words.filter { lower.contains($0.prefix(5)) }.count) / Double(words.count) >= 0.6
        }
        let title = text("title", 80)
        // A title is a label in the model's words: only its names have to be in the text.
        let named = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.first?.isUppercase == true && $0.count >= 2 }
            .dropFirst().map { $0.lowercased() }
        notes.title = !title.isEmpty && EpisodeReader.detailsFound(title, in: source)
            && named.allSatisfy({ sourceWords.contains($0) || lower.contains($0) }) ? title : ""
        let ask = text("ask", 300)
        notes.ask = supported(ask) ? ask : ""
        notes.details = (object["details"] as? [String] ?? []).prefix(6).map {
            BrainModel.redact($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { $0.count >= 4 && $0.count <= 200 && supported($0) }
        // An organization or a role only as the text writes it.
        let organization = text("organization", 60), role = text("role", 60)
        notes.organization = !organization.isEmpty && lower.contains(organization.lowercased()) ? organization : ""
        notes.role = !role.isEmpty && lower.contains(role.lowercased()) ? role : ""
        let goal = text("goal", 20).lowercased()
        notes.goal = ["job search", "sales", "project", "personal"].contains(goal) ? goal : "other"
        let days = (object["follow_up_days"] as? NSNumber)?.doubleValue ?? Double(object["follow_up_days"] as? String ?? "") ?? followUpDays
        notes.followUpDays = min(10, max(2, days))
        let importance = (object["importance"] as? NSNumber)?.doubleValue ?? Double(object["importance"] as? String ?? "") ?? 5
        notes.importance = min(10, max(0, importance))
        notes.nextStep = text("next_step", 80)
        return notes
    }

    // MARK: Saying them

    public static func line(_ thread: MemoryThread, now: Date = Date(), calendar: Calendar = .current) -> String {
        func day(_ date: Date) -> String { ScreenDates.formatter("EEE d MMM", calendar).string(from: date) }
        var who = thread.person
        let about = [thread.role, thread.organization].filter { !$0.isEmpty }.joined(separator: ", ")
        if !about.isEmpty { who += " (\(about))" }
        var text = "- \(who): \(thread.title)."
        if !thread.ask.isEmpty { text += " You asked: \(thread.ask)" + (thread.ask.hasSuffix(".") ? "" : ".") }
        if !thread.details.isEmpty { text += " Details: " + thread.details.joined(separator: "; ") + "." }
        text += " Last: \(thread.lastAction) on \(day(thread.lastAt)); \(thread.whose)"
        if thread.status == .waiting, let followUp = thread.followUp { text += ", follow up \(day(followUp))" }
        let priority = thread.priority(now: now)
        text += ". Priority \(priority >= 7.5 ? "high" : priority >= 5 ? "medium" : "low") [thread with \(thread.person)]"
        return text
    }
}

extension MemoryGraph {
    static let threadColumns = """
        id, key, title, person, organization, role, ask, details, goal, status, channel, last_action, last_at, follow_up, \
        importance, enriched
        """

    func storedThread(_ row: [String]) -> MemoryThread? {
        guard row.count >= 16, let id = Int64(row[0]) else { return nil }
        return MemoryThread(id: id, key: row[1], title: row[2], person: row[3], organization: row[4], role: row[5], ask: row[6],
                            details: row[7].split(separator: "\n").map(String.init), goal: row[8],
                            status: MemoryThread.Status(rawValue: row[9]) ?? .waiting, channel: row[10], lastAction: row[11],
                            lastAt: Date(timeIntervalSince1970: Double(row[12]) ?? 0),
                            followUp: Double(row[13]).map { Date(timeIntervalSince1970: $0) },
                            importance: Double(row[14]) ?? 5, enriched: row[15] == "1")
    }

    func createThreadTables() {
        db.exec("""
            CREATE TABLE IF NOT EXISTS thread(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
              person TEXT NOT NULL, organization TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT '', ask TEXT NOT NULL DEFAULT '',
              details TEXT NOT NULL DEFAULT '', goal TEXT NOT NULL DEFAULT 'other', status TEXT NOT NULL DEFAULT 'waiting',
              channel TEXT NOT NULL DEFAULT '', last_action TEXT NOT NULL DEFAULT '', last_at REAL NOT NULL, follow_up REAL,
              importance REAL NOT NULL DEFAULT 5, enriched INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL)
            """)
        db.exec("CREATE TABLE IF NOT EXISTS thread_item(thread INTEGER NOT NULL, item INTEGER NOT NULL, PRIMARY KEY(thread, item))")
    }

    /// A thread for what the user sent: opened, or moved on when this is newer than its last step. True when new.
    @discardableResult
    func openThread(key: String, title: String, person: String, channel: String, action: String, at: Date, followUp: Date,
                    item: Int64) -> Bool {
        let time = at.timeIntervalSince1970
        if let row = db.rows("SELECT id, last_at, status FROM thread WHERE key = ?", [key]).first, let id = Int64(row[0]) {
            db.exec("INSERT OR IGNORE INTO thread_item(thread, item) VALUES(?, ?)", [id, item])
            if time > (Double(row[1]) ?? 0) + 60 {
                db.exec("UPDATE thread SET last_action = ?, last_at = ?, status = 'waiting', follow_up = ? WHERE id = ?",
                        [action, time, followUp.timeIntervalSince1970, id])
            }
            return false
        }
        let id = db.insert("""
            INSERT INTO thread(key, title, person, channel, last_action, last_at, follow_up, created) VALUES(?,?,?,?,?,?,?,?)
            """, [key, title, person, channel, action, time, followUp.timeIntervalSince1970, Date().timeIntervalSince1970])
        guard id != 0 else { return false }
        db.exec("INSERT OR IGNORE INTO thread_item(thread, item) VALUES(?, ?)", [id, item])
        return true
    }

    func moveThread(_ id: Int64, status: MemoryThread.Status, action: String?, at: Date?, item: Int64?) {
        if let action, let at {
            db.exec("UPDATE thread SET status = ?, last_action = ?, last_at = ? WHERE id = ?", [status.rawValue, action, at.timeIntervalSince1970, id])
        } else {
            db.exec("UPDATE thread SET status = ? WHERE id = ?", [status.rawValue, id])
        }
        if let item { db.exec("INSERT OR IGNORE INTO thread_item(thread, item) VALUES(?, ?)", [id, item]) }
    }

    func enrichThread(_ id: Int64, notes: Threads.Notes, followUp: Date) {
        db.exec("""
            UPDATE thread SET title = CASE WHEN ? = '' THEN title ELSE ? END, ask = ?, details = ?, organization = ?, role = ?,
              goal = ?, importance = ?, follow_up = CASE WHEN status = 'waiting' THEN ? ELSE follow_up END, enriched = 1 WHERE id = ?
            """, [notes.title, notes.title, notes.ask, notes.details.joined(separator: "\n"), notes.organization, notes.role,
                  notes.goal, notes.importance, followUp.timeIntervalSince1970, id])
    }

    /// The user marked it done, or said so.
    public func closeThread(_ id: Int64) { db.exec("UPDATE thread SET status = 'done' WHERE id = ?", [id]) }

    /// Threads, the most recent step first.
    public func threads(limit: Int = 50) -> [MemoryThread] {
        db.rows("SELECT \(Self.threadColumns) FROM thread ORDER BY last_at DESC LIMIT ?", [limit]).compactMap(storedThread)
    }

    /// Open threads, what needs the user most first.
    public func openThreads(now: Date = Date(), limit: Int = 12) -> [MemoryThread] {
        Array(threads(limit: 200).filter { thread in
            thread.status != .done && (thread.status == .yourTurn || now.timeIntervalSince(thread.lastAt) < Threads.coldAfter)
        }.sorted { $0.priority(now: now) > $1.priority(now: now) }.prefix(limit))
    }

    /// Threads with someone a question names (by name, organization or subject words).
    public func threads(matching query: String, limit: Int = 6, now: Date = Date()) -> [MemoryThread] {
        let words = Set(BrainModel.keywords(query).filter { $0.count >= 3 })
        guard !words.isEmpty else { return [] }
        let found = threads(limit: 200).filter { thread in
            let named = Set(BrainModel.keywords(thread.person + " " + thread.organization))
            let about = Set(BrainModel.keywords(thread.title + " " + thread.ask))
            return !named.isDisjoint(with: words) || about.intersection(words).count >= 2
        }
        // What's live first; gone-cold ones only when nothing live matches.
        let live = found.filter { now.timeIntervalSince($0.lastAt) < Threads.coldAfter || $0.status == .yourTurn }
        return Array((live.isEmpty ? found : live).prefix(limit))
    }

    func threadItems(_ id: Int64) -> [StoredItem] {
        db.rows("""
            SELECT i.id, i.key, i.kind, i.title, i.body, i.actor, i.project, i.people, i.at, i.fields, i.mine, i.first, i.last
            FROM thread_item t JOIN screen_item i ON i.id = t.item WHERE t.thread = ? ORDER BY coalesce(i.at, i.last)
            """, [id]).compactMap(storedItem)
    }

    /// The user's names, from the living memory in the same file.
    func meNames() -> [String] {
        (db.rows("SELECT aliases FROM entity WHERE kind = 'me' LIMIT 1", []).first?.first ?? "")
            .split(separator: "\n").map(String.init).filter { !["me", "you", ""].contains($0) }
    }

    func snapshots(ofItem id: Int64) -> [Int64] {
        db.rows("SELECT snapshot FROM screen_item_snapshot WHERE item = ? ORDER BY snapshot DESC", [id]).compactMap { Int64($0[0]) }
    }
}
