import AgentKit
import AppKit
import AVFoundation
import MurmurIndex
import Observation
import Quartz
import SwiftUI
import VoiceKit

/// The sections of Murmur's window.
enum HomeSection: String, CaseIterable, Identifiable {
    /// `day` ("Your day") isn't in the sidebar: the morning brief's notification opens it, and the Memory page links it.
    case home, search, dictation, commands, memory, folders, about, day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .dictation: "Settings"
        case .commands: "Commands & AI"
        case .memory: "Memory"
        case .folders: "Folders"
        case .about: "About"
        case .day: "Your day"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .dictation: "gearshape"
        case .commands: "sparkles"
        case .memory: "brain"
        case .folders: "folder"
        case .about: "info.circle"
        case .day: "sun.horizon"
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
        case .dictation: SettingsPage(app: app, state: state)
        case .commands: CommandsPage(dictation: app.dictation, state: state)
        case .memory: MemoryPage(app: app, state: state)
        case .folders: FoldersPage(app: app, state: state)
        case .about: AboutPage(app: app)
        case .day: DayPage(app: app, state: state)
        }
    }
}

/// Murmur's tile: the starling on warm cream, as on the app icon.
struct BrandTile: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Color(red: 1.0, green: 0.945, blue: 0.910))
            .frame(width: size, height: size)
            .overlay { StarlingMark(.color, legs: size >= 60).padding(size * 0.1) }
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06)))
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
        let key = dictation.key.short
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
                    Text("Voice for your Mac · \(AppVersion.current)").font(.system(size: 11)).foregroundStyle(Theme.ink2)
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
            SectionLabel("Make it yours")
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 8)
            VStack(spacing: 2) {
                item(.commands, accessory: commandsBadge)
                item(.memory)
                item(.folders, accessory: foldersBadge)
                item(.dictation)
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 16)
            if let version = app.model.updateAvailable {
                updateCard(version).padding(.horizontal, 12).padding(.bottom, 8)
            }
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
        // "Your day" belongs to Memory (it isn't in the sidebar itself).
        let selected = state.section == section || (section == .memory && state.section == .day)
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

    /// A newer Murmur is waiting: say which, and install it from here (Sparkle's window, with Install).
    private func updateCard(_ version: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Murmur \(version) is ready").font(.system(size: 12, weight: .semibold))
                Text("You have \(AppVersion.current)").font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Button("Update Now") { app.updates.checkNow() }
                .buttonStyle(.murmurPrimaryCompact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accentTint))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accentRing))
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
    private var keyLabel: String { dictation.key.cap }

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
                    Gesture(keys: [keyLabel, dictation.commandModifier.symbol], plus: true, title: "Only a command",
                            detail: "Murmur usually tells by itself. Add \(dictation.commandModifier.symbol) when it guesses wrong.")
                    Gesture(keys: [keyLabel, dictation.typingModifier.symbol], plus: true, title: "Only type",
                            detail: "Add \(dictation.typingModifier.symbol) and it's always typed, never run as a command.")
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
                          detail: dictation.speechModel.card,
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
        case .waiting: dictation.speechModelChosen ? .working("Waiting", nil) : .working("Choose a language", nil)
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

/// Fitting text to the sentence, and the Ultra update for other languages. Its own view, so the download's progress
/// refreshes.
private struct SpeechAccuracyRows: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        if dictation.multilingualUpdate != nil || dictation.multilingualUpdateAvailable {
            RowDivider()
            SettingRow(title: "More accurate other languages",
                       detail: "Parakeet Ultra makes fewer mistakes in all 25 languages. A one-time download, about 630 MB; "
                           + "dictation keeps working while it downloads.") {
                if let progress = dictation.multilingualUpdate {
                    Text("Downloading · \(Int((progress * 100).rounded()))%")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        .monospacedDigit()
                } else {
                    Button("Update") { dictation.updateMultilingual() }.buttonStyle(.murmurSecondary)
                }
            }
        }
        RowDivider()
        SettingRow(title: "Microphone", detail: microphoneDetail(dictation.microphoneInUse())) {
            let devices = dictation.microphones()
            Picker("Microphone", selection: Binding(get: { dictation.microphoneUID ?? "" },
                                                    set: { dictation.microphoneUID = $0.isEmpty ? nil : $0 })) {
                Text("Automatic").tag("")
                ForEach(devices) { device in Text(device.name).tag(device.uid) }
                if let chosen = dictation.microphoneUID, !devices.contains(where: { $0.uid == chosen }) {
                    Text("Not connected").tag(chosen)
                }
            }
            .labelsHidden()
            .frame(width: 230)
        }
        if dictation.microphoneUID == nil {
            RowDivider()
            SettingRow(title: "Use the Mac's microphone over AirPods",
                       detail: "AirPods and other Bluetooth headsets drop to phone-call sound while their microphone is on, "
                           + "so Murmur hears you less clearly and may miss your first word. Not when the lid is closed.") {
                MurmurSwitch(label: "Use the Mac's microphone over AirPods",
                             isOn: Binding(get: { dictation.preferBuiltInMic }, set: { dictation.preferBuiltInMic = $0 }))
            }
        }
        RowDivider()
        SettingRow(title: "Murmur button on screen",
                   detail: "A small Murmur pill on your screen. Click it to open Murmur, drag it wherever you like, "
                       + "right-click to start dictating or hide it.") {
            MurmurSwitch(label: "Murmur button on screen",
                         isOn: Binding(get: { dictation.showLogo }, set: { dictation.showLogo = $0 }))
        }
        RowDivider()
        SettingRow(title: "Fit to the sentence",
                   detail: "Adds the space before what you say, and leaves out the capital and full stop when it goes into "
                       + "the middle of a sentence. Your words are never changed.") {
            MurmurSwitch(label: "Fit to the sentence",
                         isOn: Binding(get: { dictation.fitText }, set: { dictation.fitText = $0 }))
        }
    }

    private func microphoneDetail(_ inUse: AudioDevices.Input?) -> String {
        guard let inUse else { return "No microphone found." }
        var line = "Listening with \(inUse.name)."
        if inUse.isBluetooth { line += " Bluetooth microphones are less accurate than the Mac's own." }
        return line
    }
}

