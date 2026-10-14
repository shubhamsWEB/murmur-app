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

    /// A word or name to listen for (custom vocabulary): how it's written, and what it tends to be heard as.
    public struct VocabularyTerm: Equatable, Sendable {
        public let text: String
        public let aliases: [String]

        public init(text: String, aliases: [String] = []) {
            self.text = text
            self.aliases = aliases
        }
    }

    /// One transcription: as Parakeet heard it, and with your vocabulary applied (the same when there's none).
    public struct Transcript: Sendable {
        public let heard: String
        public let text: String
        /// Your terms that were put in from the audio.
        public let applied: [String]
    }

    public nonisolated let model: Model
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private var vocabulary: [VocabularyTerm] = []
    /// Custom vocabulary (FluidAudio): a small CTC model (Parakeet 110M) listens for your terms in the audio, and
    /// where it hears one with confidence and the transcript has a look-alike there ("samai raina"), the transcript
    /// takes your spelling ("Samay Raina"). Nothing else in the transcript changes.
    private var booster: VocabularyBoostingSession?
    private var boosterLoading: Task<VocabularyBoostingSession?, Error>?

    public init(model: Model = .english) {
        self.model = model
    }

    public var isReady: Bool { manager != nil }

    /// Downloads (first time only) and loads the model. Safe to call more than once. `progress` gets the fraction
    /// done (0…1) and whether it's downloading (true) or preparing the model for the Neural Engine (false).
    public func prepare(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws {
        _ = try await loadedManager(progress: progress)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribeDetailed(samples).text
    }

    /// The words and names to listen for (your personal dictionary). The listening model loads in the background
    /// the first time there are terms (about 200 MB, downloaded once).
    public func setVocabulary(_ terms: [VocabularyTerm]) {
        let cleaned = terms.filter { $0.text.trimmingCharacters(in: .whitespaces).count >= 3 }
        guard cleaned != vocabulary else { return }
        vocabulary = cleaned
        booster = nil
        boosterLoading = nil
        if !cleaned.isEmpty {
            Task { _ = try? await self.loadedBooster() }
        }
    }

    /// Transcribes, then applies the custom vocabulary (when `boost` and there are terms). If the vocabulary can't
    /// be used (its model failed to load), the transcript is returned as heard.
    public func transcribeDetailed(_ samples: [Float], boost: Bool = true) async throws -> Transcript {
        let manager = try await loadedManager()
        // Parakeet wants at least a second of audio: pad short clips with silence.
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        let heard = result.text
        guard boost, !vocabulary.isEmpty, let booster = try? await loadedBooster(),
              let timings = result.tokenTimings, !timings.isEmpty else {
            return Transcript(heard: heard, text: heard, applied: [])
        }
        guard let output = await booster.rescore(text: heard, tokenTimings: timings, audioSamples: audio),
              output.wasModified else {
            return Transcript(heard: heard, text: heard, applied: [])
        }
        let applied = output.replacements.filter(\.shouldReplace).compactMap(\.replacementWord)
        return Transcript(heard: heard, text: output.text, applied: applied)
    }

    private func loadedBooster() async throws -> VocabularyBoostingSession? {
        if let booster { return booster }
        if let boosterLoading { return try await boosterLoading.value }
        let terms = vocabulary
        guard !terms.isEmpty else { return nil }
        let task = Task { () throws -> VocabularyBoostingSession? in
            let models = try await CtcModels.downloadAndLoad()
            // Terms are tokenized by the session, with the CTC model's own tokenizer.
            let context = CustomVocabularyContext(terms: terms.map {
                CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
            })
            let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: models)
            return session.vocabulary.terms.isEmpty ? nil : session
        }
        boosterLoading = task
        do {
            let loaded = try await task.value
            // The vocabulary may have changed while loading: keep it only if it's still the current one.
            if terms == vocabulary { booster = loaded }
            boosterLoading = nil
            return loaded
        } catch {
            boosterLoading = nil
            throw error
        }
    }

    private func loadedManager(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let version = model.version
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
