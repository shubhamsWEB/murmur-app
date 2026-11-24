import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit
import Vision

/// The parts of "write it for me" that need the Mac: reading the box and the window round it through Accessibility,
/// and asking the model.
extension ReplyWriter {
    // MARK: Reading the window

    /// The focused text box of the front app and what's around it, or nil when the focus isn't a box Murmur may
    /// write in (a password field, a page that isn't editable, a password manager, Murmur itself).
    /// `patient`: a second try for a window that gave next to nothing the first time. Apps built on a browser
    /// engine (Electron) only describe their page once asked to, and some apps answer slowly: it asks, and waits
    /// longer.
    @MainActor
    public static func read(patient: Bool = false) -> (context: Context, field: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              !ScreenReader.neverRead.contains(bundle), app != NSRunningApplication.current else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, patient ? 1.5 : 0.4)
        if patient { AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        guard let field: AXUIElement = ScreenReader.attribute(element, kAXFocusedUIElementAttribute),
              isWritable(field), let fieldFrame = frame(of: field) else { return nil }
        // A box in a toolbar (an address bar, a search field) is for finding things, not writing to someone. In a
        // browser, only a box on the page counts, and only the page is read: not its tabs, bookmarks or sidebar.
        if ancestor(of: field, role: "AXToolbar") != nil { return nil }
        let page = ancestor(of: field, role: "AXWebArea")
        if page == nil, browsers.contains(where: { bundle == $0 || bundle.hasPrefix($0 + ".") }) { return nil }
        let window: AXUIElement? = ScreenReader.attribute(element, kAXFocusedWindowAttribute)
        let title: String = window.flatMap { ScreenReader.attribute($0, kAXTitleAttribute) } ?? ""
        let found = (page ?? window).map { Self.pieces(in: $0, skipping: field, within: patient ? 1.5 : 0.5, labels: patient) } ?? []
        let (above, below) = arrange(found, field: fieldFrame)
        let draft: String = ScreenReader.attribute(field, kAXValueAttribute) ?? ""
        let selected: String? = ScreenReader.attribute(field, kAXSelectedTextAttribute)
        let context = Context(app: ScreenText.appName(app.localizedName ?? bundle), title: ScreenText.appName(title),
                              above: above, below: below, draft: String(draft.prefix(4000)),
                              selection: selected.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
                              sides: sides(of: above, pieces: found, field: fieldFrame))
        return (context, field)
    }

    /// What the last `readPicture` found, for the log (places and counts, never the text).
    @MainActor public private(set) static var pictureNote = ""

    /// Fewer lines than this above the box and the window is read from a picture of it too: some apps (WhatsApp
    /// among them) tell Accessibility next to nothing about the conversation on show.
    public static let fewLines = 3

