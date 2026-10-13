import Foundation

/// "Murmur, …" at the start of what you said, however the speech model spelled it. Parakeet has never heard the
/// name, so it writes "Murmer", "Mermer", "Mur mur", "Marmar"…: anything close enough counts.
public enum WakeName {
    static let name = "murmur"
    /// Spellings heard in testing that are too far from "murmur" for the distance rule.
    static let heard: Set<String> = ["murma", "merma", "mirmir", "mamur", "murmurs", "mermurs", "murmers", "mermers", "merman"]
    /// Real words close to the name that start ordinary sentences.
    static let notIt: Set<String> = ["murder", "murders", "murdered", "murmured", "murmuring", "mormon", "mirror"]

    /// What you said after the name, when you started with it ("Murmer, summarise this" → "summarise this");
    /// nil when you didn't address Murmur.
    public static func strip(_ text: String) -> String? {
        let ns = text as NSString
        let pattern = #"^\s*(?:(?:hey|hi|ok|okay|yo)\b[\s,.!]*)?([a-z]+)(?:[\s-]+([a-z]+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let first = ns.substring(with: match.range(at: 1)).lowercased()
        var end = NSMaxRange(match.range(at: 1))
        var addressed = isName(first)
        if !addressed, match.range(at: 2).location != NSNotFound {
            // "Mur mur", "Mer-mer": the name heard as two words.
            let second = ns.substring(with: match.range(at: 2)).lowercased()
            if first.count <= 4, isName(first + second) {
                addressed = true
                end = NSMaxRange(match.range(at: 2))
            }
        }
        guard addressed else { return nil }
        return ns.substring(from: end)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?:;-").union(.whitespacesAndNewlines))
    }

    static func isName(_ word: String) -> Bool {
        if notIt.contains(word) { return false }
        if word == name || heard.contains(word) { return true }
        guard word.hasPrefix("m"), (5...8).contains(word.count) else { return false }
        return distance(word, name) <= 2
    }

    /// Edit distance (insertions, deletions, substitutions).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = saved
            }
        }
        return row[b.count]
    }
}
