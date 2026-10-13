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
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Brand.paperNS
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

private struct HomeView: View {
    let app: AppController
    let state: HomeState

    var body: some View {
        NavigationSplitView {
            List(HomeSection.allCases, selection: Binding(get: { state.section }, set: { state.section = $0 ?? .home })) {
                section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            if state.section == .search {
                // Search fills the page: field, results grid and preview, right here in Murmur's window.
                SearchWindowView(search: app.searchWindow.search, model: app.model, app: app)
                    .background(Brand.paper)
            } else {
                settingsPage
            }
        }
    }

    private var settingsPage: some View {
        Group {
            // Statuses (permissions, model download, index) change outside SwiftUI: look again every second or so.
            TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                ScrollView {
                    page
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Brand.paper)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch state.section {
        case .home: HomePage(app: app)
        case .search: EmptyView()   // drawn full-size by the detail column
        case .dictation: DictationPage(dictation: app.dictation, state: state)
        case .commands: CommandsPage(dictation: app.dictation, state: state)
        case .folders: FoldersPage(app: app, state: state)
        case .about: AboutPage(app: app)
        }
    }
}

/// A page title with one plain line under it.
private struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.4)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Brand.clay)
        }
        .padding(.bottom, 22)
    }
}

/// A titled group of rows on a soft card.
private struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.clay)
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
        }
        .padding(.bottom, 20)
    }
}

/// One status line: done (coral check) or waiting (an action to fix it).
private struct StatusRow: View {
    let ok: Bool
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Brand.coral : Brand.clay)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Spacer()
            if let action, !ok {
                Button(action.0, action: action.1)
            }
        }
    }
}

// MARK: - Home

/// Home: is Murmur ready, how to use it, and where each model is. One live element: the fn key lights up while
/// Murmur listens.
private struct HomePage: View {
    let app: AppController
    @ObservedObject var dictation: DictationController

    init(app: AppController) {
        self.app = app
        self.dictation = app.dictation
    }

