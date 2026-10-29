import Foundation

/// The part of a message request that the user stated plainly. This is deliberately narrower than the model's
/// interpretation: it exists as a policy boundary for a consequential action, not as a general natural-language
/// parser. If it finds a target, that target wins over a model-supplied recipient.
enum MessageIntent {
    struct Target: Equatable, Sendable {
        let recipient: String
        /// The app the user named, normalized for the send tool. Nil means the user did not name one.
        let app: String?
    }

    /// Finds a recipient only in unambiguous English and Hinglish message forms. Pronouns are follow-up references,
    /// so they deliberately return nil and are resolved from the tightly scoped conversation context instead.
    static func explicitTarget(in utterance: String) -> Target? {
        let text = QuickCommands.clean(utterance)
        for pattern in patterns {
            guard let captures = captures(pattern.expression, in: text),
                  let recipient = captures[pattern.recipient] else { continue }
            let cleaned = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^(?:the|my)\s+"#, with: "", options: .regularExpression)
            guard !cleaned.isEmpty, !pronouns.contains(cleaned) else { continue }
            return Target(recipient: cleaned, app: pattern.app.flatMap { captures[$0] }.flatMap(canonicalApp))
        }
        return nil
    }

    /// Applies the user-authored part of a request after a model has proposed tool arguments. An explicit recipient
    /// and app are capability-policy inputs, so they cannot be replaced by model context; an omitted app remains the
    /// model's choice and later falls back to the person's saved/default app in `CommandAgent`.
    static func authoritativeTarget(in utterance: String, modelRecipient: String, modelApp: String) -> Target {
        let model = Target(recipient: modelRecipient,
                           app: modelApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : modelApp)
        guard let stated = explicitTarget(in: utterance) else { return model }
        // The spoken name, written as the model wrote it when they're the same name ("Neha" rather than the cleaned
        // "neha"), else with capitals: it's what the confirmation shows and what's searched for.
        let recipient = stated.recipient.caseInsensitiveCompare(modelRecipient.trimmingCharacters(in: .whitespaces)) == .orderedSame
            ? modelRecipient.trimmingCharacters(in: .whitespaces) : stated.recipient.capitalized
        return Target(recipient: recipient, app: stated.app ?? model.app)
    }

    private static let pronouns: Set<String> = ["him", "her", "them", "it", "this", "that", "those"]
    private struct Pattern {
        let expression: String
        let recipient: Int
        let app: Int?
    }

    private static let app = #"(whatsapp|slack|telegram|signal|imessage|messages|teams|discord)"#
    private static let boundary = #"(?:saying|that|to say|and say|asking|telling|to tell)"#
    private static let name = #"([\p{L}][\p{L}' -]{0,50}?)"#

    // Keep each form bounded by a message phrase. A broad “to <words>” matcher would risk treating message content
    // as a recipient, which is worse than leaving an uncommon phrasing to the normal tool flow. The forms that start
    // the request come first: in “Message Rahul that I sent it to Priya on WhatsApp” the recipient is Rahul, and the
    // “to …” form, which can match anywhere, would have taken Priya from the message itself.
    private static let patterns: [Pattern] = [
        // “Text Rahul that …” / “Message Rahul on WhatsApp …”.
        .init(expression: #"^(?:text|message|msg|whatsapp|ping|dm)\s+"# + name + #"\s+(?:(?:on|via|in|using)\s+"# + app + #"\b|"# + boundary + #"\b)"#,
              recipient: 1, app: 2),
        // “Tell Neha on WhatsApp …” / “Tell Neha that …”.
        .init(expression: #"^tell\s+"# + name + #"\s+(?:(?:on|via|in|using)\s+"# + app + #"\b|"# + boundary + #"\b)"#,
              recipient: 1, app: 2),
        // “Send Neha a WhatsApp message …”, which is common in speech but has no “to”.
        .init(expression: #"^send\s+"# + name + #"\s+(?:a\s+|an\s+)?(?:quick\s+|short\s+)?"# + app + #"\s+(?:message|msg|text|dm)\b"#,
              recipient: 1, app: 2),
        // “Priya ko WhatsApp pe …”: one word, at the start. Longer, it took the word before the name as part of it
        // (“Abhi Priya ko …”); a full name here is left to the model.
        .init(expression: #"^([\p{L}]+)\s+ko\s+"# + app + #"(?:\s+(?:pe|par|me|mein))?\b"#,
              recipient: 1, app: 2),
        // “WhatsApp pe Priya ko …”.
        .init(expression: #"\b"# + app + #"\s+(?:pe|par|me|mein)\s+"# + name + #"\s+ko\b"#,
              recipient: 2, app: 1),
        // “Send a message to Neha on WhatsApp …” / “Send hi to Neha saying …”.
        .init(expression: #"\bto\s+"# + name + #"\s+(?:(?:on|via|in|using)\s+"# + app + #"\b|"# + boundary + #"\b)"#,
              recipient: 1, app: 2),
    ]

    private static func captures(_ pattern: String, in text: String) -> [Int: String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Dictionary(uniqueKeysWithValues: (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { (index, String(text[$0])) }
        })
    }

    private static func canonicalApp(_ value: String) -> String? {
        switch value.lowercased() {
        case "whatsapp": "WhatsApp"
        case "slack": "Slack"
        case "telegram": "Telegram"
        case "signal": "Signal"
        case "imessage", "messages": "Messages"
        case "teams": "Teams"
        case "discord": "Discord"
        default: nil
        }
    }
}
