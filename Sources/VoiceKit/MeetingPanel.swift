import AgentKit
import AppKit
import Combine
import SwiftUI

/// The meeting notes window, made to be read at a glance and read out loud: the answer in large type, a sentence a
/// line, the direct answer first; its size goes up and down with A− / A+ (⌘− / ⌘+). Three ways to sit:
/// - a card beside the call (Live, Notes, Transcript, Context);
/// - a wide strip at the top of the screen, just under the camera, with only the answer, so your eyes stay near the
///   camera while you read it out;
/// - folded into a small pill at the top, which lights up when an answer is ready.
/// On top, on every Space, and always left out of screen sharing (what's on it is about the people on the call).
@MainActor
final class MeetingPanel: NSObject, NSWindowDelegate {
    private(set) var window: NSPanel?
    private unowned let mode: MeetingMode
    private var watching: AnyCancellable?
    private var fading: AnyCancellable?
    /// Where you put the card and the strip, so switching back finds them there.
    private var frames: [MeetingState.Layout: NSRect] = [:]
    private var placed: (layout: MeetingState.Layout, collapsed: Bool)?

    init(mode: MeetingMode) {
        self.mode = mode
    }

    func show() {
        let panel = window ?? make()
        window = panel
        PrivateWindows.keepPrivate(panel)
        place(layout: mode.state.layout, collapsed: mode.state.collapsed)
        panel.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        mode.closePanel()
        return false
    }

    /// Sizes and places the window for a layout (or the pill), keeping where you'd moved the one it leaves.
    private func place(layout: MeetingState.Layout, collapsed: Bool) {
        guard let panel = window else { return }
        if let placed, !placed.collapsed, panel.isVisible { frames[placed.layout] = panel.frame }
        placed = (layout, collapsed)
        let mouse = NSEvent.mouseLocation
        let screen = panel.isVisible ? (panel.screen ?? NSScreen.main)
            : (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
        guard let area = screen?.visibleFrame else { return }
        let frame: NSRect
        if collapsed {
            panel.styleMask.remove(.resizable)
            panel.contentMinSize = NSSize(width: 200, height: 40)
            let size = NSSize(width: 300, height: 46)
            frame = NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 8, width: size.width,
                           height: size.height)
        } else if layout == .strip {
            panel.styleMask.insert(.resizable)
            panel.contentMinSize = NSSize(width: 480, height: 170)
            let width = min(780, area.width - 80), height: CGFloat = 270
            frame = frames[.strip].map { visible($0, in: area) } ?? NSRect(x: area.midX - width / 2,
                                                                         y: area.maxY - height - 6,
                                                                         width: width, height: height)
        } else {
            panel.styleMask.insert(.resizable)
            panel.contentMinSize = NSSize(width: 360, height: 340)
            let width: CGFloat = 430, height = min(700, area.height - 40)
            frame = frames[.card].map { visible($0, in: area) } ?? NSRect(x: area.maxX - width - 20,
                                                                        y: area.maxY - height - 20,
                                                                        width: width, height: height)
        }
        let animate = panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(frame, display: true, animate: animate)
    }

    /// A remembered frame, moved back onto the screen if the screens changed.
    private func visible(_ frame: NSRect, in area: NSRect) -> NSRect {
        // Never bigger than the screen, and never off it (the screens may have changed).
        var frame = frame
        frame.size.width = min(frame.width, area.width - 20)
        frame.size.height = min(frame.height, area.height - 20)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return frame
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 680),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow,
                                        .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.title = ""   // nothing for a share picker to show
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityLabel("Murmur meeting notes")
        // Left out of capture before it first shows.
        PrivateWindows.keepPrivate(panel)
        panel.delegate = self
        let host = NSHostingView(rootView: MeetingRoot(state: mode.state, mode: mode))
        // The window keeps the size it's given: content that's wider (a long line of code) or taller (a long
        // answer) scrolls inside it rather than stretching the window across or off the screen.
        host.sizingOptions = []
        panel.contentView = host
        window = panel
        // How see-through it is: the chosen opacity, solid under the pointer when that's on.
        fading = mode.state.$opacity.combineLatest(mode.state.$hovering, mode.state.$solidOnHover)
            .sink { [weak panel] opacity, hovering, solid in
                let alpha = hovering && solid ? 1 : opacity
                DispatchQueue.main.async {
                    guard let panel, panel.alphaValue > 0.01 else { return }   // not during the sharing check
                    panel.animator().alphaValue = CGFloat(alpha)
                }
            }
        // @Published sends the new value before it's stored: both values come from the publishers.
        watching = mode.state.$layout.combineLatest(mode.state.$collapsed)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] layout, collapsed in
                DispatchQueue.main.async { self?.place(layout: layout, collapsed: collapsed) }
            }
        return panel
    }
}

// MARK: - The three layouts

