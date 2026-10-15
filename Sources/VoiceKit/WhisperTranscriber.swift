import Foundation
import WhisperKit

/// Speech to text with a Whisper model on the Neural Engine (through WhisperKit). Murmur uses it for Hinglish: models
/// fine-tuned to write spoken Hindi in English letters ("main kal meeting mein aaunga"). Each model downloads once
/// from Hugging Face into Application Support/Murmur/Speech Models; after that it runs offline.
public actor WhisperTranscriber {
    /// A WhisperKit model: the Hugging Face repo and the folder in it that holds the Core ML files.
    public struct Source: Sendable, Equatable {
        public let repo: String
        public let variant: String
        /// The language token the model was trained with. The Hinglish models write English letters under "en";
        /// forcing "hi" switches them back to Devanagari.
        public let language: String
    }

    public nonisolated let source: Source
    private var kit: WhisperKit?
    private var loading: Task<WhisperKit, Error>?

    public init(source: Source) {
        self.source = source
    }

    public var isReady: Bool { kit != nil }

    static var modelsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Murmur/Speech Models")
    }

    /// Downloads (first time only) and loads the model. `progress` gets the fraction done (0…1) and whether it's
    /// downloading (true) or preparing the model for the Neural Engine (false).
    public func prepare(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws {
        _ = try await loadedKit(progress: progress)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let kit = try await loadedKit()
        let options = DecodingOptions(
            task: .transcribe,
            language: source.language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadedKit(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> WhisperKit {
        if let kit { return kit }
        if let loading { return try await loading.value }
        let source = source
        let task = Task { () throws -> WhisperKit in
            let base = Self.modelsFolder
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // Where WhisperKit's downloader keeps the files (models/<repo>/<variant>). Once they're there, load them
            // without asking Hugging Face again, so Murmur works offline.
            var folder = base.appendingPathComponent("models/\(source.repo)/\(source.variant)")
            let downloaded = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            if !downloaded {
                folder = try await WhisperKit.download(variant: source.variant, downloadBase: base, from: source.repo) { update in
                    progress?(update.fractionCompleted, true)
                }
            }
            progress?(0, false)
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: base,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            progress?(1, false)
            return kit
        }
        loading = task
        do {
            let loaded = try await task.value
            kit = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }
}
