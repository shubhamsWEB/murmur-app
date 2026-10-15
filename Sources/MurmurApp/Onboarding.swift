import AgentKit
import AppKit
import AVFoundation
import MurmurIndex
import Observation
import SwiftUI
import VoiceKit

/// First launch, in four steps: what Murmur does, which folders to search (with how long the first pass takes), the
/// hotkey (try it), and done; a fifth, code search, when there are folders with code on the Mac (it stays off unless
/// you turn it on there). The model downloads from Get Started on, shown at the bottom of every later step, and
/// the chosen folders start indexing as soon as you continue past them.
final class OnboardingController: NSObject, NSWindowDelegate {
    let state: OnboardingState
    private unowned let app: AppController
    private var window: NSWindow?

    init(app: AppController) {
        self.app = app
        state = OnboardingState(app: app)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        app.present(window)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: OnboardingView.size.width,
                                                  height: OnboardingView.size.height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Welcome to Murmur"
        window.isReleasedWhenClosed = false
        window.delegate = self
        state.close = { [weak self] in self?.close() }
        window.backgroundColor = Theme.pageNS
        window.contentView = NSHostingView(rootView: OnboardingView(state: state).murmurStyle())
        window.center()
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        state.leaving()
        window?.contentView = nil
        window = nil
        app.onboardingClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }
}

@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable {
        case welcome, voice, folders, code, shortcut, commands, ready
    }

    private(set) var step = Step.welcome
    /// The folders to search, with their estimates and subfolders; applied on Continue.
    let folders: FolderChoices
    /// Code search's folders, offered when the Mac has folders with code (`CodeFolders`); applied on Continue when
    /// `searchCode` is on.
    let codeFolders: FolderChoices
    var searchCode = false {
        didSet { if searchCode { codeFolders.startEstimates() } }
    }
    /// You pressed the hotkey on the shortcut step.
    private(set) var hotkeyWorked = false
    var launchAtLogin: Bool
    var indexOnBattery: Bool
    /// File types to skip as typed ("heic, txt"): applied on Return, and on Continue (a click there doesn't end the
    /// field's editing).
    var skippedTypesText: String
    @ObservationIgnored let app: AppController
    @ObservationIgnored var close: () -> Void = {}

    init(app: AppController) {
        self.app = app
        let settings = app.model.settings
        let candidates = Self.candidates()
        let chosen = settings.roots
        let selection = FolderSelection(chosen: (chosen.isEmpty ? candidates : chosen).map(\.path),
                                        skipped: settings.excludedFolders.map(\.path))
        // A chosen subfolder of a folder listed shows in that folder's list, not as a folder of its own.
        let others = chosen.filter { root in
            !candidates.contains { $0.path == root.path || $0.path == FolderSelection.parent(root.path) }
        }
        folders = FolderChoices(rows: candidates + others, selection: selection, types: settings.excludedTypes)
        let codeCandidates = CodeFolders.candidates(searched: [])
        codeFolders = FolderChoices(rows: codeCandidates,
                                    selection: FolderSelection(chosen: settings.codeRoots.isEmpty
                                                                   ? codeCandidates.map(\.path)
                                                                   : settings.codeRoots.map(\.path)),
                                    types: [], code: true)
        searchCode = !settings.codeRoots.isEmpty
        launchAtLogin = app.launchesAtLogin || app.suggestsLaunchAtLogin
        indexOnBattery = settings.indexOnBattery
        skippedTypesText = settings.excludedTypes.joined(separator: ", ")
    }

    var model: AppModel { app.model }
    var download: ModelDownload { app.download }

    /// The steps this Mac gets: code search's only when there's code to offer.
    var steps: [Step] {
        Step.allCases.filter { $0 != .code || !codeFolders.rows.isEmpty }
    }

    /// The folders it offers: the usual home folders that exist, or `-onboardingLocations a:b:c` (tests point it at
    /// the testbed, never at real folders).
    static func candidates() -> [URL] {
        if let list = UserDefaults.standard.string(forKey: "onboardingLocations") {
            return list.split(separator: ":").map { AppSettings.folderURL(String($0)) }
        }
        // A dev or test run (its own defaults suite) never offers, and so never estimates, the real home folders.
        if UserDefaults.standard.string(forKey: "defaultsSuite") != nil {
            log("onboarding: no -onboardingLocations in a dev run, so no folders are offered")
            return []
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .map { AppSettings.folderURL(home.appendingPathComponent($0).path) }
            .filter(AppSettings.isFolder)
    }

    // MARK: Steps

    func next() {
        switch step {
        case .welcome:
            download.start()   // the go-ahead for the one download
            go(to: .voice)
        case .voice:
            go(to: .folders)
        case .folders:
            // Indexing starts now (file names first; meaning once the model is in), while you set up the rest.
            folders.setTypes(skippedTypesText)
            app.applyFolders(folders.roots, excluded: folders.skipped, types: folders.types)
            go(to: steps.contains(.code) ? .code : .shortcut)
        case .code:
            if searchCode, !codeFolders.roots.isEmpty {
                app.applyCodeFolders(codeFolders.roots, excluded: codeFolders.skipped)
            } else if !searchCode, model.hasCode {
                app.applyCodeFolders([], excluded: [])
            }
            go(to: .shortcut)
        case .shortcut:
            go(to: .commands)
        case .commands:
            go(to: .ready)
        case .ready:
            finish()
        }
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        go(to: steps[index - 1])
    }

    func go(to step: Step) {
        self.step = step
        app.hotkeyTester = step == .shortcut ? { [weak self] in self?.hotkeyWorked = true } : nil
        if step == .folders { folders.startEstimates() }
    }

    func finish() {
        if indexOnBattery != model.settings.indexOnBattery { app.setIndexOnBattery(indexOnBattery) }
        if launchAtLogin != app.launchesAtLogin { _ = app.setLaunchAtLogin(launchAtLogin) }
        log("onboarding: done (\(model.settings.roots.count) folders, login item \(launchAtLogin ? "on" : "off"))")
        close()
    }

    /// The window is closing (Done or its close button).
    func leaving() {
        app.hotkeyTester = nil
    }

    // MARK: Folders (applied on Continue, from the first pass on; Settings has the same for later)

    func addFolders(from window: NSWindow?) {
        app.pickFolders(for: window) { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.folders.add(picked)
        }
    }

    func skipFolders(from window: NSWindow?) {
        app.pickFolders(for: window, prompt: "Skip") { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.folders.skip(picked)
        }
    }

    /// The step has what it needs to be drawn (debug snapshots wait for this).
    var isLoaded: Bool {
        switch step {
        case .folders: folders.estimatesDone
        case .code: !searchCode || codeFolders.estimatesDone
        default: true
        }
    }

    func addCodeFolders(from window: NSWindow?) {
        app.pickFolders(for: window) { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.codeFolders.add(picked)
        }
    }
}

