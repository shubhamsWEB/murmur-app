import AgentKit
import AppKit
import SwiftUI

/// Murmur's "Go ahead?" before an action that changes something (building with Claude Code, quitting an app,
/// clicking Send…): a small cream panel above every window, with the action in charcoal. ↩ confirms, Esc cancels.
@MainActor
enum ConfirmPanel {
    /// One choice under the question.
    struct Choice {
        let label: String
        let answer: Approval
        var primary = false
    }

    /// "Go ahead?" with Claude-style choices: once, for the rest of this task, or always for this kind of action.
    /// Nil kind: a payment (once only), or the start of a task ("let it run").
    static func ask(kind: Permission?, title: String, detail: String, confirm: String, symbol: String) -> Approval {
        let choices: [Choice]
        if title.hasPrefix("Let Murmur do this") {
            choices = [Choice(label: "Ask Me Each Time", answer: .once), Choice(label: "Let It Run", answer: .task, primary: true)]
        } else if let kind {
            choices = [Choice(label: "Cancel", answer: .no), Choice(label: confirm, answer: .once, primary: true),
                       Choice(label: "Allow for This Task", answer: .task),
                       Choice(label: "Always Allow \(kind.short)", answer: .always)]
        } else {
            choices = [Choice(label: "Cancel", answer: .no), Choice(label: confirm, answer: .once, primary: true)]
        }
        return present(title: title, detail: detail, symbol: symbol, choices: choices)
    }

    static func run(title: String, detail: String, confirm: String, symbol: String) -> Bool {
        present(title: title, detail: detail, symbol: symbol,
                choices: [Choice(label: "Cancel", answer: .no), Choice(label: confirm, answer: .once, primary: true)]) != .no
    }

    private static func present(title: String, detail: String, symbol: String, choices: [Choice]) -> Approval {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // Above every window, floating panels included: a question nobody sees is a command that never finishes.
        panel.level = .screenSaver
        panel.isMovableByWindowBackground = true
        // On every Space, over full-screen apps. (.moveToActiveSpace can't be combined with .canJoinAllSpaces:
        // AppKit throws, and every confirmation crashed Murmur.)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.118, green: 0.106, blue: 0.102, alpha: 1)
                : NSColor(srgbRed: 0.984, green: 0.973, blue: 0.957, alpha: 1)
        }
        var answer = Approval.no
        let view = ConfirmView(title: title, detail: detail, symbol: symbol, choices: choices) { picked in
            answer = picked
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
        // macOS can decline a menu bar app's request to come forward: ask both ways, and show the panel regardless.
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        panel.orderFrontRegardless()
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
        if lower.hasPrefix("let murmur") { return "play.fill" }
        if lower.hasPrefix("send") { return "paperplane" }
        return "questionmark"
    }
}

private struct ConfirmView: View {
    let title: String
    let detail: String
    let symbol: String
    let choices: [ConfirmPanel.Choice]
    let done: (Approval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.coral)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.ink))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                ScrollView {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.clay)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            // Two to a row: Cancel and the main answer first, then "for this task" and "always".
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: choices.count, by: 2)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(choices[start..<min(start + 2, choices.count)], id: \.label) { choice in
                            button(choice)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
        .padding(.top, 6)
        .frame(width: 420, alignment: .leading)
    }

    @ViewBuilder
    private func button(_ choice: ConfirmPanel.Choice) -> some View {
        let label = Text(choice.label).font(.system(size: 13, weight: choice.primary ? .semibold : .medium))
            .foregroundStyle(choice.primary ? Palette.onPrimary : Palette.text)
            .lineLimit(1).minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(choice.primary ? Palette.text : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(choice.primary ? Color.clear : Palette.control))
            .contentShape(Rectangle())
        if choice.primary {
            Button { done(choice.answer) } label: { label }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
        } else if choice.answer == .no || (choice.answer == .once && choices.first?.label == choice.label) {
            Button { done(choice.answer) } label: { label }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
        } else {
            Button { done(choice.answer) } label: { label }.buttonStyle(.plain)
        }
    }
}
