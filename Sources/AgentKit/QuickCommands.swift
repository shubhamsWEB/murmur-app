import Foundation

/// The fast path: common commands are recognised by pattern and run at once, with no model involved
/// ("open Slack", "quit Spotify", "volume 30", "search the web for…"). Anything else goes to the router model.
public enum QuickCommands {
    public struct Action: Equatable, Sendable {
        public let tool: String
        public let arguments: [String: String]
    }

    /// Normalizes what Parakeet wrote: lowercase, no trailing punctuation, no "please" / "hey murmur".
    static func clean(_ text: String) -> String {
        var s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"[.!?,;:]+$"#, with: "", options: .regularExpression)
        if let rest = WakeName.strip(s), !rest.isEmpty { s = rest }   // "Murmur, …" (or how Parakeet spelled it)
        s = s.replacingOccurrences(of: #"^(please |can you |could you )+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"( please)$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Spelled-out letters: "C V" → "cv", "P D F" → "pdf".
        s = s.replacingOccurrences(of: #"\bc\.? ?v\b\.?"#, with: "cv", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\bp\.? ?d\.? ?f\b\.?"#, with: "pdf", options: .regularExpression)
        // A false start before the command: "a search for…", "uh, open…", "so find…".
        s = s.replacingOccurrences(of: #"^(?:a|uh|um|erm|so|and|okay so|ok so),? (?=(?:search|find|open|show|look|pull|bring)\b)"#,
                                   with: "", options: .regularExpression)
        // "Search, my resume": Parakeet's comma after the verb isn't a pause between two commands.
        s = s.replacingOccurrences(of: #"^([a-z]+), "#, with: "$1 ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Sites people open by name, and their home pages.
    static let sites: [String: String] = [
        "youtube": "https://www.youtube.com", "you tube": "https://www.youtube.com", "gmail": "https://mail.google.com",
        "google": "https://www.google.com", "github": "https://github.com", "linkedin": "https://www.linkedin.com",
        "twitter": "https://x.com", "reddit": "https://www.reddit.com", "amazon": "https://www.amazon.in",
        "flipkart": "https://www.flipkart.com", "netflix": "https://www.netflix.com", "wikipedia": "https://en.wikipedia.org",
        "instagram": "https://www.instagram.com", "facebook": "https://www.facebook.com",
        "whatsapp web": "https://web.whatsapp.com", "chatgpt": "https://chatgpt.com", "claude": "https://claude.ai",
        "perplexity": "https://www.perplexity.ai", "google maps": "https://www.google.com/maps",
        "google drive": "https://drive.google.com", "drive": "https://drive.google.com",
        "google docs": "https://docs.google.com", "google sheets": "https://sheets.google.com",
        "google calendar": "https://calendar.google.com", "stack overflow": "https://stackoverflow.com",
        "stackoverflow": "https://stackoverflow.com", "hacker news": "https://news.ycombinator.com",
        "spotify": "https://open.spotify.com", "notion": "https://www.notion.so", "figma": "https://www.figma.com",
        "outlook": "https://outlook.live.com", "youtube music": "https://music.youtube.com",
    ]
    static let sitePattern = sites.keys.sorted { $0.count > $1.count }
        .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")

    /// Words that make "the pdf …" a sentence about the one on screen, not what to search for.
    static let aboutTheOpenOne = #"\b(is|are|was|you|can|it|scroll|read|summari[sz]e|summary|explain|on screen|open in|opened)\b"#

    private static let rules: [(String, (Match) -> Action?)] = [
        // "check for updates on my macbook", "update my mac", "is there a macos update"
        (#"^(?:check|look|search)(?: for)? (?:any |new |the )?(?:software |system |macos |mac ?os |mac )?updates?(?: (?:on|for) (?:my |the |this )?(?:mac|macbook|laptop|computer|system))?$|^(?:update|upgrade) (?:my |the |this )?(?:mac|macbook|macos|mac os|laptop|computer|system)$|^(?:is there|are there) (?:a |an |any )?(?:software |system |macos |mac )?updates?.*$"#, { _ in
            Action(tool: "open_settings", arguments: ["pane": "software update"]) }),
        (#"^(?:check for |update |show )?(?:my |all )?app (?:store )?updates$|^update (?:my |all )?apps$"#, { _ in
            Action(tool: "open_settings", arguments: ["pane": "app store updates"]) }),
        // "open wifi settings", "show battery settings", "open settings for bluetooth", "open system settings"
        (#"^(?:open|show|go to) (?:the |my )?(?:system )?(?:settings|preferences)(?: for)?(?: (.+))?$|^(?:open|show|go to) (?:the |my )?(.+?) (?:settings|preferences)$"#, { m in
            Action(tool: "open_settings", arguments: ["pane": m[1].isEmpty ? m[2] : m[1]]) }),
        // "open my resume pdf", "pull up the lease document", "open my cv": open the best match straight away.
        (#"^(?:open|pull up|bring up)(?: up)? (?:my |the |that |this |our )?((?:.+? )?(?:pdfs?|docx?|documents?|word doc|files?|photos?|pictures?|images?|videos?|screenshots?|recordings?|spreadsheets?|sheets?|slides|decks?|presentations?|resumes?|résumés?|cvs?|receipts?|invoices?|contracts?|leases?|statements?|notes?))$"#, { m in
            let query = m[1]
            // "open notes and write…" is a chain for the router, not a file called that.
            if query.range(of: #"\b(and|then)\b"#, options: .regularExpression) != nil { return nil }
            // "open photos" / "open notes" are apps; a file needs more than the type word.
            if !query.contains(" "), !["resume", "resumes", "résumé", "cv", "receipt", "invoice", "contract", "lease"]
                .contains(query) { return nil }
            return Action(tool: "open_file", arguments: ["query": query]) }),
        // "my photos on the beach", "show me pictures of the dog", "the pdf about my lease", "screenshots from last week"
        (#"^(?:show me |show |find |get |open |search for |look for )?(?:all )?(?:my |the |some )?((?:photos?|pictures?|pics|images?|screenshots?|videos?|clips?|recordings?|documents?|docs|pdfs?|files?|slides|presentations?|spreadsheets?|receipts?|invoices?)\b.*)$"#, { m in
            // "the pdf is open, you can scroll and read it", "the document on screen, summarise it": about the one
            // in front, for the router, not a search for files called that.
            if m[1].range(of: QuickCommands.aboutTheOpenOne, options: .regularExpression) != nil { return nil }
            return Action(tool: "search_files", arguments: ["query": m[1]]) }),
        (#"^(?:find|search for|search) (?:my |the )?(?:file|files|document|documents|pdf|photo|picture)s?(?: about| called| named| with)? (.+)$"#, { m in
            Action(tool: "search_files", arguments: ["query": m[1]]) }),
        // A site's own search: "search youtube for lofi", "find usb hubs on amazon", "look up swift actors on github".
        (#"^(?:search|look up|find|look for) (?:on |in )?(youtube|google images|google maps|google|amazon|flipkart|github|wikipedia|reddit|twitter|linkedin|stack ?overflow|spotify|netflix|maps)(?: for)? (.+)$"#, { m in
            Action(tool: "site_search", arguments: ["site": m[1], "query": m[2]]) }),
        (#"^(?:search|look up|find|look for) (?:for )?(.+?) (?:on|in) (youtube|google images|google maps|amazon|flipkart|github|wikipedia|reddit|twitter|linkedin|stack ?overflow|spotify|netflix)$"#, { m in
            Action(tool: "site_search", arguments: ["site": m[2], "query": m[1]]) }),
        // The web only when you say so: "google …", "search the web for …", "… on google", "look up …".
        (#"^(?:search|look) (?:on |in )?(?:the web|the internet|online|google)(?: for)? (.+)$"#, { m in
            Action(tool: "web_search", arguments: ["query": m[1]]) }),
        (#"^(?:search|look up|find) (?:for )?(.+?) (?:on google|on the web|on the internet|online)$"#, { m in
            Action(tool: "web_search", arguments: ["query": m[1]]) }),
        (#"^google (?:for )?(.+)$"#, { m in Action(tool: "web_search", arguments: ["query": m[1]]) }),
        (#"^look up (.+)$"#, { m in Action(tool: "web_search", arguments: ["query": m[1]]) }),
        // Everything else called "search" or "find" is your Mac: "search beach photos", "find the lease",
        // "search my laptop for the invoice", "look for … on my mac".
        (#"^(?:search|find|look for)(?: (?:my |the )?(?:laptop|mac|computer|files|drive|disk))?(?: for)? (.+?)(?: (?:on|in) (?:my |the )?(?:laptop|mac|computer|files|drive|disk))?$"#, { m in
            Action(tool: "search_files", arguments: ["query": m[1]]) }),
        (#"^open (?:my |the )?(downloads|documents|desktop|pictures|music|movies|home|applications)(?: folder)?$"#, { m in
            Action(tool: "open_folder", arguments: ["name": m[1]]) }),
        (#"^(?:open|go to|visit) ((?:https?://)?[a-z0-9-]+(?:\.| dot )[a-z.]{2,}(?:/\S*)?)$"#, { m in
            Action(tool: "open_url", arguments: ["url": m[1]]) }),
        // A well-known site by name: "open youtube", "go to gmail" (any "on chrome" was taken off first).
        (#"^(?:open|go to|visit|launch|pull up|bring up) (?:the )?("#
            + sitePattern + #")(?: website| site| page)?$"#, { m in
            Action(tool: "open_url", arguments: ["url": sites[m[1]] ?? m[1], "site": m[1]]) }),
        (#"^(?:open|launch|start|switch to|go to|show) (?:the )?(.+?)(?: app)?$"#, { m in
            Action(tool: "open_app", arguments: ["name": m[1]]) }),
        (#"^(?:quit|close|exit|kill) (?:the )?(.+?)(?: app)?$"#, { m in
            Action(tool: "quit_app", arguments: ["name": m[1]]) }),
        (#"^hide (?:the )?(.+?)(?: app)?$"#, { m in Action(tool: "hide_app", arguments: ["name": m[1]]) }),
        (#"^(?:set )?(?:the )?volume (?:to )?(\d{1,3})(?: percent|%)?$"#, { m in
            Action(tool: "set_volume", arguments: ["percent": m[1]]) }),
        (#"^(?:turn )?(?:the )?volume (up|down)$|^turn (up|down) (?:the )?volume$|^(louder|quieter|softer)$"#, { m in
            let word = [m[1], m[2], m[3]].first { !$0.isEmpty } ?? "up"
            return Action(tool: "change_volume", arguments: ["direction": word == "louder" || word == "up" ? "up" : "down"]) }),
        // "stop the video", "pause", "pause the music on spotify", "resume", "play it again": the media keys.
        (#"^(pause|stop|resume|unpause|continue|play)(?: playing)?(?: (?:the |this |my |that )?(?:video|music|song|playback|media|youtube|spotify|audio|track|podcast|movie|it))?(?: (?:on|in) (?:youtube|spotify|chrome|safari|apple music|music))?(?: again)?$"#, { m in
            Action(tool: "media_control", arguments: ["action": ["play", "resume", "unpause", "continue"].contains(m[1]) ? "play" : "pause"]) }),
        (#"^(?:next|skip)(?: (?:to the next )?(?:the |this )?(?:video|song|track|one))?$|^(?:play |go to )?(?:the )?next (?:video|song|track|one)$"#, { _ in
            Action(tool: "media_control", arguments: ["action": "next"]) }),
        (#"^(?:play |go to )?(?:the )?(?:previous|last) (?:video|song|track|one)$|^previous(?: (?:video|song|track))?$"#, { _ in
            Action(tool: "media_control", arguments: ["action": "previous"]) }),
        // "set brightness to 20%", "make the brightness 20 percent", "brightness 50"
        (#"^(?:(?:set|make|change|put|turn|bring) )?(?:the )?(?:screen |display )?brightness (?:to |at |up to |down to )?(\d{1,3})(?: ?percent| ?%)?$"#, { m in
            Action(tool: "set_brightness", arguments: ["percent": m[1]]) }),
        // "turn off bluetooth", "switch wifi on", "disable wi-fi"
        (#"^(?:turn|switch|put) (on|off) (?:the |my )?(bluetooth|wi-?fi|wifi|wireless)$|^(?:turn|switch|put) (?:the |my )?(bluetooth|wi-?fi|wifi|wireless) (on|off)$|^(enable|disable) (?:the |my )?(bluetooth|wi-?fi|wifi|wireless)$"#, { m in
            let state = [m[1], m[4], m[5]].first { !$0.isEmpty } ?? "on"
            let thing = [m[2], m[3], m[6]].first { !$0.isEmpty } ?? ""
            let on = state == "on" || state == "enable"
            return Action(tool: thing == "bluetooth" ? "set_bluetooth" : "set_wifi", arguments: ["on": on ? "true" : "false"]) }),
        (#"^(mute|unmute)(?: (?:the )?(?:sound|volume|audio|mac))?$"#, { m in
            Action(tool: "mute", arguments: ["on": m[1] == "mute" ? "true" : "false"]) }),
        (#"^(?:turn )?(?:the )?(?:screen )?brightness (up|down)$|^(brighter|dimmer)$"#, { m in
            let word = m[1].isEmpty ? m[2] : m[1]
            return Action(tool: "brightness", arguments: ["direction": word == "up" || word == "brighter" ? "up" : "down"]) }),
        (#"^lock (?:the |my )?(?:screen|mac|computer)$"#, { _ in Action(tool: "lock_screen", arguments: [:]) }),
        (#"^(?:take a )?screenshot$|^take a screen shot$"#, { _ in Action(tool: "screenshot", arguments: [:]) }),
        (#"^run (?:the |my )?shortcut (.+)$"#, { m in Action(tool: "run_shortcut", arguments: ["name": m[1]]) }),
    ]

    /// Words a chained command can start with ("open chrome and search facebook", "mute then lock the screen").
    static let verbs: Set<String> = [
        "open", "launch", "start", "switch", "go", "visit", "show", "quit", "close", "exit", "kill", "hide",
        "search", "google", "look", "find", "set", "turn", "volume", "mute", "unmute", "louder", "quieter", "softer",
        "brightness", "brighter", "dimmer", "lock", "take", "screenshot", "run", "my", "photos", "pictures",
        "play", "watch", "click", "type", "write", "press", "select", "pick", "add", "send", "scroll",
    ]

    /// Building software, said any way: "create a React app with a hello world page", "build me a website for my
    /// bakery", "write a python script that renames my photos", "ask Claude Code to make a todo app". One task for
    /// Claude Code or Codex, never split into steps or searched on the web.
    public static func codingTask(_ utterance: String) -> Action? {
        let text = clean(utterance)
        guard !text.isEmpty else { return nil }
        var helper = ""
        if text.range(of: #"\bcodex\b"#, options: .regularExpression) != nil { helper = "codex" }
        if text.range(of: #"\bclaude( code)?\b"#, options: .regularExpression) != nil { helper = "claude" }
        // "open claude code and build…", "ask codex to make…", "use claude to create…"
        let handOff = #"^(?:open|start|launch|ask|use|tell|get) (?:the )?(?:claude(?: code)?|codex)(?: to| and| session and| session to)? (.+)$"#
        if !helper.isEmpty, let regex = try? NSRegularExpression(pattern: handOff),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            return Action(tool: "build_with_agent", arguments: ["task": Match(text: text, result: match)[1], "helper": helper])
        }
        let verbs = #"^(?:create|build|make|scaffold|set up|setup|generate|code|write|develop|bootstrap|spin up|start) (?:me |us )?(?:a |an |the |new |simple |basic |small |quick |little )*"#
        guard text.range(of: verbs, options: .regularExpression) != nil else { return nil }
        let tech = #"\b(react|next ?js|vue|svelte|angular|node|express|python|flask|django|fast ?api|swift ?ui|swift|rust|golang|typescript|javascript|html|css|tailwind|vite|electron|chrome extension|ios|android|flutter|java|kotlin|spring|rails|laravel|php|sql|postgres|docker)\b"#
        // Only words that mean software even in a message ("write a script for the video" stays text).
        let things = #"\b(app|apps|website|web ?site|web app|webpage|landing page|api|backend|cli|command line tool|microservice|repo|(?:shell|bash|python|node) script|discord bot|telegram bot|slack bot)\b"#
        let isCode = text.range(of: tech, options: .regularExpression) != nil
            || text.range(of: things, options: .regularExpression) != nil
        guard isCode else { return nil }
        return Action(tool: "build_with_agent", arguments: ["task": text, "helper": helper])
    }

    /// All the actions in a chained command, in order, or nil unless every part is a known command.
    /// Splits only where the next part starts with a command verb, so "search for salt and pepper" stays whole.
    public static func parseAll(_ utterance: String) -> [Action]? {
        if let build = codingTask(utterance) { return [build] }
        let text = clean(utterance)
        guard !text.isEmpty, text.count < 200 else { return nil }
        var parts: [String] = []
        var current: [String] = []
        let words = text.replacingOccurrences(of: ",", with: " ,").split(separator: " ").map(String.init)
        var i = 0
        while i < words.count {
            let word = words[i]
            let joiners: Set<String> = ["and", "then", ","]
            if joiners.contains(word), !current.isEmpty {
                // Skip a run of joiners ("and then", ", and").
                var j = i
                while j < words.count, joiners.contains(words[j]) { j += 1 }
                if j < words.count, verbs.contains(words[j]) {
                    parts.append(current.joined(separator: " "))
                    current = []
                    i = j
                    continue
                }
            }
            if word != "," { current.append(word) }
            i += 1
        }
        if !current.isEmpty { parts.append(current.joined(separator: " ")) }
        var actions: [Action] = []
        for part in parts {
            guard let action = parse(part) else { return nil }
            actions.append(action)
        }
        return actions.isEmpty ? nil : actions
    }

    /// The action for a common command, or nil to let the router model decide.
    public static func parse(_ utterance: String) -> Action? {
        var text = clean(utterance)
        guard !text.isEmpty, text.count < 120 else { return nil }
        // "… on chrome", "… in safari", "… using firefox": which browser, said at the end ("" = the default one).
        var browser: String?
        let suffix = #" (?:on|in|using|with|from) (?:the |my )?(google chrome|chrome|safari|firefox|arc|brave|microsoft edge|edge|opera|vivaldi|orion|browser|web browser)$"#
        if let regex = try? NSRegularExpression(pattern: suffix),
           let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(found.range, in: text), let name = Range(found.range(at: 1), in: text) {
            browser = text[name].hasSuffix("browser") ? "" : String(text[name])
            text = String(text[..<whole.lowerBound])
        }
        if let browser {
            // "open chrome" and nothing else is just the app.
            guard !text.isEmpty else { return nil }
            let web: Set<String> = ["open_url", "web_search", "site_search"]
            for (pattern, make) in rules {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let action = make(Match(text: text, result: result)) else { continue }
                // "search flights on chrome": with a browser named, a search means the web.
                if action.tool == "search_files", let query = action.arguments["query"] {
                    var arguments = ["query": query]
                    if !browser.isEmpty { arguments["browser"] = browser }
                    return Action(tool: "web_search", arguments: arguments)
                }
                if web.contains(action.tool) {
                    var arguments = action.arguments
                    if !browser.isEmpty { arguments["browser"] = browser }
                    return Action(tool: action.tool, arguments: arguments)
                }
                // "open notion on chrome": a site we don't know by name; open it as an address.
                if action.tool == "open_app", let name = action.arguments["name"], !name.contains(" ") || name.count < 20 {
                    var arguments = ["url": name.replacingOccurrences(of: " ", with: "") + ".com"]
                    if !browser.isEmpty { arguments["browser"] = browser }
                    return Action(tool: "open_url", arguments: arguments)
                }
                return nil
            }
            return nil
        }
        for (pattern, make) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            if let action = make(Match(text: text, result: result)) {
                // "open spotify" with the Spotify app installed: the app, not the website.
                if action.tool == "open_url", let site = action.arguments["site"],
                   AppCatalog.shared.resolve(site)?.name.lowercased() == site { continue }
                // "open X" only takes the fast path when X is a real app; otherwise the router decides.
                if action.tool == "open_app" || action.tool == "quit_app" || action.tool == "hide_app" {
                    let name = action.arguments["name"] ?? ""
                    // "open notes and write a list": more than opening an app; the router does the whole thing.
                    if name.range(of: #"\b(and|then|to|with|about)\b"#, options: .regularExpression) != nil { return nil }
                    if action.tool == "open_app", AppCatalog.shared.resolve(name) == nil { return nil }
                    if name.split(separator: " ").count > 4 { return nil }
                }
                return action
            }
        }
        return nil
    }

    struct Match {
        let text: String
        let result: NSTextCheckingResult

        subscript(_ group: Int) -> String {
            guard group < result.numberOfRanges, let range = Range(result.range(at: group), in: text) else { return "" }
            return String(text[range])
        }
    }
}