// MARK: Views

struct OnboardingView: View {
    static let size = CGSize(width: 940, height: 640)
    @Bindable var state: OnboardingState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                StepIndicator(steps: state.steps, current: state.step)
                    .padding(.top, 52)
                    .padding(.horizontal, 40)
                ScrollView {
                    Group {
                        switch state.step {
                        case .welcome: WelcomeStep()
                        case .voice: VoiceStep(state: state)
                        case .folders: FoldersStep(state: state)
                        case .code: CodeStep(state: state)
                        case .shortcut: ShortcutStep(state: state)
                        case .commands: CommandsStep(state: state)
                        case .ready: ReadyStep(state: state)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 40)
                    .padding(.top, 26)
                    .padding(.bottom, 20)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.page)
            StepArt(step: state.step, hotkey: state.model.hotkey?.display ?? "⇧⌘Space")
                .frame(width: 300)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.ink)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // The file search model's download, named as such (it read as the speech model when it said "the model").
            if state.step != .welcome {
                DownloadStatus(download: state.download)
            }
            Spacer(minLength: 8)
            if state.step == .folders || state.step == .code && state.searchCode {
                Text(state.step == .code ? codeSummary : foldersSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            if state.step != .welcome, state.step != .ready {
                Button("Back") { state.back() }
                    .buttonStyle(.murmurSecondary)
            }
            Button(continueTitle) { state.next() }
                .buttonStyle(.murmurPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(state.step == .folders && state.folders.roots.isEmpty)
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .background(Theme.cardAlt)
    }

    private var continueTitle: String {
        switch state.step {
        case .welcome: "Get Started"
        case .voice: "Continue"
        case .folders: "Continue"
        case .code: "Continue"
        case .shortcut: "Continue"
        case .commands: "Continue"
        case .ready: "Done"
        }
    }

    private var codeSummary: String {
        guard !state.codeFolders.roots.isEmpty else { return "Check the folders with your code" }
        guard state.codeFolders.estimatesDone else { return "Looking at your code…" }
        let seconds = state.codeFolders.totalSeconds
        return (seconds < 1 ? "Under a second" : "About \(roughDuration(seconds))")
            + ", \(roughBytes(state.codeFolders.totalBytes))"
    }

    private var foldersSummary: String {
        guard !state.folders.roots.isEmpty else { return "Choose at least one folder" }
        guard state.folders.estimatesDone else { return "Looking at your folders…" }
        return "First pass: about \(roughDuration(state.folders.totalSeconds))"
    }
}

/// ✓ Welcome — 2 Voice — 3 Folders …: where you are in setup.
private struct StepIndicator: View {
    let steps: [OnboardingState.Step]
    let current: OnboardingState.Step

    private func name(_ step: OnboardingState.Step) -> String {
        switch step {
        case .welcome: "Welcome"
        case .voice: "Voice"
        case .folders: "Folders"
        case .code: "Code"
        case .shortcut: "Shortcuts"
        case .commands: "Commands"
        case .ready: "Done"
        }
    }

    var body: some View {
        let index = steps.firstIndex(of: current) ?? 0
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { position, step in
                if position > 0 {
                    Rectangle().fill(Theme.control).frame(width: 14, height: 1)
                }
                HStack(spacing: 6) {
                    ZStack {
                        if position < index {
                            Circle().fill(Theme.primary)
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.onPrimary)
                        } else if position == index {
                            Circle().fill(Theme.accent)
                            Text("\(position + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Circle().strokeBorder(Theme.control)
                            Text("\(position + 1)").font(.system(size: 10)).foregroundStyle(Theme.ink2)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(name(step))
                        .font(.system(size: 12, weight: position == index ? .semibold : .regular))
                        .foregroundStyle(position == index ? Theme.ink : Theme.ink2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(steps.count): \(name(current))")
    }
}

/// The dark panel on the right: what this step is about, drawn.
private struct StepArt: View {
    let step: OnboardingState.Step
    let hotkey: String
    private let cream = Color(red: 0.961, green: 0.929, blue: 0.902)
    private let charcoal = Color(red: 0.133, green: 0.118, blue: 0.110)

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            art
            Text(caption)
                .font(.system(size: 12.5))
                .foregroundStyle(cream.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 220)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(charcoal)
        .accessibilityHidden(true)
    }

    private var caption: String {
        switch step {
        case .welcome: "Talk anywhere. Find anything. Get it done."
        case .voice: "This is what you'll see at the bottom of the screen while Murmur listens."
        case .folders: "Describe a file the way you remember it. Murmur reads photos, PDFs, documents and recordings."
        case .code: "Search your code by what it does, not just by name."
        case .shortcut: "Talk with fn. Search with your shortcut. Both work in any app."
        case .commands: "“Open Slack” runs instantly. Longer requests need a model: on this Mac, or yours in the cloud."
        case .ready: "Hold fn and talk. Murmur lives in your menu bar."
        }
    }

    @ViewBuilder
    private var art: some View {
        switch step {
        case .welcome:
            BrandTile(size: 88)
        case .voice, .ready:
            HStack(spacing: 12) {
                StarlingMark(.color, listening: step == .voice).frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.accent.opacity(0.22)).padding(-5))
                HStack(spacing: 3) {
                    ForEach(Array([8.0, 16, 22, 12, 18, 9].enumerated()), id: \.offset) { _, height in
                        Capsule().fill(cream).frame(width: 3, height: height)
                    }
                }
                Text(step == .ready ? "Ready" : "Listening").font(.system(size: 13)).foregroundStyle(cream)
            }
            .padding(.leading, 12)
            .padding(.trailing, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(red: 0.180, green: 0.161, blue: 0.149)))
            .overlay(Capsule().strokeBorder(Color(red: 0.239, green: 0.212, blue: 0.196)))
        case .commands:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["Open Slack", "Check for updates", "Search YouTube for lofi and play it"], id: \.self) { phrase in
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text("“\(phrase)”").font(.system(size: 12.5)).foregroundStyle(cream)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(red: 0.180, green: 0.161, blue: 0.149)))
                }
            }
        case .folders:
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.accent)
                    Text("photos on the beach").foregroundStyle(cream)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(width: 220, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(red: 0.180, green: 0.161, blue: 0.149)))
                HStack(spacing: 8) {
                    ForEach(Array([0xF6D9C4, 0xCFE0E6, 0xE9DFC9].enumerated()), id: \.offset) { _, hex in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                                        blue: Double(hex & 0xFF) / 255))
                            .frame(width: 68, height: 56)
                    }
                }
            }
        case .code:
            Text("code: retry with backoff")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(cream)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(red: 0.180, green: 0.161, blue: 0.149)))
        case .shortcut:
            VStack(spacing: 14) {
                Text("hold fn")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(cream)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.180, green: 0.161, blue: 0.149)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.6)))
                Text(hotkey)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundStyle(cream)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.180, green: 0.161, blue: 0.149)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.6)))
            }
        }
    }
}

