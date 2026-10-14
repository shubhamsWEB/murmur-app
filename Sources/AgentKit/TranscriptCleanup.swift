import Foundation

/// Fixes that never change what you said: filler sounds ("um", "uh") go, a number you corrected yourself ("at 2,
/// sorry, 3") keeps only the correction, and your dictionary's spellings apply (`PersonalDictionary.apply`). No model.
public enum TranscriptCleanup {
    /// Sounds, not words: removed wherever they stand alone.
    static let fillers: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhm", "erm", "er", "hmm", "hmmm", "mm", "mhm", "ah"]

    private static let numberWord = "zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"
        + "fifteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred"
    private static var number: String { #"(?:\d+(?:[:.]\d+)?|"# + numberWord + #")(?:\s?(?:am|pm|a\.m\.|p\.m\.))?"# }

    /// Filler sounds and self-corrected numbers removed, then your spellings. Instant.
    @MainActor
    public static func quick(_ text: String, dictionary: PersonalDictionary) -> String {
        dictionary.apply(correctedNumbers(withoutFillers(text)))
    }

    static func withoutFillers(_ text: String) -> String {
        let alternatives = fillers.sorted { $0.count > $1.count }.joined(separator: "|")
        // "we should, uh, meet" → "we should meet"; the full stop after "it, uh." stays.
        var out = text.replacingOccurrences(of: #"(?i)(?:,\s*)?(?<![\p{L}\p{N}'-])(?:"# + alternatives
                                            + #")(?![\p{L}\p{N}'-])(?:,|…)?"#, with: "", options: .regularExpression)
        out = tidy(out)
        // A sentence that started with a filler starts with a capital again.
        if let first = out.first, first.isLowercase, let original = text.first, original.isUppercase {
            out = first.uppercased() + out.dropFirst()
        }
        return out
    }

    /// "at 2, sorry, 3" → "at 3"; "five, I mean six" → "six".
    static func correctedNumbers(_ text: String) -> String {
        let pattern = #"(?i)(?<![\p{L}\p{N}])("# + number + #")\s*,?\s+(?:sorry|actually|no|i mean|make that|or rather)\s*,?\s+("#
            + number + #")(?![\p{L}\p{N}])"#
        return tidy(text.replacingOccurrences(of: pattern, with: "$2", options: .regularExpression))
    }

    /// Spaces put back in order after words were taken out.
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([,;:])(?:\s*[,;:])+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s,;:.]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Learns spellings from what you change: when a word Murmur typed is replaced by a similar-sounding one a moment
/// later ("kopiko" → "Copico", "pool" → "pull"), that's a mishearing worth remembering.
public enum CorrectionLearner {
    /// Pairs (typed, now) from the field's text: the dictation is found in it with one or two words replaced by
    /// look-alikes. A rewrite (other words, a different length) is your editing, not a correction, and teaches nothing.
    public static func corrections(typed: String, now: String) -> [(heard: String, written: String)] {
        let original = tokens(typed), current = tokens(now)
        guard original.count >= 3, current.count >= original.count else { return [] }
        var best: (start: Int, matches: Int)?
        for start in 0...(current.count - original.count) {
            var matches = 0
            for i in 0..<original.count where original[i].lowercased() == current[start + i].lowercased() { matches += 1 }
            if matches > (best?.matches ?? -1) { best = (start, matches) }
        }
        guard let best, best.matches < original.count, best.matches >= original.count - 2,
              best.matches >= original.count / 2 + 1 else { return [] }
        var out: [(heard: String, written: String)] = []
        for i in 0..<original.count {
            let heard = original[i], written = current[best.start + i]
            guard heard != written else { continue }
            guard written.count >= 2, looksAlike(heard, written) else { return [] }
            out.append((heard, written))
        }
        return out
    }

    /// Words, keeping their capitals, without punctuation.
    static func tokens(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Close in spelling (a misheard word, not a different one): letter edits at most half the longer word.
    static func looksAlike(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[y.count] <= max(2, max(x.count, y.count) / 2)
    }

    /// Capitals that make a spelling worth keeping: "GitHub", "iPhone", "API" (not just a sentence's first letter).
    public static func hasDistinctiveCapitals(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        return letters.dropFirst().contains(where: \.isUppercase)
    }
}
