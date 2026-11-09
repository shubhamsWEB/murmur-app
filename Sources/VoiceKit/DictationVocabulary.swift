import Foundation

/// Names and terms the speech model should get right: the words you've listed in Settings, and the distinctive
/// words in the front window's title ("Sudoku Arena", a project, a person).
///
/// Parakeet only knows the words it was trained on, and a name it rarely heard comes out as the nearest common
/// sounds ("Sudoku" → "Doku"). FluidAudio's word spotter (a small CTC model listening for the listed words in the
/// same audio: Andrusenko et al., Interspeech 2024) proposes swaps. On its own it proposes far too many: on 10 Nov it
/// replaced whole phrases Parakeet had heard right ("So we need to" → "Claude", "Continue" → "Sudoku").
///
/// So Parakeet decides: every word it hears comes with how sure it was (the probability of each piece of the word;
/// a word is as sure as its least sure piece). A word it was sure of is never replaced. A proposed swap is made only
/// when every word it would replace was one Parakeet was unsure of, the swap keeps the number of words, and the
/// listed word is spelled like what was heard (a mishearing, not a different word).
public enum DictationVocabulary {
    /// At most this many terms: the spotter's matching gets looser as the list grows.
    public static let maxTerms = 40

    /// A word Parakeet heard, and how sure it was of it (0…1).
    public struct HeardWord: Equatable, Sendable {
        public let text: String
        public let confidence: Float
        public init(text: String, confidence: Float) {
            self.text = text
            self.confidence = confidence
        }
    }

    /// Below this, Parakeet wasn't sure of a word, and a listed word may take its place. A first setting: the log
    /// lists every unsure word with its score, to tune it from real dictation.
    public static let unsureBelow: Float = 0.6

    /// Parakeet's pieces (SentencePiece tokens: "▁Su", "doku") as words, each as sure as its least sure piece. A
    /// piece starting with "▁" or a space starts a word.
    public static func words(fromPieces pieces: [(text: String, confidence: Float)]) -> [HeardWord] {
        var words: [HeardWord] = []
        var text = ""
        var confidence: Float = 1
        func flush() {
            let clean = text.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { words.append(HeardWord(text: clean, confidence: confidence)) }
            text = ""
            confidence = 1
        }
        for piece in pieces where !piece.text.isEmpty && piece.text != "<blank>" && piece.text != "<pad>" {
            let startsWord = piece.text.hasPrefix("▁") || piece.text.hasPrefix(" ")
            if startsWord { flush() }
            text += piece.text.replacingOccurrences(of: "▁", with: "")
            confidence = min(confidence, piece.confidence)
        }
        flush()
        return words
    }

    /// A swap the spotter proposes: what Parakeet heard, and the listed word it thinks was said.
    public struct Replacement: Equatable, Sendable, CustomStringConvertible {
        public let original: String
        public let replacement: String
        public init(original: String, replacement: String) {
            self.original = original
            self.replacement = replacement
        }
        public var description: String { "\(original) → \(replacement)" }
    }

    /// The swaps to make, in order: those over words Parakeet was unsure of (all of them), keeping the number of
    /// words, and spelled at least half alike.
    public static func believable(_ swaps: [Replacement], heard: [HeardWord],
                                  unsureBelow threshold: Float = unsureBelow) -> [Replacement] {
        var from = 0
        var kept: [Replacement] = []
        for swap in swaps {
            let span = words(swap.original), said = words(swap.replacement)
            guard !span.isEmpty, span.count == said.count,
                  let start = find(span, in: heard, from: from) else { continue }
            let run = heard[start..<(start + span.count)]
            let a = span.joined(separator: " "), b = said.joined(separator: " ")
            guard a != b, run.allSatisfy({ $0.confidence < threshold }),
                  a.lowercased() == b.lowercased() || similarity(a.lowercased(), b.lowercased()) >= 0.5
            else { continue }
            kept.append(swap)
            from = start + span.count
        }
        return kept
    }

