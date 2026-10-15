import Foundation

/// The speech models Murmur can use for dictation. The raw values are what's saved in settings, so `english` and
/// `multilingual` keep their old names.
public enum SpeechModel: String, CaseIterable, Sendable {
    /// Parakeet TDT 0.6B v2: English only, the most accurate for English (accents included).
    case english
    /// Oriserve Whisper-Hindi2Hinglish-Apex (Whisper large-v3-turbo, fine-tuned on ~700 h of Indian Hindi), 6-bit:
    /// Hindi and English, written in English letters. (Prime, on Whisper large-v3, was tried and dropped: Apex did
    /// better.)
    case hinglishApex
    /// Parakeet TDT 0.6B v3: 25 European languages, detected automatically.
    case multilingual

    /// A saved setting, including models that were dropped (Prime is now Apex).
    public init?(saved: String) {
        if saved == "hinglishPrime" { self = .hinglishApex; return }
        self.init(rawValue: saved)
    }

    /// In the pickers.
    public var display: String {
        switch self {
        case .english: return "English (most accurate)"
        case .multilingual: return "Other languages (25 European)"
        case .hinglishApex: return "Hinglish (Hindi in English letters)"
        }
    }

    /// The language choice, in onboarding and settings.
    public var language: String {
        switch self {
        case .english: return "English"
        case .hinglishApex: return "Hinglish"
        case .multilingual: return "Other languages"
        }
    }

    /// What the language choice means.
    public var languageDetail: String {
        switch self {
        case .english: return "Only English. The most accurate for it, accents included."
        case .hinglishApex: return "Hindi and English, mixed as you like. Typed in English letters."
        case .multilingual: return "Spanish, French, German and 22 more European languages, detected as you speak."
        }
    }

    /// Whether it's downloaded already: picking it is then instant.
    public var isOnThisMac: Bool {
        switch self {
        case .english: return ParakeetTranscriber.isDownloaded(.english)
        case .multilingual: return ParakeetTranscriber.isDownloaded(.multilingual)
        case .hinglishApex: return whisperSource.map(WhisperTranscriber.isDownloaded) ?? false
        }
    }

    /// The one-time download it needs.
    public var downloadSize: String {
        switch self {
        case .english, .multilingual: return "about 600 MB"
        case .hinglishApex: return "about 590 MB"
        }
    }

    /// On Home's "On this Mac" card.
    public var card: String {
        switch self {
        case .english: return "Parakeet · English"
        case .multilingual: return "Parakeet · 25 languages"
        case .hinglishApex: return "Whisper · Hinglish"
        }
    }

    /// In the status line ("Speech model ready (…, on device)").
    public var short: String {
        switch self {
        case .english: return "English"
        case .multilingual: return "multilingual"
        case .hinglishApex: return "Hinglish"
        }
    }

    /// Which runtime runs it, for the log.
    public var engine: String {
        switch self {
        case .english, .multilingual: return "Parakeet"
        case .hinglishApex: return "Whisper"
        }
    }

    var whisperSource: WhisperTranscriber.Source? {
        switch self {
        case .english, .multilingual: return nil
        case .hinglishApex:
            return .init(repo: "raghuramr14/whisperkit-hinglish-w6",
                         variant: "Oriserve_Whisper-Hindi2Hinglish-Apex-w6", language: "en")
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
        case .hinglishApex:
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
