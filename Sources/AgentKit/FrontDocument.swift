import AppKit
import ApplicationServices
import Foundation

/// The document open in the front app (a PDF in Preview or Acrobat, a Word or RTF file in Pages, Word or TextEdit),
/// read from its file. The screen shows a page or two: "summarise pages 1 to 22" of a 470-page PDF in Preview fell
/// back to `pdftotext` and `pypdf`, which most Macs don't have, and gave up. PDFKit and AppKit read the file itself.
/// On the main actor, as Accessibility and the front app are; a PDF is parsed off it (PDFText).
@MainActor
public enum FrontDocument {
    /// What's readable: PDFs, and what NSAttributedString opens (Word, RTF, OpenDocument, HTML, plain text).
    static let readable: Set<String> = ["pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive",
                                        "txt", "text", "md", "markdown", "csv", "json", "log"]

    public struct Read: Sendable {
        public let file: URL
        /// The pages asked for, with the page count, for a PDF; nil for other documents.
        public let pageCount: Int?
        public let pages: [Int]
        public let text: String
    }

    /// The file behind the front window, and how it was found: Accessibility's document address (Preview,
    /// TextEdit, Pages, most document apps), then the window's title ("Report.pdf – Page 17 of 470") found with
    /// Spotlight, then Preview's own script (last: macOS may ask before Murmur can script Preview). Nil when the window
    /// isn't a document Murmur reads. Whether it may be read isn't checked here: a file in Downloads or Documents is
    /// refused until macOS asks you, and only opening it makes macOS ask.
    public static func locate(in app: NSRunningApplication? = nil) -> (file: URL, from: String)? {
        guard let app = app ?? ScreenControl.workingApp() else { return nil }
        if let url = accessibilityDocument(app), isDocument(url) { return (url, "the window's document") }
        if let title = windowTitle(app), let name = fileName(fromTitle: title), let url = spotlight(name) {
            return (url, "the window's title, found with Spotlight")
        }
        if app.bundleIdentifier == "com.apple.Preview",
           let path = MacActions.appleScript("tell application \"Preview\" to get path of front document"),
           !path.isEmpty, isDocument(URL(fileURLWithPath: path)) {
            return (URL(fileURLWithPath: path), "Preview")
        }
        return nil
    }

    public static func file(in app: NSRunningApplication? = nil) -> URL? { locate(in: app)?.file }

    /// The file, all of it or the `wanted` pages (a PDF's "5-7", "1 to 22"; ignored for other documents).
    public static func read(_ file: URL, pages wanted: String = "") async -> Read? {
        if file.pathExtension.lowercased() == "pdf" {
            guard let pdf = await PDFText.read(file.absoluteString, pages: wanted) else { return nil }
            return Read(file: file, pageCount: pdf.pageCount, pages: pdf.pages, text: pdf.text)
        }
        guard let data = try? Data(contentsOf: file), data.count < 40_000_000 else { return nil }
        let text: String?
        if ["txt", "text", "md", "markdown", "csv", "json", "log"].contains(file.pathExtension.lowercased()) {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        } else {
            text = (try? NSAttributedString(url: file, options: [:], documentAttributes: nil))?.string
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Read(file: file, pageCount: nil, pages: [], text: text)
    }

    /// A file of a kind Murmur reads, that's there.
    static func isDocument(_ url: URL) -> Bool {
        url.isFileURL && readable.contains(url.pathExtension.lowercased())
            && FileManager.default.fileExists(atPath: url.path)
    }

    /// "UPANISHADIC_PHILOSOPHY.pdf – Page 17 of 470" → "UPANISHADIC_PHILOSOPHY.pdf"; "Notes.docx — Edited" →
    /// "Notes.docx"; nil when the title doesn't name a readable file.
    static func fileName(fromTitle title: String) -> String? {
        let extensions = readable.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"^\s*([^/]+?\.(?:"# + extensions + #"))(?:\s+[–—-]\s.*)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let name = Range(match.range(at: 1), in: title) else { return nil }
        return String(title[name])
    }

    private static func accessibilityDocument(_ app: NSRunningApplication) -> URL? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &window) == .success,
                  let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { continue }
            var document: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &document)
                == .success, let address = document as? String, let url = URL(string: address), url.isFileURL {
                return url
            }
        }
        return nil
    }

    private static func windowTitle(_ app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    /// The file with this exact name, the most recently opened when there are several.
    private static func spotlight(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        process.arguments = ["kMDItemFSName == \"\(escaped)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let paths = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter(isDocument)
        func opened(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
        }
        return urls.max { opened($0) < opened($1) }
    }
}
