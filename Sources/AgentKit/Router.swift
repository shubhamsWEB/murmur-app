import Foundation

/// Which model picks the actions for a command (and decides command vs dictation).
public enum RouterChoice: String, CaseIterable, Sendable {
    case local
    case anthropic
    case openai

    public static let key = "routerProvider"

    public static var current: RouterChoice {
        get { UserDefaults.standard.string(forKey: key).flatMap(RouterChoice.init) ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    public var display: String {
        switch self {
        case .local: return "Local (Ollama)"
        case .anthropic: return "Claude (\(AnthropicRouter.model))"
        case .openai: return "OpenAI (\(OpenAIRouter.model))"
        }
    }

    /// The Keychain account for this provider's API key (nil for local).
    public var keyAccount: String? {
        switch self {
        case .local: return nil
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        }
    }

    public var hasKey: Bool { keyAccount.flatMap(Keychain.get) != nil }
}

/// A conversation turn, independent of any provider's wire format.
public enum RouterTurn: Sendable {
    case user(String)
    case assistant(text: String, calls: [RouterCall])
    case toolResult(callID: String, name: String, content: String)
}

public struct RouterCall: Sendable {
    public let id: String
    public let name: String
    public let arguments: [String: JSONValue]
}

public struct RouterReply: Sendable {
    public let text: String
    public let calls: [RouterCall]
}

public struct ToolSpec: @unchecked Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments.
    public let parameters: [String: Any]
}

public enum RouterError: LocalizedError {
    case noKey(String)
    case http(String, Int, String)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .noKey(let provider): return "No \(provider) API key. Add one under Commands & Assistants."
        case .http(let provider, let code, let detail):
            if code == 401 || code == 403 { return "\(provider) rejected the API key (\(code))." }
            if code == 429 { return "\(provider) says you're over your rate limit or quota (429)." }
            return "\(provider) returned \(code): \(detail.prefix(120))"
        case .unreachable(let provider): return "Couldn't reach \(provider)."
        }
    }
}

/// A model that can call tools.
public protocol Router: Sendable {
    var name: String { get }
    func chat(system: String, turns: [RouterTurn], tools: [ToolSpec]) async throws -> RouterReply
    /// Picks one of `options` (a forced single tool call / JSON schema). Nil on failure or timeout.
    func choose(system: String, user: String, field: String, options: [String], timeout: TimeInterval) async -> String?
}

/// The last error a cloud router hit, so the app can say what's wrong (a rejected key, no network).
public enum RouterDiagnostics {
    private static let lock = NSLock()
    private static var _lastError: String?

    public static var lastError: String? {
        get { lock.lock(); defer { lock.unlock() }; return _lastError }
        set { lock.lock(); _lastError = newValue; lock.unlock() }
    }

    /// True for errors that mean the API key is wrong (401/403).
    public static func isKeyProblem(_ error: String?) -> Bool {
        guard let error else { return false }
        return error.contains("rejected the API key") || error.contains("401") || error.contains("403")
            || error.contains("No ") && error.contains("API key")
    }
}

public enum Routers {
    /// The router for the current choice. Cloud choices without a key fall back to local.
    /// A cloud model whose key was just rejected isn't asked again (every command would wait for the same 401) until
    /// a new key is saved.
    public static func current(localModel: String) -> Router {
        let rejected = RouterDiagnostics.isKeyProblem(RouterDiagnostics.lastError)
        switch RouterChoice.current {
        case .anthropic where RouterChoice.anthropic.hasKey && !rejected: return AnthropicRouter()
        case .openai where RouterChoice.openai.hasKey && !rejected: return OpenAIRouter()
        default: return OllamaRouter(model: localModel)
        }
    }
}

// MARK: - Shared HTTP

enum HTTP {
    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any], timeout: TimeInterval,
                         provider: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RouterError.unreachable(provider)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let error = json["error"] as? [String: Any]
            let detail = (error?["message"] as? String) ?? (json["error"] as? String)
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw RouterError.http(provider, code, detail)
        }
        return json
    }

    static func arguments(_ raw: Any?) -> [String: JSONValue] {
        var object = raw as? [String: Any]
        if object == nil, let text = raw as? String {
            object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        var out: [String: JSONValue] = [:]
        for (key, value) in object ?? [:] { out[key] = JSONValue(value) }
        return out
    }

    static func jsonString(_ arguments: [String: JSONValue]) -> String {
        let plain = arguments.mapValues { value -> Any in
            switch value {
            case .string(let s): return s
            case .number(let n): return n
            case .bool(let b): return b
            case .other(let s): return s
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: plain)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func plain(_ arguments: [String: JSONValue]) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(jsonString(arguments).utf8))) as? [String: Any] ?? [:]
    }
}

// MARK: - Anthropic (Claude Haiku 5.5 by default)

public struct AnthropicRouter: Router {
    /// `defaults write com.copico.Murmur anthropicModel <id>` to use another model.
    public static var model: String { UserDefaults.standard.string(forKey: "anthropicModel") ?? "claude-haiku-5-5" }
    public var name: String { "Claude" }
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init() {}

