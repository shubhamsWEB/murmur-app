import Foundation

/// The structure under screen memory, in brain.sqlite beside the snapshots and the living memory:
///
/// - sighting: one stay in one window (when it began and ended), so the day is a timeline, not only a set of pages;
/// - item: what windows held, read by rules (`ItemReader`): flights, releases, issues, emails, sent messages, files,
///   pages; each once, however often seen, with the windows it was in;
/// - episode: a stretch of one piece of work (`Episodes`), with what the model later made of it (a title, what it was
///   for, how it ended, what came of it);
/// - edge: how the living memory's entities are connected, and since when ("you worked on Murmur", "Priya is in the
///   Acme project"), each with the episodes that show it.
///
/// What's derived points back to what it came from, so it can always be checked and rebuilt.
public final class MemoryGraph: @unchecked Sendable {
    let db: SQLiteConnection

    public init(url: URL = BrainStore.defaultURL) {
        db = SQLiteConnection(url: url)
        // The first version kept its items in a table named "item", a name the living memory's sources already use: its
        // tables were never made, and its triggers landed on the sources' table (where every write then failed). Gone.
        for trigger in ["item_ai", "item_ad", "item_au"]
        where db.rows("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?", [trigger]).first?.first?.contains("item_fts") == true {
            db.exec("DROP TRIGGER IF EXISTS \(trigger)")
        }
        db.exec("DROP TABLE IF EXISTS item_fts")
        db.exec("DROP TABLE IF EXISTS item_snapshot")
        for statement in [
            """
            CREATE TABLE IF NOT EXISTS sighting(id INTEGER PRIMARY KEY, snapshot INTEGER NOT NULL, start REAL NOT NULL,
              end REAL NOT NULL, app TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', domain TEXT NOT NULL DEFAULT '',
              kind TEXT NOT NULL DEFAULT '', episode INTEGER, synthetic INTEGER NOT NULL DEFAULT 0)
            """,
            "CREATE INDEX IF NOT EXISTS sighting_start ON sighting(start)",
            "CREATE INDEX IF NOT EXISTS sighting_episode ON sighting(episode)",
            "CREATE INDEX IF NOT EXISTS sighting_snapshot ON sighting(snapshot)",
            """
            CREATE TABLE IF NOT EXISTS screen_item(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
              title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', actor TEXT NOT NULL DEFAULT '', project TEXT NOT NULL DEFAULT '',
              people TEXT NOT NULL DEFAULT '', at REAL, fields TEXT NOT NULL DEFAULT '{}', mine INTEGER NOT NULL DEFAULT 0,
              first REAL NOT NULL, last REAL NOT NULL, seen INTEGER NOT NULL DEFAULT 1, used INTEGER NOT NULL DEFAULT 0)
            """,
            "CREATE INDEX IF NOT EXISTS screen_item_kind ON screen_item(kind, at)",
            "CREATE TABLE IF NOT EXISTS screen_item_snapshot(item INTEGER NOT NULL, snapshot INTEGER NOT NULL, PRIMARY KEY(item, snapshot))",
            "CREATE INDEX IF NOT EXISTS screen_item_snapshot_at ON screen_item_snapshot(snapshot)",
            // Each window's own reading of a flight: its fields are what most windows agree on.
            """
            CREATE TABLE IF NOT EXISTS screen_item_reading(item INTEGER NOT NULL, snapshot INTEGER NOT NULL, fields TEXT NOT NULL,
              PRIMARY KEY(item, snapshot))
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS screen_item_fts USING fts5(title, body, content='screen_item', content_rowid='id',
              tokenize='unicode61 remove_diacritics 2')
            """,
            """
            CREATE TRIGGER IF NOT EXISTS screen_item_ai AFTER INSERT ON screen_item BEGIN
              INSERT INTO screen_item_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS screen_item_ad AFTER DELETE ON screen_item BEGIN
              INSERT INTO screen_item_fts(screen_item_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS screen_item_au AFTER UPDATE OF title, body ON screen_item BEGIN
              INSERT INTO screen_item_fts(screen_item_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
              INSERT INTO screen_item_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END
            """,
            """
            CREATE TABLE IF NOT EXISTS episode(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, start REAL NOT NULL,
              end REAL NOT NULL, seconds REAL NOT NULL, context TEXT NOT NULL, project TEXT NOT NULL DEFAULT '',
              apps TEXT NOT NULL DEFAULT '', titles TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'provisional',
              title TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '', outcome TEXT NOT NULL DEFAULT '',
              read INTEGER NOT NULL DEFAULT 0, read_at REAL)
            """,
            "CREATE INDEX IF NOT EXISTS episode_start ON episode(start)",
            "CREATE INDEX IF NOT EXISTS episode_read ON episode(state, read)",
            "CREATE TABLE IF NOT EXISTS episode_item(episode INTEGER NOT NULL, item INTEGER NOT NULL, PRIMARY KEY(episode, item))",
            "CREATE INDEX IF NOT EXISTS episode_item_item ON episode_item(item)",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS episode_fts USING fts5(title, summary, titles, project, content='episode',
              content_rowid='id', tokenize='unicode61 remove_diacritics 2')
            """,
            """
            CREATE TRIGGER IF NOT EXISTS episode_ai AFTER INSERT ON episode BEGIN
              INSERT INTO episode_fts(rowid, title, summary, titles, project) VALUES (new.id, new.title, new.summary, new.titles, new.project); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS episode_ad AFTER DELETE ON episode BEGIN
              INSERT INTO episode_fts(episode_fts, rowid, title, summary, titles, project)
              VALUES ('delete', old.id, old.title, old.summary, old.titles, old.project); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS episode_au AFTER UPDATE OF title, summary, titles, project ON episode BEGIN
              INSERT INTO episode_fts(episode_fts, rowid, title, summary, titles, project)
              VALUES ('delete', old.id, old.title, old.summary, old.titles, old.project);
              INSERT INTO episode_fts(rowid, title, summary, titles, project) VALUES (new.id, new.title, new.summary, new.titles, new.project); END
            """,
            """
            CREATE TABLE IF NOT EXISTS edge(src INTEGER NOT NULL, rel TEXT NOT NULL, dst INTEGER NOT NULL, first REAL NOT NULL,
              last REAL NOT NULL, weight REAL NOT NULL DEFAULT 1, evidence TEXT NOT NULL DEFAULT '', PRIMARY KEY(src, rel, dst))
            """,
            "CREATE INDEX IF NOT EXISTS edge_dst ON edge(dst)",
            "CREATE TABLE IF NOT EXISTS graph_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        ] { db.exec(statement) }
        createThreadTables()
        // Added later: fails harmlessly once it's there. 1: never sent to Claude or OpenAI (money, health, identity).
        db.exec("ALTER TABLE episode ADD COLUMN private INTEGER NOT NULL DEFAULT 0")
    }

    // MARK: State

    func state(_ key: String) -> String? { db.rows("SELECT value FROM graph_state WHERE key = ?", [key]).first?.first }
    func setState(_ key: String, _ value: String) {
        db.exec("INSERT INTO graph_state(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }

    // MARK: Sightings

    /// The user is in this window from `at`: a new sighting, or the last one going on (the same window again within
    /// two and a half minutes: read again while the user stays, a title flickering, a tab switched and back).
    @discardableResult
    public func sighted(snapshot: Int64, at: Date, app: String, title: String, domain: String, kind: String) -> Int64 {
        let time = at.timeIntervalSince1970
        if let row = db.rows("SELECT id, snapshot, end FROM sighting ORDER BY start DESC LIMIT 1", []).first,
           let id = Int64(row[0]), Int64(row[1]) == snapshot, time - (Double(row[2]) ?? 0) <= 150 {
            db.exec("UPDATE sighting SET end = max(end, ?) WHERE id = ?", [time, id])
            return id
        }
        return db.insert("INSERT INTO sighting(snapshot, start, end, app, title, domain, kind) VALUES(?,?,?,?,?,?,?)",
                         [snapshot, time, time, app, ScreenText.cleanTitle(title), domain, kind])
    }

    /// The user left the window (or is still in it) at `at`: the sighting lasts until then.
    public func stayed(_ sighting: Int64, until at: Date) {
        db.exec("UPDATE sighting SET end = max(end, ?) WHERE id = ?", [at.timeIntervalSince1970, sighting])
    }

    /// Windows kept before sightings existed get one each (when first seen, for as long as they were looked at), so the
    /// days already kept have a timeline too. Once.
    public func backfill(from journal: Journal, days: Double = 14, now: Date = Date()) -> Int {
        guard state("backfilled") == nil else { return 0 }
        defer { setState("backfilled", "1") }
        guard (Int(db.rows("SELECT count(*) FROM sighting", []).first?.first ?? "0") ?? 0) == 0 else { return 0 }
        let windows = journal.snapshots(from: now.addingTimeInterval(-days * 86400), to: now, limit: 20_000)
        for window in windows {
            let span = max(5, min(window.seconds, window.last.timeIntervalSince(window.first) + 5))
            db.exec("INSERT INTO sighting(snapshot, start, end, app, title, domain, kind, synthetic) VALUES(?,?,?,?,?,?,?,1)",
                    [window.id, window.first.timeIntervalSince1970, window.first.timeIntervalSince1970 + span, window.app,
                     window.title, window.domain, window.kind])
        }
        return windows.count
    }

    // MARK: Items

    /// Reads the windows changed since the last time into items. Returns how many items were new.
    @discardableResult
    public func readItems(from journal: Journal, me: [String], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let since = Double(state("items-through") ?? "0") ?? 0
        let windows = journal.snapshots(from: Date(timeIntervalSince1970: max(since, now.timeIntervalSince1970 - 14 * 86400)),
                                        to: now.addingTimeInterval(60), limit: 20_000)
            .filter { $0.last.timeIntervalSince1970 >= since }
        var added = 0
        for window in windows {
            for item in ItemReader.read(window, me: me, calendar: calendar) {
                if store(item, snapshot: window.id, seen: window.last, calendar: calendar) { added += 1 }
            }
        }
        setState("items-through", String(now.timeIntervalSince1970 - 1))
        return added
    }

    /// Keeps an item (the latest reading of it wins, the first sighting stays). True when it's new.
    @discardableResult
    public func store(_ item: MemoryItem, snapshot: Int64, seen: Date, calendar: Calendar = .current) -> Bool {
        let at = seen.timeIntervalSince1970
        let fields = (try? JSONSerialization.data(withJSONObject: item.fields, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let id: Int64
        let new: Bool
        if let row = db.rows("SELECT id FROM screen_item WHERE key = ?", [item.key]).first, let existing = Int64(row[0]) {
            db.exec("""
                UPDATE screen_item SET title = ?, body = ?, actor = ?, project = ?, people = ?, at = coalesce(?, at), fields = ?,
                  mine = max(mine, ?), last = max(last, ?), seen = seen + 1 WHERE id = ?
                """, [item.title, item.body, item.actor, item.project, item.people.joined(separator: "\n"),
                      item.when?.timeIntervalSince1970, fields, item.mine, at, existing])
            id = existing
            new = false
        } else {
            id = db.insert("""
                INSERT INTO screen_item(key, kind, title, body, actor, project, people, at, fields, mine, first, last)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """, [item.key, item.kind.rawValue, item.title, item.body, item.actor, item.project,
                      item.people.joined(separator: "\n"), item.when?.timeIntervalSince1970, fields, item.mine, at, at])
            guard id != 0 else { return false }   // not kept: not counted, not linked
            new = true
        }
        db.exec("INSERT OR IGNORE INTO screen_item_snapshot(item, snapshot) VALUES(?, ?)", [id, snapshot])
        if item.kind == .flight { agree(flight: id, snapshot: snapshot, fields: fields, calendar: calendar) }
        return new
    }

    /// A flight's fields as most of the windows that showed it say (a page laid out oddly reads the transfer's time
    /// as the departure; the itinerary, the boarding pass and the check-in page agree on the real one).
    func agree(flight id: Int64, snapshot: Int64, fields json: String, calendar: Calendar) {
        db.exec("INSERT OR REPLACE INTO screen_item_reading(item, snapshot, fields) VALUES(?,?,?)", [id, snapshot, json])
        let readings = db.rows("SELECT fields FROM screen_item_reading WHERE item = ? ORDER BY rowid", [id]).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0[0].utf8))) as? [String: String]
        }
        guard readings.count > 1 else { return }
        var merged: [String: String] = [:]
        let keys = Set(readings.flatMap(\.keys))
        for key in keys {
            var votes: [String: Int] = [:], last: [String: Int] = [:]
            for (index, reading) in readings.enumerated() { if let value = reading[key] { votes[value, default: 0] += 1; last[value] = index } }
            // The departure decides the day and time; every other field follows the same majority, the latest on a tie.
            if let best = votes.max(by: { $0.value == $1.value ? (last[$0.key] ?? 0) < (last[$1.key] ?? 0) : $0.value < $1.value }) {
                merged[key] = best.key
            }
        }
        // Arrival and deadlines only as the readings that agree on the departure have them.
        let agreeing = readings.filter { $0["departs"] == merged["departs"] }
        for key in ["arrives", "arrival time", "check-in closes", "check-in opens", "boarding"] {
            merged[key] = ItemReader.majority(agreeing.compactMap { $0[key] })
        }
        guard let departs = merged["departs"].flatMap({ ScreenDates.formatter("yyyy-MM-dd HH:mm", calendar).date(from: $0) }) else { return }
        let (title, body) = ItemReader.flightText(merged, calendar: calendar)
        let text = (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? json
        db.exec("UPDATE screen_item SET title = ?, body = ?, fields = ?, at = ? WHERE id = ?",
                [title, body, text, departs.timeIntervalSince1970, id])
    }

    public struct StoredItem: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let item: MemoryItem
        public let first: Date
        public let last: Date
    }

    static let itemColumns = "id, key, kind, title, body, actor, project, people, at, fields, mine, first, last"

    func storedItem(_ row: [String]) -> StoredItem? {
        guard row.count >= 13, let id = Int64(row[0]), let kind = MemoryItem.Kind(rawValue: row[2]) else { return nil }
        let fields = (try? JSONSerialization.jsonObject(with: Data(row[9].utf8))) as? [String: String] ?? [:]
        let item = MemoryItem(kind: kind, key: row[1], title: row[3], body: row[4], actor: row[5], project: row[6],
                              people: row[7].split(separator: "\n").map(String.init),
                              when: Double(row[8]).map { Date(timeIntervalSince1970: $0) }, fields: fields, mine: row[10] == "1")
        return StoredItem(id: id, item: item, first: Date(timeIntervalSince1970: Double(row[11]) ?? 0),
                          last: Date(timeIntervalSince1970: Double(row[12]) ?? 0))
    }

    /// Items of some kinds, the latest first (by when they happen, else when seen).
    public func items(_ kinds: [MemoryItem.Kind], limit: Int = 20) -> [StoredItem] {
        guard !kinds.isEmpty else { return [] }
        return db.rows("""
            SELECT \(Self.itemColumns) FROM screen_item WHERE kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))
            ORDER BY coalesce(at, last) DESC LIMIT ?
            """, kinds.map { $0.rawValue as Any? } + [limit]).compactMap(storedItem)
    }

    /// What's coming up from items (flights, bookings), soonest first. A connecting flight is part of its journey, not
    /// a trip of its own.
    public func upcoming(now: Date = Date(), limit: Int = 10) -> [StoredItem] {
        let coming = db.rows("""
            SELECT \(Self.itemColumns) FROM screen_item WHERE kind IN ('flight', 'booking') AND at >= ? ORDER BY at LIMIT ?
            """, [now.timeIntervalSince1970 - 3 * 3600, limit * 2]).compactMap(storedItem)
        let legs = Set(coming.flatMap { ($0.item.fields["connecting"] ?? "").components(separatedBy: ", ") }.filter { !$0.isEmpty })
        return Array(coming.filter { !legs.contains($0.item.fields["number"] ?? "") }.prefix(limit))
    }

    /// Whether a text names a flight that's the connection of another ("Check-in closes for 6E 7575").
    public func isConnectingFlight(in text: String) -> Bool {
        let legs = items([.flight], limit: 50).flatMap { ($0.item.fields["connecting"] ?? "").components(separatedBy: ", ") }
            .filter { !$0.isEmpty }
        return legs.contains { text.contains($0) }
    }

    /// Items whose words match, best first.
    public func searchItems(_ query: String, limit: Int = 8) -> [StoredItem] {
        guard let match = Self.match(query) else { return [] }
        return db.rows("""
            SELECT i.id, i.key, i.kind, i.title, i.body, i.actor, i.project, i.people, i.at, i.fields, i.mine, i.first, i.last
            FROM screen_item_fts f JOIN screen_item i ON i.id = f.rowid WHERE screen_item_fts MATCH ? ORDER BY bm25(screen_item_fts) LIMIT ?
            """, [match, limit]).compactMap(storedItem)
    }

    public func items(ofSnapshots ids: [Int64]) -> [StoredItem] {
        guard !ids.isEmpty else { return [] }
        return db.rows("""
            SELECT DISTINCT i.id, i.key, i.kind, i.title, i.body, i.actor, i.project, i.people, i.at, i.fields, i.mine, i.first, i.last
            FROM screen_item_snapshot s JOIN screen_item i ON i.id = s.item WHERE s.snapshot IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            """, ids.map { $0 as Any? }).compactMap(storedItem)
    }

    public func items(ofEpisode id: Int64) -> [StoredItem] {
        db.rows("""
            SELECT i.id, i.key, i.kind, i.title, i.body, i.actor, i.project, i.people, i.at, i.fields, i.mine, i.first, i.last
            FROM episode_item e JOIN screen_item i ON i.id = e.item WHERE e.episode = ?
            """, [id]).compactMap(storedItem)
    }

    /// Words of a question that say nothing about what it's after.
    static let questionWords: Set<String> = ["what", "when", "where", "which", "who", "whom", "whose", "why", "how", "did",
                                             "does", "the", "and", "for", "was", "were", "are", "you", "your", "about", "tell",
                                             "know", "have", "has", "had", "with", "that", "this", "there", "from", "recently",
                                             "last", "latest", "any", "all", "can", "could", "would", "should", "into", "onto",
                                             "been", "being", "its", "it's", "our", "out", "get", "got", "doing", "done"]

    /// FTS words for a question: its meaningful words, each as a prefix, any of them.
    static func match(_ query: String) -> String? {
        let words = BrainModel.keywords(query).filter { $0.count > 2 && !questionWords.contains($0) && !$0.contains("'") }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        return words.isEmpty ? nil : words.joined(separator: " OR ")
    }

    // MARK: Episodes

    /// Cuts what's new on the timeline into episodes: sightings not in a finished episode yet are cut again with the
    /// unfinished ones (whose cut can still change). Returns the episodes that finished now.
    @discardableResult
    public func segment(now: Date = Date(), calendar: Calendar = .current) -> [Int64] {
        let open = db.rows("SELECT id FROM episode WHERE state = 'provisional'", []).compactMap { Int64($0[0]) }
        let rows = db.rows("""
            SELECT s.id, s.snapshot, s.start, s.end, s.app, s.title, s.domain, s.kind FROM sighting s
            WHERE s.episode IS NULL OR s.episode IN (SELECT id FROM episode WHERE state = 'provisional') ORDER BY s.start
            """, [])
        guard !rows.isEmpty else { return [] }
        // What each window is about, from its items: a project (code, a document's folder, a repository), else who the
        // conversation is with.
        let snapshots = Array(Set(rows.compactMap { Int64($0[1]) }))
        var about: [Int64: (project: String, person: String)] = [:]
        for chunk in stride(from: 0, to: snapshots.count, by: 500) {
            let part = Array(snapshots[chunk..<min(chunk + 500, snapshots.count)])
            for row in db.rows("""
                SELECT s.snapshot, i.kind, i.project, i.people FROM screen_item_snapshot s JOIN screen_item i ON i.id = s.item
                WHERE s.snapshot IN (\(part.map { _ in "?" }.joined(separator: ",")))
                """, part.map { $0 as Any? }) {
                guard let id = Int64(row[0]) else { continue }
                var value = about[id] ?? ("", "")
                if value.project.isEmpty, !row[2].isEmpty, row[1] != "page" { value.project = row[2] }
                if value.person.isEmpty, row[1] == "message" || row[1] == "email", let person = row[3].split(separator: "\n").first {
                    value.person = String(person)
                }
                about[id] = value
            }
        }
        let sightings = rows.compactMap { row -> Episodes.Sighting? in
            guard let id = Int64(row[0]), let snapshot = Int64(row[1]), let start = Double(row[2]), let end = Double(row[3]) else { return nil }
            let (project, person) = about[snapshot] ?? ("", "")
            let core = project.isEmpty ? "" : BrainModel.projectCore(project)
            return Episodes.Sighting(id: id, snapshot: snapshot, start: Date(timeIntervalSince1970: start),
                                     end: Date(timeIntervalSince1970: end), app: row[4], title: ScreenText.cleanTitle(row[5]), domain: row[6],
                                     kind: WindowKind(rawValue: row[7]) ?? .app,
                                     context: Episodes.context(project: core, person: person, domain: row[6], app: row[4]),
                                     project: core)
        }
        let cut = Episodes.segment(sightings, now: now)
        for id in open {
            db.exec("DELETE FROM episode_item WHERE episode = ?", [id])
            db.exec("DELETE FROM episode WHERE id = ?", [id])
        }
        var finished: [Int64] = []
        for episode in cut {
            let id = db.insert("""
                INSERT INTO episode(key, start, end, seconds, context, project, apps, titles, state) VALUES(?,?,?,?,?,?,?,?,?)
                ON CONFLICT(key) DO UPDATE SET end = excluded.end, seconds = excluded.seconds, titles = excluded.titles,
                  state = excluded.state
                """, [episode.key, episode.start.timeIntervalSince1970, episode.end.timeIntervalSince1970, episode.seconds,
                      episode.context, episode.project, episode.apps.joined(separator: "\n"),
                      episode.titles.joined(separator: "\n"), episode.final ? "final" : "provisional"])
            _ = id   // an update doesn't give the row's id: looked up by its key
            let episodeID = Int64(db.rows("SELECT id FROM episode WHERE key = ?", [episode.key]).first?.first ?? "0") ?? 0
            guard episodeID != 0 else { continue }
            for chunk in stride(from: 0, to: episode.sightings.count, by: 500) {
                let part = Array(episode.sightings[chunk..<min(chunk + 500, episode.sightings.count)])
                db.exec("UPDATE sighting SET episode = ? WHERE id IN (\(part.map { _ in "?" }.joined(separator: ",")))",
                        [episodeID as Any?] + part.map { $0 as Any? })
            }
            for item in items(ofSnapshots: episode.snapshots) {
                db.exec("INSERT OR IGNORE INTO episode_item(episode, item) VALUES(?, ?)", [episodeID, item.id])
            }
            if episode.final { finished.append(episodeID) }
        }
        return finished
    }

    public struct StoredEpisode: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let start: Date
        public let end: Date
        public let seconds: Double
        public let context: String
        public let project: String
        public let apps: [String]
        public let titles: [String]
        public let final: Bool
        public let title: String
        public let summary: String
        public let outcome: String
        public let read: Bool

        /// What to call it: the model's title once it has one, else what it was about.
        public var name: String {
            if !title.isEmpty { return title }
            if !project.isEmpty { return "Working on \(project)" }
            let parts = context.split(separator: ":", maxSplits: 1).map(String.init)
            let first = titles.first.map(ScreenText.cleanTitle)
            if parts.count == 2 {
                switch parts[0] {
                case "person": return "Talking to \(parts[1].capitalized)"
                case "site": return first.map(ItemReader.pageTitle) ?? parts[1]
                case "app" where ["claude", "chatgpt", "gemini", "perplexity"].contains(parts[1]): return "Working with \(parts[1].capitalized)"
                default: return first.flatMap { $0.lowercased() == parts[1] ? nil : $0 } ?? "Using \(parts[1].capitalized)"
                }
            }
            return first ?? context
        }
    }

    static let episodeColumns = "id, start, end, seconds, context, project, apps, titles, state, title, summary, outcome, read"

    func storedEpisode(_ row: [String]) -> StoredEpisode? {
        guard row.count >= 13, let id = Int64(row[0]) else { return nil }
        return StoredEpisode(id: id, start: Date(timeIntervalSince1970: Double(row[1]) ?? 0),
                             end: Date(timeIntervalSince1970: Double(row[2]) ?? 0), seconds: Double(row[3]) ?? 0,
                             context: row[4], project: row[5], apps: row[6].split(separator: "\n").map(String.init),
                             titles: row[7].split(separator: "\n").map(String.init), final: row[8] == "final",
                             title: row[9], summary: row[10], outcome: row[11], read: row[12] == "1")
    }

    public func episode(id: Int64) -> StoredEpisode? {
        db.rows("SELECT \(Self.episodeColumns) FROM episode WHERE id = ?", [id]).first.flatMap(storedEpisode)
    }

    /// Finished episodes the model hasn't read, the latest first (what you did today is known first), long enough to
    /// say something.
    /// `includePrivate`: false for Claude or OpenAI, which never get what must stay on this Mac.
    public func unread(limit: Int = 20, minimumSeconds: Double = 30, includePrivate: Bool = true) -> [StoredEpisode] {
        db.rows("""
            SELECT \(Self.episodeColumns) FROM episode WHERE state = 'final' AND read = 0 AND seconds >= ?
              AND (? = 1 OR private = 0) ORDER BY start DESC LIMIT ?
            """, [minimumSeconds, includePrivate, limit]).compactMap(storedEpisode)
    }

    /// An episode that must stay on this Mac: only the local model reads it.
    public func markPrivate(_ id: Int64) { db.exec("UPDATE episode SET private = 1 WHERE id = ?", [id]) }

    public func isPrivate(_ id: Int64) -> Bool {
        db.rows("SELECT private FROM episode WHERE id = ?", [id]).first?.first == "1"
    }

    /// Finished episodes too short to say anything (a few seconds in passing): closed without the model. Returns their
    /// windows, which count as read.
    public func closeShort(minimumSeconds: Double = 30) -> [Int64] {
        let ids = db.rows("SELECT id FROM episode WHERE state = 'final' AND read = 0 AND seconds < ?", [minimumSeconds]).compactMap { Int64($0[0]) }
        guard !ids.isEmpty else { return [] }
        var windows: [Int64] = []
        for chunk in stride(from: 0, to: ids.count, by: 500) {
            let part = Array(ids[chunk..<min(chunk + 500, ids.count)])
            let marks = part.map { _ in "?" }.joined(separator: ",")
            windows += db.rows("SELECT DISTINCT snapshot FROM sighting WHERE episode IN (\(marks))", part.map { $0 as Any? }).compactMap { Int64($0[0]) }
            db.exec("UPDATE episode SET read = 1, read_at = ? WHERE id IN (\(marks))", [Date().timeIntervalSince1970 as Any?] + part.map { $0 as Any? })
        }
        return windows
    }

    public func unreadCount(includePrivate: Bool = true) -> Int {
        Int(db.rows("SELECT count(*) FROM episode WHERE state = 'final' AND read = 0 AND seconds >= 30 AND (? = 1 OR private = 0)",
                    [includePrivate]).first?.first ?? "0") ?? 0
    }

    /// Episodes overlapping a span, in order.
    public func episodes(from: Date, to: Date, limit: Int = 200) -> [StoredEpisode] {
        db.rows("""
            SELECT \(Self.episodeColumns) FROM episode WHERE end >= ? AND start < ? ORDER BY start LIMIT ?
            """, [from.timeIntervalSince1970, to.timeIntervalSince1970, limit]).compactMap(storedEpisode)
    }

    /// The latest episodes (the Memory page: what you worked on).
    public func recentEpisodes(limit: Int = 12, minimumSeconds: Double = 60) -> [StoredEpisode] {
        db.rows("SELECT \(Self.episodeColumns) FROM episode WHERE seconds >= ? ORDER BY start DESC LIMIT ?",
                [minimumSeconds, limit]).compactMap(storedEpisode)
    }

    /// Episodes whose words match, best first.
    public func searchEpisodes(_ query: String, limit: Int = 6) -> [StoredEpisode] {
        guard let match = Self.match(query) else { return [] }
        return db.rows("""
            SELECT e.id, e.start, e.end, e.seconds, e.context, e.project, e.apps, e.titles, e.state, e.title, e.summary,
              e.outcome, e.read FROM episode_fts f JOIN episode e ON e.id = f.rowid WHERE episode_fts MATCH ?
            ORDER BY bm25(episode_fts, 4.0, 2.0, 1.0, 3.0) LIMIT ?
            """, [match, limit]).compactMap(storedEpisode)
    }

    public func episodes(ofProject core: String, limit: Int = 10) -> [StoredEpisode] {
        db.rows("SELECT \(Self.episodeColumns) FROM episode WHERE project = ? ORDER BY start DESC LIMIT ?",
                [core, limit]).compactMap(storedEpisode)
    }

    /// The snapshots (windows) an episode was in, most time first.
    public func snapshots(ofEpisode id: Int64) -> [(snapshot: Int64, seconds: Double)] {
        db.rows("""
            SELECT snapshot, sum(end - start) FROM sighting WHERE episode = ? GROUP BY snapshot ORDER BY sum(end - start) DESC
            """, [id]).compactMap { row in Int64(row[0]).map { ($0, Double(row[1]) ?? 0) } }
    }

    /// What the model made of an episode (or that it needed none: `title` empty).
    public func setRead(_ id: Int64, title: String, summary: String, outcome: String, now: Date = Date()) {
        db.exec("UPDATE episode SET title = ?, summary = ?, outcome = ?, read = 1, read_at = ? WHERE id = ?",
                [title, summary, outcome, now.timeIntervalSince1970, id])
    }

    /// Every episode to be read again (the rules for reading them changed).
    public func readAgain() { db.exec("UPDATE episode SET read = 0") }

    /// Items, episodes and connections made again from the timeline (it stays): after the rules for them changed.
    public func rebuild() {
        for table in ["episode_item", "edge", "screen_item_snapshot", "screen_item_reading"] { db.exec("DELETE FROM \(table)") }
        db.exec("DELETE FROM episode")
        db.exec("DELETE FROM screen_item")
        db.exec("INSERT INTO episode_fts(episode_fts) VALUES('rebuild')")
        db.exec("INSERT INTO screen_item_fts(screen_item_fts) VALUES('rebuild')")
        db.exec("UPDATE sighting SET episode = NULL")
        db.exec("DELETE FROM graph_state WHERE key = 'items-through'")
        db.exec("DELETE FROM vector WHERE kind = 'episode'")
    }

    // MARK: Edges

    public struct Edge: Sendable, Equatable {
        public let src: Int64
        public let rel: String
        public let dst: Int64
        public let first: Date
        public let last: Date
        public let weight: Double
    }

    /// Two entities connected ("worked_on", "released", "talked_with", "involved_in", "booked"): seen again, the edge
    /// grows heavier and later; the episode is its evidence.
    public func connect(_ src: Int64, _ rel: String, _ dst: Int64, at: Date, weight: Double = 1, evidence: String) {
        guard src != dst else { return }
        let time = at.timeIntervalSince1970
        db.exec("""
            INSERT INTO edge(src, rel, dst, first, last, weight, evidence) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(src, rel, dst) DO UPDATE SET last = max(last, excluded.last), first = min(first, excluded.first),
              weight = weight + excluded.weight,
              evidence = CASE WHEN instr(evidence, excluded.evidence) > 0 THEN evidence
                ELSE substr(evidence || ',' || excluded.evidence, -400) END
            """, [src, rel, dst, time, time, weight, evidence])
    }

    /// The edges touching an entity, heaviest first.
    public func edges(of entity: Int64, limit: Int = 20) -> [Edge] {
        db.rows("""
            SELECT src, rel, dst, first, last, weight FROM edge WHERE src = ? OR dst = ? ORDER BY weight DESC, last DESC LIMIT ?
            """, [entity, entity, limit]).compactMap { row in
            guard let src = Int64(row[0]), let dst = Int64(row[2]) else { return nil }
            return Edge(src: src, rel: row[1], dst: dst, first: Date(timeIntervalSince1970: Double(row[3]) ?? 0),
                        last: Date(timeIntervalSince1970: Double(row[4]) ?? 0), weight: Double(row[5]) ?? 0)
        }
    }

    /// An entity's name and kind (the living memory's table, in the same file).
    public func entityName(_ id: Int64) -> (name: String, kind: String)? {
        db.rows("SELECT name, kind FROM entity WHERE id = ?", [id]).first.map { ($0[0], $0[1]) }
    }

    // MARK: Housekeeping

    public func counts() -> (sightings: Int, items: Int, episodes: Int, unread: Int, edges: Int) {
        func count(_ sql: String) -> Int { Int(db.rows(sql, []).first?.first ?? "0") ?? 0 }
        return (count("SELECT count(*) FROM sighting"), count("SELECT count(*) FROM screen_item"), count("SELECT count(*) FROM episode"),
                unreadCount(), count("SELECT count(*) FROM edge"))
    }

    /// Sightings after 30 days (episodes keep their span), pages seen once after 30 days, links to windows gone.
    public func prune(now: Date = Date()) {
        let at = now.timeIntervalSince1970
        db.exec("DELETE FROM sighting WHERE end < ?", [at - 30 * 86400])
        db.exec("DELETE FROM screen_item WHERE kind = 'page' AND last < ? AND seen <= 1", [at - 30 * 86400])
        db.exec("DELETE FROM screen_item_snapshot WHERE snapshot NOT IN (SELECT id FROM snapshot)")
        db.exec("DELETE FROM episode_item WHERE item NOT IN (SELECT id FROM screen_item)")
        db.exec("DELETE FROM edge WHERE src NOT IN (SELECT id FROM entity) OR dst NOT IN (SELECT id FROM entity)")
    }

    /// Forgets everything seen on screen.
    public func forgetAll() {
        for table in ["sighting", "screen_item", "screen_item_snapshot", "episode", "episode_item", "edge", "graph_state",
                      "thread", "thread_item", "screen_item_reading"] {
            db.exec("DELETE FROM \(table)")
        }
        db.exec("INSERT INTO screen_item_fts(screen_item_fts) VALUES('rebuild')")
        db.exec("INSERT INTO episode_fts(episode_fts) VALUES('rebuild')")
    }

    /// Forgets what was seen in one app or on one site.
    public func forget(app: String) {
        db.exec("DELETE FROM sighting WHERE app = ? OR domain = ?", [app, app])
    }
}
