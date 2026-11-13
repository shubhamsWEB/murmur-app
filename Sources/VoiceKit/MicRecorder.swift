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
///
/// Clear voice (on unless turned off): the microphone goes through macOS's voice processing, as FaceTime's does. It
/// takes out steady background noise and the Mac's own speakers' sound, and evens out the level, before Murmur hears
/// anything. Other sound playing on the Mac is turned down as little as macOS allows. If a microphone can't do it,
/// that recording (and the rest of the session, for that microphone) is made without it, as before.
///
/// Ready between dictations (`readySeconds`, a minute unless turned off): after a dictation the microphone stays on
/// for a while, keeping only the last half second (PreRoll), and the next dictation starts with that half second.
/// The first word, often begun as the key goes down, arrives whole, and the next dictation starts at once instead of
/// waiting up to a second for the microphone. macOS shows the microphone in use for that minute; nothing is kept
/// beyond the half second, and nothing is written anywhere. Not with Clear voice: voice processing left running
/// would keep turning other sound on the Mac down.
public final class MicRecorder: @unchecked Sendable {
    private var engine = AVAudioEngine()
    /// The microphone the engine was pointed at (nil: the system default, nothing set).
    private var engineUID: String?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    /// The engine is on (recording, or ready for the next dictation).
    private var running = false
    /// Collecting a dictation; while ready but not recording, only the last half second is kept.
    private var recording = false
    private var preRoll = PreRoll(capacity: 0)
    /// How much from before the key the last recording started with, in samples at `sampleRate`.
    private var preRolled = 0
    /// What the ready microphone was started with: a change (another microphone, Clear voice) starts it afresh.
    private var readyWith: (uid: String?, clearVoice: Bool)?
    /// Turns the ready microphone off when no dictation came.
    private var cooling: DispatchWorkItem?
    /// How much of the moment before the key is kept.
    static let preRollSeconds = 0.5
    /// Which input channel to keep, decided on the first buffer with sound: the loudest one when the others are
    /// much quieter (a mic on one channel of a two-channel interface or headset: averaging would halve your voice),
    /// otherwise -1, all of them averaged.
    private var channel: Int?

    /// Called on the audio thread with the loudness of each buffer, 0…1 (for the HUD's meter).
    public var onLevel: ((Float) -> Void)?

    /// Starting the microphone can take a second or more (Bluetooth headsets, right after waking), so it happens
    /// here, off the main thread, and stopping waits for it in order.
    private let queue = DispatchQueue(label: "murmur.microphone", qos: .userInteractive)

    private var settings = (chosenUID: String?.none, preferBuiltIn: true, clearVoice: false, readySeconds: 60.0)
    /// Microphones voice processing didn't work with this session (their UID, or "default").
    private var clearVoiceFailed: Set<String> = []
    /// Whether the last recording went through voice processing.
    public var cleaned: Bool { lock.withLock { lastCleaned } }
    private var lastCleaned = false
    /// macOS's voice processing on the microphone (noise, echo and level), when it works.
    public var clearVoice: Bool {
        get { lock.withLock { settings.clearVoice } }
        set { lock.withLock { settings.clearVoice = newValue } }
    }
    /// How long the microphone stays ready after a dictation, in seconds (0: off as soon as the dictation ends).
    public var readySeconds: TimeInterval {
        get { lock.withLock { settings.readySeconds } }
        set {
            lock.withLock { settings.readySeconds = max(0, newValue) }
            if newValue <= 0 { turnOff() }
        }
    }

    /// Turns a ready microphone off now (not one that's recording).
    public func turnOff() {
        queue.async { [self] in
            guard !lock.withLock({ recording }) else { return }
            shutDown()
        }
    }

