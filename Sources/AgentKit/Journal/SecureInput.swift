#if canImport(AppKit)
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Whether a password is being typed where the keyboard is.
///
/// macOS's Secure Input flag (`IsSecureEventInputEnabled`) is one switch for the whole Mac: it's on while *any* app
/// holds it, not only while a password field has the focus. Password managers hold it, Terminal holds it with Secure
/// Keyboard Entry on, and a browser can leave it on after its password field has gone (or for a password field in a
/// tab in the background). Taken as "a password field has the focus", it made every text box look like one: dictation
/// refused to type anywhere, and screen memory stopped reading. So the focused element is asked first; the flag only
/// decides when the focused element can't be read and the front app is the one holding it.
public enum SecureInput {
    /// The app holding Secure Input now, if it's on and macOS says which.
    public static func holder() -> NSRunningApplication? {
        guard IsSecureEventInputEnabled(),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// The holder's name, for the log and the message ("1Password", "Terminal").
    public static func holderName() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        guard let app = holder() else { return "an app" }
        return app.localizedName ?? app.bundleIdentifier ?? "an app"
    }

    /// The front app's focused element is a password field, or (when that can't be read) the front app holds Secure
    /// Input. False when Secure Input is held by some other app, or left on by the front app while a normal text box
    /// has the focus.
    public static func passwordFocused() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return IsSecureEventInputEnabled() }
        switch focusedIsSecure(in: front.processIdentifier) {
        case .some(let secure):
            return secure
        case .none:
            // The focus couldn't be read: believe the flag only when the front app is the one holding it.
            guard IsSecureEventInputEnabled() else { return false }
            guard let holder = holder() else { return true }
            return holder.processIdentifier == front.processIdentifier
        }
    }

    /// Whether the app's focused element is a password field; nil when the app doesn't say what has the focus.
    private static func focusedIsSecure(in pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let focused = value as! AXUIElement
        func string(_ name: String) -> String {
            var result: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(focused, name as CFString, &result)
            return result as? String ?? ""
        }
        return string(kAXSubroleAttribute) == "AXSecureTextField" || string(kAXRoleAttribute) == "AXSecureTextField"
    }
}
#endif
