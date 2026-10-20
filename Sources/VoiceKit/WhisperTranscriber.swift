import Foundation
@preconcurrency import WhisperKit

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

    /// WhisperKit isn't Sendable; this actor is the only thing that touches it, one call at a time.
    private final class Loaded: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    public nonisolated let source: Source
    private var kit: Loaded?
    /// How the last transcription went (encode and decode time, re-decodes), for the log.
    public private(set) var lastTimings: String?
    private var loading: Task<Loaded, Error>?

    public init(source: Source) {
        self.source = source
    }

    public var isReady: Bool { kit != nil }

    /// Whether the model's files are already on this Mac (picking it then needs no download).
    public static func isDownloaded(_ source: Source) -> Bool {
        let folder = modelsFolder.appendingPathComponent("models/\(source.repo)/\(source.variant)")
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Frees the disk space of models Murmur no longer offers (Hinglish Prime, ~890 MB).
    public static func removeDroppedModels() {
        let dropped = modelsFolder.appendingPathComponent("models/nitinh/whisperkit-hinglish-coreml")
        if FileManager.default.fileExists(atPath: dropped.path) { try? FileManager.default.removeItem(at: dropped) }
    }

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
        let results = try await kit.kit.transcribe(audioArray: samples, decodeOptions: Self.options(source))
        if let t = results.first?.timings {
            // (WhisperKit's fallback count is off by one; the time spent decoding again is exact.)
            lastTimings = String(format: "encode %.2f s, decode %.2f s, decoding again %.2f s, %.2f s in all",
                                 t.encoding, t.decodingLoop, t.decodingFallback, t.fullPipeline)
        }
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How Whisper decodes. WhisperKit's defaults decode again, up to five more times and each time more randomly,
    /// whenever the model isn't confident (average log-probability under −1.0) — and then keep the last, most random
    /// attempt. The Hinglish models are often "unsure" by that measure (Hindi in English letters), so one dictation
    /// could take six decodes and come out worse. Only a repetition loop (the known Whisper failure) is decoded again,
    /// once.
    static func options(_ source: Source) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: source.language,
            temperature: 0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: nil,
            firstTokenLogProbThreshold: nil,
            chunkingStrategy: .vad
        )
    }

    private func loadedKit(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> Loaded {
        if let kit { return kit }
        if let loading { return try await loading.value }
        let source = source
        let task = Task { () throws -> Loaded in
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
            // On the GPU, not the Neural Engine: macOS optimises a model this size for the Neural Engine the first
            // time it loads, which takes minutes (sometimes far longer) with no progress to show. The GPU loads it
            // in seconds and is still quick enough for a sentence.
            let compute = ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU,
                                              textDecoderCompute: .cpuAndGPU)
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: base,
                computeOptions: compute,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            // One second of silence through the whole pipeline, so the GPU's first-run setup happens now and not on
            // your first dictation.
            _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 16_000),
                                          decodeOptions: Self.options(source))
            progress?(1, false)
            return Loaded(kit)
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
