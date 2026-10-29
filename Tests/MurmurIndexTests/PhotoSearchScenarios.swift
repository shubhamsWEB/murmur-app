import Foundation
@testable import MurmurIndex

/// Libraries with known meaning scores, for what photo search finds: every vector is placed at a chosen cosine from
/// the query (the query is the first axis; the rest of each vector points somewhere random, away from it). Text sits
/// higher than pictures for the same topic, as EmbeddingGemma's does (`Modality`: 0.75–0.86 against 0.67–0.78).
/// `PhotoSearchTests` checks what the search finds in them, the new way and the old (`Behaviour`).
enum PhotoSearchScenarios {
    /// The search as it was before photos had words and near misses (`old`), and as it is (`new`).
    struct Behaviour {
        var smallGroupsBlend: Bool
        var useLabels: Bool
        var nearMisses: Bool
        static let old = Behaviour(smallGroupsBlend: false, useLabels: false, nearMisses: false)
        static let new = Behaviour(smallGroupsBlend: true, useLabels: true, nearMisses: true)

        func apply() {
            Searcher.smallGroupsBlend = smallGroupsBlend
            Searcher.useLabels = useLabels
            Searcher.nearMisses = nearMisses
        }
    }

    /// A deterministic random source (SplitMix64), so every run builds the same library.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func normal(_ mean: Double, _ deviation: Double) -> Double {
            let u = Double.random(in: Double.ulpOfOne..<1, using: &self), v = Double.random(in: 0..<1, using: &self)
            return mean + deviation * (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// The query's vector: the first axis.
    static var query: [Float] {
        var vector = [Float](repeating: 0, count: Vectors.dimension)
        vector[0] = 1
        return vector
    }

    /// A unit vector at `cosine` from the query.
    static func vector(at cosine: Double, using random: inout Seeded) -> [Float] {
        var rest = (1..<Vectors.dimension).map { _ in Float(random.normal(0, 1)) }
        let norm = rest.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let side = Float((1 - cosine * cosine).squareRoot())
        rest = rest.map { $0 / norm * side }
        return [Float(cosine)] + rest
    }

    struct Library {
        let store: IndexStore
        let folder: URL
        /// The photo the query is about, when there is one.
        let target: String?
    }

    /// A library of `docs` documents and `photos` photos (and `screenshots`), all unrelated to the query, plus, when
    /// `withCat`, a photo of what the query asks for: it stands out among the photos (`catCosine`: about 4.5 of their
    /// deviations clear) though it scores below the documents' level. `labelled`: photos have what they show as words (`SegmentKind.labels`), as on a Mac.
    static func library(docs: Int, photos: Int, withCat: Bool = true, catCosine: Double = 0.754, labelled: Bool,
                        seed: UInt64 = 7) throws -> Library {
        var random = Seeded(state: seed)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MurmurPhotoSearch-\(UUID().uuidString)")
        let store = try IndexStore(directory: folder)
        var inode: UInt64 = 0
        func add(_ path: String, _ kind: FileKind) throws -> Int64 {
            inode += 1
            return try store.insert(Candidate(path: path, kind: kind, size: 100, mtime: Double(inode), inode: inode,
                                              device: 1))
        }
        let topics = ["budget", "travel", "invoice", "meeting", "recipe", "contract", "lecture", "roadmap"]
        for index in 0..<docs {
            let id = try add("/lib/docs/note-\(index).txt", .doc)
            let topic = topics[index % topics.count]
            try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1,
                                 text: "Notes on the \(topic) for week \(index)",
                                 vector: vector(at: min(0.95, random.normal(0.80, 0.025)), using: &random))
            try store.finish(id, state: "done")
        }
        let scenes = ["beach, sand, outdoor", "mountain, sky, outdoor", "food, plate", "car, vehicle, road",
                      "people, group", "document, paper, text", "flower, plant", "building, city"]
        for index in 0..<photos {
            let id = try add("/lib/photos/IMG_\(1000 + index).jpeg", .image)
            try store.addSegment(file: id, kind: .image, modality: .image,
                                 vector: vector(at: random.normal(0.70, 0.012), using: &random))
            if labelled {
                try store.addSegment(file: id, kind: .labels, modality: .text, text: scenes[index % scenes.count])
            }
            try store.finish(id, state: "done")
        }
        var target: String?
        if withCat {
            let path = "/lib/photos/WhatsApp Image 2026-10-28 at 18.02.11.jpeg"
            let id = try add(path, .image)
            try store.addSegment(file: id, kind: .image, modality: .image, vector: vector(at: catCosine, using: &random))
            if labelled {
                try store.addSegment(file: id, kind: .labels, modality: .text, text: "cat, feline, mammal, animal")
            }
            try store.finish(id, state: "done")
            target = path
        }
        return Library(store: store, folder: folder, target: target)
    }

    /// The search for `words` (the query vector: `query`) with `behaviour`: the paths found, best first.
    static func search(_ library: Library, _ words: String, _ behaviour: Behaviour, vector: [Float]? = nil,
                       kinds: Set<FileKind>? = nil) throws -> [String] {
        behaviour.apply()
        defer { Behaviour.new.apply() }
        let searcher = try Searcher(store: library.store)
        return try searcher.search(words, queryVector: vector ?? query, kinds: kinds).map(\.path)
    }

    /// Where the target photo is in what's found (1 = first), or nil.
    static func rank(of library: Library, _ words: String, _ behaviour: Behaviour) throws -> Int? {
        try search(library, words, behaviour).firstIndex(of: library.target ?? "").map { $0 + 1 }
    }
}
