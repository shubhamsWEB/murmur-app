import Foundation

/// Decides whether something you said is a command for Murmur or text to type, so one key does both.
///
/// Typing is the default; a command needs a clear signal:
/// 1. ⌃ held → command.
/// 2. A known command pattern ("open Slack", "open chrome and search facebook", "volume 30") → command.
/// 3. Starts with "Murmur" ("Murmur, summarise this") → command.
/// 4. Doesn't open like an instruction → typed.
/// 5. Opens like an instruction to the computer ("open…", "summarise…", "translate…"); messages and questions
///    ("send…", "what's…") don't count, so they're typed unless you say "Murmur" first or hold ⌃:
///    - the focus is somewhere you can't type (Finder, the desktop) → command;
///    - otherwise the router model decides, with a short time limit; no answer → typed.
/// Whether a text field has the focus is often unknown (Chrome and Electron apps don't always say), so "unknown"
/// never counts as "no text field".
public enum IntentClassifier {
    public enum Intent: String, Sendable {
        case command
        case dictation
    }

    /// What has the keyboard focus, as far as Accessibility can tell.
    public enum Focus: String, Sendable {
        case textField
        case notText
        case unknown
    }

    public struct Decision: Sendable {
        public let intent: Intent
        public let reason: String
        /// A clear signal (⌃, a known command, "Murmur…", nowhere to type), not the model's guess. A guessed command
        /// that ends up only answering is typed instead (see `CommandAgent`).
        public let explicit: Bool

        public init(intent: Intent, reason: String, explicit: Bool = true) {
            self.intent = intent
            self.reason = reason
            self.explicit = explicit
        }
    }

    /// Words that start an instruction to the computer. Dictated prose rarely opens with these bare.
    static let commandOpeners: Set<String> = [
        "open", "launch", "start", "quit", "close", "exit", "hide", "switch", "find", "search", "google", "play",
        "pause", "set", "turn", "mute", "unmute", "lock", "run", "summarize", "summarise", "translate", "rewrite",
        "rephrase", "shorten", "schedule", "remind", "check", "update", "upgrade", "install", "uninstall",
        "enable", "disable", "connect", "disconnect", "empty", "restart", "reboot", "shut", "sleep", "show", "go",
        "navigate", "take", "download", "clear", "change", "increase", "decrease", "reduce", "raise", "lower",
        "toggle", "create", "make", "build", "add", "delete", "remove", "move", "rename", "copy", "watch",
        "explain", "ask", "tell", "dim", "brighten",
    ]

    /// "…on my MacBook", "…on this computer": talking about the Mac, so most likely an instruction for it.
    static let aboutTheMac = #"\b(on|for|of|in) (my|this|the) (mac|macbook|laptop|computer|system|screen|desktop)\b"#

    /// A question or instruction about what's on the screen: "what's on my screen", "summarise this page", "what
    /// does this error say", "read this email", "what am I looking at". Nobody dictates these into a message.
    static let aboutTheScreen = #"^(what(['’]s| is| are| does| do)?|whats|which|read|describe|summari[sz]e|explain|tell me|look at|check)\b.*\b(screen|on screen|this (page|tab|window|error|message|email|mail|article|document|doc|site|website|video|chart|table|code|dialog|popup|notification)|the (page|tab|window|error|dialog|popup))\b|^what (am i|i'm|im) (looking at|seeing)\b"#

    /// Questions that open a sentence: with "…on my Mac" they're asked of the Mac ("how much space is left on my
    /// Mac?"), not written to someone.
    static let questionOpeners: Set<String> = [
        "what", "what's", "what’s", "whats", "how", "which", "why", "where", "when", "is", "are", "can", "could", "do", "does",
        "did", "read", "describe",
    ]

