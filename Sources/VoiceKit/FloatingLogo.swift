import AppKit
import SwiftUI

/// Murmur on screen: a small Starling pill you can drag anywhere (it stays where you leave it). Click it to open
/// Murmur; right-click for Start Dictation or Hide. When you dictate or give a command, this same pill opens into
/// the listening pill, right where it is (the listening pill grows out of it and shrinks back into it), so there's
/// only ever one. The panel never takes the focus, so dictation still goes into the app you were typing in.
@MainActor
final class FloatingLogo {
    var onOpen: (() -> Void)?
    var onStartDictation: (() -> Void)?
    var onHide: (() -> Void)?

    private var panel: NSPanel?
    private var enabled = false
    /// The listening pill is showing (grown out of this one, in its place).
    private var pillShowing = false
    private static let positionKey = "floatingLogo.origin"

    init() {
        let replace: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.replace() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main, using: replace)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main, using: replace)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        update()
    }

    /// Where the pill is on screen, for the listening pill to grow out of; nil when it's turned off.
    var anchor: NSRect? {
        guard enabled else { return nil }
        if panel == nil { update() }
        return panel?.frame
    }

    /// The listening pill appeared (its frame) or went away (nil): this one hides while it's out, since the
    /// listening pill is this pill, opened.
    func pillMoved(_ frame: NSRect?) {
        pillShowing = frame != nil
        update()
    }

    private func update() {
        guard enabled else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? make()
        if self.panel == nil {
            self.panel = panel
            place(panel)
        }
        if pillShowing {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// After a display change or waking: put it back on a screen if its spot is gone.
    private func replace() {
        guard let panel else { return }
        place(panel)
    }

    private func make() -> NSPanel {
        let panel = LogoPanel(contentRect: NSRect(x: 0, y: 0, width: 48, height: 26),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let host = LogoHost(rootView: LogoView())
        host.onClick = { [weak self] in self?.onOpen?() }
        host.onMoved = { [weak self] origin in self?.save(origin) }
        host.makeMenu = { [weak self] in
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Open Murmur") { self?.onOpen?() })
            menu.addItem(ClosureMenuItem("Start Dictation") { self?.onStartDictation?() })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Hide Murmur Button") { self?.onHide?() })
            return menu
        }
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Where you last left it, if that's still on a screen; otherwise bottom centre of the main screen, above the
    /// Dock.
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey).map(NSPointFromString) {
            let frame = NSRect(origin: saved, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(frame).width >= size.width / 2 }) {
                panel.setFrameOrigin(saved)
                return
            }
        }
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 12))
    }

    private func save(_ origin: NSPoint) {
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.positionKey)
        update()
    }
}

/// Never becomes key or main: clicking it leaves the focus where you were typing.
private final class LogoPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click opens Murmur; pressing and moving drags it (a few points of movement count as a drag, not a click);
/// right-click shows the menu.
private final class LogoHost: NSHostingView<LogoView> {
    var onClick: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var makeMenu: (() -> NSMenu)?

    private var downAt: NSPoint?
    private var startOrigin: NSPoint = .zero
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - downAt.x
        let dy = now.y - downAt.y
        if !dragging, dx * dx + dy * dy < 9 { return }
        dragging = true
        var origin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        // Kept on a screen: at least half of it stays visible.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(now, $0.frame, false) }) ?? window.screen {
            let area = screen.frame
            let size = window.frame.size
            origin.x = min(max(origin.x, area.minX - size.width / 2), area.maxX - size.width / 2)
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; dragging = false }
        if dragging {
            if let origin = window?.frame.origin { onMoved?(origin) }
        } else if downAt != nil {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// The charcoal pill with the cream starling, the same look as the listening pill.
private struct LogoView: View {
    var body: some View {
        ZStack {
            Capsule()
                .fill(Palette.ink.opacity(0.94))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
            StarlingMark(.mono(Palette.cream), listening: false)
                .frame(width: 16, height: 16)
        }
        .padding(2)
        .help("Click to open Murmur · drag to move · right-click for more")
    }
}
