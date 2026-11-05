import Foundation

/// Search by meaning, for the living memory: every memory, promise, summary and window snapshot gets a vector from
/// EmbeddingGemma 2 (the model file search already runs, in `murmur-engine memory-service`), kept in brain.sqlite.
/// "What car does Priya drive?" then finds "Priya drives a Tesla", and "my manager" finds "reports to Arjun", which
/// matching words never could.
///
/// Vectors are cut to their first 256 numbers and normalised again (EmbeddingGemma is trained for that: Matryoshka),
/// so 50,000 of them are 50 MB and searching them all takes milliseconds.
public final class MemoryVectors: @unchecked Sendable {
    public static let dimensions = 256

    public enum Kind: String, CaseIterable, Sendable {
        case memory, loop, chronicle, snapshot
    }

    public struct Hit: Sendable, Equatable {
        public let kind: Kind
        public let ref: Int64
        public let score: Float
    }

    private let db: SQLiteConnection
    private let lock = NSLock()
    /// All vectors, loaded once and kept current (reloaded when the table changed).
    private var cache: [(kind: Kind, ref: Int64, vector: [Float])] = []
    private var cacheStamp = ""

    public init(url: URL = BrainStore.defaultURL) {
        db = SQLiteConnection(url: url)
        db.exec("CREATE TABLE IF NOT EXISTS vector(kind TEXT NOT NULL, ref INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(kind, ref))")
    }

    // MARK: What needs a vector

    /// Things without a vector yet (or whose text changed: a snapshot still being written), with the text to embed,
    /// newest first. The text names who or what a memory is about, so "Priya" alone finds her memories.
    public func missing(limit: Int = 64) -> [(kind: Kind, ref: Int64, text: String)] {
        var out: [(Kind, Int64, String)] = []
        let queries: [(Kind, String)] = [
            (.memory, """
                SELECT m.id, e.name || ': ' || m.text FROM memory m JOIN entity e ON e.id = m.entity
                WHERE m.archived = 0 AND NOT EXISTS (SELECT 1 FROM vector v WHERE v.kind = 'memory' AND v.ref = m.id)
                ORDER BY m.id DESC LIMIT ?
                """),
            (.loop, """
                SELECT id, summary || CASE WHEN person != '' THEN ' (with ' || person || ')' ELSE '' END FROM loop
                WHERE NOT EXISTS (SELECT 1 FROM vector v WHERE v.kind = 'loop' AND v.ref = loop.id) ORDER BY id DESC LIMIT ?
                """),
            (.chronicle, """
                SELECT rowid, period || ': ' || summary FROM chronicle
                WHERE NOT EXISTS (SELECT 1 FROM vector v WHERE v.kind = 'chronicle' AND v.ref = chronicle.rowid)
                ORDER BY rowid DESC LIMIT ?
                """),
            (.snapshot, """
                SELECT id, app || ' ' || coalesce(domain, '') || ' ' || title || char(10) || substr(text, 1, 1500) FROM snapshot
                WHERE NOT EXISTS (SELECT 1 FROM vector v WHERE v.kind = 'snapshot' AND v.ref = snapshot.id)
                ORDER BY id DESC LIMIT ?
                """),
        ]
        for (kind, sql) in queries {
            guard out.count < limit else { break }
            for row in db.rows(sql, [limit - out.count]) {
                guard let ref = Int64(row[0]), !row[1].isEmpty else { continue }
                out.append((kind, ref, String(row[1].prefix(2000))))
            }
        }
        return out.map { (kind: $0.0, ref: $0.1, text: $0.2) }
    }

    public func store(_ kind: Kind, _ ref: Int64, _ vector: [Float]) {
        let cut = Self.cut(vector)
        guard cut.count == Self.dimensions else { return }
        let data = cut.withUnsafeBufferPointer { Data(buffer: $0) }
        db.exec("INSERT OR REPLACE INTO vector(kind, ref, data) VALUES(?,?,?)", [kind.rawValue, ref, data])
    }

    /// A thing changed (a snapshot's newer text, a memory reworded): its vector goes, and comes back on the next pass.
    public func invalidate(_ kind: Kind, _ ref: Int64) {
        db.exec("DELETE FROM vector WHERE kind = ? AND ref = ?", [kind.rawValue, ref])
    }

