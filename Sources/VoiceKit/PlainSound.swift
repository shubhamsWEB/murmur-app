import AudioToolbox
import AVFoundation
import FluidAudio
import MurmurObjC

/// The microphone's own sound, recorded beside Clear voice's.
///
/// Clear voice (macOS's voice processing) is built for calls: its noise removal takes a soft or whispered voice for
/// background noise and cuts it. On 17 Nov a quiet dictation came through it at −42 dBFS with everything between the
/// words cut to silence (−120 dBFS), and the speech model found no words in it. With this second, plain recording of
/// the same microphone (a second engine, without voice processing, which macOS allows), Murmur can use the sound the
/// microphone itself heard when Clear voice made a voice too faint, or when nothing was heard in Clear voice's.
///
/// Started after Clear voice's engine (turning voice processing on can change the microphone's format under an engine
/// that's already running), kept ready between dictations with it, and stopped with it. If it can't start, the
/// dictation goes on with Clear voice's sound alone, as before.
final class PlainSound: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var preRoll = PreRoll(capacity: 0)
    private var recording = false
    private var rate: Double = 48_000
    private var channel: Int?
    /// The microphone it was started on (nil: the system's default).
    private(set) var uid: String?

    var isRunning: Bool { engine?.isRunning ?? false }

    /// Starts recording `device` (nil: the system's default, nothing set) from now.
    func start(_ device: AudioDevices.Input?) throws {
        shutDown()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device {
            guard let unit = input.audioUnit else { throw VoiceError.cantUse(device.name) }
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw VoiceError.cantUse(device.name) }
        }
        // The format the microphone itself reports (the node's own can still be the last microphone's).
        let format = device == nil ? input.outputFormat(forBus: 0) : input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            rate = format.sampleRate
            channel = format.channelCount > 1 ? nil : -1
            preRoll.resize(Int(format.sampleRate * MicRecorder.preRollSeconds))
            recording = true
        }
        if let exception = MurmurCatchException({
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in self?.append(buffer) }
        }) {
            throw VoiceError.audioEngine(exception.reason ?? exception.name.rawValue)
        }
        var startError: Error?
        let exception = MurmurCatchException {
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if exception != nil || startError != nil {
            _ = MurmurCatchException { input.removeTap(onBus: 0) }
            lock.withLock { recording = false }
            if let startError { throw startError }
            throw VoiceError.audioEngine(exception?.reason ?? "the audio engine didn't start")
        }
        self.engine = engine
        uid = device?.uid
    }

    /// Ready from the last dictation: records from now, starting with the moment before the key.
    func resume() {
        lock.withLock {
            samples = preRoll.contents()
            preRoll.clear()
            recording = true
        }
    }

    /// What it heard since the start, at 16 kHz; it stays ready (keeping only the last half second) until shut down.
    func stop() -> [Float] {
        let (raw, rate) = lock.withLock { () -> ([Float], Double) in
            let raw = samples
            samples = []
            recording = false
            preRoll.clear()
            return (raw, self.rate)
        }
        guard !raw.isEmpty else { return [] }
        if rate == 16_000 { return raw }
        return (try? AudioConverter().resample(raw, from: rate)) ?? []
    }

    func shutDown() {
        if let engine {
            _ = MurmurCatchException {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        engine = nil
        uid = nil
        lock.withLock {
            recording = false
            samples = []
            preRoll.clear()
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let decided = lock.withLock { channel }
        guard let made = MicRecorder.mono(buffer, channel: decided) else { return }
        let (mono, use) = made
        lock.withLock {
            if decided == nil { channel = use }
            if recording { samples.append(contentsOf: mono) } else { preRoll.append(mono) }
        }
    }
}
