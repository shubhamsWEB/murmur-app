import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text into whatever app has the keyboard focus: the text goes on the clipboard, Murmur presses ⌘V, and the
/// clipboard you had is put back a moment later. This works in nearly every app, including browsers and Electron apps.
public enum TextInserter {
    public enum Outcome {
        case inserted
        /// A password field (or another app holding Secure Input) has the focus: macOS blocks synthetic keystrokes.
        case secureInput
        /// Murmur doesn't have Accessibility permission, which posting ⌘V needs.
        case needsAccessibility
    }

    /// Marks our clipboard write as temporary, so clipboard managers that honour nspasteboard.org skip it.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @MainActor
    public static func insert(_ text: String) -> Outcome {
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        if IsSecureEventInputEnabled() { return .secureInput }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: transientType)
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount

        pressCommandV()

        // Give the target app time to read the clipboard, then restore yours (unless something else wrote since).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard pasteboard.changeCount == ours else { return }
            restore(saved, to: pasteboard)
        }
        return .inserted
    }

    /// Copies text to the clipboard without pasting (for "Copy Last Dictation").
    @MainActor
    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The selected text in the front app, by pressing ⌘C (for apps that don't tell Accessibility what's selected:
    /// Chrome, Electron apps). Your clipboard is put back right after. Nil when nothing was copied.
    @MainActor
    public static func copySelection() async -> String? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        press(CGKeyCode(kVK_ANSI_C))
        for _ in 0..<12 where pasteboard.changeCount == before {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        restore(saved, to: pasteboard)
        return text?.isEmpty == false ? text : nil
    }

    private static func pressCommandV() {
        press(CGKeyCode(kVK_ANSI_V))
    }

    private static func press(_ v: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
