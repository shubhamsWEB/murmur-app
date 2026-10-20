import Foundation

/// What a command did, to show with its answer: the skills it followed, each step in plain words and whether it
/// worked, the model and the time it took. So you can see a skill was actually used, and how the task went.
public struct TaskTrace: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public let tool: String
        public let text: String
        public let worked: Bool
    }

    /// Skills given to the model in full: always-on ones, ones the request matched, ones it loaded with use_skill.
    public var skills: [String] = []
    /// Why each was given ("always on", "matched the request", "loaded by the model").
    public var why: [String: String] = [:]
    public var steps: [Step] = []
    public var model = ""
    public var started = Date()

    public init(started: Date = Date()) {
        self.started = started
    }

    public mutating func follow(_ skill: String, because reason: String) {
        guard !skills.contains(skill) else { return }
        skills.append(skill)
        why[skill] = reason
    }

    public mutating func record(_ tool: String, _ args: [String: String], result: String) {
        // Bookkeeping isn't a step you'd want to see; loading a skill is.
        guard !["done", "more_tools", "wait"].contains(tool) else { return }
        steps.append(Step(tool: tool, text: Self.describe(tool, args), worked: !TaskHealth.isFailure(result)))
    }

    /// A step in plain words: "Opened github.com", "Clicked “Inbox”", "Read the whole page".
    public static func describe(_ tool: String, _ args: [String: String]) -> String {
        func arg(_ key: String) -> String {
            let value = (args[key] ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return value.count > 60 ? String(value.prefix(57)) + "…" : value
        }
        func with(_ text: String, _ key: String) -> String { arg(key).isEmpty ? text : "\(text) \(arg(key))" }
        switch tool {
        case "open_app": return with("Opened", "name")
        case "quit_app": return with("Quit", "name")
        case "open_url": return with("Opened", "url")
        case "open_file": return "Opened file “\(arg("query"))”"
        case "search_files": return "Searched files for “\(arg("query"))”"
        case "web_search": return "Searched the web for “\(arg("query"))”"
        case "site_search": return "Searched \(arg("site")) for “\(arg("query"))”"
        case "browser_read": return "Read the page"
        case "read_whole_page": return "Read the whole page"
        case "read_screen": return "Looked at the screen"
        case "browser_click": return "Clicked “\(arg("text"))”"
        case "click": return "Clicked item [\(arg("id"))]"
        case "browser_type", "type_text": return "Typed “\(arg("text"))”"
        case "press_keys": return with("Pressed", "keys")
        case "browser_scroll": return with("Scrolled", "direction")
        case "browser_back": return "Went back a page"
        case "browser_switch_tab": return with("Switched to tab", "tab")
        case "browser_tabs": return "Listed the tabs"
        case "run_command": return "Ran `\(arg("command"))`"
        case "run_applescript": return arg("purpose").isEmpty ? "Ran a script" : "Ran a script: \(arg("purpose"))"
        case "app_dictionary": return with("Looked up the scripting terms of", "app")
        case "plan": return "Updated the task list"
        case "note": return "Noted: \(arg("text"))"
        case "use_skill": return "Loaded the \(arg("name")) skill"
        case "read_skill_file": return "Read \(arg("file")) from the \(arg("name")) skill"
        case "send_message": return "Sent a message to \(arg("to"))" + (arg("app").isEmpty ? "" : " on \(arg("app"))")
        case "write_in_app": return with("Wrote in", "app")
        case "insert_text", "paste_clipboard": return "Pasted where you were typing"
        case "replace_selection": return "Replaced the selected text"
        case "copy_text": return "Copied text"
        case "read_clipboard": return "Read the clipboard"
        case "calendar_events": return "Read the calendar"
        case "reminders_list": return "Read the reminders"
        case "remember": return "Remembered: \(arg("fact"))"
        case "recall": return "Looked back through earlier commands"
        case "reply": return "Answered"
        case "ask_claude": return "Asked Claude Code"
        case "ask_codex": return "Asked Codex"
        case "build_with_agent": return "Started a coding agent"
        default:
            let words = tool.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// "2 skills · 7 steps · 34 s"
    public func summary(now: Date = Date()) -> String {
        var parts: [String] = []
        if !skills.isEmpty { parts.append(skills.count == 1 ? "1 skill" : "\(skills.count) skills") }
        let counted = steps.filter { $0.tool != "reply" }.count
        parts.append(counted == 1 ? "1 step" : "\(counted) steps")
        let failed = steps.filter { !$0.worked }.count
        if failed > 0 { parts.append("\(failed) didn't work") }
        let seconds = Int(now.timeIntervalSince(started).rounded())
        parts.append(seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s")
        return parts.joined(separator: " · ")
    }

    public var isEmpty: Bool { skills.isEmpty && steps.isEmpty }
}
