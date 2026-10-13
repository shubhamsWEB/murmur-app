import AgentKit
import AppKit
import AVFoundation
import Observation
import Quartz
import SwiftUI
import VoiceKit

/// The sections of Murmur's window.
enum HomeSection: String, CaseIterable, Identifiable {
    case home, search, dictation, commands, folders, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .dictation: "Dictation"
        case .commands: "Commands & AI"
        case .folders: "Folders"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .dictation: "waveform"
        case .commands: "sparkles"
        case .folders: "folder"
        case .about: "info.circle"
        }
    }
}

@Observable
final class HomeState {
    var section: HomeSection = .home
    /// The tab on the Folders page (General, Folders, Code, Storage).
    var foldersTab: SettingsTab = .folders
    /// Bumped on every change made on a page, so the page redraws at once (most settings live outside SwiftUI).
    var revision = 0

    /// A binding to a setting kept elsewhere (UserDefaults, the Keychain, the dictation controller) that redraws the
    /// page as soon as it changes.
    func bind<T>(get: @escaping () -> T, set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { _ = self.revision; return get() }, set: { value in
            set(value)
            self.revision += 1
        })
    }
}

/// Murmur's one window: status and recent dictations, then each part's settings.
final class HomeWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    private(set) var window: NSWindow?
    let state = HomeState()

    init(app: AppController) {
        self.app = app
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(_ section: HomeSection? = nil) {
        if let section { state.section = section }
        let window = self.window ?? makeWindow()
        app.present(window)
    }

    private func makeWindow() -> NSWindow {
        // A Quick Look window: Space previews the selected search result.
        let window = QuickLookWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Murmur"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.pageNS
        window.delegate = self
        if UserDefaults.standard.string(forKey: "defaultsSuite") == nil {
            window.setFrameAutosaveName("MurmurMainWindow")
        }
        window.contentView = NSHostingView(rootView: HomeView(app: app, state: state).murmurStyle())
        if window.frame.origin == .zero { window.center() }
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        PreviewPlayback.shared.stop()
        window?.contentView = nil
        window = nil
        app.windowClosed()
    }
}

// MARK: - Layout

/// The window: Murmur's own sidebar (brand, pages, live status) and the page. Search fills its page; the others
/// scroll in a centred column.
private struct HomeView: View {
    let app: AppController
    @Bindable var state: HomeState

