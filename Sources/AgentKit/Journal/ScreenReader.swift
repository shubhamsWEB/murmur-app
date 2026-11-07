import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import Vision

/// Reads the window you're working in, for screen memory: its text through Accessibility (cheap: no picture), and only
/// when that shows little (a canvas, a design tool, an image, a video, a remote desktop) a picture of that one window,
/// read by Apple Vision on this Mac: its words and what it shows. Never reads password managers, private windows,
/// password fields, or anything while a password is being typed.
public enum ScreenReader {
    /// Apps never read: password managers, Murmur, the login window and screen saver.
    public static let neverRead: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.copico.Murmur", "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.SecurityAgent",
        "org.keepassxc.keepassxc", "com.apple.systempreferences",
    ]

    /// Window titles of private browsing.
    static let privateWindow = ["private browsing", "incognito", "inprivate", "private window", "— private"]

    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "app.zen-browser.zen",
        "ai.perplexity.comet", "com.openai.atlas",
    ]

    public typealias Rules = ScreenRules

    /// Why a window isn't read, or nil when it may be.
    public static func skip(bundle: String, title: String, domain: String, rules: Rules) -> String? {
        if neverRead.contains(bundle) { return "never read" }
        if rules.excluded.contains(where: { $0 == bundle || (!domain.isEmpty && (domain == $0 || domain.hasSuffix("." + $0))) }) {
            return "excluded"
        }
        let lower = title.lowercased()
        if privateWindow.contains(where: lower.contains) { return "private window" }
        if SecureInput.passwordFocused() { return "a password is being typed" }
        return nil
    }

    /// The front window as it is now, and what's being written in it (the focused message box or document, not yet
    /// sent), or nil when it isn't read (or there's nothing in it).
    @MainActor
    public static func capture(rules: Rules, plugged: Bool) async -> (capture: Journal.Capture, draft: String, boxes: [String])? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              !neverRead.contains(bundle) else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.4)   // a hung app can't hold Murmur up
        guard let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute) else { return nil }
        let title: String = attribute(window, kAXTitleAttribute) ?? ""
        let url = browsers.contains(bundle) ? pageAddress(in: window) : nil
        // The file it shows, when the app says (a document, a source file): what it's part of comes from its folder.
        let document = browsers.contains(bundle) ? nil
            : (attribute(window, kAXDocumentAttribute) as String?).flatMap(ScreenText.documentPath)
        let domain = Journal.Capture(app: "", bundle: "", title: "", url: url, text: "").domain
        guard skip(bundle: bundle, title: title, domain: domain, rules: rules) == nil else { return nil }
        let name = ScreenText.appName(app.localizedName ?? bundle)
        var boxes: [String] = []
        var text = ScreenText.clean(Self.text(of: window, boxes: &boxes))
        var via = "text", labels = ""
        // Little text to go on: a picture of the window, read on this Mac.
        if words(text) < 25, rules.pictures, let read = await picture(of: app, accurate: plugged) {
            if words(read.text) > words(text) {
                text = read.text
                via = "image"
            }
            labels = read.labels
        }
        guard words(text) >= 5 || !labels.isEmpty else { return nil }
        let kind = WindowKind.of(app: name, domain: domain, url: url, title: title, text: text)
        // A terminal's newest lines are at the bottom: keep those (the top is old scrollback). Elsewhere, the top.
        // Its secrets (keys exported, a .env printed) are taken out before anything is kept.
        let kept = ItemReader.terminals.contains(name) ? BrainModel.redact(String(text.suffix(16_000))) : String(text.prefix(16_000))
        let capture = Journal.Capture(app: name, bundle: bundle, title: ScreenText.appName(title), url: url, text: kept,
                                      via: via, labels: labels, kind: kind.rawValue, document: document)
        return (capture, rules.authored ? draft(in: element) : "", boxes)
    }

    /// What's in the focused text box (a message being written, a document being edited), never a password field.
    static func draft(in app: AXUIElement) -> String {
        guard let focused: AXUIElement = attribute(app, kAXFocusedUIElementAttribute) else { return "" }
        let role: String = attribute(focused, kAXRoleAttribute) ?? ""
        let subrole: String = attribute(focused, kAXSubroleAttribute) ?? ""
        guard ["AXTextArea", "AXTextField", "AXComboBox"].contains(role), subrole != "AXSecureTextField",
              let value: String = attribute(focused, kAXValueAttribute) else { return "" }
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    }

    /// A small JPEG of the app's front window, for the vision model: at most `side` pixels on its long side. Nil
    /// without Screen Recording permission.
    static func thumbnail(of app: NSRunningApplication, side: Int) async -> Data? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.filter({
                  $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 200
              }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(1, CGFloat(side) / max(window.frame.width, window.frame.height))
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    /// Whether an app still has a window of this title ("Mail|Re: the deck"): a compose window that's gone was sent.
    @MainActor
    static func windowExists(_ key: String) -> Bool {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let app = NSWorkspace.shared.runningApplications.first(where: {
            ScreenText.appName($0.localizedName ?? "") == parts[0]
        }) else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
        // Titles compared as read (a compose window titled with an emoji has invisible joiners in it).
        return windows.contains { ScreenText.appName((attribute($0, kAXTitleAttribute) as String?) ?? "") == ScreenText.appName(parts[1]) }
    }

    /// What's in the focused text box of the front app, alone (a glance, not a read of the window).
    @MainActor
    static func frontDraft() -> String {
        guard let app = frontApp() else { return "" }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        return draft(in: element)
    }

    /// The front app, when screen memory may read it.
    @MainActor
    static func frontApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              !neverRead.contains(bundle) else { return nil }
        return app
    }

    static func words(_ text: String) -> Int { text.split { $0.isWhitespace }.count }

    // MARK: Accessibility

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// The window's words, top to bottom: static text, text areas, headings, links, buttons' titles. At most 2,500
    /// elements and 16,000 characters, within half a second; password fields are skipped.
    static func text(of window: AXUIElement) -> String {
        var boxes: [String] = []
        return text(of: window, boxes: &boxes)
    }

    /// The same, and what's in the window's text boxes (`boxes`): a message being written is in the window's text too,
    /// and isn't sent while it's still in its box.
    static func text(of window: AXUIElement, boxes: inout [String]) -> String {
        var lines: [(text: String, control: Bool)] = []
        var seen = Set<String>()
        // A page that marks its main content (most do): only that, not the app around it.
        var queue: [(AXUIElement, Int)] = [(main(in: window) ?? window, 0)]
        var visited = 0, length = 0
        let deadline = Date().addingTimeInterval(0.5)
        while !queue.isEmpty, visited < 2500, length < 16_000, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            let subrole: String = attribute(element, kAXSubroleAttribute) ?? ""
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" { continue }
            // A page's navigation, header, footer and side panels (a chat list, a feed's sidebar): not what you worked on.
            if ScreenText.chrome.contains(subrole) { continue }
            var parts: [String] = []
            switch role {
            case "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXCell":
                if let value: String = attribute(element, kAXValueAttribute) {
                    parts.append(value)
                    // Only a box that can be typed in (some apps show messages in read-only text areas).
                    var editable = DarwinBoolean(false)
                    if role == "AXTextArea" || role == "AXTextField", boxes.count < 20, !value.isEmpty,
                       AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable) == .success, editable.boolValue {
                        boxes.append(String(value.prefix(4000)))
                    }
                }
            case "AXLink", "AXButton", "AXMenuButton", "AXTab", "AXRadioButton", "AXCheckBox":
                if let title: String = attribute(element, kAXTitleAttribute) { parts.append(title) }
            default: break
            }
            if parts.isEmpty, role != "AXGroup", let description: String = attribute(element, kAXDescriptionAttribute) {
                parts.append(description)
            }
            for part in parts {
                let line = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.count > 1, seen.insert(line).inserted else { continue }
                lines.append((line, role != "AXStaticText" && role != "AXTextArea" && role != "AXHeading"))
                length += line.count
            }
            // Menus and toolbars repeat on every window: not what you worked on.
            guard depth < 40, !["AXMenuBar", "AXMenu", "AXToolbar", "AXScrollBar"].contains(role) else { continue }
            if let children: [AXUIElement] = attribute(element, kAXVisibleChildrenAttribute) ?? attribute(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children.prefix(400).map { ($0, depth + 1) })
            }
        }
        return ScreenText.content(lines).joined(separator: "\n")
    }

    /// The window's main content area (a web page's or Electron app's `main` landmark), when it says.
    static func main(in window: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if (attribute(element, kAXSubroleAttribute) as String?) == "AXLandmarkMain" { return element }
            guard depth < 12, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { continue }
            queue.append(contentsOf: children.prefix(80).map { ($0, depth + 1) })
        }
        return nil
    }

    /// A browser window's page address: its web area's AXURL (Safari, Chrome, Arc, Edge, Brave all say it).
    static func pageAddress(in window: AXUIElement) -> String? {
        if let document: String = attribute(window, kAXDocumentAttribute), document.hasPrefix("http") { return document }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if (attribute(element, kAXRoleAttribute) as String?) == "AXWebArea" {
                if let url: URL = attribute(element, kAXURLAttribute) { return url.absoluteString }
                if let url: NSURL = attribute(element, kAXURLAttribute) { return url.absoluteString }
            }
            guard depth < 8, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { continue }
            queue.append(contentsOf: children.prefix(60).map { ($0, depth + 1) })
        }
        return nil
    }

    // MARK: Picture

    /// The words in a picture of the app's front window, and what it shows ("chart, document"): Apple Vision, the way
    /// file search reads photos. Fast recognition on battery, accurate when plugged in. Nil without Screen Recording
    /// permission (screen memory never asks for it by itself: "look at my screen" does).
    static func picture(of app: NSRunningApplication, accurate: Bool) async -> (text: String, labels: String)? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return nil
        }
        let windows = content.windows.filter {
            $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 200
        }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            return nil
        }
        let configuration = SCStreamConfiguration()
        // At most 1,600 pixels on the long side: enough to read, a fraction of the work of a full Retina picture.
        let scale = min(2, 1600 / max(window.frame.width, window.frame.height))
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) else { return nil }
        let words = VNRecognizeTextRequest()
        words.recognitionLevel = accurate ? .accurate : .fast
        words.usesLanguageCorrection = accurate
        let classify = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([words, classify])
        let text = (words.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let labels = (classify.results ?? []).filter { $0.confidence > 0.35 }.prefix(5)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
        return (text, labels)
    }
}