    /// Seconds of sound from before the key at the start of the last recording.
    public var lastPreRollSeconds: Double {
        lock.withLock { sampleRate > 0 ? Double(preRolled) / sampleRate : 0 }
    }

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
        /// The sound went through macOS's voice processing (Clear voice).
        public var cleaned = false
        /// Why Clear voice couldn't be used with this microphone, the first time it couldn't.
        public var clearVoiceProblem: String?
        /// Why the first try failed, when a second one (on a new engine) worked.
        public var retried: String?
        /// The microphone's input level in System Settings › Sound, 0…1, when it has one.
        public var inputVolume: Float?
        /// It was already on (ready from the last dictation), and the recording starts with the moment before the key.
        public var wasReady = false
        public var preRollSeconds = 0.0
    }

    /// Starts recording without holding up the caller. `done` runs on the main thread once audio is coming in, or
    /// with the error.
    public func start(_ done: @escaping @MainActor (Start) -> Void) {
        queue.async { [self] in
            let started = Date()
            var failure: String?
            var fellBack: String?
            clearVoiceProblem = nil
            retriedStart = nil
            do { fellBack = try startNow() } catch { failure = error.localizedDescription }
            var result = Start(error: failure, took: Date().timeIntervalSince(started), device: device,
                               fellBack: fellBack)
            result.wasReady = startedReady
            result.preRollSeconds = failure == nil ? lastPreRollSeconds : 0
            result.cleaned = cleaned
            result.clearVoiceProblem = clearVoiceProblem
            result.retried = retriedStart
            result.inputVolume = device.flatMap { AudioDevices.inputVolume($0.id) }
            Task { @MainActor in done(result) }
        }
    }

    /// Whether the last start found the microphone ready (set on `queue`).
    private var startedReady = false

    /// Returns why the chosen microphone was given up for the default one, if it was.
    private func startNow() throws -> String? {
        startedReady = false
        guard !lock.withLock({ recording }) else { return nil }
        cooling?.cancel()
        cooling = nil
        if running {
            // Ready from the last dictation: the same microphone, set up the same way, still going → record now,
            // starting with the half second before the key.
            let wanted = lock.withLock { settings }
            if engine.isRunning, let readyWith, readyWith.clearVoice == wanted.clearVoice,
               readyWith.uid == currentChoice()?.uid {
                lock.withLock {
                    samples = preRoll.contents()
                    preRolled = samples.count
                    preRoll.clear()
                    recording = true
                }
                startedReady = true
                return nil
            }
            shutDown()
        }
        lock.withLock {
            recording = true
            preRolled = 0
        }
        do {
            let fellBack = try startFresh()
            lock.withLock {
                preRoll.resize(Int(sampleRate * Self.preRollSeconds))
                readyWith = (lastDevice?.uid, settings.clearVoice)
            }
            return fellBack
        } catch {
            lock.withLock { recording = false }
            throw error
        }
    }

    /// Starts the engine from off.
    private func startFresh() throws -> String? {
        let target = currentChoice()
        let systemDefault = AudioDevices.defaultInput()
        // Only a microphone that isn't the system's default is set on the engine.
        let wanted = target.flatMap { $0.uid == systemDefault?.uid ? nil : $0 }
        // A fresh engine every time the microphone starts from off. One kept from before remembers the format of the
        // microphone it last used, and the default microphone changes under it: on 13 Nov, after EarPods (44.1 kHz)
        // the night before, the built-in microphone (48 kHz) failed every time ("Failed to create tap due to format
        // mismatch") until Murmur restarted. A new engine costs a few milliseconds.
        engine = AVAudioEngine()
        engineUID = nil
        if let wanted {
            do {
                if engineUID == nil { try point(at: wanted) }
                try begin(hardwareFormat: true, key: wanted.uid, device: wanted)
                lock.withLock { lastDevice = wanted }
                return nil
            } catch {
                // Back to the default microphone on a fresh engine, exactly as Murmur always recorded.
                engine = AVAudioEngine()
                engineUID = nil
                try begin(hardwareFormat: false, key: "default", device: nil)
                lock.withLock { lastDevice = systemDefault }
                return "\(wanted.name): \(error.localizedDescription)"
            }
        }
        do {
            try begin(hardwareFormat: false, key: "default", device: nil)
        } catch {
            // Once more, on a new engine in the format the microphone itself reports (it may have changed as this one
            // started): the error is only for a microphone that really won't start.
            engine = AVAudioEngine()
            engineUID = nil
            try begin(hardwareFormat: true, key: "default", device: nil)
            retriedStart = error.localizedDescription
        }
        lock.withLock { lastDevice = systemDefault }
        return nil
    }

    /// Why the first try to start failed, when a second one worked (for the log), set by `startFresh`.
    private var retriedStart: String?

    /// Why Clear voice didn't work this time (for the log), set by `begin`.
    private var clearVoiceProblem: String?

    /// Starts the engine with Clear voice when it's on and this microphone can do it; otherwise, or if it fails, on a
    /// fresh engine without it.
    private func begin(hardwareFormat: Bool, key: String, device: AudioDevices.Input?) throws {
        let wanted = lock.withLock { settings.clearVoice && !clearVoiceFailed.contains(key) }
        if wanted {
            do {
                try startEngine(hardwareFormat: hardwareFormat, voiceProcessing: true)
                // Voice processing can move to the system's microphone: only kept when it's still the one chosen.
                if let device, currentDevice() != device.id {
                    _ = MurmurCatchException { [engine] in
                        engine.inputNode.removeTap(onBus: 0)
                        engine.stop()
                    }
                    running = false
                    throw VoiceError.cantUse("\(device.name) with voice processing")
                }
                lock.withLock { lastCleaned = true }
                return
            } catch {
                lock.withLock { _ = clearVoiceFailed.insert(key) }
                clearVoiceProblem = error.localizedDescription
                engine = AVAudioEngine()
                engineUID = nil
                if let device { try point(at: device) }
            }
        } else if engine.inputNode.isVoiceProcessingEnabled {
            // Turned off since the engine was made: a fresh one, without it.
            engine = AVAudioEngine()
            engineUID = nil
            if let device { try point(at: device) }
        }
        try startEngine(hardwareFormat: hardwareFormat, voiceProcessing: false)
        lock.withLock { lastCleaned = false }
    }

    /// The microphone the engine's input is using now.
    private func currentDevice() -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr ? id : nil
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
    private func startEngine(hardwareFormat: Bool, voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if voiceProcessing, !input.isVoiceProcessingEnabled {
            var failure: Error?
            let exception = MurmurCatchException {
                do { try input.setVoiceProcessingEnabled(true) } catch { failure = error }
            }
            if let failure { throw failure }
            if let exception { throw VoiceError.audioEngine(exception.reason ?? "voice processing") }
            input.isVoiceProcessingAGCEnabled = true
            // Music and calls playing on the Mac are turned down as little as macOS allows while you speak.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        // With voice processing the format is the processed one (the hardware's own would mismatch).
        let format = hardwareFormat && !voiceProcessing ? input.inputFormat(forBus: 0) : input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        sampleRate = format.sampleRate
        // Voice processing's voice is its first channel (it can report more, which are empty or unprocessed).
        channel = voiceProcessing ? 0 : format.channelCount > 1 ? nil : -1
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
        guard running, lock.withLock({ recording }) else { return [] }
        lock.lock()
        let raw = samples
        let rate = sampleRate
        samples = []
        recording = false
        preRoll.clear()
        let ready = settings.readySeconds
        let cleaned = lastCleaned
        lock.unlock()
        // Ready for the next dictation for a while, or off now. Not with voice processing (it keeps turning other
        // sound on the Mac down while it runs).
        if ready > 0, !cleaned, engine.isRunning {
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.lock.withLock({ self.recording }) else { return }
                self.shutDown()
            }
            cooling = item
            queue.asyncAfter(deadline: .now() + ready, execute: item)
        } else {
            shutDown()
        }
        guard !raw.isEmpty else { return [] }
        if rate == 16_000 { return raw }
        return (try? AudioConverter().resample(raw, from: rate)) ?? []
    }

    /// Stops and throws the audio away (a cancelled dictation).
    public func cancel() {
        _ = stop()
    }

    /// The engine off, and nothing kept (on `queue`).
    private func shutDown() {
        cooling?.cancel()
        cooling = nil
        guard running else { return }
        let engine = engine
        _ = MurmurCatchException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        running = false
        lock.withLock {
            recording = false
            samples = []
            preRoll.clear()
            readyWith = nil
        }
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
        lock.lock()
        let collecting = recording
        // Ready between dictations: only the last half second is kept.
        if collecting { samples.append(contentsOf: mono) } else { preRoll.append(mono) }
        lock.unlock()
        guard collecting else { return }
        var sum: Float = 0
        for value in mono { sum += value * value }
        let rms = (sum / Float(frames)).squareRoot()
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
