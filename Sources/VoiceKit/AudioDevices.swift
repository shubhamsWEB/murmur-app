import CoreAudio
import Foundation
import IOKit

/// The Mac's microphones, through Core Audio: which there are and what kind each is, so dictation can listen with
/// the right one.
public enum AudioDevices {
    /// A microphone (any device with input channels).
    public struct Input: Identifiable, Hashable, Sendable {
        public let id: AudioDeviceID
        /// Stays the same across restarts and reconnects: what's saved in settings.
        public let uid: String
        public let name: String
        public let transport: UInt32

        public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
        /// AirPods and other Bluetooth headsets. While their microphone is on they switch to a phone-call codec
        /// (8–16 kHz), which is worse for recognition, and they take a moment to wake.
        public var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        public var kind: String {
            if isBuiltIn { return "built-in" }
            if isBluetooth { return "Bluetooth" }
            switch transport {
            case kAudioDeviceTransportTypeUSB: return "USB"
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeAutoAggregate: return "virtual"
            default: return "external"
            }
        }
    }

    /// Every microphone, in the order Core Audio lists them.
    public static func inputs() -> [Input] {
        deviceIDs().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Input(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "Microphone",
                         transport: transport(id))
        }
    }

    /// A microphone's input level in System Settings › Sound, 0…1; nil for one without a level of its own.
    public static func inputVolume(_ id: AudioDeviceID) -> Float? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioDevicePropertyScopeInput, mElement: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume) == noErr { return volume }
        }
        return nil
    }

    /// Sets a microphone's input level (System Settings › Sound › Input level), 0…1: on its main control, or on each
    /// channel when it only has those. Whether it could.
    @discardableResult
    public static func setInputVolume(_ id: AudioDeviceID, _ volume: Float) -> Bool {
        var value = Float32(min(1, max(0, volume)))
        var set = false
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioDevicePropertyScopeInput, mElement: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { continue }
            if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                set = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return set
    }

    /// The system's default microphone (System Settings › Sound › Input).
    public static func defaultInput() -> Input? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return inputs().first { $0.id == id }
    }

    public static func input(uid: String) -> Input? {
        inputs().first { $0.uid == uid }
    }

    /// Whether a laptop's lid is closed (its built-in microphone hears nothing then). False on desktops.
    public static var lidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    // MARK: - Core Audio

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