private struct MeetingRoot: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode

    var body: some View {
        Group {
            if state.collapsed {
                PillView(state: state, mode: mode)
            } else if state.layout == .strip {
                StripView(state: state, mode: mode)
            } else {
                CardView(state: state, mode: mode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.paper)
        .ignoresSafeArea(.container, edges: .top)
        .onHover { state.hovering = $0 }
    }
}

/// The colors a reader needs, stronger with Increase Contrast.
private struct Ink {
    let contrast: ColorSchemeContrast
    var secondary: Color { contrast == .increased ? Palette.text : Palette.clay }
    var line: Color { contrast == .increased ? Palette.clay : Palette.line }
}

/// The beside-the-call card: header, tabs, and the answer in large type on Live.
private struct CardView: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    /// Where the tabs are, in the window (the tour points at them).
    var onTabs: ((CGRect) -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let ink = Ink(contrast: contrast)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                StatusTitle(state: state).layoutPriority(-1)
                Spacer(minLength: 4)
                if state.running { Levels(state: state, mode: mode) }
                TextSizeButtons(state: state)
                OpacityMenu(state: state)
                IconButton(symbol: "rectangle.topthird.inset.filled", label: "Read near the camera",
                           hint: "Moves the answer to a wide strip at the top of the screen") { mode.setLayout(.strip) }
                if state.running {
                    IconButton(symbol: "chevron.up", label: "Fold into a pill",
                               hint: "Shrinks to a small pill at the top; it lights up when an answer is ready") {
                        mode.collapse()
                    }
                } else {
                    IconButton(symbol: "xmark", label: "Close", hint: nil) { mode.closePanel() }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            SharingLine(state: state, mode: mode, compact: false)
            Picker("Show", selection: $state.tab) {
                Text("Live").tag(MeetingState.Tab.live)
                Text("Notes").tag(MeetingState.Tab.notes)
                Text("Transcript").tag(MeetingState.Tab.transcript)
                Text("Context").tag(MeetingState.Tab.context)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onTabs?($0) }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Rectangle().fill(ink.line).frame(height: 1)
            switch state.tab {
            case .live: live(ink)
            case .notes: NotesView(state: state, mode: mode)
            case .transcript: TranscriptView(state: state, mode: mode)
            case .context: ContextView(state: state, mode: mode)
            }
            EndingLine(state: state, mode: mode)
            ProblemLine(state: state)
            Rectangle().fill(ink.line).frame(height: 1)
            Footer(state: state, mode: mode)
        }
    }

    private func live(_ ink: Ink) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AnswerControls(state: state, mode: mode)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
            QuickActions(state: state, mode: mode)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if state.answers.indices.contains(state.shown) {
                        VStack(alignment: .leading, spacing: 14) {
                            AnswerReader(answer: state.answers[state.shown], size: state.textSize)
                            Pager(state: state)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.line))
                    } else {
                        Waiting(state: state, size: state.textSize)
                    }
                    if let last = state.lines.last {
                        LastSaid(line: last, who: state.label(last))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AskBox(state: state, mode: mode)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }
}

