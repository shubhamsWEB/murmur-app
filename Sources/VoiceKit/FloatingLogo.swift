import AppKit
import SwiftUI

/// Murmur on screen: a small Starling pill you can drag anywhere (it stays where you leave it). Rest the pointer on
/// it and it opens into three round buttons, icons only: the starling (open Murmur), a microphone (dictate) and a
/// note (meeting notes; a coral stop square while they're being taken, when the small pill also shows a coral dot).
/// The one under the pointer is named in a small label above it. Right-click for the same and Hide. When
/// you dictate or give a command, this same pill opens into the listening pill, right where it is (the listening
/// pill grows out of it and shrinks back into it), so there's only ever one. The panel never takes the focus, so
/// dictation still goes into the app you were typing in.
@MainActor
final class FloatingLogo {
    var onOpen: (() -> Void)?
    var onStartDictation: (() -> Void)?
    /// Start meeting notes, or stop them when they're being taken.
    var onMeetingNotes: (() -> Void)?
    var onHide: (() -> Void)?

    private var panel: NSPanel?
    private var enabled = false
    /// The listening pill is showing (grown out of this one, in its place).
    private var pillShowing = false
    private let state = LogoState()
    /// Where the small pill sits (its bottom-left corner): the opened pill is centred on it.
    private var origin: NSPoint?
    private var opening: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    /// Opened, or on its way there (the pill itself follows a moment behind its window).
    private var wanted = false
    private var settling: DispatchWorkItem?
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

    /// Meeting notes are being taken (the pill shows it, and offers to stop them).
    func setMeeting(_ on: Bool) {
        guard state.meeting != on else { return }
        state.meeting = on
    }

    /// Where the small pill is on screen, for the listening pill to grow out of; nil when it's turned off.
    var anchor: NSRect? {
        guard enabled else { return nil }
        if panel == nil { update() }
        // The listening pill grows out of the small pill: an opened one is small again first.
        open(false, now: true)
        return origin.map { NSRect(origin: $0, size: LogoLayout.small) }
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
            place()
        }
        if pillShowing {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// After a display change or waking: put it back on a screen if its spot is gone.
    private func replace() {
        guard panel != nil else { return }
        place()
    }

    /// The pointer came to rest on the pill (it opens after a moment, so passing over it does nothing) or left it
    /// (it closes shortly after, so a slip off the edge doesn't snap it shut).
    private func hover(_ inside: Bool) {
        opening?.cancel()
        closing?.cancel()
        // Not while the listening pill is out in its place.
        if inside, pillShowing { return }
        let work = DispatchWorkItem { [weak self] in self?.open(inside) }
        if inside { opening = work } else { closing = work }
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.18 : 0.35), execute: work)
    }

    /// Opens it into its three buttons, or makes it small again. The window is made big first, with the pill still
    /// small and exactly where it was, and only then does the pill grow in it; closing, the pill shrinks first and
    /// the window follows. So the pill is never seen jumping to a new window's layout. `now`: no animation (a drag
    /// starting, the listening pill about to open out of it).
    private func open(_ on: Bool, now: Bool = false) {
        opening?.cancel()
        closing?.cancel()
        guard wanted != on || (now && !on && state.big) else { return }
        guard !(on && pillShowing) else { return }
        wanted = on
        settling?.cancel()
        settling = nil
        if on {
            quietly { state.big = true }
            layout()
            let grow = DispatchWorkItem { [weak self] in
                guard let self, self.wanted else { return }
                withAnimation(Self.motion) { self.state.open = true }
            }
            settling = grow
            DispatchQueue.main.async(execute: grow)
        } else if now {
            quietly {
                state.hot = nil
                state.open = false
                state.big = false
            }
            layout()
        } else {
            state.hot = nil
            withAnimation(Self.motion) { state.open = false }
            let shrink = DispatchWorkItem { [weak self] in
                guard let self, !self.wanted else { return }
                self.quietly { self.state.big = false }
                self.layout()
            }
            settling = shrink
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.motionSeconds + 0.04, execute: shrink)
        }
    }

    /// How the pill grows and shrinks: quick out of the blocks, a soft landing, no bounce.
    private static let motionSeconds = 0.26
    private static let motion = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: motionSeconds)

    /// A change that isn't animated.
    private func quietly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// The panel where it belongs: the small pill at `origin`, or the big window around it (the pill stays where it
    /// is on screen: `LogoLayout.below` under it for its shadow, the label's room above, and `state.shift` making up
    /// for a window the screen's edge pushed aside).
    private func layout() {
        guard let panel, let origin else { return }
        let small = NSRect(origin: origin, size: LogoLayout.small)
        guard state.big else {
            panel.setFrame(small, display: true)
            return
        }
        let size = LogoLayout.opened
        let ideal = NSRect(x: small.midX - size.width / 2, y: small.minY - LogoLayout.below, width: size.width, height: size.height)
        var frame = ideal
        if let area = NSScreen.screens.first(where: { $0.frame.intersects(small) })?.visibleFrame {
            frame.origin.x = min(max(frame.minX, area.minX + 4), area.maxX - size.width - 4)
            frame.origin.y = min(max(frame.minY, area.minY), area.maxY - size.height)
        }
        let shift = CGSize(width: ideal.minX - frame.minX, height: ideal.minY - frame.minY)
        if state.shift != shift { quietly { state.shift = shift } }
        panel.setFrame(frame, display: true)
    }

    private func make() -> NSPanel {
        let panel = LogoPanel(contentRect: NSRect(origin: .zero, size: LogoLayout.small),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        PrivateWindows.apply(panel)
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let host = LogoHost(rootView: LogoView(state: state))
        host.state = state
        host.onClick = { [weak self] zone in
            guard let self else { return }
            open(false)
            switch zone {
            case .murmur: onOpen?()
            case .dictate: onStartDictation?()
            case .notes: onMeetingNotes?()
            }
        }
        host.onHover = { [weak self] inside in self?.hover(inside) }
        host.onDragBegan = { [weak self] in self?.open(false, now: true) }
        host.onMoved = { [weak self] origin in self?.save(origin) }
        host.makeMenu = { [weak self] in
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Open Murmur") { self?.onOpen?() })
            menu.addItem(ClosureMenuItem("Start Dictation") { self?.onStartDictation?() })
            menu.addItem(ClosureMenuItem(self?.state.meeting == true ? "Stop Meeting Notes" : "Take Meeting Notes") {
                self?.onMeetingNotes?()
            })
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
    private func place() {
        let size = LogoLayout.small
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey).map(NSPointFromString) {
            let frame = NSRect(origin: saved, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(frame).width >= size.width / 2 }) {
                origin = saved
                layout()
                return
            }
        }
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 12)
        layout()
    }

    private func save(_ origin: NSPoint) {
        self.origin = origin
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.positionKey)
        layout()
        update()
    }
}

