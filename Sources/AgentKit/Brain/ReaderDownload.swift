import Foundation
import Observation

/// Downloads Murmur's reading model (`murmur-engine download-reader-model`: Qwen3, checked byte for byte) when memory
/// first needs it: a source read by the model (Notes, Mail, connected apps) or screen memory is on, and it isn't there.
/// In the background, picking up where it stopped; the Memory page shows how far it is.
@MainActor
@Observable
public final class ReaderDownload {
    public static let shared = ReaderDownload()

    public enum State: Equatable, Sendable {
        case idle
        case downloading(done: Int64, total: Int64)
        case verifying
        case waiting(String)
        case done
        case failed(String)
    }

    public private(set) var state: State = .idle
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = Data()

    init() {
        if LocalReader.installed { state = .done }
    }

    /// Starts the download unless the model is there or it's already coming.
    public func ensure() {
        guard !LocalReader.installed else { state = .done; return }
        guard process?.isRunning != true, let engine = LocalReader.engine else { return }
        let process = Process()
        process.executableURL = engine
        process.arguments = ["download-reader-model"]
        process.qualityOfService = .utility
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.read(data) }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in self?.ended(status) }
        }
        do {
            try process.run()
            self.process = process
            state = .downloading(done: 0, total: 0)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The engine's events, one JSON line each (`murmur-engine download-model`'s format).
    private func read(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch event["event"] as? String {
            case "progress":
                state = .downloading(done: (event["all_bytes"] as? NSNumber)?.int64Value ?? 0,
                                     total: (event["all_total"] as? NSNumber)?.int64Value ?? 0)
            case "verifying": state = .verifying
            case "waiting": state = .waiting("Waiting for the internet")
            case "retry": state = .waiting(event["message"] as? String ?? "Trying again")
            case "error": state = .failed(event["message"] as? String ?? "The download failed")
            case "done": state = .done
            default: break
            }
        }
    }

    private func ended(_ status: Int32) {
        process = nil
        if LocalReader.installed {
            state = .done
            Task { await Brain.shared.sync() }   // what was waiting for a model gets read
        } else if case .failed = state {
        } else {
            state = .failed("The download stopped (\(status)). It starts again next time.")
        }
    }

    /// For the Memory page.
    public var summary: String? {
        switch state {
        case .idle, .done: return nil
        case .downloading(let done, let total):
            guard total > 0 else { return "Downloading Murmur’s reading model…" }
            return "Downloading Murmur’s reading model: \(Int(Double(done) / Double(total) * 100))% of "
                + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) + "."
        case .verifying: return "Checking Murmur’s reading model…"
        case .waiting(let why): return "Murmur’s reading model: \(why)."
        case .failed(let why): return "Murmur’s reading model didn’t download: \(why)"
        }
    }
}
