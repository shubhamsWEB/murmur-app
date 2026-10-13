import AVFoundation
import FluidAudio

/// Records the default microphone while you dictate and hands back 16 kHz mono samples, the format Parakeet expects.
/// Audio stays in memory and is dropped after transcription: nothing is written to disk.
public final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private var running = false

    /// Called on the audio thread with the loudness of each buffer, 0…1 (for the HUD's meter).
    public var onLevel: ((Float) -> Void)?

    public init() {}

    public var isRunning: Bool { running }

    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        sampleRate = format.sampleRate
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    /// Stops recording and returns what was heard, resampled to 16 kHz mono.
    public func stop() -> [Float] {
        guard running else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        lock.lock()
        let raw = samples
        let rate = sampleRate
        samples = []
        lock.unlock()
        guard !raw.isEmpty else { return [] }
        if rate == 16_000 { return raw }
        return (try? AudioConverter().resample(raw, from: rate)) ?? []
    }

    /// Stops and throws the audio away (a cancelled dictation).
    public func cancel() {
        _ = stop()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let pointer = data[channel]
            for i in 0..<frames { mono[i] += pointer[i] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for i in 0..<frames { mono[i] *= scale }
        }
        var sum: Float = 0
        for value in mono { sum += value * value }
        let rms = (sum / Float(frames)).squareRoot()
        lock.lock()
        samples.append(contentsOf: mono)
        lock.unlock()
        // Log scale from −60 dBFS (silence) to −10 dBFS (loud), so a whisper still moves the meter.
        let db = 20 * log10(max(rms, 1e-6))
        onLevel?(min(1, max(0, (db + 60) / 50)))
    }
}

public enum VoiceError: LocalizedError {
    case noMicrophone

    public var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone is available."
        }
    }
}
