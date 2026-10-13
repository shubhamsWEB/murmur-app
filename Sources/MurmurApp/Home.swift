import AgentKit
import AppKit
import AVFoundation
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
}

/// Murmur's one window: status and recent dictations, then each part's settings.
final class HomeWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    private var window: NSWindow?
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Murmur"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 780, height: 540)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Brand.paperNS
        window.delegate = self
        if UserDefaults.standard.string(forKey: "defaultsSuite") == nil {
            window.setFrameAutosaveName("MurmurHomeWindow")
        }
        window.contentView = NSHostingView(rootView: HomeView(app: app, state: state).murmurStyle())
        if window.frame.origin == .zero { window.center() }
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
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
        case .search: SearchPage(app: app)
        case .dictation: DictationPage(dictation: app.dictation)
        case .commands: CommandsPage(dictation: app.dictation)
        case .folders: FoldersPage(app: app)
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
            Text(title).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Brand.clay)
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
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
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

private struct HomePage: View {
    let app: AppController
    @ObservedObject private var history = DictationHistory.shared

    var body: some View {
        let dictation = app.dictation
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Hold \(dictation.key == .fn ? "Fn" : "Right ⌥") and talk.",
                      subtitle: "Murmur types where your cursor is. Say “Murmur, …” first, or hold ⌃ too, for a command.")
            if history.wordsToday > 0 {
                Text("\(history.wordsToday) words dictated today")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Brand.coralDeep)
                    .padding(.bottom, 18)
            }
            Card("Ready to go") {
                StatusRow(ok: micOK, title: "Microphone",
                          detail: micOK ? "Allowed" : "Murmur needs it to hear you",
                          action: ("Allow…", { dictation.openMicrophoneSettings() }))
                StatusRow(ok: dictation.canPaste && dictation.isListeningForKey, title: "Typing into other apps",
                          detail: dictation.canPaste ? "Allowed" : "Turn Murmur on in Accessibility",
                          action: ("Open Settings…", { dictation.openAccessibilitySettings() }))
                StatusRow(ok: dictation.modelStatus.contains("ready"), title: "Speech model",
                          detail: dictation.modelStatus)
                StatusRow(ok: RouterChoice.current == .local || RouterChoice.current.hasKey,
                          title: "Commands", detail: "Router: \(RouterChoice.current.display)")
                StatusRow(ok: true, title: "File search", detail: app.model.statusLine)
            }
            Card("Recent") {
                if history.items.isEmpty {
                    Text("What you dictate shows up here. Hold Fn in any text box and say a sentence.")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.clay)
                } else {
                    ForEach(history.items.prefix(25)) { item in
                        HistoryRow(item: item)
                        if item.id != history.items.prefix(25).last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let item: DictationHistory.Item
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .command ? "sparkles" : "text.bubble")
                .foregroundStyle(item.kind == .command ? Brand.coral : Brand.clay)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.system(size: 14))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(meta).font(.system(size: 11)).foregroundStyle(Brand.clay)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var meta: String {
        let when = item.date.formatted(.relative(presentation: .named))
        let kind = item.kind == .command ? "Command" : "Dictation"
        return [kind, item.app, when].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Search

private struct SearchPage: View {
    let app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Search your files",
                      subtitle: "Describe what you're looking for. Photos, PDFs, documents, recordings and video.")
            HStack(spacing: 10) {
                Button {
                    app.panel.show()
                } label: {
                    Label("Open Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Search Window") { app.showSearchWindow() }
                    .controlSize(.large)
                Text("or press \(app.model.hotkey?.display ?? "⇧⌘Space") anywhere")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.clay)
            }
            .padding(.bottom, 24)
            Card("Try") {
                ForEach(["the clause about pets in the lease", "a dog on the beach", "where they talk about sleep",
                         "that payment declined screenshot", "code: retry a failed call with backoff"], id: \.self) {
                    example in
                    Text("“\(example)”").font(.system(size: 14))
                }
            }
            Card("By voice") {
                Text("Hold Fn and say “find my files about the lease”.").font(.system(size: 14))
            }
        }
    }
}

// MARK: - Dictation

private struct DictationPage: View {
    let dictation: DictationController
    @ObservedObject private var history = DictationHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Dictation", subtitle: "How you talk to Murmur and what it hears.")
            Card("Key") {
                Picker("Hold to talk", selection: Binding(get: { dictation.key }, set: { dictation.setKey($0) })) {
                    ForEach(DictationKeyMonitor.Key.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Double-tap for hands-free; tap again to finish, Esc to cancel. If Fn opens the emoji picker, set "
                     + "System Settings → Keyboard → “Press 🌐 key to” → Do Nothing.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Card("Hearing") {
                Picker("Speech model",
                       selection: Binding(get: { dictation.speechModel }, set: { dictation.setModel($0) })) {
                    ForEach(ParakeetTranscriber.Model.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                Toggle("Whisper Mode: boost quiet speech",
                       isOn: Binding(get: { dictation.whisperMode }, set: { dictation.whisperMode = $0 }))
                Button("Save Last Recording…") { dictation.saveLastRecording() }
            }
            Card("Commands") {
                Toggle("Tell commands from dictation automatically",
                       isOn: Binding(get: { dictation.detectCommands }, set: { dictation.detectCommands = $0 }))
                Text("Off: everything is typed unless you hold ⌃ with the key.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Card("History") {
                Toggle("Keep recent dictations on this Mac",
                       isOn: Binding(get: { history.isEnabled }, set: { history.isEnabled = $0 }))
                Button("Clear History") { history.clear() }
                    .disabled(history.items.isEmpty)
            }
        }
    }
}

// MARK: - Commands & AI

private struct CommandsPage: View {
    let dictation: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Commands & AI",
                      subtitle: "What picks the actions when you give a command. Speech always stays on your Mac.")
            Card("Router") {
                Picker("Router", selection: Binding(get: { RouterChoice.current }, set: { choice in
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
                    }
                    Button(RouterChoice.openai.hasKey ? "Change OpenAI Key…" : "Add OpenAI Key…") {
                        dictation.askForKey(.openai)
                    }
                }
                Text("Cloud routers get the command's words, the front app's name and any selected text. Keys are kept "
                     + "in your Keychain. Common commands like “open Slack” never use a model.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Card("Local model") {
                Picker("Ollama model", selection: Binding(get: { dictation.localRouterModel },
                                                          set: { dictation.localRouterModel = $0 })) {
                    ForEach(["qwen3:1.7b", "qwen3:4b", "qwen3:8b", "llama3.2:3b"], id: \.self) { Text($0).tag($0) }
                }
                Text("Smaller is faster. Install with “ollama pull qwen3:4b”.")
                    .font(.system(size: 12)).foregroundStyle(Brand.clay)
            }
            Card("Helpers") {
                ForEach(AssistantCLI.allCases, id: \.self) { helper in
                    Toggle("Let Murmur ask \(helper.display)",
                           isOn: Binding(get: { helper.isAllowed }, set: { helper.isAllowed = $0 }))
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
    @State private var tab = SettingsTab.folders

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Folders", subtitle: "What file search reads, and what it keeps on this Mac.")
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 16)
            SettingsPane(tab: tab, state: app.settingsWindow.state)
                .task(id: tab) { await app.settingsWindow.state.refresh() }
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
                    Text("Murmur").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 13)).foregroundStyle(Brand.clay)
                }
            }
            .padding(.bottom, 22)
            Text("Talk anywhere. Find anything.")
                .font(.system(size: 18, weight: .medium, design: .rounded))
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
