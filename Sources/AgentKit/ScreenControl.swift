import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import Vision

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

    /// The app you were last working in, other than Murmur: when Murmur's own window or panel is in front, that's
    /// the screen you mean.
    private static var lastOtherApp: NSRunningApplication?
    private static var watching: NSObjectProtocol?
    /// Asked for Screen Recording once this session (macOS shows its prompt only once anyway).
    private static var askedForScreenRecording = false

    /// Starts following which app is in front (called when Murmur starts, and again on every read).
    public static func watchFrontApp() {
        guard watching == nil else { return }
        remember(NSWorkspace.shared.frontmostApplication)
        watching = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { remember(app) }
        }
    }

    private static func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastOtherApp = app
        if BrowserControl.browser(for: app) != nil { lastBrowserApp = app }
    }

    /// The browser you were in last (Chrome, Safari…), for "summarise this page" said from another app.
    public private(set) static var lastBrowserApp: NSRunningApplication?

    /// The app you're working in: the front one, or the one you were in when Murmur's own window is in front.
    public static func workingApp() -> NSRunningApplication? {
        watchFrontApp()
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier { return front }
        return lastOtherApp.flatMap { $0.isTerminated ? nil : $0 }
    }

    /// The title of the window you're looking at in the working app ("Movies", "interview.mp4", "Inbox – Gmail").
    public static func frontWindowTitle() -> String? {
        guard AXIsProcessTrusted(), let app = workingApp() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = viewedWindow(of: app) ?? element(root, kAXFocusedWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute)
    }

    /// The window you're looking at in an app: of its windows on this desktop, the one under the pointer, else its
    /// frontmost. (Not "the app's first window": with videos on two desktops or screens, that was the other one.)
    /// Global coordinates, top-left origin, as Accessibility and AppleScript use.
    public static func viewedWindowBounds(of pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let mouse = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let pointer = CGPoint(x: mouse.x, y: top - mouse.y)
        var frontmost: CGRect?
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary), rect.width > 200, rect.height > 150 else { continue }
            if rect.contains(pointer) { return rect }
            if frontmost == nil { frontmost = rect }
        }
        return frontmost
    }

    /// That window as "x,y,width,height", for scripts that pick the matching window; "" when there's none.
    public static func viewedWindowArgument(of pid: pid_t) -> String {
        guard let rect = viewedWindowBounds(of: pid) else { return "" }
        return "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }

    /// That window, through Accessibility.
    static func viewedWindow(of app: NSRunningApplication) -> AXUIElement? {
        guard let rect = viewedWindowBounds(of: app.processIdentifier) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            guard let frame = frame(of: window) else { return false }
            return abs(frame.minX - rect.minX) < 10 && abs(frame.minY - rect.minY) < 10
                && abs(frame.width - rect.width) < 10 && abs(frame.height - rect.height) < 10
        }
    }

    /// Brings the window you're looking at to the front of its app, so keys go to it.
    public static func raiseViewedWindow(of app: NSRunningApplication) {
        guard let window = viewedWindow(of: app) else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// The app whose screen to read: the front one, or the one you were in when Murmur is in front.
    private static func targetApp() async -> NSRunningApplication? {
        watchFrontApp()
        guard let front = NSWorkspace.shared.frontmostApplication else { return lastOtherApp }
        guard front.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return front }
        guard let other = lastOtherApp, !other.isTerminated else { return nil }
        // Murmur's window was in front: bring your app back, so clicks and keys land there too.
        other.activate()
        try? await Task.sleep(nanoseconds: 400_000_000)
        return other
    }

    /// The front window: what it says (its text, top to bottom), then what you can press or type into, numbered:
    /// `[7] link "Lofi Girl – beats to relax"`. Fresh numbers every read. When the app doesn't share its contents
    /// through Accessibility (canvas apps, some Electron apps, pictures of text), the window's text is read from a
    /// capture of it instead (needs Screen Recording).
    public static func read(limit: Int = 140, textLimit: Int = 3000) async -> String {
        guard AXIsProcessTrusted() else { return "Murmur needs Accessibility permission to see the screen." }
        guard let app = await targetApp() else { return "No app is in front." }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Chrome and Electron apps build their page's accessibility tree only when an assistant asks for it.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let window = viewedWindow(of: app) ?? element(root, kAXFocusedWindowAttribute)
                ?? element(root, kAXMainWindowAttribute) else {
            return "\(app.localizedName ?? "The front app") has no window open."
        }
        elements = []
        var lines = ["App: \(app.localizedName ?? "?") · Window: \(string(window, kAXTitleAttribute) ?? "untitled")"]
        if let focused = element(root, kAXFocusedUIElementAttribute) {
            lines.append("Keyboard focus: \(describe(focused) ?? "somewhere")")
        }
        var controls: [String] = []
        var texts: [String] = []
        var textLength = 0
        var queue: [AXUIElement] = [window]
        var index = 0
        var seen = Set<String>()
        var seenText = Set<String>()
        while index < queue.count, index < 8000, elements.count < limit || textLength < textLimit {
            let current = queue[index]
            index += 1
            let role = string(current, kAXRoleAttribute) ?? ""
            let subrole = string(current, kAXSubroleAttribute) ?? ""
            let kind: String? = subrole == "AXSearchField" ? "search field" : roles[role]
            let visible = isOnScreen(current)
            if role == "AXStaticText", visible, textLength < textLimit,
               let text = longString(current, kAXValueAttribute) ?? longString(current, kAXDescriptionAttribute),
               seenText.insert(text).inserted {
                texts.append(text)
                textLength += text.count + 1
            }
            if let kind, visible, elements.count < limit {
                let label = self.label(current, role: role)
                let editable = role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
                if label != nil || editable {
                    let text = label.map { " \"\($0)\"" } ?? ""
                    let key = kind + text
                    // Pages repeat the same link many times (thumbnail + title): list it once.
                    if editable || !seen.contains(key) {
                        seen.insert(key)
                        elements.append(current)
                        controls.append("[\(elements.count)] \(kind)\(text)")
                    }
                }
                // A link's or button's children are its label, not more things to press.
                if role == "AXLink" || role == "AXButton" { continue }
            }
            // What an app shows in things that aren't text or controls (a calendar's events, a list's rows, a cell):
            // their description or title is what they say.
            if kind == nil, role != "AXStaticText", role != "AXWindow", visible, textLength < textLimit,
               let text = longString(current, kAXDescriptionAttribute) ?? longString(current, kAXTitleAttribute),
               text.count >= 3, seenText.insert(text).inserted {
                texts.append(text)
                textLength += text.count + 1
            }
            // A document's text, typed in an editor (Notes, TextEdit, Mail): what it says, as far as the limit.
            if role == "AXTextArea", visible, textLength < textLimit, let text = longString(current, kAXValueAttribute, max: 1500) {
                texts.append(text)
                textLength += text.count + 1
            }
            queue.append(contentsOf: children(current))
        }
        // Little or no text through Accessibility: read the window's pixels instead.
        if textLength < 200, let recognised = await recognisedText(of: app) {
            texts = [recognised]
        }
        if !texts.isEmpty {
            lines.append("Text on screen:")
            lines.append(String(texts.joined(separator: "\n").prefix(textLimit + 1500)))
        }
        lines.append("Things to press or type into:")
        lines.append(contentsOf: controls)
        if controls.isEmpty { lines.append("(Nothing to press or type into is visible.)") }
        return lines.joined(separator: "\n")
    }

    /// The text in a picture of the app's front window (Vision, on this Mac). Nil without Screen Recording
    /// permission (asked for once), or when there's nothing to read.
    private static func recognisedText(of app: NSRunningApplication) async -> String? {
        guard CGPreflightScreenCaptureAccess() else {
            if !askedForScreenRecording {
                askedForScreenRecording = true
                _ = await Permissions.inFront { CGRequestScreenCaptureAccess() }
            }
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windows = content.windows.filter {
                $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 80
            }
            guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? [])
                .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }        // top of the window first
                .compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    // MARK: Acting

    /// Clicks the button or link whose words match `text` (the same words, then starting with them, then containing
    /// them), from a fresh look at the screen: browser_click when the browser's page can't be scripted.
    public static func click(labeled text: String) async -> String {
        _ = await read()
        let want = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else { return "Say what to click." }
        var best: (index: Int, score: Int)?
        for (index, element) in elements.enumerated() {
            let role = string(element, kAXRoleAttribute) ?? ""
            guard let words = label(element, role: role)?.lowercased() else { continue }
            let score = words == want ? 3 : words.hasPrefix(want) ? 2 : words.contains(want) ? 1 : 0
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        guard let best else { return "Nothing on the screen says “\(text)”. read_screen to see what's there, or scroll." }
        return await click(best.index + 1)
    }

    /// Puts the cursor in the field whose label or placeholder contains `name`; with no name (or no match), the
    /// focused field, else a search field, else the first field. Returns whether there was one.
    public static func focusField(named name: String) async -> Bool {
        _ = await read()
        let editable = elements.enumerated().filter { _, element in
            let role = string(element, kAXRoleAttribute) ?? ""
            return role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
                || string(element, kAXSubroleAttribute) == "AXSearchField"
        }
        guard !editable.isEmpty else { return false }
        let want = name.lowercased().trimmingCharacters(in: .whitespaces)
        func words(_ element: AXUIElement) -> String {
            [string(element, kAXDescriptionAttribute), string(element, "AXPlaceholderValue"),
             string(element, kAXTitleAttribute)].compactMap { $0 }.joined(separator: " ").lowercased()
        }
        let pick = (want.isEmpty ? nil : editable.first { words($0.element).contains(want) })
            ?? editable.first { string($0.element, kAXSubroleAttribute) == "AXSearchField" || words($0.element).contains("search") }
            ?? editable.first
        guard let pick else { return false }
        return await focus(pick.offset + 1)
    }

    /// Presses the menu item called `title` anywhere in `app`'s menu bar, unless it's already ticked: a setting with
    /// no other way in ("Allow JavaScript from Apple Events"). Returns whether it was pressed (or already on).
    public static func turnOnMenuItem(titled title: String, in app: NSRunningApplication) async -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = element(root, kAXMenuBarAttribute) else { return false }
        var queue: [(node: AXUIElement, depth: Int)] = [(bar, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 6000 {
            let (node, depth) = queue.removeFirst()
            for child in children(node) {
                seen += 1
                if string(child, kAXRoleAttribute) == "AXMenuItem", string(child, kAXTitleAttribute) == title {
                    if let mark = string(child, "AXMenuItemMarkChar"), !mark.isEmpty { return true }   // already on
                    return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
                }
                if depth < 7 { queue.append((child, depth + 1)) }
            }
        }
        return false
    }

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

    /// Text as it is, up to `max` characters (a paragraph, not just a label).
    private static func longString(_ element: AXUIElement, _ attribute: String, max: Int = 500) -> String? {
        let text = (value(element, attribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(max))
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
