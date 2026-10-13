import FluidAudio

/// Speech to text with NVIDIA's Parakeet TDT v3 on the Neural Engine (through FluidAudio).
/// The model downloads once from Hugging Face (about 600 MB) and is cached by FluidAudio; after that it runs offline.
public actor ParakeetTranscriber {
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    public init() {}

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
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: .v3)
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