/// The pill's two sizes, and what's where in the opened one: three round buttons in a row (the starling, the
/// microphone, the note), with room above them for the label of the one under the pointer.
enum LogoLayout {
    /// The small pill's window, and the capsule drawn in it.
    static let small = NSSize(width: 48, height: 26)
    static let capsule = NSSize(width: 44, height: 22)
    static let button: CGFloat = 34
    /// The opened capsule: the same middle as the small one, a little taller.
    static let pill = NSSize(width: button * 3 + 4, height: 26)
    /// The big window: the opened capsule with the label's room above it and `below` under the small pill's window
    /// (so the opened capsule's shadow isn't cut off).
    static let opened = NSSize(width: 196, height: 66)
    static let below: CGFloat = 8
    /// The capsule's middle above the big window's bottom edge: where the small pill's middle is.
    static var middle: CGFloat { below + small.height / 2 }

    enum Zone: Int, CaseIterable { case murmur, dictate, notes }

    /// What's at `x` (points from the opened capsule's middle); nil beside the buttons.
    static func zone(fromMiddle x: CGFloat) -> Zone? {
        let inside = x + button * 1.5
        guard inside >= 0, inside < button * 3 else { return nil }
        return Zone(rawValue: Int(inside / button))
    }
}

/// What the pill shows: small or opened, which part the pointer is on, and whether meeting notes are being taken.
@MainActor
final class LogoState: ObservableObject {
    @Published var open = false
    /// The window is the big one (it is before the pill opens and until after it has closed).
    @Published var big = false
    /// How far the big window was pushed from where it would sit around the pill (a screen's edge).
    @Published var shift = CGSize.zero
    @Published var hot: LogoLayout.Zone?
    @Published var meeting = false
}

