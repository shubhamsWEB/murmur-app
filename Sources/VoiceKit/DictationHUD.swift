import AppKit
import SwiftUI

/// The small pill near the bottom of the screen that shows Murmur is listening, then working.
@MainActor
final class DictationHUD {
    /// What a message is: something done, something to know, or something that went wrong.
    enum Tone: Equatable {
        case done, info, problem
    }

    enum Mode: Equatable {
        case listening(handsFree: Bool)
        case command
        case working(String)
        case transcribing
        case preparing
        case message(String, Tone)
    }

    private let state = HUDState()
    private var hideWork: DispatchWorkItem?

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 48),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
    }()

    func show(_ mode: Mode) {
        hideWork?.cancel()
        state.mode = mode
        state.level = 0
        place()
        panel.orderFrontRegardless()
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
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func tone(of text: String) -> Tone {
        let problem = #"(?i)\b(can'?t|cannot|couldn'?t|didn'?t|doesn'?t|isn'?t|won'?t|failed|failure|error|rejected|stopped|needs|denied|not allowed|no access|unable)\b|^no "#
        return text.range(of: problem, options: .regularExpression) != nil ? .problem : .info
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    /// Bottom centre of the screen the mouse is on.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 72))
    }
}

@MainActor
final class HUDState: ObservableObject {
    @Published var mode: DictationHUD.Mode = .transcribing
    @Published var level: Float = 0
}

/// The listening pill: a charcoal capsule whose coral dot breathes with your voice.
private struct HUDView: View {
    @ObservedObject var state: HUDState

    var body: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 26, height: 26)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.cream)
                .lineLimit(1)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Palette.ink.opacity(0.94))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var label: String {
        switch state.mode {
        case .listening(let handsFree): return handsFree ? "Listening · tap Fn to finish" : "Listening"
        case .command: return "Command · let go when done"
        case .working(let text): return text
        case .transcribing: return "Writing it down"
        case .preparing: return "Getting the speech model ready"
        case .message(let text, _): return text
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state.mode {
        case .listening, .command:
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
        case .transcribing, .preparing, .working:
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
