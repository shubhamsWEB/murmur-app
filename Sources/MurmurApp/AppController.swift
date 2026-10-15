import AgentKit
import AppKit
import Combine
import MurmurIndex
import ServiceManagement
import VoiceKit

/// Owns the app's parts (engine, model download, hotkey, panel, windows, menu) and carries out what they ask for:
/// new folders, a new hotkey, the login item, which window to show.
final class AppController {
    /// `-debugOffscreen YES`: windows and the panel are built and drawn but never shown, and the app never activates,
    /// so snapshot tests don't take the keyboard from whoever is using the Mac.
    static let offscreen = UserDefaults.standard.bool(forKey: "debugOffscreen")

    let model: AppModel
    let engine: Engine
    let download: ModelDownload
    let hotkeys = HotkeyCenter()
    let updates: Updates
    /// Murmur's dictation (hold Fn to talk).
    let dictation = DictationController()
    private let power: PowerPolicy
    private let schedule: IndexSchedule
    private(set) var panel: SearchPanelController!
    private(set) var searchWindow: SearchWindowController!
    private(set) var settingsWindow: SettingsWindowController!
    /// Murmur's main window (Home, Search, Dictation, Commands & AI, Folders, About).
    private(set) var home: HomeWindowController!
    private(set) var statusMenu: StatusMenuController!
    private(set) var onboarding: OnboardingController?
    private var observers: [NSObjectProtocol] = []
    private var speechWatch: AnyCancellable?
    /// Set while onboarding's shortcut step waits for you to try the hotkey: a press goes there, not to the panel.
    var hotkeyTester: (() -> Void)?

    init(settings: AppSettings) {
        let download = ModelDownload(folder: settings.modelsDirectory)
        let model = AppModel(settings: settings, download: download)
        var engineRef: Engine?
        let power = PowerPolicy(indexOnBattery: settings.indexOnBattery) { blocker in
            engineRef?.setBackfillBlocker(blocker)
        }
        log("power: \(PowerPolicy.onACPower() ? "AC" : "battery"), backfill \(power.blocker.map { "waits (\($0))" } ?? "may run")")
        let schedule = IndexSchedule(hours: settings.indexHoursOn ? settings.indexHours : nil) { until in
            engineRef?.setHeldUntil(until)
        }
        if let until = schedule.waitsUntil {
            log("schedule: indexing waits until \(until.formatted(date: .omitted, time: .shortened))")
        }
        let engine = Engine(settings: settings, backfillBlocker: power.blocker,
                            heldUntil: schedule.waitsUntil) { status in
            let before = model.statusLine
            model.status = status
            if model.statusLine != before { log("status: \(model.statusLine)") }
        }
        engineRef = engine
        Estimates.indexDirectory = settings.indexDirectory
        self.download = download
        self.model = model
        self.power = power
        self.schedule = schedule
        self.engine = engine
        updates = Updates(model: model)
    }

    /// `showWindow`: opened by hand (not at login), so the search window comes up once the app is set up.
    func start(showWindow: Bool = false) {
        panel = SearchPanelController(app: self)
        searchWindow = SearchWindowController(app: self)
        settingsWindow = SettingsWindowController(app: self)
        home = HomeWindowController(app: self)
        settingsWindow.sheetParent = { [weak self] in self?.home.window }
        statusMenu = StatusMenuController(model: model)
        statusMenu.onSearch = { [weak self] in self?.panel.show() }
        statusMenu.onOpenWindow = { [weak self] in self?.showHome() }
        statusMenu.onSettings = { [weak self] in self?.showHome(.dictation) }
        statusMenu.onChooseFolders = { [weak self] in self?.chooseFolders() }
        statusMenu.onPauseChanged = { [weak self] paused in self?.engine.setPaused(paused) }
        statusMenu.onCheckForUpdates = { [weak self] in self?.updates.checkNow() }
        updates.onSessionEnded = { [weak self] in self?.windowClosed() }
        updates.start()

        dictation.log = { line in log(line) }
        dictation.logFile = model.settings.indexDirectory.appendingPathComponent("app.log")
        // Voice searches land in Murmur's own window (its Search page), not a separate one.
        dictation.onSearchFiles = { [weak self] query in self?.showSearchWindow(query: query) }
        dictation.onOpenFile = { [weak self] query in await self?.openBestFile(query) ?? "" }
        dictation.onOpenModelSettings = { [weak self] in self?.showHome(.commands) }
        dictation.onOpenSpeechSettings = { [weak self] in self?.showHome(.dictation) }
        // One download at a time, the speech model first: together both crawled.
        speechWatch = dictation.$speechModelState.receive(on: RunLoop.main).sink { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .downloading = state { self.download.holdForSpeech() } else { self.download.releaseForSpeech() }
            }
        }
        dictation.onFindFiles = { [weak self] query in await self?.fileCandidates(query) ?? [] }
        statusMenu.dictationItems = { [weak self] in self?.dictation.compactMenuItems() ?? [] }
        statusMenu.dictation = dictation
        statusMenu.onCommands = { [weak self] in self?.showHome(.commands) }
        dictation.start()

