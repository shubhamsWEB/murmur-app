import FluidAudio
import Foundation

/// Speech to text with NVIDIA's Parakeet TDT on the Neural Engine (through FluidAudio).
/// Each model downloads once from Hugging Face (about 600 MB) and is cached by FluidAudio; after that it runs offline.
public actor ParakeetTranscriber {
    public enum Model: String, CaseIterable, Sendable {
        /// Parakeet TDT 0.6B v2: English only, the most accurate for English (accents included).
        case english
        /// 25 European languages, detected automatically: Parakeet Ultra (a post-trained TDT 0.6B v3), or v3 on a
        /// Mac that hasn't updated yet.
        case multilingual

        public var display: String {
            switch self {
            case .english: return "English (most accurate)"
            case .multilingual: return "Multilingual (25 European languages)"
            }
        }

        /// English stays on v2 (English-only and the most accurate for it). Other languages use Parakeet Ultra, a
        /// post-trained v3 with fewer mistakes in all 25 languages at the same speed (mean FLEURS WER 14.81 % →
        /// 11.67 %). A Mac that already has v3 keeps using it until you choose to update (a 630 MB download).
        var version: AsrModelVersion {
            switch self {
            case .english: return .v2
            case .multilingual: return ParakeetTranscriber.multilingualVersion
            }
        }
    }

    /// Ultra when it's here, or when nothing is (a new download is always Ultra); v3 while that's all there is.
    static var multilingualVersion: AsrModelVersion {
        if modelsExist(.ultra) { return .ultra }
        return modelsExist(.v3) ? .v3 : .ultra
    }

    /// Other languages still run on v3 and the more accurate Ultra isn't downloaded yet.
    public static var multilingualUpdateAvailable: Bool { multilingualVersion == .v3 }

    /// Frees the disk space v3 used (about 480 MB) once Ultra is in use.
    public static func removeOldMultilingual() {
        guard modelsExist(.ultra) else { return }
        let old = AsrModels.defaultCacheDirectory(for: .v3)
        if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.removeItem(at: old) }
    }

    private static func modelsExist(_ version: AsrModelVersion) -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    public nonisolated let model: Model
    /// The Parakeet build this one loads, fixed when it's made (so an update to Ultra can load next to it).
    nonisolated let version: AsrModelVersion

    /// Whether the model's files are already on this Mac (picking it then needs no download).
    public static func isDownloaded(_ model: Model) -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: model.version), version: model.version)
    }
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    public init(model: Model = .english) {
        self.model = model
        self.version = model.version
    }

    /// Other languages on Parakeet Ultra even though v3 is what's on this Mac: the update, downloading next to v3.
    static func ultra() -> ParakeetTranscriber {
        ParakeetTranscriber(model: .multilingual, version: .ultra)
    }

    private init(model: Model, version: AsrModelVersion) {
        self.model = model
        self.version = version
    }

    public var isReady: Bool { manager != nil }

    /// Downloads (first time only) and loads the model. Safe to call more than once. `progress` gets the fraction
    /// done (0…1) and whether it's downloading (true) or preparing the model for the Neural Engine (false).
    public func prepare(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws {
        _ = try await loadedManager(progress: progress)
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

    private func loadedManager(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let version = self.version
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: { update in
                switch update.phase {
                case .compiling: progress?(update.fractionCompleted, false)
                default: progress?(update.fractionCompleted, true)
                }
            })
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
