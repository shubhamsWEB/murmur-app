import AppKit
import ApplicationServices
import AgentKit
import AVFoundation
import Carbon.HIToolbox

/// Murmur's dictation: hold the dictation key to talk and release to insert, or double-tap it for hands-free and tap
/// again to finish (Esc cancels). Speech is transcribed on this Mac and pasted into the focused app.
@MainActor
public final class DictationController: ObservableObject {
    /// Where the speech model is: shown on Murmur's Home and in the menu.
    public enum SpeechModelState: Equatable {
        case waiting
        case downloading(Double)
        case preparing(Double)
        case ready
        case failed(String)

        public var isReady: Bool { self == .ready }
    }

    public enum Phase: Equatable {
        case idle
        case listening(handsFree: Bool)
        case transcribing
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var speechModelState: SpeechModelState = .waiting
    public private(set) var lastText: String?
    @Published public private(set) var modelStatus = "Speech model not loaded"
    /// Where log lines go (the app passes its own logger).
    public var log: (String) -> Void = { print($0) }

    private let recorder = MicRecorder()
    private var transcriber: SpeechTranscriber
    private var lastSamples: [Float] = []
    private let hud = DictationHUD()
    private let monitor: DictationKeyMonitor
    private var pressedAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var retryTimer: Timer?
    private var openedAccessibilitySettings = false
    private var warnedAboutKey = false
    /// ⌃ was held with the dictation key: the speech is a command, not text to type.
    private var commandRequested = false
    /// ⇧ held with the talk key: dictation only, never a command (the opposite of ⌃).
    private var typingRequested = false
    /// The app you were in when you pressed the key (commands paste back into it).
    private var previousApp: NSRunningApplication?
    /// At the key press: whether a text field had the focus, and what was selected.
    private var focusAtPress = IntentClassifier.Focus.unknown
    private var selectionAtPress: String?
    /// Audio is coming in for this recording.
    private var micLive = false
    /// The pill says the microphone is starting (so it switches to listening once it's on).
    private var showingMicStart = false
    /// Which start the microphone's answer belongs to (a quick tap and a second press can overlap).
    private var micAttempt = UUID()
    /// What the speech model heard last, before AI cleanup (for "Paste Exactly What I Said").
    private var lastHeard: String?
    /// The last spoken command, shown above its answer.
    private var lastCommand: String?
    /// AI cleanup changed the last dictation.
    private var lastCleaned = false
    private let logo = FloatingLogo()

    /// Decide from the words whether you're dictating or giving a command (on by default). Fn+⌃ always means a command.
    public var detectCommands: Bool {
        get { UserDefaults.standard.object(forKey: "detectCommands") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "detectCommands") }
    }
    private let answerPanel = AnswerPanel()
    private lazy var agent = CommandAgent(host: makeHost())
    /// Murmur's log file (set by the app), for "Open Log".
    public var logFile: URL?
    /// Opens Murmur's file search with a query (set by the app).
    public var onSearchFiles: ((String) -> Void)?
    /// Opens the file that best matches a description, or shows the matches (set by the app). Returns what it did.
    public var onOpenFile: ((String) async -> String)?
    /// Opens the settings for the commands' model (set by the app).
    public var onOpenModelSettings: (() -> Void)?
    /// Opens Murmur's window (the floating button, set by the app).
    public var onOpenApp: (() -> Void)?
    /// Opens Settings at the speech languages (no speech model chosen yet).
    public var onOpenSpeechSettings: (() -> Void)?
    /// The search's best matches for a description of a file (set by the app).
    public var onFindFiles: ((String) async -> [FileCandidate])?

    /// A press shorter than this is a tap, not a hold (taps start hands-free dictation).
    private let tapLength: TimeInterval = 0.3
    /// Two taps within this time make a double-tap.
    private let doubleTapWindow: TimeInterval = 0.4
    /// Shorter recordings are treated as accidental and dropped.
    private let minimumSamples = 16_000 / 4

    private static let keyDefault = "dictationKey"
    private static let typingModifierDefault = "dictation.typingModifier"
    private static let commandModifierDefault = "dictation.commandModifier"
    private static let modelDefault = "speechModel"
    private static let whisperDefault = "whisperMode"
    private static let keepDefault = "keepRecordings"
    private static let fitTextDefault = "dictation.fitText"
    private static let microphoneDefault = "dictation.microphone"
    private static let preferBuiltInDefault = "dictation.preferBuiltInMic"
    private static let showLogoDefault = "dictation.showLogo"
    private static let aiCleanupDefault = "dictation.aiCleanup"

