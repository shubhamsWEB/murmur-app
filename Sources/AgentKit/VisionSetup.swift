import Foundation
import Observation

/// Getting the on-device vision model (Qwen3-VL through Ollama) onto this Mac: one download in the background, with
/// its progress, shared by onboarding, Settings and the first command that needs to see the screen. Nothing waits on
/// it: until it's in, Murmur reads the screen with the Mac's own text recognition.
@MainActor
@Observable
public final class VisionSetup {
    public static let shared = VisionSetup()

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

    public private(set) var phase: Phase = .unknown
    private var task: Task<Void, Never>?

    private init() {}

    public var model: String { VisionText.localModel }

    /// The download's size, as said to you.
    public var sizeText: String {
        model.hasSuffix("8b") ? "6.2 GB" : model.hasSuffix("2b") ? "1.9 GB" : model.hasSuffix("4b") ? "3.3 GB" : "a few GB"
    }

    private var sizeBytes: Int64 {
        model.hasSuffix("8b") ? 6_200_000_000 : model.hasSuffix("2b") ? 1_900_000_000 : 3_300_000_000
    }

    /// Free space for it, with 2 GB to spare. Unknown space counts as enough.
    public var hasRoom: Bool {
        guard let free = Self.freeSpace else { return true }
        return free > sizeBytes + 2_000_000_000
    }

    public static var freeSpace: Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// The first command that needed to see an app offered the download (once ever).
    public static var offered: Bool {
        get { UserDefaults.standard.bool(forKey: "visionOffered") }
        set { UserDefaults.standard.set(newValue, forKey: "visionOffered") }
    }

    public var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// Where things stand (not while a download runs).
    public func refresh() async {
        guard !isDownloading else { return }
        switch await OllamaProbe.check(model: model) {
        case .ready: phase = .ready
        case .missingModel, .notRunning: phase = .missing
        case .notInstalled: phase = .noOllama
        }
    }

    /// Starts the download in the background (opening Ollama if it's closed). Does nothing when it's already in or
    /// downloading.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.download()
            self?.task = nil
        }
    }

    private func download() async {
        if case .ready = await OllamaProbe.check(model: model) { phase = .ready; return }
        guard OllamaProbe.isInstalled else { phase = .noOllama; return }
        guard hasRoom else {
            let free = Self.freeSpace.map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "too little"
            phase = .failed("Not enough disk space: it needs \(sizeText) and \(free) is free.")
            return
        }
        phase = .downloading(0)
        // Ollama serves while its app is open.
        if case .notRunning = await OllamaProbe.check(model: model) {
            await OllamaProbe.start()
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if case .notRunning = await OllamaProbe.check(model: model) { continue }
                break
            }
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/pull")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        do {
            let (lines, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                phase = .failed("Ollama couldn't start the download.")
                return
            }
            // Each layer reports its own bytes: the total is all of them.
            var layers: [String: (done: Double, total: Double)] = [:]
            for try await line in lines.lines {
                guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if let error = json["error"] as? String { phase = .failed(error); return }
                if let digest = json["digest"] as? String, let total = (json["total"] as? NSNumber)?.doubleValue, total > 0 {
                    layers[digest] = ((json["completed"] as? NSNumber)?.doubleValue ?? 0, total)
                    let done = layers.values.reduce(0) { $0 + $1.done }, all = layers.values.reduce(0) { $0 + $1.total }
                    phase = .downloading(min(done / max(all, 1), 0.99))
                }
                if json["status"] as? String == "success" { break }
            }
        } catch {
            phase = .failed("The download stopped: \(error.localizedDescription)")
            return
        }
        if case .ready = await OllamaProbe.check(model: model) {
            phase = .ready
        } else {
            phase = .failed("The download didn't finish. Try again in Settings → Commands & AI.")
        }
    }

    /// Where it stands, in a few words for a pill or a row.
    public var status: String {
        switch phase {
        case .unknown: return "Checking…"
        case .ready: return "Ready · \(model)"
        case .missing: return "Not downloaded"
        case .noOllama: return "Needs Ollama"
        case .downloading(let part): return "Downloading \(Int(part * 100))%"
        case .failed: return "Didn't download"
        }
    }
}
