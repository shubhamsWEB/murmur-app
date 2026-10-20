import AppKit
import AgentKit
import ApplicationServices

/// The text around the cursor in the focused app, through Accessibility: a few characters before it and after it, so
/// dictation can be fitted to the sentence it lands in. Apps that don't say (many web pages, Electron apps,
/// terminals) give nothing, and the text goes in as heard.
@MainActor
enum CursorContext {
    /// Terminals and the like: what's before the cursor is a prompt, not a sentence.
    private static let skipped: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
    ]

    /// Up to three characters before the cursor (or the selection) and two after it. Nil when the app doesn't say.
    static func around() -> (before: String, after: String)? {
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, skipped.contains(id) { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }

        var countValue: CFTypeRef?
        let total = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success
            ? (countValue as? Int) : nil

        let start = selection.location
        let end = selection.location + max(0, selection.length)
        let beforeStart = max(0, start - 3)
        let before = start > 0 ? string(element, CFRange(location: beforeStart, length: start - beforeStart)) : ""
        let afterLength = total.map { min(2, max(0, $0 - end)) } ?? 2
        let after = afterLength > 0 ? string(element, CFRange(location: end, length: afterLength)) : ""
        // The app answered the range but not the text: fall back to the whole value when it's small.
        if (before == nil && start > 0) || (after == nil && afterLength > 0) {
            return fromValue(element, start: start, end: end)
        }
        return (before ?? "", after ?? "")
    }

    /// Dictated text fitted to where it's going, or as heard when the app doesn't say what's around the cursor.
    static func fit(_ text: String) -> String {
        guard let around = around() else { return text }
        return TextFit.fit(text, before: around.before, after: around.after, isWord: isWord)
    }

    /// Whether a lowercase word is in the Mac's dictionary as it is (names and places aren't in lowercase).
    static func isWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    private static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &result) == .success else { return nil }
        return result as? String
    }

    private static func fromValue(_ element: AXUIElement, start: Int, end: Int) -> (before: String, after: String)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let utf16 = text as NSString
        guard utf16.length < 500_000, end <= utf16.length else { return nil }
        let beforeStart = max(0, start - 3)
        let before = utf16.substring(with: NSRange(location: beforeStart, length: start - beforeStart))
        let after = utf16.substring(with: NSRange(location: end, length: min(2, utf16.length - end)))
        return (before, after)
    }
}