    /// The microphone picked in Settings (its Core Audio UID); nil chooses automatically: the system's input, or the
    /// Mac's own microphone instead of a Bluetooth headset when `preferBuiltInMic` is on.
    public var microphoneUID: String? {
        get { UserDefaults.standard.string(forKey: Self.microphoneDefault) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.microphoneDefault)
            recorder.chosenUID = newValue
            log("dictation: microphone is now \(newValue.flatMap { AudioDevices.input(uid: $0)?.name } ?? "automatic")")
            objectWillChange.send()
        }
    }

    /// Use the Mac's own microphone rather than AirPods or another Bluetooth headset (on by default): their
    /// microphone drops them to a phone-call codec, which is worse for recognition and for your music.
    public var preferBuiltInMic: Bool {
        get { UserDefaults.standard.object(forKey: Self.preferBuiltInDefault) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.preferBuiltInDefault)
            recorder.preferBuiltIn = newValue
            objectWillChange.send()
        }
    }

    /// The microphones to choose from, and the one dictation would use now.
    public func microphones() -> [AudioDevices.Input] { AudioDevices.inputs() }
    public func microphoneInUse() -> AudioDevices.Input? { recorder.currentChoice() }

    /// The Murmur button on screen (on by default): click to open Murmur, drag to move it.
    public var showLogo: Bool {
        get { UserDefaults.standard.object(forKey: Self.showLogoDefault) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.showLogoDefault)
            logo.setEnabled(newValue)
            objectWillChange.send()
        }
    }

    /// AI cleanup (off by default): fillers and stumbles out, self-corrections applied, lists set out, in the style
    /// for the kind of app. Uses the commands' model; with Claude or OpenAI the dictated words go to that provider.
    public var aiCleanup: Bool {
        get { UserDefaults.standard.bool(forKey: Self.aiCleanupDefault) }
        set { UserDefaults.standard.set(newValue, forKey: Self.aiCleanupDefault); objectWillChange.send() }
    }

    public func cleanupStyle(for category: DictationCleanup.Category) -> DictationCleanup.Style {
        UserDefaults.standard.string(forKey: "dictation.cleanupStyle.\(category.rawValue)")
            .flatMap(DictationCleanup.Style.init).flatMap { category.styles.contains($0) ? $0 : nil }
            ?? category.defaultStyle
    }

    public func setCleanupStyle(_ style: DictationCleanup.Style, for category: DictationCleanup.Category) {
        UserDefaults.standard.set(style.rawValue, forKey: "dictation.cleanupStyle.\(category.rawValue)")
        objectWillChange.send()
    }

    /// Where AI cleanup's words go: on this Mac, or to a provider.
    public var cleanupModel: String { agent.currentRouter().name }

    /// Fits what you say to the sentence it goes into: the space before it, no capital or full stop mid-sentence.
    /// The words are never changed.
    public var fitText: Bool {
        get { UserDefaults.standard.object(forKey: Self.fitTextDefault) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.fitTextDefault); objectWillChange.send() }
    }

    /// While other languages update to Parakeet Ultra: how far the download is (0…1).
    @Published public private(set) var multilingualUpdate: Double?
    /// Other languages are on v3 and the more accurate Ultra can be downloaded.
    public var multilingualUpdateAvailable: Bool {
        transcriber.model == .multilingual && ParakeetTranscriber.multilingualUpdateAvailable
    }

    /// Downloads Parakeet Ultra next to v3 (dictation keeps working on v3 meanwhile), switches to it, then frees
    /// v3's space.
    public func updateMultilingual() {
        guard multilingualUpdate == nil, multilingualUpdateAvailable else { return }
        multilingualUpdate = 0
        log("dictation: updating other languages to Parakeet Ultra")
        let next = SpeechTranscriber.multilingualUltra()
        let started = Date()
        Task { [weak self] in
            do {
                try await next.prepare { [weak self] fraction, downloading in
                    DispatchQueue.main.async {
                        guard let self, downloading else { return }
                        self.multilingualUpdate = fraction
                    }
                }
                guard let self else { return }
                multilingualUpdate = nil
                if transcriber.model == .multilingual {
                    transcriber = next
                    log(String(format: "dictation: other languages now use Parakeet Ultra (%.0f s)",
                               Date().timeIntervalSince(started)))
                }
                Task.detached(priority: .background) { ParakeetTranscriber.removeOldMultilingual() }
                objectWillChange.send()
            } catch {
                self?.multilingualUpdate = nil
                self?.log("dictation: the Ultra update failed: \(error.localizedDescription)")
                self?.hud.flash("Couldn't download the update · try again in Settings", seconds: 4)
            }
        }
    }

    /// Keep every recording and what the speech model heard (Documents/Murmur Recordings), to compare speech models on
    /// the same clips. Off by default; nothing leaves this Mac.
    public var keepRecordings: Bool {
        get { UserDefaults.standard.bool(forKey: Self.keepDefault) }
        set { UserDefaults.standard.set(newValue, forKey: Self.keepDefault) }
    }

    public static var recordingsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Murmur Recordings")
    }

    /// Opens the kept recordings in Finder.
    public func showRecordings() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    /// Saves one recording as a 16 kHz WAV and adds a line to clips.tsv: file, model, seconds of audio, seconds to
    /// transcribe, text.
    private func keep(_ samples: [Float], text: String, model: SpeechModel, took: TimeInterval) {
        let folder = Self.recordingsFolder
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let name = "\(stamp.string(from: Date())).wav"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try WAV.write(samples, sampleRate: 16_000, to: folder.appendingPathComponent(name))
            let index = folder.appendingPathComponent("clips.tsv")
            if !FileManager.default.fileExists(atPath: index.path) {
                try Data("file\tmodel\taudio_s\ttook_s\ttext\n".utf8).write(to: index)
            }
            let clean = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            let line = String(format: "%@\t%@\t%.1f\t%.2f\t%@\n", name, model.rawValue,
                              Double(samples.count) / 16_000, took, clean)
            let handle = try FileHandle(forWritingTo: index)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            log("dictation: can't keep the recording: \(error.localizedDescription)")
        }
    }

    /// Quiet Voice: boost soft speech up to 40 dB instead of 30 dB, for whispering or speaking softly. On unless
    /// you turn it off: speaking softly to the Mac is the usual way, and a stronger boost costs nothing at normal
    /// volume. (Named for your voice, not OpenAI's Whisper: speech is always recognised on this Mac. The setting
    /// keeps its old key, so a choice already made stays.)
    public var whisperMode: Bool {
        get { UserDefaults.standard.object(forKey: Self.whisperDefault) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.whisperDefault) }
    }

    public init() {
        let model = UserDefaults.standard.string(forKey: Self.modelDefault).flatMap(SpeechModel.init(saved:))
        transcriber = SpeechTranscriber(model: model ?? .english)
        let saved = UserDefaults.standard.string(forKey: Self.keyDefault).flatMap(DictationKeyMonitor.Key.init)
        monitor = DictationKeyMonitor(key: saved ?? .fn)
        monitor.onDown = { [weak self] in self?.keyDown() }
        monitor.onUp = { [weak self] in self?.keyUp() }
        monitor.onOtherKey = { [weak self] code in self?.otherKey(code) }
        monitor.onModifiers = { [weak self] flags in self?.modifiersChanged(flags) }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.setLevel(level) }
        }
        recorder.chosenUID = UserDefaults.standard.string(forKey: Self.microphoneDefault)
        recorder.preferBuiltIn = UserDefaults.standard.object(forKey: Self.preferBuiltInDefault) as? Bool ?? true
        hud.onVisible = { [weak self] frame in self?.logo.pillMoved(frame) }
        // With the Murmur button on screen, the listening pill grows out of it (one pill, not two).
        hud.anchor = { [weak self] in self?.logo.anchor }
        logo.onOpen = { [weak self] in self?.onOpenApp?() }
        logo.onStartDictation = { [weak self] in self?.logoClicked() }
        logo.onHide = { [weak self] in
            self?.showLogo = false
            self?.hud.flash("Murmur button hidden · turn it back on in Settings", seconds: 3, tone: .info)
        }
        // Which app you're working in, so "what's on my screen" reads it even when Murmur's own window is in front.
        ScreenControl.watchFrontApp()
        BrowserControl.onNeedsPermission = { [weak self] message in self?.hud.flash(message, seconds: 6, tone: .info) }
        BrowserControl.onLog = { [weak self] line in self?.log(line) }
    }

    public var key: DictationKeyMonitor.Key { monitor.key }
    /// Held with the talk key: always typed, never a command (⇧ unless you choose another).
    @Published public private(set) var typingModifier: DictationKeyMonitor.Modifier =
        UserDefaults.standard.string(forKey: "dictation.typingModifier").flatMap(DictationKeyMonitor.Modifier.init) ?? .shift
    /// Held with the talk key: always a command, never typed (⌃ unless you choose another).
    @Published public private(set) var commandModifier: DictationKeyMonitor.Modifier =
        UserDefaults.standard.string(forKey: "dictation.commandModifier").flatMap(DictationKeyMonitor.Modifier.init) ?? .control

    /// The keys that can choose typing or a command with the current talk key (not the one the talk key itself is).
    public var modifierChoices: [DictationKeyMonitor.Modifier] {
        DictationKeyMonitor.Modifier.allCases.filter { $0 != key.ownModifier }
    }

    /// Choosing the other one's key swaps them, so the two always differ.
    public func setTypingModifier(_ modifier: DictationKeyMonitor.Modifier) {
        if modifier == commandModifier { commandModifier = typingModifier }
        typingModifier = modifier
        saveModifiers()
    }

    public func setCommandModifier(_ modifier: DictationKeyMonitor.Modifier) {
        if modifier == typingModifier { typingModifier = commandModifier }
        commandModifier = modifier
        saveModifiers()
    }

    private func saveModifiers() {
        UserDefaults.standard.set(typingModifier.rawValue, forKey: Self.typingModifierDefault)
        UserDefaults.standard.set(commandModifier.rawValue, forKey: Self.commandModifierDefault)
        log("dictation: \(key.cap)+\(typingModifier.symbol) types only, \(key.cap)+\(commandModifier.symbol) runs a command")
    }

    /// A talk key that is itself one of the two (Right ⌥ with ⌥ for commands): that one moves to a free key.
    private func keepModifiersFree() {
        let free = modifierChoices.filter { $0 != typingModifier && $0 != commandModifier }
        if typingModifier == key.ownModifier, let other = free.first { typingModifier = other; saveModifiers() }
        if commandModifier == key.ownModifier, let other = free.first(where: { $0 != typingModifier }) {
            commandModifier = other
            saveModifiers()
        }
    }
    /// The speech model in use.
    public var speechModel: SpeechModel { transcriber.model }
    /// Whether the dictation key is being watched (needs Accessibility).
    public var isListeningForKey: Bool { monitor.isRunning }
    /// Whether Murmur may paste into other apps (Accessibility).
    public var canPaste: Bool { AXIsProcessTrusted() }
    /// The local (Ollama) router model.
    public var localRouterModel: String {
        get { agent.routerModel }
        set { agent.routerModel = newValue }
    }
    /// Opens System Settings at Accessibility or Microphone.
    public func openAccessibilitySettings() { Self.openPrivacyPane("Privacy_Accessibility") }
    public func openMicrophoneSettings() { Self.openPrivacyPane("Privacy_Microphone") }

    /// Asks for the microphone and Accessibility, starts watching the key, and loads the speech model.
    public func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async { self?.log("dictation: microphone \(granted ? "allowed" : "denied")") }
        }
        startMonitor(prompt: true)
        hud.prewarm()
        logo.setEnabled(showLogo)
        Task.detached(priority: .background) { WhisperTranscriber.removeDroppedModels() }
        // Only a model that's here, or one you chose to download: a fresh install used to start a 500 MB download of
        // English before you'd picked a language, alongside the search model (both slow, and not asked for).
        if speechModelChosen {
            Task { await prepareModel() }
        } else {
            modelStatus = "Choose a speech model to download"
            speechModelState = .waiting
            log("dictation: no speech model yet; waiting for a choice")
        }
        // Load the local router model now, so the first command or decision doesn't wait for it.
        if RouterChoice.current == .local {
            let router = agent.routerModel
            Task.detached { await OllamaClient(model: router).warmUp() }
        }
    }

    public func setKey(_ key: DictationKeyMonitor.Key) {
        UserDefaults.standard.set(key.rawValue, forKey: Self.keyDefault)
        monitor.stop()
        monitor.key = key
        startMonitor(prompt: false)
        log("dictation: key is now \(key.display)")
        keepModifiersFree()
        objectWillChange.send()
    }

    /// Whether a speech model can be loaded without asking: one is on this Mac, or you chose one to download.
    public var speechModelChosen: Bool {
        transcriber.model.isOnThisMac || UserDefaults.standard.bool(forKey: "speechModel.chosen")
    }

    /// The model to use, chosen by you (a language card's Download, Settings, the menu). Choosing the one already set
    /// that isn't loaded yet (English, on a fresh install) starts it.
    public func setModel(_ model: SpeechModel) {
        UserDefaults.standard.set(true, forKey: "speechModel.chosen")
        guard model != transcriber.model else {
            switch speechModelState {
            case .waiting, .failed: Task { await prepareModel() }
            default: break
            }
            return
        }
        UserDefaults.standard.set(model.rawValue, forKey: Self.modelDefault)
        transcriber = SpeechTranscriber(model: model)
        stopPreparingClock()
        log("dictation: speech model is now \(model.rawValue)")
        Task { await prepareModel() }
    }

    /// Tries loading the speech model again (after a failed download).
    public func retryModel() {
        Task { await prepareModel() }
    }

    /// Writes the last recording (16 kHz mono, exactly what the model heard) to a WAV file and shows it in Finder.
    public func saveLastRecording() {
        guard !lastSamples.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur last recording.wav")
        do {
            try WAV.write(lastSamples, sampleRate: 16_000, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            log("dictation: can't save the recording: \(error.localizedDescription)")
        }
    }

    /// Pastes the last dictation again (when it couldn't be inserted the first time).
    public func pasteLast() {
        guard let lastText else { return }
        report(TextInserter.insert(lastText))
    }

    /// Items for the menu bar menu.
    /// The few dictation items the menu bar menu keeps (everything else is in Murmur's window): fixing
    /// Accessibility, Quiet Voice, and the last dictation again.
    public func compactMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if !monitor.isRunning || !AXIsProcessTrusted() {
            items.append(ClosureMenuItem("Allow Typing in Other Apps…") { Self.openPrivacyPane("Privacy_Accessibility") })
        }
        if let lastText {
            items.append(ClosureMenuItem("Paste Last Dictation Again") { [weak self] in self?.pasteLast() })
            if let lastHeard, lastCleaned {
                items.append(ClosureMenuItem("Paste Exactly What I Said") { [weak self] in
                    self?.report(TextInserter.insert(lastHeard))
                })
            }
            items.append(ClosureMenuItem("Copy Last Dictation") { TextInserter.copy(lastText) })
        }
        items.append(ClosureMenuItem("Quiet Voice", checked: whisperMode) { [weak self] in
            guard let self else { return }
            whisperMode.toggle()
            log("dictation: quiet voice \(whisperMode ? "on" : "off")")
        })
        return items
    }

    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let header = NSMenuItem(title: "Dictation: hold \(monitor.key.display) to talk", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)
        let status = NSMenuItem(title: monitor.isRunning ? modelStatus : "Needs Accessibility permission",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        items.append(status)
        let canPaste = AXIsProcessTrusted()
        if monitor.isRunning, !canPaste {
            let note = NSMenuItem(title: "Can't paste yet: allow Murmur in Accessibility", action: nil, keyEquivalent: "")
            note.isEnabled = false
            items.append(note)
        }
        if !monitor.isRunning || !canPaste {
            items.append(ClosureMenuItem("Open Accessibility Settings…") {
                Self.openPrivacyPane("Privacy_Accessibility")
            })
        }
        let keyMenu = NSMenu()
        for key in DictationKeyMonitor.Key.allCases {
            keyMenu.addItem(ClosureMenuItem(key.display, checked: key == monitor.key) { [weak self] in
                self?.setKey(key)
            })
        }
        let keyItem = NSMenuItem(title: "Dictation Key", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        items.append(keyItem)
        let modelMenu = NSMenu()
        for model in SpeechModel.allCases {
            modelMenu.addItem(ClosureMenuItem(model.display, checked: model == transcriber.model) { [weak self] in
                self?.setModel(model)
            })
        }
        let modelItem = NSMenuItem(title: "Speech Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        items.append(modelItem)
        let assistants = NSMenu()
        assistants.addItem(ClosureMenuItem("Detect Commands Automatically", checked: detectCommands) { [weak self] in
            guard let self else { return }
            detectCommands.toggle()
            log("intent: automatic detection \(detectCommands ? "on" : "off")")
        })
        let hint = NSMenuItem(title: "\(key.cap)+\(commandModifier.symbol) always runs a command", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        assistants.addItem(hint)
        let typing = NSMenuItem(title: "\(key.cap)+\(typingModifier.symbol) always types, never a command", action: nil, keyEquivalent: "")
        typing.isEnabled = false
        assistants.addItem(typing)
        assistants.addItem(.separator())
        for helper in AssistantCLI.allCases {
            assistants.addItem(ClosureMenuItem("Allow \(helper.display)", checked: helper.isAllowed) { [weak self] in
                helper.isAllowed.toggle()
                self?.log("command: \(helper.display) \(helper.isAllowed ? "allowed" : "not allowed")")
            })
        }
        assistants.addItem(.separator())
        let routerTitle = NSMenuItem(title: "Router (decides and picks actions)", action: nil, keyEquivalent: "")
        routerTitle.isEnabled = false
        assistants.addItem(routerTitle)
        for choice in RouterChoice.allCases {
            let needsKey = choice != .local && !choice.hasKey
            let title = choice.display + (needsKey ? " · needs API key" : "")
            assistants.addItem(ClosureMenuItem(title, checked: choice == RouterChoice.current) { [weak self] in
                guard let self else { return }
                if needsKey, !askForKey(choice) { return }
                RouterChoice.current = choice
                log("command: router is now \(choice.display)")
            })
        }
        let localMenu = NSMenu()
        for model in ["qwen3:1.7b", "qwen3:4b", "qwen3:8b", "llama3.2:3b"] {
            localMenu.addItem(ClosureMenuItem(model, checked: model == agent.routerModel) { [weak self] in
                self?.agent.routerModel = model
            })
        }
        let localItem = NSMenuItem(title: "Local Model", action: nil, keyEquivalent: "")
        localItem.submenu = localMenu
        assistants.addItem(localItem)
        assistants.addItem(.separator())
        for choice in [RouterChoice.anthropic, .openai] {
            let provider = choice == .anthropic ? "Anthropic" : "OpenAI"
            let title = choice.hasKey ? "Change \(provider) API Key…" : "Add \(provider) API Key…"
            assistants.addItem(ClosureMenuItem(title) { [weak self] in _ = self?.askForKey(choice) })
        }
        let assistantsItem = NSMenuItem(title: "Commands & Assistants", action: nil, keyEquivalent: "")
        assistantsItem.submenu = assistants
        items.append(assistantsItem)
        items.append(ClosureMenuItem("Quiet Voice", checked: whisperMode) { [weak self] in
            guard let self else { return }
            whisperMode.toggle()
            log("dictation: quiet voice \(whisperMode ? "on" : "off")")
        })
        if let lastText {
            items.append(ClosureMenuItem("Paste Last Dictation") { [weak self] in self?.pasteLast() })
            items.append(ClosureMenuItem("Copy Last Dictation") { TextInserter.copy(lastText) })
        }
        if let logFile {
            items.append(ClosureMenuItem("Open Log") { NSWorkspace.shared.open(logFile) })
            items.append(ClosureMenuItem("Forget Recent Commands") { [weak self] in
                CommandMemory.forget(all: true)
                self?.log("memory: cleared")
            })
        }
        if !lastSamples.isEmpty {
            items.append(ClosureMenuItem("Save Last Recording…") { [weak self] in self?.saveLastRecording() })
        }
        return items
    }

    // MARK: - Key handling

    private func keyDown() {
        switch phase {
        case .listening(handsFree: true):
            finish()                       // a tap ends hands-free dictation
        case .idle:
            // Nothing to hear you with yet: say so, and show where to choose one.
            guard speechModelChosen else {
                hud.flash("Choose a speech model first", seconds: 3)
                onOpenSpeechSettings?()
                return
            }
            let doubleTap = Date().timeIntervalSince(lastTapAt) < doubleTapWindow
            pressedAt = Date()
            commandRequested = NSEvent.modifierFlags.contains(commandModifier.appKitFlag)
            typingRequested = !commandRequested && NSEvent.modifierFlags.contains(typingModifier.appKitFlag)
            previousApp = NSWorkspace.shared.frontmostApplication
            // The microphone first: asking the app for its focus and selection can take a moment (Chrome, Electron
            // apps), and a quick first word was lost while it did.
            begin(handsFree: doubleTap)
            focusAtPress = Self.focus()
            selectionAtPress = Self.selectedText()
        default:
            break
        }
    }

    private func keyUp() {
        guard case .listening(handsFree: false) = phase else { return }
        if Date().timeIntervalSince(pressedAt) < tapLength {
            // A tap, not a hold: drop the audio and wait to see whether a second tap follows.
            recorder.cancel()
            phase = .idle
            hud.hide()
            lastTapAt = Date()
        } else {
            finish()
        }
    }

    /// ⌃ pressed while the dictation key is held turns this recording into a command; ⇧ makes it typing only.
    private func modifiersChanged(_ flags: CGEventFlags) {
        guard case .listening(let handsFree) = phase, !commandRequested, !typingRequested else { return }
        if flags.contains(commandModifier.eventFlag) {
            commandRequested = true
            hud.show(.command)
        } else if flags.contains(typingModifier.eventFlag) {
            typingRequested = true
            hud.show(.typingOnly(handsFree: handsFree))
        }
    }

    private func otherKey(_ code: Int64) {
        switch phase {
        case .listening(handsFree: true) where code == Int64(kVK_Escape):
            cancel()
        case .listening(handsFree: false):
            cancel()                       // Fn was part of a shortcut (Fn+Delete, Fn+arrow…), not dictation
        default:
            break
        }
    }

    // MARK: - Dictation

    private func begin(handsFree: Bool) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.flash("Murmur needs microphone access")
            Self.openPrivacyPane("Privacy_Microphone")
            return
        }
        // The pill first, so you see Murmur listening the moment you press the key; the microphone starts off the
        // main thread and keeps everything from the start. A Bluetooth headset can take a second to wake, and what
        // was said meanwhile was lost while the pill already said "Listening": until audio is coming in it says
        // the microphone is starting.
        phase = .listening(handsFree: handsFree)
        micLive = false
        hud.show(listeningMode(handsFree: handsFree))
        let attempt = UUID()
        micAttempt = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, micAttempt == attempt, !micLive, case .listening = phase else { return }
            showingMicStart = true
            hud.show(.startingMic)
        }
        recorder.start { [weak self] result in
            guard let self, micAttempt == attempt else { return }
            if let error = result.error {
                log("dictation: can't start the microphone: \(error)")
                guard case .listening = phase else { return }
                phase = .idle
                hud.flash("Can't start the microphone")
                return
            }
            micLive = true
            let name = result.device.map { "\($0.name) (\($0.kind))" } ?? "the default microphone"
            log(String(format: "dictation: listening with %@, on in %.2f s", name, result.took))
            if let fellBack = result.fellBack { log("dictation: used the default microphone instead of \(fellBack)") }
            guard case .listening(let handsFree) = phase else { return }
            if showingMicStart {
                showingMicStart = false
                hud.show(listeningMode(handsFree: handsFree))
            }
        }
    }

    /// The pill while recording: a command (⌃), typing only (⇧), or plain listening.
    private func listeningMode(handsFree: Bool) -> DictationHUD.Mode {
        commandRequested ? .command : typingRequested ? .typingOnly(handsFree: handsFree) : .listening(handsFree: handsFree)
    }

    /// The Murmur button's Start Dictation: hands-free (like a double-tap of the key); the next one finishes.
    private func logoClicked() {
        switch phase {
        case .listening:
            finish()
        case .idle:
            guard speechModelChosen else {
                hud.flash("Choose a speech model first", seconds: 3)
                onOpenSpeechSettings?()
                return
            }
            pressedAt = Date()
            commandRequested = false
            typingRequested = false
            previousApp = NSWorkspace.shared.frontmostApplication
            begin(handsFree: true)
            focusAtPress = Self.focus()
            selectionAtPress = Self.selectedText()
        default:
            break
        }
    }

    private func cancel() {
        recorder.cancel()
        phase = .idle
        hud.hide()
    }

    /// Stops listening a quarter of a second after the key comes up: the last word is often still being said as
    /// the key is released, and its end was cut off.
    private func finish() {
        phase = .transcribing
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.finishRecording()
        }
    }

    private func finishRecording() {
        let recorded = recorder.stop()
        showingMicStart = false
        guard recorded.count >= minimumSamples else {
            phase = .idle
            hud.hide()
            return
        }
        phase = .transcribing
        let leveled = AudioLevel.normalize(recorded, maxGainDB: whisperMode ? 40 : 30)
        log(String(format: "dictation: speech %.0f dBFS, noise %.0f dBFS, gain +%.0f dB%@",
                   leveled.speechDB, leveled.noiseDB, leveled.gainDB, whisperMode ? " (quiet voice)" : ""))
        let samples = leveled.samples
        lastSamples = samples
        // Next to no sound at all: the microphone isn't hearing you (muted, the wrong one, a closed lid).
        let silent = leveled.speechDB < -55
        let micName = recorder.device?.name
        let transcriber = transcriber
        let forcedCommand = commandRequested
        let typingOnly = typingRequested
        let frontApp = previousApp?.localizedName
        let pressedSelection = selectionAtPress
        let focus = focusAtPress
        let detect = detectCommands
        Task { [weak self] in
            guard let self else { return }
            let ready = await transcriber.isReady
            hud.show(ready ? .transcribing : .working(modelStatus))
            let started = Date()
            do {
                let raw = try await transcriber.transcribe(samples)
                let text = TextCleanup.basic(raw)
                let seconds = Double(samples.count) / 16_000
                log(String(format: "dictation: %.1f s of audio → %ld characters in %.2f s",
                           seconds, text.count, Date().timeIntervalSince(started)))
                if let detail = await transcriber.lastDetail { log("dictation: whisper \(detail)") }
                if keepRecordings {
                    keep(samples, text: text, model: transcriber.model, took: Date().timeIntervalSince(started))
                }
                phase = .idle
                guard !text.isEmpty else {
                    if silent {
                        log("dictation: no sound from \(micName ?? "the microphone")")
                        hud.flash("No sound from \(micName ?? "the microphone") · choose another in Settings",
                                  seconds: 4, tone: .problem)
                    } else {
                        hud.flash("Didn't catch that")
                    }
                    return
                }
                var selection = pressedSelection
                // "Summarise this" with text selected in an app that doesn't report its selection: copy it.
                if selection == nil, !typingOnly, detect || forcedCommand, CommandAgent.isAboutSelection(text) {
                    selection = await TextInserter.copySelection()
                    if let selection { log("selection: \(selection.count) characters, copied with ⌘C") }
                }
                let decision = typingOnly
                    ? IntentClassifier.Decision(intent: .dictation, reason: "typing key held")
                    : detect
                    ? await IntentClassifier.decide(text, forcedCommand: forcedCommand,
                                                    focus: focus, frontApp: frontApp,
                                                    hasSelection: selection != nil, router: agent.currentRouter())
                    : IntentClassifier.Decision(intent: forcedCommand ? .command : .dictation,
                                                reason: forcedCommand ? "command key held" : "detection off")
                log("intent: \(decision.intent.rawValue) (\(decision.reason))")
                if decision.intent == .dictation,
                   text.range(of: #"(?i)\b(whatsapp|message|msg|bhej|send|text|slack|mail)\b"#, options: .regularExpression) != nil {
                    log("intent: typed, though it mentions a message: \"\(text.prefix(80))\"")
                }
                if RouterDiagnostics.isKeyProblem(decision.reason), !warnedAboutKey {
                    // Say it once per launch; the words are still typed below.
                    warnedAboutKey = true
                    let provider = RouterChoice.current == .openai ? "OpenAI" : "Anthropic"
                    hud.flash("\(provider) rejected the API key. Change it in Commands & Assistants.", seconds: 4)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
                if decision.intent == .command {
                    log("command: \"\(text)\"")
                    DictationHistory.shared.add(text, app: frontApp, kind: .command)
                    hud.show(.working("“\(text.prefix(60))”"))
                    lastCommand = text
                    await agent.run(text, frontApp: frontApp, selection: selection, explicit: decision.explicit,
                                    editable: focus == .textField)
                    if hud.isWorking { hud.hide() }
                    return
                }
                lastHeard = text
                lastCleaned = false
                var words = text
                if aiCleanup, DictationCleanup.worthCleaning(text) {
                    hud.show(.working("Tidying up"))
                    if let cleaned = await cleanUp(text) {
                        words = cleaned
                        lastCleaned = cleaned != text
                    }
                }
                lastText = words
                DictationHistory.shared.add(words, app: frontApp, kind: .dictation)
                if focus == .notText {
                    // Pasting into Finder or the desktop makes a text clipping file: copy it instead.
                    TextInserter.copy(words)
                    log("dictation: nowhere to type, copied instead")
                    hud.flash("Nowhere to type here · copied to clipboard", seconds: 3)
                    return
                }
                hud.hide()
                // Spacing, the first letter and the final full stop fitted to the sentence it goes into.
                let typed = fitText ? CursorContext.fit(words) : words
                if typed != words { log("dictation: fitted to the sentence around the cursor") }
                lastText = typed
                report(TextInserter.insert(typed))
            } catch {
                phase = .idle
                log("dictation: transcription failed: \(error.localizedDescription)")
                hud.flash("Transcription failed")
            }
        }
    }

    /// AI cleanup with the commands' model. Nil — the words are typed as heard — when the model is slow (over 4 s),
    /// fails, or replies with anything but a tidied version of what was said.
    private func cleanUp(_ text: String) async -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        let category = DictationCleanup.category(bundleID: app?.bundleIdentifier, windowTitle: Self.frontWindowTitle())
        let style = cleanupStyle(for: category)
        let router = agent.currentRouter()
        let system = DictationCleanup.system(style: style, category: category)
        let user = DictationCleanup.user(text)
        let started = Date()
        let reply: String? = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let work = Task {
                let answer = try? await router.chat(system: system, turns: [.user(user)], tools: []).text
                once.run { continuation.resume(returning: answer) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                once.run { continuation.resume(returning: nil) }
                work.cancel()
            }
        }
        let took = Date().timeIntervalSince(started)
        let what = "\(router.name), \(category.rawValue), \(style.rawValue)"
        guard let reply else {
            log(String(format: "dictation: AI cleanup (%@) gave nothing in %.1f s: typed as heard", what, took))
            return nil
        }
        guard let cleaned = DictationCleanup.accept(original: text, cleaned: reply) else {
            log(String(format: "dictation: AI cleanup (%@) changed more than tidying in %.1f s: typed as heard", what, took))
            return nil
        }
        log(String(format: "dictation: AI cleanup (%@) in %.1f s%@", what, took, cleaned == text ? ", nothing to change" : ""))
        return cleaned
    }

    /// The front window's title ("Inbox – Gmail", "WhatsApp"), for telling web apps apart in a browser.
    static func frontWindowTitle() -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    private func report(_ outcome: TextInserter.Outcome) {
        switch outcome {
        case .inserted:
            break
        case .secureInput:
            hud.flash("Can't type into a password field · use Paste Last Dictation")
        case .needsAccessibility:
            // Keep the words: they go on the clipboard, so ⌘V still works. Settings opens once per launch, not on
            // every dictation.
            if let lastText { TextInserter.copy(lastText) }
            hud.flash("Copied · press ⌘V. Allow Murmur in Accessibility to paste automatically", seconds: 4)
            if !openedAccessibilitySettings {
                openedAccessibilitySettings = true
                Self.openPrivacyPane("Privacy_Accessibility")
            }
        }
    }

    // MARK: - Setup

    private var lastDownloadLog = Date.distantPast

    private func prepareModel() async {
        let model = transcriber.model
        modelStatus = "Speech model: getting ready…"
        speechModelState = .preparing(0)
        modelInPill = false
        log("dictation: preparing \(model.engine) (\(model.rawValue))")
        let started = Date()
        do {
            try await transcriber.prepare { [weak self] fraction, downloading in
                DispatchQueue.main.async {
                    guard let self, self.transcriber.model == model else { return }
                    let percent = Int((fraction * 100).rounded())
                    if downloading {
                        if Date().timeIntervalSince(self.lastDownloadLog) >= 10 {
                            self.lastDownloadLog = Date()
                            self.log(String(format: "dictation: downloading %@ · %d%% after %.0f s", model.short, percent,
                                            Date().timeIntervalSince(started)))
                        }
                        self.speechModelState = .downloading(fraction)
                        self.modelStatus = "Downloading the speech model · \(percent)%"
                        // A download takes a while: show it in the pill too, wherever you are.
                        self.modelInPill = true
                        self.showModelProgress("Downloading \(model.short) · \(percent)%")
                    } else {
                        self.speechModelState = .preparing(fraction)
                        self.modelStatus = "Preparing the speech model · \(percent)%"
                        if self.modelInPill {
                            if fraction > 0 && fraction < 1 {
                                self.showModelProgress("Preparing \(model.short) · \(percent)%")
                            } else {
                                self.startPreparingClock(for: model)
                            }
                        }
                    }
                }
            }
            stopPreparingClock()
            guard transcriber.model == model else { return }
            modelStatus = "Speech model ready (\(model.short), on device)"
            speechModelState = .ready
            log(String(format: "dictation: %@ ready in %.1f s", model.engine, Date().timeIntervalSince(started)))
            if modelInPill, phase == .idle { hud.flash("\(model.short) is ready", tone: .done) }
        } catch {
            stopPreparingClock()
            guard transcriber.model == model else { return }
            modelStatus = "Speech model failed to load"
            speechModelState = .failed(error.localizedDescription)
            log("dictation: \(model.engine) failed: \(error.localizedDescription)")
            if modelInPill, phase == .idle { hud.flash("Couldn't get \(model.short) ready", seconds: 4, tone: .problem) }
        }
        modelInPill = false
    }

    /// Whether the pill is showing the speech model's download (only for downloads, not the usual quick load).
    private var modelInPill = false
    private var preparingClock: Timer?

    /// Loading a model has no progress to report, so the pill counts the time instead: you can see it's working.
    private func startPreparingClock(for model: SpeechModel) {
        guard preparingClock == nil else { return }
        let started = Date()
        let tick = { [weak self] in
            guard let self, self.modelInPill, self.transcriber.model == model else { return }
            let seconds = Int(Date().timeIntervalSince(started))
            self.showModelProgress(String(format: "Preparing %@ for this Mac · %d:%02d", model.short, seconds / 60, seconds % 60))
        }
        tick()
        preparingClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    private func stopPreparingClock() {
        preparingClock?.invalidate()
        preparingClock = nil
    }

    /// The model's progress in the pill, unless you're talking (then the pill is yours).
    private func showModelProgress(_ text: String) {
        switch phase {
        case .idle, .transcribing: hud.show(.working(text))
        case .listening: break
        }
    }

    /// Starts the key monitor. Without Accessibility permission macOS refuses it, so this retries every 2 s
    /// until you grant it in System Settings (once, with macOS's prompt, if `prompt`).
    private func startMonitor(prompt: Bool) {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if monitor.start() {
            log("dictation: watching \(monitor.key.display)")
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        log("dictation: waiting for Accessibility permission")
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.retryMonitor() }
        }
    }

    private func retryMonitor() {
        guard monitor.start() else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        log("dictation: Accessibility granted, watching \(monitor.key.display)")
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension DictationController {
    private func makeHost() -> CommandHost {
        var host = CommandHost(
            confirm: { [weak self] title, detail in self?.confirm(title, detail) ?? false },
            showAnswer: { [weak self] text in
                guard let self else { return }
                hud.hide()
                answerPanel.onPaste = { [weak self] text in self?.pasteIntoPreviousApp(text) }
                answerPanel.show(text, asked: lastCommand, trace: agent.trace)
            },
            insert: { [weak self] text in self?.pasteIntoPreviousApp(text) },
            searchFiles: { [weak self] query in
                self?.hud.hide()
                self?.onSearchFiles?(query)
            },
            progress: { [weak self] text in
                guard let self else { return }
                // "Thinking…", "Working… (step 3)": still going, so a spinner. Anything else is a step's outcome.
                if text.contains("…") {
                    hud.show(.working(text))
                } else {
                    let tone = DictationHUD.tone(of: text)
                    hud.flash(text, seconds: 2, tone: tone == .problem ? .problem : .done)
                }
            },
            log: { [weak self] line in self?.log(line) },
            pasteHere: { [weak self] text in
                guard let self else { return }
                lastText = text
                hud.hide()
                report(TextInserter.insert(text))
            },
            openFile: { [weak self] query in
                guard let open = self?.onOpenFile else { return "File search isn't ready." }
                return await open(query)
            },
            replaceSelection: { [weak self] text in
                guard let self else { return false }
                return await replaceSelection(with: text)
            }
        )
        host.openModelSettings = { [weak self] in self?.onOpenModelSettings?() }
        host.approve = { [weak self] kind, title, detail in self?.approve(kind, title, detail) ?? .no }
        host.findFiles = { [weak self] query in await self?.onFindFiles?(query) ?? [] }
        return host
    }

    /// Asks for an API key, checks its shape, saves it in the Keychain, then tests it with the provider and says
    /// whether it works. An empty field removes the key. Returns true when a key is set.
    @discardableResult
    public func askForKey(_ choice: RouterChoice) -> Bool {
        guard let account = choice.keyAccount else { return true }
        let provider = choice == .anthropic ? "Anthropic" : "OpenAI"
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "\(provider) API key"
            alert.informativeText = (problem.map { "\($0)\n\n" } ?? "")
                + "Used only for commands (your words, the front app's name and any selected text). Speech never "
                + "leaves your Mac. Stored in your Keychain. Leave empty to remove the key."
            if problem != nil { alert.alertStyle = .warning }
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
            field.placeholderString = choice == .anthropic ? "sk-ant-…" : "sk-proj-…"
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            Self.bringToFront(alert)
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return choice.hasKey }
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                Keychain.set(account, "")
                log("command: \(provider) key removed")
                if RouterChoice.current == choice { RouterChoice.current = .local }
                return false
            }
            if let shape = KeyCheck.shapeProblem(choice, key) {
                problem = shape          // ask again, saying what looks wrong
                continue
            }
            Keychain.set(account, key)
            RouterDiagnostics.lastError = nil   // a new key gets a fresh chance
            log("command: \(provider) key saved, checking it")
            hud.show(.working("Checking the \(provider) key…"))
            Task { [weak self] in
                let result = await KeyCheck.verify(choice)
                guard let self else { return }
                if choice == .anthropic, let result, result.contains("workspace") && result.contains("ID") {
                    self.log("command: Anthropic key check: needs a workspace ID")
                    self.hud.hide()
                    self.askForWorkspaceID(reason: result)
                    return
                }
                if let result {
                    self.log("command: \(provider) key check: \(result)")
                    self.hud.hide()
                    let warning = NSAlert()
                    warning.alertStyle = .warning
                    warning.messageText = "That \(provider) key didn't work"
                    warning.informativeText = result
                    warning.addButton(withTitle: "Enter It Again")
                    warning.addButton(withTitle: "Later")
                    Self.bringToFront(warning)
                    if warning.runModal() == .alertFirstButtonReturn { self.askForKey(choice) }
                } else {
                    self.log("command: \(provider) key works")
                    self.hud.flash("\(provider) key works", seconds: 2, tone: .done)
                }
            }
            return true
        }
    }

    /// Checks a saved key with a real (one-token) request to the model commands use, and says how it went.
    public func testKey(_ choice: RouterChoice) {
        let provider = choice == .anthropic ? "Anthropic" : "OpenAI"
        hud.show(.working("Checking the \(provider) key…"))
        Task { [weak self] in
            let result = await KeyCheck.verify(choice)
            guard let self else { return }
            self.hud.hide()
            if let result {
                self.log("command: \(provider) key check: \(result)")
                let warning = NSAlert()
                warning.alertStyle = .warning
                warning.messageText = "\(provider) can't run commands with this key"
                warning.informativeText = result
                warning.addButton(withTitle: "OK")
                Self.bringToFront(warning)
                warning.runModal()
            } else {
                self.log("command: \(provider) key works")
                self.hud.flash("\(provider) key works with \(choice == .anthropic ? AnthropicRouter.model : OpenAIRouter.model)", seconds: 2.5, tone: .done)
            }
        }
    }

    /// Asks for the Anthropic workspace an organization-wide key should use, then checks the key again.
    public func askForWorkspaceID(reason: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "Anthropic workspace ID"
        alert.informativeText = (reason.map { "\($0)\n\n" } ?? "")
            + "Paste the workspace ID (it starts with “wrkspc_”). Leave empty if your key is made inside a workspace."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "wrkspc_…"
        field.stringValue = AnthropicWorkspace.id ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        Self.bringToFront(alert)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AnthropicWorkspace.id = field.stringValue
        RouterDiagnostics.lastError = nil
        log("command: Anthropic workspace ID \(AnthropicWorkspace.id == nil ? "removed" : "saved"), checking the key")
        hud.show(.working("Checking the Anthropic key…"))
        Task { [weak self] in
            let result = await KeyCheck.verify(.anthropic)
            guard let self else { return }
            if let result {
                self.log("command: Anthropic key check: \(result)")
                self.hud.hide()
                let warning = NSAlert()
                warning.alertStyle = .warning
                warning.messageText = "Anthropic still says no"
                warning.informativeText = result
                warning.addButton(withTitle: "OK")
                Self.bringToFront(warning)
                warning.runModal()
            } else {
                self.log("command: Anthropic key works")
                self.hud.flash("Anthropic key works", seconds: 2, tone: .done)
            }
        }
    }

    /// A Murmur dialog for actions that change something. It floats above every window.
    private func confirm(_ title: String, _ detail: String) -> Bool {
        hud.hide()
        let action = title.hasPrefix("Build") ? "Start Building" : title.hasPrefix("Quit") ? "Quit"
            : title.hasPrefix("Click") ? "Click" : "Go Ahead"
        let answer = ConfirmPanel.run(title: title, detail: detail, confirm: action,
                                      symbol: ConfirmPanel.symbol(for: title))
        log("command: \(title) → \(answer ? "yes" : "no")")
        return answer
    }

    /// "Go ahead?" with the choice to allow it for the rest of the task, or always for this kind of action.
    private func approve(_ kind: Permission?, _ title: String, _ detail: String) -> Approval {
        hud.hide()
        let action = title.hasPrefix("Build") ? "Start Building" : title.hasPrefix("Quit") ? "Quit"
            : title.hasPrefix("Click") ? "Click" : title.hasPrefix("Send") ? "Send" : "Go Ahead"
        let answer = ConfirmPanel.ask(kind: kind, title: title, detail: detail, confirm: action,
                                      symbol: ConfirmPanel.symbol(for: title))
        log("command: \(title) → \(answer)")
        return answer
    }

    /// Murmur lives in the menu bar, and macOS may ignore a background app asking to come forward: float the dialog
    /// above every window and take the keyboard for it.
    static func bringToFront(_ alert: NSAlert) {
        alert.window.level = .floating
        alert.window.collectionBehavior.remove(.moveToActiveSpace)   // can't be combined with .canJoinAllSpaces
        alert.window.collectionBehavior.insert(.canJoinAllSpaces)
        alert.window.collectionBehavior.insert(.fullScreenAuxiliary)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        alert.window.center()
        alert.window.orderFrontRegardless()
        alert.window.makeKey()
    }

    /// Brings back the app you were in, then pastes there.
    /// Pastes `text` over the selection in the app you were in, then checks it took: pasting replaces a selection,
    /// so if the same text is still selected afterwards, the selection was in text that can't be edited (a web
    /// page, a received email, a PDF) and nothing changed. Returns false then, so the caller shows the result.
    func replaceSelection(with text: String) async -> Bool {
        let before = Self.selectedText()
        pasteIntoPreviousApp(text)
        try? await Task.sleep(nanoseconds: 700_000_000)   // the app comes forward (0.25 s), then reads the paste
        guard let before else { return true }              // can't tell: the paste is all there is to go on
        let after = Self.selectedText()
        return after != before
    }

    private func pasteIntoPreviousApp(_ text: String) {
        lastText = text
        hud.hide()
        if let previousApp, previousApp != NSRunningApplication.current, !previousApp.isActive {
            previousApp.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.report(TextInserter.insert(text))
            }
        } else {
            report(TextInserter.insert(text))
        }
    }

    /// What has the keyboard focus. Chrome and Electron apps often don't report their text fields, which comes back
    /// as `.unknown`, never as `.notText`.
    static func focus() -> IntentClassifier.Focus {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            // No answer. Finder with nothing selected and the desktop are places you can't type.
            let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            return id == "com.apple.finder" ? .notText : .unknown
        }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let role_ = role as? String ?? ""
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if textRoles.contains(role_) { return .textField }
        // Finder (the desktop, a folder window): there's nowhere to type unless it's a rename field.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" { return .notText }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { return .textField }
        // Text you can select isn't always text you can edit: a web page, a received email or a PDF reports a
        // selection too. Web content says when it's editable (`AXEditableAncestor`, set inside a text field or a
        // contenteditable editor); elsewhere a field you can edit has a settable value (above).
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success {
            var editable: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editable) == .success,
               editable != nil {
                return .textField
            }
            return .unknown
        }
        // Web pages and app-drawn views can hold a text field Accessibility doesn't show.
        let unclear: Set<String> = ["AXWebArea", "AXGroup", "AXScrollArea", "AXUnknown", ""]
        return unclear.contains(role_) ? .unknown : .notText
    }

    /// The text selected in the focused app, through Accessibility (for "make this shorter", "reply to this").
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        let element = focused as! AXUIElement
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

/// Tidying that needs no model: Parakeet already writes punctuation and capitals.
/// Milestone 2 replaces this with the local LLM pass.
enum TextCleanup {
    static func basic(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Resumes a continuation once, whichever comes first: the model's answer or the time running out.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
