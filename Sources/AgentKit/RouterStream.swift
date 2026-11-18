import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A router that can hand back a plain-text answer as it's written, a few words at a time (meeting answers show
/// while they're being written instead of all at once after a few seconds).
public protocol StreamingRouter: Router {
    /// The answer's text as it comes, piece by piece (each piece is new text to add). `image`: a JPEG to look at
    /// with the prompt (only when `seesImages`).
    /// `thorough`: quality over speed (meeting answers and notes): a stronger model or more effort where the
    /// provider has one.
    func stream(system: String, prompt: String, image: Data?, maxTokens: Int, thorough: Bool)
        -> AsyncThrowingStream<String, Error>
    /// Whether the model can look at a picture (a shared slide or chart in a meeting).
    var seesImages: Bool { get }
}

public extension Router {
    /// Whether this router's model can look at a picture.
    var looksAtImages: Bool { (self as? StreamingRouter)?.seesImages ?? false }
}

public extension Router {
    /// A plain-text answer, as it's written when the router can stream, otherwise all at once. If a stream fails
    /// before any text came, it's asked once more without streaming.
    func write(system: String, prompt: String, image: Data? = nil, maxTokens: Int = 1200,
               thorough: Bool = false) -> AsyncThrowingStream<String, Error> {
        let streaming = self as? StreamingRouter
        let router = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var wrote = false
                if let streaming {
                    do {
                        let picture = streaming.seesImages ? image : nil
                        for try await piece in streaming.stream(system: system, prompt: prompt, image: picture,
                                                                maxTokens: maxTokens, thorough: thorough) {
                            wrote = true
                            continuation.yield(piece)
                        }
                        continuation.finish()
                        return
                    } catch {
                        if wrote || Task.isCancelled {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }
                do {
                    let reply = try await router.chat(system: system, turns: [.user(prompt)], tools: [])
                    continuation.yield(reply.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension HTTP {
    /// Posts `body` and reads the reply line by line as it arrives (server-sent events, or Ollama's one JSON object
    /// per line), handing each line's JSON to `piece`, which returns the new text in it.
    static func streamJSON(_ url: URL, headers: [String: String], body: [String: Any], provider: String,
                           piece: @escaping @Sendable ([String: Any]) -> String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 90
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let bytes: URLSession.AsyncBytes, response: URLResponse
                    do {
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                    } catch {
                        throw RouterError.unreachable(provider)
                    }
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else {
                        var text = ""
                        for try await line in bytes.lines {
                            text += line
                            if text.count > 2000 { break }
                        }
                        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                        let detail = ((json["error"] as? [String: Any])?["message"] as? String)
                            ?? (json["error"] as? String) ?? String(text.prefix(300))
                        throw RouterError.http(provider, code, detail)
                    }
                    for try await line in bytes.lines {
                        var payload = Substring(line)
                        if payload.hasPrefix("data:") { payload = payload.dropFirst(5) }
                        payload = Substring(payload.trimmingCharacters(in: .whitespaces))
                        guard !payload.isEmpty, payload != "[DONE]", !payload.hasPrefix("event:") else { continue }
                        guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
                        else { continue }
                        if let error = json["error"] {
                            let detail = ((error as? [String: Any])?["message"] as? String) ?? "\(error)"
                            throw RouterError.http(provider, code, detail)
                        }
                        if let text = piece(json), !text.isEmpty { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AnthropicRouter: StreamingRouter {
    public var seesImages: Bool { true }

    /// Meeting answers and notes: Sonnet, at medium effort, unless another model is set (`defaults write
    /// com.copico.Murmur meetingAnthropicModel <id>`, or the commands' own `anthropicModel`).
    public static var thoroughModel: String {
        UserDefaults.standard.string(forKey: "meetingAnthropicModel")
            ?? UserDefaults.standard.string(forKey: "anthropicModel") ?? "claude-sonnet-5-5"
    }

    public func stream(system: String, prompt: String, image: Data?, maxTokens: Int,
                       thorough: Bool) -> AsyncThrowingStream<String, Error> {
        var body = base(system: system, maxTokens: maxTokens)
        if thorough {
            body["model"] = Self.thoroughModel
            body["output_config"] = ["effort": "medium"]
        }
        if let image {
            let picture: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                                     "data": image.base64EncodedString()]]
            body["messages"] = [["role": "user", "content": [picture, ["type": "text", "text": prompt]]]]
        } else {
            body["messages"] = [["role": "user", "content": prompt]]
        }
        body["stream"] = true
        let headers: [String: String]
        do { headers = try self.headers() } catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        return HTTP.streamJSON(endpoint, headers: headers, body: body, provider: "Anthropic") { json in
            guard json["type"] as? String == "content_block_delta",
                  let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        }
    }
}

public extension RouterChoice {
    /// The choice as meetings use it: Claude answers meetings with its thorough model.
    var meetingDisplay: String {
        self == .anthropic ? "Claude (\(AnthropicRouter.thoroughModel))" : display
    }
}

extension OpenAIRouter: StreamingRouter {
    /// OpenAI's models look at pictures; Sarvam's text models don't.
    public var seesImages: Bool { provider.keyAccount == "openai" }

    public func stream(system: String, prompt: String, image: Data?, maxTokens: Int,
                       thorough: Bool) -> AsyncThrowingStream<String, Error> {
        let model = provider.model
        var user: [String: Any] = ["role": "user", "content": prompt]
        if let image {
            user["content"] = [["type": "text", "text": prompt],
                               ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.base64EncodedString()]]]
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], user],
            "stream": true,
        ]
        // As little reasoning as this model takes (what plain requests settled on).
        let step = provider.step(for: model)
        for (key, value) in provider.reasoningSteps[min(step, provider.reasoningSteps.count - 1)].fields {
            body[key] = value
        }
        // Thorough: some reasoning where the model takes an effort (if it refuses, the answer is asked again plainly).
        if thorough, body["reasoning_effort"] as? String == "none" { body["reasoning_effort"] = "low" }
        let headers: [String: String]
        do { headers = try self.headers() } catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        return HTTP.streamJSON(provider.endpoint, headers: headers, body: body, provider: provider.name) { json in
            let choice = (json["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        }
    }
}

extension OllamaRouter: StreamingRouter {
    /// The local commands model reads text only; a picture's text is read on this Mac instead.
    public var seesImages: Bool { false }

    public func stream(system: String, prompt: String, image: Data?, maxTokens: Int,
                       thorough: Bool) -> AsyncThrowingStream<String, Error> {
        let client = OllamaClient(model: model)
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "stream": true,
            "think": false,
            "keep_alive": "30m",
            "options": OllamaClient.options(["num_predict": maxTokens]),
        ]
        return HTTP.streamJSON(client.base.appendingPathComponent("api/chat"), headers: [:], body: body,
                               provider: "Ollama") { json in
            (json["message"] as? [String: Any])?["content"] as? String
        }
    }
}