/// AI cleanup: off by default. When on, fillers and stumbles come out, self-corrections are applied and lists set
/// out, in a style for each kind of app.
private struct CleanupSettings: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        SettingsSection("AI cleanup") {
            SettingRow(title: "Tidy up what you say",
                       detail: "Takes out “um”, “uh” and repeated words, keeps only the corrected version when you correct "
                           + "yourself (“at 5, no, 6pm” → “at 6pm”) and sets out spoken lists. Nothing else is changed: "
                           + "if the model rewrites, answers or drops anything, or takes over 4 seconds, your words go in "
                           + "as heard. The menu's “Paste Exactly What I Said” brings back the original.") {
                MurmurSwitch(label: "Tidy up what you say",
                             isOn: Binding(get: { dictation.aiCleanup }, set: { dictation.aiCleanup = $0 }))
            }
            if dictation.aiCleanup {
                RowDivider()
                SettingRow(title: "Model", detail: modelDetail) {
                    HStack(spacing: 8) {
                        if own.choice == .murmur {
                            switch own.phase {
                            case .missing where CleanupModel.source != nil, .failed:
                                Button("Download \(CleanupModel.sizeText)") { own.start() }
                            case .downloading:
                                ProgressView().controlSize(.small)
                            default:
                                EmptyView()
                            }
                        }
                        Picker("Cleanup model", selection: Binding(get: { own.choice }, set: { own.choice = $0 })) {
                            ForEach(CleanupModel.Choice.allCases, id: \.self) { Text($0.display).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .disabled(own.isDownloading)
                    }
                }
                .task { await own.refresh() }
                ForEach(DictationCleanup.Category.allCases, id: \.self) { category in
                    RowDivider()
                    SettingRow(title: category.display, detail: category.examples) {
                        Picker(category.display, selection: Binding(get: { dictation.cleanupStyle(for: category) },
                                                                    set: { dictation.setCleanupStyle($0, for: category) })) {
                            ForEach(category.styles, id: \.self) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: category.styles.count == 3 ? 270 : 180)
                    }
                }
            }
        }
    }

    private var own: CleanupModel { CleanupModel.shared }

    private var modelDetail: String {
        let fallback: String
        if dictation.cleanupModel == "Local model" {
            fallback = "the local model (Ollama) set in Commands & Assistants. Your words stay on this Mac."
        } else {
            fallback = "\(dictation.cleanupModel), as set in Commands & Assistants. What you dictate is sent to it to be tidied."
        }
        guard own.choice == .murmur else { return "Uses " + fallback }
        let about = "Murmur's own model, made only for tidying dictation: on this Mac, in a fraction of a second."
        switch own.phase {
        case .ready:
            return about + " Your words stay on this Mac."
        case .unknown:
            return about
        case .noOllama:
            return about + " It runs in Ollama, which isn't installed. Until then, cleanup uses " + fallback
        case .missing where CleanupModel.source == nil:
            return about + " It isn't on this Mac yet (build it with murmur-models). Until then, cleanup uses " + fallback
        case .missing:
            return about + " Download it (\(CleanupModel.sizeText)); until then, cleanup uses " + fallback
        case .downloading(let part):
            return about + " Downloading, \(Int(part * 100))%. Until it's in, cleanup uses " + fallback
        case .failed(let why):
            return about + " \(why) Until it's in, cleanup uses " + fallback
        }
    }
}

/// All of Murmur's settings on one page: the language you speak, the talk key, commands, indexing, the app, and what's
/// kept. Folders, the AI for commands, and memory have their own pages, linked from here.
private struct SettingsPage: View {
    let app: AppController
    let state: HomeState
    @ObservedObject private var history = DictationHistory.shared

    private var dictation: DictationController { app.dictation }