/// Near the camera: only the answer, wide and large, and the few controls you need while reading it out.
private struct StripView: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StatusTitle(state: state).layoutPriority(-1)
                Spacer(minLength: 4)
                if state.answers.count > 1 { Pager(state: state, compact: true) }
                SmallButton(title: "Answer now", detail: MeetingHotkey.display, primary: true) { mode.answerNow() }
                    .disabled(!state.running && state.lines.isEmpty)
                    .accessibilityHint("Answers what the other side just said")
                IconButton(symbol: "eye", label: "Answer about the screen",
                           hint: "Answers about what's shown in the meeting, like a shared slide or chart") {
                    mode.answerFromScreen()
                }
                .disabled(!state.running && state.lines.isEmpty)
                Menu {
                    Button("What should I say?") { mode.whatToSay() }
                    Button("Follow-up questions") { mode.followUpQuestions() }
                    Button("Recap so far") { mode.recap() }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Palette.line.opacity(0.6)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(state.lines.isEmpty)
                .help("What should I say?, Follow-up questions, Recap")
                .accessibilityLabel("Quick help")
                TextSizeButtons(state: state)
                OpacityMenu(state: state)
                IconButton(symbol: "rectangle.righthalf.inset.filled", label: "Show beside the call",
                           hint: "Back to the card with notes, transcript and context") { mode.setLayout(.card) }
                IconButton(symbol: "chevron.up", label: "Fold into a pill", hint: nil) { mode.collapse() }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            ScrollView {
                Group {
                    if state.answers.indices.contains(state.shown) {
                        AnswerReader(answer: state.answers[state.shown], size: state.textSize + 2, wide: true)
                    } else {
                        Waiting(state: state, size: state.textSize + 2)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.sharing == .visible { SharingLine(state: state, mode: mode, compact: true) }
            ProblemLine(state: state)
        }
    }
}

/// Folded: a pill at the top of the screen. Click to open; it turns coral when an answer is ready.
private struct PillView: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode

    var body: some View {
        Button { mode.expand() } label: {
            HStack(spacing: 9) {
                Circle().fill(state.unread ? Palette.onPrimary : (state.running ? Palette.coral : Palette.clay))
                    .frame(width: 8, height: 8)
                Text(state.unread ? "Answer ready" : state.finishing ? "Writing the notes…" : "\(state.app ?? "Meeting") notes")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(state.unread ? "Show" : "Open").font(.system(size: 12.5, weight: .medium)).opacity(0.85)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(state.unread ? Palette.onPrimary : Palette.text)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(state.unread ? Palette.coralDeep : Palette.paper)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.unread ? "Meeting notes: answer ready" : "Meeting notes")
        .accessibilityHint("Opens the meeting notes")
    }
}

// MARK: - The answer

/// The answer as it's read out: the question small, then what to say a sentence a line in large type, then the
/// extra points smaller. Code (an answer from the screen) is drawn as Markdown.
private struct AnswerReader: View {
    let answer: MeetingAnswer
    let size: CGFloat
    var wide = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let ink = Ink(contrast: contrast)
        VStack(alignment: .leading, spacing: size * 0.7) {
            Text("“\(answer.question)”")
                .font(.system(size: max(12.5, size * 0.66)))
                .foregroundStyle(ink.secondary)
                .lineLimit(wide ? 1 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Question: \(answer.question)")
            if answer.usedScreen {
                HStack(spacing: 6) {
                    if answer.looking { ProgressView().controlSize(.mini) } else { Image(systemName: "eye") }
                    Text(answer.looking ? "Looking at the meeting's screen…" : "Looked at the meeting's screen")
                }
                .font(.system(size: max(12, size * 0.6), weight: .medium))
                .foregroundStyle(ink.secondary)
                .accessibilityElement(children: .combine)
            }
            if answer.text.isEmpty, !answer.looking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Drafting an answer…").font(.system(size: max(13, size * 0.72))).foregroundStyle(ink.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: size * 0.55) {
                    // The direct answer: one line, said first.
                    if let headline = answer.spoken.headline {
                        Text(Self.inline(headline))
                            .font(.system(size: size * 1.08, weight: .semibold))
                            .foregroundStyle(Palette.text)
                            .lineSpacing(size * 0.18)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The points that complete it, a short spoken line each, key words in bold.
                    if !answer.spoken.points.isEmpty {
                        VStack(alignment: .leading, spacing: size * 0.4) {
                            ForEach(Array(answer.spoken.points.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .firstTextBaseline, spacing: size * 0.45) {
                                    Text("•").foregroundStyle(Palette.coralDeep).accessibilityHidden(true)
                                    Text(Self.inline(point))
                                        .foregroundStyle(Palette.text)
                                        .lineSpacing(size * 0.2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: size))
                            }
                        }
                    }
                    // An answer in the older shape, or plain text: a sentence a line.
                    ForEach(Array(answer.spoken.say.enumerated()), id: \.offset) { index, sentence in
                        Text(sentence)
                            .font(.system(size: size, weight: index == 0 && answer.spoken.headline == nil ? .semibold : .regular))
                            .foregroundStyle(Palette.text)
                            .lineSpacing(size * 0.22)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let example = answer.spoken.example {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Palette.coral.opacity(0.7)).frame(width: 3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("For example").font(.system(size: max(12, size * 0.62), weight: .semibold))
                                    .foregroundStyle(ink.secondary)
                                Text(Self.inline(example)).font(.system(size: size * 0.88))
                                    .foregroundStyle(Palette.text)
                                    .lineSpacing(size * 0.18)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Answer: \(answer.spoken.spokenText)")
                ForEach(Array(answer.spoken.code.enumerated()), id: \.offset) { _, block in
                    CodeView(block: block, size: size, writing: answer.writing)
                }
                if !answer.spoken.also.isEmpty {
                    VStack(alignment: .leading, spacing: size * 0.3) {
                        Text(answer.kind.alsoTitle)
                            .font(.system(size: max(12, size * 0.62), weight: .semibold))
                            .foregroundStyle(ink.secondary)
                        ForEach(Array(answer.spoken.also.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(Palette.coralDeep)
                                Text(point).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: max(13, size * 0.78)))
                        }
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

extension AnswerReader {
    /// A line with its **bold** key words drawn bold (a half-written one shows as it is).
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A block of code in an answer: monospaced, scrolling sideways rather than wrapping, with its language and Copy.
private struct CodeView: View {
    let block: AnswerCode
    let size: CGFloat
    let writing: Bool
    @State private var copied = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(block.language.isEmpty ? "Code" : block.language.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink(contrast: contrast).secondary)
                Spacer()
                Button {
                    TextInserter.copy(block.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 8).frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(writing)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(block.text)
                    .font(.system(size: max(12, size * 0.68), design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.paper))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(block.language.isEmpty ? "Code" : block.language) code")
    }
}

/// No answer yet: what will appear, and how to ask for one.
private struct Waiting: View {
    @ObservedObject var state: MeetingState
    let size: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(state.autoAnswer
             ? "When someone asks a question, an answer you can read out shows here once they've finished asking."
             : "Auto answer is off. Press Answer now (\(MeetingHotkey.display)) after a question.")
            .font(.system(size: max(13.5, size * 0.78)))
            .foregroundStyle(Ink(contrast: contrast).secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }
}

/// ‹ 2 of 5 ›, with ⌘[ and ⌘] (and Copy).
private struct Pager: View {
    @ObservedObject var state: MeetingState
    var compact = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 6) {
            if !compact, let answer = state.answers[safe: state.shown], !answer.text.isEmpty {
                SmallButton(title: "Copy", detail: nil, primary: false) {
                    TextInserter.copy(answer.spoken.spokenText)
                }
                .accessibilityHint("Copies what to say")
            }
            if !compact { Spacer(minLength: 0) }
            if state.answers.count > 1 {
                IconButton(symbol: "chevron.left", label: "Previous answer", hint: nil, enabled: state.shown > 0) {
                    state.shown -= 1
                }
                .keyboardShortcut("[", modifiers: .command)
                Text("\(state.shown + 1) of \(state.answers.count)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Ink(contrast: contrast).secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                IconButton(symbol: "chevron.right", label: "Next answer", hint: nil,
                           enabled: state.shown < state.answers.count - 1) {
                    state.shown += 1
                }
                .keyboardShortcut("]", modifiers: .command)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.answers.count > 1 ? "Answer \(state.shown + 1) of \(state.answers.count)" : "Answer")
    }
}

/// Answer now, About the screen, and Auto answer.
private struct AnswerControls: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode

    var body: some View {
        HStack(spacing: 8) {
            SmallButton(title: "Answer now", detail: MeetingHotkey.display, primary: true) { mode.answerNow() }
                .accessibilityHint("Answers what the other side just said, now")
            SmallButton(title: "Screen", detail: nil, primary: false) { mode.answerFromScreen() }
                .help("Answer about what's shown in the meeting, like a shared slide or chart")
                .accessibilityLabel("Answer about the screen")
                .accessibilityHint("Answers about what's shown in the meeting, like a shared slide or chart")
            Spacer(minLength: 4)
            Toggle("Auto", isOn: Binding(get: { state.autoAnswer }, set: { mode.setAutoAnswer($0) }))
                .help("Auto answer: answer each question once they've finished asking")
                .accessibilityLabel("Auto answer")
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12.5))
                .accessibilityHint("Answers each question once they've finished asking")
        }
        .disabled(!state.running && state.lines.isEmpty)
    }
}

/// One-click help: what to say next, questions to ask, and a recap for when you lost the thread.
private struct QuickActions: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode

    var body: some View {
        HStack(spacing: 6) {
            chip("What should I say?", "text.bubble") { mode.whatToSay() }
            chip("Follow-ups", "questionmark.bubble") { mode.followUpQuestions() }
                .help("Questions you could ask now")
            chip("Recap", "arrow.counterclockwise") { mode.recap() }
                .help("The meeting so far, for when you lost the thread")
        }
        .disabled(state.lines.isEmpty)
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(Palette.line.opacity(0.7)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// "Ask about this meeting…": a question typed privately, answered with the meeting (Return sends it).
private struct AskBox: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Ask about this meeting…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused)
                .onSubmit(send)
                .accessibilityLabel("Ask about this meeting")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.onPrimary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(text.trimmingCharacters(in: .whitespaces).isEmpty ? Palette.clay.opacity(0.4) : Palette.text))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Ask")
        }
        .padding(.leading, 12).padding(.trailing, 5)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focused ? Palette.clay : Palette.control))
    }

    private func send() {
        let question = text
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        text = ""
        mode.ask(question)
    }
}

