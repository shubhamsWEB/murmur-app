import AppKit
import SwiftUI

/// The pill that shows Murmur is listening, then working. With the Murmur button on screen, it grows out of that
/// button, where it is (and shrinks back into it when done), so there's one pill, not two; otherwise it appears
/// near the bottom of the screen, opening out of a small Starling pill the same way.
@MainActor
final class DictationHUD {
    /// What a message is: something done, something to know, or something that went wrong.
    enum Tone: Equatable {
        case done, info, problem
    }

    enum Mode: Equatable {
        case listening(handsFree: Bool)
        case command
        /// ⇧ with the talk key: what you say is typed, never run as a command.
        case typingOnly(handsFree: Bool)
        /// The key is down but the microphone isn't on yet (a Bluetooth headset waking): wait before speaking.
        case startingMic
        case working(String)
        case transcribing
        case preparing
        case message(String, Tone)
    }

    private let state = HUDState()
    private var hideWork: DispatchWorkItem?
    /// Bumped by every open and close, so a step scheduled for one never acts on the next.
    private var generation = 0
    /// Told where the pill is when it appears, and nil when it goes away: the floating button hides while it's out.
    var onVisible: ((NSRect?) -> Void)?
    /// Where the floating Murmur button is, if it's on: the pill opens out of it.
    var anchor: (() -> NSRect?)?

    static let panelSize = NSSize(width: 480, height: 48)
    /// Room round the pill for its shadow.
    static let inset: CGFloat = 12

    private var panelStorage: NSPanel?
    private var panel: NSPanel {
        if let panelStorage { return panelStorage }
        let made = Self.makePanel(state: state)
        panelStorage = made
        return made
    }

