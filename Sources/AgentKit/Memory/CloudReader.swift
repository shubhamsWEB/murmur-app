import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reading episodes with Claude, OpenAI or Sarvam instead of the local model, when the user turns it on (Memory → "Read with
/// Claude"): seconds an episode, at any time, on any Mac, without the Mac's GPU. Only an episode's text goes (with
/// secrets taken out, as for the local model), with the user's own API key; nothing else of the memory does. Off by
/// default: Murmur stays local unless the user chooses this.
public enum CloudReader {
    /// "anthropic", "openai" or "sarvam".
    public typealias Provider = String

    /// The keys the app hands its helper when it starts it (the helper can't read Murmur's Keychain items, nor its
    /// settings), one line of JSON on its standard input: {"anthropic": "...", "anthropicModel": "...",
    /// "anthropicWorkspace": "...", "openai": "...", "openaiModel": "...", "sarvam": "...", "sarvamModel": "..."}.
    nonisolated(unsafe) public static var keys: [String: String] = [:]

    /// Reads the keys the app sent, when it said it would (MURMUR_KEYS_ON_STDIN): one line, then stdin is done with.
    public static func takeKeysFromStandardInput() {
        guard ProcessInfo.processInfo.environment["MURMUR_KEYS_ON_STDIN"] == "1",
              let line = readLine(strippingNewline: true),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String] else { return }
        keys = object.filter { !$0.value.isEmpty }
    }

    public static func available(_ provider: Provider?) -> Bool { provider.map { keys[$0] != nil } ?? false }

    /// What the app sends its helper: the keys saved for Claude, OpenAI and Sarvam, the models picked for
    /// commands, and the Anthropic workspace.
    public static func handoff(anthropic: String?, anthropicModel: String, workspace: String?, openai: String?,
                               openaiModel: String, sarvam: String? = nil, sarvamModel: String? = nil) -> String {
        var object: [String: String] = ["anthropicModel": anthropicModel, "openaiModel": openaiModel]
        if let anthropic { object["anthropic"] = anthropic }
        if let openai { object["openai"] = openai }
        if let sarvam { object["sarvam"] = sarvam }
        if let sarvamModel { object["sarvamModel"] = sarvamModel }
        if let workspace { object["anthropicWorkspace"] = workspace }
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The models: what the user picked for commands, else Claude's small fast one.
    static var anthropicModel: String { keys["anthropicModel"] ?? "claude-haiku-5-5" }
    static var openaiModel: String { keys["openaiModel"] ?? "gpt-6-luna" }
    static var sarvamModel: String { keys["sarvamModel"] ?? ChatCompletions.sarvam.defaultModel }

    /// Put after an answer that ran out of tokens.
    public static let cutOff = "\n[cut off]"

    /// The model it reads with.
    static func model(_ provider: Provider) -> String {
        provider == "anthropic" ? anthropicModel : provider == "sarvam" ? sarvamModel : openaiModel
    }

    /// The provider's name, as the memory log says it.
    static func name(_ provider: Provider) -> String {
        switch provider {
        case "openai": return "OpenAI"
        case "sarvam": return "Sarvam"
        default: return "Anthropic"
        }
    }

    /// The way an episode reader asks it.
    /// `json`: the answer is a JSON object (an episode's reading), else prose (a summary of the day).
    public static func ask(_ provider: Provider, json: Bool = true) -> EpisodeReader.Ask? {
        guard ["anthropic", "openai", "sarvam"].contains(provider), let key = keys[provider] else { return nil }
        let model = provider == "anthropic" ? anthropicModel : provider == "sarvam" ? sarvamModel : openaiModel
        return { system, user in
            await chat(system: system + (json ? "\nAnswer with the JSON object only." : ""), user: user, key: key,
                       provider: provider, model: model, json: json)
        }
    }

    static func chat(system: String, user: String, key: String, provider: Provider, model: String,
                     json: Bool = true) async -> String? {
        let anthropic = provider == "anthropic"
        let label = Self.name(provider)
        var request: URLRequest
        let body: [String: Any]
        if anthropic {
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let workspace = keys["anthropicWorkspace"], !workspace.isEmpty {
                request.setValue(workspace, forHTTPHeaderField: "anthropic-workspace-id")
            }
            body = ["model": model, "max_tokens": 4000, "system": system,
                    "messages": [["role": "user", "content": user]]]
        } else if provider == "sarvam" {
            // Sarvam's Token Factory: OpenAI-style, reasoning off (Sarvam 105B takes "none").
            request = URLRequest(url: ChatCompletions.sarvam.endpoint)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "max_tokens": 4000, "reasoning_effort": "none",
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        } else {
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var openai: [String: Any] = ["model": model, "max_completion_tokens": 4000,
                                         "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
            if json { openai["response_format"] = ["type": "json_object"] }
            body = openai
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else {
            MemoryLog.write("couldn't reach \(label) to read (offline?): the local model reads instead")
            return nil
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard code == 200 else {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            MemoryLog.write("\(label) refused to read (\(code)): \(detail.prefix(160))")
            return nil
        }
        // Out of tokens: the answer is cut off mid-word. Said in the log, and marked, so what reads it keeps only what
        // was finished (`cutOff`).
        let text: String?, cut: Bool
        if anthropic {
            let blocks = json?["content"] as? [[String: Any]] ?? []
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            cut = json?["stop_reason"] as? String == "max_tokens"
        } else {
            let choice = (json?["choices"] as? [[String: Any]])?.first
            text = (choice?["message"] as? [String: Any])?["content"] as? String
            cut = choice?["finish_reason"] as? String == "length"
        }
        guard let text else { return nil }
        if cut { MemoryLog.write("\(label)'s answer was cut off (out of tokens)") }
        return cut ? text + cutOff : text
    }
}
