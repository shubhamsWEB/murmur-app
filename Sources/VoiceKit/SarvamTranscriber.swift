import AgentKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Dictation by Sarvam's speech-to-text (Saaras), with the user's Sarvam key: Hindi, Hinglish, English and 20 more
/// Indian languages, mixed as spoken. The one speech model that isn't on this Mac: picked only by choice, and the
/// recording goes to Sarvam (nothing else does). A dictation over 28 seconds goes in pieces cut at its pauses, sent
/// together and put back in order.
actor SarvamTranscriber {
    static let endpoint = URL(string: "https://api.sarvam.ai/speech-to-text")!
    static let keyAccount = "sarvam"

    enum Failure: LocalizedError {
        case noKey
        case unreachable
        case refused(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "No Sarvam API key. Add one under Commands & AI → API keys."
            case .unreachable: return "Couldn't reach Sarvam. Check your internet connection."
            case .refused(let code, let detail):
                let why = detail.isEmpty ? "" : ": \(detail.prefix(160))"
                switch code {
                case 401, 403: return "Sarvam rejected the API key (\(code))\(why)"
                case 429: return "Sarvam says you're over your rate limit or out of credits (429)\(why)"
                default: return "Sarvam returned \(code)\(why)"
                }
            }
        }
    }

    /// How what you say is written (Settings → Dictation, with Sarvam picked).
    static var output: SarvamAudio.Output {
        UserDefaults.standard.string(forKey: "sarvamOutput").flatMap(SarvamAudio.Output.init) ?? .standard
    }

    /// Saaras v4 refused a mode (English letters, translation) this launch: those go to v3.
    private static let modesLock = NSLock()
    nonisolated(unsafe) private static var modesOnV3 = false
    static var onV3: Bool {
        get { modesLock.withLock { modesOnV3 } }
        set { modesLock.withLock { modesOnV3 = newValue } }
    }

    /// The language to expect; "unknown" lets Sarvam tell (the default).
    static var language: String { UserDefaults.standard.string(forKey: "sarvamLanguage") ?? "unknown" }

    static var hasKey: Bool { Keychain.get(keyAccount).map { !$0.isEmpty } ?? false }

    /// The language Sarvam heard in the last dictation, for the log.
    private(set) var lastLanguage: String?

    /// `keyterms`: names and terms to listen for (Saaras v4 only).
    func transcribe(_ samples: [Float], keyterms: [String] = []) async throws -> String {
        guard let key = Keychain.get(Self.keyAccount), !key.isEmpty else { throw Failure.noKey }
        let output = Self.output
        let pieces = SarvamAudio.pieces(samples)
        guard !pieces.isEmpty else { return "" }
        do {
            return try await transcribe(samples, pieces: pieces, output: output, keyterms: keyterms, key: key)
        } catch Failure.refused(let code, _) where (code == 400 || code == 422) && output != .spoken && !Self.onV3 {
            // v4 doesn't take this mode after all: v3, from now on.
            lastLanguage = nil
            Self.onV3 = true
            return try await transcribe(samples, pieces: pieces, output: output, keyterms: keyterms, key: key)
        }
    }

    private func transcribe(_ samples: [Float], pieces: [Range<Int>], output: SarvamAudio.Output, keyterms: [String],
                            key: String) async throws -> String {
        let onV3 = Self.onV3
        var fields = output.fields(onV3: onV3) + [("language_code", Self.language)]
        if output.takesKeyterms(onV3: onV3), let terms = SarvamAudio.keyterms(keyterms) { fields.append(("keyterms", terms)) }
        let results = try await withThrowingTaskGroup(of: (Int, String, String?).self) { group in
            for (index, piece) in pieces.enumerated() {
                let wav = SarvamAudio.wav(samples[piece])
                group.addTask { let (text, language) = try await Self.send(wav, fields: fields, key: key); return (index, text, language) }
            }
            var texts = [String](repeating: "", count: pieces.count)
            var language: String?
            for try await (index, text, heard) in group {
                texts[index] = text
                if index == 0 { language = heard }
            }
            return (texts, language)
        }
        lastLanguage = results.1
        return results.0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// One piece: its text, and the language Sarvam heard.
    private static func send(_ wav: Data, fields: [(String, String)], key: String) async throws -> (String, String?) {
        let boundary = "murmur-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = SarvamAudio.form(boundary: boundary, fields: fields, file: wav)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw Failure.refused(code, detail)
        }
        return (json["transcript"] as? String ?? "", json["language_code"] as? String)
    }
}