    init() {
        // After a display change or waking from sleep the pill's window can be left stranded (on a screen or Space
        // that's gone): build a fresh one the next time it's needed.
        let reset: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main, using: reset)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main, using: reset)
    }

    /// Builds the window ahead of time, so the first press of the key shows the pill at once.
    func prewarm() {
        _ = panel
    }

    private func reset() {
        guard let old = panelStorage else { return }
        if old.isVisible { place(); return }
        old.close()
        panelStorage = nil
    }

    private static func makePanel(state: HUDState) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the pill draws its own: the window's would outline the empty panel's edges
        // Above full-screen apps too: a panel high enough to sit over them, on every Space, that never hides
        // because Murmur isn't the active app (NSPanel hides on deactivate by default).
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HUDView(state: state))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    func show(_ mode: Mode) {
        hideWork?.cancel()
        hideWork = nil
        generation += 1
        state.mode = mode
        state.level = 0
        let opening = !panel.isVisible
        if opening {
            // Starts as the small pill (the floating button's size and look, in its place), then opens.
            state.expanded = false
            place()
        }
        panel.orderFrontRegardless()
        if !panel.isVisible || !panel.isOnActiveSpace {
            // The old window didn't come back: replace it.
            panelStorage?.close()
            panelStorage = nil
            place()
            panel.orderFrontRegardless()
        }
        if opening || !state.expanded {
            // Drawn closed first (the button's twin, on top of it), then the button goes and the pill opens: the
            // two windows overlap for a frame rather than leave a gap.
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            let frame = panel.frame
            let shown = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, self.generation == shown else { return }
                self.onVisible?(frame)
                self.state.expanded = true
            }
        } else {
            onVisible?(panel.frame)
        }
    }

    /// Showing a "working" line (cleared when the command finishes).
    var isWorking: Bool {
        if case .working = state.mode { return panel.isVisible }
        return false
    }

    func setLevel(_ level: Float) {
        state.level = level
    }

    /// Shows a short message, then hides. Without a tone, words like "can't" or "failed" make it a problem and
    /// anything else plain information.
    func flash(_ text: String, seconds: Double = 2.5, tone: Tone? = nil) {
        show(.message(text, tone ?? Self.tone(of: text)))
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func tone(of text: String) -> Tone {
        let problem = #"(?i)\b(can'?t|cannot|couldn'?t|didn'?t|doesn'?t|isn'?t|won'?t|failed|failure|error|rejected|stopped|needs|denied|not allowed|no access|unable)\b|^no "#
        return text.range(of: problem, options: .regularExpression) != nil ? .problem : .info
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        close()
    }

    /// Shrinks back into the small pill, then goes; the floating button (its twin, in the same place) comes back
    /// a frame before the pill leaves, so there's no gap.
    private func close() {
        generation += 1
        guard let panel = panelStorage, panel.isVisible else {
            onVisible?(nil)
            return
        }
        state.expanded = false   // the view closes it on its own curve
        let closing = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == closing else { return }
            self.onVisible?(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, self.generation == closing else { return }
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
    }

    /// Out of the floating button when it's on: the small pill exactly where the button is, opening away from the
    /// nearest screen edge (to the right of a button on the left, to the left of one on the right, both ways in the
    /// middle). Otherwise bottom centre of the screen the mouse is on.
    private func place() {
        let size = Self.panelSize
        if let button = anchor?() {
            let screen = NSScreen.screens.first { $0.frame.intersects(button) } ?? NSScreen.main
            let area = screen?.frame ?? button
            let third = area.width / 3
            let x: CGFloat
            if button.midX < area.minX + third {
                state.alignment = .leading
                x = button.minX + 2 - Self.inset          // the pill's left edge on the button's
            } else if button.midX > area.maxX - third {
                state.alignment = .trailing
                x = button.maxX - 2 + Self.inset - size.width
            } else {
                state.alignment = .center
                x = button.midX - size.width / 2
            }
            panel.setFrame(NSRect(x: x, y: button.midY - size.height / 2, width: size.width, height: size.height),
                           display: false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        state.alignment = .center
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 72, width: size.width, height: size.height),
                       display: false)
    }
}

@MainActor
final class HUDState: ObservableObject {
    @Published var mode: DictationHUD.Mode = .transcribing
    @Published var level: Float = 0
    /// Open (the whole pill) or closed (the small Starling pill it grows out of and shrinks back into).
    @Published var expanded = false
    /// Which way it opens: from the button's left edge, its right edge, or both ways.
    @Published var alignment: HorizontalAlignment = .center
}

/// The listening pill: a charcoal capsule whose coral dot breathes with your voice.
///
/// It opens out of the small Starling pill (the floating button's size) and closes back into it. One capsule
/// changes size, from the closed size to the measured size of what it shows, on an ease-out curve with no bounce;
/// what it shows is laid out at full size the whole time and revealed as the capsule widens (it never re-flows
/// mid-animation), fading in just behind the edge. A new line ("Writing it down" after "Listening") changes the
/// width the same way, and the words cross-fade.
private struct HUDView: View {
    @ObservedObject var state: HUDState
    /// What the open pill measures (its contents at their natural size).
    @State private var content = CGSize(width: 160, height: 42)

    static let closed = CGSize(width: 44, height: 22)
    static let opening = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.46)    // fast out, long soft landing
    static let closing = Animation.timingCurve(0.5, 0, 0.75, 0, duration: 0.24)    // gathers, then tucks in
    static let resizing = Animation.timingCurve(0.25, 0.9, 0.3, 1, duration: 0.32)

    private var open: Bool { state.expanded }
    private var size: CGSize { open ? CGSize(width: max(content.width, Self.closed.width), height: content.height) : Self.closed }
    private var alignment: Alignment { Alignment(horizontal: state.alignment, vertical: .center) }

    var body: some View {
        ZStack(alignment: alignment) {
            Capsule()
                .fill(Palette.ink.opacity(0.94))
                .overlay(Capsule().strokeBorder(Color.white.opacity(open ? 0.08 : 0.10)))
                .shadow(color: .black.opacity(open ? 0.25 : 0.22), radius: open ? 10 : 4, y: open ? 4 : 2)
                .frame(width: size.width, height: size.height)

            // The open pill's contents, at full size always, shown through the capsule as it grows.
            contents
                .fixedSize()
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PillSize.self, value: proxy.size)
                })
                .opacity(open ? 1 : 0)
                .animation(open ? .easeOut(duration: 0.26).delay(0.07) : .easeIn(duration: 0.1), value: open)
                .frame(width: size.width, height: size.height, alignment: alignment)
                .clipShape(Capsule())

            // The closed pill's Starling, where the floating button has it.
            StarlingMark(.mono(Palette.cream), listening: false)
                .frame(width: 16, height: 16)
                .frame(width: Self.closed.width, height: Self.closed.height)
                .opacity(open ? 0 : 1)
                .scaleEffect(open ? 1.25 : 1)
                .animation(open ? .easeOut(duration: 0.14) : .easeOut(duration: 0.18).delay(0.08), value: open)
        }
        .animation(open ? Self.opening : Self.closing, value: open)
        .animation(Self.resizing, value: content)
        .onPreferenceChange(PillSize.self) { measured in
            guard measured.width > 0 else { return }
            MainActor.assumeIsolated { content = measured }
        }
        .padding(.horizontal, DictationHUD.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private var contents: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 26, height: 26)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.cream)
                .lineLimit(1)
                .frame(maxWidth: 380, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: label)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
    }

    private var label: String {
        switch state.mode {
        case .listening(let handsFree): return handsFree ? "Listening · tap the key to finish" : "Listening"
        case .command: return "Command · let go when done"
        case .typingOnly(let handsFree): return handsFree ? "Typing only · tap the key to finish" : "Typing only"
        case .working(let text): return text
        case .transcribing: return "Writing it down"
        case .preparing: return "Getting the speech model ready"
        case .startingMic: return "Starting the microphone…"
        case .message(let text, _): return text
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state.mode {
        case .listening, .command, .typingOnly:
            // The starling swells with your voice; the halo shows it's live even in silence.
            let level = CGFloat(min(1, max(0, state.level)))
            ZStack {
                Circle()
                    .fill(Palette.coral.opacity(0.22))
                    .frame(width: 14 + 10 * level, height: 14 + 10 * level)
                StarlingMark(state.mode == .command ? .mono(Palette.cream) : .color, listening: level > 0.15)
                    .frame(width: 20 + 6 * level, height: 20 + 6 * level)
            }
            .animation(.easeOut(duration: 0.09), value: state.level)
        case .transcribing, .preparing, .working, .startingMic:
            ProgressView().controlSize(.small).tint(Palette.coral)
        case .message(_, .problem):
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Palette.coral)
        case .message(_, .done):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Palette.cream)
        case .message(_, .info):
            StarlingMark(.mono(Palette.cream), listening: false)
                .frame(width: 20, height: 20)
        }
    }
}

/// The open pill's natural size, measured as it's laid out.
private struct PillSize: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}