    var body: some View {
        HStack(spacing: 0) {
            // Statuses (permissions, models, index, keys) change outside SwiftUI: look again every second or so.
            TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                Sidebar(app: app, state: state, dictation: app.dictation)
            }
            Group {
                if state.section == .search {
                    SearchWindowView(search: app.searchWindow.search, model: app.model, app: app)
                } else {
                    TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                        ScrollView {
                            page
                                .frame(maxWidth: state.section == .home ? 920 : 720, alignment: .leading)
                                .padding(.horizontal, 48)
                                .padding(.top, 56)
                                .padding(.bottom, 48)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.page)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.page)
        .foregroundStyle(Theme.ink)
    }

    @ViewBuilder
    private var page: some View {
        switch state.section {
        case .home: HomePage(app: app, state: state)
        case .search: EmptyView()   // drawn full-size above
        case .dictation: DictationPage(dictation: app.dictation, state: state)
        case .commands: CommandsPage(dictation: app.dictation, state: state)
        case .folders: FoldersPage(app: app, state: state)
        case .about: AboutPage(app: app)
        }
    }
}

/// Murmur's charcoal tile with the coral wave.
struct BrandTile: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Color(red: 0.133, green: 0.118, blue: 0.110))
            .frame(width: size, height: size)
            .overlay {
                HStack(spacing: size * 0.08) {
                    ForEach(Array([0.3, 0.55, 0.85, 0.55, 0.3].enumerated()), id: \.offset) { _, height in
                        Capsule().fill(Theme.accent).frame(width: size * 0.08, height: size * height * 0.62)
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

/// Whether Murmur can be used now, in a few words, for the headline and the sidebar.
struct Readiness {
    let title: String
    let detail: String
    let busy: Bool
    let problem: Bool

    @MainActor
    init(_ dictation: DictationController) {
        let now = Self.state(dictation)
        title = now.0
        detail = now.1
        busy = now.2
        problem = now.3
    }

    @MainActor
    private static func state(_ dictation: DictationController) -> (String, String, Bool, Bool) {
        let key = dictation.key == .fn ? "fn" : "Right ⌥"
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let typing = dictation.canPaste && dictation.isListeningForKey
        switch dictation.speechModelState {
        case .downloading(let f): return ("Getting ready", "Downloading speech · \(Int(f * 100))%", true, false)
        case .preparing, .waiting: return ("Getting ready", "Preparing the speech model", true, false)
        case .failed: return ("Speech didn't load", "See Dictation", false, true)
        case .ready: break
        }
        if !mic || !typing {
            return ("Almost ready", !mic ? "Allow the microphone" : "Allow typing in apps", false, true)
        }
        switch dictation.phase {
        case .listening: return ("Listening…", "Let go of \(key) to finish", true, false)
        case .transcribing: return ("Writing it down…", "One moment", true, false)
        case .idle: return ("Ready when you are", "Hold \(key) anywhere to talk", false, false)
        }
    }

    var dot: Color { problem ? Theme.accent : busy ? Theme.accent : Theme.goodDot }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let app: AppController
    @Bindable var state: HomeState
    @ObservedObject var dictation: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let _ = state.revision
            Color.clear.frame(height: 52)   // the window buttons
            HStack(spacing: 10) {
                BrandTile(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Murmur").font(.system(size: 15, weight: .semibold)).tracking(-0.2)
                    Text("Voice for your Mac").font(.system(size: 11)).foregroundStyle(Theme.ink2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
            VStack(spacing: 2) {
                item(.home)
                item(.search, accessory: AnyView(
                    Text(app.model.hotkey?.display ?? "⇧⌘Space")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.ink3)))
            }
            .padding(.horizontal, 10)
            SectionLabel("Settings")
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 8)
            VStack(spacing: 2) {
                item(.dictation)
                item(.commands, accessory: commandsBadge)
                item(.folders, accessory: foldersBadge)
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 16)
            statusCard.padding(.horizontal, 12)
            Button {
                state.section = .about
            } label: {
                Text("About & Help")
                    .font(.system(size: 12, weight: state.section == .about ? .semibold : .regular))
                    .foregroundStyle(state.section == .about ? Theme.ink : Theme.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private var commandsBadge: AnyView? {
        let current = RouterChoice.current
        if current != .local, !current.hasKey { return AnyView(Pill(text: "Key", tone: .attention)) }
        if current != .local, RouterDiagnostics.isKeyProblem(RouterDiagnostics.lastError) {
            return AnyView(Pill(text: "Key", tone: .attention))
        }
        return nil
    }

    private var foldersBadge: AnyView? {
        if !app.model.hasFolders { return AnyView(Pill(text: "Set up", tone: .attention)) }
        if app.model.activityBadge != nil { return AnyView(Pill(text: "Indexing", tone: .busy)) }
        return nil
    }

    private func item(_ section: HomeSection, accessory: AnyView? = nil) -> some View {
        let selected = state.section == section
        return Button {
            state.section = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.accentText : Theme.ink2)
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                if let accessory { accessory }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.card : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Theme.line : Color.clear))
            .shadow(color: selected ? Color.black.opacity(0.05) : .clear, radius: 1, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var statusCard: some View {
        let ready = Readiness(dictation)
        return HStack(spacing: 10) {
            Circle().fill(ready.dot).frame(width: 8, height: 8)
                .padding(3)
                .background(Circle().fill(ready.dot.opacity(0.18)))
            VStack(alignment: .leading, spacing: 1) {
                Text(ready.title).font(.system(size: 12, weight: .semibold))
                Text(ready.detail).font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }
}

// MARK: - Home

/// Home: is Murmur ready, how to talk to it, your week, things to say, and where each model is.
private struct HomePage: View {
    let app: AppController
    let state: HomeState
    @ObservedObject var dictation: DictationController
    @ObservedObject private var history = DictationHistory.shared

    init(app: AppController, state: HomeState) {
        self.app = app
        self.state = state
        self.dictation = app.dictation
    }

    private var micOK: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    private var typingOK: Bool { dictation.canPaste && dictation.isListeningForKey }
    private var keyLabel: String { dictation.key == .fn ? "fn" : "⌥" }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            if !micOK || !typingOK { permissions }
            IndexingCard(model: app.model)
            hero
            ThingsToSay(key: keyLabel)
            onThisMac
        }
    }

    private var header: some View {
        let ready = Readiness(dictation)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Circle().fill(ready.dot).frame(width: 10, height: 10)
                    .padding(4)
                    .background(Circle().fill(ready.dot.opacity(0.16)))
                Text(ready.title)
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.5)
                    .monospacedDigit()
            }
            Text("Hold \(keyLabel) and talk in any app. Murmur types what you say, or does what you ask.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink2)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !micOK {
                Fix(text: "Murmur can't hear you yet. Allow the microphone.", action: "Allow…") {
                    dictation.openMicrophoneSettings()
                }
            }
            if !typingOK {
                Fix(text: "Murmur can't type into other apps yet. Turn it on in Accessibility.",
                    action: "Open Settings") { dictation.openAccessibilitySettings() }
            }
        }
    }

    // How to talk to it, and what you got out of it this week.
    private var hero: some View {
        HStack(spacing: 0) {
            HStack(alignment: .center, spacing: 28) {
                LiveKey(label: keyLabel, lit: dictation.phase != .idle)
                VStack(alignment: .leading, spacing: 14) {
                    Gesture(keys: [keyLabel], title: "Hold to dictate",
                            detail: "Talk, let go, it's typed where your cursor is.")
                    Gesture(keys: [keyLabel, keyLabel], title: "Double-tap for hands-free",
                            detail: "Tap \(keyLabel) again to finish. Esc cancels.")
                    Gesture(keys: [keyLabel, "⌃"], plus: true, title: "Force a command",
                            detail: "Murmur usually tells by itself. Add ⌃ when it guesses wrong.")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            week
                .padding(24)
                .frame(width: 220, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.cardAlt)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
    }

    @ViewBuilder
    private var week: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("This week").padding(.horizontal, -4)
            if history.isEnabled {
                Stat(value: history.wordsThisWeek.formatted(), label: "words dictated")
                Stat(value: "\(history.minutesSavedThisWeek) min", label: "saved vs. typing")
                Stat(value: history.commandsThisWeek.formatted(), label: "commands done")
            } else {
                Text("Turn on history in Dictation to see your week here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var onThisMac: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On this Mac").font(.system(size: 15, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                ModelCard(name: "Speech",
                          detail: dictation.speechModel == .english ? "Parakeet · English" : "Parakeet · 25 languages",
                          state: speechState)
                ModelCard(name: "File search", detail: "EmbeddingGemma 2", state: searchState) {
                    state.section = .folders
                }
                ModelCard(name: "Commands", detail: RouterChoice.current.display, state: commandsState) {
                    state.section = .commands
                }
            }
        }
    }

    private var speechState: ModelCard.State {
        switch dictation.speechModelState {
        case .waiting: .working("Waiting", nil)
        case .downloading(let f): .working("Downloading \(Int(f * 100))%", f)
        case .preparing(let f): .working("Preparing", f > 0 ? f : nil)
        case .ready: .done("On device")
        case .failed(let message): .problem(message)
        }
    }

    private var searchState: ModelCard.State {
        let download = app.download
        switch download.phase {
        case .ready:
            if let badge = app.model.activityBadge { return .working(badge, nil) }
            switch app.model.status.activity {
            case .starting: return .working("Starting", nil)
            case .failed(let message): return .problem(message)
            default: return app.model.hasFolders ? .done("Ready") : .problem("Choose folders")
            }
        case .needed: return .problem("Not downloaded (865 MB)")
        case .failed(let message): return .problem(message)
        default: return .working(download.progressText, download.fraction)
        }
    }

    private var commandsState: ModelCard.State {
        switch RouterChoice.current {
        case .local: .done("Ollama · \(dictation.localRouterModel)")
        case .anthropic, .openai:
            !RouterChoice.current.hasKey ? .problem("Needs an API key")
                : AnthropicWorkspace.isNeeded(RouterDiagnostics.lastError) ? .problem("Needs a workspace ID")
                : RouterDiagnostics.isKeyProblem(RouterDiagnostics.lastError) ? .problem("Key was rejected")
                : .done("Your API key")
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .semibold)).tracking(-0.4).monospacedDigit()
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
        }
    }
}

/// What you can say, by what you want to do; a click on a phrase copies it.
private struct ThingsToSay: View {
    let key: String
    @State private var copied: String?

    private struct Idea: Identifiable {
        let symbol: String
        let title: String
        let how: String
        let say: [String]
        var id: String { title }
    }

    private var ideas: [Idea] {
        [
            Idea(symbol: "text.cursor", title: "Write anywhere",
                 how: "Click in any text box, hold \(key) and talk.",
                 say: ["Running ten minutes late, start without me"]),
            Idea(symbol: "text.quote", title: "Work on selected text",
                 how: "Select text first, then say what to do with it.",
                 say: ["Summarise this", "Make this more formal"]),
            Idea(symbol: "macwindow", title: "Control your Mac",
                 how: "Apps, settings, websites, several steps in a row.",
                 say: ["Search YouTube for lofi and play the first video", "Check for updates"]),
            Idea(symbol: "doc.text.magnifyingglass", title: "Find and open files",
                 how: "Describe a file: its name, what's in it, what it looks like.",
                 say: ["Open my resume PDF", "Find my beach photos"]),
            Idea(symbol: "chevron.left.forwardslash.chevron.right", title: "Build software",
                 how: "Starts Claude Code or Codex in Terminal, in a new project folder.",
                 say: ["Create a React app with a Hello World page"]),
            Idea(symbol: "sparkles", title: "Ask Murmur",
                 how: "Start with “Murmur” for anything else.",
                 say: ["Murmur, what's 18% of 2,400?"]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Things to say").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Click a phrase to copy it").font(.system(size: 12)).foregroundStyle(Theme.ink2)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3),
                      spacing: 12) {
                ForEach(ideas) { idea in tile(idea) }
            }
        }
    }

    private func tile(_ idea: Idea) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: idea.symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentTint))
                Text(idea.title).font(.system(size: 13.5, weight: .semibold))
            }
            Text(idea.how)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(idea.say, id: \.self) { phrase in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(phrase, forType: .string)
                        copied = phrase
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            if copied == phrase { copied = nil }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("“\(phrase)”")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if copied == phrase {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.good)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill.opacity(0.7)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }
}

