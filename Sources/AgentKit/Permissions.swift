import AppKit
import EventKit

/// macOS asks for a permission in a window that belongs to Murmur. Murmur lives in the menu bar, so the question
/// opened behind the app you were in and was easy to miss. Now, just before macOS asks, Murmur comes to the front
/// (so the question is on top of everything), then hands the front back to the app you were in.
@MainActor
public enum Permissions {
    /// Runs `ask` with Murmur in front, then puts the app you were in back in front.
    public static func inFront<T>(_ ask: () async -> T) async -> T {
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        let result = await ask()
        if let previous, previous != NSRunningApplication.current { previous.activate(options: []) }
        return result
    }

    /// Before Murmur first works an app through Apple Events, macOS asks "Murmur wants to control …". When that
    /// question is still to come, ask it now, in front. An app that isn't running is started hidden first (the
    /// question can only be asked about a running app). Nothing happens once it's been answered.
    public static func automation(_ bundleID: String) async {
        let first = status(bundleID, ask: false)
        if first == -600 {   // procNotFound: not running
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard status(bundleID, ask: false) == -1744 else { return }
        } else if first != -1744 {   // errAEEventWouldRequireUserConsent: not asked yet
            return
        }
        _ = await inFront {
            await Task.detached { Permissions.status(bundleID, ask: true) }.value
        }
    }

    /// The apps a script talks to ("tell application \"Notes\"", "Application('com.apple.Music')"), asked about first.
    public static func automation(forScript source: String) async {
        var ids: [String] = []
        let patterns = [#"application id "([^"]+)""#, #"application "([^"]+)""#, #"Application\(['"]([^'"]+)['"]\)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let found = Range(match.range(at: 1), in: source) else { continue }
                let name = String(source[found])
                if name.contains("."), !name.contains(" ") { ids.append(name); continue }
                if let id = AppCatalog.shared.resolve(name)?.bundleID { ids.append(id) }
            }
        }
        for id in Set(ids) { await automation(id) }
    }

    /// Calendars or reminders: access, asked for in front when it hasn't been asked yet.
    static func events(_ type: EKEntityType, store: EKEventStore) async -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return true
        case .notDetermined:
            return await inFront {
                (try? await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())) ?? false
            }
        default: return false
        }
    }

    nonisolated static func status(_ bundleID: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let pointer = target.aeDesc else { return -600 }
        return AEDeterminePermissionToAutomateTarget(pointer, typeWildCard, typeWildCard, ask)
    }
}