/// The search model's download, small: "Downloading the search model · 42% · about 1 min left", then "Search model
/// ready". (Named, so it isn't taken for the speech model.)
struct DownloadStatus: View {
    let download: ModelDownload

    var body: some View {
        HStack(spacing: 7) {
            switch download.phase {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("File search model ready")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(1)
                Button("Try Again") { download.start() }.controlSize(.small)
                Button("Use Files…") { download.chooseFiles(for: NSApp.keyWindow) }
                    .controlSize(.small)
                    .help("Downloaded the model's two files somewhere else? Choose them here.")
            case .needed where download.heldForSpeech:
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("File search model: paused while the speech model downloads").lineLimit(1)
            case .needed:
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                Text("File search model not downloaded")
                Button("Download") { download.start() }.controlSize(.small)
            default:
                ProgressView(value: download.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("File search model · downloading \(download.progressText)")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to Murmur")
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.5)
            Text("Your voice, for everything on your Mac. Private by default.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "text.cursor", title: "Dictation in any app",
                        example: "Hold fn, speak, let go: the text appears where you're typing.")
                Feature(symbol: "macwindow", title: "Commands that get things done",
                        example: "“Open Slack”, “check for updates”, “search YouTube for lofi and play it”.")
                Feature(symbol: "doc.text.magnifyingglass", title: "Find any file by describing it",
                        example: "“That payment error screenshot”, “the clause about pets in the lease”.")
                Feature(symbol: "chevron.left.forwardslash.chevron.right", title: "Build with Claude Code or Codex",
                        example: "“Create a React app with a Hello World page.”")
            }
            .padding(.top, 28)
            // What gets downloaded and when, said up front: the footer's progress later is the first of these.
            VStack(alignment: .leading, spacing: 10) {
                Text("Two downloads, once each").font(.system(size: 12.5, weight: .semibold))
                DownloadLine(symbol: "doc.text.magnifyingglass", title: "File search model · 865 MB",
                             detail: "Starts when you click Get Started. Its progress shows at the bottom of each step.")
                DownloadLine(symbol: "waveform", title: "Speech model · about 500–600 MB",
                             detail: "On the next step, for the language you choose. Nothing downloads until you say so.")
                Text("Then speech and file search run on this Mac, offline. Commands use the model you choose.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            .padding(.top, 26)
        }
        .frame(maxWidth: 480, alignment: .leading)
    }
}

private struct DownloadLine: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let example: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accentTint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(example).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StepTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.4)
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FoldersStep: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "What should Murmur search?",
                      subtitle: "Pick folders, or open one to pick some of its subfolders. You can change this "
                          + "anytime in Settings.")
            ScrollView {
                VStack(spacing: 6) {
                    FolderList(choices: state.folders, addTitle: "Add Folder…") {
                        state.addFolders(from: NSApp.keyWindow)
                    }
                    SkipChoices(state: state)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("macOS will ask before Murmur can read folders like Desktop, Documents and Downloads. "
                     + "Murmur only reads files: it never changes, moves or uploads them.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.bottom, 14)
        }
    }
}

