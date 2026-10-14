import Foundation

/// Takes a model's reasoning out of what it says, so you only ever see the answer.
///
/// Ollama is asked not to think (`"think": false`), but an older Ollama, or a model that ignores the switch, still
/// writes its reasoning into the answer: `<think>…</think>` (Qwen3, DeepSeek-R1), a cut-off `<think>` with no end
/// when the answer hit its length cap mid-thought, or gpt-oss's analysis channel.
public enum ModelOutput {
    private static let tags = "think|thinking|reasoning|thought|reflection"

    /// The answer without the reasoning. Empty when there was only reasoning.
    public static func answer(_ raw: String) -> String {
        var text = raw
        // gpt-oss (harmony format): keep the final channel when one is there.
        if let final = text.range(of: "<|channel|>final<|message|>") {
            text = String(text[final.upperBound...])
        }
        // gpt-oss's analysis channel with no final one: reasoning only.
        text = text.replacingOccurrences(of: #"(?s)<\|channel\|>analysis<\|message\|>.*?(<\|end\|>|$)"#, with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"<\|[a-z_]+\|>"#, with: "", options: .regularExpression)
        // Whole reasoning blocks.
        text = text.replacingOccurrences(of: #"(?is)<(\#(tags))>.*?</\1>"#, with: "", options: .regularExpression)
        // An end tag with no start (the template opened the block): everything before it was reasoning.
        if let regex = try? NSRegularExpression(pattern: #"(?i)</(\#(tags))>"#),
           let end = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
           let range = Range(end.range, in: text) {
            text = String(text[range.upperBound...])
        }
        // A start tag with no end (cut off mid-thought): everything after it is reasoning.
        if let start = text.range(of: #"(?i)<(\#(tags))>"#, options: .regularExpression) {
            text = String(text[..<start.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `raw` held reasoning at all (so an empty answer means "only reasoning", worth asking again).
    public static func hadReasoning(_ raw: String) -> Bool {
        raw.range(of: #"(?i)</?(\#(tags))>|<\|channel\|>"#, options: .regularExpression) != nil
    }
}
