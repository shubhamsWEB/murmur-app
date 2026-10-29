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
    public static func pagesMentioned(_ request: String) -> String {
        let pattern = #"(?i)\b(?:pages?|pg\.?|p\.)\s*(\d+(?:\s*(?:-|–|to|and|,|&)\s*\d+)*)"#
        guard let match = request.range(of: pattern, options: .regularExpression) else { return "" }
        return String(request[match]).replacingOccurrences(of: #"(?i)^(pages?|pg\.?|p\.)\s*"#, with: "",
                                                           options: .regularExpression)
            .replacingOccurrences(of: " and ", with: ", ")
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