/// The other side's or your last line, small, under the answer.
private struct LastSaid: View {
    let line: MeetingLine
    let who: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(who)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(line.speaker == .you ? Palette.coralDeep : Ink(contrast: contrast).secondary)
            Text(line.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last said, by \(line.speaker == .you ? "you" : who): \(line.text)")
    }
}

// MARK: - Header pieces

private struct StatusTitle: View {
    @ObservedObject var state: MeetingState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.running ? Palette.coral : Palette.clay.opacity(0.5))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            if state.running {
                TimelineView(.periodic(from: state.started, by: 1)) { context in
                    Text("\(state.app ?? "Listening") · \(elapsed(context.date))")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .accessibilityLabel("Listening to \(state.app ?? "the meeting")")
            } else {
                Text(state.finishing ? "Writing the notes…" : "Meeting notes")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
            }
        }
    }

    private func elapsed(_ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(state.started)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct Levels: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode

    var body: some View {
        HStack(spacing: 6) {
            LevelChip(label: "Call", symbol: "speaker.wave.2.fill", level: state.callLevel, off: false)
                .help("The call's sound: what the others say")
                .accessibilityLabel("Call sound")
            Button { mode.setMicMuted(!state.micMuted) } label: {
                LevelChip(label: "You", symbol: state.micMuted ? "mic.slash.fill" : "mic.fill",
                          level: state.micLevel, off: state.micMuted)
            }
            .buttonStyle(.plain)
            .help(state.micMuted ? "Your microphone is left out of the notes. Click to include it."
                  : "Your microphone. Click to leave it out of the notes (the call is still heard).")
            .accessibilityLabel(state.micMuted ? "Your microphone, left out" : "Your microphone")
            .accessibilityHint(state.micMuted ? "Includes your microphone in the notes" : "Leaves your microphone out of the notes")
        }
    }
}

/// How see-through the window is: 100 % to 40 %, and whether it turns solid under the pointer.
private struct OpacityMenu: View {
    @ObservedObject var state: MeetingState
    private static let steps: [Double] = [1, 0.85, 0.7, 0.55, 0.4]

    var body: some View {
        Menu {
            ForEach(Self.steps, id: \.self) { step in
                Button {
                    state.opacity = step
                } label: {
                    if abs(state.opacity - step) < 0.01 {
                        Label("\(Int(step * 100)) %", systemImage: "checkmark")
                    } else {
                        Text("\(Int(step * 100)) %")
                    }
                }
            }
            Divider()
            Toggle("Solid when the pointer is on it", isOn: $state.solidOnHover)
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.line.opacity(0.6)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("See-through: \(Int(state.opacity * 100)) %")
        .accessibilityLabel("Window opacity, \(Int(state.opacity * 100)) percent")
    }
}

private struct TextSizeButtons: View {
    @ObservedObject var state: MeetingState

