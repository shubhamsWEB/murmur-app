import AppKit

/// Murmur's windows kept out of screen sharing and screen recordings (on unless turned off): the dictation pill,
/// answers, confirmations, the Murmur button, Settings, every window Murmur opens. What you dictate, and what
/// Murmur answers, stays on your screen and not on the call.
///
/// It's macOS's own setting for a window (`NSWindow.sharingType = .none`, what Electron's content protection sets),
/// so the window server leaves the window out of what other apps capture. macOS has no promise behind it: Apple says
/// there's no public way to prevent screen capture, and from macOS 15 apps that capture with ScreenCaptureKit can
/// still see such windows. Apps on the older capture path (and macOS 14 and earlier) leave them out.
///
/// Set on each panel as it's made (a window should be left out before it first shows), and, for every other window
/// (Settings, sheets, alerts), checked after each event and once a second: AppKit can put a window's sharing type
/// back after some window operations, so setting it once isn't enough.
@MainActor
public enum PrivateWindows {
    static let key = "privacy.hideFromScreenSharing"
    private static var cached: Bool?

    public static var isOn: Bool {
        get {
            if let cached { return cached }
            let on = UserDefaults.standard.object(forKey: key) as? Bool ?? true
            cached = on
            return on
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            cached = newValue
            applyToAll()
        }
    }

    /// Windows left out of sharing whatever the setting (meeting notes): what's on them is about the people on the
    /// call.
    private static var alwaysPrivate: Set<ObjectIdentifier> = []

    static func keepPrivate(_ window: NSWindow) {
        alwaysPrivate.insert(ObjectIdentifier(window))
        apply(window)
    }

    /// One window, as chosen.
    public static func apply(_ window: NSWindow) {
        let wanted: NSWindow.SharingType = isOn || alwaysPrivate.contains(ObjectIdentifier(window)) ? .none : .readOnly
        if window.sharingType != wanted { window.sharingType = wanted }
    }

    public static func applyToAll() {
        for window in NSApp.windows { apply(window) }
    }

    private static var watching: NSObjectProtocol?
    private static var watchdog: Timer?

    /// Keeps every window Murmur has, and every one it opens later, as chosen.
    public static func watch() {
        guard watching == nil else { return }
        applyToAll()
        watching = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { applyToAll() }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { applyToAll() }
        }
    }
}