    /// The same box with the conversation read from a picture of the window (Vision, on this Mac; the picture isn't
    /// kept): the lines over the box, in the box's own column, each where it is, so whose message is whose can be
    /// told by side. Nil when Screen Recording isn't allowed, or the picture has no more to read than was read.
    @MainActor
    public static func readPicture(_ context: Context, field: AXUIElement) async -> Context? {
        pictureNote = ""
        guard let box = frame(of: field) else { pictureNote = "the box has no place on the screen"; return nil }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            pictureNote = "no picture: Screen Recording isn't allowed, or nothing is on screen"
            return nil
        }
        // The window the box is in: of the app's windows, the smallest that holds it (a full-screen app can also
        // have a strip of a window for its toolbar). None found: the display it's on (the app is in front).
        let middle = CGPoint(x: box.midX, y: box.midY)
        let windows = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.frame.contains(middle) }
        let filter: SCContentFilter, area: CGRect
        if let window = windows.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            area = window.frame
        } else if let display = content.displays.first(where: { $0.frame.contains(middle) }) ?? content.displays.first {
            filter = SCContentFilter(display: display, excludingWindows: [])
            area = display.frame
        } else {
            pictureNote = "no picture: no window or display holds the box"
            return nil
        }
        let configuration = SCStreamConfiguration()
        let scale = min(NSScreen.main?.backingScaleFactor ?? 2, 2600 / max(area.width, area.height))
        configuration.width = max(1, Int(area.width * scale))
        configuration.height = max(1, Int(area.height * scale))
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            pictureNote = "no picture: the capture failed"
            return nil
        }
        func place(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))" }
        pictureNote = "box \(place(box)); picture of \(windows.isEmpty ? "the display" : "its window") \(place(area)), "
            + "\(image.width)×\(image.height) px"
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations: [VNRecognizedTextObservation] = await Task.detached(priority: .userInitiated) {
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
            return request.results ?? []
        }.value
        var pieces: [Piece] = []
        var all = 0
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.count > 1 else { continue }
            let b = observation.boundingBox   // 0…1, from the bottom-left of the picture
            let frame = CGRect(x: area.minX + b.minX * area.width, y: area.minY + (1 - b.maxY) * area.height,
                               width: b.width * area.width, height: b.height * area.height)
            all += 1
            // The conversation's column only (not a list of chats beside it), and not what's typed in the box.
            guard frame.midX >= box.minX - 80, frame.midX <= box.maxX + 80, !box.insetBy(dx: -4, dy: -4).contains(frame)
            else { continue }
            pieces.append(Piece(text: text, frame: frame))
        }
        let (above, below) = arrange(pieces, field: box)
        pictureNote += "; \(all) lines of text in it, \(pieces.count) in the box's column, \(above.count) above the box"
        guard above.count > context.above.count else { return nil }
        return Context(app: context.app, title: context.title, above: above, below: below, draft: context.draft,
                       selection: context.selection, sides: sides(of: above, pieces: pieces, field: box))
    }

    /// Browsers: a box in one is written in only when it's on the page.
    static let browsers = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
                           "org.mozilla.firefox", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                           "com.kagi.kagimacOS"]

    /// The nearest element above this one with that role (the page a box is on, the toolbar it's in).
    @MainActor
    static func ancestor(of element: AXUIElement, role wanted: String, levels: Int = 40) -> AXUIElement? {
        var current: AXUIElement? = ScreenReader.attribute(element, kAXParentAttribute)
        var climbed = 0
        while let node = current, climbed < levels {
            let role: String = ScreenReader.attribute(node, kAXRoleAttribute) ?? ""
            if role == wanted { return node }
            if role == "AXWindow" || role == "AXApplication" { return nil }
            current = ScreenReader.attribute(node, kAXParentAttribute)
            climbed += 1
        }
        return nil
    }

    /// A box that takes typing: a text field or area that isn't a password, or web content that says it's editable.
    @MainActor
    static func isWritable(_ element: AXUIElement) -> Bool {
        let role: String = ScreenReader.attribute(element, kAXRoleAttribute) ?? ""
        let subrole: String = ScreenReader.attribute(element, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return false }
        var settable = DarwinBoolean(false)
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        var editable: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editable) == .success && editable != nil
    }

    @MainActor
    static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// The window's words with where each is: static text, other text areas, headings, cells. At most 2,500 elements
    /// within half a second; password fields, the page's navigation and side panels, and the box itself left out.
    @MainActor
    /// `labels`: also what elements are described as, not only the text they hold. Some apps (WhatsApp) put a
    /// message's words in its description for VoiceOver ("message, Try karta hu, 6:26 PM, Received from Rahul") and
    /// nowhere else.
    static func pieces(in window: AXUIElement, skipping field: AXUIElement, within seconds: TimeInterval = 0.5,
                       labels: Bool = false) -> [Piece] {
        var found: [Piece] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        let deadline = Date().addingTimeInterval(seconds)
        while !queue.isEmpty, visited < 2500, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if CFEqual(element, field) { continue }
            let role: String = ScreenReader.attribute(element, kAXRoleAttribute) ?? ""
            let subrole: String = ScreenReader.attribute(element, kAXSubroleAttribute) ?? ""
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" || ScreenText.chrome.contains(subrole) { continue }
            if ["AXStaticText", "AXTextArea", "AXHeading", "AXCell"].contains(role),
               let value: String = ScreenReader.attribute(element, kAXValueAttribute),
               let frame = Self.frame(of: element) {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > 1 { found.append(Piece(text: text, frame: frame)) }
            } else if labels, !["AXWindow", "AXApplication", "AXScrollArea", "AXSplitGroup", "AXTextField"].contains(role),
                      let label: String = ScreenReader.attribute(element, kAXDescriptionAttribute)
                        ?? ScreenReader.attribute(element, kAXTitleAttribute),
                      let frame = Self.frame(of: element) {
                // A description that says something: a sentence, or a message described ("…, Received from …").
                let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > 1, saidBy(text) != nil || saysSomething(text) { found.append(Piece(text: text, frame: frame)) }
            }
            guard depth < 40, !["AXMenuBar", "AXMenu", "AXToolbar", "AXScrollBar"].contains(role) else { continue }
            if let children: [AXUIElement] = ScreenReader.attribute(element, kAXVisibleChildrenAttribute)
                ?? ScreenReader.attribute(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children.prefix(400).map { ($0, depth + 1) })
            }
        }
        return found
    }

    /// What's in the box now.
    @MainActor
    public static func text(in field: AXUIElement) -> String {
        ScreenReader.attribute(field, kAXValueAttribute) ?? ""
    }

    /// Selects everything in the box through Accessibility; false when the box doesn't take that (then ⌘A).
    @MainActor
    public static func selectAll(in field: AXUIElement) -> Bool {
        let length = (text(in: field) as NSString).length
        var range = CFRange(location: 0, length: length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            return false
        }
        let selected: String? = ScreenReader.attribute(field, kAXSelectedTextAttribute)
        return (selected as NSString?)?.length == length
    }

    /// Asks `router` and returns what goes in the box (nil: nothing usable, or no answer in `timeout` seconds).
    public static func write(_ context: Context, router: Router, me: [String], digest: String?, memory: String?,
                             timeout: TimeInterval = 25) async -> String? {
        await write(context, router: router, me: me, knowing: Knowledge(digest: digest, memory: memory), timeout: timeout).text
    }

    /// The same with all Murmur knows (`Knowledge`). What comes back is checked: a time, date, amount, link or
    /// address that's in nothing the model was given is made up, and it's asked once to write it again without
    /// (`rechecked`: what it had made up).
    public static func write(_ context: Context, router: Router, me: [String], knowing: Knowledge,
                             timeout: TimeInterval = 25) async -> (text: String?, rechecked: [String]) {
        let user = prompt(context, me: me, knowing: knowing)
        func ask(_ turns: [String], seconds: TimeInterval) async -> String? {
            await withTaskGroup(of: String?.self) { group in
                group.addTask { try? await router.chat(system: system, turns: turns.map { .user($0) }, tools: []).text }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        guard let first = await ask([user], seconds: timeout).flatMap({ clean($0, context: context) }) else { return (nil, []) }
        let made = unsupported(in: first, given: user)
        guard !made.isEmpty else { return (first, []) }
        // One more go, with what it made up pointed out; if that fails, the first answer stands.
        let again = await ask([user + "\n\n" + recheck(first, unsupported: made)], seconds: 12)
            .flatMap { clean($0, context: context) }
        return (again ?? first, made)
    }
}