    var body: some View {
        HStack(spacing: 2) {
            Button { state.smallerText() } label: {
                Text("A").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(state.textSize <= 15)
            .accessibilityLabel("Smaller text")
            Button { state.biggerText() } label: {
                Text("A").font(.system(size: 16, weight: .semibold)).frame(width: 26, height: 26)
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(state.textSize >= 30)
            .accessibilityLabel("Larger text")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.text)
        .background(Capsule().fill(Palette.line.opacity(0.6)))
        .help("Text size (⌘− and ⌘+)")
    }
}

private struct IconButton: View {
    let symbol: String
    let label: String
    let hint: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(enabled ? Palette.text : Palette.clay.opacity(0.4))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.line.opacity(0.6)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(hint.map { "\(label): \($0)" } ?? label)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

private struct SharingLine: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    let compact: Bool

    var body: some View {
        switch state.sharing {
        case .unchecked:
            EmptyView()
        case .checking:
            line("eye.slash", "Checking that screen sharing can't see this…", Palette.clay, again: false)
        case .hidden:
            line("eye.slash", "Hidden from screen sharing on this Mac", Palette.clay, again: true)
        case .visible:
            line("eye.trianglebadge.exclamationmark",
                 "Screen sharing on this Mac can show this. Share one window, not your entire screen.",
                 Palette.coralDeep, again: true)
        case .unknown:
            line("questionmark.circle", "Couldn't check whether screen sharing sees this.", Palette.clay, again: true)
        }
    }

    private func line(_ symbol: String, _ text: String, _ color: Color, again: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11.5)).accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if again {
                Button("Check again") { Task { await mode.checkSharing() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.text)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 16)
        .padding(.bottom, compact ? 10 : 8)
    }
}

/// The people on the call over the transcript, one chip each (a name, or Speaker N): click one to name them, say
/// they're the same person as another, or have Murmur remember their voice.
private struct PeopleRow: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let voices = state.numbers.sorted { $0.value < $1.value }.map(\.key) + (state.single.map { [$0] } ?? [])
        if !voices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("On the call").font(.system(size: 11.5)).foregroundStyle(Ink(contrast: contrast).secondary)
                        ForEach(voices, id: \.self) { PersonChip(state: state, mode: mode, voice: $0) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                Rectangle().fill(Ink(contrast: contrast).line).frame(height: 1)
            }
        }
    }
}

private struct PersonChip: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    let voice: Int
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 5) {
                Text(SpeakerEditor.title(state, voice)).font(.system(size: 12, weight: .semibold))
                if let maybe = state.suggestions[voice] {
                    Text("possibly \(maybe.name)?").font(.system(size: 11.5)).foregroundStyle(Palette.coralDeep)
                }
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Palette.control.opacity(0.55)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Name this person, merge them with another, or remember their voice")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            SpeakerEditor(state: state, mode: mode, voice: voice) { editing = false }
        }
    }
}

