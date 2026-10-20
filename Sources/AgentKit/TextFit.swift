import Foundation

/// Fits dictated text to where it lands, the way you'd type it there: a space before it when it follows a word, no
/// capital or full stop when it goes into the middle of a sentence, a capital when it starts one. The words
/// themselves are never changed, only spacing, the first letter's case and the final full stop.
public enum TextFit {
    /// - Parameters:
    ///   - text: what was heard.
    ///   - before: the few characters just before the cursor (or the selection being replaced); empty at the start.
    ///   - after: the few characters just after it; empty at the end.
    ///   - isWord: whether a lowercase word is an ordinary dictionary word ("meeting" yes, "monday" or "shubham"
    ///     no), so names keep their capital.
    public static func fit(_ text: String, before: String, after: String, isWord: (String) -> Bool) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = out.first else { return text }

        // Where the text starts: a new sentence (start of the field, a new line, after . ! ? …) or mid-sentence.
        let lineBefore = before.reversed().prefix { $0 == " " || $0 == "\t" }
        let beforeTrimmed = String(before.dropLast(lineBefore.count))
        let previous = beforeTrimmed.last
        let startsSentence = previous == nil || previous!.isNewline || ".!?…".contains(previous!)
        let afterFirst = after.first
        let afterWord = after.drop { $0 == " " || $0 == "\t" }.first

        if startsSentence {
            if first.isLowercase, first.isLetter {
                out = first.uppercased() + out.dropFirst()
            }
        } else if let previous, previous.isLetter || previous.isNumber || ",;:-–—".contains(previous) {
            out = lowercasingFirstWord(out, isWord: isWord)
        }

        // A full stop at the end only belongs at the end of a sentence: not when more of it follows (a lowercase
        // word, a number, punctuation). A capital after it starts a new sentence, so the stop stays.
        if let afterWord, afterWord.isLowercase || afterWord.isNumber || ",;:.!?".contains(afterWord),
           out.hasSuffix("."), !out.hasSuffix("..") {
            out.removeLast()
        }

        // Spacing: a space after a word before the text, and between the text and a word right after it.
        if let last = before.last, !last.isWhitespace, !"([{\"'“‘/@#$\n".contains(last),
           let start = out.first, !",.;:!?)]}”’%".contains(start) {
            out = " " + out
        }
        if let afterFirst, afterFirst.isLetter || afterFirst.isNumber || "([{\"“".contains(afterFirst) {
            out += " "
        }
        return out
    }

    /// "Tomorrow works" → "tomorrow works"; "I think", "Monday", "API", "iPhone" stay as they are.
    static func lowercasingFirstWord(_ text: String, isWord: (String) -> Bool) -> String {
        let word = text.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        if word == "A" { return "a" + text.dropFirst() }
        guard word.count >= 2, let head = word.first, head.isUppercase,
              word.dropFirst().allSatisfy({ !$0.isUppercase }) else { return text }
        let bare = word.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? String(word)
        guard bare != "I", isWord(bare.lowercased()) else { return text }
        return head.lowercased() + text.dropFirst()
    }
}
