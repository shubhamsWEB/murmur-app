import Foundation
import Testing
@testable import AgentKit

/// Search by meaning: vectors kept and searched, rankings fused, everything new given its vector.
struct MemorySearchTests {
    /// A stand-in for EmbeddingGemma: each concept is a direction, and words that mean the same share it
    /// ("car", "drives", "tesla" are all "vehicle"), the way the real model places them.
    static let concepts: [String: Int] = [
        "car": 0, "drives": 0, "tesla": 0, "vehicle": 0, "manager": 1, "reports": 1, "boss": 1,
        "deck": 2, "slides": 2, "presentation": 2, "trek": 3, "hike": 3, "kudremukh": 3,
    ]
    static func embed(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0.01, count: 768)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let concept = concepts[String(word)] { vector[concept] += 1 }
        }
        return vector
    }

    func setup() -> (BrainStore, Journal, MemoryVectors) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString).sqlite")
        return (BrainStore(url: file), Journal(url: file), MemoryVectors(url: file))
    }

    func fact(_ about: String, _ text: String) -> BrainModel.Candidate {
        BrainModel.Candidate(about: about, aboutKind: .person, text: text, kind: .fact, confidence: 0.9, origin: .notes)
    }

    @Test func onlyClearMatchesByMeaningCount() {
        func hits(_ scores: [Float]) -> [MemoryVectors.Hit] {
            scores.enumerated().map { MemoryVectors.Hit(kind: .memory, ref: Int64($0.offset), score: $0.element) }
        }
        // EmbeddingGemma 2's real scores (2026-11-05): "open Safari" against memories, then "what car does Priya have".
        #expect(MemorySearch.kept(hits([0.64, 0.63, 0.61])).isEmpty)
        #expect(MemorySearch.kept(hits([0.87, 0.75, 0.68])).map(\.ref) == [0])
        #expect(MemorySearch.kept(hits([0.76, 0.72, 0.65])).map(\.ref) == [0, 1])
    }

    @Test func vectorsAreCutAndNormalised() {
        let cut = MemoryVectors.cut([Float](repeating: 2, count: 768))
        #expect(cut.count == 256)
        #expect(abs(cut.reduce(0) { $0 + $1 * $1 } - 1) < 0.001)
        #expect(MemoryVectors.cut([1, 2, 3]).isEmpty)
    }

    @Test func fusionRewardsAgreement() {
        let fused = MemoryVectors.fuse([["a", "b", "c"], ["c", "a"]])
        #expect(fused["a"]! > fused["c"]! && fused["c"]! > fused["b"]!)
    }

    @Test func findsByMeaningWhatWordsMiss() async {
        let (store, journal, vectors) = setup()
        store.apply([fact("Priya Shah", "Priya Shah drives a Tesla"),
                     fact("Arjun Mehta", "Arjun Mehta reports to Priya Shah"),
                     fact("Rahul", "Rahul went on a trek to Kudremukh")], item: nil)
        journal.take([Journal.Promise(summary: "Send Priya the Q3 deck", person: "Priya")], evidence: [])
        let search = MemorySearch(store: store, journal: journal, vectors: vectors)
        let made = await search.catchUp { texts in texts.map(Self.embed) }
        #expect(made == 4 && vectors.missing().isEmpty)
        // No word of "vehicle" is in any memory: words alone find nothing.
        #expect(store.search("which vehicle").isEmpty)
        let byMeaning = search.memories("which vehicle", vector: Self.embed("which vehicle"))
        #expect(byMeaning.first?.memory.text == "Priya Shah drives a Tesla")
        #expect(search.memories("who is my boss", vector: Self.embed("boss")).first?.memory.text.contains("reports") == true)
        // Without a vector, the same search still works by words and names.
        #expect(search.memories("Priya", vector: nil).count >= 2)
        // Promises by meaning: "slides" finds the deck.
        #expect(search.related(Self.embed("the slides")).loops.first?.summary == "Send Priya the Q3 deck")
    }

    @Test func changedOrGoneThingsLoseTheirVectors() async {
        let (store, journal, vectors) = setup()
        var chat = Journal.Capture(app: "Slack", bundle: "", title: "#trip", text: "Planning a hike to Kudremukh this weekend")
        let shot = journal.record(chat)
        let search = MemorySearch(store: store, journal: journal, vectors: vectors)
        await search.catchUp { $0.map(Self.embed) }
        #expect(vectors.count() == 1)
        chat.text += " with Rahul and Priya"
        journal.record(chat)   // the same window, newer text
        #expect(vectors.missing().contains { $0.kind == .snapshot && $0.ref == shot.id })
        await search.catchUp { $0.map(Self.embed) }
        journal.forgetAll()
        vectors.prune()
        #expect(vectors.count() == 0)
    }

    @Test func noEmbedderMeansNoVectorsAndNoHarm() async {
        let (store, journal, vectors) = setup()
        store.apply([fact("Priya Shah", "Priya Shah drives a Tesla")], item: nil)
        let made = await MemorySearch(store: store, journal: journal, vectors: vectors).catchUp { _ in nil }
        #expect(made == 0 && vectors.missing().count == 1)
    }
}

