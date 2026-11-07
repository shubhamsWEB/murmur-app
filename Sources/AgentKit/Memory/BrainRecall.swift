import Foundation

/// One way into Murmur's memory and one way out. Every question (the quick memory answer, the agent's brief,
/// ask_memory, Claude Code and Cursor through the memory server) is read once and searched across everything memory
/// holds at once (`MemoryIndex`); what comes back is one evidence pack in one format.
///
/// How a question is searched, with no keyword lists deciding where to look:
/// 1. Read once: misheard names corrected (Grounding, before this), its parts ("what did we release, and have we
///    posted about it?" is two searches, the second knowing what the first is about), the span it names ("today",
///    "last week"), whether it's about the user ("did we", "my"), whether it asks for the latest, or what's owed.
/// 2. Several ways of finding at once, each a ranked list: words (BM25 with stemming, so "release" finds
///    "Releasing"), meaning (EmbeddingGemma vectors), who and what it names, the span it names, what's owed.
/// 3. The lists fused by reciprocal rank (k = 60), then weighed by what each record is: what the user did and told
///    Murmur above what was merely seen; how much of the question it covers; how recent it is; for "latest", the
///    highest version among them. At most four of a kind, so one kind can't crowd out the rest.
/// 4. Nothing found by words, and nothing close in meaning: nothing at all (an honest "not in memory", not the
///    nearest noise).
///
/// Measured on the user's own questions from 5 to 7 Nov against a copy of their memory: the right evidence in the
/// top 8 for 29 of 31 checks (the old way put "Jason (Murmur)" and 1.5.1 above two records of releasing 1.7.0).
public final class BrainRecall: @unchecked Sendable {
    public struct Found: Sendable {
        public let record: MemoryIndex.Record
        public let score: Double
    }

    public struct Evidence: Sendable {
        public let question: String
        public let found: [Found]
        public var isEmpty: Bool { found.isEmpty }

        /// The pack as lines a model reads: what kind of thing each is, when, and what it says.
        public func text(limit: Int = 6000, calendar: Calendar = .current) -> String {
            var lines: [String] = []
            var length = 0
            for item in found {
                let line = BrainRecall.line(item.record, calendar: calendar)
                guard length + line.count <= limit else { break }
                lines.append(line)
                length += line.count + 1
            }
            return lines.joined(separator: "\n")
        }
    }

    /// How a question reads, before it's searched.
    public struct Reading: Sendable, Equatable {
        public var text: String
        public var terms: [String]
        public var versions: Set<String>
        public var span: (from: Date, to: Date)?
        public var aboutTheUser: Bool
        public var owed: Bool
        public var latest: Bool
        public var names: [String]
        /// What an earlier part of the question was about ("release" in "what did we release, and have we posted
        /// about it?"): weighs in on how much of the question a record covers, but isn't searched for by itself.
        public var topic: [String] = []
        /// About telling people: posted, shared, notified, sent, announced. What the user sent or posted then beats
        /// sessions of reading a feed.
        public var telling: Bool = false
        /// Asking what they did over a stretch of time ("summary of today's work", "what did I do yesterday"): the
        /// summaries of their hours and days, and the stretches of work, are the answer.
        public var recap: Bool = false

        public static func == (a: Reading, b: Reading) -> Bool {
            a.text == b.text && a.terms == b.terms && a.versions == b.versions && a.aboutTheUser == b.aboutTheUser
                && a.owed == b.owed && a.latest == b.latest && a.names == b.names
                && a.span?.from == b.span?.from && a.span?.to == b.span?.to
        }
    }

    let index: MemoryIndex
    let vectors: MemoryVectors?

    public init(index: MemoryIndex, vectors: MemoryVectors?) {
        self.index = index
        self.vectors = vectors
    }

    // MARK: Reading a question

    /// Words that say how something is asked, not what it's about.
    static let asking: Set<String> = [
        "what", "when", "where", "which", "who", "whom", "whose", "why", "how", "did", "do", "does", "done", "doing", "is",
        "are", "was", "were", "be", "been", "am", "have", "has", "had", "can", "could", "would", "should", "will", "shall",
        "may", "might", "must", "the", "a", "an", "to", "of", "on", "in", "at", "for", "and", "or", "but", "with", "from",
        "by", "as", "so", "just", "also", "please", "tell", "know", "give", "get", "got", "let", "me", "my", "mine", "i",
        "we", "us", "our", "ours", "you", "your", "it", "its", "this", "that", "these", "those", "there", "here", "any",
        "all", "some", "about", "regarding", "whatever", "else", "exactly", "recently", "recent", "latest", "last", "new",
        "newest", "now", "then", "than", "very", "really", "thing", "things", "uh", "um", "okay", "ok", "yeah", "hey",
        "into", "onto", "out", "up", "if", "whether", "not", "no", "yes", "check", "find", "show", "remind", "recall",
        "remember", "memory", "anything", "something", "someone", "anyone", "one", "ever",
    ]