    /// The words Parakeet was unsure of, with their scores ("Doku 0.41"), for the log.
    public static func unsure(_ heard: [HeardWord], below threshold: Float = 0.8) -> String {
        heard.filter { $0.confidence < threshold }
            .map { String(format: "%@ %.2f", $0.text, $0.confidence) }
            .joined(separator: ", ")
    }

    /// The text with the swaps made, each at its place (in order, punctuation kept).
    public static func apply(_ swaps: [Replacement], to text: String) -> String {
        var result = text
        var from = result.startIndex
        for swap in swaps {
            let heard = words(swap.original).joined(separator: " ")
            guard !heard.isEmpty, let range = result.range(of: heard, range: from..<result.endIndex) else { continue }
            let said = words(swap.replacement).joined(separator: " ")
            result.replaceSubrange(range, with: said)
            from = result.index(range.lowerBound, offsetBy: said.count, limitedBy: result.endIndex) ?? result.endIndex
        }
        return result
    }

    /// The terms for one dictation, your own words first.
    public static func terms(windowTitle: String?, appName: String?, userWords: [String]) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        func add(_ term: String) {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard clean.count >= 3, seen.insert(clean.lowercased()).inserted else { return }
            terms.append(clean)
        }
        for word in userWords { add(word) }
        for word in screenWords(in: [windowTitle, appName].compactMap { $0 }.joined(separator: " – ")) { add(word) }
        return Array(terms.prefix(maxTerms))
    }

    /// Your words as typed in Settings: separated by commas (or lines).
    public static func userWords(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The words in a title that stand out: a capital letter (or one inside), at least four letters, not shouting,
    /// not a common word or a browser's name.
    static func screenWords(in title: String) -> [String] {
        let pieces = title.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)
        return pieces.compactMap { raw in
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
            guard word.count >= 4, let first = word.first,
                  first.isUppercase || word.dropFirst().contains(where: \.isUppercase),
                  word != word.uppercased(), !common.contains(word.lowercased())
            else { return nil }
            return word
        }
    }

    /// The words of a span, without the punctuation around them.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Where a span of words starts among the words heard, from `from` on.
    static func find(_ span: [String], in heard: [HeardWord], from: Int) -> Int? {
        let wanted = span.map { $0.lowercased() }
        let texts = heard.map { $0.text.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        guard wanted.count <= texts.count, from <= texts.count - wanted.count else { return nil }
        return (from...(texts.count - wanted.count)).first { Array(texts[$0..<($0 + wanted.count)]) == wanted }
    }

    /// How alike two spellings are: 1 − edit distance ÷ the longer length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(longest)
    }

    /// Words not worth listening for: common English, and the names of apps a title ends with.
    static let common: Set<String> = [
        "google", "chrome", "safari", "firefox", "mozilla", "edge", "microsoft", "brave", "opera", "window",
        "untitled", "document", "home", "inbox", "settings", "preferences", "finder", "desktop", "downloads",
        "documents", "terminal", "profile", "private", "incognito", "tabs", "page", "pages", "loading",
        "about", "after", "again", "also", "another", "back", "because", "been", "before", "best", "between", "both",
        "call", "come", "could", "does", "done", "down", "each", "even", "every", "find", "first", "free", "from",
        "full", "game", "games", "give", "good", "great", "have", "help", "here", "high", "into", "just", "know",
        "last", "like", "line", "list", "little", "live", "long", "look", "made", "make", "many", "more", "most",
        "much", "must", "name", "need", "never", "news", "next", "only", "open", "other", "over", "part", "play",
        "puzzle", "read", "right", "same", "search", "should", "show", "side", "some", "start", "still", "such",
        "take", "than", "that", "their", "them", "then", "there", "these", "they", "thing", "this", "those",
        "through", "time", "today", "under", "very", "want", "watch", "well", "were", "what", "when", "where",
        "which", "while", "will", "with", "work", "world", "would", "year", "your", "edit", "view", "file", "sign",
        "login", "welcome", "dashboard", "overview", "project", "projects", "notes", "chat", "chats", "mail",
        "message", "messages", "online",
    ]
}
