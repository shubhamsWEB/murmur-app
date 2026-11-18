import AudioToolbox
import AVFoundation
import CoreAudio
import MurmurObjC

/// Your side of a meeting: the microphone, heard continuously (not only while a key is held), as one channel at the
/// microphone's own rate. A plain engine of its own, beside dictation's (macOS lets both read the microphone).
final class LiveMicrophone: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var channel: Int?
    private(set) var rate: Double = 48_000
    /// Called on the audio thread with each buffer, as one channel.
    private var onSamples: (([Float]) -> Void)?

    /// Starts on `device` (nil: the system's default). `handler` is given the sample rate and returns what's called
    /// with each buffer.
    func start(_ device: AudioDevices.Input?, handler: (Double) -> ([Float]) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let pointed = device.map { $0.uid != AudioDevices.defaultInput()?.uid } ?? false
        if let device, pointed {
            guard let unit = input.audioUnit else { throw VoiceError.cantUse(device.name) }
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw VoiceError.cantUse(device.name) }
        }
        // The format the microphone itself reports when pointed at one (the node's own can still be the last one's).
        let format = pointed ? input.inputFormat(forBus: 0) : input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        rate = format.sampleRate
        onSamples = handler(format.sampleRate)
        lock.withLock { channel = format.channelCount > 1 ? nil : -1 }
        if let exception = MurmurCatchException({
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in self?.receive(buffer) }
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
            if let startError { throw startError }
            throw VoiceError.audioEngine(exception?.reason ?? "the audio engine didn't start")
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        _ = MurmurCatchException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        let decided = lock.withLock { channel }
        guard let made = MicRecorder.mono(buffer, channel: decided) else { return }
        let (mono, use) = made
        if decided == nil, use != nil { lock.withLock { channel = use } }
        onSamples?(mono)
    }
}

/// The other side of a meeting: the sound the Mac plays (the call), taken with a Core Audio process tap (macOS
/// 14.2 and later) before it reaches the speakers or headphones, as one channel. Everything playing is in it except
/// Murmur's own sound; it doesn't change what you hear.
///
/// macOS asks once for permission ("System Audio Recording Only", under Privacy & Security › Screen & System Audio
/// Recording). Without it the tap gives silence rather than an error, which MeetingMode notices and explains.
@available(macOS 14.2, *)
final class CallAudio: @unchecked Sendable {
    enum Failure: LocalizedError {
        case status(String, OSStatus)
        case format

        var errorDescription: String? {
            switch self {
            case .status(let what, let status): return "Couldn't \(what) (\(status))."
            case .format: return "The call's sound came in a format Murmur can't read."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "murmur.meeting.call", qos: .userInitiated)
    private(set) var rate: Double = 48_000
    private var channels = 1
    private var interleaved = true
    /// Called on the tap's queue with each buffer, as one channel.
    private var onSamples: (([Float]) -> Void)?

    /// `handler` is given the sample rate and returns what's called with each buffer.
    func start(handler: (Double) -> ([Float]) -> Void) throws {
        let own = Self.ownProcess().map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Murmur meeting notes"
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure.status("listen to the call's sound", status) }
        tapID = tap

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &stream)
        guard status == noErr else { stop(); throw Failure.status("read the call's sound format", status) }
        guard stream.mFormatID == kAudioFormatLinearPCM, stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              stream.mBitsPerChannel == 32, stream.mSampleRate > 0 else { stop(); throw Failure.format }
        rate = stream.mSampleRate
        channels = max(1, Int(stream.mChannelsPerFrame))
        interleaved = stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        onSamples = handler(rate)

        // A private device made of the tap (and the output it listens to), which is what can be read.
        guard let output = Self.defaultOutputUID() else { stop(); throw Failure.status("find the Mac's sound output", -1) }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur meeting notes",
            kAudioAggregateDeviceUIDKey: "murmur.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else { stop(); throw Failure.status("set up the call's sound", status) }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }
        guard status == noErr, let proc else { stop(); throw Failure.status("read the call's sound", status) }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { stop(); throw Failure.status("start reading the call's sound", status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                _ = AudioDeviceStop(aggregateID, procID)
                _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let data = first.mData else { return }
        var mono: [Float]
        if interleaved || list.count == 1 {
            let step = interleaved ? channels : 1
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / step
            let samples = data.assumingMemoryBound(to: Float.self)
            mono = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<step { sum += samples[i * step + c] }
                mono[i] = sum / Float(step)
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            mono = [Float](repeating: 0, count: frames)
            for buffer in list {
                guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) { mono[i] += pointer[i] }
            }
            let scale = 1 / Float(list.count)
            for i in 0..<frames { mono[i] *= scale }
        }
        guard !mono.isEmpty else { return }
        onSamples?(mono)
    }

    /// Murmur's own process, so its sounds stay out of the call's.
    private static func ownProcess() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return AudioDevices.string(id, kAudioDevicePropertyDeviceUID)
    }
}

/// Which apps have the microphone on now, to notice a meeting starting (Zoom, Teams, Meet in a browser…) and ending.
/// macOS 14.2 and later, where Core Audio lists the processes using audio.
enum MicUsers {
    /// A meeting app with the microphone on, by its name; nil when none is.
    static func meetingApp() -> String? { meeting()?.name }

    /// A meeting app with the microphone on: its name, and the bundle identifier of its app (a browser's helper
    /// process counts as the browser).
    static func meeting() -> (name: String, bundle: String)? {
        guard #available(macOS 14.2, *) else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        for process in processes() where isRunningInput(process) && pid(process) != own {
            guard let bundle = AudioDevices.string(process, kAudioProcessPropertyBundleID) else { continue }
            for (prefix, name) in known where bundle == prefix || bundle.hasPrefix(prefix + ".") {
                return (name, prefix == "com.apple.WebKit.GPU" ? "com.apple.Safari"
                        : prefix == "com.apple.avconferenced" ? "com.apple.FaceTime" : prefix)
            }
        }
        return nil
    }

    /// The name shown for an app's bundle identifier when it's a meeting app or a browser (a call on the web).
    static func meetingName(_ bundle: String) -> String? {
        for (prefix, name) in known where bundle == prefix || bundle.hasPrefix(prefix + ".") { return name }
        return nil
    }

    private static let known: [(String, String)] = [
        ("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Teams"), ("com.microsoft.teams", "Teams"),
        ("com.apple.FaceTime", "FaceTime"), ("com.apple.avconferenced", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"), ("Cisco-Systems.Spark", "Webex"), ("com.webex.meetingmanager", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"), ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit.GPU", "Safari"),
        ("company.thebrowser.Browser", "Arc"), ("com.microsoft.edgemac", "Edge"), ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave"), ("com.vivaldi.Vivaldi", "Vivaldi"),
    ]

    @available(macOS 14.2, *)
    private static func processes() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    @available(macOS 14.2, *)
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    @available(macOS 14.2, *)
    private static func pid(_ process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
        return value
    }
}