/// Folders and file types to leave out, before the first pass reads anything. Folded away unless something is set.
private struct SkipChoices: View {
    @Bindable var state: OnboardingState
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.folders.selection.effectiveSkips, id: \.self) { folder in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(tildePath(folder)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            state.folders.unskip(folder)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Search this folder again")
                    }
                    .font(.system(size: 12))
                }
                Button {
                    state.skipFolders(from: NSApp.keyWindow)
                } label: {
                    Label("Skip a Folder…", systemImage: "plus")
                }
                .controlSize(.small)
                HStack(spacing: 8) {
                    Text("File types")
                    TextField("Extensions", text: $state.skippedTypesText, prompt: Text("e.g. heic, txt"))
                        .labelsHidden()
                        .controlSize(.small)
                        .onSubmit { state.folders.setTypes(state.skippedTypesText) }
                }
                .font(.system(size: 12))
                Text("Code, keys, certificates, hidden folders, app bundles and caches are always skipped.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            Text("Skip some folders or file types")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .onAppear {
            expanded = !state.folders.selection.effectiveSkips.isEmpty || !state.folders.types.isEmpty
        }
    }
}

/// Code search, if you want it: a switch (off until you turn it on), then the folders with code, each opening to its
/// repos with how long reading them takes and the room their index needs, and the editor results open in.
private struct CodeStep: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "Search your code too?",
                      subtitle: "Murmur can find code by what it does: type code: in the search panel, as in "
                          + "“code: retry with backoff”. It gets an index of its own and never shows up in other "
                          + "searches. You can turn it on later in Settings → Code.")
            SwitchRow(title: "Search my code", detail: "Off unless you turn it on.", isOn: $state.searchCode)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card)).overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            if state.searchCode {
                ScrollView {
                    VStack(spacing: 6) {
                        FolderList(choices: state.codeFolders, addTitle: "Add Folder…") {
                            state.addCodeFolders(from: NSApp.keyWindow)
                        }
                        CodeFolderNote().padding(.top, 4)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                HStack {
                    Text("Open code in")
                    Picker("Open code in", selection: Binding(get: { CodeEditor.current.id },
                                                              set: { state.app.setCodeEditor($0) })) {
                        ForEach(CodeEditor.installed) { editor in Text(editor.name).tag(editor.id) }
                        Text(CodeEditor.defaultApp.name).tag(CodeEditor.defaultApp.id)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Permissions and a first dictation: hold Fn, say something, see it come back.
private struct VoiceStep: View {
    let state: OnboardingState
    @ObservedObject private var history = DictationHistory.shared
    @State private var appeared = Date()

    var body: some View {
        // Permissions are granted in System Settings, outside the app: look again every second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let dictation = state.app.dictation
            let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let heard = history.items.first { $0.date > appeared }
            VStack(alignment: .leading, spacing: 0) {
                StepTitle(title: "Talk to your Mac",
                          subtitle: "Hold Fn, speak, and let go. Murmur types it wherever your cursor is.")
                LanguageChoice(dictation: dictation)
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.top, 20)
                VStack(alignment: .leading, spacing: 10) {
                    PermissionRow(ok: mic, title: "Microphone", detail: "So Murmur can hear you",
                                  button: "Allow…") { dictation.openMicrophoneSettings() }
                    PermissionRow(ok: dictation.canPaste && dictation.isListeningForKey, title: "Accessibility",
                                  detail: "So Murmur notices the Fn key and can type into other apps",
                                  button: "Open Settings…") { dictation.openAccessibilitySettings() }
                    PermissionRow(ok: dictation.speechModelState.isReady, title: "Speech model",
                                  detail: dictation.modelStatus, button: nil, okText: "Ready") {}
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 16)
                tryIt(heard: heard, mic: mic, dictation: dictation)
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.top, 22)
                Text("If Fn opens the emoji picker, set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.top, 14)
            }
        }
    }
}

/// Which language you'll speak: each is its own speech model (English, Hinglish, or the other languages). Picking one
/// that's on this Mac switches at once; one that isn't asks first, with its size, before anything downloads. Also on
/// the Settings page.
struct LanguageChoice: View {
    @ObservedObject var dictation: DictationController
    /// A model picked that needs a download, waiting for the go-ahead.
    @State private var asking: SpeechModel?

    var body: some View {
        let current = dictation.speechModel
        VStack(alignment: .leading, spacing: 10) {
            // Nothing chosen yet (a fresh install): English, the default, is offered with its Download button showing.
            Text("Which language will you speak?").font(.system(size: 13.5, weight: .semibold))
            HStack(alignment: .top, spacing: 10) {
                ForEach(SpeechModel.allCases, id: \.self) { model in
                    // On a fresh install nothing is chosen yet (English is only the default): no tick until you pick.
                    card(model, chosen: model == current && dictation.speechModelChosen, asked: model == asking)
                }
            }
            if let asking {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(asking.language) needs a one-time download, \(asking.downloadSize).")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("From Hugging Face, then it runs offline on this Mac. Dictation waits while it downloads.")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Not now") { self.asking = nil }.buttonStyle(.murmurSecondaryCompact)
                    Button("Download") {
                        dictation.setModel(asking)
                        self.asking = nil
                    }
                    .buttonStyle(.murmurPrimaryCompact)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accentTint))
            }
        }
        .onAppear {
            if !dictation.speechModelChosen, asking == nil { asking = current }
        }
    }

    private func card(_ model: SpeechModel, chosen: Bool, asked: Bool) -> some View {
        Button {
            guard !chosen else {
                asking = nil
                if case .failed = dictation.speechModelState { dictation.retryModel() }
                return
            }
            if model.isOnThisMac {
                asking = nil
                dictation.setModel(model)
            } else {
                asking = model
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.language).font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 0)
                    if chosen {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    }
                }
                Text(model.languageDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                status(model, chosen: chosen)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(chosen ? Theme.accentTint : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(chosen || asked ? Theme.accent : Theme.line, lineWidth: chosen || asked ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.language): \(model.languageDetail)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Where the model is: downloading or getting ready (the chosen one), on this Mac, or a download away.
    @ViewBuilder
    private func status(_ model: SpeechModel, chosen: Bool) -> some View {
        if chosen, case .downloading(let fraction) = dictation.speechModelState {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction).tint(Theme.accent)
                Text("Downloading · \(Int(fraction * 100))%").font(.system(size: 11)).foregroundStyle(Theme.ink2)
            }
        } else if chosen, case .preparing = dictation.speechModelState {
            Text("Getting ready…").font(.system(size: 11)).foregroundStyle(Theme.ink2)
        } else if chosen, case .failed = dictation.speechModelState {
            Text("Couldn't load. Pick it again to retry.").font(.system(size: 11)).foregroundStyle(Theme.danger)
        } else if model.isOnThisMac || (chosen && dictation.speechModelState == .ready) {
            Label("On this Mac", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Theme.good)
        } else {
            Label("\(model.downloadSize) download", systemImage: "arrow.down.circle")
                .font(.system(size: 11)).foregroundStyle(Theme.ink3)
        }
    }
}

