import AppKit
import ApplicationServices
import Foundation

/// The parts of "write it for me" that need the Mac: reading the box and the window round it through Accessibility,
/// and asking the model.
extension ReplyWriter {
    // MARK: Reading the window

    /// The focused text box of the front app and what's around it, or nil when the focus isn't a box Murmur may
    /// write in (a password field, a page that isn't editable, a password manager, Murmur itself).
    @MainActor
    public static func read() -> (context: Context, field: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              !ScreenReader.neverRead.contains(bundle), app != NSRunningApplication.current else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.4)
        guard let field: AXUIElement = ScreenReader.attribute(element, kAXFocusedUIElementAttribute),
              isWritable(field), let fieldFrame = frame(of: field) else { return nil }
        // A box in a toolbar (an address bar, a search field) is for finding things, not writing to someone. In a
        // browser, only a box on the page counts, and only the page is read: not its tabs, bookmarks or sidebar.
        if ancestor(of: field, role: "AXToolbar") != nil { return nil }
        let page = ancestor(of: field, role: "AXWebArea")
        if page == nil, browsers.contains(where: { bundle == $0 || bundle.hasPrefix($0 + ".") }) { return nil }
        let window: AXUIElement? = ScreenReader.attribute(element, kAXFocusedWindowAttribute)
        let title: String = window.flatMap { ScreenReader.attribute($0, kAXTitleAttribute) } ?? ""
        let pieces = (page ?? window).map { pieces(in: $0, skipping: field) } ?? []
        let (above, below) = arrange(pieces, field: fieldFrame)
        let draft: String = ScreenReader.attribute(field, kAXValueAttribute) ?? ""
        let selected: String? = ScreenReader.attribute(field, kAXSelectedTextAttribute)
        let context = Context(app: ScreenText.appName(app.localizedName ?? bundle), title: ScreenText.appName(title),
                              above: above, below: below, draft: String(draft.prefix(4000)),
                              selection: selected.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
        return (context, field)
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
    static func pieces(in window: AXUIElement, skipping field: AXUIElement) -> [Piece] {
        var found: [Piece] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        let deadline = Date().addingTimeInterval(0.5)
        while !queue.isEmpty, visited < 2500, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if CFEqual(element, field) { continue }
            let role: String = ScreenReader.attribute(element, kAXRoleAttribute) ?? ""
            let subrole: String = ScreenReader.attribute(element, kAXSubroleAttribute) ?? ""
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" || ScreenText.chrome.contains(subrole) { continue }
            if ["AXStaticText", "AXTextArea", "AXHeading", "AXCell"].contains(role),
               let value: String = ScreenReader.attribute(element, kAXValueAttribute),
               let frame = frame(of: element) {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > 1 { found.append(Piece(text: text, frame: frame)) }
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
        let user = prompt(context, me: me, digest: digest, memory: memory)
        let answer: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await router.chat(system: system, turns: [.user(user)], tools: []).text }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return answer.flatMap { clean($0, context: context) }
    }
}
