import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// A PDF open in the browser, read from the file itself: every page, numbered. Chrome's PDF viewer shares only some
/// of its text through Accessibility (Murmur got the first 12,000 characters, about four pages of a 21-page paper,
/// and summarised those as the whole thing), and its page box can't be typed into without page scripting ("summarise
/// page 10" gave up). The file is the same one the tab shows: its address, fetched again, or the file on this Mac.
public enum PDFText {
    /// The tab shows a PDF: an address ending in .pdf, an arXiv-style /pdf/ address, or a title that's a PDF's name.
    public static func isPDF(url: String, title: String) -> Bool {
        let address = url.lowercased()
        let path = URL(string: address)?.path ?? address
        return path.hasSuffix(".pdf") || path.contains("/pdf/") || title.lowercased().hasSuffix(".pdf")
    }

    /// "10" → [10]; "5-7" → [5, 6, 7]; "3, 8" → [3, 8]; "page 4 to 6" → [4, 5, 6]. Empty: all of it. Pages past the
    /// end are left out.
    public static func pages(_ wanted: String, of count: Int) -> [Int] {
        let text = wanted.lowercased().replacingOccurrences(of: #"\b(pages?|pp?\.?|to|till|until|through|se|tak)\b"#,
                                                            with: "-", options: .regularExpression)
        var out: [Int] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "&" }) {
            let numbers = piece.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let first = numbers.first else { continue }
            let last = piece.contains("-") && numbers.count >= 2 ? numbers[1] : first
            for page in min(first, last)...max(first, last) where page >= 1 && page <= count && !out.contains(page) {
                out.append(page)
            }
        }
        return out
    }

    /// The pages a request names: "summarise page 10" → "10", "pages 5 to 7" → "5 to 7", "page 3 and 4" → "3 and 4";
    /// "" when it names none ("all 21 pages" names a count, not a page).
    /// Spoken numbers count: "page one to page twenty two" → "1 to 22", "pages 5 through 7" → "5 to 7".
    public static func pagesMentioned(_ request: String) -> String {
        let request = digits(request)
        let pattern = #"(?i)\b(?:pages?|pg\.?|p\.)\s*(\d+(?:\s*(?:-|–|to|till|until|through|and|,|&)\s*(?:(?:pages?|pg\.?|p\.)\s*)?\d+)*)"#
        guard let match = request.range(of: pattern, options: .regularExpression) else { return "" }
        return String(request[match]).replacingOccurrences(of: #"(?i)^(pages?|pg\.?|p\.)\s*"#, with: "",
                                                           options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*\b(?:pages?|pg\.?|p\.)\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*\b(?:through|till|until)\b\s*"#, with: " to ", options: .regularExpression)
            .replacingOccurrences(of: " and ", with: ", ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Numbers said as words, as digits: "twenty two" → "22", "one hundred and five" → "105", "forty-one" → "41".
    /// Other words are left as they were.
    public static func digits(_ text: String) -> String {
        let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                     "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                     "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
                    "ninety": 90]
        var out: [String] = []
        var number: Int?
        var lastWasTens = false
        var pendingAnd = false
        func flush() {
            if let number { out.append(String(number)) }
            if pendingAnd { out.append("and") }
            number = nil
            lastWasTens = false
            pendingAnd = false
        }
        for raw in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let trailing = String(raw.reversed().prefix { ",.;:!?".contains($0) }.reversed())
            let word = String(raw.dropLast(trailing.count))
            let lower = word.lowercased()
            let parts = lower.split(separator: "-").map(String.init)
            var value: Int?
            if parts.count == 2, let ten = tens[parts[0]], let unit = units[parts[1]], unit > 0, unit < 10 {
                value = ten + unit
            } else if parts.count == 1 {
                value = units[lower] ?? tens[lower]
            }
            if let value {
                if let current = number, current >= 100, current % 100 == 0, value < 100 {
                    number = current + value          // "one hundred (and) five"
                } else if let current = number, lastWasTens, value < 10, !pendingAnd {
                    number = current + value          // "twenty two"
                } else {
                    flush()
                    number = value
                }
                lastWasTens = tens[lower] != nil
                pendingAnd = false
            } else if lower == "hundred", let current = number, current < 10, !pendingAnd {
                number = current * 100
                lastWasTens = false
            } else if lower == "and", let current = number, current >= 100, current % 100 == 0, !pendingAnd {
                pendingAnd = true
            } else {
                flush()
                out.append(word)
            }
            if !trailing.isEmpty {
                flush()
                if out.isEmpty { out.append(trailing) } else { out[out.count - 1] += trailing }
            }
        }
        flush()
        return out.joined(separator: " ")
    }

    /// [1, 2, …, 22] → "1–22"; [3, 8, 9, 10] → "3, 8–10".
    public static func span(_ pages: [Int]) -> String {
        var out: [String] = []
        var start: Int?
        var last: Int?
        for page in pages.sorted() {
            if let l = last, page == l + 1 { last = page; continue }
            if let s = start, let l = last { out.append(s == l ? "\(s)" : "\(s)–\(l)") }
            start = page
            last = page
        }
        if let s = start, let l = last { out.append(s == l ? "\(s)" : "\(s)–\(l)") }
        return out.joined(separator: ", ")
    }

    /// The pages' text, each under "--- Page n of N ---".
    public static func joined(_ pages: [(number: Int, text: String)], of count: Int) -> String {
        pages.map { "--- Page \($0.number) of \(count) ---\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
    }

    public struct Read: Sendable {
        public let pageCount: Int
        /// The pages asked for (all of them when none were), numbered.
        public let text: String
        public let pages: [Int]
    }

    /// The PDF at `address` (http, https or file), all of it or the `wanted` pages. Nil when it can't be fetched or
    /// isn't a PDF (a sign-in page, a viewer that hides the file).
    public static func read(_ address: String, pages wanted: String = "") async -> Read? {
        #if canImport(PDFKit)
        guard let url = URL(string: address) else { return nil }
        var data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else if url.scheme == "http" || url.scheme == "https" {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("application/pdf,*/*", forHTTPHeaderField: "Accept")
            if let (body, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                data = body
            }
        }
        guard let data, data.count < 80_000_000, data.starts(with: Array("%PDF".utf8)),
              let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        let count = document.pageCount
        let chosen = wanted.trimmingCharacters(in: .whitespaces).isEmpty ? Array(1...count) : pages(wanted, of: count)
        guard !chosen.isEmpty else { return Read(pageCount: count, text: "", pages: []) }
        let text = joined(chosen.map { ($0, document.page(at: $0 - 1)?.string ?? "") }, of: count)
        return Read(pageCount: count, text: text, pages: chosen)
        #else
        return nil
        #endif
    }
}
