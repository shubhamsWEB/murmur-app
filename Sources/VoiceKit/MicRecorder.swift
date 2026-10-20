import AudioToolbox
import AVFoundation
import FluidAudio
import MurmurObjC

/// Records the microphone while you dictate and hands back 16 kHz mono samples, the format Parakeet expects.
/// Audio stays in memory and is dropped after transcription: nothing is written to disk.
///
/// Which microphone: the one chosen in Settings, or the system's default, except that AirPods and other Bluetooth
/// headsets are passed over for the Mac's own microphone when you prefer it (their microphone drops them to a
/// phone-call codec, and they're slow to wake). The system's default needs nothing set and records exactly as
/// before. Another microphone gets a fresh engine pointed at it before anything reads its format, the tap uses the
/// format the hardware reports, and if AVFoundation still objects (it raises an Objective-C exception, which would
/// quit the app) the recording falls back to the default microphone.
public final class MicRecorder: @unchecked Sendable {
    private var engine = AVAudioEngine()
    /// The microphone the engine was pointed at (nil: the system default, nothing set).
    private var engineUID: String?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private var running = false
    /// Which input channel to keep, decided on the first buffer with sound: the loudest one when the others are
    /// much quieter (a mic on one channel of a two-channel interface or headset: averaging would halve your voice),
    /// otherwise -1, all of them averaged.
    private var channel: Int?

    /// Called on the audio thread with the loudness of each buffer, 0…1 (for the HUD's meter).
    public var onLevel: ((Float) -> Void)?

    /// Starting the microphone can take a second or more (Bluetooth headsets, right after waking), so it happens
    /// here, off the main thread, and stopping waits for it in order.
    private let queue = DispatchQueue(label: "murmur.microphone", qos: .userInteractive)

    private var settings = (chosenUID: String?.none, preferBuiltIn: true)
    /// The microphone picked in Settings (its Core Audio UID); nil chooses automatically.
    public var chosenUID: String? {
        get { lock.withLock { settings.chosenUID } }
        set { lock.withLock { settings.chosenUID = newValue } }
    }
    /// Automatic choice: the Mac's own microphone rather than a Bluetooth headset's.
    public var preferBuiltIn: Bool {
        get { lock.withLock { settings.preferBuiltIn } }
        set { lock.withLock { settings.preferBuiltIn = newValue } }
    }
    /// The microphone the last recording used.
    public var device: AudioDevices.Input? { lock.withLock { lastDevice } }
    private var lastDevice: AudioDevices.Input?

    public init() {}

    public var isRunning: Bool { queue.sync { running } }

    /// The microphone a recording would use now.
    public func currentChoice() -> AudioDevices.Input? {
        let wanted = lock.withLock { settings }
        let all = AudioDevices.inputs()
        if let uid = wanted.chosenUID, let chosen = all.first(where: { $0.uid == uid }) { return chosen }
        let fallback = AudioDevices.defaultInput()
        if wanted.preferBuiltIn, let fallback, fallback.isBluetooth, !AudioDevices.lidClosed,
           let builtIn = all.first(where: \.isBuiltIn) {
            return builtIn
        }
        return fallback
    }

    /// How a start went, for the log and the pill.
    public struct Start: Sendable {
        /// What went wrong, when the microphone couldn't start.
        public let error: String?
        /// Seconds from the call until audio was coming in.
        public let took: TimeInterval
        public let device: AudioDevices.Input?
        /// The chosen microphone couldn't be used, so the default one was.
        public let fellBack: String?
    }

    /// Starts recording without holding up the caller. `done` runs on the main thread once audio is coming in, or
    /// with the error.
    public func start(_ done: @escaping @MainActor (Start) -> Void) {
        queue.async { [self] in
            let started = Date()
            var failure: String?
            var fellBack: String?
            do { fellBack = try startNow() } catch { failure = error.localizedDescription }
            let result = Start(error: failure, took: Date().timeIntervalSince(started), device: device,
                               fellBack: fellBack)
            Task { @MainActor in done(result) }
        }
    }

