import Foundation

/// Reading a whole page for a summary or a question about all of it. A model left to scroll and read a screenful at
/// a time stopped after one scroll and answered from the top of the page. Murmur reads the page to the end itself;
/// a page that fits goes to the model whole, and a longer one is read in parts, with notes taken on each part for
/// the request, so the answer covers all of it.
public enum PageDigest {
    /// "summarise this page", "what's this article about", "explain this post and its comments", "is page ka saar
    /// batao": a request about a whole page (or "this" in a browser). `cleaned`: QuickCommands.clean of the request.
    public static func wantsWholePage(_ cleaned: String) -> Bool {
        let about = #"\b(summari[sz]e|summary|sum up|sum it up|tl ?;? ?dr|explain|key points|main points|takeaways|gist|overview|what([’']s| is| are) (this|the|it|they)( [a-z]+)? (about|saying)|what does (this|the|it)( [a-z]+)? say|saar|saransh|samjhao|samjha do|kya likha hai|kya bol raha)\b"#
        let page = #"\b(page|webpage|web page|article|post|posts|blog|website|site|this|it|thread|comments?|replies|discussion|readme|docs?|documentation|link|tab|news|story|review|reviews|video|paper|essay|guide|tutorial|answer|answers|wiki|is page|ye page|yeh page)\b"#
        let whole = #"\b(whole|entire|complete|full|all of|poora|pura|saara|sara) (the |this )?(page|article|post|thread|blog|document|doc|readme|comments|discussion)\b"#
        return cleaned.range(of: whole, options: .regularExpression) != nil
            || (cleaned.range(of: about, options: .regularExpression) != nil
                && cleaned.range(of: page, options: .regularExpression) != nil)
    }

    /// "how many unread emails", "list all my pending invoices", "which is the cheapest", "reply to every comment",
    /// "the latest message", "saare messages padho": the answer (or the thing to act on) can be anywhere in a list,
    /// chat, feed or table, not only in its first screenful. `cleaned`: QuickCommands.clean of the request.
    public static func wantsEverything(_ cleaned: String) -> Bool {
        if wantsWholePage(cleaned) { return true }
        let pattern = #"\b(all|every|each|everything|entire|whole|how many|count|total|list|compare|cheapest|lowest|highest|most|least|latest|newest|oldest|unread|pending|missed|sab|sabhi|saare|sare|saari|sari|kitne|kitni|har ek)\b"#
        return cleaned.range(of: pattern, options: .regularExpression) != nil
    }

    /// What was read so far, with one more screenful after scrolling: the lines the two share (the end of what was
    /// read, the top of the new screen) are kept once. A header that stays put at the top of every screen (a table's
    /// column names, a chat's title) is allowed for. With nothing shared, the screen jumped further than a screenful:
    /// it's added after. Lines that legitimately repeat ("Reply", "10:30") are kept wherever they aren't the overlap.
    public static func merge(_ read: [String], _ screen: [String]) -> [String] {
        guard !read.isEmpty else { return screen }
        guard !screen.isEmpty else { return read }
        for skip in 0...min(3, screen.count - 1) {
            let rest = screen[(screen.startIndex + skip)...]
            let most = min(read.count, rest.count)
            let fewest = skip == 0 ? 1 : 2
            guard most >= fewest else { continue }
            for size in stride(from: most, through: fewest, by: -1)
            where read[(read.count - size)...].elementsEqual(rest.prefix(size)) {
                return read + rest.dropFirst(size)
            }
        }
        // Nothing new at all (the screen didn't move): every line of it is already in what was read, in order.
        if screen.count <= read.count, contains(Array(read.suffix(screen.count + 3)), inOrder: screen) {
            return read
        }
        return read + screen
    }

    private static func contains(_ lines: [String], inOrder wanted: [String]) -> Bool {
        var index = lines.startIndex
        for line in wanted {
            guard let found = lines[index...].firstIndex(of: line) else { return false }
            index = found + 1
        }
        return true
    }

    /// Text in lines for `merge`: trimmed, empty ones left out.
    public static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The page in parts of about `size` characters, broken at a paragraph (else a line, else a sentence) so no
    /// part starts mid-thought.
    public static func parts(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var out: [String] = []
        var rest = Substring(text)
        while rest.count > size {
            let window = rest.prefix(size)
            let floor = window.index(window.startIndex, offsetBy: size / 2)
            var cut = window.endIndex
            for mark in ["\n\n", "\n", ". "] {
                if let found = window.range(of: mark, options: .backwards), found.upperBound > floor {
                    cut = found.upperBound
                    break
                }
            }
            out.append(String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[cut...]
        }
        let last = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { out.append(last) }
        return out
    }

    public static let noteSystem = "You read one part of a web page and take notes on it for the user's request. "
        + "Write only the notes."

    /// What the model is asked for one part.
    public static func notePrompt(request: String, title: String, url: String, part: Int, of count: Int,
                                  text: String) -> String {
        "The user's request: \"\(request)\"\nThe page: \(title) (\(url))\nPart \(part) of \(count):\n\"\"\"\n\(text)\n\"\"\"\n\n"
            + "Notes on this part for the request: every point, fact, name, number, step and opinion in it that "
            + "matters, as short lines starting with \"- \", in the page's order. Leave out menus, ads and links. "
            + "Where the text marks pages (\"--- Page 10 of 21 ---\"), start each note with its page (\"p. 10: \"). "
            + "If nothing in this part matters, write \"- (nothing here for the request)\"."
    }

    /// The page as the model gets it, read to the end: whole, or as notes on each part.
    public static func whole(title: String, url: String, text: String) -> String {
        "The whole page, read to the very end (\(text.count) characters). Answer from all of it; there's no need to "
            + "scroll or read it again.\nPage: \(title) — \(url)\n\n\(text)"
    }

    public static func notes(title: String, url: String, characters: Int, parts: [String]) -> String {
        var lines = ["The whole page has been read to the very end (\(characters) characters, in \(parts.count) parts), "
            + "and these are the notes on each part, in order. Answer from all of them; there's no need to scroll or "
            + "read it again.", "Page: \(title) — \(url)"]
        for (index, notes) in parts.enumerated() {
            lines.append("\nPart \(index + 1) of \(parts.count):\n\(notes)")
        }
        return lines.joined(separator: "\n")
    }
}
