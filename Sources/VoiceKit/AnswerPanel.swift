import AgentKit
import AppKit
import SwiftUI

/// A small floating window for answers you read rather than paste. The answer is drawn as Markdown (headings,
/// lists, code, tables), the window grows to fit it, and Copy / Paste give plain text without the * and #.
@MainActor
final class AnswerPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let state = AnswerState()
    /// You dragged the window to a size of your own: keep it until the next answer.
    private var sizedByHand = false
    var onPaste: ((String) -> Void)?

    static let narrow: CGFloat = 520
    static let wide: CGFloat = 640
    static let headerHeight: CGFloat = 46
    static let footerHeight: CGFloat = 54
    /// Header, footer and their two hairlines, around the scrolling answer.
    static let chrome: CGFloat = headerHeight + footerHeight + 2

    /// `asked`: what you said, shown above the answer. `trace`: how the command went (skills followed, steps),
    /// shown under it.
    func show(_ text: String, asked: String? = nil, trace: TaskTrace? = nil) {
        state.text = text
        state.asked = asked?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.trace = trace.flatMap { $0.isEmpty ? nil : $0 }
        state.showSteps = false
        state.blocks = MarkdownBlocks.parse(text)
        state.copied = false
        sizedByHand = false

        let panel = self.panel ?? make()
        self.panel = panel
        let roomy = state.blocks.contains {
            if case .table = $0 { return true }
            if case .code = $0 { return true }
            return false
        }
        let width = roomy ? Self.wide : Self.narrow
        let wasVisible = panel.isVisible
        if wasVisible {
            var frame = panel.frame
            frame.origin.x = frame.midX - width / 2
            frame.size.width = width
            panel.setFrame(frame, display: true)
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                panel.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 130, width: width, height: 220),
                               display: false)
            }
        }
        // Lay the answer out now so the window opens at its height rather than jumping to it.
        panel.contentView?.layoutSubtreeIfNeeded()
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    func close() { panel?.orderOut(nil) }

    /// The answer's laid-out height: the window takes it, up to most of the screen (then it scrolls).
    fileprivate func fit(contentHeight: CGFloat) {
        guard let panel, !sizedByHand, contentHeight > 0 else { return }
        let area = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(max(contentHeight + Self.chrome, 150), area.height * 0.72).rounded()
        guard abs(panel.frame.height - height) > 1 else { return }
        var frame = panel.frame
        frame.size.height = height   // the bottom edge stays put; it grows upward
        if frame.maxY > area.maxY { frame.origin.y = area.maxY - height }
        panel.setFrame(frame, display: true, animate: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) { sizedByHand = true }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.narrow, height: 220),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow,
                                        .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.title = "Murmur"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 380, height: 150)
        panel.delegate = self
        // After SwiftUI's layout pass, not inside it.
        state.onHeight = { [weak self] height in
            DispatchQueue.main.async { self?.fit(contentHeight: height) }
        }
        panel.contentView = NSHostingView(rootView: AnswerView(state: state, copy: { [weak self] in
            guard let self else { return }
            TextInserter.copy(MarkdownBlocks.plain(state.text))
            state.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.state.copied = false }
        }, paste: { [weak self] in
            guard let self else { return }
            close()
            onPaste?(MarkdownBlocks.plain(state.text))
        }, close: { [weak self] in self?.close() }))
        return panel
    }
}