/// The big key: charcoal with coral bars while Murmur listens or writes.
private struct LiveKey: View {
    let label: String
    let lit: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text(label)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
            HStack(spacing: 3) {
                ForEach(Array([6.0, 12, 8, 14, 5].enumerated()), id: \.offset) { _, height in
                    Capsule().fill(lit ? Theme.accent : Theme.control).frame(width: 3, height: height)
                }
            }
            .frame(height: 14)
        }
        .foregroundStyle(lit ? Theme.onPrimary : Theme.ink)
        .frame(width: 112, height: 112)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(lit ? Theme.primary : Theme.page))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(lit ? Theme.primary : Theme.control))
        .overlay(alignment: .bottom) {
            if !lit {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 3)
                    .mask(VStack { Spacer(); Rectangle().frame(height: 6) })
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.accentTint)
                .padding(-6)
                .opacity(lit ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: lit)
        .accessibilityLabel(lit ? "Listening" : "Hold \(label) to talk")
    }
}

private struct Gesture: View {
    let keys: [String]
    var plus = false
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if plus, index > 0 {
                        Text("+").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                    }
                    KeyCap(key)
                }
            }
            .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One model on this Mac: name, status pill, what it is, a thin bar while it downloads or prepares.
private struct ModelCard: View {
    enum State {
        case done(String)
        case working(String, Double?)
        case problem(String)
    }