    public static func decide(_ utterance: String, forcedCommand: Bool, focus: Focus, frontApp: String?,
                              hasSelection: Bool, router: Router) async -> Decision {
        if forcedCommand { return Decision(intent: .command, reason: "⌃ held") }
        let cleaned = QuickCommands.clean(utterance)
        if cleaned.isEmpty { return Decision(intent: .dictation, reason: "empty") }
        // Text selected and "summarise this", "make it more formal", "translate this to Hindi".
        if hasSelection, CommandAgent.isAboutSelection(utterance) {
            return Decision(intent: .command, reason: "an instruction about the selected text")
        }
        // "my photos from Goa are amazing" in a message is text; "find my photos…" is a search anywhere.
        let verblessFileSearch = QuickCommands.parseAll(utterance)?.allSatisfy { $0.tool == "search_files" } == true
            && cleaned.range(of: #"^(find|search|show|get|look|open)\b"#, options: .regularExpression) == nil
        if verblessFileSearch, focus == .textField {
            return Decision(intent: .dictation, reason: "file words, but you're in a text field")
        }
        if let quick = QuickCommands.parseAll(utterance), cleaned.split(separator: " ").count <= 14 {
            return Decision(intent: .command, reason: "known command (\(quick.map(\.tool).joined(separator: " + ")))")
        }
        // "open Notes and write a shopping list", "open TextEdit and type…": a task in an app.
        // Building software: "create a React app with a hello world page".
        if QuickCommands.codingTask(utterance) != nil {
            return Decision(intent: .command, reason: "something to build (Claude Code / Codex)")
        }
        // A chain of steps for the computer: "open Notes and write…", "search YouTube for lofi and play the first one".
        if cleaned.range(of: #"^(open|launch|start|go to|visit|switch to|search|find|look up|play|google) .+ (and|then) (then )?(write|type|draft|jot|note|add|put|create|make|compose|list|play|watch|click|open|search|press|select|pick|scroll|sort|filter|subscribe|save|download|summari[sz]e|sum up|explain|describe|read|translate|tell|check|compare|reply|answer|copy|send|email|share|bookmark|find|look)\b"#,
                         options: .regularExpression) != nil {
            return Decision(intent: .command, reason: "a chain of steps")
        }
        if WakeName.strip(utterance) != nil {
            return Decision(intent: .command, reason: "addressed to Murmur")
        }
        if cleaned.range(of: aboutTheScreen, options: .regularExpression) != nil {
            return Decision(intent: .command, reason: "about what's on the screen")
        }
        // Somewhere you can't type (the desktop, a Finder window, a player): whatever you said is for Murmur.
        if focus == .notText { return Decision(intent: .command, reason: "nowhere to type") }
        let first = cleaned.split(separator: " ").first.map(String.init) ?? ""
        let mentionsMac = cleaned.range(of: aboutTheMac, options: .regularExpression) != nil
        // "What's on my screen?", "how much space is left on my Mac?", "open the Downloads folder on my Mac".
        if mentionsMac, commandOpeners.contains(first) || questionOpeners.contains(first) {
            return Decision(intent: .command, reason: "about this Mac")
        }
        guard commandOpeners.contains(first) || mentionsMac else {
            return Decision(intent: .dictation, reason: "reads as text")
        }
        if focus == .notText { return Decision(intent: .command, reason: "instruction, and nowhere to type") }

        let system = """
        You classify one utterance spoken to Murmur, a Mac voice assistant. Either the user is giving Murmur a \
        COMMAND to carry out (open or quit apps, search, change settings, ask Murmur a question, rewrite or \
        summarise the selected text, write something for them), or they are DICTATING words to be typed as-is into \
        the text field they are in (a message, an email body, notes), even if those words contain verbs or questions. \
        Answer "command" or "dictation".
        """
        let user = """
        App in front: \(frontApp ?? "unknown"). Text field focused: \(focus == .textField ? "yes" : "probably"). \
        Text selected: \(hasSelection ? "yes" : "no").
        Utterance: "\(utterance)"
        """
        let answer = await router.choose(system: system, user: user, field: "intent",
                                         options: ["command", "dictation"], timeout: 2.5)
        switch answer {
        case "command": return Decision(intent: .command, reason: "\(router.name): command", explicit: false)
        case "dictation": return Decision(intent: .dictation, reason: "\(router.name): dictation")
        default:
            let why = RouterDiagnostics.lastError.map { ": \($0)" } ?? ""
            return Decision(intent: .dictation, reason: "\(router.name) didn't answer\(why); typed")
        }
    }
}
