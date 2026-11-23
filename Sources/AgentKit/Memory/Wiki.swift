import Foundation

/// The wiki: a page for each person, project, organization, place and topic that matters in the user's world, in the
/// same file as the rest of memory (brain.sqlite). Written by `WikiWriter` from everything memory holds about the
/// subject; the rules are `WikiRules`.
///
/// - page: the subject (one per entity of the living memory), its one-line summary, its claims as text, the pages it
///   links, when it was last written and by which model.
/// - page_claim: one claim, with whose it is, how it's known, how much it's worth, the sources it was read from, when
///   it was first written and last confirmed, and when it stopped being true (`invalid_at`). A rewrite never deletes a
///   claim: one the new page leaves out is marked no longer true, so "what was true in June" can still be answered.
///
/// A page is due again when its subject got a memory or a connection after it was written.
public final class Wiki: @unchecked Sendable {
    let db: SQLiteConnection
    public let url: URL

    public init(url: URL = BrainStore.defaultURL) {
        self.url = url
        db = SQLiteConnection(url: url)
        for statement in [
            """
            CREATE TABLE IF NOT EXISTS page(id INTEGER PRIMARY KEY, entity INTEGER NOT NULL UNIQUE, title TEXT NOT NULL,
              kind TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '',
              body TEXT NOT NULL DEFAULT '', links TEXT NOT NULL DEFAULT '', first REAL NOT NULL, updated REAL NOT NULL,
              model TEXT NOT NULL DEFAULT '', rev INTEGER NOT NULL DEFAULT 1)
            """,
            """
            CREATE TABLE IF NOT EXISTS page_claim(id INTEGER PRIMARY KEY, page INTEGER NOT NULL, text TEXT NOT NULL,
              whose TEXT NOT NULL DEFAULT 'thing', basis TEXT NOT NULL DEFAULT 'seen', worth TEXT NOT NULL DEFAULT 'detail',
              sources TEXT NOT NULL DEFAULT '', created REAL NOT NULL, confirmed REAL NOT NULL, invalid_at REAL)
            """,
            "CREATE INDEX IF NOT EXISTS page_claim_page ON page_claim(page, invalid_at)",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS page_fts USING fts5(title, aliases, summary, body, content='page',
              content_rowid='id', tokenize='unicode61 remove_diacritics 2')
            """,
            """
            CREATE TRIGGER IF NOT EXISTS page_ai AFTER INSERT ON page BEGIN
              INSERT INTO page_fts(rowid, title, aliases, summary, body) VALUES (new.id, new.title, new.aliases, new.summary, new.body); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS page_ad AFTER DELETE ON page BEGIN
              INSERT INTO page_fts(page_fts, rowid, title, aliases, summary, body)
              VALUES ('delete', old.id, old.title, old.aliases, old.summary, old.body); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS page_au AFTER UPDATE OF title, aliases, summary, body ON page BEGIN
              INSERT INTO page_fts(page_fts, rowid, title, aliases, summary, body)
              VALUES ('delete', old.id, old.title, old.aliases, old.summary, old.body);
              INSERT INTO page_fts(rowid, title, aliases, summary, body) VALUES (new.id, new.title, new.aliases, new.summary, new.body); END
            """,
        ] { db.exec(statement) }
    }

    // MARK: Pages

    public struct Claim: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let text: String
        public let whose: String
        public let basis: String
        public let worth: String
        public let sources: [String]
        public let created: Date
        public let confirmed: Date
        /// When a rewrite left it out: no longer true from then.
        public let invalidAt: Date?
    }

    public struct Page: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let entity: Int64
        public let title: String
        public let kind: String
        public let aliases: [String]
        public let summary: String
        public let links: [String]
        public let updated: Date
        public let model: String
        /// What's true now; `history` adds what no longer is.
        public var claims: [Claim]

        /// The page as text: its line and claims, with where each came from when `sources`.
        public func text(sources: Bool = false) -> String {
            WikiRules.render(title: title, kind: kind, summary: summary,
                             claims: claims.map { ($0.text, $0.basis, $0.worth, $0.sources) }, updated: updated, sources: sources)
        }
    }

    public func page(id: Int64, history: Bool = false) -> Page? {
        db.rows("SELECT id, entity, title, kind, aliases, summary, links, updated, model FROM page WHERE id = ?", [id])
            .first.flatMap { page($0, history: history) }
    }

    public func page(entity: Int64, history: Bool = false) -> Page? {
        db.rows("SELECT id, entity, title, kind, aliases, summary, links, updated, model FROM page WHERE entity = ?", [entity])
            .first.flatMap { page($0, history: history) }
    }

    /// The page a name means: its title or one of its other names, else the best match by words.
    public func page(named name: String, history: Bool = false) -> Page? {
        let key = BrainModel.nameKey(name)
        for row in db.rows("SELECT id, entity, title, kind, aliases, summary, links, updated, model FROM page", []) {
            let names = [row[2]] + row[4].split(separator: "\n").map(String.init)
            if names.contains(where: { BrainModel.nameKey($0) == key }) { return page(row, history: history) }
        }
        return search(name, limit: 1).first.flatMap { self.page(id: $0.id, history: history) }
    }

    /// Pages whose words match, best first.
    public func search(_ query: String, limit: Int = 6) -> [Page] {
        let words = BrainModel.keywords(query).filter { $0.count > 1 }.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        guard !words.isEmpty else { return [] }
        return db.rows("""
            SELECT p.id, p.entity, p.title, p.kind, p.aliases, p.summary, p.links, p.updated, p.model
            FROM page_fts f JOIN page p ON p.id = f.rowid WHERE page_fts MATCH ? ORDER BY bm25(page_fts, 10, 5, 2, 1) LIMIT ?
            """, [words.joined(separator: " OR "), limit]).compactMap { page($0, history: false) }
    }

    /// Pages of one kind (or all), the most recently written first.
    public func list(kind: String? = nil, limit: Int = 50) -> [Page] {
        let rows = kind.map {
            db.rows("SELECT id, entity, title, kind, aliases, summary, links, updated, model FROM page WHERE kind = ? ORDER BY updated DESC LIMIT ?", [$0, limit])
        } ?? db.rows("SELECT id, entity, title, kind, aliases, summary, links, updated, model FROM page ORDER BY updated DESC LIMIT ?", [limit])
        return rows.compactMap { page($0, history: false, claims: false) }
    }

    private func page(_ row: [String], history: Bool, claims withClaims: Bool = true) -> Page? {
        guard row.count == 9, let id = Int64(row[0]), let entity = Int64(row[1]) else { return nil }
        return Page(id: id, entity: entity, title: row[2], kind: row[3],
                    aliases: row[4].split(separator: "\n").map(String.init), summary: row[5],
                    links: row[6].split(separator: "\n").map(String.init),
                    updated: Date(timeIntervalSince1970: Double(row[7]) ?? 0), model: row[8],
                    claims: withClaims ? claims(page: id, history: history) : [])
    }

    public func claims(page: Int64, history: Bool = false) -> [Claim] {
        db.rows("""
            SELECT id, text, whose, basis, worth, sources, created, confirmed, invalid_at FROM page_claim
            WHERE page = ? \(history ? "" : "AND invalid_at IS NULL") ORDER BY invalid_at IS NOT NULL, worth = 'detail', id
            """, [page]).compactMap { row in
            guard row.count == 9, let id = Int64(row[0]) else { return nil }
            return Claim(id: id, text: row[1], whose: row[2], basis: row[3], worth: row[4],
                         sources: row[5].split(separator: ",").map(String.init),
                         created: Date(timeIntervalSince1970: Double(row[6]) ?? 0),
                         confirmed: Date(timeIntervalSince1970: Double(row[7]) ?? 0),
                         invalidAt: Double(row[8]).map { Date(timeIntervalSince1970: $0) })
        }
    }

    // MARK: What's due

    public struct Subject: Sendable, Equatable {
        public let entity: Int64
        public let name: String
        public let kind: String
        public let aliases: [String]
    }

    /// Subjects whose page is missing or older than what memory learned about them since: at least two current
    /// memories, or a connection to the user's work. The most talked-about first. The user's own page ("You") too.
    public func due(limit: Int = 8) -> [Subject] {
        // Connections live in screen memory's graph, which a Mac without screen memory (or a test) hasn't made: a
        // query naming a missing table returns nothing at all.
        let edges = !db.rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'edge'", []).isEmpty
        let connected = edges ? "EXISTS (SELECT 1 FROM edge g WHERE g.src = e.id OR g.dst = e.id)" : "0"
        let newerEdge = edges ? "coalesce((SELECT max(g.last) FROM edge g WHERE g.src = e.id OR g.dst = e.id), 0) > p.updated" : "0"
        // A topic ("YouTube video") needs memories of its own: a connection alone makes a page of what was watched.
        return db.rows("""
            SELECT e.id, e.name, e.kind, e.aliases FROM entity e
            LEFT JOIN page p ON p.entity = e.id
            WHERE (
                (SELECT count(*) FROM memory m WHERE m.entity = e.id AND m.archived = 0) >= 2
                OR (e.kind != 'topic' AND \(connected))
              )
              AND NOT (e.kind IN ('topic', 'place') AND e.name NOT LIKE '% %' AND e.name = lower(e.name))
              AND (p.id IS NULL
                OR coalesce((SELECT max(m.confirmed) FROM memory m WHERE m.entity = e.id AND m.archived = 0), 0) > p.updated
                OR \(newerEdge))
            ORDER BY p.id IS NOT NULL,
              CASE e.kind WHEN 'me' THEN 0 WHEN 'person' THEN 1 WHEN 'project' THEN 1 WHEN 'organization' THEN 2 ELSE 3 END,
              e.mentions DESC, e.last_seen DESC LIMIT ?
            """, [limit]).compactMap { row in
            guard row.count == 4, let id = Int64(row[0]) else { return nil }
            return Subject(entity: id, name: row[1], kind: row[2], aliases: row[3].split(separator: "\n").map(String.init))
        }
    }

    public func dueCount() -> Int { due(limit: 10_000).count }

    /// The subjects that have a page, the first written first (`murmur-memory knowledge 3 rewrite`).
    public func written(limit: Int = 8) -> [Subject] {
        db.rows("""
            SELECT e.id, e.name, e.kind, e.aliases FROM page p JOIN entity e ON e.id = p.entity ORDER BY p.id LIMIT ?
            """, [limit]).compactMap { row in
            guard row.count == 4, let id = Int64(row[0]) else { return nil }
            return Subject(entity: id, name: row[1], kind: row[2], aliases: row[3].split(separator: "\n").map(String.init))
        }
    }

    // MARK: Writing

    /// Keeps a page's new claims: a claim already on the page (the same in other words) is confirmed and keeps when it
    /// was first written; a new one is added; one the rewrite left out stops being true now. At most 40 claims that
    /// are no longer true are kept per page, the oldest go first.
    @discardableResult
    public func save(_ subject: Subject, written: WikiRules.Written, model: String, now: Date = Date())
        -> (added: Int, confirmed: Int, retired: Int) {
        let at = now.timeIntervalSince1970
        let pageID: Int64
        if let existing = page(entity: subject.entity) {
            pageID = existing.id
            db.exec("""
                UPDATE page SET title = ?, kind = ?, aliases = ?, summary = ?, links = ?, updated = ?, model = ?, rev = rev + 1
                WHERE id = ?
                """, [subject.name, subject.kind, subject.aliases.joined(separator: "\n"),
                      written.summary.isEmpty ? existing.summary : written.summary, written.links.joined(separator: "\n"),
                      at, model, pageID])
        } else {
            pageID = db.insert("""
                INSERT INTO page(entity, title, kind, aliases, summary, links, first, updated, model) VALUES(?,?,?,?,?,?,?,?,?)
                """, [subject.entity, subject.name, subject.kind, subject.aliases.joined(separator: "\n"), written.summary,
                      written.links.joined(separator: "\n"), at, at, model])
        }
        guard pageID != 0 else { return (0, 0, 0) }
        let current = claims(page: pageID)
        var matched = Set<Int64>(), added = 0, confirmed = 0
        for draft in written.claims {
            let words = BrainModel.keywords(WikiRules.unlinked(draft.text))
            if let same = current.first(where: { !matched.contains($0.id)
                && ($0.text == draft.text || BrainModel.similarity(BrainModel.keywords(WikiRules.unlinked($0.text)), words) >= 0.75) }) {
                matched.insert(same.id)
                // Kept as it was ("page"): its own sources stay.
                let sources = draft.sources == ["page"] ? same.sources : WikiRules.unique(draft.sources + same.sources)
                db.exec("""
                    UPDATE page_claim SET text = ?, whose = ?, basis = ?, worth = ?, sources = ?, confirmed = ? WHERE id = ?
                    """, [draft.text, draft.whose, draft.basis, draft.worth, sources.prefix(8).joined(separator: ","), at, same.id])
                confirmed += 1
            } else {
                db.insert("""
                    INSERT INTO page_claim(page, text, whose, basis, worth, sources, created, confirmed) VALUES(?,?,?,?,?,?,?,?)
                    """, [pageID, draft.text, draft.whose, draft.basis, draft.worth,
                          draft.sources.filter { $0 != "page" }.prefix(8).joined(separator: ","), at, at])
                added += 1
            }
        }
        let retired = current.filter { !matched.contains($0.id) }
        for claim in retired { db.exec("UPDATE page_claim SET invalid_at = ? WHERE id = ?", [at, claim.id]) }
        db.exec("""
            DELETE FROM page_claim WHERE page = ? AND invalid_at IS NOT NULL AND id NOT IN (
              SELECT id FROM page_claim WHERE page = ? AND invalid_at IS NOT NULL ORDER BY invalid_at DESC LIMIT 40)
            """, [pageID, pageID])
        // The page's text, for search by words and by meaning.
        if let saved = page(id: pageID) {
            db.exec("UPDATE page SET body = ? WHERE id = ?", [saved.claims.map(\.text).joined(separator: "\n"), pageID])
        }
        db.exec("DELETE FROM vector WHERE kind = 'page' AND ref = ?", [pageID])
        return (added, confirmed, retired.count)
    }

    /// Marks a subject's page written (nothing changed) so it isn't due again until memory learns more.
    public func touch(entity: Int64, now: Date = Date()) {
        db.exec("UPDATE page SET updated = ? WHERE entity = ?", [now.timeIntervalSince1970, entity])
    }

    /// Pages of entities that are gone (forgotten, merged): gone too.
    public func prune() {
        db.exec("DELETE FROM page_claim WHERE page IN (SELECT id FROM page WHERE entity NOT IN (SELECT id FROM entity))")
        db.exec("DELETE FROM page WHERE entity NOT IN (SELECT id FROM entity)")
    }

    public func forgetAll() {
        db.exec("DELETE FROM page_claim")
        db.exec("DELETE FROM page")
        db.exec("INSERT INTO page_fts(page_fts) VALUES('rebuild')")
    }

    public func counts() -> (pages: Int, claims: Int, retired: Int) {
        func count(_ sql: String) -> Int { Int(db.rows(sql, []).first?.first ?? "0") ?? 0 }
        return (count("SELECT count(*) FROM page"), count("SELECT count(*) FROM page_claim WHERE invalid_at IS NULL"),
                count("SELECT count(*) FROM page_claim WHERE invalid_at IS NOT NULL"))
    }
}

/// Writes the wiki's pages with the model that reads memory (the local one, or Claude/OpenAI when the user chose it):
/// a few due pages a round, each from everything memory holds about its subject, numbered.
public enum WikiWriter {
    /// What memory holds about a subject, as numbered evidence: its memories (the user's own words first), the
    /// connections and episodes of work that involve it, and the windows that name it. Private episodes are left out
    /// when it goes to Claude or OpenAI (`remote`), and so is anything from a window.
    public static func evidence(for subject: Wiki.Subject, brain: BrainStore, graph: MemoryGraph, journal: Journal,
                                remote: Bool, now: Date = Date()) -> [WikiRules.Evidence] {
        var items: [WikiRules.Evidence] = []
        var episodes: [Int64] = []
        let me = brain.meNames()
        // Memories: what the user told Murmur, then Contacts, Calendar…, then what was read off the screen.
        let memories = brain.memories(of: subject.entity, now: now)
            .sorted { ($0.origin == .told ? 0 : 1, -$0.importance, -$0.confirmed.timeIntervalSince1970)
                < ($1.origin == .told ? 0 : 1, -$1.importance, -$1.confirmed.timeIntervalSince1970) }
        for memory in memories.prefix(7) {
            let from = memory.origin == .told ? "the user told Murmur" : "memory, from \(memory.origin.display)"
            items.append(.init(label: from, when: memory.confirmed, text: memory.text, source: "memory:\(memory.id)"))
        }
        // Connections: "You worked on Murmur", with the episodes that show it.
        for edge in graph.edges(of: subject.entity, limit: 6) {
            guard let src = graph.entityName(edge.src), let dst = graph.entityName(edge.dst) else { continue }
            let from = src.kind == "me" ? "You" : src.name, to = dst.kind == "me" ? "you" : dst.name
            let verb = WikiWriter.phrase(edge.rel)
            let span = day(edge.first) == day(edge.last) ? "on \(day(edge.last))" : "from \(day(edge.first)) to \(day(edge.last))"
            items.append(.init(label: "connection", when: edge.last, text: "\(from) \(verb) \(to) \(span)", source: "edge"))
            episodes += graph.evidence(src: edge.src, rel: edge.rel, dst: edge.dst)
        }
        // Episodes of work: from the connections, then by the subject's name.
        episodes += graph.searchEpisodes(subject.name, limit: 4).map(\.id)
        var taken = Set<Int64>()
        for id in episodes where taken.insert(id).inserted {
            guard items.count < WikiRules.maxEvidence - 2, let episode = graph.episode(id: id), episode.read, !episode.title.isEmpty else { continue }
            if remote, graph.isPrivate(id) { continue }
            let minutes = Int((episode.seconds / 60).rounded())
            var text = "\(episode.title). \(episode.summary) \(episode.outcome)".trimmingCharacters(in: .whitespaces)
            if remote { text = CloudPrivacy.scrub(text) }
            items.append(.init(label: "what you did, \(minutes) min", when: episode.start, text: String(text.prefix(500)),
                               source: "episode:\(id)"))
        }
        // Windows that name it (never to Claude or OpenAI): the lines around the name.
        if !remote {
            for window in journal.search(subject.name, limit: 6) where items.count < WikiRules.maxEvidence {
                guard let excerpt = excerpt(of: window.title + "\n" + window.text, around: [subject.name] + subject.aliases) else { continue }
                let place = window.domain.isEmpty ? window.app : window.domain
                let wrote = window.authored.isEmpty ? "" : " The user wrote here: " + String(window.authored.suffix(300))
                items.append(.init(label: "seen in \(place)", when: window.first,
                                   text: BrainModel.redact(excerpt + wrote), source: "snapshot:\(window.id)"))
            }
        }
        // Older episodes were written before the user stopped being someone they worked with ("with Shubham").
        return items.map { WikiRules.Evidence(label: $0.label, when: $0.when, text: WikiRules.withoutSelf($0.text, me: me),
                                              source: $0.source) }
            .sorted { ($0.when ?? .distantPast) < ($1.when ?? .distantPast) }
    }

    /// The text around a name: up to 450 characters, starting at a line.
    static func excerpt(of text: String, around names: [String]) -> String? {
        let lower = text.lowercased()
        for name in names where name.count >= 3 {
            guard let range = lower.range(of: name.lowercased()) else { continue }
            let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
            let start = text.index(text.startIndex, offsetBy: max(0, offset - 150))
            let lineStart = text[..<start].lastIndex(of: "\n").map { text.index(after: $0) } ?? start
            let chosen = text.distance(from: lineStart, to: range.lowerBound) > 300 ? start : lineStart
            return String(text[chosen...].prefix(450)).replacingOccurrences(of: "\n", with: " · ")
        }
        return nil
    }

    static func day(_ date: Date) -> String { WikiRules.formatter("d MMM yyyy", .current).string(from: date) }

    /// A connection as words: "involved_in" → "was involved in" ("You involved in Murmur" isn't English).
    static func phrase(_ rel: String) -> String {
        switch rel {
        case "involved_in": return "was involved in"
        case "talked_with": return "talked with"
        case "worked_on": return "worked on"
        default: return rel.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// One round: up to `limit` due pages, each rewritten from its evidence and checked against it. `ask` is the model
    /// (JSON); `remote` when it's Claude or OpenAI. Returns how many pages were written.
    @discardableResult
    public static func pass(wiki: Wiki, brain: BrainStore, graph: MemoryGraph, journal: Journal, ask: EpisodeReader.Ask,
                            model: String, remote: Bool, limit: Int = 4, now: Date = Date(), subjects: [Wiki.Subject]? = nil,
                            keepGoing: () -> Bool = { true }) async -> Int {
        var written = 0
        // Links only to what has, or is due, a page of its own: not every app or phrase memory named once.
        // Not to topics either ("video", "Sudoku game"): people, organizations, projects and places.
        let known = WikiRules.unique(wiki.list(limit: 400).filter { $0.kind != "topic" }.map(\.title)
                                     + wiki.due(limit: 400).filter { $0.kind != "topic" }.map(\.name))
            .filter { $0 != "You" && $0.count >= 3 }
        for subject in subjects ?? wiki.due(limit: limit) {
            guard keepGoing() else { break }
            let evidence = evidence(for: subject, brain: brain, graph: graph, journal: journal, remote: remote, now: now)
            guard !evidence.isEmpty else { wiki.touch(entity: subject.entity, now: now); continue }
            let title = subject.kind == "me" ? "You (the user)" : subject.name
            let existing = wiki.page(entity: subject.entity)?.claims.map(\.text) ?? []
            let others = known.filter { BrainModel.nameKey($0) != BrainModel.nameKey(subject.name) }
            let prompt = WikiRules.prompt(title: title, kind: subject.kind, aliases: subject.aliases, existing: existing,
                                          evidence: evidence, known: others, today: now)
            guard let content = await ask(WikiRules.system(), remote ? CloudPrivacy.scrub(prompt) : prompt) else { break }
            guard let page = WikiRules.check(content, title: subject.name, aliases: subject.aliases, existing: existing,
                                             evidence: evidence, known: others) else {
                MemoryLog.write("the page about \(subject.name) didn't come back as JSON; tried again later")
                MemoryLog.debug("it answered: " + String(content.prefix(400)).replacingOccurrences(of: "\n", with: " "))
                wiki.touch(entity: subject.entity, now: now)
                continue
            }
            guard !page.claims.isEmpty else {
                MemoryLog.write("left the page about \(subject.name) as it was: none of \(page.unsupported) claims held up")
                wiki.touch(entity: subject.entity, now: now)
                continue
            }
            let saved = wiki.save(subject, written: page, model: model, now: now)
            written += 1
            MemoryLog.write("wrote the page about \(subject.name): \(saved.added) new, \(saved.confirmed) confirmed, "
                            + "\(saved.retired) left out" + (page.unsupported > 0 ? ", \(page.unsupported) left out (not in the evidence)" : ""))
        }
        return written
    }
}