    /// A question as it will be searched.
    public static func read(_ text: String, names: [String], now: Date = Date(), calendar: Calendar = .current) -> Reading {
        let words = MemoryRoute.spoken(text)
        let lower = " " + words.joined(separator: " ") + " "
        let terms = words.filter { $0.count > 1 && !asking.contains($0) && $0.range(of: #"^[\d.]+$"#, options: .regularExpression) == nil }
        var seen = Set<String>()
        let unique = terms.filter { seen.insert($0).inserted }
        let named = names.filter { $0.count >= 3 && lower.contains(" " + $0.lowercased() + " ") }
        let owed = lower.range(of: #" (need to|needs to|have to|has to|to do|todo|should i|pending|owe|owed|due|deadline|on my plate|follow up|waiting on) "#,
                               options: .regularExpression) != nil
        // Asking what's owed, "need" and "pending" say how it's asked, not what about.
        let owing: Set<String> = ["need", "needs", "pending", "owe", "owed", "due", "deadline", "plate", "follow", "waiting", "todo"]
        let content = owed ? unique.filter { !owing.contains($0) } : unique
        return Reading(text: text, terms: content, versions: MemoryIndex.versionKeys(text),
                       span: MemoryRecall.span(of: text, now: now, calendar: calendar),
                       aboutTheUser: [" i ", " we ", " my ", " our ", " me ", " us ", " i've ", " we've "].contains(where: lower.contains),
                       owed: owed,
                       latest: [" latest ", " recent ", " recently ", " newest ", " last ", " new "].contains(where: lower.contains),
                       names: named,
                       telling: lower.range(of: #" (notif\w*|post|posted|posts|posting|shar\w*|sent|send|told|tell|announc\w*|tweet\w*|messag\w*|email\w*|mail\w*|repl\w*|publish\w*|inform\w*|update) "#,
                                            options: .regularExpression) != nil,
                       recap: lower.range(of: #" (summary|summari[sz]e|recap|wrap up|what did i do|what have i done|what did we do|my work|worked on|working on|my day|been doing|spent) "#,
                                          options: .regularExpression) != nil)
    }

    /// The questions in what was said: "what did we release, and have we posted about it on LinkedIn?" is two.
    public static func parts(_ text: String) -> [String] {
        let pattern = #"(?i)[,;]?\s+(?:and|also|plus)\s+(?:also\s+)?(?=(?:have|has|had|did|do|does|was|were|is|are|what|when|who|which|how|where|whether|if)\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        var parts: [String] = [], start = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            parts.append(String(text[start..<range.lowerBound]))
            start = range.upperBound
        }
        parts.append(String(text[start...]))
        let kept = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.split(separator: " ").count >= 2 }
        return kept.isEmpty ? [text] : kept
    }

    // MARK: Searching

    /// The evidence for a question (already grounded). `embed`: the question's parts as vectors (nil without the
    /// model: words, names and time still find).
    public func recall(_ question: String, names: [String], vectors embedded: [[Float]]? = nil, now: Date = Date(),
                       calendar: Calendar = .current, limit: Int = 10) -> Evidence {
        let parts = Self.parts(question)
        guard parts.count > 1 else {
            let reading = Self.read(question, names: names, now: now, calendar: calendar)
            return Evidence(question: question, found: one(reading, vector: embedded?.first, now: now, limit: limit))
        }
        // A later part is about what the first named ("…and have we posted about it?"): its words come along.
        let topic = Self.read(parts[0], names: names, now: now, calendar: calendar).terms
        var packs: [[Found]] = []
        for (position, part) in parts.enumerated() {
            var reading = Self.read(part, names: names, now: now, calendar: calendar)
            if position > 0 { reading.topic = topic.filter { !reading.terms.contains($0) } }
            let vector = embedded.flatMap { position < $0.count ? $0[position] : nil }
            packs.append(one(reading, vector: vector, now: now, limit: limit))
        }
        // Each part's best first, in turn, so no part is crowded out.
        var merged: [Found] = [], taken = Set<String>()
        for rank in 0..<limit {
            for pack in packs where rank < pack.count && taken.insert(pack[rank].record.source).inserted {
                merged.append(pack[rank])
            }
        }
        return Evidence(question: question, found: Array(merged.prefix(limit + 2)))
    }

