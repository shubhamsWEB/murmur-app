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

    private static let rules: [(String, (Match) -> Action?)] = [
        // "open my resume pdf", "pull up the lease document", "open my cv": open the best match straight away.
        (#"^(?:open|pull up|bring up)(?: up)? (?:my |the |that |this |our )?((?:.+? )?(?:pdfs?|docx?|documents?|word doc|files?|photos?|pictures?|images?|videos?|screenshots?|recordings?|spreadsheets?|sheets?|slides|decks?|presentations?|resumes?|résumés?|cvs?|receipts?|invoices?|contracts?|leases?|statements?|notes?))$"#, { m in
            let query = m[1]
            // "open photos" / "open notes" are apps; a file needs more than the type word.
            if !query.contains(" "), !["resume", "resumes", "résumé", "cv", "receipt", "invoice", "contract", "lease"]
                .contains(query) { return nil }
            return Action(tool: "open_file", arguments: ["query": query]) }),
        // "my photos on the beach", "show me pictures of the dog", "the pdf about my lease", "screenshots from last week"
        (#"^(?:show me |show |find |get |open |search for |look for )?(?:all )?(?:my |the |some )?((?:photos?|pictures?|pics|images?|screenshots?|videos?|clips?|recordings?|documents?|docs|pdfs?|files?|slides|presentations?|spreadsheets?|receipts?|invoices?)\b.*)$"#, { m in
            Action(tool: "search_files", arguments: ["query": m[1]]) }),
        (#"^(?:find|search for|search) (?:my |the )?(?:file|files|document|documents|pdf|photo|picture)s?(?: about| called| named| with)? (.+)$"#, { m in
            Action(tool: "search_files", arguments: ["query": m[1]]) }),
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
    ]

    /// All the actions in a chained command, in order, or nil unless every part is a known command.
    /// Splits only where the next part starts with a command verb, so "search for salt and pepper" stays whole.
    public static func parseAll(_ utterance: String) -> [Action]? {
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
        let text = clean(utterance)
        guard !text.isEmpty, text.count < 120 else { return nil }
        for (pattern, make) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            if let action = make(Match(text: text, result: result)) {
                // "open X" only takes the fast path when X is a real app; otherwise the router decides.
                if action.tool == "open_app" || action.tool == "quit_app" || action.tool == "hide_app" {
                    let name = action.arguments["name"] ?? ""
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