/// Never becomes key or main: clicking it leaves the focus where you were typing.
private final class LogoPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Resting the pointer on it opens it; a click does what's under the pointer (the small pill: open Murmur); pressing
/// and moving drags it (a few points of movement count as a drag, not a click); right-click shows the menu.
private final class LogoHost: NSHostingView<LogoView> {
    var state: LogoState?
    var onClick: ((LogoLayout.Zone) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var makeMenu: (() -> NSMenu)?

    private var downAt: NSPoint?
    private var startOrigin: NSPoint = .zero
    private var dragging = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if downAt == nil { onHover?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        state?.hot = nil
        if downAt == nil { onHover?(false) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let state, state.open else { return }
        let zone = zone(at: event)
        if state.hot != zone { state.hot = zone }
    }

    /// The button under the pointer in the opened pill (nil over the label's room above it, or beside it).
    private func zone(at event: NSEvent) -> LogoLayout.Zone? {
        guard let state else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let fromBottom = (isFlipped ? bounds.height - point.y : point.y) - state.shift.height
        guard abs(fromBottom - LogoLayout.middle) <= LogoLayout.pill.height / 2 + 4 else { return nil }
        return LogoLayout.zone(fromMiddle: point.x - bounds.width / 2 - state.shift.width)
    }

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
        if !dragging {
            // It's the small pill that's dragged: an opened one closes first, under the pointer.
            dragging = true
            onDragBegan?()
            startOrigin = NSPoint(x: downAt.x - LogoLayout.small.width / 2, y: downAt.y - LogoLayout.small.height / 2)
        }
        var origin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        // Kept on a screen: at least half of it stays visible.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(now, $0.frame, false) }) ?? window.screen {
            let area = screen.frame
            let size = LogoLayout.small
            origin.x = min(max(origin.x, area.minX - size.width / 2), area.maxX - size.width / 2)
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        }
        window.setFrame(NSRect(origin: origin, size: LogoLayout.small), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; dragging = false }
        if dragging {
            if let origin = window?.frame.origin { onMoved?(origin) }
        } else if downAt != nil {
            if state?.open == true {
                if let zone = zone(at: event) { onClick?(zone) }
            } else {
                onClick?(.murmur)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// The charcoal pill with the cream starling, the same look as the listening pill. One capsule the whole time: opening
/// widens it where it is (its middle doesn't move) and its three round buttons fade in as the starling fades out;
/// the one under the pointer is lit and named in a small label above.
private struct LogoView: View {
    @ObservedObject var state: LogoState

    var body: some View {
        let size = state.open ? LogoLayout.pill : LogoLayout.capsule
        ZStack {
            Capsule()
                .fill(Palette.ink.opacity(0.94))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
            // What's in it is cut to its shape, so the buttons appear as it widens over them.
            ZStack {
                // Small: the starling, and a coral dot while meeting notes are being taken.
                HStack(spacing: 5) {
                    StarlingMark(.mono(Palette.cream), listening: false).frame(width: 16, height: 16)
                    if state.meeting { Circle().fill(Palette.coral).frame(width: 6, height: 6) }
                }
                .opacity(state.open ? 0 : 1)
                // Opened: the three, laid out at full size the whole time.
                HStack(spacing: 0) {
                    ForEach(LogoLayout.Zone.allCases, id: \.rawValue) { zone in
                        icon(zone)
                            .frame(width: LogoLayout.button - 6, height: LogoLayout.pill.height - 6)
                            .background(Capsule().fill(Color.white.opacity(state.hot == zone ? 0.14 : 0)))
                            .frame(width: LogoLayout.button)
                    }
                }
                .fixedSize()
                .opacity(state.open ? 1 : 0)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(Capsule())
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) { label.offset(y: -28) }
        // In the small window it's in the middle; in the big one, where the small window's middle is.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.big ? .bottom : .center)
        .padding(.bottom, state.big ? LogoLayout.middle - size.height / 2 + state.shift.height : 0)
        .offset(x: state.big ? state.shift.width : 0)
    }

    /// The name of the button under the pointer, above it.
    @ViewBuilder private var label: some View {
        if state.open, let hot = state.hot {
            Text(name(hot))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.cream)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Palette.ink.opacity(0.94)))
                .offset(x: CGFloat(hot.rawValue - 1) * LogoLayout.button)
                .transition(.opacity.animation(.easeOut(duration: 0.1)))
        }
    }

    @ViewBuilder private func icon(_ zone: LogoLayout.Zone) -> some View {
        switch zone {
        case .murmur:
            StarlingMark(.mono(Palette.cream), listening: false).frame(width: 16, height: 16)
        case .dictate:
            Image(systemName: "mic.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.cream)
        case .notes:
            if state.meeting {
                RoundedRectangle(cornerRadius: 2.5).fill(Palette.coral).frame(width: 10, height: 10)
            } else {
                Image(systemName: "note.text").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.cream)
            }
        }
    }

    private func name(_ zone: LogoLayout.Zone) -> String {
        switch zone {
        case .murmur: return "Open Murmur"
        case .dictate: return "Dictate"
        case .notes: return state.meeting ? "Stop meeting notes" : "Take meeting notes"
        }
    }
}