extension VoiceStep {
    /// "Try it now" only once Murmur can hear you, type, and has its speech model; until then, what it's waiting for.
    /// Continue never waits: the model keeps downloading and you can try it later.
    @ViewBuilder
    func tryIt(heard: DictationHistory.Item?, mic: Bool, dictation: DictationController) -> some View {
        let key = dictation.key.short
        if let heard {
            Label("Heard: “\(heard.text)”", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.good)
                .lineLimit(2)
        } else if !mic || !(dictation.canPaste && dictation.isListeningForKey) {
            Text("Allow the microphone and Accessibility above, then try it.")
                .foregroundStyle(.secondary)
        } else if !dictation.speechModelChosen {
            Text("Choose the language you'll speak above; its model downloads once you say so.")
                .foregroundStyle(.secondary)
        } else {
            switch dictation.speechModelState {
            case .ready:
                Text("Try it now: hold \(key) and say “Hello, Murmur”.")
                    .foregroundStyle(.secondary)
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction).tint(Theme.accent).frame(maxWidth: 320)
                    Text("Downloading the speech model · \(Int(fraction * 100))%. You can try it when it's ready, or "
                         + "continue: it keeps downloading and you can try it later.")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .waiting, .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting the speech model ready. Try it in a moment, or continue and try it later.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let message):
                HStack(spacing: 10) {
                    Text("The speech model didn't load: \(message)")
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                    Button("Try Again") { dictation.retryModel() }.buttonStyle(.murmurSecondaryCompact)
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let button: String?
    /// The word when it's fine: "Allowed" for a permission, "Ready" for the speech model.
    var okText = "Allowed"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: ok ? "checkmark" : "exclamationmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ok ? Theme.good : Theme.accentText)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ok ? Theme.goodTint : Theme.accentTint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).lineLimit(2)
            }
            Spacer(minLength: 8)
            if ok {
                Pill(text: okText, tone: .good)
            } else if let button {
                Button(button, action: action).buttonStyle(.murmurPrimaryCompact)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(ok ? Theme.line : Theme.accent.opacity(0.7)))
        .background(RoundedRectangle(cornerRadius: Theme.radius + 3, style: .continuous)
            .fill(Theme.accentRing).padding(-3).opacity(ok || button == nil ? 0 : 1))
    }
}

