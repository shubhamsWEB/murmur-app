import Foundation

/// Finding what's relevant in the living memory, three ways at once, fused into one ranking (reciprocal rank fusion):
///
/// - names: everything about someone or something the words name ("Priya", "the Acme deal");
/// - words: the full-text index (SQLite FTS5, BM25);
/// - meaning: EmbeddingGemma 2 vectors (`MemoryVectors`), so "what car does Priya drive" finds "Priya drives a Tesla".
///
/// Then, among what's close in rank, the stronger memory first (recently confirmed, used, certain). Works without
/// vectors too (the model not downloaded, or not answering): names and words alone, as before.
public struct MemorySearch: Sendable {
    public let store: BrainStore
    public let journal: Journal
    public let vectors: MemoryVectors

    /// EmbeddingGemma 2's similarities run high: unrelated commands ("open Safari", "turn the volume down") still
    /// score 0.58 to 0.67 against memories, with no gap between best and next; real questions score 0.73 to 0.87, a
    /// clear step above the rest (measured on Murmur's memories, 2026-11-05). A match by meaning counts from 0.70, and
    /// only within 0.10 of the best one.
    public static let floor: Float = 0.70
    public static let spread: Float = 0.10

    /// The hits that count: above the floor, and close to the best.
    static func kept(_ hits: [MemoryVectors.Hit], floor: Float = MemorySearch.floor) -> [MemoryVectors.Hit] {
        guard let best = hits.first?.score, best >= floor else { return [] }
        return hits.filter { $0.score >= floor && $0.score >= best - spread }
    }

    public init(store: BrainStore, journal: Journal, vectors: MemoryVectors) {
        self.store = store
        self.journal = journal
        self.vectors = vectors
    }

    /// Memories for a question or command, the best first.
    public func memories(_ query: String, vector: [Float]?, limit: Int = 14, now: Date = Date()) -> [BrainStore.Hit] {
        let byWords = store.search(query, limit: 30, now: now)
        var byMeaning: [BrainStore.Hit] = []
        if let vector {
            let near = Self.kept(vectors.search(vector, kinds: [.memory], limit: 30, floor: Self.floor))
            byMeaning = store.hits(ids: near.map(\.ref), now: now)
        }
        var all: [Int64: BrainStore.Hit] = [:]
        for hit in byWords + byMeaning { all[hit.id] = hit }
        let fused = MemoryVectors.fuse([byWords.map(\.id), byMeaning.map(\.id)])
        return all.values.sorted { a, b in
            // Relevance first; then what matters to the user (importance) and what's still strong (recent, used).
            let x = (fused[a.id] ?? 0) * (0.6 + 0.4 * a.memory.importance) + 0.004 * BrainModel.strength(a.memory, now: now)
            let y = (fused[b.id] ?? 0) * (0.6 + 0.4 * b.memory.importance) + 0.004 * BrainModel.strength(b.memory, now: now)
            return x > y
        }.prefix(limit).map { $0 }
    }

    /// Promises, summaries and windows close in meaning to the query (beyond what its words ask for).
    public func related(_ vector: [Float]?, now: Date = Date()) -> (loops: [Journal.Loop], chronicle: [String], seen: [Journal.Snapshot]) {
        guard let vector else { return ([], [], []) }
        let near = Self.kept(vectors.search(vector, kinds: [.loop, .chronicle, .snapshot], limit: 12, floor: Self.floor + 0.02),
                             floor: Self.floor + 0.02)
        let loopIDs = Set(near.filter { $0.kind == .loop }.map(\.ref))
        let loops = journal.loops(limit: 200).filter { loopIDs.contains($0.id) }
        let chronicle = near.filter { $0.kind == .chronicle }.prefix(2).compactMap { journal.chronicleLine(rowid: $0.ref) }
        let seen = near.filter { $0.kind == .snapshot }.prefix(2).compactMap { journal.snapshot(id: $0.ref) }
        return (loops, chronicle, seen)
    }

    /// Gives vectors to whatever has none yet, a batch at a time (cheap: EmbeddingGemma's text part, a few
    /// milliseconds a sentence). Returns how many were embedded; stops when `embed` can't (nil).
    @discardableResult
    public func catchUp(batches: Int = 4, embed: ([String]) async -> [[Float]]?) async -> Int {
        var done = 0
        for _ in 0..<batches {
            let missing = vectors.missing(limit: 32)
            guard !missing.isEmpty, let made = await embed(missing.map(\.text)), made.count == missing.count else { break }
            for (item, vector) in zip(missing, made) { vectors.store(item.kind, item.ref, vector) }
            done += missing.count
        }
        if done > 0 { vectors.prune() }
        return done
    }
}