    private var micOK: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    private var typingOK: Bool { dictation.canPaste && dictation.isListeningForKey }
    private var keyLabel: String { dictation.key == .fn ? "fn" : "⌥" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            if !micOK || !typingOK { permissions.padding(.top, 20) }
            howTo.padding(.top, 30)
            ThingsToSay(key: keyLabel).padding(.top, 34)
            models.padding(.top, 34)
        }
    }

    // What state Murmur is in, in one line.
    private var headline: some View {
        let (title, busy) = summary
        return HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(busy ? Brand.coral : Color.primary.opacity(0.7))
                .frame(width: 10, height: 10)
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.4)
                .monospacedDigit()
        }
    }

    private var summary: (String, Bool) {
        switch dictation.speechModelState {
        case .downloading(let f): return ("Getting ready · speech model \(Int(f * 100))%", true)
        case .preparing: return ("Getting ready · preparing speech", true)
        case .waiting: return ("Getting ready", true)
        case .failed: return ("The speech model didn't load", true)
        case .ready: break
        }
        if !micOK || !typingOK { return ("Almost ready", true) }
        switch dictation.phase {
        case .listening: return ("Listening", true)
        case .transcribing: return ("Writing it down", true)
        case .idle: return ("Ready. Hold \(keyLabel) and talk.", false)
        }
    }

    // Only what's missing, with the way to fix it.
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !micOK {
                Fix(text: "Murmur can't hear you yet. Allow the microphone.", action: "Allow…") {
                    dictation.openMicrophoneSettings()
                }
            }
            if !typingOK {
                Fix(text: "Murmur can't type into other apps yet. Turn it on in Accessibility.",
                    action: "Open Settings…") { dictation.openAccessibilitySettings() }
            }
        }
    }

    // The three ways to use it, shown as the keys you press.
    private var howTo: some View {
        HStack(alignment: .top, spacing: 28) {
            LiveKey(label: keyLabel, lit: dictation.phase != .idle)
            VStack(alignment: .leading, spacing: 18) {
                Gesture(keys: [keyLabel], title: "Hold to dictate",
                        detail: "Speak, then let go. The text appears where your cursor is.")
                Gesture(keys: [keyLabel, keyLabel], title: "Double-tap for hands-free",
                        detail: "Tap \(keyLabel) again to finish. Esc cancels.")
                Gesture(keys: [keyLabel, "⌃"], plus: true, title: "Add ⌃ to make it a command",
                        detail: "Murmur tells commands from dictation by itself. Hold ⌃ too when it guesses wrong.")
            }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Models").font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.clay)
                .padding(.bottom, 10)
            ModelRow(name: "Speech", detail: dictation.speechModel == .english ? "Parakeet, English" : "Parakeet, 25 languages",
                     state: speechState)
            Divider()
            ModelRow(name: "File search", detail: "EmbeddingGemma 2", state: searchState)
            Divider()
            ModelRow(name: "Commands", detail: RouterChoice.current.display, state: commandsState)
        }
    }

    private var speechState: ModelRow.State {
        switch dictation.speechModelState {
        case .waiting: .working("Waiting", nil)
        case .downloading(let f): .working("Downloading \(Int(f * 100))%", f)
        case .preparing(let f): .working("Preparing for the Neural Engine", f > 0 ? f : nil)
        case .ready: .done("On this Mac")
        case .failed(let message): .problem(message)
        }
    }

    private var searchState: ModelRow.State {
        let download = app.download
        switch download.phase {
        case .ready:
            if let badge = app.model.activityBadge { return .working(badge, nil) }
            switch app.model.status.activity {
            case .starting: return .working("Starting", nil)
            case .failed(let message): return .problem(message)
            default: return .done(app.model.statusLine)
            }
        case .needed: return .problem("Not downloaded yet (865 MB)")
        case .failed(let message): return .problem(message)
        default: return .working(download.progressText, download.fraction)
        }
    }

    private var commandsState: ModelRow.State {
        switch RouterChoice.current {
        case .local: .done("Ollama, \(dictation.localRouterModel)")
        case .anthropic, .openai:
            !RouterChoice.current.hasKey ? .problem("Needs an API key")
                : AnthropicWorkspace.isNeeded(RouterDiagnostics.lastError) ? .problem("Needs a workspace ID")
                : RouterDiagnostics.isKeyProblem(RouterDiagnostics.lastError) ? .problem("Key was rejected")
                : .done("Your API key")
        }
    }
}

/// What you can say, by what you want to do: each with real phrases to copy.
private struct ThingsToSay: View {
    let key: String

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
                 how: "Click in any text box, hold \(key) and talk. Let go and it's typed.",
                 say: ["Running ten minutes late, start without me"]),
            Idea(symbol: "text.quote", title: "Work on selected text",
                 how: "Select text in any app first, then hold \(key) and say what to do.",
                 say: ["Summarise this", "Make this more formal", "Translate this to Hindi"]),
            Idea(symbol: "macwindow", title: "Control your Mac",
                 how: "Apps, volume, brightness, Shortcuts. Common ones run instantly.",
                 say: ["Open Slack", "Volume 30", "Open Chrome and search Facebook"]),
            Idea(symbol: "doc.text.magnifyingglass", title: "Find and open files",
                 how: "Describe a file: its name, what's in it, what it looks like.",
                 say: ["Open my resume PDF", "Find my beach photos"]),
            Idea(symbol: "sparkles", title: "Ask Murmur",
                 how: "Start with “Murmur” for anything else.",
                 say: ["Murmur, what's 18% of 2,400?"]),
            Idea(symbol: "magnifyingglass", title: "Search by typing",
                 how: "Press ⇧⌘Space anywhere, or use Search in this window.",
                 say: []),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Things to say").font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.clay)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                                GridItem(.flexible(), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(ideas) { idea in tile(idea) }
            }
        }
    }

    private func tile(_ idea: Idea) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: idea.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.tile))
                Text(idea.title).font(.system(size: 14, weight: .semibold))
            }
            Text(idea.how)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !idea.say.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(idea.say, id: \.self) { phrase in
                        Text("“\(phrase)”")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Brand.coralDeep)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Brand.coral.opacity(0.12)))
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// The big key: lit coral while Murmur listens or writes.
private struct LiveKey: View {
    let label: String
    let lit: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(lit ? Color.white : Color.primary)
            .frame(width: 112, height: 112)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(lit ? Brand.coral : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(lit ? Brand.coralDeep : Color.primary.opacity(0.14), lineWidth: 1)
            )
            .background(
                // the key's edge, like a real keycap
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(lit ? Brand.coralDeep : Color.primary.opacity(0.12))
                    .offset(y: 4)
            )
            .animation(.easeOut(duration: 0.15), value: lit)
            .accessibilityLabel(lit ? "Listening" : "Hold \(label) to talk")
    }
}

