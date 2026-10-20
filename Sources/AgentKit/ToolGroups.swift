import Foundation

/// The local model's tools, in sets. A small model chooses better, and answers sooner, from a short list: every
/// command gets the core tools (open, find, look at the screen, click, type, run a command, answer, plan), and the
/// other sets only when the request, the screen or the model asks for them. A call to a tool from a set that wasn't
/// loaded still runs, and loads its set. Cloud models get every tool, as before.
public enum ToolGroup: String, CaseIterable, Sendable, Comparable {
    case apps
    case system
    case browser
    case text
    case appData = "app_data"
    case messages
    case memory
    case coding
    case skills

    public static func < (a: ToolGroup, b: ToolGroup) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Always offered.
    public static let core: Set<String> = [
        "open_app", "open_file", "search_files", "open_url", "web_search", "read_screen", "click", "type_text",
        "press_keys", "wait", "run_command", "reply", "plan", "note", "done", "more_tools",
        // The helpers for hard reasoning, when the user turned them on: a small model's way out of its depth.
        "ask_claude", "ask_codex",
    ]

    public var tools: Set<String> {
        switch self {
        case .apps: return ["quit_app", "hide_app", "find_apps", "list_running_apps", "open_folder", "open_settings"]
        case .system:
            return ["set_volume", "change_volume", "mute", "brightness", "set_brightness", "lock_screen", "media_control",
                    "set_bluetooth", "set_wifi", "screenshot", "list_shortcuts", "run_shortcut"]
        case .browser:
            return ["site_search", "browser_read", "read_whole_page", "browser_click", "browser_type", "browser_scroll",
                    "browser_tabs", "browser_switch_tab", "browser_back"]
        case .text:
            return ["write_in_app", "insert_text", "read_clipboard", "copy_text", "paste_clipboard", "replace_selection"]
        case .appData: return ["calendar_events", "reminders_list", "run_applescript", "app_dictionary"]
        case .messages: return ["send_message"]
        case .memory: return ["remember", "forget_fact", "recall"]
        case .coding: return ["coding_followup", "build_with_agent"]
        case .skills: return ["use_skill", "read_skill_file"]
        }
    }

    /// What the set is for, in the words more_tools shows.
    public var purpose: String {
        switch self {
        case .apps: return "quit, hide and list apps, open folders, open System Settings"
        case .system: return "volume, brightness, Wi-Fi, Bluetooth, lock, screenshot, play/pause media, Shortcuts"
        case .browser: return "read, click, type and scroll inside web pages, browser tabs, search a site"
        case .text: return "write in an app, paste where the user was typing, the clipboard, replace the selection"
        case .appData: return "calendar, reminders, AppleScript for Mail, Notes, Messages and other apps"
        case .messages: return "send a message on WhatsApp, Messages, Slack and other chat apps"
        case .memory: return "remember a fact or preference, forget one, look back at earlier commands"
        case .coding: return "build software with Claude Code or Codex, and follow up on what they're building"
        case .skills: return "load one of the user's skills, read a skill's files"
        }
    }

    /// The set a tool belongs to; nil for a core tool (or one Murmur doesn't know).
    public static func of(_ tool: String) -> ToolGroup? {
        allCases.first { $0.tools.contains(tool) }
    }

    /// Whether `tool` is offered when `groups` are loaded.
    public static func offers(_ tool: String, in groups: Set<ToolGroup>) -> Bool {
        if core.contains(tool) { return true }
        guard let group = of(tool) else { return true }
        return groups.contains(group)
    }

