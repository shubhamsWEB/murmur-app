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
}
