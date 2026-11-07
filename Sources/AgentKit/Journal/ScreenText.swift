import Foundation

/// What of a window's text is content, not the app around it.
public enum ScreenText {
    /// Accessibility subroles of a page's navigation, header, footer and side panels (web pages and Electron apps say
    /// them): skipped whole.
    public static let chrome: Set<String> = ["AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo",
                                             "AXLandmarkComplementary", "AXTabList"]

    static let adLabels: Set<String> = ["promoted", "sponsored", "ad", "advertisement", "sponsored content", "paid partnership"]

    /// The lines without menus and lists of titles: a run of six or more short controls in a row (links, buttons,
    /// rows of a sidebar: "Kunafa base ingredients", "India carbon credit scheme"…) is navigation, and goes.
    /// `control`: the line is a link, button or row rather than text.
    public static func content(_ lines: [(text: String, control: Bool)], run: Int = 6) -> [String] {
        var out: [String] = []
        var pending: [String] = []
        func flush() {
            if pending.count < run { out += pending }
            pending.removeAll()
        }
        var skipping = 0
        for line in lines {
            // An advert in a feed: its label and the post around it ("Promoted", "Sponsored", "Ad").
            if adLabels.contains(line.text.lowercased()) { skipping = 12; continue }
            if skipping > 0 { skipping -= 1; continue }
            let short = line.text.split(separator: " ").count <= 7 && line.text.count <= 60
            if line.control && short {
                pending.append(line.text)
            } else {
                flush()
                out.append(line.text)
            }
        }
        flush()
        return out
    }

    /// The message the user sent, if the box held one that's gone from it and now shows in the conversation: the
    /// conversation's own line for it (the box may have held only the start of it when last looked at).
    public static func sent(before: String, now: String, in text: String) -> String? {
        let draft = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.split(separator: " ").count >= 2, now.isEmpty || !now.hasPrefix(draft) else { return nil }
        let start = String(draft.prefix(30))
        guard let line = text.split(separator: "\n").last(where: { $0.contains(start) }) else { return nil }
        return String(line.count >= draft.count ? line : Substring(draft)).trimmingCharacters(in: .whitespaces)
    }

    /// The file a window shows, from its Accessibility "document" (a file:// address, percent-encoded): Cocoa document
    /// apps (TextEdit, Pages, Preview, Xcode) say it; browsers' is a web page's address, not a file. The approach is
    /// screenpipe's (MIT-licensed version; see THIRD_PARTY_NOTICES.md).
    public static func documentPath(_ raw: String) -> String? {
        guard raw.hasPrefix("file://") else { return nil }
        if let url = URL(string: raw), url.isFileURL, !url.path.isEmpty { return url.path }
        var rest = String(raw.dropFirst("file://".count))
        if rest.hasPrefix("localhost/") { rest = String(rest.dropFirst("localhost".count)) }
        return rest.removingPercentEncoding ?? rest
    }

    /// A browser's and a web app's own words, not the page's: Chrome's tab list ("Murmur - Memory usage - 378 MB"),
    /// its buttons, Gmail's toolbar ("Reply", "Not starred", "Print all"), JSON a page leaves in its tree.
    static let interfaceLines: Set<String> = [
        "new tab", "tab search", "open gemini in chrome", "close", "none selected", "of", "print all", "in new window",
        "not important", "important", "reply", "reply all", "forward", "add reaction", "not starred", "starred",
        "show details", "hide details", "more", "archive", "delete", "report spam", "mark as unread", "snooze",
        "move to", "labels", "older", "newer", "back to inbox", "select", "refresh", "more options", "settings",
        "support", "google apps", "search mail", "show search options", "main menu", "compose", "inbox",
        "snoozed", "sent", "drafts", "more labels", "expand all", "collapse all", "unread", "attachment",
    ]

    /// The window's text without what belongs to the browser or the app around the content, and with Google's redirect
    /// addresses back to where they lead.
    public static func clean(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if interfaceLines.contains(lower) { continue }
            // Chrome's tab list and its memory badges.
            if lower.range(of: #" - (high )?memory usage - [\d.,]+ ?[kmg]b$"#, options: .regularExpression) != nil { continue }
            // JSON a page left in its accessibility tree; a link's tracking tail broken over lines.
            if line.hasPrefix("{"), line.hasSuffix("}"), line.contains("\":") { continue }
            if lower.range(of: #"^[\w./-]*&(source|ust|sa|usg)="#, options: .regularExpression) != nil
                || lower.range(of: #"^\d{10,}&sa=e$"#, options: .regularExpression) != nil { continue }
            lines.append(String(raw))
        }
        var result = lines.joined(separator: "\n")
        // "https://www.google.com/url?q= http://thetrost.com&source= gmail&ust=…&sa= E" is thetrost.com.
        result = result.replacingOccurrences(of: #"https?://www\.google\.com/url\?q=\s*(\S+?)&source=\s*\S+(?:&ust=\S*)?(?:&sa=\s*\S)?"#,
                                             with: "$1", options: .regularExpression)
        return result
    }

    /// A window's title without what the browser adds: "(6711) How to build… - YouTube – Audio playing - High memory
    /// usage - 952 MB - Google Chrome – Shubham" is "How to build… - YouTube".
    public static func cleanTitle(_ title: String) -> String {
        var text = title
        for pattern in [#"\s[-–]\s(Google Chrome|Brave|Microsoft Edge|Chromium|Arc|Safari|Firefox|Vivaldi|Opera)(\s[-–]\s.*)?$"#,
                        #"\s[-–]\s(High )?[Mm]emory usage\s[-–]\s[\d.,]+\s?[KMG]B"#, #"\s[-–]\sAudio playing"#,
                        #"\s[-–]\sCamera or microphone recording"#, #"^\(\d[\d,]*\)\s"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