/// A small keycap.
private struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 26, minHeight: 24)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.16)))
    }
}

private struct Gesture: View {
    let keys: [String]
    var plus = false
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if plus, index > 0 {
                        Text("+").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Keycap(label: key)
                }
            }
            .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Brand.clay)
            }
        }
    }
}

/// One model: name, what it is, where it's at, and a thin progress line while it downloads or prepares.
private struct ModelRow: View {
    enum State {
        case done(String)
        case working(String, Double?)
        case problem(String)
    }

    let name: String
    let detail: String
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 14, weight: .semibold)).frame(width: 110, alignment: .leading)
                Text(detail).font(.system(size: 13)).foregroundStyle(Brand.clay)
                Spacer(minLength: 12)
                status
            }
            if case .working(_, let fraction) = state {
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(Brand.coral)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Brand.coral)
                }
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .done(let text):
            Label(text, systemImage: "checkmark").labelStyle(.titleAndIcon)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        case .working(let text, _):
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.coralDeep).monospacedDigit()
                .lineLimit(1)
        case .problem(let text):
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.coralDeep).lineLimit(1)
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
            Rectangle().fill(Brand.coral).frame(width: 3)
            Text(text).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            Button(action, action: perform)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
        .background(Brand.coral.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Search

// MARK: - Dictation

private struct DictationPage: View {
    let dictation: DictationController
    let state: HomeState
    @ObservedObject private var history = DictationHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Dictation", subtitle: "How you talk to Murmur and what it hears.")
            Card("Key") {
                Picker("Hold to talk", selection: state.bind(get: { dictation.key }, set: { dictation.setKey($0) })) {
                    ForEach(DictationKeyMonitor.Key.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Double-tap for hands-free; tap again to finish, Esc to cancel. If Fn opens the emoji picker, set "
                     + "System Settings → Keyboard → “Press 🌐 key to” → Do Nothing.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Card("Hearing") {
                Picker("Speech model",
                       selection: state.bind(get: { dictation.speechModel }, set: { dictation.setModel($0) })) {
                    ForEach(ParakeetTranscriber.Model.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                Toggle("Whisper Mode: boost quiet speech",
                       isOn: state.bind(get: { dictation.whisperMode }, set: { dictation.whisperMode = $0 }))
                Button("Save Last Recording…") { dictation.saveLastRecording() }
            }
            Card("Commands") {
                Toggle("Tell commands from dictation automatically",
                       isOn: state.bind(get: { dictation.detectCommands }, set: { dictation.detectCommands = $0 }))
                Text("Off: everything is typed unless you hold ⌃ with the key.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Card("History") {
                Toggle("Keep recent dictations on this Mac",
                       isOn: state.bind(get: { history.isEnabled }, set: { history.isEnabled = $0 }))
                Button("Clear History") { history.clear() }
                    .disabled(history.items.isEmpty)
            }
        }
    }
}

// MARK: - Commands & AI

private struct CommandsPage: View {
    let dictation: DictationController
    let state: HomeState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Commands & AI",
                      subtitle: "What picks the actions when you give a command. Speech always stays on your Mac.")
            Card("Router") {
                Picker("Router", selection: state.bind(get: { RouterChoice.current }, set: { choice in
                    if choice != .local, !choice.hasKey, !dictation.askForKey(choice) { return }
                    RouterChoice.current = choice
                })) {
                    ForEach(RouterChoice.allCases, id: \.self) { choice in
                        Text(choice.display + (choice != .local && !choice.hasKey ? " (needs a key)" : "")).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                HStack {
                    Button(RouterChoice.anthropic.hasKey ? "Change Anthropic Key…" : "Add Anthropic Key…") {
                        dictation.askForKey(.anthropic)
                        state.revision += 1
                    }
                    Button(AnthropicWorkspace.id == nil ? "Workspace ID…" : "Workspace ID ✓") {
                        dictation.askForWorkspaceID()
                        state.revision += 1
                    }
                    Button(RouterChoice.openai.hasKey ? "Change OpenAI Key…" : "Add OpenAI Key…") {
                        dictation.askForKey(.openai)
                        state.revision += 1
                    }
                }
                Text("Cloud routers get the command's words, the front app's name and any selected text. Keys are kept "
                     + "in your Keychain. Common commands like “open Slack” never use a model.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Card("Local model") {
                Picker("Ollama model", selection: state.bind(get: { dictation.localRouterModel },
                                                          set: { dictation.localRouterModel = $0 })) {
                    ForEach(["qwen3:1.7b", "qwen3:4b", "qwen3:8b", "llama3.2:3b"], id: \.self) { Text($0).tag($0) }
                }
                Text("Smaller is faster. Install with “ollama pull qwen3:4b”.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Card("Helpers") {
                ForEach(AssistantCLI.allCases, id: \.self) { helper in
                    Toggle("Let Murmur ask \(helper.display)",
                           isOn: state.bind(get: { helper.isAllowed }, set: { helper.isAllowed = $0 }))
                }
                Text("For harder steps Murmur can ask Claude Code or Codex, with your own login. They can't change files, "
                     + "and Murmur asks you before each one.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Card("Things to say") {
                ForEach(["Open Chrome and search Facebook", "Quit Spotify", "Volume 30", "Lock the screen",
                         "Murmur, summarise this (with text selected)", "Find my files about the lease"], id: \.self) {
                    Text("“\($0)”").font(.system(size: 14))
                }
            }
        }
    }
}

// MARK: - Folders

private struct FoldersPage: View {
    let app: AppController
    @Bindable var state: HomeState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Folders", subtitle: "What file search reads, the search shortcut, and what's kept on this Mac.")
            Picker("", selection: $state.foldersTab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 16)
            SettingsPane(tab: state.foldersTab, state: app.settingsWindow.state)
                .task(id: state.foldersTab) { await app.settingsWindow.state.refresh() }
        }
    }
}

// MARK: - About

private struct AboutPage: View {
    let app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Murmur").font(.system(size: 30, weight: .semibold)).tracking(-0.4)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 13)).foregroundStyle(Brand.clay)
                }
            }
            .padding(.bottom, 22)
            Text("Talk anywhere. Find anything.")
                .font(.system(size: 18, weight: .medium))
                .padding(.bottom, 20)
            Card("Made with") {
                Text("File index and search from DigUp by Abdur Rahim (MIT). Speech recognition with NVIDIA Parakeet "
                     + "through FluidAudio (Apache 2.0). Search embeddings with Google DeepMind's EmbeddingGemma 2 on "
                     + "llama.cpp (MIT).")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Acknowledgements and Licenses") {
                    if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Card("Setup") {
                Button("Run Setup Again…") { app.showOnboarding() }
                Text("Walks through permissions, the Fn key, the speech model and the folders to search.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
        }
    }
}
