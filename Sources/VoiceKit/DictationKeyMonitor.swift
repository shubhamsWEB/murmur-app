import AppKit
import Carbon.HIToolbox

/// Watches the dictation key (Fn/🌐, or Right ⌥ on keyboards without Fn) with an event tap, so Murmur sees the key go
/// down and up anywhere in macOS. Events are passed on unchanged: other apps still get every key.
/// Needs Accessibility permission; `start()` returns false until it's granted.
public final class DictationKeyMonitor {
    public enum Key: String, CaseIterable {
        case fn
        case rightOption
        case rightCommand

        public var display: String {
            switch self {
            case .fn: return "Fn (🌐)"
            case .rightOption: return "Right ⌥"
            case .rightCommand: return "Right ⌘"
            }
        }

        /// In a sentence: "hold fn", "hold Right ⌥".
        public var short: String {
            switch self {
            case .fn: return "fn"
            case .rightOption: return "Right ⌥"
            case .rightCommand: return "Right ⌘"
            }
        }

        /// On a key cap: "fn", "⌥", "⌘".
        public var cap: String {
            switch self {
            case .fn: return "fn"
            case .rightOption: return "⌥"
            case .rightCommand: return "⌘"
            }
        }

        /// The modifier the key itself sets, which can't also choose typing or a command.
        public var ownModifier: Modifier? {
            switch self {
            case .fn: return nil
            case .rightOption: return .option
            case .rightCommand: return .command
            }
        }
    }

    /// A key held with the talk key to decide what it's for: typing only, or a command.
    public enum Modifier: String, CaseIterable {
        case shift, control, option, command

        public var symbol: String {
            switch self {
            case .shift: return "⇧"
            case .control: return "⌃"
            case .option: return "⌥"
            case .command: return "⌘"
            }
        }

        public var name: String {
            switch self {
            case .shift: return "Shift"
            case .control: return "Control"
            case .option: return "Option"
            case .command: return "Command"
            }
        }

        public var eventFlag: CGEventFlags {
            switch self {
            case .shift: return .maskShift
            case .control: return .maskControl
            case .option: return .maskAlternate
            case .command: return .maskCommand
            }
        }

        public var appKitFlag: NSEvent.ModifierFlags {
            switch self {
            case .shift: return .shift
            case .control: return .control
            case .option: return .option
            case .command: return .command
            }
        }
    }

    public var key: Key
    public var onDown: (() -> Void)?
    public var onUp: (() -> Void)?
    /// Another key was pressed: `keyCode` is its virtual key code. Used to cancel when Fn is part of a shortcut
    /// (Fn+Delete, Fn+F5…) and for Esc during hands-free dictation.
    public var onOtherKey: ((Int64) -> Void)?
    /// Modifier keys changed (other than the dictation key itself): used to spot ⌃ for command mode.
    public var onModifiers: ((CGEventFlags) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    public init(key: Key) {
        self.key = key
    }

    public var isRunning: Bool { tap != nil }

    /// Starts watching. Returns false when macOS refuses the tap (no Accessibility permission yet).
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // A listen-only tap only sees keys meant for Murmur unless the app also has Input Monitoring. A default
            // tap is covered by Accessibility (which pasting needs anyway) and sees keys in every app. It passes
            // every event on unchanged.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<DictationKeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            onOtherKey?(event.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let pressed: Bool
            switch key {
            case .fn:
                guard code == kVK_Function else { onModifiers?(event.flags); return }
                pressed = event.flags.contains(.maskSecondaryFn)
            case .rightOption:
                guard code == kVK_RightOption else { onModifiers?(event.flags); return }
                pressed = event.flags.contains(.maskAlternate)
            case .rightCommand:
                guard code == kVK_RightCommand else { onModifiers?(event.flags); return }
                pressed = event.flags.contains(.maskCommand)
            }
            if pressed, !isDown {
                isDown = true
                onDown?()
            } else if !pressed, isDown {
                isDown = false
                onUp?()
            }
        default:
            break
        }
    }
}