@MainActor
final class AnswerState: ObservableObject {
    @Published var text = ""
    @Published var asked: String?
    @Published var blocks: [MarkdownBlocks.Block] = []
    @Published var copied = false
    @Published var trace: TaskTrace?
    @Published var showSteps = false
    var onHeight: ((CGFloat) -> Void)?
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AnswerView: View {
    @ObservedObject var state: AnswerState
    let copy: () -> Void
    let paste: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MarkdownView(blocks: state.blocks)
                    if let trace = state.trace {
                        TraceView(trace: trace, open: $state.showSteps)
                    }
                }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeight.self, value: proxy.size.height)
                    })
            }
            .onPreferenceChange(ContentHeight.self) { height in
                MainActor.assumeIsolated { state.onHeight?(height) }
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            footer
        }
        .background(Palette.paper)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 1.0, green: 0.945, blue: 0.910))
                .frame(width: 22, height: 22)
                .overlay { StarlingMark(.color).padding(2) }
            if let asked = state.asked, !asked.isEmpty {
                Text("“\(asked)”")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.clay)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(asked)
            } else {
                Text("Murmur").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.clay)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Palette.line.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14)
        .frame(height: AnswerPanel.headerHeight)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("↩ paste  ·  esc close")
                .font(.system(size: 11))
                .foregroundStyle(Palette.clay.opacity(0.8))
            Spacer()
            Button(action: copy) {
                HStack(spacing: 5) {
                    Image(systemName: state.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(state.copied ? "Copied" : "Copy")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.control))
            }
            .buttonStyle(.plain)
            Button(action: paste) {
                Text("Paste")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.onPrimary)
                    .padding(.horizontal, 16).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.text))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .frame(height: AnswerPanel.footerHeight)
    }
}

// MARK: - Markdown

/// Draws an answer's Markdown blocks. Bold, italics, `code` and links inside a block use the system's own inline
/// Markdown; everything is selectable.
struct MarkdownView: View {
    let blocks: [MarkdownBlocks.Block]

    static let bodySize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block, first: index == 0)
            }
        }
        .textSelection(.enabled)
        .tint(Palette.coralDeep)
    }

    static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct BlockView: View {
    let block: MarkdownBlocks.Block
    let first: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownView.inline(text))
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15.5 : 14, weight: .semibold))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, first ? 0 : 4)

        case .paragraph(let text):
            paragraph(text)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.coral.opacity(0.7)).frame(width: 3)
                Text(MarkdownView.inline(text))
                    .font(.system(size: MarkdownView.bodySize))
                    .foregroundStyle(Palette.clay)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .list(_, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(item)
                        Text(MarkdownView.inline(item.text))
                            .font(.system(size: MarkdownView.bodySize))
                            .foregroundStyle(item.checked == true ? Palette.clay : Palette.text)
                            .strikethrough(item.checked == true, color: Palette.clay)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }

        case .code(let language, let text):
            CodeBlock(language: language, text: text)

        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownView.inline(cell))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.clay)
                    }
                }
                Rectangle().fill(Palette.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownView.inline(cell))
                                .font(.system(size: 13.5))
                                .foregroundStyle(Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line))

        case .rule:
            Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 3)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(MarkdownView.inline(text))
            .font(.system(size: MarkdownView.bodySize))
            .foregroundStyle(Palette.text)
            .lineSpacing(3.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func marker(_ item: MarkdownBlocks.ListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 12.5))
                .foregroundStyle(checked ? Palette.coral : Palette.clay)
                .frame(width: 16, alignment: .center)
        } else if let number = item.number {
            Text("\(number).")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.clay)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            Text(item.level == 0 ? "•" : "◦")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.coral)
                .frame(width: 12, alignment: .center)
        }
    }
}

/// A code block: monospaced, scrolls sideways rather than wrapping, with its own Copy.
private struct CodeBlock: View {
    let language: String?
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.clay)
                Spacer()
                Button {
                    TextInserter.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.clay)
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line))
    }
}

/// How the command went, under its answer: the skills it followed (always shown, so you can see they were used),
/// and, opened, each step in plain words with whether it worked.
private struct TraceView: View {
    let trace: TaskTrace
    @Binding var open: Bool

    /// "Skills followed: working-on-the-mac (always on), email-triage (matched the request)"
    private var skillLine: String {
        let named = trace.skills.map { name -> String in
            guard let why = trace.why[name] else { return name }
            return "\(name) (\(why))"
        }
        return "Skills followed: " + named.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("How I did it")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text(trace.summary())
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.clay)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !trace.skills.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.coral)
                    Text(skillLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.clay)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(trace.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: step.worked ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(step.worked ? Palette.clay.opacity(0.55) : Palette.coral)
                            Text("\(index + 1). \(step.text)")
                                .font(.system(size: 12))
                                .foregroundStyle(step.worked ? Palette.text : Palette.coralDeep)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !trace.model.isEmpty {
                        Text("Model: \(trace.model)")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.clay.opacity(0.8))
                            .padding(.top, 2)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line))
    }
}