    var body: some View {
        let _ = state.revision
        let settings = app.model.settings
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: "Settings",
                       subtitle: "Speech, commands and indexing. Everything runs on this Mac unless you add an AI key.")
            SettingsSection("Speech") {
                LanguageChoice(dictation: dictation)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                RowDivider()
                SettingRow(title: "Clear voice",
                           detail: "Takes out background noise and echo at the microphone, as FaceTime does. For a noisy room or "
                               + "speakers playing: in a quiet room Murmur hears you better without it.") {
                    MurmurSwitch(label: "Clear voice",
                                 isOn: state.bind(get: { dictation.clearVoice }, set: { dictation.clearVoice = $0 }))
                }
                RowDivider()
                SettingRow(title: "Quiet voice", detail: "Boosts soft speech more, for open offices and late nights. Still on this Mac.") {
                    MurmurSwitch(label: "Quiet voice",
                                 isOn: state.bind(get: { dictation.whisperMode }, set: { dictation.whisperMode = $0 }))
                }
                RowDivider()
                SettingRow(title: "Set the microphone level",
                           detail: "Murmur raises a microphone that’s turned down and adjusts it as you dictate, so your "
                               + "voice arrives clearly. It changes the input level in System Settings › Sound.") {
                    MurmurSwitch(label: "Set the microphone level",
                                 isOn: state.bind(get: { dictation.adjustsMicLevel }, set: { dictation.adjustsMicLevel = $0 }))
                }
                RowDivider()
                SettingRow(title: "Catch your first word",
                           detail: "Keeps the microphone ready for a minute after you dictate, so the next dictation starts at once "
                               + "and includes the half second before you pressed the key. Nothing is kept beyond that half second.") {
                    MurmurSwitch(label: "Catch your first word",
                                 isOn: state.bind(get: { dictation.micStaysReady }, set: { dictation.micStaysReady = $0 }))
                }
                RowDivider()
                SettingRow(title: "Words on screen",
                           detail: "Listens for the names in the window's title, like a page or project. Only a word Murmur "
                               + "wasn't sure it heard is corrected. English only; a one-time download, about 106 MB.") {
                    MurmurSwitch(label: "Words on screen",
                                 isOn: state.bind(get: { dictation.listensForScreenWords },
                                                  set: { dictation.listensForScreenWords = $0 }))
                }
                RowDivider()
                SettingRow(title: "Your words",
                           detail: "Names and terms Murmur should spell right, separated by commas. Only a word Murmur "
                               + "wasn't sure it heard is corrected.") {
                    TextField("Copico, Parakeet, Sudoku", text: state.bind(get: { dictation.dictationWords },
                                                                         set: { dictation.dictationWords = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .frame(width: 230)
                }

                SpeechAccuracyRows(dictation: dictation)
            }
            CleanupSettings(dictation: dictation)
            SettingsSection("Shortcuts") {
                SettingRow(title: "Talk",
                           detail: "Hold it and speak: Murmur works out whether it's typed or done. Double-tap for hands-free; "
                               + "tap again to finish, Esc cancels. If fn opens the emoji picker, set Keyboard → “Press 🌐 key "
                               + "to” → Do Nothing, or pick another key.") {
                    Picker("Talk key", selection: state.bind(get: { dictation.key }, set: { dictation.setKey($0) })) {
                        ForEach(DictationKeyMonitor.Key.allCases, id: \.self) { Text($0.display).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 290)
                }
                RowDivider()
                SettingRow(title: "Only type",
                           detail: "Hold it with \(dictation.key.short): always typed where your cursor is, never a command.") {
                    modifierPicker("Only type", get: { dictation.typingModifier }, set: { dictation.setTypingModifier($0) })
                }
                RowDivider()
                SettingRow(title: "Only a command",
                           detail: "Hold it with \(dictation.key.short): always carried out, never typed.") {
                    modifierPicker("Only a command", get: { dictation.commandModifier }, set: { dictation.setCommandModifier($0) })
                }
                RowDivider()
                SettingRow(title: "Search files",
                           detail: "Opens the search panel from any app. Click the keys and press new ones to change it.") {
                    ShortcutRecorder(combo: app.model.hotkey, apply: { app.setHotkey($0) },
                                     listening: { app.hotkeyRecording($0) }, capSize: 13)
                }
            }
            SettingsSection("Commands") {
                SettingRow(title: "Tell commands from dictation",
                           detail: "“Open Slack” or “PDF kholo” runs; “see you at 5” is typed. Off: only \(dictation.key.short) with \(dictation.commandModifier.symbol) runs commands.") {
                    MurmurSwitch(label: "Tell commands from dictation",
                                 isOn: state.bind(get: { dictation.detectCommands }, set: { dictation.detectCommands = $0 }))
                }
                RowDivider()
                SettingRow(title: "AI for commands", detail: RouterChoice.current.display) {
                    Button("Change…") { state.section = .commands }.buttonStyle(.murmurSecondary)
                }
                RowDivider()
                SettingRow(title: "Memory", detail: "What you've told Murmur, and what it noticed from your commands.") {
                    Button("Open…") { state.section = .memory }.buttonStyle(.murmurSecondary)
                }
            }
            SettingsSection("Permissions") {
                // "Always Allow …" in a Go Ahead? panel turns these on; this is where to take it back.
                ForEach(Array(Permission.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { RowDivider() }
                    SettingRow(title: kind.display,
                               detail: kind.alwaysAllowed ? "Goes ahead without asking." : "Asks first (or once per task).") {
                        MurmurSwitch(label: kind.display,
                                     isOn: state.bind(get: { kind.alwaysAllowed }, set: { kind.alwaysAllowed = $0 }))
                    }
                }
                RowDivider()
                Text("Anything that pays, buys or transfers money always asks.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SkillsSettings()
            SettingsSection("Indexing") {
                SettingRow(title: "Folders",
                           detail: settings.roots.isEmpty ? "No folders yet."
                               : "\(settings.roots.count) folder\(settings.roots.count == 1 ? "" : "s") searched.") {
                    Button("Manage…") { state.section = .folders }.buttonStyle(.murmurSecondary)
                }
                RowDivider()
                SettingRow(title: "Pause indexing", detail: "Search keeps working; new and changed files wait until you resume.") {
                    MurmurSwitch(label: "Pause indexing",
                                 isOn: state.bind(get: { app.model.status.paused }, set: { app.engine.setPaused($0) }))
                }
                RowDivider()
                SettingRow(title: AppSettings.batteryTitle, detail: AppSettings.batteryDetail) {
                    MurmurSwitch(label: AppSettings.batteryTitle,
                                 isOn: state.bind(get: { app.model.settings.indexOnBattery },
                                                  set: { app.setIndexOnBattery($0) }))
                }
                RowDivider()
                SettingRow(title: "Index only at set hours",
                           detail: "Files are read only between these times. Search works all day.") {
                    HStack(spacing: 8) {
                        if settings.indexHoursOn {
                            DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text("to").foregroundStyle(Theme.ink2)
                            DatePicker("To", selection: time(\.end), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        MurmurSwitch(label: "Index only at set hours",
                                     isOn: state.bind(get: { app.model.settings.indexHoursOn }, set: { on in
                                         app.setIndexHours(on: on, hours: app.model.settings.indexHours)
                                     }))
                    }
                }
            }
            SettingsSection("App") {
                SettingsPane(tab: .general, state: app.settingsWindow.state, embedded: true)
                    .task { await app.settingsWindow.state.refresh() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsSection("Recordings and history") {
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
                SettingRow(title: "Keep recordings",
                           detail: "Saves every recording and what Murmur heard to Documents › Murmur Recordings, to compare speech models.") {
                    HStack(spacing: 10) {
                        Button("Show") { dictation.showRecordings() }.buttonStyle(.murmurSecondary)
                        MurmurSwitch(label: "Keep recordings",
                                     isOn: state.bind(get: { dictation.keepRecordings }, set: { dictation.keepRecordings = $0 }))
                    }
                }
                RowDivider()
                SettingRow(title: "Last recording", detail: "Save what the microphone heard, to check its quality.") {
                    Button("Save…") { dictation.saveLastRecording() }.buttonStyle(.murmurSecondary)
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

    /// "fn + [⇧ Shift ▾]": which key, held with the talk key, chooses typing or a command.
    private func modifierPicker(_ label: String, get: @escaping () -> DictationKeyMonitor.Modifier,
                                set: @escaping (DictationKeyMonitor.Modifier) -> Void) -> some View {
        HStack(spacing: 6) {
            KeyCap(dictation.key.cap)
            Text("+").font(.system(size: 11)).foregroundStyle(Theme.ink3)
            Picker(label, selection: state.bind(get: get, set: set)) {
                ForEach(dictation.modifierChoices, id: \.self) { Text("\($0.symbol) \($0.name)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
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

    /// One end of the set hours, as a time of day for a date picker.
    private func time(_ end: KeyPath<IndexHours, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = app.model.settings.indexHours[keyPath: end]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let hours = app.model.settings.indexHours
            app.setIndexHours(on: true, hours: end == \IndexHours.start ? IndexHours(start: minute, end: hours.end)
                                                                        : IndexHours(start: hours.start, end: minute))
            state.revision += 1
        })
    }
}

// MARK: - Skills

/// The agent's skills: what each is for, whether it's on (always, when the task fits, or off), and adding one from
/// a GitHub link or the Skills folder.
private struct SkillsSettings: View {
    @ObservedObject private var library = SkillLibrary.shared
    @State private var link = ""
    @State private var adding = false
    @State private var status: (text: String, good: Bool)?

    var body: some View {
        let _ = library.revision
        SettingsSection("Skills") {
            ForEach(Array(library.skills.enumerated()), id: \.element.id) { index, skill in
                if index > 0 { RowDivider() }
                row(skill)
            }
            if !library.skills.isEmpty { RowDivider() }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Skill link", text: $link,
                              prompt: Text("GitHub link to a skill's folder or SKILL.md"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(adding ? "Adding…" : "Add Skill", action: add)
                        .buttonStyle(.murmurPrimaryCompact)
                        .disabled(adding || link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 8) {
                    if let status {
                        Text(status.text).font(.system(size: 12))
                            .foregroundStyle(status.good ? Theme.good : Theme.accentText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Skills Folder") { library.openFolder() }.buttonStyle(.murmurSecondaryCompact)
                    Button("Reload") { library.reload() }.buttonStyle(.murmurSecondaryCompact)
                }
                Text("Skills are instructions the agent follows, in the same format as Claude's: a folder with a SKILL.md. "
                     + "“Always” ones shape every command; “When it fits” ones are used when a task matches. "
                     + "Put your own in the Skills folder and press Reload.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private func row(_ skill: Skill) -> some View {
        SettingRow(title: skill.name, detail: detail(skill)) {
            HStack(spacing: 10) {
                if let tool = skill.requires, SkillLibrary.toolPath(tool) == nil {
                    if let install = skill.install, let url = URL(string: install) {
                        Button("Get \(tool)…") { NSWorkspace.shared.open(url) }.buttonStyle(.murmurSecondaryCompact)
                    } else {
                        Pill(text: "Needs \(tool)", tone: .attention)
                    }
                }
                if !skill.builtIn {
                    Button("Remove") {
                        library.remove(skill)
                        status = ("Removed \(skill.name) (it's in the Trash).", true)
                    }
                    .buttonStyle(.murmurDestructive)
                }
                Picker(skill.name, selection: Binding(get: { library.mode(of: skill) },
                                                      set: { library.setMode($0, for: skill) })) {
                    ForEach(Skill.Mode.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
            }
        }
    }

    private func detail(_ skill: Skill) -> String {
        var text = skill.description.count > 220 ? String(skill.description.prefix(217)) + "…" : skill.description
        if let tool = skill.requires, SkillLibrary.toolPath(tool) == nil {
            text += "\nNeeds \(tool), which isn't installed on this Mac: it turns on by itself once it is."
        }
        text += skill.builtIn ? "\nComes with Murmur." : "\nYours" + (skill.source.map { ", from \($0)" } ?? "") + "."
        return text
    }

    private func add() {
        let wanted = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !adding else { return }
        adding = true
        status = ("Downloading…", true)
        Task {
            do {
                let skill = try await library.add(from: wanted)
                status = ("Added \(skill.name). It's set to “\(library.mode(of: skill).display)”.", true)
                link = ""
            } catch {
                status = (error.localizedDescription, false)
            }
            adding = false
        }
    }
}

// MARK: - Memory

/// What Murmur remembers, in three short lists: what you told it, what it noticed, what you asked lately. Each line
/// can be forgotten on its own; one switch stops remembering commands, one button forgets everything.
private struct MemoryPage: View {
    let app: AppController
    let state: HomeState
    @State private var confirmingClear = false
    @State private var question = ""
    @State private var answers: [BrainStore.Hit]?
    @State private var kind: BrainModel.EntityKind = .person
    @State private var open: Int64?
    @State private var showAllScreen = false

    private var brain: Brain { Brain.shared }

    var body: some View {
        let _ = state.revision
        let _ = brain.revision
        let told = CommandMemory.toldFacts()
        let noticed = CommandMemory.learned()
        let recent = CommandMemory.recentCommands(limit: 8)
        let counts = brain.store.counts()
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: "Memory",
                       subtitle: "Murmur’s second brain: who’s who, what’s coming up, and what you told it. It keeps "
                           + "itself current, forgets what’s gone, and stays on this Mac.") {
                Button(brain.activity == nil ? "Sync Now" : "Syncing…") { Task { await brain.sync(now: true) } }
                    .buttonStyle(.murmurSecondary)
                    .disabled(brain.activity != nil)
            }
            ask
            sources
            screen
            if ScreenMemory.shared.settings.enabled { loopsAndToday }
            apps
            if ScreenMemory.shared.settings.enabled {
                threadsSection
                workedOn
                fromScreen
            }
            known(total: counts.entities)
            lately
            list("You told Murmur", items: told,
                 empty: "Nothing yet. Say “remember that…” or “from now on…”, like “remember that Mom is Roma on WhatsApp”.")
            list("Murmur noticed", items: noticed,
                 empty: "Patterns in what you ask show up here, like who you message where. Nothing yet.")
            list("Recent commands", items: recent, empty: "Commands you give appear here.")
            HStack(spacing: 12) {
                MurmurSwitch(label: "Remember commands",
                             isOn: state.bind(get: { CommandMemory.remembersCommands },
                                              set: { CommandMemory.remembersCommands = $0 }))
                Text("Remember commands").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                Spacer()
                Button("Forget Everything…") { confirmingClear = true }
                    .buttonStyle(.murmurDestructive)
                    .disabled(told.isEmpty && recent.isEmpty && counts.memories == 0)
            }
        }
        .alert("Forget everything?", isPresented: $confirmingClear) {
            Button("Forget Everything", role: .destructive) {
                CommandMemory.forget(all: true, facts: true)
                brain.forgetAll()
                ScreenMemory.shared.forgetAll()
                answers = nil
                state.revision += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Murmur forgets every command, everything you told it, and everything it learned from your apps. "
                 + "Sources that are on teach it again at the next sync. This can't be undone.")
        }
    }

    // MARK: Ask

    private var ask: some View {
        SettingsSection("Ask your memory") {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.ink3)
                TextField("Who is Priya? When did I last meet Arjun? What’s coming up?", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .onSubmit { search() }
                if !question.isEmpty {
                    Button("Ask") { search() }.buttonStyle(.murmurSecondaryCompact)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            if let answers {
                RowDivider()
                if answers.isEmpty {
                    note("Nothing known about that yet.")
                } else {
                    ForEach(answers) { hit in
                        memoryRow(hit.memory, about: hit.about)
                    }
                }
            }
        }
    }

    private func search() {
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { answers = nil; return }
        answers = brain.store.search(query, limit: 12)
    }

    // MARK: Sources

    private var sources: some View {
        SettingsSection("Where it learns from") {
            if let activity = brain.activity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                RowDivider()
            }
            ForEach(Array(BrainSource.allCases.enumerated()), id: \.element) { index, source in
                if index > 0 { RowDivider() }
                sourceRow(source)
            }
            RowDivider()
            driveRow
            if let download = ReaderDownload.shared.summary {
                RowDivider()
                note(download + " Notes, Mail, connected apps and what you work on are read with it, on this Mac.")
            } else if brain.reader == nil {
                RowDivider()
                note("Notes, Mail, connected apps and what you work on are read by Murmur’s own model, on this Mac. "
                     + "It downloads when you turn one of them on.")
            }
        }
    }

    private func sourceRow(_ source: BrainSource) -> some View {
        let current = brain.state(source)
        var detail = source.about
        if current.enabled, !current.status.isEmpty { detail += "\n" + current.status }
        if current.enabled, let last = current.lastSync {
            detail += " Checked \(last.formatted(.relative(presentation: .named)))."
        }
        return SettingRow(title: source.title, detail: detail) {
            MurmurSwitch(label: source.title, isOn: Binding(
                get: { _ = brain.revision; return current.enabled },
                set: { on in Task { await brain.set(source, enabled: on); state.revision += 1 } }))
        }
    }

    @ViewBuilder
    private var driveRow: some View {
        let drives = BrainSources.googleDriveFolders()
        let roots = Set(app.model.settings.roots.map(\.standardizedFileURL.path))
        let missing = drives.filter { !roots.contains($0.standardizedFileURL.path) }
        SettingRow(title: "Google Drive",
                   detail: drives.isEmpty
                       ? "Install Google Drive for desktop and Murmur can search what’s in your Drive, on this Mac."
                       : missing.isEmpty ? "Your Drive is in Murmur’s folders: its files are searchable."
                       : "Add your Drive to Murmur’s folders, so what’s in its files can be found and asked about.") {
            if drives.isEmpty {
                Button("Get It") { NSWorkspace.shared.open(URL(string: "https://www.google.com/drive/download/")!) }
                    .buttonStyle(.murmurSecondaryCompact)
            } else if !missing.isEmpty {
                Button("Add Drive") {
                    app.applyFolders(app.model.settings.roots + missing)
                    state.revision += 1
                }
                .buttonStyle(.murmurSecondaryCompact)
            } else {
                Pill(text: "Added", tone: .good)
            }
        }
    }

    // MARK: Screen memory

    @State private var confirmingScreenForget = false

    private var screen: some View {
        let memory = ScreenMemory.shared
        let settings = memory.settings
        var detail = "Murmur reads the window you’re working in when it changes (its text, or a picture of it when there’s "
            + "little text), and while you’re away your local model turns it into memories, promises and a record of your "
            + "days. Never password managers, private windows or password fields. Nothing leaves this Mac."
        if let problem = memory.problem { detail += "\n" + problem }
        else if settings.enabled {
            let counts = memory.journal.counts()
            detail += "\n\(memory.running ? "On" : "Starting"): \(counts.snapshots) windows kept, \(counts.openLoops) open loops."
        }
        return SettingsSection("Screen memory") {
            SettingRow(title: "Remember what I work on", detail: detail) {
                MurmurSwitch(label: "Screen memory", isOn: Binding(
                    get: { _ = brain.revision; return memory.settings.enabled },
                    set: { memory.set(enabled: $0); state.revision += 1 }))
            }
            if settings.enabled {
                RowDivider()
                SettingRow(title: "Only during work hours",
                           detail: settings.always ? "Reads whenever you use the Mac."
                               : "From \(settings.from):00 to \(settings.to):00\(settings.weekends ? ", every day" : ", weekdays").") {
                    HStack(spacing: 8) {
                        if !settings.always {
                            Picker("From", selection: Binding(get: { memory.settings.from },
                                                              set: { value in memory.update { $0.from = value } })) {
                                ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                            }.labelsHidden().frame(width: 76)
                            Picker("To", selection: Binding(get: { memory.settings.to },
                                                            set: { value in memory.update { $0.to = value } })) {
                                ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                            }.labelsHidden().frame(width: 76)
                            MurmurSwitch(label: "Weekends", isOn: Binding(get: { memory.settings.weekends },
                                                                          set: { value in memory.update { $0.weekends = value } }))
                                .help("Weekends too")
                        }
                        MurmurSwitch(label: "Work hours", isOn: Binding(get: { !memory.settings.always },
                                                                        set: { value in memory.update { $0.always = !value } }))
                    }
                }
                RowDivider()
                SettingRow(title: "Look at windows, not only read them",
                           detail: "Apple Vision reads windows with little text. On Macs with Apple silicon and 16 GB or more, "
                               + "the vision model also looks at a small picture of windows you stayed in, to tell your own "
                               + "conversations and work from websites, demos and adverts. Only while plugged in, away and "
                               + "quiet; each picture is deleted once seen. Needs Screen Recording.") {
                    MurmurSwitch(label: "Pictures", isOn: Binding(get: { memory.settings.rules.pictures },
                                                                  set: { value in memory.update { $0.rules.pictures = value } }))
                }
                if let cloud = cloudReaderChoice {
                    let name = cloud == .anthropic ? "Claude" : "OpenAI"
                    RowDivider()
                    SettingRow(title: "Read with \(name)",
                               detail: "Faster, and while you work: each finished stretch of your work is read by \(name) with "
                                   + "your API key, in seconds, instead of by the model on this Mac. Only the text of those "
                                   + "windows goes, with passwords and codes taken out. Off, everything stays on this Mac.") {
                        MurmurSwitch(label: "Read with \(name)",
                                     isOn: Binding(get: { memory.settings.cloudReader == cloud.rawValue },
                                                   set: { value in memory.update { $0.cloudReader = value ? cloud.rawValue : nil } }))
                    }
                }
                RowDivider()
                SettingRow(title: "Keep what you send",
                           detail: "Messages you send in Slack, Mail, WhatsApp and other conversations are kept as yours: "
                               + "the surest sign of what you promised. Password fields are never read.") {
                    MurmurSwitch(label: "Keep what you send", isOn: Binding(get: { memory.settings.rules.authored },
                                                                            set: { value in memory.update { $0.rules.authored = value } }))
                }
                RowDivider()
                SettingRow(title: "Morning brief and evening wrap-up",
                           detail: "What’s due and where you left off at 9:00, what you did and what’s still open at 18:30.") {
                    MurmurSwitch(label: "Briefs", isOn: Binding(
                        get: { !memory.settings.brief.isEmpty },
                        set: { on in memory.update { $0.brief = on ? "09:00" : ""; $0.wrap = on ? "18:30" : "" } }))
                }
                RowDivider()
                excludedRow(settings.rules.excluded)
                RowDivider()
                HStack {
                    Spacer()
                    Button("Forget What It Saw…") { confirmingScreenForget = true }.buttonStyle(.murmurDestructive)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
        }
        .alert("Forget what screen memory saw?", isPresented: $confirmingScreenForget) {
            Button("Forget", role: .destructive) { memory.forgetAll(); state.revision += 1 }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The windows it kept, your time, open loops, your daily summaries, and what it learned from them.")
        }
    }

    private func excludedRow(_ excluded: [String]) -> some View {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        func name(_ id: String) -> String {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Never read").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Menu("Add App") {
                    ForEach(running, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier!) {
                            let id = app.bundleIdentifier!
                            ScreenMemory.shared.update { if !$0.rules.excluded.contains(id) { $0.rules.excluded.append(id) } }
                            state.revision += 1
                        }
                    }
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                TextField("Or a site, like mybank.com", text: $excludedSite)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                    .onSubmit { excludeSite() }
                Button("Add") { excludeSite() }.buttonStyle(.murmurSecondaryCompact).disabled(!excludedSite.contains("."))
            }
            if excluded.isEmpty {
                Text("Password managers, private windows and password fields are never read.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink3)
            } else {
                ForEach(excluded, id: \.self) { id in
                    HStack {
                        Text(id.contains(".") && !id.contains("com.") && !id.contains("org.") ? id : name(id))
                            .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        Spacer()
                        Button {
                            ScreenMemory.shared.update { $0.rules.excluded.removeAll { $0 == id } }
                            state.revision += 1
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Read \(id) again")
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @State private var excludedSite = ""

    private func excludeSite() {
        var site = excludedSite.lowercased().trimmingCharacters(in: .whitespaces)
        if let host = URL(string: site.contains("://") ? site : "https://" + site)?.host { site = host }
        if site.hasPrefix("www.") { site = String(site.dropFirst(4)) }
        guard site.contains(".") else { return }
        ScreenMemory.shared.update { if !$0.rules.excluded.contains(site) { $0.rules.excluded.append(site) } }
        excludedSite = ""
        state.revision += 1
    }

    @ViewBuilder
    private var loopsAndToday: some View {
        let journal = ScreenMemory.shared.journal
        let loops = journal.loops(limit: 20)
        let start = Calendar.current.startOfDay(for: Date())
        let todays = journal.latestNudges(limit: 12).filter { ($0.kind == "brief" || $0.kind == "wrap") && $0.created >= start }
        // Always: the way to the whole day, then today's brief and wrap-up as sent.
        if ScreenMemory.shared.settings.enabled {
            SettingsSection("Your day") {
                SettingRow(title: "Your whole day",
                           detail: "What’s due and coming up, who’s waiting on you, and what you worked on, in full.") {
                    Button("Open") { state.section = .day }.buttonStyle(.murmurSecondaryCompact)
                }
                if !todays.isEmpty { RowDivider() }
                ForEach(Array(todays.reversed().enumerated()), id: \.offset) { index, nudge in
                    if index > 0 { RowDivider() }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(nudge.title + " · " + nudge.created.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                        Text(nudge.body).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                if ScreenMemory.shared.notificationsAllowed == false {
                    RowDivider()
                    SettingRow(title: "Notifications are off for Murmur",
                               detail: "The morning brief, the evening wrap-up and reminders show here until you allow them.") {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.murmurSecondaryCompact)
                    }
                }
            }
        }
        SettingsSection("Open loops") {
            if loops.isEmpty {
                note("Promises you make or are owed (“I’ll send it Friday”) show up here, and close themselves when "
                     + "Murmur sees they’re done.")
            }
            ForEach(Array(loops.enumerated()), id: \.element.id) { index, loop in
                if index > 0 { RowDivider() }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loop.summary).font(.system(size: 13.5)).foregroundStyle(Theme.ink).lineLimit(2)
                        Text([loop.label, loop.person.isEmpty ? nil : loop.person,
                              loop.due.map { "due " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }]
                            .compactMap { $0 }.joined(separator: ", "))
                            .font(.system(size: 11.5)).foregroundStyle(loop.due.map { $0 < Date() } == true ? Theme.ink2 : Theme.ink3)
                    }
                    Spacer(minLength: 8)
                    Button("Done") { journal.set(loop: loop.id, status: "done"); state.revision += 1 }
                        .buttonStyle(.murmurSecondaryCompact)
                    Button {
                        journal.set(loop: loop.id, status: "dropped")
                        state.revision += 1
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.ink3)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Not a promise")
                    .accessibilityLabel("Not a promise: \(loop.summary)")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
            }
        }
        waitingToBeRead
        let today = Journal.Level.day.period(of: Date())
        let hours = journal.chronicles(.hour, within: today)
        let time = journal.time(from: Calendar.current.startOfDay(for: Date()), to: Date()).prefix(6)
        SettingsSection("Today") {
            if hours.isEmpty && time.isEmpty {
                note("A few sentences for each hour you work, and where your time went, written while you’re away.")
            }
            if !time.isEmpty {
                Text(time.map { "\($0.name) \(Int($0.seconds / 60)) min" }.joined(separator: ", "))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }
            ForEach(hours, id: \.period) { hour in
                RowDivider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(hour.period.suffix(2)):00").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
                        .monospacedDigit().frame(width: 44, alignment: .leading)
                    Text(hour.summary).font(.system(size: 13)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18).padding(.vertical, 9)
            }
        }
    }

    // MARK: Connected apps

    @State private var address = ""
    @State private var adding = false

    private var apps: some View {
        let connectors = Connectors.shared
        return SettingsSection("Connected apps") {
            ForEach(Array(connectors.all.enumerated()), id: \.element.id) { index, connector in
                if index > 0 { RowDivider() }
                appRow(connector, status: connectors.status[connector.id] ?? .off)
            }
            RowDivider()
            HStack(spacing: 10) {
                TextField("Add another app by its MCP server’s address, like mcp.sentry.dev/mcp", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { addApp() }
                Button(adding ? "Connecting…" : "Connect") { addApp() }
                    .buttonStyle(.murmurSecondaryCompact)
                    .disabled(adding || Connector.custom(address) == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            note("You sign in on the app’s own page. Murmur keeps the sign-in in your Keychain, uses the app in commands "
                 + "(it asks before changing anything), and learns from it with your local model.")
            RowDivider()
            SettingRow(title: "Use your memory in Claude Code",
                       detail: "Claude Code, Claude Desktop and Cursor can ask Murmur what it knows (read-only, on this Mac). "
                           + "Copies the command that adds it to Claude Code.") {
                Button("Copy Command") {
                    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/murmur-memory").path
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("claude mcp add --scope user murmur -- \"\(helper)\" mcp", forType: .string)
                }
                .buttonStyle(.murmurSecondaryCompact)
            }
        }
    }

    private func addApp() {
        let text = address
        adding = true
        Task {
            if await Connectors.shared.add(text) != nil { address = "" }
            adding = false
        }
    }

    private func appRow(_ connector: Connector, status: Connectors.Status) -> some View {
        var detail = connector.about
        switch status {
        case .connected(let tools): if tools > 0 { detail += "\nConnected: \(tools) tools." }
        case .failed(let why): detail += "\n" + why
        default: break
        }
        return SettingRow(title: connector.name, detail: detail) {
            switch status {
            case .connecting:
                ProgressView().controlSize(.small)
            case .connected:
                HStack(spacing: 8) {
                    Pill(text: "Connected", tone: .good)
                    Button(connector.custom ? "Remove" : "Disconnect") {
                        if connector.custom { Connectors.shared.remove(connector) } else { Connectors.shared.disconnect(connector) }
                    }
                    .buttonStyle(.murmurSecondaryCompact)
                }
            case .off, .failed:
                Button("Connect") { Task { await Connectors.shared.connect(connector) } }
                    .buttonStyle(.murmurSecondaryCompact)
            }
        }
    }

    // MARK: What it knows

    private func known(total: Int) -> some View {
        let kinds: [BrainModel.EntityKind] = [.person, .organization, .project, .topic, .place]
        let entities = brain.store.entities(kind: kind, limit: 60)
        let me = brain.store.entities(kind: .me, limit: 1).first
        return SettingsSection("What Murmur knows") {
            Picker("", selection: $kind) {
                ForEach(kinds, id: \.self) { Text($0.display).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            if let me, kind == .person {
                RowDivider()
                entityRow(me, name: "You")
            }
            if entities.isEmpty {
                RowDivider()
                note(total == 0 ? "Nothing yet. Turn on a source above, and what Murmur learns shows up here."
                     : "No \(kind.display.lowercased()) yet.")
            }
            ForEach(entities) { entity in
                RowDivider()
                entityRow(entity, name: entity.name)
            }
        }
    }

    @ViewBuilder
    private func entityRow(_ entity: BrainStore.EntityRow, name: String) -> some View {
        let expanded = open == entity.id
        Button {
            withAnimation(.easeOut(duration: 0.15)) { open = expanded ? nil : entity.id }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                if !entity.aliases.isEmpty, entity.kind != .me {
                    Text(entity.aliases.prefix(2).joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(entity.memories)").font(.system(size: 12)).foregroundStyle(Theme.ink3).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .accessibilityLabel("\(name), \(entity.memories) memories")
        if expanded {
            ForEach(brain.store.memories(of: entity.id)) { memory in
                memoryRow(memory, about: nil)
            }
            HStack {
                Spacer()
                Button("Forget \(entity.kind == .me ? "What It Knows About You" : name)") {
                    brain.forget(entity: entity.id)
                    open = nil
                }
                .buttonStyle(.murmurDestructive)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    private func memoryRow(_ memory: BrainModel.Memory, about: String?) -> some View {
        let strength = BrainModel.strength(memory)
        var detail = memory.origin.display
        if let about, !memory.text.localizedCaseInsensitiveContains(about) { detail = about + ", " + detail }
        detail += memory.pinned ? "" : ", " + memory.confirmed.formatted(.relative(presentation: .named))
        if let expires = memory.expires { detail += ", until \(expires.formatted(.dateTime.day().month(.abbreviated)))" }
        return HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(Theme.ink.opacity(0.15 + 0.7 * strength))
                .frame(width: 6, height: 6)
                .help(memory.pinned ? "You told Murmur: it never fades" : "How sure Murmur still is: \(Int(strength * 100))%")
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.text).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(3)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                brain.forget(memory: memory.id)
                if answers != nil { search() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Forget this")
            .accessibilityLabel("Forget \(memory.text)")
        }
        .padding(.leading, 38)
        .padding(.trailing, 18)
        .padding(.vertical, 7)
    }

    // MARK: Lately

    /// Which cloud model could read screen memory: the one picked for commands when it has a key, else whichever has one.
    private var cloudReaderChoice: RouterChoice? {
        if RouterChoice.current != .local, RouterChoice.current.hasKey { return RouterChoice.current }
        return [RouterChoice.anthropic, .openai].first { $0.hasKey }
    }

    /// What's left to read: how many episodes of work (each read once, as a whole), what the reader is doing, the
    /// next few, and a way to read now.
    @ViewBuilder
    private var waitingToBeRead: some View {
        let graph = brain.graph
        let count = graph.unreadCount()
        let next = graph.unread(limit: 6)
        let status = MemoryLog.status()
        SettingsSection("Waiting to be read") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 0 ? "Everything is read" : count == 1 ? "1 episode of your work" : "\(count) episodes of your work")
                        .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                    if let status {
                        Text(status.text + ", " + status.at.formatted(.relative(presentation: .named)))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Button("Read Now") { MemoryLog.requestReading(); state.revision += 1 }
                    .buttonStyle(.murmurSecondaryCompact)
                    .disabled(count == 0)
                    .help("Read what you did now instead of when you step away")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            ForEach(next) { episode in
                RowDivider()
                episodeRow(episode)
            }
            if count > next.count {
                RowDivider()
                note("And \(count - next.count) more. Each stretch of work is read once, as a whole, oldest first.")
            }
        }
    }

    /// Open business with people: whose turn it is, who to follow up with, who you're waiting on, most needed first.
    private var threadsSection: some View {
        let threads = brain.graph.openThreads(limit: 8)
        return SettingsSection("People and replies") {
            if threads.isEmpty {
                note("Emails and messages you send show up here as threads: who it's with, what you asked, whose turn it is, "
                     + "and when to follow up.")
            } else {
                ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                    if index > 0 { RowDivider() }
                    threadRow(thread)
                }
            }
        }
    }

    private func threadRow(_ thread: MemoryThread) -> some View {
        let who: String = thread.person + (thread.organization.isEmpty ? "" : ", \(thread.organization)")
        let when: String = thread.lastAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let standing: String = thread.whose
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(who): \(thread.title)")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(standing), since \(when)")
                    .font(.system(size: 11.5)).foregroundStyle(thread.status == .waiting ? Theme.ink3 : Theme.ink2).lineLimit(1)
                if !thread.ask.isEmpty {
                    Text(thread.ask)
                        .font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Done") { brain.graph.closeThread(thread.id); state.revision += 1 }
                .buttonStyle(.murmurSecondaryCompact)
                .help("Nothing more to do with this one")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    /// What you did, an episode at a time: the latest ones, as the reader named them.
    private var workedOn: some View {
        let episodes = brain.graph.recentEpisodes(limit: showAllScreen ? 30 : 8)
        return SettingsSection("What you worked on") {
            if episodes.isEmpty {
                note("Each stretch of your work (a project, a conversation, a booking) shows up here, with how long it took and how it ended.")
            } else {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    if index > 0 { RowDivider() }
                    episodeRow(episode)
                }
            }
        }
    }

    private func episodeRow(_ episode: MemoryGraph.StoredEpisode) -> some View {
        let minutes = max(1, Int((episode.seconds / 60).rounded()))
        let length = minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
        let when: String = episode.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let apps: String = episode.apps.prefix(3).joined(separator: ", ")
        var parts: [String] = [when, length, apps]
        if !episode.outcome.isEmpty { parts.append(episode.outcome) }
        let detail = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 2) {
            Text(episode.name)
                .font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
            Text(detail)
                .font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
            if !episode.summary.isEmpty {
                Text(episode.summary)
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    /// The newest memories made from what was on screen, so they can be seen (and forgotten) without opening people.
    private var fromScreen: some View {
        let hits = brain.store.fromScreen(limit: showAllScreen ? 60 : 8)
        return SettingsSection("From your screen") {
            if hits.isEmpty {
                note("While you’re away, what you worked on turns into memories here: people, projects and decisions. Nothing yet.")
            } else {
                ForEach(hits) { hit in memoryRow(hit.memory, about: hit.about) }
                if hits.count >= 8 {
                    RowDivider()
                    Button(showAllScreen ? "Show fewer" : "Show more") { showAllScreen.toggle() }
                        .buttonStyle(.murmurSecondaryCompact)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private var lately: some View {
        let changes = brain.store.changes(limit: 12)
        return SettingsSection("Lately") {
            if changes.isEmpty {
                note("What Murmur learns, updates and forgets shows up here.")
            } else {
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    if index > 0 { RowDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(change.what.prefix(1).uppercased() + change.what.dropFirst())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(change.what == "learned" || change.what == "updated" ? Theme.ink2 : Theme.ink3)
                            .frame(width: 62, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.text).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(2)
                            Text([change.origin?.display, change.at.formatted(.relative(presentation: .named))]
                                .compactMap { $0 }.joined(separator: ", "))
                                .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
    }

    // MARK: Commands and what you told it

    private func list(_ title: String, items: [CommandMemory.Item], empty: String) -> some View {
        SettingsSection(title) {
            if items.isEmpty {
                note(empty)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider() }
                    row(item)
                }
            }
        }
    }

    private func row(_ item: CommandMemory.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button {
                CommandMemory.remove(item.id)
                state.revision += 1
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Forget this")
            .accessibilityLabel("Forget \(item.text)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

// MARK: - Commands & AI

private struct CommandsPage: View {
    let dictation: DictationController
    let state: HomeState
    /// The local model: whether it's on this Mac, and its download from here.
    @State private var localModelState: OllamaProbe.State?
    @State private var pullingLocal = false
    @State private var localProblem: String?
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
                SettingRow(title: "Ollama model", detail: localModelDetail) {
                    HStack(spacing: 8) {
                        switch localModelState {
                        case .missingModel:
                            Button(pullingLocal ? "Downloading…"
                                   : "Download \(LocalModels.sizeText(dictation.localRouterModel))") {
                                pullLocalModel()
                            }
                            .disabled(pullingLocal)
                        case .notRunning:
                            Button("Open Ollama") { Task { await OllamaProbe.start(); await checkLocalModel() } }
                        default:
                            EmptyView()
                        }
                        Picker("Ollama model", selection: state.bind(get: { dictation.localRouterModel }, set: { model in
                            dictation.localRouterModel = model
                            localProblem = nil
                            Task { await checkLocalModel() }
                        })) {
                            ForEach(LocalModels.choices, id: \.self) { Text(LocalModels.display($0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .disabled(pullingLocal)
                    }
                }
            }
            .task { await checkLocalModel() }
            SettingsSection("Screen vision") {
                SettingRow(title: "Screenshots go to",
                           detail: "When an app's buttons and text can't be read directly (pictures, canvas apps, icons), Murmur "
                               + "looks at a screenshot of its window. “On this Mac” keeps every screenshot here.") {
                    Picker("Screenshots go to", selection: state.bind(get: { VisionText.mode.rawValue },
                                                                    set: { UserDefaults.standard.set($0, forKey: "screenVision") })) {
                        Text("On this Mac").tag(VisionText.Mode.local.rawValue)
                        Text("The cloud model").tag(VisionText.Mode.cloud.rawValue)
                        Text("Nowhere (text only)").tag(VisionText.Mode.off.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                RowDivider()
                SettingRow(title: "Vision model on this Mac", detail: visionDetail) {
                    HStack(spacing: 8) {
                        Picker("Vision model", selection: state.bind(get: { VisionText.localModel }, set: { model in
                            UserDefaults.standard.set(model, forKey: "visionModel")
                            Task { await VisionSetup.shared.refresh() }
                        })) {
                            ForEach(["qwen3-vl:4b-instruct", "qwen3-vl:8b-instruct", "qwen3-vl:2b-instruct", "qwen3-vl:4b",
                                     "qwen3-vl:8b"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .disabled(VisionSetup.shared.isDownloading)
                        switch VisionSetup.shared.phase {
                        case .missing, .failed:
                            Button("Download") { VisionSetup.shared.start() }
                                .disabled(!VisionSetup.shared.hasRoom)
                        case .downloading:
                            ProgressView().controlSize(.small)
                        default:
                            EmptyView()
                        }
                    }
                }
            }
            .task { await VisionSetup.shared.refresh() }
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

    /// The vision model's row: what it is, and how its download is going.
    private func checkLocalModel() async {
        guard !pullingLocal else { return }
        localModelState = await OllamaProbe.check(model: dictation.localRouterModel)
    }

    private func pullLocalModel() {
        let model = dictation.localRouterModel
        pullingLocal = true
        localProblem = nil
        Task {
            localProblem = await OllamaProbe.pull(model)
            pullingLocal = false
            await checkLocalModel()
        }
    }

    private var localModelDetail: String {
        let model = dictation.localRouterModel
        var text = model == LocalModels.agent
            ? "Murmur Agent is Murmur's own model, trained on its tools: quicker and more accurate than the general "
                + "models here. Used when “On this Mac” is picked."
            : "Used when “On this Mac” is picked. Murmur Agent, Murmur's own model, is quicker and more accurate."
        switch localModelState {
        case .notInstalled: text += " Needs Ollama (ollama.com)."
        case .notRunning: text += " Ollama isn't open."
        case .missingModel: text += " Not downloaded yet."
        default: break
        }
        if let localProblem { text += " The download didn't finish: \(localProblem)" }
        return text
    }

    private var visionDetail: String {
        let vision = VisionSetup.shared
        switch vision.phase {
        case .ready: return "\(vision.model) is installed. Screenshots stay on this Mac."
        case .downloading(let part): return "Downloading \(vision.model): \(Int(part * 100))% of \(vision.sizeText)."
        case .noOllama: return "Needs Ollama (ollama.com). Until then Murmur reads the screen's text."
        case .failed(let why): return why
        case .missing where !vision.hasRoom: return "\(vision.model) needs \(vision.sizeText) and more free disk space."
        default: return "Qwen3-VL through Ollama. 4B Instruct (3.3 GB) answers in seconds; 8B Instruct (6.1 GB) is a "
            + "little more accurate and twice as slow. The plain tags think first and are much slower."
        }
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
                // General (the shortcut, login, updates) is on the Settings page.
            ForEach(SettingsTab.allCases.filter { $0 != .general }, id: \.self) { Text($0.title).tag($0) }
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

/// The version people see ("1.4.1"), from the app's Info.plist.
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
}

private struct AboutPage: View {
    let app: AppController

    /// This version, whether a newer one is waiting, and the button that gets it.
    @ViewBuilder private var updatesRow: some View {
        if !Updates.hasFeed {
            SettingRow(title: "Version \(AppVersion.current)", detail: "This build doesn't check for updates.") { EmptyView() }
        } else if let version = app.model.updateAvailable {
            SettingRow(title: "Murmur \(version) is available", detail: "You have \(AppVersion.current). It installs and restarts Murmur.") {
                Button("Update Now") { app.updates.checkNow() }.buttonStyle(.murmurPrimary)
            }
        } else {
            SettingRow(title: "Version \(AppVersion.current)", detail: app.updates.automaticallyChecks
                       ? "Murmur looks for a newer version every day." : "Automatic checks are off.") {
                Button("Check for Updates") { app.updates.checkNow() }.buttonStyle(.murmurSecondary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Murmur").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                    Text("Version \(AppVersion.current)")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
            }
            Text("Talk anywhere. Find anything. Get it done.")
                .font(.system(size: 18, weight: .medium))
            SettingsSection("Updates") {
                updatesRow
            }
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
                    Text("Speech recognition with NVIDIA Parakeet through FluidAudio (Apache 2.0). Search embeddings with "
                         + "Google DeepMind's EmbeddingGemma 2 on llama.cpp (MIT).")
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
