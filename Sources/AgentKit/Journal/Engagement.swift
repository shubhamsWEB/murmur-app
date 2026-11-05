import Foundation

/// How a window was used, for judging what matters: a feed you scrolled ("browsing") counts for little unless it's
/// about you; a window that names you or people you know, that you stayed in or came back to, counts for more. Read
/// from what Murmur already has (the site, the text, the time), with no model and no extra permission.
public enum Engagement {
    /// Sites where most of what's shown isn't about the user: feeds and news.
    static let feeds = ["linkedin.com", "x.com", "twitter.com", "facebook.com", "instagram.com", "reddit.com",
                        "youtube.com", "threads.net", "news.ycombinator.com", "medium.com", "news.google.com",
                        "bbc.com", "cnn.com", "nytimes.com", "theguardian.com", "timesofindia.indiatimes.com",
                        "ndtv.com", "moneycontrol.com", "hindustantimes.com", "pinterest.com", "quora.com", "tiktok.com"]
    /// Parts of those sites that are conversations, not feeds.
    static let personal = ["messag", "inbox", "compose", "/chat", "/dm", "notifications", "/direct"]

    /// A window where the user talks with people or does their own work, as opposed to reading the web.
    public static func isConversation(_ snapshot: Journal.Snapshot) -> Bool { WindowKind.of(snapshot).canOblige }

    /// A window where what's shown is mostly not about the user: a feed, a video, an article, a product's site,
    /// search results.
    public static func isBrowsing(_ snapshot: Journal.Snapshot) -> Bool {
        [.feed, .video, .article, .product, .search].contains(WindowKind.of(snapshot))
    }

    /// The user's own names, as they'd appear in text ("Shubham Agrawal", "Shubham").
    static func mentions(_ text: String, any names: [String]) -> Bool {
        let lower = " " + text.lowercased() + " "
        return names.contains { name in
            let key = name.lowercased()
            guard key.count >= 3 else { return false }
            var start = lower.startIndex
            while let found = lower.range(of: key, range: start..<lower.endIndex) {
                let before = lower[lower.index(before: found.lowerBound)], after = found.upperBound < lower.endIndex ? lower[found.upperBound] : " "
                if !before.isLetter && !after.isLetter { return true }
                start = found.upperBound
            }
            return false
        }
    }

    /// The labels the model reads for a window: "browsing", "mentions you", "people you know: Priya Shah, Arjun",
    /// "came back 4 times".
    public static func tags(_ snapshot: Journal.Snapshot, me: [String], known: (String) -> [String]) -> [String] {
        var tags: [String] = []
        let kind = WindowKind.of(snapshot)
        tags.append(kind.label)
        if isBrowsing(snapshot) { tags.append("browsing") }
        let text = String(snapshot.text.prefix(6000))
        if mentions(text, any: me) { tags.append("mentions you") }
        let people = known(text).filter { name in !me.contains { $0.lowercased() == name.lowercased() } }
        if !people.isEmpty { tags.append("people you know: " + people.prefix(4).joined(separator: ", ")) }
        if snapshot.sightings >= 3 { tags.append("came back \(snapshot.sightings) times") }
        return tags
    }
}
