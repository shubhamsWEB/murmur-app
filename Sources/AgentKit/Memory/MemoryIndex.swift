import Foundation

/// Everything Murmur remembers, as one kind of record in one index: what the user did (sent, posted, released, worked
/// on), what's theirs (a flight, a file), conversations, facts, summaries of their days, promises, what Murmur did for
/// them, and the raw windows everything else was read from. One record says what happened, who did it, when, about
/// whom or what, and where it came from.
///
/// Before this there were six stores and fifteen keyword lists deciding which one a question went to ("release" →
/// releases, "flight" → flights): a question in other words, or about two things, missed even when memory held the
/// answer. On 7 Nov "what did we release?" was answered with 1.5.1 while two episodes said "Releasing Murmur 1.7.0".
/// Now every question searches all of it at once (`BrainRecall`), and the stores stay what they are underneath: the
/// index is rebuilt from them, never written to by anyone else.
public final class MemoryIndex: @unchecked Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The user did it: sent, posted, released, tagged, worked on.
        case did
        /// The user's own thing: a booking, a file, a project.
        case yours
        /// Someone the user is in a conversation with, and where it stands.
        case conversation
        /// Something known: from Contacts, Calendar, what the user told Murmur, a note, a page.
        case fact
        /// A summary of an hour or a day.
        case summary
        /// Something promised or owed.
        case promise
        /// What Murmur did for the user (a message it sent, a reminder it made).
        case murmur
        /// A window as it was on screen: the source of truth for everything above, ranked below it.
        case saw
    }

    public struct Record: Sendable, Equatable {
        public var id: Int64 = 0
        /// Where it came from, unique: "item:259", "episode:84", "snapshot:744".
        public var source: String
        public var kind: Kind
        /// "me" (the user), "murmur", or "other".
        public var actor: String
        /// When it happened (else when it was first seen).
        public var at: Date?
        public var title: String
        public var text: String
        /// Who and what it involves: people, apps, projects.
        public var entities: [String]
        /// How much to trust it, 0 to 1: what the user did and what they told Murmur first, raw windows last.
        public var prior: Double

        public init(source: String, kind: Kind, actor: String, at: Date?, title: String, text: String,
                    entities: [String] = [], prior: Double) {
            self.source = source
            self.kind = kind
            self.actor = actor
            self.at = at
            self.title = title
            self.text = text
            self.entities = entities
            self.prior = prior
        }
    }

    private let db: SQLiteConnection
    private let lock = NSLock()

    public init(url: URL = BrainStore.defaultURL) {
        db = SQLiteConnection(url: url)
        db.exec("""
            CREATE TABLE IF NOT EXISTS recall_record(id INTEGER PRIMARY KEY, source TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
              actor TEXT NOT NULL, at REAL, title TEXT NOT NULL, text TEXT NOT NULL, entities TEXT NOT NULL, prior REAL NOT NULL)
            """)
        db.exec("CREATE INDEX IF NOT EXISTS recall_record_at ON recall_record(at)")
        // Porter stemming: "release" finds "Releasing", "post" finds "posted". `extra` holds version keys ("v1_7") so
        // "1.7" finds "1.7.0".
        db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS recall_fts USING fts5(title, text, entities, extra,
              tokenize='porter unicode61 remove_diacritics 2')
            """)
        db.exec("CREATE TABLE IF NOT EXISTS recall_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    // MARK: Writing

    /// Puts records in (a record from the same source replaces the one before).
    @discardableResult
    public func put(_ records: [Record]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return writeAll(records)
    }

    /// Writes records a few hundred at a time, each batch all or nothing, so the screen-memory helper and the MCP server
    /// (other processes on the same file) never wait long for the lock. False when any batch failed (busy, a snapshot
    /// that moved under it): the caller then doesn't mark the store as read, and it's read again next time.
    private func writeAll(_ records: [Record]) -> Bool {
        var ok = true
        for start in stride(from: 0, to: records.count, by: 400) {
            let chunk = records[start..<min(start + 400, records.count)]
            switch batch({ chunk.allSatisfy(write) }) {
            case .done: continue
            case .busy: ok = false
            case .failed:
                // One record that can't be written (not the file being busy) is left out and said in the log, not
                // tried again with the rest at every sync.
                for record in chunk {
                    switch batch({ write(record) }) {
                    case .done: continue
                    case .busy: ok = false
                    case .failed: MemoryLog.write("memory index: couldn't keep \(record.source)")
                    }
                }
            }
        }
        return ok
    }

    enum Batch { case done, busy, failed }

    /// One write transaction, taken up front (IMMEDIATE, so another writer can't slip in between its reads and writes),
    /// committed only when every write in it worked. `busy`: another process held the file (try again later).
    private func batch(_ body: () -> Bool) -> Batch {
        guard db.exec("BEGIN IMMEDIATE") else { return .busy }
        guard body() else { db.exec("ROLLBACK"); return .failed }
        guard db.exec("COMMIT") else { db.exec("ROLLBACK"); return .busy }
        return .done
    }

    private func write(_ unsafe: Record) -> Bool {
        // What goes into the index can reach a model (the agent's, Claude Code's through the MCP server): no passwords,
        // keys, codes, card numbers or recovery phrases in it.
        var record = unsafe
        record.title = BrainModel.redact(unsafe.title)
        record.text = BrainModel.redact(unsafe.text)
        if let old = db.rows("SELECT id FROM recall_record WHERE source = ?", [record.source]).first?.first, let id = Int64(old) {
            guard remove(id) else { return false }
        }
        let id = db.insert("""
            INSERT INTO recall_record(source, kind, actor, at, title, text, entities, prior) VALUES(?,?,?,?,?,?,?,?)
            """, [record.source, record.kind.rawValue, record.actor, record.at?.timeIntervalSince1970, record.title,
                  record.text, record.entities.joined(separator: "\n"), record.prior])
        guard id != 0 else { return false }
        let extra = Self.versionKeys(record.title + " " + record.text).sorted().joined(separator: " ")
        return db.exec("INSERT INTO recall_fts(rowid, title, text, entities, extra) VALUES(?,?,?,?,?)",
                       [id, record.title, record.text, record.entities.joined(separator: " "), extra])
    }

    private func remove(_ id: Int64) -> Bool {
        db.exec("DELETE FROM recall_fts WHERE rowid = ?", [id]) && db.exec("DELETE FROM recall_record WHERE id = ?", [id])
    }

    /// Takes out every record from sources starting with a prefix ("episode:") but those listed.
    public func keepOnly(prefix: String, sources: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        prune(prefix: prefix, keep: sources)
    }

    @discardableResult
    private func prune(prefix: String, keep: Set<String>) -> Bool {
        let gone = db.rows("SELECT id, source FROM recall_record WHERE source LIKE ?", [prefix + "%"])
            .filter { !keep.contains($0[1]) }.compactMap { Int64($0[0]) }
        var ok = true
        for start in stride(from: 0, to: gone.count, by: 400) {
            ok = batch { gone[start..<min(start + 400, gone.count)].allSatisfy(remove) } == .done && ok
        }
        return ok
    }

    func state(_ key: String) -> String? {
        db.rows("SELECT value FROM recall_state WHERE key = ?", [key]).first?.first
    }

    func setState(_ key: String, _ value: String) {
        db.exec("INSERT OR REPLACE INTO recall_state(key, value) VALUES(?, ?)", [key, value])
    }

    // MARK: Reading

    /// Records whose words match, best first (BM25 over title, text, who and what, versions).
    public func search(_ match: String, limit: Int = 300) -> [Int64] {
        guard !match.isEmpty else { return [] }
        return db.rows("SELECT rowid FROM recall_fts WHERE recall_fts MATCH ? ORDER BY bm25(recall_fts, 3.0, 1.0, 4.0, 6.0) LIMIT ?",
                       [match, limit]).compactMap { Int64($0[0]) }
    }

    /// Records that name someone or something, the newest first.
    public func naming(_ name: String, limit: Int = 100) -> [Int64] {
        db.rows("SELECT id FROM recall_record WHERE entities LIKE ? OR title LIKE ? ORDER BY at DESC LIMIT ?",
                ["%\(name)%", "%\(name)%", limit]).compactMap { Int64($0[0]) }
    }

    /// Records of these kinds in a span, the most trusted and newest first.
    public func within(_ from: Date, _ to: Date, kinds: [Kind], limit: Int = 60) -> [Int64] {
        db.rows("""
            SELECT id FROM recall_record WHERE at >= ? AND at < ? AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))
            ORDER BY prior DESC, at DESC LIMIT ?
            """, ([from.timeIntervalSince1970, to.timeIntervalSince1970] as [Any?]) + kinds.map { $0.rawValue as Any? } + [limit as Any?])
            .compactMap { Int64($0[0]) }
    }

    /// What the user owes: to-dos, things due, promises, conversations waiting on them.
    public func owed(limit: Int = 40) -> [Int64] {
        db.rows("""
            SELECT id FROM recall_record WHERE (kind = 'promise' AND actor = 'me')
              OR (kind = 'fact' AND (text LIKE 'To do:%' OR text LIKE '%(due %' OR text LIKE 'Coming up:%'))
              OR (kind = 'conversation' AND (text LIKE '%your turn%' OR text LIKE '%follow up%'))
            ORDER BY prior DESC, at DESC LIMIT ?
            """, [limit]).compactMap { Int64($0[0]) }
    }

    /// The record for a source ("snapshot:744"), when there is one.
    public func id(of source: String) -> Int64? {
        db.rows("SELECT id FROM recall_record WHERE source = ?", [source]).first?.first.flatMap { Int64($0) }
    }

    public func records(_ ids: [Int64]) -> [Int64: Record] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: Record] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            for row in db.rows("""
                SELECT id, source, kind, actor, at, title, text, entities, prior FROM recall_record
                WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                """, chunk.map { $0 as Any? }) {
                guard row.count == 9, let id = Int64(row[0]), let kind = Kind(rawValue: row[2]) else { continue }
                var record = Record(source: row[1], kind: kind, actor: row[3],
                                    at: Double(row[4]).map { Date(timeIntervalSince1970: $0) }, title: row[5], text: row[6],
                                    entities: row[7].split(separator: "\n").map(String.init), prior: Double(row[8]) ?? 0.5)
                record.id = id
                out[id] = record
            }
        }
        return out
    }

    public func count() -> Int { Int(db.rows("SELECT count(*) FROM recall_record", []).first?.first ?? "") ?? 0 }

    /// "1.7.0" → v1_7 and v1_7_0, so a question about "1.7" finds "1.7.0" and the other way round.
    public static func versionKeys(_ text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\bv?(\d+)\.(\d+)(?:\.(\d+))?\b"#) else { return [] }
        var keys = Set<String>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
            guard let major = group(1), let minor = group(2) else { continue }
            keys.insert("v\(major)_\(minor)")
            if let patch = group(3) { keys.insert("v\(major)_\(minor)_\(patch)") }
        }
        return keys
    }
}

// MARK: - Keeping the index current

extension MemoryIndex {
    /// Brings the index up to date with the stores it's made from (all in brain.sqlite): what changed since the last
    /// time, and what went away. Cheap when nothing changed (one query of counts); the small stores are read whole,
    /// windows only when new or changed.
    public func sync(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        // One stamp per store: only a store that changed is read again (windows change every minute; the rest
        // seldom).
        // A stamp is a fingerprint of what the index reads from that store: a status changing from "open" to "done",
        // an entity renamed or a thread's ask edited changes it, so the store is read again.
        let stamps: [(key: String, sql: String, records: () -> [Record])] = [
            ("items", "SELECT group_concat(id || ':' || coalesce(last, '') || ':' || coalesce(seen, '') || ':' || coalesce(length(title), '') || ':' || coalesce(length(body), ''), ',') FROM screen_item",
             self.itemRecords),
            ("episodes", """
                SELECT group_concat(id || ':' || coalesce(end, '') || ':' || coalesce(length(title), '') || ':' || coalesce(length(summary), '') || ':' || coalesce(length(outcome), ''), ',')
                FROM episode
                """, self.episodeRecords),
            ("threads", """
                SELECT group_concat(id || ':' || coalesce(last_at, '') || ':' || coalesce(status, '') || ':' || coalesce(length(title), '') || ':'
                  || coalesce(length(last_action), '') || ':' || coalesce(length(ask), '') || ':' || coalesce(length(details), ''), ',') FROM thread
                """, self.threadRecords),
            ("memories", """
                SELECT group_concat(m.id || ':' || coalesce(m.confirmed, '') || ':' || coalesce(length(m.text), '') || ':' || e.id || ':' || coalesce(e.name, ''), ',')
                FROM memory m JOIN entity e ON e.id = m.entity WHERE m.archived = 0
                """, self.memoryRecords),
            ("chronicle", "SELECT group_concat(rowid || ':' || coalesce(generated, '') || ':' || coalesce(length(summary), ''), ',') FROM chronicle",
             self.chronicleRecords),
            ("loops", "SELECT group_concat(id || ':' || coalesce(last, '') || ':' || coalesce(status, '') || ':' || coalesce(due, ''), ',') FROM loop",
             self.loopRecords),
        ]
        var changed = false
        for store in stamps {
            let stamp = Self.fingerprint(db.rows(store.sql, []).first?.first ?? "")
            guard stamp != state("stamp-" + store.key) else { continue }
            // Marked read only when every write went in; otherwise it's read again next time.
            if writeAll(store.records()) { setState("stamp-" + store.key, stamp) }
            changed = true
        }
        // Windows: the ones changed since the last time, with a few minutes' overlap for a window the helper wrote late.
        // The new mark is the newest window actually read, so nothing written while this ran is skipped.
        let through = Double(state("snapshots-through") ?? "0") ?? 0
        let windows = snapshotRecords(since: through - 600)
        if !windows.isEmpty {
            let known = Set(db.rows("SELECT source FROM recall_record WHERE source LIKE 'snapshot:%' AND at >= ?",
                                    [through - 86400 * 2]).map { $0[0] })
            let fresh = windows.filter { $0.last > through || !known.contains($0.record.source) }.map(\.record)
            if !fresh.isEmpty {
                changed = true
                if writeAll(fresh), let newest = windows.map(\.last).max() { setState("snapshots-through", String(max(newest, through))) }
            }
        }
        let pruneStamp = db.rows("SELECT count(*) FROM snapshot", []).first?.first ?? ""
        guard changed || pruneStamp != state("stamp-pruned") else { return }
        // What's gone from the stores goes from the index: windows pruned after two weeks, memories forgotten.
        let present: [(String, String)] = [
            ("item:", "SELECT 'item:' || id FROM screen_item"), ("episode:", "SELECT 'episode:' || id FROM episode"),
            ("thread:", "SELECT 'thread:' || id FROM thread"), ("memory:", "SELECT 'memory:' || id FROM memory WHERE archived = 0"),
            ("chronicle:", "SELECT 'chronicle:' || rowid FROM chronicle"), ("loop:", "SELECT 'loop:' || id FROM loop"),
            ("snapshot:", "SELECT 'snapshot:' || id FROM snapshot"),
        ]
        var pruned = true
        for (prefix, sql) in present {
            pruned = prune(prefix: prefix, keep: Set(db.rows(sql, []).map { $0[0] })) && pruned
        }
        if pruned { setState("stamp-pruned", pruneStamp) }
    }

    /// A short, stable fingerprint (FNV-1a) of a store's stamp text: the same in every process and every launch.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16) + ":" + String(text.utf8.count)
    }

    /// What Murmur did for the user (from its own command history), as records, replacing the ones before: an action
    /// forgotten in Murmur's history, or older than the history it was given, leaves the index too.
    public func putMurmur(_ actions: [(at: Date, what: String, source: String)]) {
        lock.lock(); defer { lock.unlock() }
        let records = actions.map { Record(source: $0.source, kind: .murmur, actor: "murmur", at: $0.at, title: "Murmur did this for you",
                                           text: $0.what, entities: ["Murmur"], prior: 0.9) }
        // Only what changed is written (this runs before every question).
        let have = Dictionary(db.rows("SELECT source, text FROM recall_record WHERE source LIKE 'murmur:%'", []).map { ($0[0], $0[1]) },
                              uniquingKeysWith: { first, _ in first })
        if writeAll(records.filter { have[$0.source] != $0.text }) {
            prune(prefix: "murmur:", keep: Set(records.map(\.source)))
        }
    }

    // MARK: The stores, as records

    private func date(_ text: String) -> Date? { Double(text).map { Date(timeIntervalSince1970: $0) } }

    /// Items: what the user sent, posted, released or tagged is what they did; their bookings and files are theirs;
    /// a page is something seen.
    func itemRecords() -> [Record] {
        db.rows("SELECT id, kind, title, body, people, at, first, mine, fields FROM screen_item", []).compactMap { row in
            guard row.count == 9 else { return nil }
            let kind = row[1], mine = row[7] == "1"
            let people = row[4].split(separator: "\n").map(String.init)
            let fields = (row[8].data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let places = ["app", "platform", "name", "repository", "to"].compactMap { fields[$0] as? String }.filter { !$0.isEmpty }
            let when = date(row[5]) ?? date(row[6])
            if kind == "page" {
                return Record(source: "item:\(row[0])", kind: .saw, actor: "other", at: date(row[6]), title: row[2],
                              text: String(row[3].prefix(600)), entities: people, prior: 0.25)
            }
            let did = mine && ["email", "message", "post", "release"].contains(kind)
            return Record(source: "item:\(row[0])", kind: did ? .did : (mine ? .yours : .saw), actor: mine ? "me" : "other",
                          at: when, title: row[2], text: String(row[3].prefix(1500)), entities: people + places,
                          // A file or folder the user had open says little on its own; a booking or a project says more.
                          prior: did ? 1.0 : (mine ? (["code", "document"].contains(kind) ? 0.5 : 0.9) : 0.6))
        }
    }

    /// Episodes: stretches of the user's work, as the reading model saw them; an unread one only when it was long.
    func episodeRecords() -> [Record] {
        db.rows("SELECT id, start, seconds, project, title, summary, outcome, apps, titles FROM episode", []).compactMap { row in
            guard row.count == 9, let seconds = Double(row[2]) else { return nil }
            let minutes = Int((seconds / 60).rounded())
            let apps = row[7].split(separator: "\n").map(String.init)
            var title = row[4], text = row[5]
            var prior = 0.85
            if title.isEmpty && text.isEmpty {
                guard seconds >= 300 else { return nil }
                title = "Work in " + apps.prefix(3).joined(separator: ", ")
                text = row[8].replacingOccurrences(of: "\n", with: "; ").prefix(500).description
                prior = 0.35
            }
            if !row[6].isEmpty { text += " Outcome: \(row[6])." }
            text += " (\(max(1, minutes)) min, in \(apps.prefix(3).joined(separator: ", ")))"
            return Record(source: "episode:\(row[0])", kind: .did, actor: "me", at: date(row[1]), title: title, text: text,
                          entities: [row[3]] + apps, prior: prior)
        }
    }

    /// Conversations: who, about what, and whose turn it is.
    func threadRecords() -> [Record] {
        db.rows("SELECT id, title, person, organization, status, channel, last_action, last_at, ask, details FROM thread", [])
            .compactMap { row in
                guard row.count == 10 else { return nil }
                let status = ["waiting": "waiting for their reply", "your_turn": "your turn to reply",
                              "nudge": "time to follow up, no reply yet", "done": "done"][row[4]] ?? row[4]
                var text = "\(row[6]). Status: \(status)" + (row[5].isEmpty ? "" : " (\(row[5]))") + "."
                if !row[8].isEmpty { text += " They asked: \(row[8])." }
                if !row[9].isEmpty { text += " " + row[9].prefix(300) }
                return Record(source: "thread:\(row[0])", kind: .conversation, actor: "me", at: date(row[7]), title: row[1],
                              text: text, entities: [row[2], row[3]].filter { !$0.isEmpty }, prior: 0.9)
            }
    }

    /// Facts: what the user told Murmur and what their apps say first, what was inferred from a page last.
    func memoryRecords() -> [Record] {
        let trust = ["told": 0.95, "calendar": 0.9, "reminders": 0.9, "contacts": 0.9, "mail": 0.7, "notes": 0.5, "screen": 0.45]
        return db.rows("""
            SELECT m.id, e.kind, e.name, m.text, m.origin, m.confidence, m.confirmed FROM memory m
            JOIN entity e ON e.id = m.entity WHERE m.archived = 0
            """, []).compactMap { row in
            guard row.count == 7 else { return nil }
            let confidence = Double(row[5]) ?? 0.6
            return Record(source: "memory:\(row[0])", kind: .fact, actor: row[1] == "me" ? "me" : "other", at: date(row[6]),
                          title: row[1] == "me" ? "About you" : row[2], text: row[3], entities: row[1] == "me" ? [] : [row[2]],
                          prior: (trust[row[4]] ?? 0.5) * (0.6 + 0.4 * confidence))
        }
    }

    /// Summaries of the user's hours and days.
    func chronicleRecords() -> [Record] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return db.rows("SELECT rowid, level, period, summary, generated FROM chronicle", []).compactMap { row in
            guard row.count == 5 else { return nil }
            formatter.dateFormat = row[1] == "hour" ? "yyyy-MM-dd'T'HH" : "yyyy-MM-dd"
            let at = formatter.date(from: row[2]) ?? date(row[4])
            return Record(source: "chronicle:\(row[0])", kind: .summary, actor: "me", at: at,
                          title: "Your \(row[1]), \(row[2])", text: row[3], prior: 0.55)
        }
    }

    /// Promises and things owed.
    func loopRecords() -> [Record] {
        db.rows("SELECT id, summary, person, status, first, due FROM loop", []).compactMap { row in
            guard row.count == 6 else { return nil }
            let open = row[3] == "open"
            var text = row[1] + (row[2].isEmpty ? "" : " (with \(row[2]))") + ", \(row[3])"
            if let due = date(row[5]) { text += ", due " + due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
            // A promise kept or dropped is still remembered, but isn't owed: `owed()` finds the user's open ones only.
            return Record(source: "loop:\(row[0])", kind: .promise, actor: open ? "me" : "closed", at: date(row[4]), title: row[1],
                          text: text, entities: [row[2]].filter { !$0.isEmpty }, prior: open ? 0.7 : 0.5)
        }
    }

    /// Windows as they were on screen, new or changed since `since`: the evidence under everything, found when what
    /// was read from it missed the point.
    func snapshotRecords(since: Double) -> [(record: Record, last: Double)] {
        db.rows("SELECT id, app, title, domain, text, first, authored, last FROM snapshot WHERE last > ?", [since]).compactMap { row in
            guard row.count == 8, let last = Double(row[7]) else { return nil }
            let app = ScreenText.appName(row[1])
            let authored = ScreenText.confirmed(row[6])
            let text = (authored.isEmpty ? "" : "You wrote and sent here: \(authored.prefix(800))\n") + row[4].prefix(2500)
            return (Record(source: "snapshot:\(row[0])", kind: .saw, actor: authored.isEmpty ? "other" : "me", at: date(row[5]),
                           title: "\(app): \(ScreenText.cleanTitle(row[2]))".prefix(200).description, text: text,
                           entities: [app, row[3]].filter { !$0.isEmpty }, prior: authored.isEmpty ? 0.3 : 0.45), last)
        }
    }
}