/// The real thing: `murmur-engine memory-service` with EmbeddingGemma 2 and the reading model. Set MURMUR_MEMORY_SOCKET
/// to a running service's socket to run it.
struct MemoryServiceTests {
    static let socket = ProcessInfo.processInfo.environment["MURMUR_MEMORY_SOCKET"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: socket != nil)) func searchesByMeaningWithTheRealModel() async throws {
        let socket = try #require(Self.socket)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString).sqlite")
        let store = BrainStore(url: file), journal = Journal(url: file), vectors = MemoryVectors(url: file)
        func fact(_ about: String, _ text: String) -> BrainModel.Candidate {
            BrainModel.Candidate(about: about, aboutKind: .person, text: text, kind: .fact, confidence: 0.9, origin: .notes)
        }
        store.apply([fact("Priya Shah", "Priya Shah drives a Tesla Model 3"), fact("Arjun Mehta", "Arjun Mehta reports to Priya Shah"),
                     fact("Rahul", "Rahul went on a trek to Kudremukh"), fact("Sanskriti Singh", "Sanskriti Singh is a product designer")],
                    item: nil)
        journal.take([Journal.Promise(summary: "Send Priya the Q3 deck by Friday", person: "Priya")], evidence: [])
        let search = MemorySearch(store: store, journal: journal, vectors: vectors)
        let made = await search.catchUp { await LocalReader.embed($0, query: false, socket: socket, start: false) }
        #expect(made == 5)
        func top(_ query: String) async -> String? {
            let vector = await LocalReader.embed([query], query: true, socket: socket, start: false)?.first
            return search.memories(query, vector: vector, limit: 3).first?.memory.text
        }
        #expect(await top("what car does Priya have") == "Priya Shah drives a Tesla Model 3")
        #expect(await top("any hiking plans") == "Rahul went on a trek to Kudremukh")
        #expect(await top("who designs our product") == "Sanskriti Singh is a product designer")
        // An unrelated command brings nothing in by meaning.
        let unrelated = await LocalReader.embed(["turn the volume down"], query: true, socket: socket, start: false)?.first
        #expect(search.memories("turn the volume down", vector: unrelated).isEmpty)
        let promise = await LocalReader.embed(["did I promise anyone slides"], query: true, socket: socket, start: false)?.first
        #expect(search.related(promise).loops.first?.summary == "Send Priya the Q3 deck by Friday")
        // And the reading model answers, as JSON when asked.
        let json = await LocalReader.ask(system: "Reply with JSON: {\"name\": \"...\"}", user: "My name is Sam.", json: true,
                                         maxTokens: 40, socket: socket, start: false)
        #expect((try? JSONSerialization.jsonObject(with: Data((json ?? "").utf8))) != nil)
    }
}
