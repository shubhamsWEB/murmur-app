import FluidAudio

/// Speech to text with NVIDIA's Parakeet TDT on the Neural Engine (through FluidAudio).
/// Each model downloads once from Hugging Face (about 600 MB) and is cached by FluidAudio; after that it runs offline.
public actor ParakeetTranscriber {
    public enum Model: String, CaseIterable, Sendable {
        /// Parakeet TDT 0.6B v2: English only, the most accurate for English (accents included).
        case english
        /// Parakeet TDT 0.6B v3: 25 European languages, detected automatically.
        case multilingual

        public var display: String {
            switch self {
            case .english: return "English (most accurate)"
            case .multilingual: return "Multilingual (25 European languages)"
            }
        }

        var version: AsrModelVersion {
            switch self {
            case .english: return .v2
            case .multilingual: return .v3
            }
        }
    }

    public nonisolated let model: Model
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    public init(model: Model = .english) {
        self.model = model
    }

    public var isReady: Bool { manager != nil }

    /// Downloads (first time only) and loads the model. Safe to call more than once.
    public func prepare() async throws {
        _ = try await loadedManager()
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let manager = try await loadedManager()
        // Parakeet wants at least a second of audio: pad short clips with silence.
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let version = model.version
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do {
            let loaded = try await task.value
            manager = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }
}
