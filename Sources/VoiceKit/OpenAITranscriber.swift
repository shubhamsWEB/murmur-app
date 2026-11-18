import AgentKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Speech to text by OpenAI, with the user's OpenAI key: meeting notes use it to transcribe in the cloud when the
/// meeting's AI is OpenAI (and there's no Sarvam key). A stretch of speech at a time (each well under OpenAI's 25 MB),
/// as a 16 kHz WAV. `defaults write com.copico.Murmur openaiTranscribeModel <id>` to use another model.
enum OpenAITranscriber {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static var model: String { UserDefaults.standard.string(forKey: "openaiTranscribeModel") ?? "gpt-4o-mini-transcribe" }
    static var hasKey: Bool { RouterChoice.openai.hasKey }

    static func transcribe(_ samples: [Float]) async throws -> String {
        guard let key = Keychain.get("openai"), !key.isEmpty else { throw RouterError.noKey("OpenAI") }
        let boundary = "murmur-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = SarvamAudio.form(boundary: boundary, fields: [("model", model), ("response_format", "json")],
                                            file: SarvamAudio.wav(samples[...]))
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RouterError.unreachable("OpenAI")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw RouterError.http("OpenAI", code, detail)
        }
        return json["text"] as? String ?? ""
    }
}