    /// Returns why the chosen microphone was given up for the default one, if it was.
    private func startNow() throws -> String? {
        guard !running else { return nil }
        let target = currentChoice()
        let systemDefault = AudioDevices.defaultInput()
        // Only a microphone that isn't the system's default is set on the engine.
        let wanted = target.flatMap { $0.uid == systemDefault?.uid ? nil : $0 }
        if wanted?.uid != engineUID {
            engine = AVAudioEngine()
            engineUID = nil
        }
        if let wanted {
            do {
                if engineUID == nil { try point(at: wanted) }
                try startEngine(hardwareFormat: true)
                lock.withLock { lastDevice = wanted }
                return nil
            } catch {
                // Back to the default microphone on a fresh engine, exactly as Murmur always recorded.
                engine = AVAudioEngine()
                engineUID = nil
                try startEngine(hardwareFormat: false)
                lock.withLock { lastDevice = systemDefault }
                return "\(wanted.name): \(error.localizedDescription)"
            }
        }
        try startEngine(hardwareFormat: false)
        lock.withLock { lastDevice = systemDefault }
        return nil
    }

    /// Points a fresh engine's input at a microphone, before anything reads its format.
    private func point(at device: AudioDevices.Input) throws {
        guard let unit = engine.inputNode.audioUnit else { throw VoiceError.cantUse(device.name) }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw VoiceError.cantUse(device.name) }
        engineUID = device.uid
    }

    /// `hardwareFormat`: tap in the format the microphone itself reports (after pointing the engine at another
    /// microphone, the node's output format can still be the old one's, and a mismatch is what AVFoundation objects
    /// to).
    private func startEngine(hardwareFormat: Bool) throws {
        let input = engine.inputNode
        let format = hardwareFormat ? input.inputFormat(forBus: 0) : input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        sampleRate = format.sampleRate
        channel = format.channelCount > 1 ? nil : -1
        lock.unlock()
        var tapError: NSException?
        tapError = MurmurCatchException {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.append(buffer)
            }
        }
        if let tapError { throw VoiceError.audioEngine(tapError.reason ?? tapError.name.rawValue) }
        var startError: Error?
        let exception = MurmurCatchException { [engine] in
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if exception != nil || startError != nil {
            _ = MurmurCatchException { input.removeTap(onBus: 0) }
            if let startError { throw startError }
            throw VoiceError.audioEngine(exception?.reason ?? "the audio engine didn't start")
        }
        running = true
    }

    /// Stops recording and returns what was heard, resampled to 16 kHz mono.
    public func stop() -> [Float] {
        queue.sync { stopNow() }
    }

    private func stopNow() -> [Float] {
        guard running else { return [] }
        let engine = engine
        _ = MurmurCatchException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
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
        lock.lock()
        var use = channel
        lock.unlock()
        if use == nil {
            var energies = [Float](repeating: 0, count: channels)
            for c in 0..<channels {
                let pointer = data[c]
                for i in 0..<frames { energies[c] += pointer[i] * pointer[i] }
            }
            let loudest = energies.indices.max { energies[$0] < energies[$1] } ?? 0
            let quietest = energies.min() ?? 0
            if energies[loudest] > 1e-7 {
                // 6 dB or more between channels: one carries the voice. Keep it alone.
                use = quietest * 4 < energies[loudest] ? loudest : -1
                lock.lock()
                channel = use
                lock.unlock()
            }
        }
        var mono = [Float](repeating: 0, count: frames)
        if let only = use, only >= 0, only < channels {
            let pointer = data[only]
            for i in 0..<frames { mono[i] = pointer[i] }
        } else {
            for c in 0..<channels {
                let pointer = data[c]
                for i in 0..<frames { mono[i] += pointer[i] }
            }
            if channels > 1 {
                let scale = 1 / Float(channels)
                for i in 0..<frames { mono[i] *= scale }
            }
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
    case cantUse(String)
    case audioEngine(String)

    public var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone is available."
        case .cantUse(let name): return "Can't switch to \(name)."
        case .audioEngine(let reason): return "The microphone couldn't start (\(reason))."
        }
    }
}
