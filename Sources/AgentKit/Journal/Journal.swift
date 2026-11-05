import Foundation
import SQLite3

/// What Murmur saw you work on, and what came of it: in the same file as the living memory (brain.sqlite), written by
/// the screen-memory helper (`murmur-memory`) and read by the app.
///
/// - snapshot: the text of a window you worked in (its app, title, address and site), once per distinct content: seeing
///   it again only adds to how long and how often. Read into memories, then kept two weeks for "what was that…".
/// - ledger: seconds per hour in each app and site, for "where did my time go".
/// - loop: an open loop, something promised: by you ("I'll send the deck Friday") or to you ("Priya will review it"),
///   with the snapshots that show it, until the evidence shows it's done.
/// - chronicle: what you did, an hour, a day, a month and a year at a time.
/// - nudge: a brief or reminder Murmur showed, so each is shown once.
public final class Journal: @unchecked Sendable {
    private let db: SQLiteConnection

    public init(url: URL = BrainStore.defaultURL) {
        db = SQLiteConnection(url: url)
        for statement in [
            """
            CREATE TABLE IF NOT EXISTS snapshot(id INTEGER PRIMARY KEY, app TEXT NOT NULL, bundle TEXT NOT NULL DEFAULT '',
              title TEXT NOT NULL DEFAULT '', url TEXT, domain TEXT NOT NULL DEFAULT '', text TEXT NOT NULL,
              hash TEXT NOT NULL, via TEXT NOT NULL DEFAULT 'text', labels TEXT NOT NULL DEFAULT '', first REAL NOT NULL,
              last REAL NOT NULL, seconds REAL NOT NULL DEFAULT 0, sightings INTEGER NOT NULL DEFAULT 1,
              consolidated INTEGER NOT NULL DEFAULT 0)
            """,
            "CREATE INDEX IF NOT EXISTS snapshot_pending ON snapshot(consolidated, last)",
            "CREATE INDEX IF NOT EXISTS snapshot_hash ON snapshot(hash)",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS snapshot_fts USING fts5(title, text, content='snapshot', content_rowid='id',
              tokenize='unicode61 remove_diacritics 2')
            """,
            """
            CREATE TRIGGER IF NOT EXISTS snapshot_ai AFTER INSERT ON snapshot BEGIN
              INSERT INTO snapshot_fts(rowid, title, text) VALUES (new.id, new.title, new.text); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS snapshot_ad AFTER DELETE ON snapshot BEGIN
              INSERT INTO snapshot_fts(snapshot_fts, rowid, title, text) VALUES ('delete', old.id, old.title, old.text); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS snapshot_au AFTER UPDATE OF title, text ON snapshot BEGIN
              INSERT INTO snapshot_fts(snapshot_fts, rowid, title, text) VALUES ('delete', old.id, old.title, old.text);
              INSERT INTO snapshot_fts(rowid, title, text) VALUES (new.id, new.title, new.text); END
            """,
            """
            CREATE TABLE IF NOT EXISTS ledger(hour REAL NOT NULL, app TEXT NOT NULL, domain TEXT NOT NULL DEFAULT '',
              seconds REAL NOT NULL DEFAULT 0, PRIMARY KEY(hour, app, domain))
            """,
            """
            CREATE TABLE IF NOT EXISTS loop(id INTEGER PRIMARY KEY, summary TEXT NOT NULL, person TEXT NOT NULL DEFAULT '',
              project TEXT NOT NULL DEFAULT '', mine INTEGER NOT NULL DEFAULT 1, due REAL, status TEXT NOT NULL DEFAULT 'open',
              confidence REAL NOT NULL DEFAULT 0.6, first REAL NOT NULL, last REAL NOT NULL, closed REAL,
              evidence TEXT NOT NULL DEFAULT '', closing TEXT NOT NULL DEFAULT '', origin TEXT NOT NULL DEFAULT 'screen')
            """,
            "CREATE INDEX IF NOT EXISTS loop_status ON loop(status, due)",
            """
            CREATE TABLE IF NOT EXISTS chronicle(level TEXT NOT NULL, period TEXT NOT NULL, summary TEXT NOT NULL,
              generated REAL NOT NULL, PRIMARY KEY(level, period))
            """,
            """
            CREATE TABLE IF NOT EXISTS nudge(key TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
              created REAL NOT NULL, seen REAL)
            """,
        ] { db.exec(statement) }
        // Added later: each fails harmlessly once the column is there.
        for column in ["kind TEXT NOT NULL DEFAULT ''", "authored TEXT NOT NULL DEFAULT ''", "seen_as TEXT NOT NULL DEFAULT ''",
                       "picture TEXT", "read_text TEXT NOT NULL DEFAULT ''"] {
            db.exec("ALTER TABLE snapshot ADD COLUMN \(column)")
        }
        db.exec("ALTER TABLE loop ADD COLUMN kind TEXT NOT NULL DEFAULT 'promised'")
    }

    // MARK: Snapshots

    public struct Capture: Sendable, Equatable {
        public var app: String
        public var bundle: String
        public var title: String
        public var url: String?
        public var text: String
        /// "text" (read through Accessibility) or "image" (read from a picture of the window).
        public var via: String
        public var labels: String
        /// `WindowKind`'s name for it.
        public var kind: String
        /// What the user sent from it since it was last read.
        public var authored: String

        public init(app: String, bundle: String, title: String, url: String? = nil, text: String, via: String = "text",
                    labels: String = "", kind: String = "", authored: String = "") {
            self.app = app
            self.bundle = bundle
            self.title = title
            self.url = url
            self.text = text
            self.via = via
            self.labels = labels
            self.kind = kind
            self.authored = authored
        }

        /// "mail.google.com" for a page's address; "" for an app.
        public var domain: String {
            guard let url, let host = URL(string: url)?.host else { return "" }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        public var hash: String { BrainModel.fingerprint([app, title, text]) }
    }

    public struct Snapshot: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let app: String
        public let title: String
        public let url: String?
        public let domain: String
        public let text: String
        public let first: Date
        public let last: Date
        public let seconds: Double
        public let sightings: Int
        /// What kind of window it was (`WindowKind`): a conversation, your own work, a feed, a product's site…
        public var kind: String = ""
        /// What the user wrote and sent in it ("Sure, I'll send it Thursday"), as seen leaving the message box.
        public var authored: String = ""
        /// What the vision model made of a picture of it ("a product's website showing a demo chat"), once it looked.
        public var seenAs: String = ""
        /// Its text when the model last read it: next time only what's new is read.
        public var readText: String = ""
    }

    /// Keeps what a window showed. The same content seen again (even after looking elsewhere) only counts the time;
    /// returns the snapshot's id and whether it was new.
    @discardableResult
    public func record(_ capture: Capture, seconds: Double = 0, now: Date = Date()) -> (id: Int64, new: Bool) {
        let at = now.timeIntervalSince1970
        let hash = capture.hash
        if let row = db.rows("SELECT id FROM snapshot WHERE hash = ? AND last > ? ORDER BY id DESC LIMIT 1",
                             [hash, at - 6 * 3600]).first, let id = Int64(row[0]) {
            db.exec("""
                UPDATE snapshot SET last = ?, seconds = seconds + ?, sightings = sightings + 1,
                  authored = CASE WHEN ? = '' THEN authored ELSE trim(authored || char(10) || ?) END,
                  consolidated = CASE WHEN ? = '' THEN consolidated ELSE 0 END WHERE id = ?
                """, [at, seconds, capture.authored, capture.authored, capture.authored, id])
            return (id, false)
        }
        // The same window still changing (a chat being written, a page scrolled, a document edited): its latest
        // version replaces the one before, instead of a near-copy each time. Read again into memories if it was read.
        if let row = db.rows("""
            SELECT id, text FROM snapshot WHERE app = ? AND title = ? AND coalesce(url, '') = ? AND last > ?
            ORDER BY id DESC LIMIT 1
            """, [capture.app, capture.title, capture.url ?? "", at - 15 * 60]).first, let id = Int64(row[0]),
           Self.sameWindow(row[1], capture.text) {
            db.exec("""
                UPDATE snapshot SET text = ?, hash = ?, via = ?, labels = ?, last = ?, seconds = seconds + ?,
                  sightings = sightings + 1, consolidated = 0, kind = ?,
                  authored = CASE WHEN ? = '' THEN authored ELSE trim(authored || char(10) || ?) END WHERE id = ?
                """, [capture.text, hash, capture.via, capture.labels, at, seconds, capture.kind, capture.authored,
                      capture.authored, id])
            db.exec("DELETE FROM vector WHERE kind = 'snapshot' AND ref = ?", [id])   // its newer text gets a vector
            return (id, false)
        }
        let id = db.insert("""
            INSERT INTO snapshot(app, bundle, title, url, domain, text, hash, via, labels, first, last, seconds, kind, authored)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [capture.app, capture.bundle, capture.title, capture.url, capture.domain, capture.text, hash, capture.via,
                  capture.labels, at, at, seconds, capture.kind, capture.authored])
        return (id, true)
    }