/// Naming one voice on the call.
private struct SpeakerEditor: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    let voice: Int
    let done: () -> Void
    @State private var name = ""
    @State private var message: String?
    @State private var remembering = false

    static func title(_ state: MeetingState, _ voice: Int) -> String {
        if let name = state.names[voice]?.name, !name.isEmpty { return name }
        return state.numbers[voice].map { "Speaker \($0)" } ?? "Them"
    }

    private var source: String? {
        guard let name = state.names[voice], !name.name.isEmpty else { return nil }
        switch name.source {
        case .user: return "You named them."
        case .library: return "Recognised from a voice you saved" + (name.evidence.map { " (\($0))." } ?? ".")
        case .window: return "Named by the meeting app."
        case .conversation: return "From what was said" + (name.evidence.map { ": \($0)" } ?? ".")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(Self.title(state, voice)).font(.system(size: 14, weight: .semibold))
            if let source { Text(source).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let maybe = state.suggestions[voice] {
                HStack(spacing: 8) {
                    Text("Possibly \(maybe.name) (\(Int((maybe.score * 100).rounded())) %)").font(.system(size: 12.5))
                    Spacer(minLength: 4)
                    Button("Yes") { mode.answerSuggestion(voice, yes: true) }
                    Button("No") { mode.answerSuggestion(voice, yes: false) }
                }
            }
            HStack(spacing: 8) {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // Names heard in the meeting that nobody has yet: one click, spelled right.
            let taken = Set(state.names.values.map { $0.name.lowercased() })
            let heard = state.people.filter { !taken.contains($0.lowercased()) }
            if !heard.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Names heard in this meeting").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(heard, id: \.self) { person in
                                Button(person) { mode.rename(voice, to: person); name = person; message = nil }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            let others = state.numbers.keys.filter { $0 != voice }.sorted { state.numbers[$0]! < state.numbers[$1]! }
            if !others.isEmpty {
                Menu("Same person as…") {
                    ForEach(others, id: \.self) { other in
                        Button(Self.title(state, other)) { mode.merge(voice, into: other); done() }
                    }
                }
                .menuStyle(.button).buttonStyle(.borderless).fixedSize()
            }
            if let current = state.names[voice], !current.name.isEmpty, current.source != .user {
                Button("Not them") { mode.rename(voice, to: ""); done() }.buttonStyle(.link)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button(remembering ? "Remembering…" : "Remember this voice") {
                    remembering = true
                    Task {
                        message = await mode.remember(voice)
                        remembering = false
                    }
                }
                .disabled(remembering || (state.names[voice]?.name ?? "").isEmpty)
                Text("Check with them first. Their voiceprint stays on this Mac, and you can delete it under Meetings › People.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message { Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { name = state.names[voice]?.name ?? "" }
    }

    private func save() {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        mode.rename(voice, to: typed)
        message = nil
    }
}

/// A meeting you started yourself, with nobody talking for a long while: it ends by itself unless you keep it going.
private struct EndingLine: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode

    var body: some View {
        if let left = state.endingIn {
            HStack(spacing: 8) {
                Image(systemName: "hourglass").font(.system(size: 12)).accessibilityHidden(true)
                Text("No one has spoken for \(MeetingMode.silentMinutes) min. Ending in \(left) s and writing the notes.")
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Keep going") { mode.keepGoing() }
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

private struct ProblemLine: View {
    @ObservedObject var state: MeetingState

    var body: some View {
        if let problem = state.problem {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).accessibilityHidden(true)
                Text(problem).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { state.problem = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .foregroundStyle(Palette.coralDeep)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

private struct Footer: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode

    var body: some View {
        HStack(spacing: 8) {
            if let saved = state.saved {
                SmallButton(title: "Show file", detail: nil, primary: false, height: 32) {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                }
            } else if state.running {
                Button { state.tab = .context } label: {
                    Text("Answers with \(mode.aiName)")
                        .font(.system(size: 12)).foregroundStyle(Palette.clay).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .layoutPriority(-1)
                .help("Change the AI under Context")
                .accessibilityHint("Shows where to change the AI for answers and notes")
            }
            Spacer(minLength: 8)
            SmallButton(title: state.copied ? "Copied" : "Copy notes", detail: nil, primary: false, height: 32) {
                copyNotes()
            }
            .disabled(state.notesText.isEmpty && state.lines.isEmpty)
            if state.running {
                SmallButton(title: "Stop", detail: nil, primary: true, height: 32) { mode.stop() }
                    .accessibilityHint("Stops listening and writes the final notes")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    /// The notes, or the transcript when there are no notes yet.
    private func copyNotes() {
        let text = state.notesText.isEmpty
            ? state.lines.map { "\(state.label($0)): \($0.text)" }.joined(separator: "\n")
            : MarkdownBlocks.plain(state.notesText)
        TextInserter.copy(text)
        state.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [state] in state.copied = false }
    }
}

// MARK: - Notes, Transcript, Context

private struct NotesView: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !state.running, !state.finishing, !(state.notesText.isEmpty && state.lines.isEmpty) {
                    EmailCard(state: state, mode: mode)
                }
                if state.writingNotes {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Updating the notes…").font(.system(size: 13)).foregroundStyle(Ink(contrast: contrast).secondary)
                    }
                }
                if state.notes.isEmpty {
                    if !state.writingNotes {
                        Text("Notes show here after a minute or so of talk: a summary, decisions and action items.")
                            .font(.system(size: 13.5)).foregroundStyle(Ink(contrast: contrast).secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    MarkdownView(blocks: state.notes)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// After the meeting: a follow-up email drafted from the notes, to copy or open in Mail.
private struct EmailCard: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    @State private var copied = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let email = state.email {
                Text("Follow-up email").font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Ink(contrast: contrast).secondary)
                Text(email.subject).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                Text(email.body).font(.system(size: 13.5)).foregroundStyle(Palette.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SmallButton(title: copied ? "Copied" : "Copy email", detail: nil, primary: false) {
                        TextInserter.copy("Subject: \(email.subject)\n\n\(email.body)")
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                    }
                    SmallButton(title: "Open in Mail", detail: nil, primary: true) { open(email) }
                    Spacer()
                    SmallButton(title: "Redo", detail: nil, primary: false) { mode.draftEmail() }
                        .disabled(state.draftingEmail)
                }
            } else if state.draftingEmail {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Drafting the follow-up email…").font(.system(size: 13))
                        .foregroundStyle(Ink(contrast: contrast).secondary)
                }
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Follow-up email").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.text)
                        Text("Thanks, what was agreed, who does what, and the next step.")
                            .font(.system(size: 12.5)).foregroundStyle(Ink(contrast: contrast).secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    SmallButton(title: "Draft", detail: nil, primary: true) { mode.draftEmail() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
    }

    /// A new message in the Mail app (or whatever handles mailto:), with the subject and the email filled in.
    private func open(_ email: MeetingEmail) {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.queryItems = [URLQueryItem(name: "subject", value: email.subject),
                            URLQueryItem(name: "body", value: email.body)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
}

private struct TranscriptView: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PeopleRow(state: state, mode: mode)
            lines
        }
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.lines.isEmpty {
                        Text("What's said shows here, a stretch of speech at a time.")
                            .font(.system(size: 13.5)).foregroundStyle(Ink(contrast: contrast).secondary)
                    }
                    ForEach(state.lines) { line in
                        (Text(state.label(line) + "  ")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(line.speaker == .you ? Palette.coralDeep : Ink(contrast: contrast).secondary)
                            + Text(line.text).font(.system(size: 14)).foregroundColor(Palette.text))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(line.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.lines.count) {
                if let last = state.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

private struct ContextView: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI for answers and notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                    MeetingAIPicker(state: state, mode: mode)
                    Text("A cloud AI keeps the work (and the fan) off this Mac; the conversation goes to that provider.")
                        .font(.system(size: 12)).foregroundStyle(Ink(contrast: contrast).secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speech for meetings").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                    Picker("Speech for meetings", selection: Binding(get: { state.speech }, set: { mode.setSpeech($0) })) {
                        ForEach(MeetingMode.Speech.allCases, id: \.self) { choice in
                            Text(choice.display + (choice.hasKey ? "" : " · needs API key")).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    Text("Who turns what's said into text, apart from the AI. Takes effect from the next meeting.")
                        .font(.system(size: 12)).foregroundStyle(Ink(contrast: contrast).secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                field("What's this meeting about?", text: $state.about,
                      hint: "e.g. Weekly Android release sync with QA and design", height: 64)
                field("Instructions for answers", text: Binding(get: { state.instructions },
                                                                set: { mode.setInstructions($0) }),
                      hint: "e.g. Short answers first, then one example. Kept for your next meetings.", height: 56)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Documents").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                    ForEach(state.documents) { document in
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(Ink(contrast: contrast).secondary)
                            Text(document.name).font(.system(size: 13)).foregroundStyle(Palette.text).lineLimit(1)
                            Spacer()
                            Button { state.documents.removeAll { $0.id == document.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Ink(contrast: contrast).secondary)
                            .accessibilityLabel("Remove \(document.name)")
                        }
                    }
                    SmallButton(title: "Add files…", detail: nil, primary: false) { mode.addDocuments() }
                        .disabled(state.documents.count >= 5)
                }
                Text("Used for answers and notes. Documents are read on this Mac (up to five: text, Markdown, PDF, Word); "
                     + "their text goes with the conversation to your AI for commands.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink(contrast: contrast).secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ title: String, text: Binding<String>, hint: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(hint).font(.system(size: 13)).foregroundStyle(Ink(contrast: contrast).secondary.opacity(0.8))
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .accessibilityHidden(true)
                }
                TextEditor(text: text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4).padding(.vertical, 4)
                    .accessibilityLabel(title)
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.control))
        }
    }
}

// MARK: - Small parts

/// "Call ▮▮▮": one side, and whether sound is coming in from it.
private struct LevelChip: View {
    let label: String
    let symbol: String
    let level: Float
    let off: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            HStack(spacing: 1.5) {
                ForEach(0..<3) { bar in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(!off && level > Float(bar) * 0.22 + 0.12 ? Palette.coral : Palette.control)
                        .frame(width: 2.5, height: CGFloat(5 + bar * 2))
                }
            }
            .accessibilityHidden(true)
        }
        .foregroundStyle(off ? Palette.coralDeep : Palette.clay)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Capsule().fill(Palette.line.opacity(0.6)))
    }
}

private struct SmallButton: View {
    let title: String
    let detail: String?
    let primary: Bool
    var height: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: primary ? .semibold : .medium))
                if let detail {
                    Text(detail).font(.system(size: 11)).opacity(0.75).accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(primary ? Palette.onPrimary : Palette.text)
            .padding(.horizontal, 12).frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(primary ? Palette.text : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(primary ? Color.clear : Palette.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Which AI writes the meeting's answers and notes: the commands' one, or one of its own.
private struct MeetingAIPicker: View {
    @ObservedObject var state: MeetingState
    let mode: MeetingMode

    var body: some View {
        Picker("AI for answers and notes", selection: Binding(get: { state.ai }, set: { mode.setAI($0) })) {
            Text("Same as commands: \(RouterChoice.current.meetingDisplay)").tag(RouterChoice?.none)
            ForEach(RouterChoice.allCases, id: \.self) { choice in
                Text(choice.meetingDisplay + (choice != .local && !choice.hasKey ? " · needs API key" : ""))
                    .tag(Optional(choice))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 320, alignment: .leading)
    }
}

/// Meeting notes drawn the way the panel draws them, for other windows (the Meetings page).
public struct MeetingNotesText: View {
    private let blocks: [MarkdownBlocks.Block]

    public init(markdown: String) {
        blocks = MarkdownBlocks.parse(markdown)
    }

    public var body: some View { MarkdownView(blocks: blocks) }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - The offer

/// "Zoom has the microphone on. Take notes?": a card at the top right that offers meeting notes, and goes away by
/// itself after half a minute. Large enough to read and hit at a glance; left out of screen sharing like the panel.
@MainActor
final class MeetingPrompt {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    static let size = NSSize(width: 380, height: 124)

    func show(app: String, start: @escaping () -> Void, dismiss: @escaping () -> Void) {
        hide()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityLabel("Murmur: take notes of this meeting?")
        PrivateWindows.keepPrivate(panel)
        let host = NSHostingView(rootView: PromptView(app: app, start: { [weak self] in
            self?.hide()
            start()
        }, dismiss: { [weak self] in
            self?.hide()
            dismiss()
        }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(Self.size)
        if let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - Self.size.width - 16, y: area.maxY - Self.size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(app) has the microphone on. Murmur offers to take notes.",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PromptView: View {
    let app: String
    let start: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.945, blue: 0.910))
                    .frame(width: 30, height: 30)
                    .overlay { StarlingMark(.color).padding(3) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take notes of this meeting?").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text("\(app) has the microphone on.").font(.system(size: 13)).foregroundStyle(Palette.clay)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                SmallButton(title: "Not now", detail: nil, primary: false, height: 32, action: dismiss)
                SmallButton(title: "Take notes", detail: nil, primary: true, height: 32, action: start)
            }
        }
        .padding(16)
        .frame(width: MeetingPrompt.size.width, height: MeetingPrompt.size.height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.line))
    }
}

// MARK: - In the tour

/// Meeting notes as the tour shows them: the real offer card and the real panel, playing a made-up call instead of
/// listening to one. Nothing records and nothing is sent anywhere; the panel's buttons don't act (the tour moves it
/// from tab to tab). Its AI and speech settings are the real ones, as the panel shows them.
@MainActor
public final class MeetingDemo: ObservableObject {
    public enum Scene: Equatable, Sendable { case offer, live, notes, transcript, context, ended }

    let state = MeetingState()
    let mode: MeetingMode
    @Published public private(set) var scene: Scene?
    private var playing: Task<Void, Never>?
    private var levels: Timer?
    private var nextLine = 0

    public init(mode: MeetingMode) {
        self.mode = mode
    }

    /// Shows a part of the call: at once (`animated` false, as in a snapshot), or as it happens.
    public func show(_ scene: Scene, animated: Bool) {
        guard scene != self.scene else { return }
        self.scene = scene
        playing?.cancel()
        switch scene {
        case .offer:
            reset()
        case .live:
            if state.lines.isEmpty { reset() }
            state.tab = .live
            playing = Task { [weak self] in await self?.ask(animated: animated) }
        case .notes:
            state.tab = .notes
            playing = Task { [weak self] in await self?.writeNotes(animated: animated) }
        case .transcript:
            state.tab = .transcript
            if animated {
                playing = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    self?.say(.you, "Yes, and the first month of onboarding is on us.")
                }
            } else {
                say(.you, "Yes, and the first month of onboarding is on us.")
            }
        case .context:
            state.tab = .context
        case .ended:
            stopLevels()
        }
        if scene != .offer, scene != .ended, animated, levels == nil { startLevels() }
    }

    /// The tour's over (or left the meeting part).
    public func stop() {
        playing?.cancel()
        playing = nil
        stopLevels()
        scene = nil
    }

    private func reset() {
        state.reset()
        state.running = true
        state.app = "Zoom"
        state.started = Date().addingTimeInterval(-12 * 60 - 40)
        state.sharing = .hidden
        state.autoAnswer = true
        state.about = "Acme's renewal. They want fifty seats and will push for a discount."
        state.instructions = "Keep answers short. Don't promise dates."
        state.ai = MeetingMode.aiChoice
        state.speech = MeetingMode.speechChoice
        state.documents = [MeetingDocument(url: URL(fileURLWithPath: "/Pricing v3.pdf"), text: "")]
        nextLine = 0
        say(.them, "Thanks for making time. We've looked at the renewal with the team.")
        say(.you, "Great. Where did you land?")
        say(.them, "We'd like to go from twenty seats to fifty.")
    }

    private func say(_ speaker: MeetingLine.Speaker, _ text: String) {
        nextLine += 1
        state.lines.append(MeetingLine(id: nextLine, speaker: speaker, text: text, at: Date()))
    }

    /// They ask; once they've finished, the answer is written in as it comes.
    private func ask(animated: Bool) async {
        let question = "What would fifty seats cost us on the yearly plan?"
        let answer = """
            ANSWER: Fifty seats on the yearly plan come to ₹40,000 a month.
            POINTS:
            - That's **20% less** than paying month to month.
            - Onboarding and single sign-on are included.
            EXAMPLE: Twenty seats today cost ₹19,000 a month, so it's about ₹800 a seat instead of ₹950.
            """
        guard state.answers.isEmpty else { return }
        if !animated {
            say(.them, question)
            let index = state.beginAnswer(question: question)
            state.updateAnswer(index, text: answer, done: true)
            return
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard !Task.isCancelled else { return }
        say(.them, question)
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        guard !Task.isCancelled else { return }
        let index = state.beginAnswer(question: question)
        let words = answer.split(separator: " ", omittingEmptySubsequences: false)
        var written = ""
        for (i, word) in words.enumerated() {
            guard !Task.isCancelled else { break }
            written += (i == 0 ? "" : " ") + word
            state.updateAnswer(index, text: written)
            try? await Task.sleep(nanoseconds: 55_000_000)
        }
        state.updateAnswer(index, text: answer, done: true)
    }

    private func writeNotes(animated: Bool) async {
        let notes = """
            ## Summary
            Acme renews for a year and grows from twenty seats to fifty. They asked for a discount.

            ## Decisions
            - Yearly plan, fifty seats.
            - 10% off if they sign by Friday.

            ## Action items
            - **You:** send the updated contract today.
            - **Rahul:** share the pricing sheet with their finance team.
            """
        guard state.notes.isEmpty else { return }
        if animated {
            state.writingNotes = true
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { state.writingNotes = false; return }
        }
        state.setNotes(notes)
        state.writingNotes = false
    }

    /// The level chips move as they would in a call: theirs mostly, yours now and then.
    private func startLevels() {
        levels = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = Date().timeIntervalSinceReferenceDate
                self.state.callLevel = Float(max(0, sin(t * 1.3))) * Float.random(in: 0.35...0.9)
                self.state.micLevel = Float(max(0, sin(t * 0.7 + 2))) * Float.random(in: 0.2...0.6)
            }
        }
    }

    private func stopLevels() {
        levels?.invalidate()
        levels = nil
        state.callLevel = 0
        state.micLevel = 0
    }
}

/// The offer card, as it appears at the top right of the screen when a call starts.
public struct MeetingDemoOffer: View {
    let take: () -> Void
    let later: () -> Void

    public init(take: @escaping () -> Void, later: @escaping () -> Void) {
        self.take = take
        self.later = later
    }

    @MainActor public static var size: CGSize { MeetingPrompt.size }

    public var body: some View {
        PromptView(app: "Zoom", start: take, dismiss: later)
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

/// The notes panel, as it sits beside a call, playing the tour's call. `tabs` gets where its tabs are.
public struct MeetingDemoPanel: View {
    @ObservedObject var demo: MeetingDemo
    let tabs: (CGRect) -> Void

    public init(demo: MeetingDemo, tabs: @escaping (CGRect) -> Void) {
        self.demo = demo
        self.tabs = tabs
    }

    /// The panel's width, as it first opens beside a call.
    public static let width: CGFloat = 430

    public var body: some View {
        CardView(state: demo.state, mode: demo.mode, onTabs: tabs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            .allowsHitTesting(false)
    }
}
