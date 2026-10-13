import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Murmur's eyes and hands in other apps, through Accessibility: what's in the front window (buttons, links, fields,
/// numbered), clicking one, typing, pressing keys. This is what lets a command go step by step through any app or
/// website ("open YouTube, search lofi and play the first video") instead of only the actions Murmur knows.
@MainActor
public enum ScreenControl {
    /// The elements of the last read, by number (1-based in what the model sees).
    private static var elements: [AXUIElement] = []

    private static let roles: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "text field", "AXTextArea": "text area",
        "AXComboBox": "combo box", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXMenuItem": "menu item",
        "AXMenuButton": "menu button", "AXPopUpButton": "pop-up", "AXTab": "tab", "AXHeading": "heading",
        "AXSlider": "slider", "AXDisclosureTriangle": "disclosure", "AXRow": "row", "AXCell": "cell",
    ]

    // MARK: Reading

    /// The front window as a numbered list: `[7] link "Lofi Girl – beats to relax"`. Fresh numbers every read.
    public static func read(limit: Int = 140) async -> String {
        guard AXIsProcessTrusted() else { return "Murmur needs Accessibility permission to see the screen." }
        guard let app = NSWorkspace.shared.frontmostApplication else { return "No app is in front." }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Chrome and Electron apps build their page's accessibility tree only when an assistant asks for it.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let window = element(root, kAXFocusedWindowAttribute) ?? element(root, kAXMainWindowAttribute) else {
            return "\(app.localizedName ?? "The front app") has no window open."
        }
        elements = []
        var lines = ["App: \(app.localizedName ?? "?") · Window: \(string(window, kAXTitleAttribute) ?? "untitled")"]
        if let focused = element(root, kAXFocusedUIElementAttribute) {
            lines.append("Keyboard focus: \(describe(focused) ?? "somewhere")")
        }
        var queue: [AXUIElement] = [window]
        var index = 0
        var seen = Set<String>()
        while index < queue.count, index < 6000, elements.count < limit {
            let current = queue[index]
            index += 1
            let role = string(current, kAXRoleAttribute) ?? ""
            let subrole = string(current, kAXSubroleAttribute) ?? ""
            let kind: String? = subrole == "AXSearchField" ? "search field" : roles[role]
            if let kind, isOnScreen(current) {
                let label = self.label(current, role: role)
                let editable = role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
                if label != nil || editable {
                    let text = label.map { " \"\($0)\"" } ?? ""
                    let key = kind + text
                    // Pages repeat the same link many times (thumbnail + title): list it once.
                    if editable || !seen.contains(key) {
                        seen.insert(key)
                        elements.append(current)
                        lines.append("[\(elements.count)] \(kind)\(text)")
                    }
                }
                // A link's or button's children are its label, not more things to press.
                if role == "AXLink" || role == "AXButton" { continue }
            }
            queue.append(contentsOf: children(current))
        }
        if elements.isEmpty { lines.append("(Nothing to press or type into is visible.)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Acting

    /// What element `id` is, for asking before a risky click.
    public static func name(of id: Int) -> String? {
        guard id >= 1, id <= elements.count else { return nil }
        return describe(elements[id - 1])
    }

    public static func click(_ id: Int) async -> String {
        guard id >= 1, id <= elements.count else { return "There's no [\(id)]. Read the screen again." }
        let target = elements[id - 1]
        let what = describe(target) ?? "[\(id)]"
        if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return "Clicked \(what)."
        }
        guard let center = center(of: target) else { return "Couldn't click \(what)." }
        mouseClick(at: center)
        try? await Task.sleep(nanoseconds: 400_000_000)
        return "Clicked \(what)."
    }

    /// Puts the cursor in field `id` (a click, which web pages need, then Accessibility focus).
    public static func focus(_ id: Int) async -> Bool {
        guard id >= 1, id <= elements.count else { return false }
        let target = elements[id - 1]
        if let center = center(of: target) { mouseClick(at: center) }
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 250_000_000)
        return true
    }

    /// "return", "cmd+l", "cmd+shift+n", "down", "tab", "escape", "space".
    public static func press(_ combo: String) -> String {
        let parts = combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            default: key = keyCodes[part]
            }
        }
        guard let key else { return "I don't know the key in \"\(combo)\"." }
        MacActions.postKey(key, flags: flags)
        return "Pressed \(combo)."
    }

    // MARK: Accessibility helpers

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        let text = (value(element, attribute) as? String)?
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? String(text!.prefix(90)) : nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let found = value(element, attribute), CFGetTypeID(found) == AXUIElementGetTypeID() else { return nil }
        return (found as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Its title, description, placeholder or value, or the text inside it (a web link's words).
    private static func label(_ element: AXUIElement, role: String) -> String? {
        if let title = string(element, kAXTitleAttribute) { return title }
        if let description = string(element, kAXDescriptionAttribute) { return description }
        if let placeholder = string(element, "AXPlaceholderValue") { return placeholder }
        if role != "AXTextField", role != "AXTextArea", let text = string(element, kAXValueAttribute) { return text }
        var texts: [String] = []
        var level = children(element)
        for _ in 0..<3 where texts.isEmpty {
            var next: [AXUIElement] = []
            for child in level.prefix(12) {
                if let text = string(child, kAXValueAttribute) ?? string(child, kAXTitleAttribute)
                    ?? string(child, kAXDescriptionAttribute) { texts.append(text) }
                next.append(contentsOf: children(child))
            }
            level = next
        }
        let joined = texts.joined(separator: " ")
        return joined.isEmpty ? nil : String(joined.prefix(90))
    }

    private static func describe(_ element: AXUIElement) -> String? {
        let role = string(element, kAXRoleAttribute) ?? ""
        let kind = roles[role] ?? "element"
        return label(element, role: role).map { "\(kind) \"\($0)\"" } ?? kind
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func center(of element: AXUIElement) -> CGPoint? {
        guard let frame = frame(of: element), frame.width > 0, frame.height > 0 else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Inside some screen (scrolled-away page parts are left out). Elements without a frame count as visible.
    private static func isOnScreen(_ element: AXUIElement) -> Bool {
        guard let frame = frame(of: element) else { return true }
        if frame.width <= 1 || frame.height <= 1 { return false }
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        // AX uses top-left origin; the union's height is all the same for this rough check.
        return frame.maxY > 0 && frame.minY < union.height + 40 && frame.maxX > union.minX && frame.minX < union.maxX
    }

    private static func mouseClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var codes: [String: Int] = [
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "escape": kVK_Escape,
            "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        ]
        codes["⏎"] = kVK_Return
        return codes.mapValues { CGKeyCode($0) }
    }()
}