private struct ShortcutStep: View {
    let state: OnboardingState
    @ObservedObject private var history = DictationHistory.shared
    @State private var appeared = Date()

    /// "Try it" only once the speech model is ready; until then, how far along it is.
    private func talkTest(_ dictation: DictationController, key: String) -> String {
        switch dictation.speechModelState {
        case .ready: "Try it: hold \(key) and say “Hello, Murmur”."
        case .downloading(let fraction): "The speech model is downloading (\(Int(fraction * 100))%). Try it when it's ready."
        case .waiting where !dictation.speechModelChosen: "Choose a language on the Voice step first."
        case .waiting, .preparing: "The speech model is getting ready. Try it in a moment."
        case .failed: "The speech model didn't load. Retry on the Voice step or in Settings."
        }
    }

    var body: some View {
        // Redraws every second, so the speech model's progress shows.
        TimelineView(.periodic(from: .now, by: 1)) { _ in content }
    }

    @ViewBuilder
    private var content: some View {
        let dictation = state.app.dictation
        let talkKey = dictation.key.short
        let heard = history.items.first { $0.date > appeared }
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Your shortcuts",
                      subtitle: "Hold \(talkKey) and Murmur works out whether you're writing or asking. Add a key to decide "
                          + "yourself. All of them work in any app.")
            VStack(alignment: .leading, spacing: 10) {
                ShortcutCard(number: "1", title: "Talk", detail: "Hold \(talkKey) and speak; let go and it's typed, or done "
                                 + "if you asked for something. Double-tap for hands-free.",
                             extras: [([talkKey, dictation.typingModifier.symbol], "Only type: always typed, never a command"),
                                      ([talkKey, dictation.commandModifier.symbol], "Only a command: always done, never typed")],
                             tested: heard != nil,
                             test: heard.map { "Heard: “\($0.text)”" } ?? talkTest(dictation, key: talkKey)) {
                    HStack(spacing: 4) {
                        KeyCap(talkKey)
                        Text("hold").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                    }
                }
                ShortcutCard(number: "2", title: "Search files", detail: "Describe a file and press Return to open it. "
                                 + "Click the keys to choose different ones.",
                             tested: state.hotkeyWorked,
                             test: state.hotkeyWorked ? "That's it. It works from any app."
                                 : "Try it: press \(state.model.hotkey?.display ?? "the shortcut").") {
                    ShortcutRecorder(combo: state.model.hotkey, apply: { state.app.setHotkey($0) },
                                     listening: { state.app.hotkeyRecording($0) }, capSize: 13)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.top, 24)
            .animation(.default, value: state.hotkeyWorked)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("In the search panel")
                HStack(spacing: 22) {
                    KeyTip(caps: ["↩"], text: "Open")
                    KeyTip(caps: ["⌘", "↩"], text: "Show in Finder")
                    KeyTip(caps: ["Space"], text: "Quick Look")
                }
            }
            .padding(.top, 22)
        }
    }
}

