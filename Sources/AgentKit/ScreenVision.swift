import Foundation

/// Screenshots waiting to go to a model that can see (by id, from the markers in tool results). Only the latest few
/// are kept: older ones are left out of the conversation anyway.
public final class ScreenshotStore: @unchecked Sendable {
    public static let shared = ScreenshotStore()
    private let lock = NSLock()
    private var images: [(id: String, jpeg: Data)] = []

    public func put(_ jpeg: Data) -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        lock.lock()
        defer { lock.unlock() }
        images.append((String(id), jpeg))
        if images.count > 6 { images.removeFirst(images.count - 6) }
        return String(id)
    }

    public func get(_ id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return images.last { $0.id == id }?.jpeg
    }
}

/// Seeing the screen with a vision model on this Mac: Qwen3-VL through Ollama. The screenshot never leaves the Mac;
/// what goes on to the planning model (even a cloud one) is the description and the positions, as text.
public enum LocalVision {
    public enum Failure: Error, Sendable {
        case notReady(String)
        case failed(String)

        public var text: String {
            switch self {
            case .notReady(let why), .failed(let why): return why
            }
        }
    }

    /// The vision model to use: the one set (or the default) when it's on this Mac, else one an earlier version
    /// downloaded (until the default is downloaded too); nil when there's none, or Ollama isn't running.
    public static func model() async -> String? {
        if case .ready = await OllamaProbe.check(model: VisionText.localModel) { return VisionText.localModel }
        guard !VisionText.modelChosen else { return nil }
        for earlier in VisionText.earlierModels {
            if case .ready = await OllamaProbe.check(model: earlier) { return earlier }
        }
        return nil
    }

    /// A vision model is pulled and Ollama is running.
    public static func isReady() async -> Bool {
        await model() != nil
    }

    /// The model the last answer came from, for the log.
    nonisolated(unsafe) public private(set) static var lastModel = ""

    /// Why it can't be used yet, in words for the user.
    public static func setupHint() async -> String {
        switch await OllamaProbe.check(model: VisionText.localModel) {
        case .ready: return ""
        case .notInstalled: return "Install Ollama (ollama.com) for on-device screen vision."
        case .notRunning: return "Open the Ollama app for on-device screen vision."
        case .missingModel(let model):
            return "On-device screen vision needs its model: ollama pull \(model) (\(model.contains("8b") ? "6.1" : "3.3") GB)."
        }
    }

    /// The answer to `question` about the screenshot (or a short account of it), in a few sentences, with any
    /// position in the screenshot's pixels. `text`: what the Mac's text recognition read off it.
    public static func describe(_ jpeg: Data, width: Int, height: Int, app: String, window: String,
                                question: String, text: String?) async -> Result<String, Failure> {
        let prompt = VisionText.answerPrompt(app: app, window: window, question: question, text: text)
        switch await ask(prompt, jpeg: jpeg, maxTokens: 400) {
        case .failure(let failure): return .failure(failure)
        case .success(let answer): return .success(VisionText.inPixels(answer, width: width, height: height))
        }
    }

    /// Where `target` is on the screenshot, in its pixels; nil when the model says it isn't there.
    public static func locate(_ target: String, jpeg: Data, width: Int, height: Int)
        async -> Result<(x: Int, y: Int)?, Failure> {
        switch await ask(VisionText.locatePrompt(target), jpeg: jpeg, maxTokens: 60) {
        case .failure(let failure): return .failure(failure)
        case .success(let answer):
            guard let point = VisionText.location(in: answer) else { return .success(nil) }
            return .success(VisionText.pixels(relativeX: point.x, y: point.y, width: width, height: height))
        }
    }

    private static func ask(_ prompt: String, jpeg: Data, maxTokens: Int) async -> Result<String, Failure> {
        guard let model = await model() else { return .failure(.notReady(await setupHint())) }
        lastModel = model
        let client = OllamaClient(model: model)
        let message: [String: Any] = ["role": "user", "content": prompt, "images": [jpeg.base64EncodedString()]]
        do {
            let reply = try await client.chat(messages: [message], tools: [], maxTokens: maxTokens)
            let text = ModelOutput.answer(reply.content).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failure(.failed("The vision model gave no answer.")) : .success(text)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}
