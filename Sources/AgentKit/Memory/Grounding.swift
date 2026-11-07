import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// What was said, checked against what Murmur knows before anything acts on it. Speech-to-text writes names it has
/// never heard as words it has: on 7 Nov "the AI Builders WhatsApp group" came out as "the CI Builder WhatsApp book",
/// Raipur as "diaper", and "one point seven" stayed words, so nothing in memory matched. Here:
///
/// - Spoken versions become numbers: "one point seven" → "1.7", "version two point one point zero" → "2.1.0".
/// - A run of one to four words that sounds like a name memory holds (a person, a group you message, a project, a
///   place) but isn't spelled like it is read as that name: "CI Builder" → "AI Builders x Blr", "Tanai" → "Tanay".
///   A real English word on its own is left alone ("diaper" is a word; it may have been meant), and so is anything
///   already spelled as a known name.
///
/// No model and no guessing beyond the names memory holds: each correction says what was heard, what it's taken
/// for and why, so the agent (and the user, in the log) can see it and the user's own words still win.
public enum Grounding {
    /// A name memory holds, with what it is ("a WhatsApp group you wrote to").
    public struct Name: Sendable, Equatable {
        public let name: String
        public let what: String
        public init(_ name: String, what: String) {
            self.name = name
            self.what = what
        }
    }

    public struct Fix: Sendable, Equatable {
        public let heard: String
        public let meant: String
        public let why: String
    }

    public struct Result: Sendable, Equatable {
        /// What was said with the corrections made: what memory is searched with and requests are routed by.
        public let text: String
        public let fixes: [Fix]

        public init(text: String, fixes: [Fix] = []) {
            self.text = text
            self.fixes = fixes
        }

        /// For the model: what was heard, and what it most likely meant.
        public var note: String? {
            guard !fixes.isEmpty else { return nil }
            return "The request was spoken and transcribed; these words were most likely misheard (corrected from "
                + "memory; if the request clearly means otherwise, the user's words win):\n"
                + fixes.map { "- \"\($0.heard)\" → \"\($0.meant)\"" + ($0.why.isEmpty ? "" : " (\($0.why))") }.joined(separator: "\n")
        }
    }

    // MARK: Numbers