    /// Vectors of things that are gone (forgotten, archived, pruned).
    public func prune() {
        db.exec("DELETE FROM vector WHERE kind = 'memory' AND ref NOT IN (SELECT id FROM memory WHERE archived = 0)")
        db.exec("DELETE FROM vector WHERE kind = 'loop' AND ref NOT IN (SELECT id FROM loop)")
        db.exec("DELETE FROM vector WHERE kind = 'chronicle' AND ref NOT IN (SELECT rowid FROM chronicle)")
        db.exec("DELETE FROM vector WHERE kind = 'snapshot' AND ref NOT IN (SELECT id FROM snapshot)")
    }

    public func count() -> Int { Int(db.rows("SELECT count(*) FROM vector", []).first?.first ?? "") ?? 0 }

    // MARK: Searching

    /// The closest things to a query's vector, of these kinds, best first; at least `floor` similar.
    public func search(_ query: [Float], kinds: Set<Kind> = Set(Kind.allCases), limit: Int = 20,
                       floor: Float = 0.3) -> [Hit] {
        let q = Self.cut(query)
        guard q.count == Self.dimensions else { return [] }
        lock.lock(); defer { lock.unlock() }
        reload()
        var hits: [Hit] = []
        hits.reserveCapacity(64)
        for entry in cache where kinds.contains(entry.kind) {
            var dot: Float = 0
            for i in 0..<Self.dimensions { dot += q[i] * entry.vector[i] }
            if dot >= floor { hits.append(Hit(kind: entry.kind, ref: entry.ref, score: dot)) }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// One thing's vector, when it has one.
    public func vector(_ kind: Kind, _ ref: Int64) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        reload()
        return cache.first { $0.kind == kind && $0.ref == ref }?.vector
    }

    /// The average direction of these memories' vectors, normalised: "what matters to the user". Nil without them.
    public func centroid(of memories: [Int64]) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        reload()
        let wanted = Set(memories)
        var sum = [Float](repeating: 0, count: Self.dimensions)
        var count = 0
        for entry in cache where entry.kind == .memory && wanted.contains(entry.ref) {
            for i in 0..<Self.dimensions { sum[i] += entry.vector[i] }
            count += 1
        }
        guard count >= 3 else { return nil }
        let length = sum.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? sum.map { $0 / length } : nil
    }

    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }

    private func reload() {
        let stamp = db.rows("SELECT count(*), coalesce(sum(ref), 0), coalesce(max(rowid), 0) FROM vector", []).first?.joined(separator: ":") ?? ""
        guard stamp != cacheStamp else { return }
        cache = db.rows("SELECT kind, ref, hex(data) FROM vector", []).compactMap { row in
            guard let kind = Kind(rawValue: row[0]), let ref = Int64(row[1]) else { return nil }
            let vector = Self.floats(hex: row[2])
            return vector.count == Self.dimensions ? (kind, ref, vector) : nil
        }
        cacheStamp = stamp
    }

    // MARK: Numbers

    /// The first 256 numbers, normalised to length 1.
    public static func cut(_ vector: [Float]) -> [Float] {
        guard vector.count >= dimensions else { return [] }
        let head = Array(vector.prefix(dimensions))
        let length = head.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? head.map { $0 / length } : []
    }

    static func floats(hex: String) -> [Float] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8 = 0, odd = false
        for c in hex.utf8 {
            let v: UInt8 = c >= 65 ? (c & 0x5f) - 55 : c - 48
            if odd { bytes.append(high << 4 | v) } else { high = v }
            odd.toggle()
        }
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Reciprocal rank fusion (k = 60): rankings from words, names and meaning made into one, each ranking's best
    /// counting most, agreement between them counting more.
    public static func fuse<Key: Hashable>(_ rankings: [[Key]], k: Double = 60) -> [Key: Double] {
        var scores: [Key: Double] = [:]
        for ranking in rankings {
            for (rank, key) in ranking.enumerated() { scores[key, default: 0] += 1 / (k + Double(rank + 1)) }
        }
        return scores
    }
}
