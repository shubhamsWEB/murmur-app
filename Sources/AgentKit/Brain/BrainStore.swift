import Foundation
import SQLite3

/// Where the living memory is kept: one SQLite file on this Mac (~/Library/Application Support/Murmur/brain.sqlite).
///
/// - entity: a person, organization, project, place or topic, with the other names it goes by.
/// - memory: one thing known about an entity, with its kind, the slot it fills ("employer"), how sure it is, when a
///   source last said it, when it stops being true, and the source item it came from. A memory a newer one replaced,
///   or one that went stale, is archived (kept out of answers) rather than deleted, so a source saying it again brings
///   it back. Full-text indexed.
/// - item: each thing a source showed Murmur (a contact, an event, a note, an email), with a hash of its content, so
///   only what changed is read again and what was deleted at the source is forgotten too.
/// - source: each source's switch, last sync and how it went.
/// - change: what Murmur learned, updated or forgot, for the Memory page's "Lately" list.
///
/// BrainModel decides; this keeps. Every call is short and synchronous behind a lock.
public final class BrainStore: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    public static let defaultURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Murmur/brain.sqlite")

    public init(url: URL = BrainStore.defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { return }
        db = handle
        for statement in [
            "PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL", "PRAGMA foreign_keys = ON",
            """
            CREATE TABLE IF NOT EXISTS entity(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL,
              key TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '', first_seen REAL, last_seen REAL,
              mentions INTEGER NOT NULL DEFAULT 1, UNIQUE(kind, key))
            """,
            """
            CREATE TABLE IF NOT EXISTS memory(id INTEGER PRIMARY KEY, entity INTEGER NOT NULL REFERENCES entity(id)
              ON DELETE CASCADE, text TEXT NOT NULL, kind TEXT NOT NULL, slot TEXT, confidence REAL NOT NULL,
              created REAL NOT NULL, confirmed REAL NOT NULL, expires REAL, pinned INTEGER NOT NULL DEFAULT 0,
              origin TEXT NOT NULL, item TEXT, archived INTEGER NOT NULL DEFAULT 0, replaced_by INTEGER,
              uses INTEGER NOT NULL DEFAULT 0, last_used REAL)
            """,
            "CREATE INDEX IF NOT EXISTS memory_entity ON memory(entity, archived)",
            "CREATE INDEX IF NOT EXISTS memory_item ON memory(item)",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(text, content='memory', content_rowid='id',
              tokenize='unicode61 remove_diacritics 2')
            """,
            """
            CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory BEGIN
              INSERT INTO memory_fts(rowid, text) VALUES (new.id, new.text); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory BEGIN
              INSERT INTO memory_fts(memory_fts, rowid, text) VALUES ('delete', old.id, old.text); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE OF text ON memory BEGIN
              INSERT INTO memory_fts(memory_fts, rowid, text) VALUES ('delete', old.id, old.text);
              INSERT INTO memory_fts(rowid, text) VALUES (new.id, new.text); END
            """,
            """
            CREATE TABLE IF NOT EXISTS item(source TEXT NOT NULL, external TEXT NOT NULL, hash TEXT NOT NULL,
              title TEXT NOT NULL DEFAULT '', seen REAL NOT NULL, read REAL, PRIMARY KEY(source, external))
            """,
            """
            CREATE TABLE IF NOT EXISTS source(name TEXT PRIMARY KEY, enabled INTEGER NOT NULL DEFAULT 1,
              last_sync REAL, status TEXT NOT NULL DEFAULT '', items INTEGER NOT NULL DEFAULT 0)
            """,
            "CREATE TABLE IF NOT EXISTS change(id INTEGER PRIMARY KEY, at REAL NOT NULL, what TEXT NOT NULL, text TEXT NOT NULL, origin TEXT)",
            "CREATE INDEX IF NOT EXISTS change_at ON change(at)",
        ] { exec(statement) }
        exec("DELETE FROM change WHERE at < ?", [Date().timeIntervalSince1970 - 30 * 86400])
    }

    deinit { sqlite3_close(db) }

    // MARK: Entities

    /// The entity with this name (or another name it goes by), made when it's new. `me` is always the one entity.
    @discardableResult
    public func entity(named name: String, kind: BrainModel.EntityKind, now: Date = Date()) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return entityLocked(named: name, kind: kind, now: now)
    }

    private func entityLocked(named rawName: String, kind: BrainModel.EntityKind, now: Date) -> Int64? {
        let name = kind == .me ? "You" : rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = kind == .me ? "me" : BrainModel.nameKey(name)
        guard !key.isEmpty else { return nil }
        let at = now.timeIntervalSince1970
        // By name or alias, in any kind first for people (a contact the model called an organization stays one entity).
        if let found = rows("SELECT id FROM entity WHERE kind = ? AND (key = ? OR instr(aliases, ?) > 0) LIMIT 1",
                            [kind.rawValue, key, "\n\(key)\n"]).first?.first, let id = Int64(found) {
            exec("UPDATE entity SET last_seen = ?, mentions = mentions + 1 WHERE id = ?", [at, id])
            return id
        }
        // The user, by their own name (from their Contacts card).
        if kind == .person, let found = rows("SELECT id FROM entity WHERE kind = 'me' AND instr(aliases, ?) > 0 LIMIT 1",
                                             ["\n\(key)\n"]).first?.first, let id = Int64(found) {
            exec("UPDATE entity SET last_seen = ? WHERE id = ?", [at, id])
            return id
        }
        if kind != .me, let found = rows("SELECT id FROM entity WHERE key = ? AND kind != 'me' LIMIT 1", [key]).first?.first,
           let id = Int64(found) {
            exec("UPDATE entity SET last_seen = ?, mentions = mentions + 1 WHERE id = ?", [at, id])
            return id
        }
        return insert("INSERT INTO entity(kind, name, key, aliases, first_seen, last_seen) VALUES(?,?,?,'',?,?)",
                      [kind.rawValue, name, key, at, at])
    }

    /// Another name an entity goes by ("Mom" for Roma Agrawal): found by either from now on.
    public func addAlias(_ alias: String, to entity: Int64) {
        let key = BrainModel.nameKey(alias)
        guard !key.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let current = rows("SELECT aliases, key FROM entity WHERE id = ?", [entity]).first ?? ["", ""]
        guard current[1] != key, !current[0].contains("\n\(key)\n") else { return }
        let aliases = (current[0].isEmpty ? "\n" : current[0]) + key + "\n"
        exec("UPDATE entity SET aliases = ? WHERE id = ?", [aliases, entity])
    }

    public struct EntityRow: Identifiable, Sendable, Equatable {
        public let id: Int64
        public let kind: BrainModel.EntityKind
        public let name: String
        public let aliases: [String]
        public let memories: Int
        public let lastSeen: Date
    }

    /// Entities with something current known about them, the most talked-about first.
    public func entities(kind: BrainModel.EntityKind? = nil, matching words: String = "", limit: Int = 200) -> [EntityRow] {
        lock.lock(); defer { lock.unlock() }
        var sql = """
            SELECT e.id, e.kind, e.name, e.aliases, count(m.id), e.last_seen FROM entity e
            JOIN memory m ON m.entity = e.id AND m.archived = 0 WHERE 1
            """
        var values: [Any?] = []
        if let kind { sql += " AND e.kind = ?"; values.append(kind.rawValue) }
        let key = BrainModel.nameKey(words)
        if !key.isEmpty { sql += " AND (e.key LIKE ? OR e.aliases LIKE ?)"; values += ["%\(key)%", "%\(key)%"] }
        sql += " GROUP BY e.id ORDER BY e.kind = 'me' DESC, count(m.id) + e.mentions DESC, e.last_seen DESC LIMIT ?"
        values.append(limit)
        return rows(sql, values).compactMap(entityRow)
    }

    private func entityRow(_ row: [String]) -> EntityRow? {
        guard row.count >= 6, let id = Int64(row[0]) else { return nil }
        return EntityRow(id: id, kind: BrainModel.EntityKind(rawValue: row[1]) ?? .topic, name: row[2],
                         aliases: row[3].split(separator: "\n").map(String.init), memories: Int(row[4]) ?? 0,
                         lastSeen: Date(timeIntervalSince1970: Double(row[5]) ?? 0))
    }

    // MARK: Memories

    public struct Applied: Sendable, Equatable {
        public var added = 0, confirmed = 0, replaced = 0
        public var total: Int { added + confirmed + replaced }
    }

    /// Puts what a source said into memory: each candidate confirms, replaces or adds to what's known about its
    /// entity (BrainModel.decide). `item`: the source item it came from ("contacts:ABC-123"), so it's forgotten when
    /// that is deleted.
    @discardableResult
    public func apply(_ candidates: [BrainModel.Candidate], item: String?, now: Date = Date()) -> Applied {
        lock.lock(); defer { lock.unlock() }
        var applied = Applied()
        let at = now.timeIntervalSince1970
        exec("BEGIN")
        for candidate in candidates {
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing with a password, key, code or card number in it is kept (Contacts' numbers are fine).
            if ![.contacts, .told].contains(candidate.origin), BrainModel.hasSecret(text) { continue }
            guard !text.isEmpty, let entity = entityLocked(named: candidate.about, kind: candidate.aboutKind, now: now) else {
                continue
            }
            let existing = memoriesLocked(entity: entity, includeArchived: true)
            // An archived memory a source says again comes back; one the user replaced stays replaced.
            let live = existing.filter { !$0.archived }.map(\.memory)
            let archived = existing.filter { $0.archived && !$0.replaced }.map(\.memory)
            switch BrainModel.decide(candidate, existing: live) {
            case .confirm(let id):
                let old = live.first { $0.id == id }!
                // A fuller wording of the same thing ("works at Acme" → "works at Acme as a product manager") wins.
                let fuller = BrainModel.keywords(text).isSuperset(of: BrainModel.keywords(old.text))
                    && text.count > old.text.count
                exec("UPDATE memory SET confirmed = ?, confidence = ?, expires = coalesce(?, expires), text = ? WHERE id = ?",
                     [at, BrainModel.confirmed(confidence: old.confidence, by: candidate.confidence),
                      candidate.expires?.timeIntervalSince1970, fuller ? text : old.text, id])
                applied.confirmed += 1
            case .replace(let id):
                let new = insertMemory(candidate, text: text, entity: entity, item: item, at: at)
                exec("UPDATE memory SET archived = 1, replaced_by = ? WHERE id = ?", [new, id])
                let old = live.first { $0.id == id }?.text ?? ""
                log("updated", "\(text) (was: \(old))", candidate.origin, at: at)
                applied.replaced += 1
            case .keepTold:
                continue
            case .add:
                if let back = archived.first(where: {
                    BrainModel.similarity(BrainModel.keywords(text), BrainModel.keywords($0.text)) >= 0.7
                }) {
                    exec("UPDATE memory SET archived = 0, confirmed = ?, confidence = ? WHERE id = ?",
                         [at, max(back.confidence, candidate.confidence), back.id])
                    applied.confirmed += 1
                } else {
                    insertMemory(candidate, text: text, entity: entity, item: item, at: at)
                    log("learned", text, candidate.origin, at: at)
                    applied.added += 1
                }
            }
        }
        exec("COMMIT")
        return applied
    }

    @discardableResult
    private func insertMemory(_ candidate: BrainModel.Candidate, text: String, entity: Int64, item: String?,
                              at: Double) -> Int64 {
        insert("""
            INSERT INTO memory(entity, text, kind, slot, confidence, created, confirmed, expires, pinned, origin, item)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [entity, text, candidate.kind.rawValue, candidate.slot, candidate.confidence, at, at,
                  candidate.expires?.timeIntervalSince1970, candidate.origin == .told ? 1 : 0, candidate.origin.rawValue, item])
    }

    private struct Kept {
        let memory: BrainModel.Memory
        let archived: Bool
        let replaced: Bool
    }

    private func memoriesLocked(entity: Int64, includeArchived: Bool) -> [Kept] {
        rows("""
            SELECT id, entity, text, kind, slot, confidence, created, confirmed, expires, pinned, origin, archived,
              replaced_by, uses FROM memory WHERE entity = ?\(includeArchived ? "" : " AND archived = 0")
            """, [entity]).compactMap { row in
            memoryRow(row, uses: row.count > 13 ? row[13] : "").map {
                Kept(memory: $0, archived: row[11] == "1", replaced: !row[12].isEmpty)
            }
        }
    }

    private func memoryRow(_ row: [String], uses: String = "") -> BrainModel.Memory? {
        guard row.count >= 11, let id = Int64(row[0]), let entity = Int64(row[1]) else { return nil }
        return BrainModel.Memory(
            id: id, entity: entity, text: row[2], kind: BrainModel.Kind.read(row[3]), slot: row[4].isEmpty ? nil : row[4],
            confidence: Double(row[5]) ?? 0.5, created: Date(timeIntervalSince1970: Double(row[6]) ?? 0),
            confirmed: Date(timeIntervalSince1970: Double(row[7]) ?? 0),
            expires: Double(row[8]).map { Date(timeIntervalSince1970: $0) }, pinned: row[9] == "1",
            origin: BrainModel.Origin(rawValue: row[10]) ?? .commands, uses: Int(uses) ?? 0)
    }

    /// These memories were used in an answer: they fade more slowly from now on.
    public func used(_ ids: [Int64], now: Date = Date()) {
        guard !ids.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        exec("UPDATE memory SET uses = uses + 1, last_used = ? WHERE id IN (\(marks))",
             [now.timeIntervalSince1970] + ids.map { $0 as Any? })
    }

    /// What's currently known about an entity, strongest first.
    public func memories(of entity: Int64, now: Date = Date()) -> [BrainModel.Memory] {
        lock.lock(); defer { lock.unlock() }
        return memoriesLocked(entity: entity, includeArchived: false).map(\.memory)
            .sorted { BrainModel.strength($0, now: now) > BrainModel.strength($1, now: now) }
    }

    /// A memory found for a question, with what it's about.
    public struct Hit: Sendable, Equatable, Identifiable {
        public let memory: BrainModel.Memory
        public let about: String
        public let aboutKind: BrainModel.EntityKind
        public var id: Int64 { memory.id }
    }

    /// Memories that match the words, or are about someone or something the words name; the best first (how well
    /// they match, and how strong they still are).
    public func search(_ query: String, limit: Int = 12, now: Date = Date()) -> [Hit] {
        lock.lock(); defer { lock.unlock() }
        var scored: [Int64: (hit: Hit, score: Double)] = [:]
        func add(_ rows: [[String]], boost: Double) {
            for (rank, row) in rows.enumerated() {
                guard row.count >= 14, let memory = memoryRow(Array(row.prefix(11)), uses: row[13]) else { continue }
                let strength = BrainModel.strength(memory, now: now)
                guard strength > 0 else { continue }
                let score = boost / Double(rank + 2) + strength
                let hit = Hit(memory: memory, about: row[11], aboutKind: BrainModel.EntityKind(rawValue: row[12]) ?? .topic)
                if let earlier = scored[memory.id] { scored[memory.id] = (hit, earlier.score + score) }
                else { scored[memory.id] = (hit, score) }
            }
        }
        let columns = "m.id, m.entity, m.text, m.kind, m.slot, m.confidence, m.created, m.confirmed, m.expires, m.pinned, m.origin, e.name, e.kind, m.uses"
        // Everything about an entity the question names.
        for entity in namedLocked(in: query) {
            add(rows("SELECT \(columns) FROM memory m JOIN entity e ON e.id = m.entity WHERE m.entity = ? AND m.archived = 0 LIMIT 40",
                     [entity]), boost: 3)
        }
        // And the memories whose words match.
        let words = BrainModel.keywords(query).filter { $0.count > 2 }.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        if !words.isEmpty {
            add(rows("""
                SELECT \(columns) FROM memory_fts f JOIN memory m ON m.id = f.rowid JOIN entity e ON e.id = m.entity
                WHERE memory_fts MATCH ? AND m.archived = 0 ORDER BY bm25(memory_fts) LIMIT 40
                """, [words.joined(separator: " OR ")]), boost: 2)
        }
        return scored.values.sorted { $0.score > $1.score }.prefix(limit).map(\.hit)
    }

    /// What's coming up and still to do, soonest first.
    public func upcoming(limit: Int = 8, now: Date = Date()) -> [Hit] {
        lock.lock(); defer { lock.unlock() }
        return rows("""
            SELECT m.id, m.entity, m.text, m.kind, m.slot, m.confidence, m.created, m.confirmed, m.expires, m.pinned,
              m.origin, e.name, e.kind, m.uses FROM memory m JOIN entity e ON e.id = m.entity
            WHERE m.archived = 0 AND m.kind IN ('event', 'task') AND e.kind = 'me' AND (m.expires IS NULL OR m.expires > ?)
            ORDER BY coalesce(m.expires, 9e12) LIMIT ?
            """, [now.timeIntervalSince1970, limit]).compactMap { row in
            guard row.count >= 14, let memory = memoryRow(Array(row.prefix(11)), uses: row[13]) else { return nil }
            return Hit(memory: memory, about: row[11], aboutKind: BrainModel.EntityKind(rawValue: row[12]) ?? .me)
        }
    }

    /// The entities a text names: by full name or another name they go by, or by first name when only one person has
    /// it.
    public func named(in text: String) -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return namedLocked(in: text)
    }

    private func namedLocked(in text: String) -> [Int64] {
        let spoken = " " + BrainModel.nameKey(text.replacingOccurrences(of: "'s", with: "")) + " "
        var found: [Int64] = []
        var firsts: [String: [Int64]] = [:]
        for row in rows("SELECT id, key, aliases, kind FROM entity WHERE kind != 'me' AND id IN (SELECT entity FROM memory WHERE archived = 0)", []) {
            guard let id = Int64(row[0]) else { continue }
            let names = [row[1]] + row[2].split(separator: "\n").map(String.init)
            if names.contains(where: { $0.count > 2 && spoken.contains(" \($0) ") }) {
                found.append(id)
            } else if row[3] == "person", let first = row[1].split(separator: " ").first.map(String.init), first.count > 2 {
                firsts[first, default: []].append(id)
            }
        }
        for (first, ids) in firsts where ids.count == 1 && spoken.contains(" \(first) ") && !found.contains(ids[0]) {
            found.append(ids[0])
        }
        return found
    }

    /// Forgets one memory for good.
    public func forget(memory id: Int64) {
        lock.lock(); defer { lock.unlock() }
        if let text = rows("SELECT text, origin FROM memory WHERE id = ?", [id]).first {
            log("forgot", text[0], BrainModel.Origin(rawValue: text[1]), at: Date().timeIntervalSince1970)
        }
        exec("DELETE FROM memory WHERE id = ?", [id])
    }

    /// Forgets everything about an entity.
    public func forget(entity id: Int64) {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM entity WHERE id = ?", [id])
    }

    /// Forgets all a source taught Murmur, and what it had seen there (turning a source off).
    public func forget(origin: BrainModel.Origin) {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM memory WHERE origin = ?", [origin.rawValue])
        exec("DELETE FROM item WHERE source = ?", [origin.rawValue])
        exec("DELETE FROM entity WHERE id NOT IN (SELECT entity FROM memory)")
    }

    /// Forgets everything.
    public func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        for table in ["memory", "entity", "item", "change"] { exec("DELETE FROM \(table)") }
        exec("INSERT INTO memory_fts(memory_fts) VALUES('rebuild')")
    }

    // MARK: Keeping it current

    /// Archives what's stale: expired events and tasks, and memories that faded below `BrainModel.staleBelow`
    /// because no source has said them for long. Returns how many.
    @discardableResult
    public func tidy(now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        let at = now.timeIntervalSince1970
        var stale: [(Int64, String, String)] = []
        for row in rows("""
            SELECT id, entity, text, kind, slot, confidence, created, confirmed, expires, pinned, origin FROM memory
            WHERE archived = 0 AND pinned = 0
            """, []) {
            guard let memory = memoryRow(row), BrainModel.isStale(memory, now: now) else { continue }
            stale.append((memory.id, memory.text, row[10]))
        }
        guard !stale.isEmpty else { return 0 }
        exec("BEGIN")
        for (id, text, origin) in stale {
            exec("UPDATE memory SET archived = 1 WHERE id = ?", [id])
            log("faded", text, BrainModel.Origin(rawValue: origin), at: at)
        }
        // Archived for a year, or replaced for 90 days: gone.
        exec("DELETE FROM memory WHERE archived = 1 AND ((replaced_by IS NOT NULL AND confirmed < ?) OR confirmed < ?)",
             [at - 90 * 86400, at - 365 * 86400])
        exec("DELETE FROM entity WHERE id NOT IN (SELECT entity FROM memory)")
        exec("COMMIT")
        return stale.count
    }

    // MARK: Source items

    /// Which of a source's items are new or changed since Murmur last saw them (by their content's hash), and forgets
    /// what came from items no longer there (deleted at the source). Returns the keys to read.
    public func changed(source: String, items: [String: (hash: String, title: String)], complete: Bool,
                        now: Date = Date()) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var known: [String: String] = [:]
        for row in rows("SELECT external, hash FROM item WHERE source = ?", [source]) { known[row[0]] = row[1] }
        let fresh = Set(items.compactMap { key, value in known[key] == value.hash ? nil : key })
        exec("BEGIN")
        for (key, value) in items {
            exec("""
                INSERT INTO item(source, external, hash, title, seen) VALUES(?,?,?,?,?)
                ON CONFLICT(source, external) DO UPDATE SET seen = excluded.seen, title = excluded.title
                """, [source, key, known[key] == value.hash ? value.hash : "", value.title, now.timeIntervalSince1970])
            // Still there and unchanged: the source still says what it said, so its memories don't fade.
            if known[key] == value.hash {
                exec("UPDATE memory SET confirmed = ? WHERE item = ? AND archived = 0",
                     [now.timeIntervalSince1970, "\(source):\(key)"])
            }
        }
        // A full listing (all of a source's items, not just the latest few): what's gone from it was deleted there.
        if complete {
            for key in Set(known.keys).subtracting(items.keys) {
                let item = "\(source):\(key)"
                for text in rows("SELECT text FROM memory WHERE item = ? AND pinned = 0", [item]) {
                    log("forgot", "\(text[0]) (deleted in \(source))", BrainModel.Origin(rawValue: source), at: now.timeIntervalSince1970)
                }
                exec("DELETE FROM memory WHERE item = ? AND pinned = 0", [item])
                exec("DELETE FROM item WHERE source = ? AND external = ?", [source, key])
            }
            exec("DELETE FROM entity WHERE id NOT IN (SELECT entity FROM memory)")
        }
        exec("COMMIT")
        return fresh
    }

    /// An item has been read: its hash is kept, so it isn't read again until it changes.
    public func read(source: String, key: String, hash: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        exec("UPDATE item SET hash = ?, read = ? WHERE source = ? AND external = ?", [hash, now.timeIntervalSince1970, source, key])
    }

    /// Before an item that changed is read again, what it said before goes: what it says now replaces it.
    public func clear(item: String) {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM memory WHERE item = ? AND pinned = 0", [item])
    }

    // MARK: Sources

    public struct SourceState: Sendable, Equatable {
        public var enabled: Bool
        public var lastSync: Date?
        public var status: String
        public var items: Int
    }

    public func source(_ name: String, enabledByDefault: Bool) -> SourceState {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows("SELECT enabled, last_sync, status, items FROM source WHERE name = ?", [name]).first else {
            return SourceState(enabled: enabledByDefault, lastSync: nil, status: "", items: 0)
        }
        return SourceState(enabled: row[0] == "1", lastSync: Double(row[1]).map { Date(timeIntervalSince1970: $0) },
                           status: row[2], items: Int(row[3]) ?? 0)
    }

    public func setSource(_ name: String, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        exec("INSERT INTO source(name, enabled) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET enabled = excluded.enabled",
             [name, enabled ? 1 : 0])
    }

    public func synced(_ name: String, status: String, items: Int?, enabled: Bool, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        exec("""
            INSERT INTO source(name, enabled, last_sync, status, items) VALUES(?,?,?,?,?)
            ON CONFLICT(name) DO UPDATE SET last_sync = excluded.last_sync, status = excluded.status,
              items = coalesce(?, source.items)
            """, [name, enabled ? 1 : 0, now.timeIntervalSince1970, status, items ?? 0, items])
    }

    // MARK: Lately

    public struct Change: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let at: Date
        /// "learned", "updated", "faded", "forgot".
        public let what: String
        public let text: String
        public let origin: BrainModel.Origin?
    }

    public func changes(limit: Int = 30) -> [Change] {
        lock.lock(); defer { lock.unlock() }
        return rows("SELECT id, at, what, text, origin FROM change ORDER BY id DESC LIMIT ?", [limit]).compactMap { row in
            guard let id = Int64(row[0]) else { return nil }
            return Change(id: id, at: Date(timeIntervalSince1970: Double(row[1]) ?? 0), what: row[2], text: row[3],
                          origin: BrainModel.Origin(rawValue: row[4]))
        }
    }

    /// How much is known: current memories and the entities they're about.
    public func counts() -> (memories: Int, entities: Int) {
        lock.lock(); defer { lock.unlock() }
        let memories = Int(rows("SELECT count(*) FROM memory WHERE archived = 0", []).first?.first ?? "") ?? 0
        let entities = Int(rows("SELECT count(DISTINCT entity) FROM memory WHERE archived = 0", []).first?.first ?? "") ?? 0
        return (memories, entities)
    }

    private func log(_ what: String, _ text: String, _ origin: BrainModel.Origin?, at: Double) {
        exec("INSERT INTO change(at, what, text, origin) VALUES(?,?,?,?)", [at, what, String(text.prefix(300)), origin?.rawValue])
    }

    // MARK: SQLite

    private func bind(_ statement: OpaquePointer?, _ values: [Any?]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .none: sqlite3_bind_null(statement, position)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            case let number as Double: sqlite3_bind_double(statement, position, number)
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            case let some?: sqlite3_bind_text(statement, position, "\(some)", -1, transient)
            }
        }
    }

    @discardableResult
    private func exec(_ sql: String, _ values: [Any?] = []) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    @discardableResult
    private func insert(_ sql: String, _ values: [Any?]) -> Int64 {
        exec(sql, values)
        return db.map(sqlite3_last_insert_rowid) ?? 0
    }

    private func rows(_ sql: String, _ values: [Any?]) -> [[String]] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var out: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            out.append((0..<count).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }
}
