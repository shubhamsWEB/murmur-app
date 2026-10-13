import Foundation

/// A minimal client for Ollama's chat API with tool calling (http://127.0.0.1:11434/api/chat), local only.
public struct OllamaClient: Sendable {
    public struct ToolCall: Sendable {
        public let name: String
        public let arguments: [String: JSONValue]
    }

    public struct Reply: Sendable {
        public let content: String
        public let toolCalls: [ToolCall]
    }

    public enum OllamaError: LocalizedError {
        case notRunning
        case modelMissing(String)
        case bad(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: return "Ollama isn't running. Open the Ollama app, then try again."
            case .modelMissing(let model): return "The model \(model) isn't installed. Run: ollama pull \(model)"
            case .bad(let detail): return "Ollama returned an error: \(detail)"
            }
        }
    }

    public let base = URL(string: "http://127.0.0.1:11434")!
    public var model: String

    public init(model: String) {
        self.model = model
    }

    /// One chat turn. `messages` are Ollama message objects; `tools` are function definitions.
    public func chat(messages: [[String: Any]], tools: [[String: Any]]) async throws -> Reply {
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": tools,
            "stream": false,
            "think": false,                 // a router needs a decision, not a chain of thought
            "keep_alive": "30m",            // stay loaded between commands
            "options": ["temperature": 0],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OllamaError.notRunning
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            let message = json["error"] as? String ?? "HTTP \(status)"
            if status == 404 || message.contains("not found") { throw OllamaError.modelMissing(model) }
            throw OllamaError.bad(message)
        }
        let message = json["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? String ?? ""
        var calls: [ToolCall] = []
        for call in message["tool_calls"] as? [[String: Any]] ?? [] {
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else {
                continue
            }
            var arguments: [String: JSONValue] = [:]
            if let raw = function["arguments"] as? [String: Any] {
                for (key, value) in raw { arguments[key] = JSONValue(value) }
            } else if let text = function["arguments"] as? String,
                      let raw = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                for (key, value) in raw { arguments[key] = JSONValue(value) }
            }
            calls.append(ToolCall(name: name, arguments: arguments))
        }
        return Reply(content: content, toolCalls: calls)
    }

    /// One short completion constrained to a JSON schema (for quick decisions). Nil on any failure or timeout.
    public func decide(system: String, user: String, schema: [String: Any], timeout: TimeInterval) async
        -> [String: Any]? {
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "format": schema,
            "stream": false,
            "think": false,
            "keep_alive": "30m",
            "options": ["temperature": 0, "num_predict": 24],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String,
              let object = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any]
        else { return nil }
        return object
    }

    /// Loads the model into memory ahead of the first command, so it answers fast.
    public func warmUp() async {
        var request = URLRequest(url: base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": "30m"])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Whether Ollama answers at all (for the menu's status line).
    public func isRunning() async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request)) != nil
    }
}

/// A JSON value from a tool call's arguments.
public enum JSONValue: Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case other(String)

    init(_ value: Any) {
        if let s = value as? String {
            self = .string(s)
        } else if let n = value as? NSNumber {
            // JSONSerialization gives NSNumber for both; only a real JSON true/false is a CFBoolean.
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        } else {
            self = .other(String(describing: value))
        }
    }

    public var description: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .other(let s): return s
        }
    }

    public var number: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
