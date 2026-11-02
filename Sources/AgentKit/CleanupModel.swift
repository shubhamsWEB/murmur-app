import Foundation
import Observation

/// The model AI cleanup uses. By default Murmur's own: a small model (Qwen3.5 0.8B, about 0.5 GB) trained only to
/// tidy dictation by Murmur's rules, in Ollama on this Mac. It answers in a fraction of a second and keeps your words,
/// where a general model of a few billion parameters takes seconds and often writes its reasoning instead. Until it's
/// on this Mac (or with "Same as commands" picked), cleanup uses the commands' model, local or cloud, as before.
@MainActor
@Observable
public final class CleanupModel {
    public static let shared = CleanupModel()

    public enum Choice: String, CaseIterable, Sendable {
        /// Murmur's cleanup model, when it's on this Mac; else the commands' model.
        case murmur
        /// The commands' model (Settings → Commands & AI).
        case commands

        public var display: String {
            switch self {
            case .murmur: return "Murmur Cleanup"
            case .commands: return "Same as commands"
            }
        }
    }

    public enum Phase: Equatable, Sendable {
        case unknown
        case ready
        /// Ollama is there, the model isn't.
        case missing
        case noOllama
        /// 0 to 1.
        case downloading(Double)
        case failed(String)
    }

    /// The name Murmur asks Ollama for. A model built from a GGUF (`ollama create murmur-cleanup -f Modelfile`, see
    /// murmur-models) counts, as does one downloaded from `source`.
    public static let tag = "murmur-cleanup"

    /// Where the download comes from: the model in Ollama's library, with the chat layout and settings it was trained
    /// with. It's copied to `tag` once downloaded, so a new version is a new source and the same name.
    /// `defaults write com.copico.Murmur cleanupModelSource <library name>` for another.
    public static var source: String? {
        if let chosen = UserDefaults.standard.string(forKey: "cleanupModelSource"), !chosen.isEmpty { return chosen }
        return published
    }

    /// The published model (ollama.com/shubhama664/murmur-cleanup): Qwen3.5 0.8B trained with murmur-models.
    static let published: String? = "shubhama664/murmur-cleanup:v1"

    public static let sizeText = "0.5 GB"

    public private(set) var phase: Phase = .unknown
    public var choice: Choice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "cleanupModel") }
    }
    private var task: Task<Void, Never>?

    private init() {
        choice = UserDefaults.standard.string(forKey: "cleanupModel").flatMap(Choice.init) ?? .murmur
    }

    /// Cleanup runs on Murmur's own model: it's picked and on this Mac.
    public var inUse: Bool { choice == .murmur && phase == .ready }

    public var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// Looks again when it wasn't there a minute or more ago (Ollama opened since, or the model was built), before a
    /// dictation. A fraction of a second, and only while it's missing.
    public func refreshIfStale() async {
        guard choice == .murmur, phase != .ready, !isDownloading,
              Date().timeIntervalSince(checked) > (phase == .unknown ? 0 : 60) else { return }
        await refresh()
    }

    @ObservationIgnored private var checked = Date.distantPast

    /// Where things stand (not while a download runs).
    public func refresh() async {
        guard !isDownloading else { return }
        checked = Date()
        switch await OllamaProbe.check(model: Self.tag) {
        case .ready: phase = .ready
        case .missingModel, .notRunning: phase = .missing
        case .notInstalled: phase = .noOllama
        }
    }

    /// Starts the download in the background (opening Ollama if it's closed). Does nothing when it's already in,
    /// downloading, or not published yet.
    public func start() {
        guard task == nil, let source = Self.source else { return }
        task = Task { [weak self] in
            await self?.download(source)
            self?.task = nil
        }
    }

    private func download(_ source: String) async {
        if case .ready = await OllamaProbe.check(model: Self.tag) { phase = .ready; return }
        guard OllamaProbe.isInstalled else { phase = .noOllama; return }
        phase = .downloading(0)
        await OllamaProbe.startIfNeeded(model: Self.tag)
        if let error = await OllamaProbe.download(source, progress: { [weak self] part in self?.phase = .downloading(part) }) {
            phase = .failed(error)
            return
        }
        if let error = await OllamaProbe.copy(source, to: Self.tag) {
            phase = .failed(error)
            return
        }
        if case .ready = await OllamaProbe.check(model: Self.tag) {
            phase = .ready
        } else {
            phase = .failed("The download didn't finish. Try again in Settings → AI cleanup.")
        }
    }
}