        hotkeys.onPress = { [weak self] in
            guard let self else { return }
            if let hotkeyTester { hotkeyTester() } else { panel.toggle() }
        }
        if let combo = KeyCombo(model.settings.hotkey) {
            model.hotkey = hotkeys.register(combo) ? combo : nil
            log(model.hotkey == nil ? "hotkey \(combo.display) is taken by another app" : "hotkey \(combo.display)")
        } else {
            log("hotkey: can't read \"\(model.settings.hotkey)\" (try cmd+shift+space)")
        }

        Previews.shared.passage = { [engine] id, code in await engine.text(ofSegment: id, code: code) }
        CodeEditor.current = CodeEditor.chosen(model.settings.codeEditor)
        download.onReady = { [weak self] in self?.engine.modelArrived() }
        engine.start()
        let settings = model.settings
        if !settings.onboarded, settings.roots.isEmpty {
            showOnboarding()
        } else {
            // Set up already (the go-ahead came with onboarding), so a missing model just downloads.
            if !download.isReady { download.start() }
            if showWindow { showHome() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil,
                                                                               queue: .main) { [weak self] note in
                let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                MainActor.assumeIsolated { self?.volumeChanged(volume) }
            })
        }
    }

    /// A drive was connected or ejected: only a chosen folder on it (or one that's missing) is of interest.
    private func volumeChanged(_ volume: String?) {
        guard let volume else { return }
        let prefix = volume.hasSuffix("/") ? volume : volume + "/"
        let affected = model.settings.roots.contains { $0.path == volume || $0.path.hasPrefix(prefix) }
            || !model.status.missingRoots.isEmpty
        guard affected else { return }
        log("volume: \(volume) came or went")
        engine.volumesChanged()
    }

    // MARK: Folders

    /// The folders to index from now on, and those to skip in them (and the file types, when given); the engine
    /// follows without a relaunch. A folder another chosen one already searches is dropped (its files would be found
    /// twice), and so is a skip with nothing around it to skip from (`FolderSelection`).
    func applyFolders(_ roots: [URL], excluded: [URL]? = nil, types: [String]? = nil) {
        let selection = FolderSelection(chosen: roots.map { AppSettings.folderURL($0.path).path },
                                        skipped: (excluded ?? model.settings.excludedFolders).map(\.path))
        let roots = selection.folders.map(AppSettings.folderURL)
        let excluded = selection.effectiveSkips.map(AppSettings.folderURL)
        let types = types ?? model.settings.excludedTypes
        if roots.count < selection.chosen.count {
            log("folders: \(selection.chosen.count - roots.count) inside another chosen folder, already covered")
        }
        let settings = model.settings
        guard roots != settings.roots || excluded != settings.excludedFolders || types != settings.excludedTypes
        else { return }
        AppSettings.save(roots: roots)
        AppSettings.save(excludedFolders: excluded)
        AppSettings.save(excludedTypes: types)
        model.settings.roots = roots
        model.settings.excludedFolders = excluded
        model.settings.excludedTypes = types
        engine.setFolders(roots: roots, excluded: excluded, excludedTypes: types)
    }

    func removeFolder(_ root: URL) {
        applyFolders(model.settings.roots.filter { $0.path != root.path })
    }

    func setExcluded(_ folders: [URL]) {
        AppSettings.save(excludedFolders: folders)
        model.settings.excludedFolders = folders
        engine.setFolders(roots: model.settings.roots, excluded: folders, excludedTypes: model.settings.excludedTypes)
    }

    /// File extensions never to index ("heic, .txt"); files of those types already indexed leave the index.
    func setExcludedTypes(_ text: String) {
        let types = IndexOptions.extensions(text).sorted()
        guard types != model.settings.excludedTypes else { return }
        AppSettings.save(excludedTypes: types)
        model.settings.excludedTypes = types
        engine.setFolders(roots: model.settings.roots, excluded: model.settings.excludedFolders, excludedTypes: types)
    }

    // MARK: Code search

    /// The code folders from now on (none turns code search off and deletes the code index), and those skipped in
    /// them, by `FolderSelection`'s rule.
    func applyCodeFolders(_ roots: [URL], excluded: [URL]) {
        let selection = FolderSelection(chosen: roots.map { AppSettings.folderURL($0.path).path },
                                        skipped: excluded.map(\.path))
        let roots = selection.folders.map(AppSettings.folderURL)
        let excluded = selection.effectiveSkips.map(AppSettings.folderURL)
        guard roots != model.settings.codeRoots || excluded != model.settings.codeExcluded else { return }
        AppSettings.save(codeRoots: roots, excluded: excluded)
        model.settings.codeRoots = roots
        model.settings.codeExcluded = excluded
        engine.setCodeFolders(roots: roots, excluded: excluded)
    }

    func removeCodeFolder(_ root: URL) {
        applyCodeFolders(model.settings.codeRoots.filter { $0.path != root.path },
                         excluded: model.settings.codeExcluded.filter { !FolderSelection.isInside($0.path, root.path) })
    }

    /// The editor code results open in (a bundle id; "" for each file's default app).
    func setCodeEditor(_ id: String) {
        AppSettings.save(codeEditor: id)
        model.settings.codeEditor = id
        CodeEditor.current = CodeEditor.chosen(id)
        log("code results open in \(CodeEditor.current.name)")
    }

    func setIndexOnBattery(_ on: Bool) {
        AppSettings.save(indexOnBattery: on)
        model.settings.indexOnBattery = on
        power.setIndexOnBattery(on)
    }

    /// "Index only at set hours": on or off, and the hours (kept while it's off).
    func setIndexHours(on: Bool, hours: IndexHours) {
        AppSettings.save(indexHoursOn: on, hours: hours)
        model.settings.indexHoursOn = on
        model.settings.indexHours = hours
        schedule.setHours(on ? hours : nil)
    }

    /// Asks for folders with the standard open panel (as a sheet when there's a window).
    func pickFolders(for window: NSWindow?, prompt: String = "Add", then done: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = "Choose folders for Murmur to search."
        let finish = { (response: NSApplication.ModalResponse) in
            done(response == .OK ? panel.urls.map { AppSettings.folderURL($0.path) } : [])
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// No folders yet: onboarding if it never ran, else Settings' folder list with Add Folders open.
    func chooseFolders() {
        guard model.settings.onboarded else { return showOnboarding() }
        showSettings(.folders)
        settingsWindow.addFolders()
    }

    /// Settings → Code with its folders' sheet open.
    func chooseCodeFolders() {
        showSettings(.code)
        settingsWindow.addCodeFolders()
    }

    // MARK: Hotkey

    /// Nil when `combo` is now the hotkey, else why it can't be.
    func setHotkey(_ combo: KeyCombo) -> String? {
        if let conflict = combo.systemConflict { return conflict }
        guard hotkeys.register(combo) else { return "Another app is using \(combo.display)" }
        AppSettings.save(hotkey: combo.spec)
        model.settings.hotkey = combo.spec
        model.hotkey = combo
        log("hotkey: \(combo.display)")
        return nil
    }

    /// The shortcut recorder is listening (the hotkey steps aside so pressing it reaches the recorder).
    func hotkeyRecording(_ on: Bool) {
        if on { hotkeys.suspend() } else { hotkeys.resume() }
    }

    // MARK: Login item

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Dev builds (anywhere but /Applications) don't suggest it, so trying a build never adds a login item.
    var suggestsLaunchAtLogin: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// Nil when done, else why it failed.
    func setLaunchAtLogin(_ on: Bool) -> String? {
        guard on != launchesAtLogin else { return nil }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log("login item: \(on ? "on" : "off")")
            return nil
        } catch {
            log("login item: \(error)")
            return error.localizedDescription
        }
    }

    // MARK: Windows

    func showSearchWindow(query: String? = nil, kind: ResultGroupKind? = nil) {
        searchWindow.show(query: query, kind: kind)
    }

    /// "Open my resume pdf": searches with the model's description and opens the top result; with no match, shows the
    /// Search page.
    func openBestFile(_ spoken: String) async -> String {
        guard model.hasFolders else {
            showSearchWindow(query: spoken)
            return "Choose folders to search first."
        }
        let (wanted, hits, named) = await searchFile(spoken)
        let rows = ResultSet(hits, query: wanted.text).ranked
        let kindNames = wanted.kinds.map { $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "any"
        log("open file: \"\(spoken)\" → \"\(wanted.text)\" in \(kindNames): \(named.count) named, \(rows.count) strong, top "
            + "\(named.first.map { ($0.file.path as NSString).lastPathComponent } ?? rows.first?.name ?? "none")")
        // A file named for what was asked ("PanCard.pdf" for "my PAN card") opens first: a scanned card has little
        // text, and a long document that mentions the words outranked it in the search.
        if let file = named.first {
            let url = URL(fileURLWithPath: file.file.path)
            log("open: \(url.lastPathComponent) (its name matches)" + (Opener.dryRun ? " (dry run)" : ""))
            if !Opener.dryRun { NSWorkspace.shared.open(url) }
            return "Opened \(url.lastPathComponent)."
        }
        // Otherwise the search's best match: its ranking weighs the words, the file's text and the kind asked for.
        if let best = rows.first {
            engine.open(best)
            return "Opened \(best.name)."
        }
        showSearchWindow(query: wanted.text)
        return "Nothing matched “\(wanted.text)”."
    }

    /// The one search behind opening a file by description: what `openBestFile` opens and what the command model
    /// picks from are the same results, in the same order.
    private func searchFile(_ spoken: String) async
        -> (SpokenFile, [SearchHit], [(file: FileRecord, score: Double)]) {
        // "my Aadhaar card": the user's own documents usually carry their name.
        let wanted = SpokenFile(spoken, owner: CommandAgent.ownerForPersonalFile(spoken))
        let vector = await engine.embedQuery(wanted.text)
        let hits = await engine.search(wanted.text, vector: vector, prefixLast: false, kinds: wanted.kinds, limit: 30)
        var named = await engine.filesNamed(wanted.text, kinds: wanted.kinds)
        // "My resume" names Roma's CV as well as yours: between equally good names, the one with your name first.
        if !wanted.owner.isEmpty {
            let mine = { (file: FileRecord) in
                FileNameMatch.nameWords((file.path as NSString).lastPathComponent).contains { wanted.owner.contains($0) }
            }
            named = named.enumerated().sorted { a, b in
                if a.element.score != b.element.score { return a.element.score > b.element.score }
                let (x, y) = (mine(a.element.file), mine(b.element.file))
                return x != y ? x : a.offset < b.offset
            }.map(\.element)
        }
        return (wanted, hits, named)
    }

    /// The strong matches for a description, best first, for the command model to pick from.
    func fileCandidates(_ spoken: String) async -> [FileCandidate] {
        guard model.hasFolders else { return [] }
        let (wanted, hits, named) = await searchFile(spoken)
        // Files named for it first (scored above any search score, so one alone is a clear winner), then the search's
        // matches. At least five of those: one long document that mentions the words used to leave only itself above
        // the cut, and the photo of the driving license below it.
        let strong = hits.prefix(max(Searcher.strongCount(hits), 5))
        var seen = Set<String>()
        var files: [FileCandidate] = named.compactMap { item in
            guard seen.insert(item.file.path).inserted else { return nil }
            return FileCandidate(path: item.file.path, kind: item.file.kind.rawValue,
                                 modified: Date(timeIntervalSince1970: item.file.mtime),
                                 excerpt: "its name matches what was asked", score: 100 * item.score)
        }
        for hit in strong where files.count < 8 && seen.insert(hit.path).inserted {
            files.append(FileCandidate(path: hit.path, kind: hit.kind.rawValue,
                                       modified: Date(timeIntervalSince1970: hit.modified), excerpt: hit.excerpt,
                                       score: hit.score))
        }
        log("open file: \"\(spoken)\" → \"\(wanted.text)\": \(files.count) for the model (\(named.count) named), top "
            + "\(files.first.map { ($0.path as NSString).lastPathComponent } ?? "none")")
        return files
    }

    func showHome(_ section: HomeSection? = nil) {
        home.show(section)
    }

    /// The old Settings window's tabs live on the Murmur window's Folders page now.
    func showSettings(_ tab: SettingsTab = .general) {
        // General's settings (the shortcut, login, updates) are on the Settings page; the rest on Folders.
        if tab == .general { home.show(.dictation); return }
        home.state.foldersTab = tab
        home.show(.folders)
    }

    func showOnboarding() {
        let onboarding = self.onboarding ?? OnboardingController(app: self)
        self.onboarding = onboarding
        onboarding.show()
    }

    /// Onboarding closed: by Done, or by its close button. Folders chosen by then count as set up.
    func onboardingClosed() {
        hotkeyTester = nil
        if model.hasFolders {
            AppSettings.saveOnboarded()
            model.settings.onboarded = true
        }
        onboarding = nil
        windowClosed()
    }

    /// Brings a window forward, with the Dock icon showing while any window is open. Offscreen test runs only build it.
    func present(_ window: NSWindow) {
        guard !Self.offscreen else { return }
        // Come to the desktop you're on, not the Space the window was last open on (it looked like nothing happened).
        if !window.collectionBehavior.contains(.canJoinAllSpaces) { window.collectionBehavior.insert(.moveToActiveSpace) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.setActivationPolicy(.regular)
        // macOS can decline a menu bar app's request to come forward; ask both ways, and put the window in front
        // regardless, so it never opens behind the app you're in.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        bringAppToFront()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        // Activation can land a moment later than the window: make sure it ends up key and in front.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if !window.isKeyWindow {
                bringAppToFront()
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }

    /// A window closed: the Dock icon goes once none is left.
    func windowClosed() {
        DispatchQueue.main.async { [self] in
            let open = [searchWindow?.isVisible, settingsWindow?.isVisible, onboarding?.isVisible, home?.isVisible]
                .contains { $0 == true }
            if !open {
                NSApp.setActivationPolicy(.accessory)
                Thumbnails.shared.clear()
                Previews.shared.clear()
            }
        }
    }
}

/// A file as you'd say it: "my resume pdf" is the words "resume", in PDFs.
struct SpokenFile {
    let text: String
    let kinds: Set<FileKind>?
    /// The user's own name (from memory), for "my resume", "my Aadhaar card": it's searched for, and between files
    /// that match it picks the one with their name, but a file isn't chosen for having their name alone (that would
    /// open their resume for "my Aadhaar card").
    let owner: [String]

    private static let typeWords: [String: Set<FileKind>] = [
        "pdf": [.pdf], "pdfs": [.pdf],
        "doc": [.doc, .pdf], "docs": [.doc, .pdf], "docx": [.doc], "document": [.doc, .pdf], "documents": [.doc, .pdf],
        "file": [], "files": [],
        "photo": [.image], "photos": [.image], "picture": [.image], "pictures": [.image], "image": [.image],
        "images": [.image], "screenshot": [.screenshot], "screenshots": [.screenshot],
        "video": [.video], "videos": [.video], "recording": [.audio, .video], "recordings": [.audio, .video],
        "spreadsheet": [.doc], "spreadsheets": [.doc], "sheet": [.doc], "slides": [.doc, .pdf], "deck": [.doc, .pdf],
        "presentation": [.doc, .pdf],
    ]

    init(_ spoken: String, owner ownerName: String? = nil) {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        var owner = (ownerName ?? "").split(separator: " ").map { fold(String($0)) }.filter { $0.count > 1 }
        let said = spoken.lowercased().split(separator: " ").map(String.init)
        // "Shubham Agrawal Aadhaar" when memory only knows "Shubham": the word after the user's name is their surname,
        // not what the file is about (it matched their resume's name, so the resume opened for "my Aadhaar card").
        for (index, word) in said.enumerated() where index > 0 && owner.contains(fold(said[index - 1])) {
            let next = fold(word)
            if next.count > 2, Self.typeWords[next] == nil, !owner.contains(next) { owner.append(next) }
        }
        self.owner = owner
        let words = said
            .filter { word in !owner.contains(fold(word.trimmingCharacters(in: CharacterSet(charactersIn: "'’s")))) }
        var kinds = Set<FileKind>()
        var rest: [String] = []
        for word in words {
            if let found = Self.typeWords[word] { kinds.formUnion(found) } else { rest.append(word) }
        }
        let filler: Set<String> = ["my", "the", "a", "an", "that", "this", "our", "of", "called", "named",
                                   // Hinglish: "meri resume wali PDF", "mujhe bank statement ki file"
                                   "mujhe", "meri", "mera", "mere", "apni", "apna", "apne", "wala", "wali", "wale",
                                   "vala", "vali", "vale", "ki", "ka", "ke", "ko", "se"]
        rest = rest.filter { !filler.contains($0) }
        // A CV is a résumé: look for both.
        if rest.contains(where: { ["cv", "resume", "résumé"].contains($0) }) {
            rest = rest.filter { !["cv", "resume", "résumé"].contains($0) } + ["resume", "cv"]
        }
        // What the file is, without the user's name: their name is in every file about them (a handover, a
        // contract), which then outranked the Aadhaar or PAN card asked for.
        text = rest.isEmpty ? spoken : rest.joined(separator: " ")
        // A photo can be a screenshot and the other way round; "file" says nothing.
        if kinds.contains(.image) { kinds.insert(.screenshot) }
        self.kinds = kinds.isEmpty ? nil : kinds
    }
}