    /// One question's evidence, best first.
    func one(_ reading: Reading, vector: [Float]?, now: Date, limit: Int) -> [Found] {
        var ranks: [Int64: [String: Int]] = [:]
        func rank(_ ids: [Int64], _ arm: String) {
            for (position, id) in ids.enumerated() where ranks[id]?[arm] == nil { ranks[id, default: [:]][arm] = position }
        }
        // Words: any of them, stemmed; versions by their keys.
        let words = reading.terms.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            + reading.versions.map { "extra:\"\($0)\"" }
        rank(index.search(words.joined(separator: " OR "), limit: 150), "words")
        let foundByWords = !(ranks.isEmpty)
        // Meaning.
        var closest: Float = 0
        if let vector, let vectors {
            let hits = vectors.search(vector, limit: 60, floor: 0.6)
            closest = hits.first?.score ?? 0
            rank(hits.compactMap { index.id(of: "\($0.kind.rawValue):\($0.ref)") }, "meaning")
        }
        // Who and what it names, the span it names, what's owed.
        for name in reading.names { rank(index.naming(name), "name") }
        // A version is as exact as a name ("1.7": whatever holds 1.7 or 1.7.0).
        if !reading.versions.isEmpty {
            rank(index.search(reading.versions.sorted().map { "extra:\"\($0)\"" }.joined(separator: " OR "), limit: 80), "version")
        }
        if let span = reading.span {
            rank(index.within(span.from, span.to, kinds: reading.recap ? [.summary, .did] : [.did, .summary, .conversation, .yours, .murmur],
                              limit: 120), "time")
        }
        if reading.owed { rank(index.owed(), "owed") }
        // Nothing by words, nothing close in meaning, nothing by name, time or what's owed: memory doesn't have it.
        let foundOtherwise = ranks.values.contains { arms in arms.keys.contains { arm in arm != "meaning" } }
        guard foundByWords || closest >= 0.72 || foundOtherwise else {
            return []
        }
        let records = index.records(Array(ranks.keys))
        guard !records.isEmpty else { return [] }
        let newest = records.values.compactMap(\.at).max() ?? now
        let weights: [String: Double] = ["words": 1.0, "meaning": 1.0, "name": 1.2, "version": 1.2, "time": 1.0, "owed": 1.2]
        var scored: [(Double, MemoryIndex.Record)] = []
        for (id, arms) in ranks {
            guard let record = records[id] else { continue }
            var score = arms.reduce(0) { $0 + (weights[$1.key] ?? 1) / (60 + Double($1.value)) }
            // How much of the question it covers: a record matching most of what was asked beats one matching a word.
            var covered = Self.coverage(of: record, terms: reading.terms, topic: reading.topic, versions: reading.versions)
            if arms.keys.contains(where: { ["name", "time", "owed"].contains($0) }) { covered = max(covered, 0.6) }
            score *= record.prior * pow(0.5 + covered, 2)
            if reading.aboutTheUser, record.actor == "me" || record.actor == "murmur" { score *= 1.25 }
            // "Have we posted / told / sent…": what the user sent or posted (or Murmur sent for them) is the answer.
            if reading.telling, record.kind == .did || record.kind == .murmur, record.source.hasPrefix("item:") || record.kind == .murmur {
                score *= 1.6
            }
            // "What do I need to do?": what's owed is the answer, whatever its words.
            if reading.owed, arms["owed"] != nil { score *= 1.6 }
            // "Summary of today's work": the summaries of those hours, then the stretches of work.
            if reading.recap {
                if record.kind == .summary { score *= 2.0 } else if record.source.hasPrefix("episode:") { score *= 1.3 }
            }
            if let span = reading.span {
                score *= record.at.map { $0 >= span.from && $0 < span.to } == true ? 1.4 : 0.35
            }
            let days = max(0, newest.timeIntervalSince(record.at ?? .distantPast) / 86400)
            score *= 1 / (1 + days / (reading.latest ? 3 : 14))
            scored.append((score, record))
        }
        // "Latest", "newest", "last": of the versions the best candidates mention, the highest is the latest.
        if reading.latest {
            let top = scored.sorted { $0.0 > $1.0 }.prefix(40)
            let versions = top.compactMap { Self.highestVersion(in: $0.1.title + " " + $0.1.text.prefix(300)) }
            if let highest = versions.max(by: { ItemReader.newerVersion($1, than: $0) }) {
                // The same release line counts ("Murmur 1.7 is out" and "Releasing Murmur 1.7.0").
                let line = Self.releaseLine(highest)
                scored = scored.map { found -> (Double, MemoryIndex.Record) in
                    let version = Self.highestVersion(in: found.1.title + " " + found.1.text.prefix(300))
                    return version.map(Self.releaseLine) == line ? (found.0 * 1.6, found.1) : found
                }
            }
        }
        var out: [Found] = [], perKind: [MemoryIndex.Kind: Int] = [:], titles = Set<String>()
        for (score, record) in scored.sorted(by: { $0.0 > $1.0 }) {
            // The same thing twice (a release read as four episodes, a window seen three times): once. Facts share
            // titles ("About you") and differ by what they say.
            let key = record.kind.rawValue + ":" + Grounding.key(record.kind == .fact ? record.title + " " + record.text.prefix(80)
                                                                                         : record.title).prefix(90)
            guard !titles.contains(key), perKind[record.kind, default: 0] < (record.kind == .saw ? 3 : 4) else { continue }
            titles.insert(key)
            perKind[record.kind, default: 0] += 1
            out.append(Found(record: record, score: score))
            if out.count >= limit { break }
        }
        return out
    }

