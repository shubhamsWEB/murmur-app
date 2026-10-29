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

    /// The vision model is pulled and Ollama is running.
    public static func isReady() async -> Bool {
        if case .ready = await OllamaProbe.check(model: VisionText.localModel) { return true }
        return false
    }

    /// Why it can't be used yet, in words for the user.
    public static func setupHint() async -> String {
        switch await OllamaProbe.check(model: VisionText.localModel) {
        case .ready: return ""
        case .notInstalled: return "Install Ollama (ollama.com) for on-device screen vision."
        case .notRunning: return "Open the Ollama app for on-device screen vision."
        case .missingModel(let model):
            return "On-device screen vision needs its model: ollama pull \(model) (\(model.hasSuffix("8b") ? "6.2" : "3.3") GB)."
        }
    }

    /// Everything on the screenshot (text, clickable things with their positions in the screenshot's pixels, whether
    /// it's cut off), and the answer to `question` when there is one.
    public static func describe(_ jpeg: Data, width: Int, height: Int, app: String, window: String,
                                question: String) async -> Result<String, Failure> {
        let prompt = VisionText.describePrompt(app: app, window: window, question: question)
        switch await ask(prompt, jpeg: jpeg, maxTokens: 1800) {
        case .failure(let failure): return .failure(failure)
        case .success(let text): return .success(VisionText.inPixels(text, width: width, height: height))
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
        guard await isReady() else { return .failure(.notReady(await setupHint())) }
        let client = OllamaClient(model: VisionText.localModel)
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