    /// What the request is about, from what was said and where: generous, since a missing set costs a step.
    /// `cleaned`: the request lowercased (QuickCommands.clean).
    public static func select(_ cleaned: String, frontIsBrowser: Bool, hasSelection: Bool, codingSession: Bool,
                              skillsListed: Bool, mentionsMemory: Bool) -> Set<ToolGroup> {
        func says(_ pattern: String) -> Bool { cleaned.range(of: pattern, options: .regularExpression) != nil }
        var groups: Set<ToolGroup> = []
        if says(#"\b(quit|close|hide|band karo|band kar|running|installed|apps|folder|downloads|documents folder|desktop|finder|settings?|preferences|software update|updates?)\b"#) {
            groups.insert(.apps)
        }
        if says(#"\b(volume|sound|louder|quieter|softer|mute|unmute|awaaz|aawaz|awaz|bright(ness|er)?|dimmer|dim|dark mode|light mode|wi-?fi|bluetooth|lock|screenshot|screen ?shot|shortcuts?|pause|unpause|play|playing|next|previous|skip|song|music|track|video|chalao|bajao|roko|rok do)\b"#) {
            groups.insert(.system)
        }
        if frontIsBrowser
            || says(#"\b(web|website|site|page|tab|tabs|browser|chrome|safari|brave|arc|edge|firefox|google|youtube|online|internet|link|url|amazon|flipkart|myntra|swiggy|zomato|linkedin|twitter|reddit|github|gmail|wikipedia|maps|netflix|prime video|hotstar|instagram|facebook|news|price|prices|weather|score|article|blog|post|comments|search online|look up)\b"#)
            || says(#"\b[a-z0-9-]+\.(com|in|org|io|ai|dev|net|app|co)\b"#) {
            groups.insert(.browser)
        }
        if hasSelection
            || says(#"\b(write|type|paste|copy|insert|draft|translate|rewrite|summari[sz]e|notes?|textedit|pages|letter|clipboard|selection|selected|likho|likh do|likhkar|chipkao)\b"#) {
            groups.insert(.text)
        }
        if says(#"\b(calendar|meetings?|events?|schedule|reminders?|remind|mail|e-?mails?|inbox|notes|contacts?|applescript|today|tomorrow|tonight|this week|next week|kal|aaj|parso)\b"#) {
            groups.insert(.appData)
        }
        if says(#"\b(message|messages|msg|text|texts|whatsapp|imessage|slack|telegram|teams|discord|signal|send|reply|bhej|bhejo|bhejna|bata do|batao|tell|chat|dm)\b"#) {
            groups.insert(.messages)
        }
        if mentionsMemory
            || says(#"\b(remember|forget|recall|yaad|again|earlier|before|last time|yesterday|previous|from now on|call me|my name|did i|what did|which (file|video|page|song))\b"#) {
            groups.insert(.memory)
        }
        if codingSession
            || says(#"\b(build|code|coding|website|web app|script|api|project|react|next ?js|python|swift|program|claude|codex|repo|git|bug|compile)\b|\bcreate (an? )?(app|site|tool|game|extension)\b"#) {
            groups.insert(.coding)
        }
        if skillsListed { groups.insert(.skills) }
        return groups
    }

    /// The more_tools description: the sets not loaded yet, each with what it's for.
    public static func moreToolsHint(loaded: Set<ToolGroup>) -> String {
        let missing = allCases.filter { !loaded.contains($0) }
        guard !missing.isEmpty else { return "" }
        return missing.map { "\($0.rawValue) (\($0.purpose))" }.joined(separator: "; ")
    }

    /// "browser, system" / "the browser tools" → the sets named. Unknown words are ignored.
    public static func parse(_ text: String) -> [ToolGroup] {
        let words = text.lowercased().replacingOccurrences(of: "-", with: "_")
            .split(whereSeparator: { !$0.isLetter && $0 != "_" }).map(String.init)
        let other: [String: ToolGroup] = [
            "appdata": .appData, "calendar": .appData, "applescript": .appData, "web": .browser, "page": .browser,
            "pages": .browser, "message": .messages, "skill": .skills,
        ]
        var out: [ToolGroup] = []
        for word in words {
            guard let group = ToolGroup(rawValue: word) ?? other[word], !out.contains(group) else { continue }
            out.append(group)
        }
        return out
    }
}
