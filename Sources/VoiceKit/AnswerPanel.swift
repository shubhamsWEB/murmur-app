import AppKit
import SwiftUI

/// A small floating window for answers you read rather than paste: Copy, Paste and Close.
@MainActor
final class AnswerPanel {
    private var panel: NSPanel?
    private let state = AnswerState()
    var onPaste: ((String) -> Void)?

    func show(_ text: String) {
        state.text = text
        let panel = self.panel ?? make()
        self.panel = panel
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 130))
            }
        }
        panel.orderFrontRegardless()
    }

    func close() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = "Murmur"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: AnswerView(state: state, copy: { [weak self] in
            guard let self else { return }
            TextInserter.copy(state.text)
        }, paste: { [weak self] in
            guard let self else { return }
            close()
            onPaste?(state.text)
        }, close: { [weak self] in self?.close() }))
        return panel
    }
}

@MainActor
final class AnswerState: ObservableObject {
    @Published var text = ""
}

private struct AnswerView: View {
    @ObservedObject var state: AnswerState
    let copy: () -> Void
    let paste: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(state.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Copy", action: copy)
                Button("Paste", action: paste)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 160)
    }
}
