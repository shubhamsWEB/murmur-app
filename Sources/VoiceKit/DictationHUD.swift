import AppKit
import SwiftUI

/// The small pill near the bottom of the screen that shows Murmur is listening, then working.
@MainActor
final class DictationHUD {
    enum Mode: Equatable {
        case listening(handsFree: Bool)
        case transcribing
        case preparing
        case message(String)
    }

    private let state = HUDState()
    private var hideWork: DispatchWorkItem?

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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

    func setLevel(_ level: Float) {
        state.level = level
    }

    /// Shows a short message, then hides.
    func flash(_ text: String, seconds: Double = 2.5) {
        show(.message(text))
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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

private struct HUDView: View {
    @ObservedObject var state: HUDState

    var body: some View {
        HStack(spacing: 10) {
            indicator
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var label: String {
        switch state.mode {
        case .listening(let handsFree): return handsFree ? "Listening · tap Fn to finish" : "Listening…"
        case .transcribing: return "Transcribing…"
        case .preparing: return "Preparing speech model…"
        case .message(let text): return text
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state.mode {
        case .listening:
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let weights: [Float] = [0.5, 0.8, 1, 0.8, 0.5]
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 3, height: CGFloat(4 + 14 * min(1, state.level * weights[i])))
                }
            }
            .frame(height: 18)
            .animation(.easeOut(duration: 0.08), value: state.level)
        case .transcribing, .preparing:
            ProgressView().controlSize(.small).tint(.white)
        case .message:
            Image(systemName: "info.circle")
        }
    }
}