private struct ShortcutCard<Keys: View>: View {
    let number: String
    let title: String
    let detail: String
    /// More ways to press it: the keys together, and what that does.
    var extras: [([String], String)] = []
    let tested: Bool
    let test: String
    @ViewBuilder var keys: Keys

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentTint))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    keys
                }
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(extras.enumerated()), id: \.offset) { _, extra in
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            ForEach(Array(extra.0.enumerated()), id: \.offset) { index, key in
                                if index > 0 { Text("+").font(.system(size: 11)).foregroundStyle(Theme.ink3) }
                                KeyCap(key)
                            }
                        }
                        Text(extra.1).font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                    }
                }
                Label(test, systemImage: tested ? "checkmark.circle.fill" : "hand.point.right")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tested ? Theme.good : Theme.ink)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(tested ? Theme.good.opacity(0.5) : Theme.line))
    }
}

private struct KeyTip: View {
    let caps: [String]
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Keycaps(caps: caps, size: 11)
                .frame(width: 66, alignment: .leading)
            Text(text).font(.system(size: 12))
        }
    }
}

/// Optional: a model for commands that aren't built in. Ollama on this Mac, or a cloud key; neither blocks setup.
private struct CommandsStep: View {
    let state: OnboardingState
    @State private var ollama: OllamaProbe.State?
    @State private var pulling = false
    @State private var pullProblem: String?
    @State private var revision = 0

