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
        var scroller: (element: AXUIElement, size: CGFloat)?
        while index < queue.count, index < 8000, elements.count < limit || textLength < textLimit {
            let current = queue[index]
            index += 1
            let role = string(current, kAXRoleAttribute) ?? ""
            let subrole = string(current, kAXSubroleAttribute) ?? ""
            let kind: String? = subrole == "AXSearchField" ? "search field" : roles[role]
            let visible = isOnScreen(current)
            // The biggest part that scrolls up and down: whether there's more of it than is in view.
            if role == "AXScrollArea", visible, let box = frame(of: current), box.width > 80, box.height > 80,
               element(current, kAXVerticalScrollBarAttribute) != nil, box.width * box.height > (scroller?.size ?? 0) {
                scroller = (current, box.width * box.height)
            }
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
        // Only what's in view was read: say when the window's list or document goes on past it, so the model scrolls
        // or reads it all instead of answering from the first screenful.
        if let area = scroller?.element, let at = position(of: area) {
            if at < 0.97 {
                lines.append("More below: this is only the part in view (\(Int((at * 100).rounded()))% of the way down). "
                    + "scroll down, or read_everything to get all of it.")
            } else if at > 0.03 {
                lines.append("This is the end of it; there's more above (scroll up, or read_everything).")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Seeing (screenshots)

    /// A screenshot of the window you're looking at, small enough to send to a vision model, with what's needed to
    /// turn a point on it back into a point on the screen.
    public struct Shot: @unchecked Sendable {
        public let image: CGImage
        public let jpeg: Data
        /// The image's size in pixels (what positions on it are measured in).
        public let width: Int
        public let height: Int
        /// The window on the screen (global, top-left origin, in points).
        public let frame: CGRect
        public let app: String
        public let window: String

        /// The screen point for a pixel of the screenshot.
        public func screenPoint(x: Double, y: Double) -> CGPoint {
            CGPoint(x: frame.minX + x * frame.width / Double(width), y: frame.minY + y * frame.height / Double(height))
        }
    }

    /// The latest screenshot: positions in click_at and scroll_at are on it.
    public private(set) static var lastShot: Shot?

    /// Takes a screenshot of the working app's window (longest side at most `maxSide` pixels). Nil without Screen
    /// Recording permission (asked for once) or with no window.
    public static func shoot(maxSide: CGFloat = 1280) async -> Shot? {
        guard let app = await targetApp() else { return nil }
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
            // The window you're looking at (under the pointer, else the front one), else the biggest.
            let viewed = viewedWindowBounds(of: app.processIdentifier)
            guard let window = windows.first(where: { candidate in
                    viewed.map { abs(candidate.frame.minX - $0.minX) < 4 && abs(candidate.frame.minY - $0.minY) < 4
                        && abs(candidate.frame.width - $0.width) < 4 } ?? false
                  })
                    ?? windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { return nil }
            let frame = window.frame
            let scale = min(NSScreen.main?.backingScaleFactor ?? 2, maxSide / max(frame.width, frame.height))
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(frame.width * scale))
            configuration.height = max(1, Int(frame.height * scale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
            guard let jpeg = NSBitmapImageRep(cgImage: image)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return nil }
            let shot = Shot(image: image, jpeg: jpeg, width: image.width, height: image.height, frame: frame,
                            app: app.localizedName ?? "the app", window: window.title ?? "untitled")
            lastShot = shot
            return shot
        } catch {
            return nil
        }
    }

    /// The text in a picture (Vision, on this Mac), top to bottom.
    public static func recognise(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The text in a screenshot with where each line is, in its pixels: "Send at (640, 200)". What click_at needs when
    /// there's no vision model to describe the screen.
    public static func recognisedLines(_ shot: Shot, limit: Int = 4000) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cgImage: shot.image).perform([request])) != nil else { return nil }
        let lines = (request.results ?? [])
            .sorted { (Int((1 - $0.boundingBox.midY) * 100), $0.boundingBox.minX)
                < (Int((1 - $1.boundingBox.midY) * 100), $1.boundingBox.minX) }
            .compactMap { observation -> String? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox   // 0–1, from the bottom-left
                let x = Int((box.midX * Double(shot.width)).rounded())
                let y = Int(((1 - box.midY) * Double(shot.height)).rounded())
                return "\(text) at (\(x), \(y))"
            }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    /// What's under a point on the screen, as Accessibility names it ("button “Send”"): for the risk check before a
    /// click at a point, and to say what was clicked.
    public static func describe(at point: CGPoint) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &found)
                == .success, let found else { return nil }
        // A label inside a button: name the button.
        var node: AXUIElement? = found
        for _ in 0..<3 {
            guard let current = node else { break }
            let role = string(current, kAXRoleAttribute) ?? ""
            if roles[role] != nil, role != "AXStaticText", let words = label(current, role: role) {
                return "\(roles[role] ?? "element") “\(words)”"
            }
            node = element(current, kAXParentAttribute)
        }
        return describe(found)
    }

    /// Clicks a point on the screen as a person would: the pointer goes there and clicks (twice for `double`, with the
    /// right button for `right`).
    public static func click(at point: CGPoint, double: Bool = false, right: Bool = false) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right
            ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for count in 1...(double ? 2 : 1) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                    mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    /// Scrolls whatever is under a point on the screen (a screenful, or to the top or end).
    public static func scroll(at point: CGPoint, direction: String) async {
        let way = direction.lowercased()
        let pixels = way == "top" ? 20_000 : way == "bottom" || way == "end" ? -20_000 : way == "up" ? 600 : -600
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 60_000_000)
        var left = pixels
        while left != 0 {
            let chunk = left > 0 ? min(left, 400) : max(left, -400)
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                wheel1: Int32(chunk) * wheelSign, wheel2: 0, wheel3: 0)
            event?.location = point
            event?.post(tap: .cghidEventTap)
            left -= chunk
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
    }

    // MARK: Scrolling

    /// All of the front window's list, chat, feed, table or document, read the way a person would: scrolled through
    /// screen by screen to the end, each screenful's text joined to the last without the overlap. A model left to
    /// do this itself read one screen and answered ("you have 3 unread emails" with 40 more below).
    public struct Everything: Sendable {
        public let text: String
        /// Screenfuls read (1: it all fitted on the screen, nothing was out of view).
        public let screens: Int
        /// Read to the very end (else stopped at the limit, with more below).
        public let reachedEnd: Bool
    }

    /// `fromTop`: start at the top (a list, a document, settings); false: from where it's scrolled to now (a chat,
    /// where the newest is at the bottom). The window is put back where it was afterwards.
    public static func readEverything(fromTop: Bool = true, maxScreens: Int = 25,
                                      limit: Int = 24_000) async -> Result<Everything, ReadFailure> {
        guard AXIsProcessTrusted() else { return .failure(.message("Murmur needs Accessibility permission to see the screen.")) }
        guard let app = await targetApp() else { return .failure(.message("No app is in front.")) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let window = viewedWindow(of: app) ?? element(root, kAXFocusedWindowAttribute)
                ?? element(root, kAXMainWindowAttribute) else {
            return .failure(.message("\(app.localizedName ?? "The front app") has no window open."))
        }
        let header = "App: \(app.localizedName ?? "?") · Window: \(string(window, kAXTitleAttribute) ?? "untitled")"
        let area = scrollArea(in: window)
        let container = area ?? window
        // A document (Notes, TextEdit, Mail's message, Pages): its whole text is there at once, scrolled or not.
        if let document = documentText(in: container), document.count > 400 {
            return .success(Everything(text: header + "\nThe whole document (\(document.count) characters):\n"
                + String(document.prefix(limit)), screens: 1, reachedEnd: document.count <= limit))
        }
        let clip = frame(of: container)
        let started = position(of: container)
        if fromTop, started.map({ $0 > 0.005 }) ?? true {
            await scrollToEnd(container, top: true)
        }
        var lines: [String] = []
        var screens = 0
        var reachedEnd = false
        var unchanged = 0
        var useful = 0   // screens that brought something new
        while screens < maxScreens {
            screens += 1
            var screen = visibleLines(in: container, clip: clip)
            // Little or no text through Accessibility (canvas and some Electron apps): the window's pixels instead.
            if screen.joined().count < 60, let recognised = await recognisedText(of: app) {
                screen = PageDigest.lines(recognised)
            }
            let before = lines.count
            lines = PageDigest.merge(lines, screen)
            if lines.count > before { useful += 1 }
            if lines.reduce(0, { $0 + $1.count + 1 }) >= limit { break }
            let at = position(of: container)
            if let at, at >= 0.995 { reachedEnd = true; break }
            if at == nil {
                // No scroll bar to ask: the end is when a scroll brings nothing new, twice.
                unchanged = lines.count == before && screens > 1 ? unchanged + 1 : 0
                if unchanged >= 2 { reachedEnd = true; break }
            }
            let page = Int((clip?.height ?? 600) * 0.8)
            await wheel(container, by: -page)
            try? await Task.sleep(nanoseconds: 450_000_000)   // lists and feeds load more as they're reached
            if let at, let now = position(of: container), abs(now - at) < 0.0005 { reachedEnd = true; break }
        }
        // Back to where the user was (where the app lets its scroll bar be set; else it stays where reading ended).
        if let started { setPosition(container, started) }
        let text = String(lines.joined(separator: "\n").prefix(limit))
        let how = useful <= 1 ? "It all fits on the screen."
            : reachedEnd ? "Scrolled through all of it: \(useful) screens, \(fromTop ? "top" : "from where it was") to the very end."
            : "Scrolled through \(useful) screens; there's more below that wasn't read."
        return .success(Everything(text: header + "\n" + how + "\n" + text, screens: useful, reachedEnd: reachedEnd))
    }

    public enum ReadFailure: Error, Sendable {
        case message(String)
        public var text: String {
            switch self { case .message(let text): return text }
        }
    }

    /// Scrolls the front window's list or document (the one around element `id` from the last read, else the
    /// biggest one in view): "down", "up" (a screenful), "top", "bottom". Says where it got to.
    public static func scroll(_ direction: String, around id: Int? = nil) async -> String {
        guard AXIsProcessTrusted() else { return "Murmur needs Accessibility permission to scroll." }
        guard let app = await targetApp() else { return "No app is in front." }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = viewedWindow(of: app) ?? element(root, kAXFocusedWindowAttribute) else {
            return "\(app.localizedName ?? "The front app") has no window open."
        }
        let container = scrollArea(in: window, around: id) ?? window
        let way = direction.lowercased().trimmingCharacters(in: .whitespaces)
        let before = position(of: container)
        let shownBefore = visibleLines(in: container, clip: frame(of: container))
        let page = Int((frame(of: container)?.height ?? 600) * 0.8)
        switch way {
        case "top", "bottom", "end", "start":
            await scrollToEnd(container, top: way == "top" || way == "start")
        case "up":
            await wheel(container, by: page)
        default:
            await wheel(container, by: -page)
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        let after = position(of: container)
        let upward = way == "up" || way == "top" || way == "start"
        if let before, let after, abs(after - before) < 0.0005 {
            return upward ? "Already at the top." : "Already at the end: there's nothing more below."
        }
        if before == nil, visibleLines(in: container, clip: frame(of: container)) == shownBefore {
            return upward ? "Nothing moved: it's at the top, or this part doesn't scroll."
                : "Nothing moved: it's at the end, or this part doesn't scroll (try another [n] inside the list)."
        }
        guard let after else { return "Scrolled \(way)." }
        if after >= 0.995 { return "Scrolled \(way): this is the end of it." }
        if after <= 0.005 { return "Scrolled \(way): this is the top." }
        return "Scrolled \(way) (now \(Int((after * 100).rounded()))% of the way down)."
    }

    /// The part of the window that scrolls: the scroll area around element `id` from the last read, else the biggest
    /// one in view that scrolls up and down (a chat, an inbox, a list, a document).
    private static func scrollArea(in window: AXUIElement, around id: Int? = nil) -> AXUIElement? {
        if let id, id >= 1, id <= elements.count {
            var node: AXUIElement? = elements[id - 1]
            for _ in 0..<40 {
                guard let current = node else { break }
                if string(current, kAXRoleAttribute) == "AXScrollArea" { return current }
                node = element(current, kAXParentAttribute)
            }
        }
        // Their contents are text and rows, not more scroll areas: not walked.
        let leaves: Set<String> = ["AXStaticText", "AXRow", "AXCell", "AXLink", "AXButton", "AXImage", "AXTextArea",
                                   "AXTextField", "AXMenuItem", "AXCheckBox", "AXRadioButton"]
        var best: (element: AXUIElement, size: CGFloat)?
        var queue = [window]
        var index = 0
        while index < queue.count, index < 3000 {
            let node = queue[index]
            index += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            if leaves.contains(role) { continue }
            if role == "AXScrollArea", let box = frame(of: node), box.width > 80, box.height > 80, isOnScreen(node) {
                // One that scrolls up and down beats a bigger one that doesn't (a sidebar's, a toolbar's).
                let size = box.width * box.height * (element(node, kAXVerticalScrollBarAttribute) != nil ? 4 : 1)
                if size > (best?.size ?? 0) { best = (node, size) }
            }
            queue.append(contentsOf: children(node))
        }
        return best?.element
    }

    /// How far down it's scrolled, 0 (top) to 1 (end); nil when it has no scroll bar to ask (web content, a
    /// window), or nothing to scroll.
    private static func position(of area: AXUIElement) -> Double? {
        guard let bar = element(area, kAXVerticalScrollBarAttribute),
              let number = value(bar, kAXValueAttribute) as? NSNumber else { return nil }
        return min(max(number.doubleValue, 0), 1)
    }

    /// Scrolls straight to `to` (0 top, 1 end) through its scroll bar; false when the app doesn't allow it.
    @discardableResult
    private static func setPosition(_ area: AXUIElement, _ to: Double) -> Bool {
        guard let bar = element(area, kAXVerticalScrollBarAttribute) else { return false }
        return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: to)) == .success
    }

    /// To the top or the end: through the scroll bar when the app allows it, else with the wheel, in big steps
    /// until it stops moving (lists that load more as they're reached keep going, up to a limit).
    private static func scrollToEnd(_ area: AXUIElement, top: Bool) async {
        if setPosition(area, top ? 0 : 1) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let at = position(of: area), top ? at <= 0.005 : at >= 0.995 { return }
        }
        var last = visibleLines(in: area, clip: frame(of: area))
        for _ in 0..<12 {
            await wheel(area, by: top ? 6000 : -6000)
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let at = position(of: area), top ? at <= 0.005 : at >= 0.995 { break }
            let now = visibleLines(in: area, clip: frame(of: area))
            if now == last { break }
            last = now
        }
    }

    /// Positive: up (towards the top). Flipped once if the app turned out to scroll the other way.
    private static var wheelSign: Int32 = 1

    /// Scrolls `area` by `pixels` (positive up, negative down) with the scroll wheel, as a person would: the pointer
    /// goes over it for the moment it takes and comes back.
    private static func wheel(_ area: AXUIElement, by pixels: Int) async {
        guard pixels != 0, let box = frame(of: area) else { return }
        let point = CGPoint(x: box.midX, y: box.minY + min(box.height / 2, 300))
        let pointer = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let before = position(of: area)
        var left = pixels
        while left != 0 {
            let chunk = left > 0 ? min(left, 400) : max(left, -400)
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                wheel1: Int32(chunk) * wheelSign, wheel2: 0, wheel3: 0)
            event?.location = point
            event?.post(tap: .cghidEventTap)
            left -= chunk
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        // Went the wrong way (the bar says so): the sign is the other way round here, and the scroll is done again.
        if let before, let after = position(of: area), abs(after - before) > 0.0005, (after < before) != (pixels > 0) {
            wheelSign = -wheelSign
            for _ in 0..<2 {
                var again = pixels
                while again != 0 {
                    let chunk = again > 0 ? min(again, 400) : max(again, -400)
                    let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                        wheel1: Int32(chunk) * wheelSign, wheel2: 0, wheel3: 0)
                    event?.location = point
                    event?.post(tap: .cghidEventTap)
                    again -= chunk
                    try? await Task.sleep(nanoseconds: 12_000_000)
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if let pointer {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: pointer, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// The text shown inside `container` right now, top to bottom (left to right on a line): what a person sees
    /// there. `clip`: the part of the screen it shows (things scrolled out of it are left out).
    private static func visibleLines(in container: AXUIElement, clip: CGRect?) -> [String] {
        var found: [(y: CGFloat, x: CGFloat, text: String)] = []
        var queue = [container]
        var index = 0
        while index < queue.count, index < 5000 {
            let node = queue[index]
            index += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            let box = frame(of: node)
            if let box, let clip, !box.intersects(clip.insetBy(dx: -2, dy: -2)) {
                continue   // out of view, and so is everything in it
            }
            let inside = role == "AXStaticText" ? [] : children(node)
            // Text, and things that say what they are only by their label (a calendar's event, an image, an icon
            // button with no text inside it).
            let text = role == "AXStaticText"
                ? longString(node, kAXValueAttribute) ?? longString(node, kAXDescriptionAttribute)
                : inside.isEmpty && role != "AXTextArea" && role != "AXTextField" && role != "AXScrollBar"
                    ? (longString(node, kAXDescriptionAttribute) ?? longString(node, kAXTitleAttribute))
                        .flatMap { $0.count >= 3 ? $0 : nil }
                    : nil
            if let text, let box {
                found.append((box.minY, box.minX, text.replacingOccurrences(of: "\n", with: " ")))
            }
            queue.append(contentsOf: inside)
        }
        // Reading order: by line (to within a few points), then left to right.
        found.sort { (Int($0.y / 6), $0.x) < (Int($1.y / 6), $1.x) }
        var lines: [String] = []
        for item in found where lines.last != item.text { lines.append(item.text) }
        return lines
    }

    /// The whole text of a document shown in `container` (a text area's value is all of it, scrolled or not).
    private static func documentText(in container: AXUIElement) -> String? {
        var queue = [container]
        var index = 0
        var longest: String?
        while index < queue.count, index < 1500 {
            let node = queue[index]
            index += 1
            if string(node, kAXRoleAttribute) == "AXTextArea",
               let text = longString(node, kAXValueAttribute, max: 200_000), text.count > (longest?.count ?? 0) {
                longest = text
            }
            queue.append(contentsOf: children(node))
        }
        return longest
    }

    /// All the text of the web page in the front browser window, top to bottom, including what's scrolled out of view,
    /// through Accessibility. For when the browser won't let Murmur script its pages ("Allow JavaScript from Apple
    /// Events" off): `read()` gives only what's visible, and "summarise this" got the first screenful of a long page.
    /// Nil when there's no page (not a browser, or nothing in it).
    public static func readPage(limit: Int = 12_000) async -> String? {
        guard AXIsProcessTrusted(), let app = await targetApp() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        guard let window = viewedWindow(of: app) ?? element(root, kAXFocusedWindowAttribute) else { return nil }
        // The page: the window's web area (the browser's own toolbars and tabs are left out).
        var queue = [window]
        var index = 0
        var page: AXUIElement?
        while index < queue.count, index < 4000 {
            let node = queue[index]
            index += 1
            if string(node, kAXRoleAttribute) == "AXWebArea" { page = node; break }
            queue.append(contentsOf: children(node))
        }
        guard let page else { return nil }
        // Depth first, so the text comes in reading order.
        var stack = [page]
        var texts: [String] = []
        var length = 0
        var visited = 0
        while let node = stack.popLast(), visited < 30_000, length < limit {
            visited += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            if role == "AXStaticText", let text = longString(node, kAXValueAttribute, max: 2000)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, texts.last != text {
                texts.append(text)
                length += text.count + 1
                continue
            }
            if role == "AXImage", let text = longString(node, kAXDescriptionAttribute), text.count >= 3 {
                texts.append("[image: \(text)]")
                length += text.count + 10
            }
            stack.append(contentsOf: children(node).reversed())
        }
        guard length > 0 else { return nil }
        let title = string(page, kAXTitleAttribute).map { "Page: \($0)\n" } ?? ""
        return title + String(texts.joined(separator: "\n").prefix(limit))
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
            return recognise(image)
        } catch {
            return nil
        }
    }

    // MARK: Acting

    /// Clicks the button or link whose words best match `text`, found anywhere in the front window, not only among
    /// the first things a read lists: a web app like Gmail has hundreds, and "Sent" in its sidebar wasn't among
    /// them. The same words first, then words that start with them ("Sent 3" for "Sent"), then ones that contain
    /// them; links and buttons before other things, ones on screen first. Pressed through Accessibility (scrolled
    /// into view first), else clicked with the pointer. browser_click uses it when the page can't be scripted.
    public static func click(labeled text: String) async -> String {
        guard AXIsProcessTrusted() else { return "Murmur needs Accessibility permission to click." }
        let want = folded(text)
        guard !want.isEmpty else { return "Say what to click." }
        guard let app = await targetApp() else { return "No app is in front." }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        guard let window = viewedWindow(of: app) ?? element(root, kAXFocusedWindowAttribute) else {
            return "\(app.localizedName ?? "The front app") has no window open."
        }
        let pressable: Set<String> = [
            "AXLink", "AXButton", "AXTab", "AXMenuItem", "AXMenuButton", "AXRadioButton", "AXCheckBox",
            "AXPopUpButton", "AXDisclosureTriangle", "AXTreeItem", "AXRow", "AXCell",
        ]
        var best: (element: AXUIElement, score: Int)?
        var queue = [window]
        var index = 0
        while index < queue.count, index < 25_000 {
            let node = queue[index]
            index += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            if pressable.contains(role), let words = label(node, role: role) {
                let match = matchScore(folded(words), want)
                if match > 0 {
                    let score = match * 10 + (role == "AXLink" || role == "AXButton" ? 2 : 0) + (isOnScreen(node) ? 1 : 0)
                    if score > (best?.score ?? 0) { best = (node, score) }
                }
                // A link's or button's children are its label.
                if role == "AXLink" || role == "AXButton" { continue }
            }
            queue.append(contentsOf: children(node))
        }
        guard let best else {
            return "Nothing on the screen says “\(text)”. read_screen to see what's there, or scroll."
        }
        let what = describe(best.element) ?? "“\(text)”"
        AXUIElementPerformAction(best.element, "AXScrollToVisible" as CFString)
        if AXUIElementPerformAction(best.element, kAXPressAction as CFString) == .success {
            try? await Task.sleep(nanoseconds: 700_000_000)
            return "Clicked \(what)."
        }
        guard let point = center(of: best.element) else { return "Couldn't click \(what)." }
        app.activate()
        try? await Task.sleep(nanoseconds: 200_000_000)
        mouseClick(at: point)
        try? await Task.sleep(nanoseconds: 700_000_000)
        return "Clicked \(what)."
    }

    /// Lowercased, quotes and punctuation dropped, spaces collapsed: "“Sent”" → "sent".
    nonisolated static func folded(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[“”"'‘’.,:;!?()\[\]]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// How well a control's words match what to click: 4 the same, 3 starting with it as a word ("sent 3"),
    /// 2 starting with it, 1 containing it as a word, 0 not at all.
    nonisolated static func matchScore(_ words: String, _ want: String) -> Int {
        guard !words.isEmpty, !want.isEmpty else { return 0 }
        if words == want { return 4 }
        if words.hasPrefix(want + " ") { return 3 }
        if words.hasPrefix(want) { return 2 }
        if (" " + words + " ").contains(" " + want + " ") { return 1 }
        return 0
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
