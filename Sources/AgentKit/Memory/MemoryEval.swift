import Foundation

/// `murmur-memory eval evals/memory.local.json [--words] [--memory brain.sqlite] [-v]`: scores memory on your own questions, against your own
/// memory, the way a question to Murmur is answered (heard → grounded → recalled). Each question lists what the
/// evidence must hold; "a|b" accepts either. It prints each miss with what came back instead, recall over all of
/// them, and how long a search takes. Nothing is sent anywhere and no model answers: it scores what memory hands the
/// model, which is where answers go wrong. The file names your own people and work, so keep it local
/// (`evals/*.local.json` is ignored by git).
///
///     {"now": "2026-11-07 19:20",                       // optional: score as of then (memory changes daily)
///      "queries": [{"q": "When is my flight?", "expect": ["Flight 6E 537"]},
///                  {"q": "Did we post the release?", "expect": ["Releasing Murmur 1.7", "1.7 is out|impressions"]}]}
public enum MemoryEval {
    struct File: Decodable {
        struct Query: Decodable {
            let q: String
            let expect: [String]
        }
        let now: String?
        let queries: [Query]
    }

    public struct Outcome {
        public let question: String
        public let missing: [String]
        public let heardAs: String?
        public let evidence: String
        public let milliseconds: Double
    }

    public static func run(_ arguments: [String]) -> Never {
        var options = Array(arguments.dropFirst())   // "eval"
        // `--memory <file>`: score a copy (a saved brain.sqlite) instead of the live memory.
        var memory = BrainStore.defaultURL
        if let at = options.firstIndex(of: "--memory"), at + 1 < options.count {
            memory = URL(fileURLWithPath: (options[at + 1] as NSString).expandingTildeInPath)
            options.removeSubrange(at...(at + 1))
        }
        guard let path = options.first(where: { !$0.hasPrefix("-") }) else {
            print("Usage: murmur-memory eval evals/memory.local.json [--words] [--memory brain.sqlite] [-v]")
            exit(1)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            print("murmur-memory: can't read \(path) (expected {\"queries\": [{\"q\": \"…\", \"expect\": [\"…\"]}]})")
            exit(1)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let now = file.now.flatMap(formatter.date(from:)) ?? Date()
        let useVectors = !options.contains("--words") && LocalReader.embedderInstalled
        let verbose = options.contains("-v")

        guard FileManager.default.fileExists(atPath: memory.path) else {
            print("murmur-memory: no memory at \(memory.path)")
            exit(1)
        }
        let index = MemoryIndex(url: memory), vectors = MemoryVectors(url: memory)
        var started = Date()
        index.sync(now: now)
        if memory == BrainStore.defaultURL { index.putMurmur(CommandMemory.actionsForIndex(days: 30)) }
        guard index.count() > 0 else {
            print("murmur-memory: \(memory.path) holds nothing to search yet")
            exit(1)
        }
        print(String(format: "index: %d records, brought up to date in %.0f ms", index.count(), elapsed(since: started)))
        if useVectors {
            // What has no vector yet gets one first, so the score is the one the app gives once it has caught up.
            started = Date()
            var made = 0
            while case let missing = vectors.missing(limit: 64), !missing.isEmpty,
                  let out = LocalReader.embedNow(missing.map(\.text), query: false) {
                for (item, vector) in zip(missing, out) { vectors.store(item.kind, item.ref, vector) }
                made += missing.count
            }
            print(String(format: "meaning: %d vectors (%d new, %.1f s)", vectors.count(), made, elapsed(since: started) / 1000))
        } else {
            print("meaning: off (" + (LocalReader.embedderInstalled ? "--words" : "EmbeddingGemma isn't downloaded") + "): words, names, time and what's owed only")
        }

        let names = Grounding.vocabulary(brain: BrainStore(url: memory), graph: MemoryGraph(url: memory),
                                         prefs: CommandMemory.preferences())
        let recall = BrainRecall(index: index, vectors: useVectors ? vectors : nil)
        var outcomes: [Outcome] = []
        for query in file.queries {
            let grounded = Grounding.ground(query.q, names: names)
            let embedded = useVectors ? LocalReader.embedNow(BrainRecall.parts(grounded.text), query: true) : nil
            let searched = Date()
            let evidence = recall.recall(grounded.text, names: names.map(\.name), vectors: embedded, now: now, limit: 8)
            let milliseconds = elapsed(since: searched)
            outcomes.append(score(query.q, expect: query.expect, heard: grounded, evidence: evidence, milliseconds: milliseconds))
        }

        var passed = 0, total = 0
        for (query, outcome) in zip(file.queries, outcomes) {
            let expected = query.expect.count
            total += expected
            passed += expected - outcome.missing.count
            print((outcome.missing.isEmpty ? "PASS  " : "MISS  ") + outcome.question.prefix(80)
                  + (outcome.heardAs.map { "   [heard as: \($0)]" } ?? ""))
            for missing in outcome.missing { print("        missing: \(missing)") }
            if verbose || !outcome.missing.isEmpty {
                for line in outcome.evidence.split(separator: "\n").prefix(8) { print("          " + line.prefix(160)) }
            }
        }
        let times = outcomes.map(\.milliseconds).sorted()
        print(String(format: "\nrecall@8: %d/%d = %.0f%%   search median %.1f ms, slowest %.1f ms (after the question's vector)",
                     passed, total, total == 0 ? 0 : Double(passed) / Double(total) * 100,
                     times.isEmpty ? 0 : times[times.count / 2], times.last ?? 0))
        exit(passed == total ? 0 : 3)
    }

    /// Which of `expect` the evidence lacks ("a|b": either will do), case-insensitively, in titles and texts.
    static func score(_ question: String, expect: [String], heard: Grounding.Result, evidence: BrainRecall.Evidence,
                      milliseconds: Double) -> Outcome {
        let texts = evidence.found.map { $0.record.title + " " + $0.record.text }
        let missing = expect.filter { wanted in
            !wanted.split(separator: "|").contains { alternative in
                texts.contains { $0.localizedCaseInsensitiveContains(alternative.trimmingCharacters(in: .whitespaces)) }
            }
        }
        return Outcome(question: question, missing: missing, heardAs: heard.fixes.isEmpty ? nil : heard.text,
                       evidence: evidence.text(limit: 4000), milliseconds: milliseconds)
    }

    private static func elapsed(since start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
}
