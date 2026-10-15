import Foundation

/// The speech models Murmur can use for dictation. The raw values are what's saved in settings, so `english` and
/// `multilingual` keep their old names.
public enum SpeechModel: String, CaseIterable, Sendable {
    /// Parakeet TDT 0.6B v2: English only, the most accurate for English (accents included).
    case english
    /// Parakeet TDT 0.6B v3: 25 European languages, detected automatically.
    case multilingual
    /// Oriserve Whisper-Hindi2Hinglish-Apex (Whisper large-v3-turbo, fine-tuned on ~700 h of Indian Hindi), 6-bit.
    case hinglishApex
    /// Oriserve Whisper-Hindi2Hinglish-Prime (Whisper large-v3, fine-tuned on ~550 h of Indian Hindi), 4-bit.
    case hinglishPrime

    /// In the pickers.
    public var display: String {
        switch self {
        case .english: return "English (most accurate)"
        case .multilingual: return "Multilingual (25 European languages)"
        case .hinglishApex: return "Hinglish · Apex (590 MB)"
        case .hinglishPrime: return "Hinglish · Prime (890 MB)"
        }
    }

    /// On Home's "On this Mac" card.
    public var card: String {
        switch self {
        case .english: return "Parakeet · English"
        case .multilingual: return "Parakeet · 25 languages"
        case .hinglishApex: return "Whisper · Hinglish Apex"
        case .hinglishPrime: return "Whisper · Hinglish Prime"
        }
    }

    /// In the status line ("Speech model ready (…, on device)").
    public var short: String {
        switch self {
        case .english: return "English"
        case .multilingual: return "multilingual"
        case .hinglishApex: return "Hinglish Apex"
        case .hinglishPrime: return "Hinglish Prime"
        }
    }

    /// Which runtime runs it, for the log.
    public var engine: String {
        switch self {
        case .english, .multilingual: return "Parakeet"
        case .hinglishApex, .hinglishPrime: return "Whisper"
        }
    }

    var whisperSource: WhisperTranscriber.Source? {
        switch self {
        case .english, .multilingual: return nil
        case .hinglishApex:
            return .init(repo: "raghuramr14/whisperkit-hinglish-w6",
                         variant: "Oriserve_Whisper-Hindi2Hinglish-Apex-w6", language: "en")
        case .hinglishPrime:
            return .init(repo: "nitinh/whisperkit-hinglish-coreml",
                         variant: "Oriserve_Whisper-Hindi2Hinglish-Prime_889MB", language: "en")
        }
    }
}

/// One front for every speech model: Parakeet (FluidAudio) or Whisper (WhisperKit), picked by `SpeechModel`.
public actor SpeechTranscriber {
    public nonisolated let model: SpeechModel
    private let parakeet: ParakeetTranscriber?
    private let whisper: WhisperTranscriber?

    public init(model: SpeechModel = .english) {
        self.model = model
        switch model {
        case .english:
            parakeet = ParakeetTranscriber(model: .english); whisper = nil
        case .multilingual:
            parakeet = ParakeetTranscriber(model: .multilingual); whisper = nil
        case .hinglishApex, .hinglishPrime:
            parakeet = nil; whisper = model.whisperSource.map(WhisperTranscriber.init(source:))
        }
    }

    public var isReady: Bool {
        get async {
            if let parakeet { return await parakeet.isReady }
            if let whisper { return await whisper.isReady }
            return false
        }
    }

    public func prepare(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws {
        if let parakeet { try await parakeet.prepare(progress: progress) }
        if let whisper { try await whisper.prepare(progress: progress) }
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        if let parakeet { return try await parakeet.transcribe(samples) }
        if let whisper { return try await whisper.transcribe(samples) }
        return ""
    }
}