    /// Whether two readings are the same window's content, changed a little: most of their words in common.
    static func sameWindow(_ before: String, _ after: String) -> Bool {
        let a = BrainModel.keywords(String(before.prefix(8000))), b = BrainModel.keywords(String(after.prefix(8000)))
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.6
    }

    /// Time spent on a snapshot after it was taken (you stayed on that window).
    public func stayed(_ id: Int64, seconds: Double, now: Date = Date()) {
        db.exec("UPDATE snapshot SET seconds = seconds + ?, last = ? WHERE id = ?", [seconds, now.timeIntervalSince1970, id])
    }

    /// Adds time to the hour's ledger for an app (and site).
    public func spend(_ seconds: Double, app: String, domain: String, at: Date = Date()) {
        guard seconds > 0 else { return }
        let hour = (at.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        db.exec("""
            INSERT INTO ledger(hour, app, domain, seconds) VALUES(?,?,?,?)
            ON CONFLICT(hour, app, domain) DO UPDATE SET seconds = seconds + excluded.seconds
            """, [hour, app, domain, seconds])
    }

    /// Everything not read into memories yet (including windows still open and changing), newest first, and how many.
    public func waiting(limit: Int = 8) -> (count: Int, windows: [Snapshot]) {
        let count = Int(db.rows("SELECT count(*) FROM snapshot WHERE consolidated = 0", []).first?.first ?? "") ?? 0
        let windows = db.rows("""
            SELECT id, app, title, url, domain, text, first, last, seconds, sightings, kind, authored, seen_as, read_text FROM snapshot
            WHERE consolidated = 0 ORDER BY last DESC LIMIT ?
            """, [limit]).compactMap(snapshot)
        return (count, windows)
    }

    /// Snapshots not yet read into memories, settled (not seen for `settled` seconds), oldest first.
    public func pending(limit: Int = 40, settled: Double = 90, now: Date = Date()) -> [Snapshot] {
        db.rows("""
            SELECT id, app, title, url, domain, text, first, last, seconds, sightings, kind, authored, seen_as, read_text FROM snapshot
            WHERE consolidated = 0 AND last < ? AND (picture IS NULL OR seen_as != '' OR first < ?) ORDER BY first LIMIT ?
            """, [now.timeIntervalSince1970 - settled, now.timeIntervalSince1970 - 6 * 3600, limit]).compactMap(snapshot)
    }

    // MARK: Pictures (while the vision model hasn't looked yet)

    /// Where pictures wait for the vision model: Application Support/Murmur/Pictures, small JPEGs, gone once seen.
    public static let pictures = BrainStore.defaultURL.deletingLastPathComponent().appendingPathComponent("Pictures")

    /// A window waiting to be looked at gets its picture (wins over an earlier one).
    public func setPicture(_ id: Int64, path: String) {
        if let old = db.rows("SELECT picture FROM snapshot WHERE id = ?", [id]).first?.first, !old.isEmpty, old != path {
            try? FileManager.default.removeItem(atPath: old)
        }
        db.exec("UPDATE snapshot SET picture = ? WHERE id = ?", [path, id])
    }

    public func hasPicture(_ id: Int64) -> Bool {
        !(db.rows("SELECT picture FROM snapshot WHERE id = ? AND picture IS NOT NULL", [id]).first?.first ?? "").isEmpty
    }

    /// Windows with a picture the vision model hasn't seen, those you spent longest in first.
    public func waitingPictures(limit: Int = 10) -> [(snapshot: Snapshot, path: String)] {
        db.rows("""
            SELECT id, app, title, url, domain, text, first, last, seconds, sightings, kind, authored, seen_as, read_text, picture
            FROM snapshot WHERE picture IS NOT NULL AND seen_as = '' ORDER BY seconds DESC LIMIT ?
            """, [limit]).compactMap { row in snapshot(row).map { ($0, row[14]) } }
    }

    /// What the vision model made of a window; its picture goes.
    public func understood(_ id: Int64, seenAs: String, kind: WindowKind?) {
        if let path = db.rows("SELECT picture FROM snapshot WHERE id = ?", [id]).first?.first, !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
        db.exec("UPDATE snapshot SET seen_as = ?, picture = NULL, kind = coalesce(?, kind), consolidated = 0 WHERE id = ?",
                [seenAs.isEmpty ? "-" : seenAs, kind?.rawValue, id])
    }

    /// Pictures older than a day (the vision model never got the chance) and any left without a window.
    public func prunePictures(now: Date = Date()) {
        for row in db.rows("SELECT id, picture FROM snapshot WHERE picture IS NOT NULL AND first < ?", [now.timeIntervalSince1970 - 86400]) {
            try? FileManager.default.removeItem(atPath: row[1])
            db.exec("UPDATE snapshot SET picture = NULL WHERE id = ?", [row[0]])
        }
        let kept = Set(db.rows("SELECT picture FROM snapshot WHERE picture IS NOT NULL", []).map { $0[0] })
        for file in (try? FileManager.default.contentsOfDirectory(atPath: Self.pictures.path)) ?? [] {
            let path = Self.pictures.appendingPathComponent(file).path
            if !kept.contains(path) { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    /// How much the waiting pictures take, in bytes.
    public static func picturesSize() -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Promises taken from the screen (before only conversations could make one).
    /// Loops "with" the user themselves (a promise to yourself read as one to someone else).
    public func forgetLoops(with me: [String]) {
        for row in db.rows("SELECT id, person FROM loop WHERE person != ''", []) {
            if me.contains(where: { Self.samePerson($0, row[1]) }) { db.exec("DELETE FROM loop WHERE id = ?", [row[0]]) }
        }
    }

    public func forgetScreenLoops() {
        db.exec("DELETE FROM loop WHERE origin = 'screen'")
        db.exec("DELETE FROM vector WHERE kind = 'loop' AND ref NOT IN (SELECT id FROM loop)")
    }

    /// Every kept window to be read again (after the rules for reading them changed).
    /// These windows are read again, all of their text.
    public func readAgain(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        db.exec("UPDATE snapshot SET consolidated = 0, read_text = '' WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                ids.map { $0 as Any? })
    }

    public func readAgain() {
        db.exec("UPDATE snapshot SET consolidated = 0, read_text = ''")
    }

    public func consolidated(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        db.exec("UPDATE snapshot SET consolidated = 1, read_text = text WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                ids.map { $0 as Any? })
    }

    public func snapshots(from: Date, to: Date, limit: Int = 400) -> [Snapshot] {
        db.rows("""
            SELECT id, app, title, url, domain, text, first, last, seconds, sightings, kind, authored, seen_as, read_text FROM snapshot
            WHERE last >= ? AND first < ? ORDER BY first LIMIT ?
            """, [from.timeIntervalSince1970, to.timeIntervalSince1970, limit]).compactMap(snapshot)
    }

    /// Snapshots whose words match, newest first: "that pricing page I saw".
    public func search(_ query: String, limit: Int = 10) -> [Snapshot] {
        let words = BrainModel.keywords(query).filter { $0.count > 2 }.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        guard !words.isEmpty else { return [] }
        return db.rows("""
            SELECT s.id, s.app, s.title, s.url, s.domain, s.text, s.first, s.last, s.seconds, s.sightings, s.kind, s.authored, s.seen_as, s.read_text
            FROM snapshot_fts f JOIN snapshot s ON s.id = f.rowid WHERE snapshot_fts MATCH ?
            ORDER BY bm25(snapshot_fts) LIMIT ?
            """, [words.joined(separator: " OR "), limit]).compactMap(snapshot)
    }

    private func snapshot(_ row: [String]) -> Snapshot? {
        guard row.count >= 10, let id = Int64(row[0]) else { return nil }
        return Snapshot(id: id, app: row[1], title: row[2], url: row[3].isEmpty ? nil : row[3], domain: row[4], text: row[5],
                        first: Date(timeIntervalSince1970: Double(row[6]) ?? 0),
                        last: Date(timeIntervalSince1970: Double(row[7]) ?? 0), seconds: Double(row[8]) ?? 0,
                        sightings: Int(row[9]) ?? 1, kind: row.count > 10 ? row[10] : "",
                        authored: row.count > 11 ? row[11] : "", seenAs: row.count > 12 ? row[12] : "",
                        readText: row.count > 13 ? row[13] : "")
    }

    /// Forgets snapshots older than `days` (their memories, loops and chronicle stay), and the ledger after a year.
    public func prune(days: Double = 14, now: Date = Date()) {
        let at = now.timeIntervalSince1970
        db.exec("DELETE FROM snapshot WHERE last < ? AND consolidated = 1", [at - days * 86400])
        db.exec("DELETE FROM snapshot WHERE last < ?", [at - 2 * days * 86400])
        db.exec("DELETE FROM ledger WHERE hour < ?", [at - 365 * 86400])
        db.exec("DELETE FROM nudge WHERE created < ?", [at - 90 * 86400])
        prunePictures(now: now)
    }

    /// Forgets everything seen on screen: snapshots, the ledger, loops and the chronicle.
    public func forgetAll() {
        for table in ["snapshot", "ledger", "loop", "chronicle", "nudge"] { db.exec("DELETE FROM \(table)") }
        try? FileManager.default.removeItem(at: Self.pictures)
        db.exec("INSERT INTO snapshot_fts(snapshot_fts) VALUES('rebuild')")
    }

    /// Forgets what was seen in one app (or on one site), now that it's excluded.
    public func forget(app: String) {
        db.exec("DELETE FROM snapshot WHERE app = ? OR bundle = ? OR domain = ?", [app, app, app])
        db.exec("DELETE FROM ledger WHERE app = ? OR domain = ?", [app, app])
    }

    // MARK: Time

    public struct Spent: Sendable, Equatable {
        public let app: String
        public let domain: String
        public let seconds: Double
        public var name: String { domain.isEmpty ? app : domain }
    }

    /// Where the time went between two moments, the most first.
    public func time(from: Date, to: Date) -> [Spent] {
        db.rows("""
            SELECT app, domain, sum(seconds) FROM ledger WHERE hour >= ? AND hour < ? GROUP BY app, domain
            ORDER BY sum(seconds) DESC LIMIT 30
            """, [(from.timeIntervalSince1970 / 3600).rounded(.down) * 3600, to.timeIntervalSince1970]).map {
            Spent(app: $0[0], domain: $0[1], seconds: Double($0[2]) ?? 0)
        }
    }

    // MARK: Open loops

    public struct Loop: Sendable, Equatable, Identifiable {
        public let id: Int64
        public var summary: String
        public var person: String
        public var project: String
        /// You promised it (true), or someone promised it to you.
        public var mine: Bool
        public var due: Date?
        public var status: String
        public var first: Date
        public var last: Date
        /// "promised", "asked" (someone asked you) or "owed" (`Promise.kind`).
        public var kind: String = "promised"

        /// How the Memory page and answers say it.
        public var label: String {
            switch kind {
            case "asked": return "Asked of you"
            case "plan": return "Coming up"
            case "owed": return "Promised to you"
            default: return mine ? "You promised" : "Promised to you"
            }
        }
    }

    public struct Promise: Sendable, Equatable {
        public var summary: String
        public var person: String
        public var project: String
        public var mine: Bool
        public var due: Date?
        /// "open", or "done" when what was seen shows it was done (sent, replied, merged, paid…).
        public var status: String
        /// "promised" (the user said they'd do it), "asked" (someone asked the user to: the user owes it too), or
        /// "owed" (someone said they'd do it for the user).
        public var kind: String

        public init(summary: String, person: String = "", project: String = "", mine: Bool = true, due: Date? = nil,
                    status: String = "open", kind: String? = nil) {
            self.summary = summary
            self.person = person
            self.project = project
            self.mine = mine
            self.due = due
            self.status = status
            self.kind = kind ?? (mine ? "promised" : "owed")
        }
    }

    /// Takes in promises read from what was seen: a new one opens a loop, one already open is confirmed (its due date
    /// kept or updated), and one shown done closes the matching open loop. Returns (opened, closed).
    @discardableResult
    public func take(_ promises: [Promise], evidence: [Int64], now: Date = Date()) -> (opened: Int, closed: Int) {
        let at = now.timeIntervalSince1970
        let proof = evidence.map(String.init).joined(separator: ",")
        var opened = 0, closed = 0
        let open = loops(status: "open", limit: 500)
        for promise in promises {
            let words = BrainModel.keywords(promise.summary)
            let match = open.first { loop in
                // A plan matches only a plan, and closely: "Check-in closes: Flight 6E 537" isn't the flight.
                if promise.kind == "plan" || loop.kind == "plan" {
                    return promise.kind == loop.kind
                        && BrainModel.similarity(words, BrainModel.keywords(loop.summary)) >= 0.7
                }
                let samePerson = promise.person.isEmpty || loop.person.isEmpty
                    || Self.samePerson(loop.person, promise.person)
                return samePerson && BrainModel.similarity(words, BrainModel.keywords(loop.summary)) >= 0.45
            }
            if promise.status == "done" {
                guard let match else { continue }   // done, but never seen open: nothing to close
                db.exec("UPDATE loop SET status = 'done', closed = ?, last = ?, closing = ? WHERE id = ?", [at, at, proof, match.id])
                closed += 1
            } else if let match {
                db.exec("UPDATE loop SET last = ?, due = coalesce(?, due), confidence = min(1, confidence + 0.15) WHERE id = ?",
                        [at, promise.due?.timeIntervalSince1970, match.id])
            } else {
                db.insert("""
                    INSERT INTO loop(summary, person, project, mine, due, first, last, evidence, kind) VALUES(?,?,?,?,?,?,?,?,?)
                    """, [promise.summary, promise.person, promise.project, promise.mine ? 1 : 0,
                          promise.due?.timeIntervalSince1970, at, at, proof, promise.kind])
                opened += 1
            }
        }
        // A plan whose time has passed (the flight has left): done.
        db.exec("UPDATE loop SET status = 'done', closed = ? WHERE kind = 'plan' AND status = 'open' AND due < ?",
                [at, at - 3600])
        // Loops nobody mentions for three weeks, past their date or with none, are dropped (they rarely still matter).
        db.exec("UPDATE loop SET status = 'dropped' WHERE status = 'open' AND last < ? AND (due IS NULL OR due < ?)",
                [at - 21 * 86400, at])
        return (opened, closed)
    }

    /// "Priya" and "Priya Shah" are the same person; "Priya Shah" and "Priya Nair" aren't.
    static func samePerson(_ a: String, _ b: String) -> Bool {
        let x = BrainModel.nameKey(a).split(separator: " "), y = BrainModel.nameKey(b).split(separator: " ")
        guard let first = x.first, first == y.first else { return false }
        return x.count == 1 || y.count == 1 || x == y
    }

    /// Loops by status, the soonest due first (then the newest).
    public func loops(status: String = "open", limit: Int = 30) -> [Loop] {
        db.rows("""
            SELECT id, summary, person, project, mine, due, status, first, last, kind FROM loop WHERE status = ?
            ORDER BY due IS NULL, due, last DESC LIMIT ?
            """, [status, limit]).compactMap { row in
            guard let id = Int64(row[0]) else { return nil }
            return Loop(id: id, summary: row[1], person: row[2], project: row[3], mine: row[4] == "1",
                        due: Double(row[5]).map { Date(timeIntervalSince1970: $0) }, status: row[6],
                        first: Date(timeIntervalSince1970: Double(row[7]) ?? 0),
                        last: Date(timeIntervalSince1970: Double(row[8]) ?? 0), kind: row.count > 9 ? row[9] : "promised")
        }
    }

    /// Closes a loop by hand ("done"), or drops it ("not a promise").
    public func set(loop id: Int64, status: String, now: Date = Date()) {
        db.exec("UPDATE loop SET status = ?, closed = ? WHERE id = ?", [status, now.timeIntervalSince1970, id])
    }

    // MARK: Chronicle

    public enum Level: String, CaseIterable, Sendable {
        case hour, day, month, year

        /// The period a moment falls in, as kept: "2026-11-05T14", "2026-11-05", "2026-11", "2026".
        public func period(of date: Date, calendar: Calendar = .current) -> String {
            let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            let (y, m, d, h) = (parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0)
            switch self {
            case .hour: return String(format: "%04d-%02d-%02dT%02d", y, m, d, h)
            case .day: return String(format: "%04d-%02d-%02d", y, m, d)
            case .month: return String(format: "%04d-%02d", y, m)
            case .year: return String(format: "%04d", y)
            }
        }

        /// The level below, whose summaries make this one.
        public var below: Level? {
            switch self {
            case .hour: return nil
            case .day: return .hour
            case .month: return .day
            case .year: return .month
            }
        }
    }

    public func chronicle(_ level: Level, _ period: String) -> String? {
        db.rows("SELECT summary FROM chronicle WHERE level = ? AND period = ?", [level.rawValue, period]).first?.first
    }

    public func setChronicle(_ level: Level, _ period: String, _ summary: String, now: Date = Date()) {
        db.exec("""
            INSERT INTO chronicle(level, period, summary, generated) VALUES(?,?,?,?)
            ON CONFLICT(level, period) DO UPDATE SET summary = excluded.summary, generated = excluded.generated
            """, [level.rawValue, period, summary, now.timeIntervalSince1970])
    }

    /// The summaries of a level within a period of the level above: the hours of "2026-11-05", the days of "2026-11".
    public func chronicles(_ level: Level, within period: String) -> [(period: String, summary: String)] {
        db.rows("SELECT period, summary FROM chronicle WHERE level = ? AND substr(period, 1, ?) = ? ORDER BY period",
                [level.rawValue, period.count, period]).map { ($0[0], $0[1]) }
    }

    /// One chronicle entry by its row ("2026-11-05: You…"), for search by meaning.
    public func chronicleLine(rowid: Int64) -> String? {
        db.rows("SELECT period, summary FROM chronicle WHERE rowid = ?", [rowid]).first.map { "\($0[0]): \($0[1])" }
    }

    public func snapshot(id: Int64) -> Snapshot? {
        db.rows("SELECT id, app, title, url, domain, text, first, last, seconds, sightings, kind, authored, seen_as, read_text FROM snapshot WHERE id = ?", [id])
            .first.flatMap(snapshot)
    }

    /// Chronicle entries whose words match.
    public func searchChronicle(_ query: String, limit: Int = 6) -> [(level: String, period: String, summary: String)] {
        let words = BrainModel.keywords(query).filter { $0.count > 2 }
        guard !words.isEmpty else { return [] }
        let clause = words.map { _ in "lower(summary) LIKE ?" }.joined(separator: " OR ")
        return db.rows("SELECT level, period, summary FROM chronicle WHERE \(clause) ORDER BY period DESC LIMIT ?",
                       words.map { "%\($0)%" as Any? } + [limit]).map { ($0[0], $0[1], $0[2]) }
    }

    // MARK: Nudges

    /// Whether a nudge with this key was already made (a brief once a day, a reminder once).
    public func nudged(_ key: String) -> Bool { !db.rows("SELECT 1 FROM nudge WHERE key = ?", [key]).isEmpty }

    public func nudge(_ key: String, kind: String, title: String, body: String, now: Date = Date()) {
        db.exec("INSERT OR IGNORE INTO nudge(key, kind, title, body, created) VALUES(?,?,?,?,?)",
                [key, kind, title, body, now.timeIntervalSince1970])
    }

    /// Nudges not shown yet (the app shows them, then marks them seen).
    public func unseenNudges() -> [(key: String, kind: String, title: String, body: String)] {
        db.rows("SELECT key, kind, title, body FROM nudge WHERE seen IS NULL ORDER BY created", []).map { ($0[0], $0[1], $0[2], $0[3]) }
    }

    public func seen(nudge key: String, now: Date = Date()) {
        db.exec("UPDATE nudge SET seen = ? WHERE key = ?", [now.timeIntervalSince1970, key])
    }

    public func latestNudges(limit: Int = 10) -> [(kind: String, title: String, body: String, created: Date)] {
        db.rows("SELECT kind, title, body, created FROM nudge ORDER BY created DESC LIMIT ?", [limit]).map {
            ($0[0], $0[1], $0[2], Date(timeIntervalSince1970: Double($0[3]) ?? 0))
        }
    }

    public func counts() -> (snapshots: Int, openLoops: Int) {
        (Int(db.rows("SELECT count(*) FROM snapshot", []).first?.first ?? "") ?? 0,
         Int(db.rows("SELECT count(*) FROM loop WHERE status = 'open'", []).first?.first ?? "") ?? 0)
    }
}

/// One SQLite connection, used from any thread (one call at a time), shared by Murmur's app and its helper through
/// WAL (each waits up to five seconds for the other's write).
final class SQLiteConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { db = nil; return }
        sqlite3_busy_timeout(db, 5000)
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    func exec(_ sql: String, _ values: [Any?] = []) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return run(sql, values) { _ in }
    }

    @discardableResult
    func insert(_ sql: String, _ values: [Any?]) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return run(sql, values) { _ in } ? sqlite3_last_insert_rowid(db) : 0
    }

    func rows(_ sql: String, _ values: [Any?]) -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        var out: [[String]] = []
        run(sql, values) { statement in
            let columns = sqlite3_column_count(statement)
            out.append((0..<columns).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Any?], row: (OpaquePointer?) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, position)
            case let text as String: sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            case let number as Double: sqlite3_bind_double(statement, position, number)
            case let flag as Bool: sqlite3_bind_int(statement, position, flag ? 1 : 0)
            case let data as Data:
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), Self.transient) }
            default: sqlite3_bind_text(statement, position, "\(value!)", -1, Self.transient)
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { row(statement); continue }
            return step == SQLITE_DONE
        }
    }
}
