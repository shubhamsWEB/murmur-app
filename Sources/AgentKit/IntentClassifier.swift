import Foundation

/// Decides whether something you said is a command for Murmur or text to type, so one key does both.
///
/// Cheap signals first, the model only when they can't tell:
/// 1. ⌃ held → command.
/// 2. No text field has the focus → command (there's nothing to type into).
/// 3. A known command pattern ("open Slack", "volume 30") → command.
/// 4. Starts with "Murmur" ("Murmur, summarise this") → command.
/// 5. In a text field and it opens like an instruction ("send…", "summarise…", "translate…") → the router model
///    decides, with a short time limit; if it can't answer in time, it's typed.
/// 6. Anything else → typed.
public enum IntentClassifier {
    public enum Intent: String, Sendable {
        case command
        case dictation
    }

    public struct Decision: Sendable {
        public let intent: Intent
        public let reason: String

        public init(intent: Intent, reason: String) {
            self.intent = intent
            self.reason = reason
        }
    }

    /// Words that start an instruction to the computer. Dictated prose rarely opens with these bare.
    static let commandOpeners: Set<String> = [
        "open", "launch", "start", "quit", "close", "exit", "hide", "show", "switch", "go", "find", "search", "google",
        "look", "play", "pause", "stop", "set", "turn", "mute", "unmute", "lock", "take", "run", "send", "reply",
        "write", "draft", "compose", "summarize", "summarise", "translate", "rewrite", "rephrase", "shorten",
        "make", "fix", "correct", "explain", "ask", "create", "schedule", "remind", "email", "message", "text",
        "call", "copy", "paste", "select", "delete", "undo", "check", "tell", "what", "what's", "whats", "who",
        "when", "where", "how", "why", "can", "could", "please",
    ]

    public static func decide(_ utterance: String, forcedCommand: Bool, textFieldFocused: Bool, frontApp: String?,
                              hasSelection: Bool, model: String) async -> Decision {
        if forcedCommand { return Decision(intent: .command, reason: "⌃ held") }
        let cleaned = QuickCommands.clean(utterance)
        if cleaned.isEmpty { return Decision(intent: .dictation, reason: "empty") }
        if !textFieldFocused { return Decision(intent: .command, reason: "no text field focused") }
        if let quick = QuickCommands.parseAll(utterance), cleaned.split(separator: " ").count <= 14 {
            return Decision(intent: .command, reason: "known command (\(quick.map(\.tool).joined(separator: " + ")))")
        }
        if utterance.lowercased().range(of: #"^\s*(hey |ok |okay )?murmur\b"#, options: .regularExpression) != nil {
            return Decision(intent: .command, reason: "addressed to Murmur")
        }
        let first = cleaned.split(separator: " ").first.map(String.init) ?? ""
        guard commandOpeners.contains(first) else { return Decision(intent: .dictation, reason: "reads as text") }

        let system = """
        You classify one utterance spoken to Murmur, a Mac voice assistant. Either the user is giving Murmur a \
        COMMAND to carry out (open or quit apps, search, change settings, ask Murmur a question, rewrite or \
        summarise the selected text, write something for them), or they are DICTATING words to be typed as-is into \
        the text field they are in (a message, an email body, notes), even if those words contain verbs or questions. \
        Answer with JSON {"intent": "command"} or {"intent": "dictation"}.
        """
        let user = """
        App in front: \(frontApp ?? "unknown"). A text field has the focus. Text selected: \(hasSelection ? "yes" : "no").
        Utterance: "\(utterance)"
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["intent": ["type": "string", "enum": ["command", "dictation"]]],
            "required": ["intent"],
        ]
        let answer = await OllamaClient(model: model).decide(system: system, user: user, schema: schema, timeout: 2.5)
        switch answer?["intent"] as? String {
        case "command": return Decision(intent: .command, reason: "model: command")
        case "dictation": return Decision(intent: .dictation, reason: "model: dictation")
        default: return Decision(intent: .dictation, reason: "model unavailable, typed")
        }
    }
}