    let name: String
    let detail: String
    let state: State
    var open: (() -> Void)?

    var body: some View {
        Button {
            open?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    pill
                }
                if case .working(_, let fraction) = state { ThinProgress(fraction: fraction) }
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
    }

    @ViewBuilder
    private var pill: some View {
        switch state {
        case .done(let text): Pill(text: text, tone: .good)
        case .working(let text, _): Pill(text: text, tone: .busy).monospacedDigit()
        case .problem(let text): Pill(text: text, tone: .attention)
        }
    }
}

/// Something to fix, with the button that fixes it.
private struct Fix: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 15))
            Text(text).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            Button(action, action: perform).buttonStyle(.murmurPrimaryCompact)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.accentTint.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.accentRing))
    }
}

// MARK: - Dictation

private struct DictationPage: View {
    let dictation: DictationController
    let state: HomeState
    @ObservedObject private var history = DictationHistory.shared

    var body: some View {
        let _ = state.revision
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: "Dictation",
                       subtitle: "How you talk to Murmur, and what it hears. Speech never leaves this Mac.")
            SettingsSection("Talk key") {
                SettingRow(title: "Hold to talk",
                           detail: "If fn opens the emoji picker, set Keyboard → “Press 🌐 key to” → Do Nothing, or use Right ⌥.") {
                    Picker("Talk key", selection: state.bind(get: { dictation.key }, set: { dictation.setKey($0) })) {
                        ForEach(DictationKeyMonitor.Key.allCases, id: \.self) { Text($0.display).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                RowDivider()
                SettingRow(title: "Hands-free", detail: "Double-tap to talk as long as you like; tap again to finish. Esc cancels.") {
                    HStack(spacing: 4) { KeyCap(dictation.key == .fn ? "fn" : "⌥"); KeyCap(dictation.key == .fn ? "fn" : "⌥") }
                }
            }
            SettingsSection("Recognition") {
                SettingRow(title: "Speech model",
                           detail: "English is the most accurate. Multilingual understands 25 languages.") {
                    Picker("Speech model",
                           selection: state.bind(get: { dictation.speechModel }, set: { dictation.setModel($0) })) {
                        ForEach(ParakeetTranscriber.Model.allCases, id: \.self) { Text($0.display).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                RowDivider()
                SettingRow(title: "Whisper mode", detail: "Boosts quiet speech, for open offices and late nights.") {
                    MurmurSwitch(label: "Whisper mode",
                                 isOn: state.bind(get: { dictation.whisperMode }, set: { dictation.whisperMode = $0 }))
                }
                RowDivider()
                SettingRow(title: "Last recording", detail: "Save what the microphone heard, to check its quality.") {
                    Button("Save…") { dictation.saveLastRecording() }.buttonStyle(.murmurSecondary)
                }
            }
            SettingsSection("Commands or text") {
                SettingRow(title: "Tell commands from dictation",
                           detail: "“Open Slack” runs; “see you at 5” is typed. Off: only the key with ⌃ runs commands.") {
                    MurmurSwitch(label: "Tell commands from dictation",
                                 isOn: state.bind(get: { dictation.detectCommands }, set: { dictation.detectCommands = $0 }))
                }
            }
            SettingsSection("Privacy") {
                SettingRow(title: "Keep a history", detail: "Used for “This week” on Home. Stays on this Mac.") {
                    HStack(spacing: 12) {
                        Button("Clear History") { history.clear() }
                            .buttonStyle(.murmurDestructive)
                            .disabled(history.items.isEmpty)
                        MurmurSwitch(label: "Keep a history",
                                     isOn: state.bind(get: { history.isEnabled }, set: { history.isEnabled = $0 }))
                    }
                }
                RowDivider()
                HStack(spacing: 10) {
                    Text("Microphone").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    permission(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized) {
                        dictation.openMicrophoneSettings()
                    }
                    Spacer().frame(width: 16)
                    Text("Typing in other apps").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    permission(dictation.canPaste) { dictation.openAccessibilitySettings() }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private func permission(_ allowed: Bool, fix: @escaping () -> Void) -> some View {
        if allowed {
            Pill(text: "Allowed", tone: .good)
        } else {
            Button("Allow…", action: fix).buttonStyle(.murmurPrimaryCompact)
        }
    }
}

// MARK: - Commands & AI

private struct CommandsPage: View {
    let dictation: DictationController
    let state: HomeState
    @State private var installed: [AssistantCLI: Bool] = [:]
    /// The model picked, held by the page itself so the cards change the moment you click (the setting lives in
    /// UserDefaults, which SwiftUI doesn't watch).
    @State private var picked = RouterChoice.current
    /// Bumped after a key is added, changed or tested: the key rows and pills read it.
    @State private var keysChanged = 0

    var body: some View {
        let _ = state.revision
        let _ = keysChanged
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: "Commands & AI",
                       subtitle: "Common commands like “open Slack” run instantly with no model. Everything else goes to the model you pick here.")
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Model for commands")
                HStack(alignment: .top, spacing: 12) {
                    ForEach(RouterChoice.allCases, id: \.self) { choice in modelCard(choice) }
                }
            }
            SettingsSection("API keys") {
                SettingRow(title: "Anthropic", detail: keyDetail(.anthropic)) {
                    HStack(spacing: 8) {
                        keyPill(.anthropic)
                        Button("Workspace ID…") {
                            dictation.askForWorkspaceID()
                            state.revision += 1
                            keysChanged += 1
                        }
                        .buttonStyle(.murmurSecondary)
                        if RouterChoice.anthropic.hasKey {
                            Button("Test") { dictation.testKey(.anthropic) }.buttonStyle(.murmurSecondary)
                        }
                        Button(RouterChoice.anthropic.hasKey ? "Change…" : "Add Key…") {
                            dictation.askForKey(.anthropic)
                            state.revision += 1
                            keysChanged += 1
                        }
                        .buttonStyle(.murmurSecondary)
                    }
                }
                RowDivider()
                SettingRow(title: "OpenAI", detail: keyDetail(.openai)) {
                    HStack(spacing: 8) {
                        keyPill(.openai)
                        if RouterChoice.openai.hasKey {
                            Button("Test") { dictation.testKey(.openai) }.buttonStyle(.murmurSecondary)
                        }
                        Button(RouterChoice.openai.hasKey ? "Change…" : "Add Key…") {
                            dictation.askForKey(.openai)
                            state.revision += 1
                            keysChanged += 1
                        }
                        .buttonStyle(.murmurSecondary)
                    }
                }
                RowDivider()
                SettingRow(title: "Models", detail: "The model each key uses for commands. Change it if your account names it differently.") {
                    HStack(spacing: 8) {
                        TextField("Claude model", text: state.bind(get: { AnthropicRouter.model }, set: { value in
                            let trimmed = value.trimmingCharacters(in: .whitespaces)
                            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: "anthropicModel")
                        }))
                        .frame(width: 150)
                        TextField("OpenAI model", text: state.bind(get: { OpenAIRouter.model }, set: { value in
                            let trimmed = value.trimmingCharacters(in: .whitespaces)
                            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: "openaiModel")
                            RouterDiagnostics.lastError = nil
                        }))
                        .frame(width: 130)
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
                RowDivider()
                Text("A cloud model gets the command's words, the front app's name, any selected text and, for multi-step "
                     + "tasks, the names of buttons on screen. Speech and files stay on this Mac. Keys are kept in your Keychain.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .lineSpacing(2)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            SettingsSection("Local model") {
                SettingRow(title: "Ollama model", detail: "Used when “On this Mac” is picked. Install with “ollama pull qwen3:4b”.") {
                    Picker("Ollama model", selection: state.bind(get: { dictation.localRouterModel },
                                                              set: { dictation.localRouterModel = $0 })) {
                        ForEach(["qwen3:1.7b", "qwen3:4b", "qwen3:8b", "llama3.2:3b"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
            SettingsSection("Coding agents") {
                ForEach(AssistantCLI.allCases, id: \.self) { helper in
                    agentRow(helper)
                    RowDivider()
                }
                SettingRow(title: "Start without asking",
                           detail: "“Create a React app…” opens the session at once. The agent still asks before running commands.") {
                    MurmurSwitch(label: "Start without asking",
                                 isOn: state.bind(get: { AssistantCLI.autoApprove }, set: { AssistantCLI.autoApprove = $0 }))
                }
                RowDivider()
                SettingRow(title: "New projects go in", detail: nil) {
                    HStack(spacing: 10) {
                        Text(AssistantCLI.projectsFolder().path.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 12, design: .monospaced))
                        Button("Show") {
                            let folder = AssistantCLI.projectsFolder()
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(folder)
                        }
                        .buttonStyle(.murmurSecondaryCompact)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shield").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always asks first").font(.system(size: 13.5, weight: .semibold))
                    Text("Quitting apps, running Shortcuts, and clicking anything that sends, buys, posts or deletes.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.accentTint.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.accentRing))
        }
        .task {
            for helper in AssistantCLI.allCases {
                installed[helper] = await helper.locate() != nil
            }
        }
        .onAppear { picked = RouterChoice.current }
    }

    private static func pretty(_ id: String) -> String {
        switch id {
        case "claude-haiku-5-5": "Claude Haiku 5.5"
        case "claude-sonnet-5-5": "Claude Sonnet 5.5"
        case "gpt-6-luna": "GPT-6 Luna"
        default: id
        }
    }

    private func modelCard(_ choice: RouterChoice) -> some View {
        let selected = picked == choice
        let (name, model, tags): (String, String, [String]) = switch choice {
        case .local: ("On this Mac", "Ollama · \(dictation.localRouterModel)", ["Free", "Private", "Slower"])
        case .anthropic: ("Claude", Self.pretty(AnthropicRouter.model), ["Fastest", "Your key"])
        case .openai: ("OpenAI", Self.pretty(OpenAIRouter.model), ["Fast", "Your key"])
        }
        return Button {
            if choice != .local, !choice.hasKey, !dictation.askForKey(choice) { return }
            RouterChoice.current = choice
            picked = choice
            keysChanged += 1
            state.revision += 1
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.system(size: 13.5, weight: .semibold))
                    Spacer()
                    Circle()
                        .strokeBorder(selected ? Theme.accentText : Theme.control, lineWidth: selected ? 5 : 1.5)
                        .frame(width: 16, height: 16)
                }
                Text(model).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill))
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.line))
            .background(RoundedRectangle(cornerRadius: Theme.radius + 3, style: .continuous)
                .fill(Theme.accentRing).padding(-3).opacity(selected ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func keyDetail(_ choice: RouterChoice) -> String {
        guard choice.hasKey else { return "Not set" }
        let workspace = choice == .anthropic && AnthropicWorkspace.id != nil ? " · workspace set" : ""
        return "Saved in your Keychain" + workspace
    }

    @ViewBuilder
    private func keyPill(_ choice: RouterChoice) -> some View {
        if choice.hasKey {
            let error = RouterChoice.current == choice ? RouterDiagnostics.lastError : nil
            if AnthropicWorkspace.isNeeded(error), choice == .anthropic {
                Pill(text: "Needs workspace", tone: .attention)
            } else if RouterDiagnostics.isKeyProblem(error) {
                Pill(text: "Rejected", tone: .attention)
            } else {
                Pill(text: "Saved", tone: .good)
            }
        }
    }

    private func agentRow(_ helper: AssistantCLI) -> some View {
        let found = installed[helper]
        let install = helper == .claude ? "npm i -g @anthropic-ai/claude-code" : "npm i -g @openai/codex"
        return HStack(spacing: 12) {
            Text(">_")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(found == true ? Theme.accent : Theme.ink2)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(found == true ? Color(red: 0.133, green: 0.118, blue: 0.110) : Theme.fill))
            VStack(alignment: .leading, spacing: 2) {
                Text(helper.display).font(.system(size: 13.5, weight: .semibold))
                Group {
                    if found == nil {
                        Text("Looking…")
                    } else if found == true {
                        Text("Installed · builds apps in Terminal with your subscription")
                    } else {
                        Text("Not installed · ") + Text(install).font(.system(size: 11.5, design: .monospaced))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                MurmurSwitch(label: "Let Murmur ask \(helper.display)",
                             isOn: state.bind(get: { helper.isAllowed }, set: { helper.isAllowed = $0 }))
                Text("Answers questions").font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

// MARK: - Folders

private struct FoldersPage: View {
    let app: AppController
    @Bindable var state: HomeState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Folders",
                       subtitle: "Murmur only searches where you tell it to. Everything is read and indexed on this Mac.") {
                Button {
                    app.chooseFolders()
                } label: {
                    Label("Add Folder", systemImage: "plus")
                }
                .buttonStyle(.murmurPrimary)
            }
            IndexingCard(model: app.model)
            Picker("", selection: $state.foldersTab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            SettingsPane(tab: state.foldersTab, state: app.settingsWindow.state, embedded: true)
                .task(id: state.foldersTab) { await app.settingsWindow.state.refresh() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - About

private struct AboutPage: View {
    let app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Murmur").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
            }
            Text("Talk anywhere. Find anything. Get it done.")
                .font(.system(size: 18, weight: .medium))
            SettingsSection("Help") {
                SettingRow(title: "Run setup again", detail: "Permissions, the talk key, the speech model and the folders to search.") {
                    Button("Start…") { app.showOnboarding() }.buttonStyle(.murmurSecondary)
                }
                RowDivider()
                SettingRow(title: "Log", detail: "What Murmur heard and did, for when something goes wrong.") {
                    Button("Show") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [app.model.settings.indexDirectory.appendingPathComponent("app.log")])
                    }
                    .buttonStyle(.murmurSecondary)
                }
            }
            SettingsSection("Made with") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("File index and search from DigUp by Abdur Rahim (MIT). Speech recognition with NVIDIA Parakeet "
                         + "through FluidAudio (Apache 2.0). Search embeddings with Google DeepMind's EmbeddingGemma 2 on "
                         + "llama.cpp (MIT).")
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Acknowledgements and Licenses") {
                        if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.murmurSecondary)
                }
                .padding(18)
            }
        }
    }
}
