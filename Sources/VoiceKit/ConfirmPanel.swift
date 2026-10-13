import AppKit
import SwiftUI

/// Murmur's "Go ahead?" before an action that changes something (building with Claude Code, quitting an app,
/// clicking Send…): a small cream panel above every window, with the action in charcoal. ↩ confirms, Esc cancels.
@MainActor
enum ConfirmPanel {
    static func run(title: String, detail: String, confirm: String, symbol: String) -> Bool {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .modalPanel
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.118, green: 0.106, blue: 0.102, alpha: 1)
                : NSColor(srgbRed: 0.984, green: 0.973, blue: 0.957, alpha: 1)
        }
        var answer = false
        let view = ConfirmView(title: title, detail: detail, confirm: confirm, symbol: symbol) { ok in
            answer = ok
            NSApp.stopModal()
        }
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2,
                                         y: area.midY - panel.frame.height / 2 + area.height * 0.12))
        }
        // Back to the app you were in afterwards, so the command's next steps (typing, clicking) land there.
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        if let previous, previous != NSRunningApplication.current { previous.activate(options: []) }
        return answer
    }

    /// A symbol for what's being asked.
    static func symbol(for title: String) -> String {
        let lower = title.lowercased()
        if lower.hasPrefix("build") { return "chevron.left.forwardslash.chevron.right" }
        if lower.hasPrefix("quit") { return "xmark" }
        if lower.hasPrefix("click") { return "cursorarrow.click" }
        if lower.contains("shortcut") { return "square.stack" }
        if lower.hasPrefix("ask") { return "sparkles" }
        return "questionmark"
    }
}

private struct ConfirmView: View {
    let title: String
    let detail: String
    let confirm: String
    let symbol: String
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.coral)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.ink))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.clay)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button { done(false) } label: {
                    Text("Cancel").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.control))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button { done(true) } label: {
                    Text(confirm).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.onPrimary)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.text))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .padding(.top, 6)
        .frame(width: 400, alignment: .leading)
    }
}
