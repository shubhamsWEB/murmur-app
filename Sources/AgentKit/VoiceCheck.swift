import Foundation

/// A short check of how well Murmur hears you: you read three short sentences in one go (about ten seconds), Murmur
/// compares what it heard with what they say, word by word, and the names it got wrong become dictionary entries
/// (the word, and how it was heard), so dictation and custom vocabulary get them right from then on.
public enum VoiceCheck {
    /// Names, places and app names: what accents and speech models trip over most.
    public static let standard = [
        "Play Samay Raina videos on YouTube.",
        "Send the invoice to Priya Sharma on Friday.",
    ]

    /// The two standard sentences and one with your own names (or a stand-in when you gave none).
    public static func sentences(names: [String]) -> [String] {
        let own = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let personal: String
        switch own.count {
        case 0: personal = "Book a cab from Koramangala to Whitefield."
        case 1: personal = "Remind me to call \(own[0]) tomorrow."
        case 2: personal = "Remind me to call \(own[0]) and \(own[1]) tomorrow."
        default: personal = "Tell \(own[0]) and \(own[1]) about \(own[2])."
        }
        return standard + [personal]
    }

    /// Something said that was heard differently.
    public struct Mistake: Sendable, Hashable, Identifiable {
        public var id: String { expected + "→" + heard }
        public let expected: String
        public let heard: String
        /// A name or a term (capitalised mid-sentence, or one of yours): worth a dictionary entry.
        public let isName: Bool
    }

    public struct Result: Sendable {
        public let correct: Int
        public let total: Int
        public let mistakes: [Mistake]
        public var accuracy: Double { total == 0 ? 1 : Double(correct) / Double(total) }
    }

    /// Compares what was said with what was heard, word by word (case and punctuation aside). Neighbouring mistakes
    /// are one mistake, and a mistake inside a name takes in the rest of the name ("Samay Raina" heard as "samai
    /// raina", not just "Samay").
    public static func compare(said: String, heard: String, names: [String] = []) -> Result {
        let expected = tokens(said), got = tokens(heard)
        let a = expected.map(normalized), b = got.map(normalized)
        let nameWords = Set(names.flatMap { tokens($0).map(normalized) })
        // Edit-distance table, then walk back to pair each word with what it was heard as.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        if !a.isEmpty && !b.isEmpty {
            for i in 1...a.count {
                for j in 1...b.count {
                    table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1]
                        : 1 + min(table[i - 1][j - 1], table[i - 1][j], table[i][j - 1])
                }
            }
        }
        var pairs: [(said: Int?, heard: Int?)] = []
        var i = a.count, j = b.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1], table[i][j] == table[i - 1][j - 1] {
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, j > 0, table[i][j] == table[i - 1][j - 1] + 1 {
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, table[i][j] == table[i - 1][j] + 1 {
                pairs.append((i - 1, nil)); i -= 1
            } else {
                pairs.append((nil, j - 1)); j -= 1
            }
        }
        pairs.reverse()
        let isWrong = pairs.map { pair -> Bool in
            guard let s = pair.said, let h = pair.heard else { return true }
            return a[s] != b[h]
        }
        func isNameWord(_ index: Int?) -> Bool {
            guard let index else { return false }
            let word = expected[index]
            return nameWords.contains(a[index]) || (index > 0 && word.first?.isUppercase == true)
        }
        // Mistakes, widened over the rest of a name they're in.
        var marked = isWrong
        var changed = true
        while changed {
            changed = false
            for k in pairs.indices where !marked[k] {
                let nextToMistake = (k > 0 && marked[k - 1]) || (k + 1 < pairs.count && marked[k + 1])
                if nextToMistake, isNameWord(pairs[k].said),
                   (k > 0 && marked[k - 1] && isNameWord(pairs[k - 1].said)) || (k + 1 < pairs.count && marked[k + 1] && isNameWord(pairs[k + 1].said)) {
                    marked[k] = true
                    changed = true
                }
            }
        }
        var mistakes: [Mistake] = []
        var k = 0
        while k < pairs.count {
            guard marked[k] else { k += 1; continue }
            var saidWords: [String] = [], heardWords: [String] = []
            var name = false
            while k < pairs.count, marked[k] {
                if let s = pairs[k].said { saidWords.append(expected[s]); if isNameWord(s) { name = true } }
                if let h = pairs[k].heard { heardWords.append(got[h]) }
                k += 1
            }
            mistakes.append(Mistake(expected: saidWords.joined(separator: " "), heard: heardWords.joined(separator: " "),
                                    isName: name))
        }
        let correct = zip(pairs, isWrong).filter { $0.0.said != nil && !$0.1 }.count
        return Result(correct: correct, total: a.count, mistakes: mistakes)
    }

    /// Dictionary entries to suggest: misheard names, with how they were heard. A name that wasn't heard at all
    /// (nothing in its place) is still worth listening for, so it comes without a "heard as".
    /// A "heard as" that is one ordinary word ("the", "summer") would be swapped everywhere you really mean it, so
    /// `isRealWord` drops it: the name is still listened for, it just gets no swap.
    public static func suggestions(_ mistakes: [Mistake],
                                   isRealWord: (String) -> Bool = { _ in false }) -> [DictionaryEntry] {
        var seen = Set<String>()
        return mistakes.filter(\.isName).compactMap { mistake in
            let written = mistake.expected.trimmingCharacters(in: .punctuationCharacters)
            guard written.count >= 3, seen.insert(written.lowercased()).inserted else { return nil }
            let heard = mistake.heard.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let risky = heard.isEmpty || (!heard.contains(" ") && isRealWord(heard))
            return DictionaryEntry(written: written, heard: risky ? [] : [heard])
        }
    }

    static func tokens(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { !$0.isEmpty }
    }

    static func normalized(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "-", with: "")
    }
}
