import Foundation

/// What a window is, decided without a model from the app, the address and what's on it: the first thing screen
/// memory asks, because it decides what the window can mean. A promise can come from a conversation or your own work;
/// a product's website or a feed can only be something you saw.
public enum WindowKind: String, Sendable, CaseIterable {
    /// People talking: Slack, Mail, Messages, WhatsApp, Teams, LinkedIn messages, Gmail.
    case conversation
    /// The user's own work: a document, an issue, a note, code, a calendar.
    case work
    /// An AI assistant's chat (Claude, ChatGPT, Gemini): the user's questions and its answers.
    case assistant
    /// A feed: LinkedIn, X, YouTube, Reddit's front pages.
    case feed
    /// An article or a news story.
    case article
    /// A company's or product's own site: features, pricing, demos, sign-up.
    case product
    /// Search results.
    case search
    /// Documentation, a reference.
    case docs
    /// A video or a stream.
    case video
    /// Any other web page.
    case page
    /// Any other app.
    case app

    /// What can come of it: only conversations and work make promises and requests the user owes.
    public var canOblige: Bool { self == .conversation || self == .work }

    /// What it says to the model reading it.
    public var label: String {
        switch self {
        case .conversation: return "a conversation"
        case .work: return "the user's own work"
        case .assistant: return "an AI assistant chat (the user's questions and its answers, not people)"
        case .feed: return "a feed (other people's posts)"
        case .article: return "an article (someone else's writing)"
        case .product: return "a product's or company's website (marketing, demos and examples, not the user's life)"
        case .search: return "search results"
        case .docs: return "documentation"
        case .video: return "a video"
        case .page: return "a web page"
        case .app: return "an app"
        }
    }

    static let conversationApps = ["slack", "mail", "messages", "whatsapp", "microsoft teams", "teams", "discord", "telegram",
                                   "signal", "outlook", "spark", "superhuman", "airmail", "mimestream", "zoom", "facetime",
                                   "microsoft outlook", "skype", "webex"]
    static let workApps = ["linear", "notion", "jira", "asana", "todoist", "things", "reminders", "notes", "calendar",
                           "microsoft word", "microsoft excel", "microsoft powerpoint", "pages", "numbers", "keynote",
                           "xcode", "visual studio code", "code", "cursor", "intellij idea", "android studio", "figma",
                           "obsidian", "bear", "craft", "fantastical", "terminal", "iterm2", "warp", "ghostty", "zed",
                           "sublime text", "textedit", "preview", "antigravity", "antigravity ide", "windsurf"]
    static let assistantApps = ["claude", "chatgpt", "perplexity", "gemini", "copilot", "murmur"]
    static let conversationSites = ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
                                    "app.slack.com", "web.whatsapp.com", "teams.microsoft.com", "teams.live.com",
                                    "discord.com", "web.telegram.org", "messenger.com", "mail.yahoo.com", "mail.proton.me"]
    static let workSites = ["linear.app", "notion.so", "app.asana.com", "atlassian.net", "docs.google.com",
                            "sheets.google.com", "slides.google.com", "calendar.google.com", "github.com", "gitlab.com",
                            "app.clickup.com", "trello.com", "basecamp.com", "monday.com", "figma.com", "drive.google.com",
                            "onedrive.live.com", "sharepoint.com", "airtable.com", "miro.com", "vercel.com", "console.cloud.google.com"]
    static let assistantSites = ["claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "perplexity.ai",
                                 "copilot.microsoft.com", "chat.deepseek.com", "grok.com"]
    static let feedSites = ["linkedin.com", "x.com", "twitter.com", "facebook.com", "instagram.com", "reddit.com",
                            "threads.net", "news.ycombinator.com", "pinterest.com", "tiktok.com", "producthunt.com", "quora.com"]
    static let videoSites = ["youtube.com", "netflix.com", "primevideo.com", "hotstar.com", "vimeo.com", "twitch.tv"]
    static let articleSites = ["medium.com", "substack.com", "nytimes.com", "theguardian.com", "bbc.com", "cnn.com",
                               "ndtv.com", "timesofindia.indiatimes.com", "hindustantimes.com", "moneycontrol.com",
                               "economictimes.indiatimes.com", "techcrunch.com", "theverge.com", "wikipedia.org", "dev.to"]
    static let searchSites = ["google.com", "bing.com", "duckduckgo.com", "search.brave.com", "kagi.com"]
    /// A social site's messages (LinkedIn, X, Instagram, Facebook) are a conversation, not its feed.
    static let messagePaths = ["messag", "/inbox", "/direct", "/dm", "/chat"]
    /// A product's site says these.
    static let marketing = ["pricing", "get started", "sign up", "start free", "free trial", "book a demo", "request a demo",
                            "download for", "download now", "features", "testimonials", "trusted by", "join the waitlist",
                            "try it free", "for teams", "plans", "per month", "/mo"]

    static func on(_ domain: String, _ sites: [String]) -> Bool {
        sites.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// The kind of a window: its app (or site), then its address, then what it says.
    public static func of(app: String, domain: String, url: String?, title: String, text: String) -> WindowKind {
        let name = app.lowercased()
        let address = (url ?? "").lowercased()
        guard !domain.isEmpty else {
            if conversationApps.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) { return .conversation }
            if assistantApps.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) { return .assistant }
            if workApps.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) { return .work }
            return .app
        }
        if on(domain, conversationSites) { return .conversation }
        if on(domain, feedSites) || on(domain, videoSites) {
            if messagePaths.contains(where: address.contains) { return .conversation }
            return on(domain, videoSites) ? .video : .feed
        }
        if on(domain, assistantSites) { return .assistant }
        if on(domain, workSites) { return .work }
        if on(domain, searchSites), address.contains("search") || address.contains("q=") { return .search }
        if on(domain, articleSites) { return .article }
        if domain.hasPrefix("docs.") || domain.hasPrefix("developer.") || address.contains("/docs") || address.contains("/documentation") {
            return .docs
        }
        // A site that sells something says so: a few marketing phrases on its page.
        let lower = (title + "\n" + text.prefix(6000)).lowercased()
        if marketing.filter({ lower.contains($0) }).count >= 2 { return .product }
        return .page
    }

    public static func of(_ snapshot: Journal.Snapshot) -> WindowKind {
        WindowKind(rawValue: snapshot.kind) ?? of(app: snapshot.app, domain: snapshot.domain, url: snapshot.url,
                                                   title: snapshot.title, text: snapshot.text)
    }
}
