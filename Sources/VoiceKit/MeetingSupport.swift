import AgentKit
import AppKit
import Carbon.HIToolbox
import PDFKit
import ScreenCaptureKit

/// The text of a document you give meeting notes (an agenda, a spec, notes): plain text and Markdown, PDF, Word,
/// RTF and web pages. Read on this Mac.
enum MeetingDocuments {
    static let limit = 30_000

    static func text(_ url: URL) -> String? {
        let text: String?
        switch url.pathExtension.lowercased() {
        case "pdf":
            text = PDFDocument(url: url)?.string
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive":
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        default:
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }
}

/// A picture of the meeting: the meeting app's biggest window (where a shared slide or chart shows), or the front
/// window when no meeting app is known. Murmur's own windows are never in it. Needs Screen Recording.
@MainActor
enum MeetingScreen {
    struct Picture {
        let jpeg: Data
        let image: CGImage
        let title: String
    }

    static func capture(bundle: String?) async -> Picture? {
        if let bundle, let picture = await window(of: bundle) { return picture }
        guard let shot = await ScreenControl.shoot(maxSide: 1600) else { return nil }
        return Picture(jpeg: shot.jpeg, image: shot.image, title: "\(shot.app) — \(shot.window)")
    }

    private static func window(of bundle: String) async -> Picture? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter { window in
            guard let app = window.owningApplication, app.processID != own, window.windowLayer == 0,
                  window.frame.width > 200, window.frame.height > 150 else { return false }
            return app.bundleIdentifier == bundle || app.bundleIdentifier.hasPrefix(bundle + ".")
        }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let frame = window.frame
        let scale = min(NSScreen.main?.backingScaleFactor ?? 2, 1600 / max(frame.width, frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(frame.width * scale))
        configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return nil }
        return Picture(jpeg: jpeg, image: image, title: "\(window.owningApplication?.applicationName ?? "") — \(window.title ?? "")")
    }
}

/// Whether this Mac's screen capture can see a window that's set to be left out (macOS 15 and later let apps that
/// capture with ScreenCaptureKit see such windows). Captures the window's area with it hidden twice (how much the
/// screen behind changes by itself) and shown once, and compares: if showing it changes the capture, it's seen.
/// The window disappears for about a quarter of a second while this runs. Needs Screen Recording.
@MainActor
enum ShareCheck {
    enum Verdict: Equatable {
        case hidden
        case visible
        case unknown(String)
    }

    static func run(_ window: NSWindow) async -> Verdict {
        guard window.isVisible, let screen = window.screen ?? NSScreen.main else { return .unknown("the panel isn't on screen") }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return .unknown("Screen Recording isn't allowed for Murmur, so this couldn't be checked")
        }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let display = content.displays.first(where: { $0.displayID == number?.uint32Value }) ?? content.displays.first
        else { return .unknown("no display to capture") }
        // The window's area on its display, from the display's top left.
        let frame = window.frame, screenFrame = screen.frame
        let area = CGRect(x: frame.minX - screenFrame.minX, y: screenFrame.maxY - frame.maxY,
                          width: frame.width, height: frame.height)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area
        configuration.width = 64
        configuration.height = max(16, Int(64 * area.height / max(area.width, 1)))
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        func grab() async -> [UInt8]? {
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                         configuration: configuration) else { return nil }
            return pixels(image)
        }
        let alpha = window.alphaValue
        window.alphaValue = 0
        try? await Task.sleep(nanoseconds: 120_000_000)
        let first = await grab()
        let second = await grab()
        // Fully shown for the last capture (a see-through panel would change the picture less).
        window.alphaValue = 1
        try? await Task.sleep(nanoseconds: 150_000_000)
        let shown = await grab()
        window.alphaValue = alpha
        guard let first, let second, let shown else { return .unknown("the screen couldn't be captured") }
        let noise = MeetingText.changedFraction(first, second)
        let change = MeetingText.changedFraction(second, shown)
        if change > max(0.3, noise + 0.25) { return .visible }
        if change <= noise + 0.05 { return .hidden }
        return .unknown("the screen behind the panel was changing too much to tell")
    }

    /// An image's pixels as RGBA bytes, at its own size.
    private static func pixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}

/// ⌥⌘↩ while meeting notes run: answer what was just said now, without waiting. A system-wide hotkey (Carbon's,
/// which needs no permission), registered only while notes run. Murmur's other hotkey handler sees the presses
/// that aren't this one.
@MainActor
final class MeetingHotkey {
    static let display = "⌥⌘↩"
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    nonisolated fileprivate static let signature = OSType(0x4D_45_45_54)   // "MEET"

    init?(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), meetingHotkeyPressed, 1, &spec, me, &handler) == noErr
        else { return nil }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Return), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(),
                                         0, &hotKey)
        guard status == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return nil
        }
    }

    func invalidate() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    fileprivate func fire() { action() }
}

/// Carbon delivers hotkey events on the main thread. Another hotkey's press goes on to the next handler.
private func meetingHotkeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                  _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == MeetingHotkey.signature else { return OSStatus(eventNotHandledErr) }
    let address = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        Unmanaged<MeetingHotkey>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue().fire()
    }
    return noErr
}