    private var dictation: DictationController { state.app.dictation }
    private var model: String { dictation.localRouterModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "A model for commands",
                      subtitle: "Dictation, file search and common commands like “open Slack” work without one. For "
                          + "longer requests (“summarise this”, “search YouTube and play the first video”) Murmur "
                          + "needs a model. Optional: you can set this later in Commands & AI.")
            VStack(alignment: .leading, spacing: 10) {
                optionCard(title: "On this Mac, with Ollama", detail: "Free and private. Slower than the cloud.",
                           pill: ollamaPill) { ollamaAction }
                optionCard(title: "Claude or OpenAI, with your API key", detail: "Fastest. Only the command's words go out.",
                           pill: keyPill) {
                    HStack(spacing: 8) {
                        Button(RouterChoice.anthropic.hasKey ? "Claude ✓" : "Add Claude Key…") {
                            if dictation.askForKey(.anthropic) { RouterChoice.current = .anthropic }
                            revision += 1
                        }
                        .buttonStyle(.murmurSecondaryCompact)
                        Button(RouterChoice.openai.hasKey ? "OpenAI ✓" : "Add OpenAI Key…") {
                            if dictation.askForKey(.openai) { RouterChoice.current = .openai }
                            revision += 1
                        }
                        .buttonStyle(.murmurSecondaryCompact)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.top, 24)
            .id(revision)
            if let pullProblem {
                Text(pullProblem).font(.system(size: 12)).foregroundStyle(Theme.danger).lineLimit(3).padding(.top, 10)
            }
            Label(nothingNote, systemImage: "info.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .frame(maxWidth: 560, alignment: .leading)
        }
        .task {
            while !Task.isCancelled {
                if !pulling { ollama = await OllamaProbe.check(model: model) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var nothingNote: String {
        if case .ready = ollama { return "Commands that need a model will use \(model) on this Mac." }
        if RouterChoice.current != .local, RouterChoice.current.hasKey {
            return "Commands that need a model will use \(RouterChoice.current == .anthropic ? "Claude" : "OpenAI")."
        }
        return "Skipping is fine: everything else works now, and Murmur tells you when a command needs a model."
    }

    private var keyPill: Pill? {
        RouterChoice.anthropic.hasKey || RouterChoice.openai.hasKey ? Pill(text: "Key saved", tone: .good) : nil
    }

    private var ollamaPill: Pill? {
        if pulling { return Pill(text: "Downloading \(model)…", tone: .busy) }
        switch ollama {
        case .none: return Pill(text: "Checking…", tone: .neutral)
        case .notInstalled: return Pill(text: "Not installed", tone: .neutral)
        case .notRunning: return Pill(text: "Not running", tone: .busy)
        case .missingModel: return Pill(text: "Needs \(model)", tone: .busy)
        case .ready: return Pill(text: "Ready · \(model)", tone: .good)
        }
    }

    @ViewBuilder
    private var ollamaAction: some View {
        switch ollama {
        case .notInstalled:
            Button("Get Ollama…") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                .buttonStyle(.murmurSecondaryCompact)
        case .notRunning:
            Button("Open Ollama") { Task { await OllamaProbe.start() } }
                .buttonStyle(.murmurSecondaryCompact)
        case .missingModel:
            Button(pulling ? "Downloading…" : "Download \(model) (about 2.5 GB)") {
                pulling = true
                pullProblem = nil
                Task {
                    pullProblem = await OllamaProbe.pull(model)
                    pulling = false
                    ollama = await OllamaProbe.check(model: model)
                }
            }
            .buttonStyle(.murmurSecondaryCompact)
            .disabled(pulling)
        default:
            EmptyView()
        }
    }

    private func optionCard<Action: View>(title: String, detail: String, pill: Pill?,
                                          @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                if let pill { pill }
            }
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
            action().padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }
}

private struct ReadyStep: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(Theme.accent)
                .padding(.top, 8)
            Text("You're all set")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 14)
            Text("Hold fn and talk, or press \(state.model.hotkey?.display ?? "the shortcut") to search. "
                 + "Murmur keeps reading your folders in the background.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470)
                .padding(.top, 8)
            IndexingCard(model: state.model)
                .frame(maxWidth: 470)
                .padding(.top, 20)
            Text(progressNote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 16) {
                SwitchRow(title: "Open Murmur when you log in", detail: "So the shortcut always works.",
                          isOn: $state.launchAtLogin)
                Divider()
                SwitchRow(title: AppSettings.batteryTitle, detail: AppSettings.batteryDetail,
                          isOn: $state.indexOnBattery)
            }
            .padding(20)
            .frame(maxWidth: 470, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card)).overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            .padding(.top, 28)
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                Text("Murmur lives in the menu bar, which shows how indexing is going.")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
    }

    private var progressNote: String {
        let seconds = state.folders.totalSeconds, later = state.folders.totalLaterSeconds
        let time = seconds > 0 ? " (about \(roughDuration(seconds)) on this Mac)" : ""
        let rest = later >= 30 ? " Long PDFs and documents get their first pages in that time, and the rest "
            + "afterwards (about \(roughDuration(later)) more)." : ""
        if state.download.isReady {
            return "Murmur is reading your folders\(time), newest files first. You can search right away; "
                + "results fill in as it goes." + rest
        }
        return "Murmur starts reading your folders\(time) once the model has downloaded "
            + "(\(state.download.progressText)). Until then, search finds files by name." + rest
    }
}

/// A setting with a title, a line about it, and a switch on the right.
struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}
