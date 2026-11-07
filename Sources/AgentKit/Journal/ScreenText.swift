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

    /// The message the user sent: the box held it, the box no longer does (`boxes`: what the window's text boxes hold
    /// now; a draft still in one wasn't sent, only left when the user clicked elsewhere), and the conversation shows
    /// it, all of it. What's kept is what the user wrote, never the line on the page (someone else's message can
    /// start the same way).
    public static func sent(before: String, now: String, in text: String, boxes: [String] = [], byItsEnd: Bool = true) -> String? {
        let draft = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.split(separator: " ").count >= 2, now.isEmpty || !now.hasPrefix(draft) else { return nil }
        // Compared as they read, not as they're typed: WhatsApp and Slack show "*Murmur 1.7*" as bold "Murmur 1.7",
        // and a long message wraps onto several lines.
        let written = plain(draft)
        guard !written.isEmpty, !stillWriting(written, in: boxes) else { return nil }
        // Without spaces too: a mention or a link breaks a post onto lines of its own ("Congrats\nPriya Sharma\n, well…").
        func tight(_ text: String) -> String { plain(text).filter { !$0.isWhitespace } }
        // The box held only the start of it when last looked at ("Sure, I'll send it Thurs"): the chat's line for it,
        // when it begins with all of that and is little more (not someone else's longer message that starts the same
        // way). On a feed, never: what the user wrote is kept.
        if byItsEnd, !text.split(separator: "\n").contains(where: { plain(String($0)) == written }),
           let line = text.split(separator: "\n").last(where: { plain(String($0)).hasPrefix(written) }),
           plain(String(line)).count - written.count <= max(12, written.count / 2) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        if plain(text).contains(written) || tight(text).contains(tight(draft)) { return draft }
        // A long message shows in the chat by its end when its start has scrolled up (a caption under a video),
        // wrapped onto lines of its own: compared without spaces, by its last 40 letters.
        let end = String(tight(draft).suffix(40))
        if byItsEnd, draft.split(separator: " ").count >= 8, end.count == 40, tight(text).contains(end) { return draft }
        return nil
    }

    /// Whether a text box still holds the draft (its start): it hasn't been sent.
    static func stillWriting(_ written: String, in boxes: [String]) -> Bool {
        let start = String(written.prefix(24))
        return boxes.contains { plain($0).contains(start) }
    }

    /// Text as it reads: no chat formatting marks (* _ ~ `), no invisible direction marks, one space between words.
    static func plain(_ text: String) -> String {
        let marks = CharacterSet(charactersIn: "*_~`").union(invisible)
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !marks.contains($0) }))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Invisible characters apps put in names and text: direction marks (WhatsApp calls itself "\u{200E}WhatsApp"),
    /// zero-width joiners and spaces, the byte-order mark.
    static let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")

    /// An app's name as people say it: "\u{200E}WhatsApp" is "WhatsApp" (the mark made it no chat app at all, so the
    /// messages sent in it were never kept).
    public static func appName(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.filter { !invisible.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// What the user published on a feed: the box they wrote it in emptied (or moved on to something else) and the
    /// text is on the page now, or the site said it was posted ("Post successful", "Your post is live"). At least five
    /// words, so a search or a one-word reaction isn't taken for a post.
    /// `before`: the page's text the last time it was read; a "posted" message already there then says nothing new.
    public static func posted(before: String, now: String, in text: String, boxes: [String] = [], earlier: String = "") -> String? {
        let draft = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.split(separator: " ").count >= 5, now.isEmpty || !now.hasPrefix(String(draft.prefix(20))) else { return nil }
        guard !stillWriting(plain(draft), in: boxes) else { return nil }
        // On the page, all of it (not by its end: a feed is full of other people's words).
        if let shown = sent(before: draft, now: now, in: text, boxes: boxes, byItsEnd: false) { return shown }
        // A long post shows cut short ("… more"): its first hundred letters, then the cut.
        let tight = plain(draft).filter { !$0.isWhitespace }
        let page = plain(text).filter { !$0.isWhitespace }.lowercased()
        if tight.count >= 100, page.contains(String(tight.prefix(100)).lowercased()),
           ["…more", "...more", "seemore", "…seemore", "showmore", "readmore"].contains(where: page.contains) {
            return draft
        }
        // The site said so, just now (not a notification that was on the page before).
        let lower = text.lowercased(), was = earlier.lowercased()
        let said = ["post successful", "your post is live", "your post was shared", "post shared", "posted successfully",
                    "your post has been", "your tweet was sent", "your post was sent", "comment posted", "reply sent"]
        if said.contains(where: { lower.contains($0) && !was.contains($0) }) { return draft }
        return nil
    }

    /// Put before a post seen leaving its box but not seen on the page (by an earlier version; no longer made).
    public static let unconfirmed = "(not confirmed on the page) "

    /// What the user wrote and sent here, without what an earlier version kept as "not confirmed": a draft that left
    /// its box is no proof it was sent.
    public static func confirmed(_ authored: String) -> String {
        authored.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(unconfirmed.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file a window shows, from its Accessibility "document" (a file:// address, percent-encoded): Cocoa document
    /// apps (TextEdit, Pages, Preview, Xcode) say it; browsers' is a web page's address, not a file.
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