    /// The share of the question's words a record holds (by the start of each word: "posted" holds "post"), a version
    /// it names counting as one of them.
    static func coverage(of record: MemoryIndex.Record, terms: [String], topic: [String] = [], versions: Set<String> = []) -> Double {
        guard !terms.isEmpty || !topic.isEmpty || !versions.isEmpty else { return 0.5 }
        // The start of a long window is enough to tell (and keeps a search over hundreds of candidates in milliseconds).
        let raw = (record.title + " " + record.text.prefix(1200) + " " + record.entities.joined(separator: " ")).lowercased()
        let body = " " + String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? $0 : " "
        }))
        func holds(_ term: String) -> Bool { body.contains(" " + String(term.prefix(max(4, term.count - 2)))) }
        // The question's own words count in full, an earlier part's at half.
        let holdsVersion = !versions.isEmpty && !versions.isDisjoint(with: MemoryIndex.versionKeys(record.title + " " + record.text))
        let held = Double(terms.filter(holds).count) + 0.5 * Double(topic.filter(holds).count) + (holdsVersion ? 1 : 0)
        return held / (Double(terms.count) + 0.5 * Double(topic.count) + (versions.isEmpty ? 0 : 1))
    }

    /// The highest version a text mentions ("1.7.0" in "Releasing Murmur 1.7.0").
    static func highestVersion(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b\d+\.\d+(?:\.\d+)?\b"#) else { return nil }
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
        return found.max { ItemReader.newerVersion($1, than: $0) }
    }

    /// A version's major and minor: "1.7.0" and "1.7" are both "1.7".
    static func releaseLine(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    // MARK: Writing it out

    static func label(_ record: MemoryIndex.Record) -> String {
        if record.actor == "murmur" { return "Murmur did for you" }
        switch record.kind {
        case .did: return "you did"
        case .yours: return "yours"
        case .conversation: return "a conversation"
        case .fact: return record.source.hasPrefix("memory:") ? "known" : "fact"
        case .summary: return "summary of your time"
        case .promise: return "owed or promised"
        case .murmur: return "Murmur did for you"
        case .saw: return record.actor == "me" ? "you wrote, on screen" : "seen on screen"
        }
    }

    static func line(_ record: MemoryIndex.Record, calendar: Calendar) -> String {
        let when = record.at.map { ScreenDates.formatter("EEE d MMM HH:mm", calendar).string(from: $0) } ?? "undated"
        let text = record.text.replacingOccurrences(of: "\n", with: " ").prefix(record.kind == .saw ? 260 : 420)
        let title = record.title.isEmpty ? "" : record.title + ": "
        return "- [\(label(record)), \(when)] \(title)\(text)"
    }
}
