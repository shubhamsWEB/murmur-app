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
    private var transcriber: ParakeetTranscriber
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
    /// The app you were in when you pressed the key (commands paste back into it).
    private var previousApp: NSRunningApplication?
    /// At the key press: whether a text field had the focus, and what was selected.
    private var focusAtPress = IntentClassifier.Focus.unknown
    private var selectionAtPress: String?

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

    /// A press shorter than this is a tap, not a hold (taps start hands-free dictation).
    private let tapLength: TimeInterval = 0.3
    /// Two taps within this time make a double-tap.
    private let doubleTapWindow: TimeInterval = 0.4
    /// Shorter recordings are treated as accidental and dropped.
    private let minimumSamples = 16_000 / 4

    private static let keyDefault = "dictationKey"
    private static let modelDefault = "speechModel"
    private static let whisperDefault = "whisperMode"

    /// Whisper Mode: boost quiet speech up to 32 dB instead of 20 dB, for whispering or speaking softly.
    public var whisperMode: Bool {
        get { UserDefaults.standard.bool(forKey: Self.whisperDefault) }
        set { UserDefaults.standard.set(newValue, forKey: Self.whisperDefault) }
    }

    public init() {
        let model = UserDefaults.standard.string(forKey: Self.modelDefault).flatMap(ParakeetTranscriber.Model.init)
        transcriber = ParakeetTranscriber(model: model ?? .english)
        let saved = UserDefaults.standard.string(forKey: Self.keyDefault).flatMap(DictationKeyMonitor.Key.init)
        monitor = DictationKeyMonitor(key: saved ?? .fn)
        monitor.onDown = { [weak self] in self?.keyDown() }
        monitor.onUp = { [weak self] in self?.keyUp() }
        monitor.onOtherKey = { [weak self] code in self?.otherKey(code) }
        monitor.onModifiers = { [weak self] flags in self?.modifiersChanged(flags) }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.setLevel(level) }
        }
    }

    public var key: DictationKeyMonitor.Key { monitor.key }
    /// The speech model in use.
    public var speechModel: ParakeetTranscriber.Model { transcriber.model }
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
        Task { await prepareModel() }
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
    }

    public func setModel(_ model: ParakeetTranscriber.Model) {
        guard model != transcriber.model else { return }
        UserDefaults.standard.set(model.rawValue, forKey: Self.modelDefault)
        transcriber = ParakeetTranscriber(model: model)
        log("dictation: speech model is now \(model.rawValue)")
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
        for model in ParakeetTranscriber.Model.allCases {
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
        let hint = NSMenuItem(title: "Fn+⌃ always runs a command", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        assistants.addItem(hint)
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
        items.append(ClosureMenuItem("Whisper Mode", checked: whisperMode) { [weak self] in
            guard let self else { return }
            whisperMode.toggle()
            log("dictation: whisper mode \(whisperMode ? "on" : "off")")
        })
        if let lastText {
            items.append(ClosureMenuItem("Paste Last Dictation") { [weak self] in self?.pasteLast() })
            items.append(ClosureMenuItem("Copy Last Dictation") { TextInserter.copy(lastText) })
        }
        if let logFile {
            items.append(ClosureMenuItem("Open Log") { NSWorkspace.shared.open(logFile) })
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
            let doubleTap = Date().timeIntervalSince(lastTapAt) < doubleTapWindow
            pressedAt = Date()
            commandRequested = NSEvent.modifierFlags.contains(.control)
            previousApp = NSWorkspace.shared.frontmostApplication
            focusAtPress = Self.focus()
            selectionAtPress = Self.selectedText()
            begin(handsFree: doubleTap)
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

    /// ⌃ pressed while the dictation key is held turns this recording into a command.
    private func modifiersChanged(_ flags: CGEventFlags) {
        guard case .listening = phase, flags.contains(.maskControl), !commandRequested else { return }
        commandRequested = true
        hud.show(.command)
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
        do {
            try recorder.start()
            phase = .listening(handsFree: handsFree)
            hud.show(commandRequested ? .command : .listening(handsFree: handsFree))
        } catch {
            log("dictation: can't start the microphone: \(error.localizedDescription)")
            hud.flash("Can't start the microphone")
        }
    }

    private func cancel() {
        recorder.cancel()
        phase = .idle
        hud.hide()
    }

    private func finish() {
        let recorded = recorder.stop()
        guard recorded.count >= minimumSamples else {
            phase = .idle
            hud.hide()
            return
        }
        phase = .transcribing
        let leveled = AudioLevel.normalize(recorded, maxGainDB: whisperMode ? 32 : 20)
        log(String(format: "dictation: speech %.0f dBFS, noise %.0f dBFS, gain +%.0f dB%@",
                   leveled.speechDB, leveled.noiseDB, leveled.gainDB, whisperMode ? " (whisper mode)" : ""))
        let samples = leveled.samples
        lastSamples = samples
        let transcriber = transcriber
        let forcedCommand = commandRequested
        let frontApp = previousApp?.localizedName
        let selection = selectionAtPress
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
                phase = .idle
                guard !text.isEmpty else {
                    hud.flash("Didn't catch that")
                    return
                }
                let decision = detect
                    ? await IntentClassifier.decide(text, forcedCommand: forcedCommand,
                                                    focus: focus, frontApp: frontApp,
                                                    hasSelection: selection != nil, router: agent.currentRouter())
                    : IntentClassifier.Decision(intent: forcedCommand ? .command : .dictation,
                                                reason: forcedCommand ? "⌃ held" : "detection off")
                log("intent: \(decision.intent.rawValue) (\(decision.reason))")
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
                    await agent.run(text, frontApp: frontApp, selection: selection, explicit: decision.explicit)
                    if hud.isWorking { hud.hide() }
                    return
                }
                lastText = text
                hud.hide()
                DictationHistory.shared.add(text, app: frontApp, kind: .dictation)
                report(TextInserter.insert(text))
            } catch {
                phase = .idle
                log("dictation: transcription failed: \(error.localizedDescription)")
                hud.flash("Transcription failed")
            }
        }
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

    private func prepareModel() async {
        modelStatus = "Speech model: getting ready…"
        speechModelState = .preparing(0)
        log("dictation: preparing Parakeet (\(transcriber.model.rawValue))")
        let started = Date()
        do {
            try await transcriber.prepare { [weak self] fraction, downloading in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let percent = Int((fraction * 100).rounded())
                    if downloading {
                        speechModelState = .downloading(fraction)
                        modelStatus = "Downloading the speech model · \(percent)%"
                    } else {
                        speechModelState = .preparing(fraction)
                        modelStatus = "Preparing the speech model · \(percent)%"
                    }
                }
            }
            modelStatus = "Speech model ready (\(transcriber.model == .english ? "English" : "multilingual"), on device)"
            speechModelState = .ready
            log(String(format: "dictation: Parakeet ready in %.1f s", Date().timeIntervalSince(started)))
        } catch {
            modelStatus = "Speech model failed to load"
            speechModelState = .failed(error.localizedDescription)
            log("dictation: Parakeet failed: \(error.localizedDescription)")
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
        CommandHost(
            confirm: { [weak self] title, detail in self?.confirm(title, detail) ?? false },
            showAnswer: { [weak self] text in
                guard let self else { return }
                hud.hide()
                answerPanel.onPaste = { [weak self] text in self?.pasteIntoPreviousApp(text) }
                answerPanel.show(text)
            },
            insert: { [weak self] text in self?.pasteIntoPreviousApp(text) },
            searchFiles: { [weak self] query in
                self?.hud.hide()
                self?.onSearchFiles?(query)
            },
            progress: { [weak self] text in
                guard let self else { return }
                if text.hasSuffix("…") { hud.show(.working(text)) } else { hud.flash(text, seconds: 2) }
            },
            log: { [weak self] line in self?.log(line) }
        )
    }

    /// Asks for an API key and saves it in the Keychain. An empty field removes the key. Returns true when a key is set.
    @discardableResult
    public func askForKey(_ choice: RouterChoice) -> Bool {
        guard let account = choice.keyAccount else { return true }
        let provider = choice == .anthropic ? "Anthropic" : "OpenAI"
        let alert = NSAlert()
        alert.messageText = "\(provider) API key"
        alert.informativeText = "Used only for commands (the words you said, the front app's name and any selected "
            + "text). Speech never leaves your Mac. Stored in your Keychain. Leave empty to remove the key."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = choice == .anthropic ? "sk-ant-…" : "sk-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        Self.bringToFront(alert)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return choice.hasKey }
        Keychain.set(account, field.stringValue)
        log("command: \(provider) key \(field.stringValue.isEmpty ? "removed" : "saved")")
        if field.stringValue.isEmpty, RouterChoice.current == choice { RouterChoice.current = .local }
        return choice.hasKey
    }

    /// A Murmur dialog for actions that change something. Murmur comes to the front while it's open.
    private func confirm(_ title: String, _ detail: String) -> Bool {
        hud.hide()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Go Ahead")
        alert.addButton(withTitle: "Cancel")
        Self.bringToFront(alert)
        let answer = alert.runModal() == .alertFirstButtonReturn
        log("command: \(title) → \(answer ? "yes" : "no")")
        return answer
    }

    /// Murmur lives in the menu bar, and macOS may ignore a background app asking to come forward: float the dialog
    /// above every window and take the keyboard for it.
    static func bringToFront(_ alert: NSAlert) {
        alert.window.level = .floating
        alert.window.collectionBehavior.insert(.canJoinAllSpaces)
        alert.window.collectionBehavior.insert(.fullScreenAuxiliary)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        alert.window.center()
        alert.window.orderFrontRegardless()
        alert.window.makeKey()
    }

    /// Brings back the app you were in, then pastes there.
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
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { return .textField }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success {
            return .textField
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