    private func headers() throws -> [String: String] {
        guard let key = Keychain.get("anthropic") else { throw RouterError.noKey("Anthropic") }
        return ["x-api-key": key, "anthropic-version": "2023-06-01"]
    }

    private func messages(_ turns: [RouterTurn]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for turn in turns {
            switch turn {
            case .user(let text):
                out.append(["role": "user", "content": text])
            case .assistant(let text, let calls):
                var blocks: [[String: Any]] = []
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for call in calls {
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name,
                                   "input": HTTP.plain(call.arguments)])
                }
                out.append(["role": "assistant", "content": blocks])
            case .toolResult(let id, _, let content):
                let block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
                // Consecutive results belong in one user message.
                if var last = out.last, last["role"] as? String == "user", var blocks = last["content"] as? [[String: Any]],
                   blocks.first?["type"] as? String == "tool_result" {
                    blocks.append(block)
                    last["content"] = blocks
                    out[out.count - 1] = last
                } else {
                    out.append(["role": "user", "content": [block]])
                }
            }
        }
        return out
    }

    private func base(system: String, maxTokens: Int) -> [String: Any] {
        // Fastest settings: no extended thinking, low effort.
        ["model": Self.model, "max_tokens": maxTokens, "system": system,
         "thinking": ["type": "disabled"], "output_config": ["effort": "low"]]
    }

    public func chat(system: String, turns: [RouterTurn], tools: [ToolSpec]) async throws -> RouterReply {
        var body = base(system: system, maxTokens: tools.isEmpty ? 2048 : 1024)
        body["messages"] = messages(turns)
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description, "input_schema": tool.parameters]
            }
        }
        let json = try await HTTP.postJSON(endpoint, headers: try headers(), body: body, timeout: 20, provider: "Anthropic")
        var text = ""
        var calls: [RouterCall] = []
        for block in json["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text": text += block["text"] as? String ?? ""
            case "tool_use":
                calls.append(RouterCall(id: block["id"] as? String ?? UUID().uuidString,
                                        name: block["name"] as? String ?? "", arguments: HTTP.arguments(block["input"])))
            default: break
            }
        }
        return RouterReply(text: text, calls: calls)
    }

    public func choose(system: String, user: String, field: String, options: [String],
                       timeout: TimeInterval) async -> String? {
        var body = base(system: system, maxTokens: 64)
        body["messages"] = [["role": "user", "content": user]]
        let schema: [String: Any] = ["type": "object", "properties": [field: ["type": "string", "enum": options]],
                                     "required": [field]]
        let answerTool: [String: Any] = ["name": "answer", "description": "Give the answer", "input_schema": schema]
        body["tools"] = [answerTool]
        body["tool_choice"] = ["type": "tool", "name": "answer"]
        let json: [String: Any]
        do {
            json = try await HTTP.postJSON(endpoint, headers: try headers(), body: body, timeout: timeout,
                                           provider: "Anthropic")
            RouterDiagnostics.lastError = nil
        } catch {
            RouterDiagnostics.lastError = error.localizedDescription
            return nil
        }
        for block in json["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
            return (block["input"] as? [String: Any])?[field] as? String
        }
        return nil
    }
}

// MARK: - OpenAI (GPT-6 Luna by default)

public struct OpenAIRouter: Router {
    /// `defaults write com.copico.Murmur openaiModel <id>` to use another model.
    public static var model: String { UserDefaults.standard.string(forKey: "openaiModel") ?? "gpt-6-luna" }
    public var name: String { "OpenAI" }
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    public init() {}

    private func headers() throws -> [String: String] {
        guard let key = Keychain.get("openai") else { throw RouterError.noKey("OpenAI") }
        return ["Authorization": "Bearer \(key)"]
    }

