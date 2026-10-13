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
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.insert(.fullSizeContentView)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.ink)
                    .frame(width: 22, height: 22)
                    .overlay {
                        HStack(spacing: 2) {
                            ForEach(Array([6.0, 11, 7].enumerated()), id: \.offset) { _, height in
                                Capsule().fill(Palette.coral).frame(width: 2, height: height)
                            }
                        }
                    }
                Text("Murmur").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                Text("Esc to close").font(.system(size: 11.5)).foregroundStyle(Palette.clay)
            }
            .padding(.leading, 72)   // beside the window buttons
            .padding(.trailing, 16)
            .frame(height: 40)
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView {
                Text(state.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 8) {
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.clay)
                Spacer()
                Button(action: copy) {
                    Text("Copy").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.text)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.control))
                }
                .buttonStyle(.plain)
                Button(action: paste) {
                    Text("Paste ↩").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.onPrimary)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.text))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.card)
        }
        .frame(minWidth: 380, minHeight: 190)
        .background(Palette.paper)
        .ignoresSafeArea(.container, edges: .top)
    }
}
