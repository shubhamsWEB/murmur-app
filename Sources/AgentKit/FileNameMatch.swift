import Foundation

/// Whether a file's name is the file asked for: "PanCard.pdf" for "my PAN card", "Aadhar.pdf" for "aadhaar card",
/// "Roma_Patel_CV.pdf" for "Roma Patel ka resume". Scanned cards and photos have little text for the search to
/// find, so their names are often all there is; and a long document that mentions the words (a book, a handover)
/// must not outrank the file named for them. One definition, used by opening a file and by the check for "the file
/// from before", so the two can't drift apart.
public enum FileNameMatch {
    /// Words that say what kind of thing it is, not which one: a name needn't have them.
    static let generic: Set<String> = [
        "card", "cards", "file", "files", "document", "documents", "doc", "docs", "docx", "copy", "scan", "scanned",
        "pdf", "pdfs", "photo", "photos", "image", "images", "picture", "pictures", "pic", "front", "back", "final",
        "new", "latest", "old", "version",
    ]
    /// Words that say nothing about the file (English and Hinglish).
    static let filler: Set<String> = [
        "my", "the", "a", "an", "of", "and", "or", "for", "from", "with", "in", "on", "to", "me", "please", "open",
        "show", "find", "get", "that", "this", "our", "your", "called", "named", "also", "too", "bhi", "aur",
        "mujhe", "mera", "meri", "mere", "apna", "apni", "apne", "wala", "wali", "wale", "vala", "vali", "vale",
        "ka", "ki", "ke", "ko", "se", "kholo", "khol", "kholna", "kholkar", "do", "de", "dikhao", "karo",
    ]
    /// Spellings said or written more than one way.
    static let spellings: [(String, String)] = [
        ("licence", "license"), ("résumé", "cv"), ("resume", "cv"), ("pen card", "pan card"), ("pancard", "pan card"),
        ("adhar", "aadhaar"), ("adhaar", "aadhaar"), ("aadhar", "aadhaar"),
    ]

    /// Lowercase, accents off, the spellings above made one, and doubled letters single ("aadhaar", "aadhar" →
    /// "adhar").
    public static func fold(_ text: String) -> String {
        var s = text.lowercased()
        for (from, to) in spellings { s = s.replacingOccurrences(of: from, with: to) }
        s = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out = ""
        for ch in s where !(ch.isLetter && out.last == ch) { out.append(ch) }
        return out
    }

    /// The words of a file name: "PanCard_2024-scan.pdf" → ["pan", "card", "2024", "scan"]. Camel case and digits
    /// split, the extension left out.
    public static func nameWords(_ name: String) -> [String] {
        let stem = (name as NSString).deletingPathExtension
        var spaced = ""
        var previous: Character?
        for ch in stem {
            if let p = previous,
               (p.isLowercase && ch.isUppercase) || (p.isLetter && ch.isNumber) || (p.isNumber && ch.isLetter) {
                spaced.append(" ")
            }
            spaced.append(ch)
            previous = ch
        }
        return fold(spaced).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The words that pick the file out, from what was asked ("my driving license" → ["driving", "license"]).
    public static func askedWords(_ query: String) -> [String] {
        var seen = Set<String>()
        return fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !filler.contains($0) && seen.insert($0).inserted }
    }

    /// How well the name answers the request: nil unless it has every distinctive word asked for (and the request
    /// has at least one: "the PDF" names no file); otherwise 1 plus the share of all the words asked that it has,
    /// so "PanCard.pdf" (pan, card) beats "PAN.pdf" (pan) for "PAN card".
    public static func score(name: String, for query: String) -> Double? {
        let asked = askedWords(query)
        let distinctive = asked.filter { !generic.contains($0) }
        guard !distinctive.isEmpty else { return nil }
        let words = nameWords(name)
        guard !words.isEmpty else { return nil }
        let joined = words.joined()
        func has(_ word: String) -> Bool {
            words.contains(word)
                || (word.count >= 4 && words.contains { $0.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) })
                || (word.count >= 5 && joined.contains(word))
        }
        // "pancard" said as one word, or a name written as one ("drivinglicense.pdf").
        let together = distinctive.joined()
        let all = together.count >= 6 && joined.contains(together)
        guard all || distinctive.allSatisfy(has) else { return nil }
        let matched = asked.filter { all && distinctive.contains($0) || has($0) }.count
        return 1 + Double(matched) / Double(asked.count)
    }

    /// Whether what was said names this file: "my PAN card" and "PanCard.pdf", "aadhaar wala" and "Aadhar.pdf".
    public static func names(_ said: String, _ name: String) -> Bool {
        let words = nameWords(name).filter { !generic.contains($0) && $0.count > 2 && !$0.allSatisfy(\.isNumber) }
        guard !words.isEmpty else { return false }
        let heard = askedWords(said)
        let joined = heard.joined()
        // Every distinctive word of the name, or the name run together ("pan card" → "pancard").
        return words.allSatisfy { word in heard.contains(word) || (word.count >= 5 && joined.contains(word)) }
            || (words.joined().count >= 5 && joined.contains(words.joined()))
    }
}