    private func messages(system: String, _ turns: [RouterTurn]) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            switch turn {
            case .user(let text):
                out.append(["role": "user", "content": text])
            case .assistant(let text, let calls):
                var message: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty {
                    message["tool_calls"] = calls.map { call -> [String: Any] in
                        let function: [String: Any] = ["name": call.name, "arguments": HTTP.jsonString(call.arguments)]
                        return ["id": call.id, "type": "function", "function": function]
                    }
                }
                out.append(message)
            case .toolResult(let id, _, let content):
                out.append(["role": "tool", "tool_call_id": id, "content": content])
            }
        }
        return out
    }

    private func toolList(_ tools: [ToolSpec]) -> [[String: Any]] {
        tools.map { tool -> [String: Any] in
            let function: [String: Any] = ["name": tool.name, "description": tool.description,
                                           "parameters": tool.parameters]
            return ["type": "function", "function": function]
        }
    }

    public func chat(system: String, turns: [RouterTurn], tools: [ToolSpec]) async throws -> RouterReply {
        var body: [String: Any] = ["model": Self.model, "messages": messages(system: system, turns)]
        if !tools.isEmpty { body["tools"] = toolList(tools) }   // an empty list is an error; none means plain text
        let json = try await HTTP.postJSON(endpoint, headers: try headers(), body: body, timeout: 20, provider: "OpenAI")
        let message = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> RouterCall? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else {
                return nil
            }
            return RouterCall(id: call["id"] as? String ?? UUID().uuidString, name: name,
                              arguments: HTTP.arguments(function["arguments"]))
        }
        return RouterReply(text: message["content"] as? String ?? "", calls: calls)
    }

    public func choose(system: String, user: String, field: String, options: [String],
                       timeout: TimeInterval) async -> String? {
        let schema: [String: Any] = ["type": "object", "properties": [field: ["type": "string", "enum": options]],
                                     "required": [field]]
        let tool = ToolSpec(name: "answer", description: "Give the answer", parameters: schema)
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "tools": toolList([tool]),
            "tool_choice": ["type": "function", "function": ["name": "answer"]] as [String: Any],
        ]
        let json: [String: Any]
        do {
            json = try await HTTP.postJSON(endpoint, headers: try headers(), body: body, timeout: timeout,
                                           provider: "OpenAI")
            RouterDiagnostics.lastError = nil
        } catch {
            RouterDiagnostics.lastError = error.localizedDescription
            return nil
        }
        guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let call = (message["tool_calls"] as? [[String: Any]])?.first,
              let function = call["function"] as? [String: Any] else { return nil }
        return HTTP.arguments(function["arguments"])[field]?.description
    }
}

// MARK: - Ollama (local)

public struct OllamaRouter: Router {
    public let model: String
    public var name: String { "Local model" }

    public init(model: String) {
        self.model = model
    }

    private func messages(system: String, _ turns: [RouterTurn]) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            switch turn {
            case .user(let text):
                out.append(["role": "user", "content": text])
            case .assistant(let text, let calls):
                let list = calls.map { call -> [String: Any] in
                    let function: [String: Any] = ["name": call.name, "arguments": HTTP.plain(call.arguments)]
                    return ["function": function]
                }
                out.append(["role": "assistant", "content": text, "tool_calls": list])
            case .toolResult(_, let name, let content):
                out.append(["role": "tool", "tool_name": name, "content": content])
            }
        }
        return out
    }

    public func chat(system: String, turns: [RouterTurn], tools: [ToolSpec]) async throws -> RouterReply {
        let list = tools.map { tool -> [String: Any] in
            let function: [String: Any] = ["name": tool.name, "description": tool.description,
                                           "parameters": tool.parameters]
            return ["type": "function", "function": function]
        }
        let reply = try await OllamaClient(model: model).chat(messages: messages(system: system, turns), tools: list)
        let calls = reply.toolCalls.enumerated().map { index, call in
            RouterCall(id: "call_\(index)", name: call.name, arguments: call.arguments)
        }
        return RouterReply(text: reply.content, calls: calls)
    }

    public func choose(system: String, user: String, field: String, options: [String],
                       timeout: TimeInterval) async -> String? {
        let schema: [String: Any] = ["type": "object", "properties": [field: ["type": "string", "enum": options]],
                                     "required": [field]]
        let answer = await OllamaClient(model: model).decide(system: system, user: user, schema: schema,
                                                            timeout: timeout)
        return answer?[field] as? String
    }
}


/// Checks an API key before you rely on it: the shape first, then one cheap call to the provider (listing models).
public enum KeyCheck {
    /// What looks wrong with a key's shape, or nil.
    public static func shapeProblem(_ choice: RouterChoice, _ key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch choice {
        case .openai where !key.hasPrefix("sk-"):
            return "OpenAI keys start with “sk-” (project keys with “sk-proj-”). This one starts with “\(key.prefix(6))…”, so part of it may be missing."
        case .anthropic where !key.hasPrefix("sk-ant-"):
            return "Anthropic keys start with “sk-ant-”. This one starts with “\(key.prefix(6))…”, so part of it may be missing."
        default:
            return key.count < 20 ? "That key looks too short." : nil
        }
    }

    /// Asks the provider whether the saved key works. Nil when it does, else what's wrong.
    public static func verify(_ choice: RouterChoice) async -> String? {
        guard let account = choice.keyAccount, let key = Keychain.get(account) else { return "No key saved." }
        var request: URLRequest
        switch choice {
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .local:
            return nil
        }
        request.timeoutInterval = 10
        let provider = choice == .openai ? "OpenAI" : "Anthropic"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else {
            return "Couldn't reach \(provider) to check the key. Check your internet connection."
        }
        switch code {
        case 200:
            RouterDiagnostics.lastError = nil
            return nil
        case 401, 403:
            let message = "\(provider) rejected this key (\(code)). Copy the whole key again from your \(provider) account."
            RouterDiagnostics.lastError = RouterError.http(provider, code, "").localizedDescription
            return message
        default:
            return "\(provider) answered \(code) when checking the key. It may still work; try a command."
        }
    }
}