    static let numberWords: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    ]

    /// "one point seven" → "1.7", "one point seven point zero" → "1.7.0", "1 point 7" → "1.7". Only with "point" or
    /// "dot" between: "one of seven" and "two people" stay words.
    public static func versions(in text: String) -> (text: String, fixes: [Fix]) {
        let number = #"(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|\d{1,3})"#
        let pattern = "(?i)\\b\(number)(?:\\s+(?:point|dot)\\s+\(number))+\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        var out = text, fixes: [Fix] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let heard = String(text[range])
            let parts = heard.lowercased().split { $0 == " " || $0 == "\t" }.map(String.init).filter { $0 != "point" && $0 != "dot" }
            let digits = parts.compactMap { numberWords[$0] ?? Int($0) }
            guard digits.count == parts.count, digits.count >= 2 else { continue }
            let meant = digits.map(String.init).joined(separator: ".")
            guard let outRange = Range(match.range, in: out) else { continue }
            out.replaceSubrange(outRange, with: meant)
            fixes.insert(Fix(heard: heard, meant: meant, why: "a version said aloud"), at: 0)
        }
        return (out, fixes)
    }

    // MARK: Names

    /// Words too common to be a misheard name on their own.
    static let small: Set<String> = [
        "a", "an", "the", "to", "of", "on", "in", "at", "for", "and", "or", "my", "our", "we", "i", "you", "me", "us",
        "is", "are", "was", "it", "this", "that", "with", "from", "by", "as", "be", "do", "did", "have", "has", "send",
        "tell", "ask", "message", "group", "chat", "call", "open", "what", "when", "who", "how", "about", "all", "new",
        "update", "release", "post", "share", "shared", "notified", "linkedin", "whatsapp", "slack", "mail", "email",
    ]

    /// Letters and digits only, lowercased: what two spellings are compared by.
    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// How alike two keys are, 0 to 1 (1 = the same letters).
    static func likeness(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return 1 - Double(AppCatalog.distance(a, b)) / Double(max(a.count, b.count))
    }

    /// How a name sounds, as its consonants: "Herschel" and "Harshal" are both "hrshl", "Thanai" and "Tanay" "tn".
    static func skeleton(_ text: String) -> String {
        var s = key(text)
        for (from, to) in [("ph", "f"), ("th", "t"), ("sch", "sh"), ("ck", "k"), ("q", "k"), ("x", "ks"), ("z", "s"),
                           ("c", "k"), ("w", "v"), ("y", "")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        guard let first = s.first else { return "" }
        var out = String(first)
        for character in s.dropFirst() where !"aeiouh".contains(character) && character != out.last { out.append(character) }
        return out
    }

    /// Sound likeness of two skeletons; nothing for ones too short to tell apart.
    static func soundLikeness(_ a: String, _ b: String) -> Double {
        if a == b, a.count >= 2 { return 1 }
        guard a.count >= 3, b.count >= 3 else { return 0 }
        return likeness(a, b)
    }

    /// Whether a word is in the Mac's dictionary (then on its own it isn't taken for a misheard name). On another
    /// thread than the main one, or without AppKit, every word counts as one: nothing on its own is changed.
    public static func dictionaryWord(_ word: String) -> Bool {
        #if canImport(AppKit)
        guard Thread.isMainThread else { return true }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
        #else
        return true
        #endif
    }

    /// The request with misheard names read as the names memory holds. `isWord`: whether a word is a real word
    /// (the Mac's dictionary by default).
    public static func ground(_ utterance: String, names: [Name], isWord: (String) -> Bool = dictionaryWord) -> Result {
        let spoken = versions(in: utterance)
        var text = spoken.text
        var fixes = spoken.fixes
        // The candidates: each name, and its first words ("AI Builders" of "AI Builders x Blr"), each at least five
        // letters long, so "Raj" or "AI" alone never pulls a word toward it.
        var candidates: [(key: String, words: Int, name: Name, full: Bool)] = []
        var known = Set<String>()
        for name in names {
            let words = name.name.split(separator: " ").map(String.init)
            for count in 1...max(1, min(words.count, 4)) {
                let part = key(words.prefix(count).joined())
                known.insert(part)
                if part.count >= 5 { candidates.append((part, count, name, count == words.count)) }
            }
        }
        guard !candidates.isEmpty else { return Result(text: text, fixes: fixes) }
        // The words as said, with where each is in the text.
        func tokens(_ text: String) -> [(word: String, range: Range<String.Index>)] {
            guard let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}'’]+"#) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range, in: text).map { (String(text[$0]), $0) }
            }
        }
        let words = tokens(text)
        var taken = Array(repeating: false, count: words.count)
        // Longest runs first: "CI Builder" before "Builder".
        for size in stride(from: 4, through: 1, by: -1) where words.count >= size {
            var start = 0
            while start + size <= words.count {
                let span = start..<(start + size)
                defer { start += 1 }
                guard !span.contains(where: { taken[$0] }) else { continue }
                let said = span.map { words[$0].word }
                let saidKey = key(said.joined())
                // Already a name memory holds, as said: right, nothing to do.
                if known.contains(saidKey) { for index in span { taken[index] = true }; continue }
                // A name may hold a small word ("Bank of America") but never starts or ends with one: "to Tana" is
                // "to" and a name, and only the name is misheard.
                guard saidKey.count >= 4, !small.contains(said[0].lowercased()),
                      !small.contains(said[said.count - 1].lowercased()) else { continue }
                // A number isn't part of a misheard name ("1.7 Murmur" stays), and nor is a name already said right
                // ("Tanay reply" isn't a mishearing of "Tanay Kothari").
                if said.contains(where: { $0.allSatisfy(\.isNumber) }) { continue }
                if size > 1, said.contains(where: { known.contains(key($0)) }) { continue }
                // A capital in the middle of a sentence is speech-to-text hearing a name ("reply from Herschel"),
                // even when the word is also in the dictionary.
                func heardAsName(_ index: Int) -> Bool { index > 0 && words[index].word.first?.isUppercase == true }
                // A word on its own that's a real word may have been meant ("diaper").
                if size == 1, isWord(said[0].lowercased()), !heardAsName(start) { continue }
                let realWords = span.filter { index in
                    let word = words[index].word.lowercased()
                    return small.contains(word) || (isWord(word) && !heardAsName(index))
                }.count
                let saidSound = skeleton(said.joined())
                var best: (score: Double, name: Name, key: String, full: Bool)?
                for candidate in candidates where abs(candidate.words - size) <= 1 {
                    // By spelling, or by sound when a word in it isn't one ("Herschel" / "Harshal", "Thanai" / "Tanay").
                    var score = likeness(saidKey, candidate.key)
                    if realWords < size { score = max(score, 0.97 * soundLikeness(saidSound, skeleton(candidate.key))) }
                    // Real words throughout need a closer sound-alike than a run with a stray word in it.
                    let needed = realWords == size ? 0.86 : 0.78
                    guard score >= needed else { continue }
                    // The closest wins; on a tie, a whole name ("Tanay") over the start of a longer one ("Tanay Kothari").
                    let better = score > (best?.score ?? 0) || (score == best?.score && candidate.full && best?.full == false)
                    if better { best = (score, candidate.name, candidate.key, candidate.full) }
                }
                guard let best, best.key != saidKey else { continue }
                let heard = String(text[words[span.lowerBound].range.lowerBound..<words[span.upperBound - 1].range.upperBound])
                fixes.append(Fix(heard: heard, meant: best.name.name, why: best.name.what))
                for index in span { taken[index] = true }
            }
        }
        // Applied from the end, so earlier positions stay right.
        let named = fixes.filter { $0.why != "a version said aloud" }
        for fix in named.reversed() {
            if let range = text.range(of: fix.heard, options: .backwards) { text.replaceSubrange(range, with: fix.meant) }
        }
        return Result(text: text, fixes: fixes)
    }

    // MARK: What memory knows by name

    /// The names worth hearing correctly: people and groups you message (and where), the people, projects,
    /// organisations and places memory knows most about, and nicknames you gave Murmur.
    public static func vocabulary(brain: BrainStore, graph: MemoryGraph, prefs: CommandMemory.Preferences,
                                  limit: Int = 600) -> [Name] {
        var names: [Name] = [], seen = Set<String>()
        func add(_ name: String, _ what: String) {
            let clean = ScreenText.appName(name).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = key(clean)
            guard key.count >= 3, clean.count <= 60, seen.insert(key).inserted else { return }
            names.append(Name(clean, what: what))
        }
        // Who you write to, and where: the strongest sign of a name you'll say.
        for stored in graph.items([.message, .email, .post], limit: 400) where stored.item.mine {
            let app = stored.item.fields["app"] ?? stored.item.kind.rawValue
            for person in stored.item.people { add(person, "you wrote to them on \(app)") }
        }
        for (person, app) in prefs.chatApps { add(person.capitalized, "you message them on \(app)") }
        for (nickname, person) in prefs.aliases { add(person, "\"\(nickname)\" to you") }
        for thread in graph.openThreads(limit: 40) {
            add(thread.person, "a conversation you have open")
        }
        for row in brain.entities(limit: limit) where row.kind != .me {
            add(row.name, row.kind.rawValue)
            for alias in row.aliases.prefix(3) { add(alias, "\(row.kind.rawValue), also called \(row.name)") }
        }
        return names
    }
}
