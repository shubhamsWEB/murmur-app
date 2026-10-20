import Foundation

/// Markdown in an answer, split into the blocks the answer panel draws: headings, paragraphs, lists, code, quotes,
/// tables and rules. Inline styling inside a block (bold, italics, `code`, links) is left in the text for the
/// system's own inline Markdown. Anything unusual reads as a paragraph, so nothing is ever lost.
public enum MarkdownBlocks {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// A list: each item with its indent level (0 at the left) and, for a numbered list, its number.
        case list(ordered: Bool, items: [ListItem])
        case code(language: String?, text: String)
        case quote(String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    public struct ListItem: Equatable, Sendable {
        public let level: Int
        public let number: Int?
        public let text: String
        /// "- [ ]" / "- [x]" items: nil for an ordinary item.
        public let checked: Bool?
    }

    public static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Code fence: everything until the closing fence, as is.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1   // the closing fence (or the end)
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }

            // Heading.
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }

            // Rule.
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Table: a row of cells followed by a | --- | separator.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[i].trimmingCharacters(in: .whitespaces))
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Quote: consecutive "> " lines.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: " ")))
                continue
            }

            // List: consecutive items of the same kind (and their wrapped continuation lines).
            if let first = listItem(line) {
                flushParagraph()
                let ordered = first.number != nil
                var items: [ListItem] = []
                while i < lines.count {
                    let current = lines[i]
                    if let item = listItem(current), (item.number != nil) == ordered || item.level > 0 {
                        items.append(item)
                        i += 1
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, let last = items.last,
                              current.hasPrefix("  "), listItem(current) == nil {
                        // A wrapped line belongs to the item above.
                        items[items.count - 1] = ListItem(level: last.level, number: last.number,
                                                          text: last.text + " " + current.trimmingCharacters(in: .whitespaces),
                                                          checked: last.checked)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// The answer as plain text for pasting into other apps: no #, **, ` or table pipes; lists keep their
    /// bullets and numbers.
    public static func plain(_ markdown: String) -> String {
        parse(markdown).map { block -> String in
            switch block {
            case .heading(_, let text): return inline(text)
            case .paragraph(let text): return inline(text)
            case .quote(let text): return inline(text)
            case .code(_, let text): return text
            case .rule: return ""
            case .list(_, let items):
                return items.map { item in
                    let indent = String(repeating: "    ", count: item.level)
                    let marker = item.checked.map { $0 ? "☑" : "☐" } ?? item.number.map { "\($0)." } ?? "•"
                    return "\(indent)\(marker) \(inline(item.text))"
                }.joined(separator: "\n")
            case .table(let header, let rows):
                return ([header] + rows).map { $0.map(inline).joined(separator: "\t") }.joined(separator: "\n")
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Inline markers taken out: **bold**, __bold__, *italic*, _italic_, `code`, [text](link) → text.
    public static func inline(_ text: String) -> String {
        var out = text
        // Links: keep the words.
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "`"] { out = out.replacingOccurrences(of: marker, with: "") }
        out = out.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*]+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<![\w_])_(?!\s)([^_]+?)(?<!\s)_(?![\w_])"#, with: "$1", options: .regularExpression)
        return out
    }

    // MARK: - Pieces

    static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: hashes, text: text)
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var t = row
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func listItem(_ line: String) -> ListItem? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }
        let indent = spaces.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(spaces.count)
        let level = min(3, indent / 2)
        // Bullets: -, *, +, •
        if let marker = rest.first, "-*+•".contains(marker), rest.dropFirst().first == " " {
            var text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            var checked: Bool?
            if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { checked = true; text = String(text.dropFirst(4)) }
            return ListItem(level: level, number: nil, text: text, checked: checked)
        }
        // Numbers: "1." or "1)"
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                return ListItem(level: level, number: Int(digits), text: after.dropFirst(2).trimmingCharacters(in: .whitespaces),
                                checked: nil)
            }
        }
        return nil
    }
}
