import AppKit
import ApplicationServices
import AgentKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import FluidAudio

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
    /// Watching what becomes of the last text written into a box (`watchWritten`).
    private var writtenWatch: Task<Void, Never>?

    private let recorder = MicRecorder()
    private var transcriber: SpeechTranscriber
    private var lastSamples: [Float] = []
    private let hud = DictationHUD()
    private let monitor: DictationKeyMonitor
    private var pressedAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var retryTimer: Timer?
    private var openedAccessibilitySettings = false
    /// The app last logged as holding Secure Input while Murmur typed anyway (so it's said once, not every time).
    private var secureHolderLogged: String?
    private var warnedAboutKey = false
    /// ⌃ was held with the dictation key: the speech is a command, not text to type.
    private var commandRequested = false
    /// ⇧ held with the talk key: dictation only, never a command (the opposite of ⌃).
    private var typingRequested = false
    /// The app you were in when you pressed the key (commands paste back into it).
    private var previousApp: NSRunningApplication?
    /// At the key press: whether a text field had the focus, and what was selected.
    private var focusAtPress = IntentClassifier.Focus.unknown
    /// The front window's title when the key went down (another AI's page in a browser: what you say is typed).
    private var titleAtPress: String?
    /// The words to listen for in this dictation (DictationVocabulary), from the window it started in.
    private var vocabularyAtPress: [String] = []
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
    private var meetingRunning: AnyCancellable?

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
    /// The microphone is on: what a command will need can start loading while the user speaks.
    public var onListening: (() -> Void)?
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
    private static let clearVoiceDefault = "dictation.clearVoice"
    /// Set once Clear voice's default changed to off (it was on): a Mac that had it on only by default goes off.
    private static let clearVoiceOffByDefault = "dictation.clearVoiceOffByDefault"
    private static let micReadyDefault = "dictation.micReady"
    private static let autoLevelDefault = "dictation.autoLevel"
    private static let wordsDefault = "dictation.words"
    private static let screenWordsDefault = "dictation.screenWords.v2"
    /// Developer switch (no setting): each dictation is also transcribed the old way (no half second before the key,
    /// no silence after, no vocabulary) and both are logged, to compare. Logs what you said.
    private static let compareDefault = "dictation.compare"
    private static let lowLevelWarnedDefault = "dictation.lowLevelWarned"
    private static let showLogoDefault = "dictation.showLogo"
    private static let aiCleanupDefault = "dictation.aiCleanup"
    private static let grammarFixDefault = "dictation.grammarFix"
    private static let writeOnTapDefault = "dictation.writeOnTap"

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

    /// Clear voice: macOS's voice processing on the microphone (as FaceTime uses): background noise and echo out,
    /// your level evened out, before Murmur hears it. Off unless turned on: it's made for people listening on a call,
    /// and what it does to a voice costs a speech model more than a quiet room's noise does (it also cut pauses to
    /// digital silence, a whole command once came back empty, a soft voice was cut to nothing, and it takes a second
    /// to start). For a noisy room or speakers playing.
    public var clearVoice: Bool {
        get { UserDefaults.standard.object(forKey: Self.clearVoiceDefault) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.clearVoiceDefault)
            recorder.clearVoice = newValue
            log("dictation: clear voice \(newValue ? "on" : "off")")
            objectWillChange.send()
        }
    }

    /// The microphone stays ready for a minute after a dictation, so the next one starts at once and with the half
    /// second before the key (the first word, often begun as the key goes down, arrives whole). On unless turned
    /// off; macOS shows the microphone in use for that minute.
    public var micStaysReady: Bool {
        get { UserDefaults.standard.object(forKey: Self.micReadyDefault) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.micReadyDefault)
            recorder.readySeconds = newValue ? 60 : 0
            log("dictation: microphone stays ready \(newValue ? "for a minute" : "off")")
            objectWillChange.send()
        }
    }

    /// Words the speech model should get right (names, products, jargon), as typed in Settings, separated by commas.
    public var dictationWords: String {
        get { UserDefaults.standard.string(forKey: Self.wordsDefault) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.wordsDefault)
            objectWillChange.send()
            prepareVocabularyIfWanted()
        }
    }

    /// Also listen for the distinctive words in the window's title (a page, a project, a person). On unless turned
    /// off: only a word Parakeet was unsure of can be swapped for one (DictationVocabulary).
    public var listensForScreenWords: Bool {
        get { UserDefaults.standard.object(forKey: Self.screenWordsDefault) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.screenWordsDefault)
            objectWillChange.send()
            prepareVocabularyIfWanted()
        }
    }

    /// Whether vocabulary is in use (your words, or the window's), and the model can take it.
    private var wantsVocabulary: Bool {
        transcriber.takesVocabulary
            && ((listensForScreenWords && transcriber.model != .sarvam)
                || !DictationVocabulary.userWords(from: dictationWords).isEmpty)
    }

    /// The word spotter, downloaded (once, about 106 MB) and loaded in the background when vocabulary is wanted.
    private func prepareVocabularyIfWanted() {
        guard wantsVocabulary, transcriber.model != .sarvam else { return }
        let transcriber = transcriber
        let downloaded = ParakeetTranscriber.vocabularyModelIsDownloaded
        Task { [weak self] in
            let started = Date()
            do {
                try await transcriber.prepareVocabulary()
                self?.log(String(format: "dictation: word spotter ready in %.1f s%@", Date().timeIntervalSince(started),
                                 downloaded ? "" : " (downloaded)"))
            } catch {
                self?.log("dictation: word spotter couldn't load: \(error.localizedDescription)")
            }
        }
    }

    /// The words for a dictation starting now, in the front window.
    private func vocabularyNow() -> [String] {
        guard wantsVocabulary else { return [] }
        // Sarvam gets only the words you listed. Given the window's words too, it wrote them over what you said, with
        // nothing to check it: "Murmur ki website" said into Claude came back "Claude ki website" (23 Nov). Parakeet
        // may still listen for them: there a word is swapped only when Parakeet wasn't sure of it.
        let screen = listensForScreenWords && transcriber.model != .sarvam
        let title = screen ? Self.frontWindowTitle() : nil
        let app = screen ? NSWorkspace.shared.frontmostApplication?.localizedName : nil
        return DictationVocabulary.terms(windowTitle: title, appName: app,
                                         userWords: DictationVocabulary.userWords(from: dictationWords))
    }

    /// Murmur sets the microphone's input level itself (MicLevel): a level turned down is raised when you dictate, and
    /// it moves a step after each dictation toward your voice arriving clearly. On unless turned off. With Clear voice,
    /// judged by the microphone's own sound (recorded beside it), since voice processing evens out what it lets
    /// through but can't bring back a voice the microphone barely heard.
    public var adjustsMicLevel: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoLevelDefault) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoLevelDefault)
            log("dictation: microphone level \(newValue ? "set by Murmur" : "left as it is")")
            objectWillChange.send()
        }
    }

    /// Sets a microphone's level and says so in the log.
    private func setMicLevel(_ device: AudioDevices.Input, from volume: Float, to level: Float, why: String) -> Bool {
        guard AudioDevices.setInputVolume(device.id, level) else {
            log(String(format: "dictation: couldn't set %@'s input level (it's %.0f%%)", device.name, volume * 100))
            return false
        }
        log(String(format: "dictation: %@'s input level %.0f%% → %.0f%% (%@)", device.name, volume * 100, level * 100, why))
        return true
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

    /// Murmur's windows left out of screen sharing and recordings (on by default): PrivateWindows.
    public var hidesFromScreenSharing: Bool {
        get { PrivateWindows.isOn }
        set {
            PrivateWindows.isOn = newValue
            log("privacy: Murmur's windows \(newValue ? "hidden from" : "shown in") screen sharing")
            objectWillChange.send()
        }
    }

    /// Meeting notes (MeetingMode): listens to the call and your microphone, keeps notes, drafts answers.
    public private(set) lazy var meeting = MeetingMode(
        log: { [weak self] in self?.log($0) },
        transcriber: { [weak self] in self?.transcriber },
        router: { [weak self] in
            guard let self else { return nil }
            guard let choice = MeetingMode.aiChoice else { return agent.currentRouter() }
            return Routers.router(for: choice, localModel: agent.routerModel)
        },
        microphone: { [weak self] in self?.recorder.currentChoice() })

    /// The AI for meeting answers and notes (nil: the commands' AI).
    /// Who transcribes meetings: the dictation model, or Sarvam or OpenAI in the cloud.
    public var meetingSpeech: MeetingMode.Speech {
        get { MeetingMode.speechChoice }
        set {
            meeting.askForKey = { [weak self] in self?.askForKey($0) ?? false }
            meeting.setSpeech(newValue)
            objectWillChange.send()
        }
    }

    public var meetingAI: RouterChoice? {
        get { MeetingMode.aiChoice }
        set {
            meeting.askForKey = { [weak self] in self?.askForKey($0) ?? false }
            meeting.setAI(newValue)
            objectWillChange.send()
        }
    }

    /// Offer meeting notes when a meeting app turns on the microphone (on by default).
    public var offersMeetingNotes: Bool {
        get { meeting.offers }
        set {
            meeting.offers = newValue
            log("meeting: \(newValue ? "offering" : "not offering") notes when a meeting starts")
            objectWillChange.send()
        }
    }

    public var meetingNotesRunning: Bool { meeting.isOn }

    public func startMeetingNotes() { meeting.start() }

    /// AI cleanup (off by default): fillers and stumbles out, self-corrections applied, lists set out, in the style
    /// for the kind of app. Uses Murmur's cleanup model on this Mac (`CleanupModel`), or the commands' model; with
    /// Claude or OpenAI the dictated words go to that provider.
    public var aiCleanup: Bool {
        get { UserDefaults.standard.bool(forKey: Self.aiCleanupDefault) }
        set { UserDefaults.standard.set(newValue, forKey: Self.aiCleanupDefault); objectWillChange.send() }
    }

    /// Grammar fixing (off by default, on its own or with AI cleanup): grammar mistakes corrected ("he go" → "he goes")
    /// and nothing else, by the same model as cleanup. With both on, one reply does both.
    public var grammarFix: Bool {
        get { UserDefaults.standard.bool(forKey: Self.grammarFixDefault) }
        set { UserDefaults.standard.set(newValue, forKey: Self.grammarFixDefault); objectWillChange.send() }
    }

    /// One tap of the key in a text box writes what goes there (on by default): the reply to the conversation above,
    /// what the box asks for ("say yes but after 5"), or the draft finished. Nothing is sent; ⌘Z takes it back.
    public var writeOnTap: Bool {
        get { UserDefaults.standard.object(forKey: Self.writeOnTapDefault) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.writeOnTapDefault); objectWillChange.send() }
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

    /// Where AI cleanup's words go when Murmur's own cleanup model isn't used: the commands' model, on this Mac or a
    /// provider.
    public var cleanupModel: String { agent.currentRouter().name }

    /// The model that tidies dictation: Murmur's cleanup model when it's picked and on this Mac (checked once, then
    /// again after a failure, or each minute while it's missing), else the commands' model.
    private func cleanupRouter() async -> (router: Router, name: String) {
        let own = CleanupModel.shared
        await own.refreshIfStale()
        if own.inUse { return (OllamaRouter(model: CleanupModel.tag), CleanupModel.tag) }
        let router = agent.currentRouter()
        return (router, router.name)
    }

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

    /// Clear voice's sound under this (its speech level, after its own level control evened it out: normal speech
    /// came through at −12 to −16 dBFS) is a voice it took for noise, and the microphone's own sound is used instead.
    static let faintThroughClearVoiceDB: Float = -30
    /// A voice standing at least this far above the noise in the microphone's own sound is worth transcribing.
    static let voiceOverNoiseDB: Float = 6

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
        // Clear voice was on by default; it's off by default now. Once: a Mac where it was on goes off (it can be
        // turned back on in Settings).
        if !UserDefaults.standard.bool(forKey: Self.clearVoiceOffByDefault) {
            UserDefaults.standard.set(true, forKey: Self.clearVoiceOffByDefault)
            UserDefaults.standard.removeObject(forKey: Self.clearVoiceDefault)
        }
        recorder.clearVoice = UserDefaults.standard.object(forKey: Self.clearVoiceDefault) as? Bool ?? false
        recorder.readySeconds = (UserDefaults.standard.object(forKey: Self.micReadyDefault) as? Bool ?? true) ? 60 : 0
        PrivateWindows.watch()
        Task { @MainActor [weak self] in
            guard let self else { return }
            meeting.askForKey = { [weak self] in self?.askForKey($0) ?? false }
            meeting.watch()
            // The Murmur button shows when notes are being taken, and offers to stop them.
            meetingRunning = meeting.state.$running.receive(on: DispatchQueue.main).sink { [weak self] on in
                self?.logo.setMeeting(on)
            }
        }
        hud.onVisible = { [weak self] frame in self?.logo.pillMoved(frame) }
        // With the Murmur button on screen, the listening pill grows out of it (one pill, not two).
        hud.anchor = { [weak self] in self?.logo.anchor }
        logo.onOpen = { [weak self] in self?.onOpenApp?() }
        logo.onStartDictation = { [weak self] in self?.logoClicked() }
        logo.onMeetingNotes = { [weak self] in
            guard let self else { return }
            if meeting.isOn { meeting.stop() } else { meeting.start() }
        }
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
        watchTrust()
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
        // Sarvam transcribes with your Sarvam key: asked for first, and nothing changes without one.
        if model == .sarvam, !RouterChoice.sarvam.hasKey, !askForKey(.sarvam) { return }
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
        var items: [NSMenuItem] = meetingMenuItems()
        if commandTask != nil {
            items.append(ClosureMenuItem("Stop Command") { [weak self] in self?.stopCommand() })
        }
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

    /// Meeting notes: start them, or show and stop them while they run.
    private func meetingMenuItems() -> [NSMenuItem] {
        if meeting.isOn {
            return [ClosureMenuItem("Show Meeting Notes") { [weak self] in self?.meeting.showPanel() },
                    ClosureMenuItem("Stop Meeting Notes") { [weak self] in self?.meeting.stop() }]
        }
        return [ClosureMenuItem("Take Meeting Notes") { [weak self] in self?.startMeetingNotes() }]
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
        for model in LocalModels.choices {
            localMenu.addItem(ClosureMenuItem(LocalModels.display(model), checked: model == agent.routerModel) { [weak self] in
                self?.agent.routerModel = model
            })
        }
        let localItem = NSMenuItem(title: "Local Model", action: nil, keyEquivalent: "")
        localItem.submenu = localMenu
        assistants.addItem(localItem)
        assistants.addItem(.separator())
        for choice in [RouterChoice.anthropic, .openai, .sarvam] {
            let provider = choice.provider
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
        // A second tap: hands-free dictation, not writing. A press while Murmur writes: you've moved on.
        pendingWrite?.cancel()
        pendingWrite = nil
        if let writing = writeTask {
            log("write: the key was pressed; stopping")
            writing.cancel()
            writeTask = nil
        }
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
            titleAtPress = Self.frontWindowTitle()
            selectionAtPress = Self.selectedText()
            vocabularyAtPress = vocabularyNow()
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
            // The first tap of a double-tap, or a single tap: in a text box, a single one writes what goes there.
            let doubleTapped = Date().timeIntervalSince(lastTapAt) < doubleTapWindow * 2
            lastTapAt = Date()
            if writeOnTap, !commandRequested, !typingRequested, !doubleTapped {
                let wait = UInt64(doubleTapWindow * 1_000_000_000)
                pendingWrite = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: wait)
                    guard !Task.isCancelled else { return }
                    self?.writeHere()
                }
            }
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
            // Esc while a command runs stops it. (Keys Murmur presses itself never reach here.)
            if code == Int64(kVK_Escape), let writing = writeTask {
                log("write: Esc pressed; stopping")
                writing.cancel()
                writeTask = nil
                hud.hide()
            }
            if code == Int64(kVK_Escape), let running = commandTask {
                log("command: Esc pressed; stopping")
                agent.stop()
                running.cancel()
            }
        }
    }

    /// The command running now, so Esc or the next command can stop it.
    private var commandTask: Task<Void, Never>?

    /// Stops the running command (the menu's Stop Command).
    public func stopCommand() {
        guard let running = commandTask else { return }
        log("command: Stop Command chosen; stopping")
        agent.stop()
        running.cancel()
    }

    public var isRunningCommand: Bool { commandTask != nil }

    // MARK: - Checking dictation with recordings

    /// Debug runs: a recording (any audio file) through dictation as it would go after you let go of the key: the
    /// level, the speech model chosen, numbers in digits and AI cleanup as set, the safety checks; nothing typed.
    /// Returns what the speech model heard and what would be typed.
    public func dictateFile(_ url: URL) async -> (heard: String, typed: String, seconds: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0] else { return nil }
        let raw = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rate = file.processingFormat.sampleRate
        let samples = rate == 16_000 ? raw : ((try? AudioConverter().resample(raw, from: rate)) ?? [])
        guard !samples.isEmpty else { return nil }
        let leveled = AudioLevel.normalize(samples, maxGainDB: whisperMode ? 40 : 30)
        let heard = TextCleanup.basic((try? await transcriber.transcribe(leveled.samples, vocabulary: [])) ?? "")
        var text = heard
        if aiCleanup { text = SpokenNumbers.digits(text) }
        let tidy = aiCleanup && DictationCleanup.worthCleaning(text)
        let fix = grammarFix && DictationCleanup.worthFixing(text)
        if tidy || fix, let cleaned = await cleanUp(text, tidy: tidy, grammar: fix) { text = cleaned }
        return (heard, text, Double(samples.count) / 16_000)
    }

    // MARK: - Write it for me

    /// The single tap waiting to see whether a second one follows.
    private var pendingWrite: Task<Void, Never>?
    /// Writing now, so Esc or the next press can stop it.
    private var writeTask: Task<Void, Never>?
    /// Debug runs: what was read and written goes in the log too.
    private var writeEcho = false

    /// Debug runs: writes in the focused box now, as a tap would, and returns once it's in.
    public func writeNow(echo: Bool) async {
        writeEcho = echo
        writeHere()
        await writeTask?.value
        writeEcho = false
    }

    /// One tap of the key in a text box: reads the box and the window round it, asks the commands' model what goes
    /// there (with what memory knows about this conversation), and puts it in the box: in place of an instruction
    /// or draft, over the selection, or into the empty box. Nothing is sent. Nothing happens outside a text box, so
    /// a stray tap stays harmless.
    private func writeHere() {
        pendingWrite = nil
        guard case .idle = phase, writeTask == nil, commandTask == nil, AXIsProcessTrusted() else { return }
        guard var read = ReplyWriter.read() else {
            log("write: a tap, but the focus isn't a text box Murmur may write in")
            return
        }
        // Next to nothing above the box: asked again, with more patience (an app that only describes itself once
        // asked, or answers slowly).
        if read.context.above.count < ReplyWriter.fewLines, let again = ReplyWriter.read(patient: true),
           again.context.above.count > read.context.above.count {
            log("write: a second, slower read found \(again.context.above.count) lines (the first: \(read.context.above.count))")
            read = again
        }
        let (context, field) = read
        if context.selection == nil, context.draft.count > 3000 {
            hud.flash("This box is long · select the part to write", seconds: 3)
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        let box = context.selection != nil ? "text selected"
            : context.draft.isEmpty ? "empty" : ReplyWriter.isInstruction(context.draft) ? "an instruction" : "a draft"
        log("write: \(context.app), \(context.above.count) lines above the box, \(context.below.count) below; the box: \(box)"
            + "; mine \(context.sides.filter { $0 == .me }.count), theirs \(context.sides.filter { $0 == .them }.count)")
        let me = Brain.shared.store.meNames()
        let digest = Profile.shared.digestForPrompt()
        let router = agent.currentRouter()
        let oneLine = { (text: Substring) in text.replacingOccurrences(of: "\n", with: " ⏎ ") }
        if writeEcho {
            log("write: app \(context.app) — \(context.title)")
            let marks = context.sides.isEmpty ? [ReplyWriter.Side?](repeating: nil, count: context.above.count) : context.sides
            log("write: whose message is whose: \(context.sides.isEmpty ? "not shown by this window" : "by side")")
            for (line, side) in zip(context.above, marks).suffix(12) {
                log("write:   above │ \(side?.rawValue ?? "-") │ \(line.prefix(160))")
            }
            log("write:   box   │ \(oneLine(context.draft.prefix(200)))")
            if let selection = context.selection { log("write:   selected │ \(oneLine(selection.prefix(200)))") }
            for line in context.below.prefix(3) { log("write:   below │ \(line.prefix(160))") }
        }
        hud.show(.working("Writing · Esc stops"))
        let started = Date()
        let echo = writeEcho, log = log
        writeTask = Task { @MainActor [weak self] in
            // An app that tells Accessibility next to nothing of the conversation: read from a picture of its window.
            var context = context
            let thin = context.above.count < ReplyWriter.fewLines
            let pictured = thin ? await ReplyWriter.readPicture(context, field: field) : nil
            if thin { log("write: a picture of the window: \(ReplyWriter.pictureNote)") }
            if echo, thin {
                for line in context.above { log("write:   the one read │ \(line.prefix(120))") }
            }
            if let seen = pictured {
                context = seen
                log("write: read from a picture of the window: \(seen.above.count) lines above the box; mine "
                    + "\(seen.sides.filter { $0 == .me }.count), theirs \(seen.sides.filter { $0 == .them }.count)")
                if echo {
                    let marks = seen.sides.isEmpty ? [ReplyWriter.Side?](repeating: nil, count: seen.above.count) : seen.sides
                    for (line, side) in zip(seen.above, marks).suffix(14) {
                        log("write:   seen  │ \(side?.rawValue ?? "-") │ \(line.prefix(160))")
                    }
                }
            }
            // What Murmur knows, gathered together: who they're writing to and what memory holds about that person,
            // what it holds about this conversation, who the user is, and how they've written here before.
            let head = ([context.title] + context.above.prefix(4)).joined(separator: "\n")
            let partner = ReplyWriter.partner(context, known: Brain.shared.store.knownPeople(in: head), me: me)
            let thread = await Brain.shared.context(for: context.title + "\n" + context.recent, limit: 1800)
            var about: String?
            if let partner { about = ReplyWriter.about(partner, in: await Brain.shared.context(for: partner, limit: 2400)) }
            let profile = Profile.shared.text("profile")?.text
            // The digest even when it's a few days old (it says its date): old news about the user beats none.
            let current = digest ?? Profile.shared.text("digest").map {
                "As of \(DateFormatter.localizedString(from: $0.generated, dateStyle: .medium, timeStyle: .none)):\n"
                    + String($0.text.prefix(2200))
            }
            let knowing = ReplyWriter.Knowledge(
                profile: profile, digest: current, partner: partner, dossier: about, memory: thread,
                sent: WriteMemory.shared.examples(app: context.app, partner: partner),
                corrections: WriteMemory.shared.corrections(app: context.app))
            let kept = [knowing.digest, knowing.memory].compactMap { ReplyWriter.relevant($0, to: context, me: me) }
                .reduce(0) { $0 + $1.count }
            log("write: to \(partner == nil ? "nobody named" : "a named person"); memory: \(knowing.dossier?.count ?? 0) characters about "
                + "them, \(kept) about this conversation; profile \(profile == nil ? "none" : "in"); the user's own "
                + "messages here: \(ReplyWriter.ownLines(context).count), sent before: \(knowing.sent.count), corrections: "
                + "\(knowing.corrections.count)")
            if echo {
                for line in (knowing.dossier ?? "").split(separator: "\n").prefix(6) { log("write:   about │ \(line.prefix(160))") }
            }
            let (text, rechecked) = await ReplyWriter.write(context, router: router, me: me, knowing: knowing)
            if !rechecked.isEmpty { log("write: \(rechecked.count) made-up detail(s) taken out on a second pass") }
            guard let self, !Task.isCancelled else { return }
            writeTask = nil
            let took = Date().timeIntervalSince(started)
            guard let text else {
                log(String(format: "write: nothing usable from %@ in %.1f s", router.name, took))
                hud.flash("Couldn't write anything here", seconds: 2.5)
                return
            }
            log(String(format: "write: %ld characters from %@ in %.1f s", text.count, router.name, took))
            if writeEcho { log("write: wrote │ \(oneLine(text[...]))") }
            DictationHistory.shared.add(text, app: context.app, kind: .written)
            lastText = text
            // Moved on meanwhile (another app, or typed in the box): copied, not put where it no longer fits.
            let now = ReplyWriter.text(in: field)
            let moved = NSWorkspace.shared.frontmostApplication != app
            let trimmed = { (s: String) in s.prefix(4000).trimmingCharacters(in: .whitespacesAndNewlines) }
            if moved || trimmed(now) != trimmed(context.draft) {
                TextInserter.copy(text)
                log("write: \(moved ? "another app is in front" : "the box changed") now; copied instead")
                hud.flash(moved ? "Written and copied · you'd switched apps" : "The box changed · copied instead", seconds: 3)
                return
            }
            // An instruction or a draft is replaced by what was written; a selection is pasted over.
            if context.selection == nil, !context.draft.isEmpty {
                if !ReplyWriter.selectAll(in: field) {
                    TextInserter.selectAll()
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
            }
            hud.hide()
            report(TextInserter.insert(text))
            watchWritten(text, before: context.draft, in: field, app: app, name: context.app, partner: partner)
            if writeEcho {
                try? await Task.sleep(nanoseconds: 700_000_000)
                log("write: the box now reads │ \(oneLine(ReplyWriter.text(in: field).prefix(400)))")
            }
        }
    }

    /// What becomes of text Murmur wrote into a box, so it learns how you write: the box is looked at every second
    /// for up to two minutes. Emptied, with your text now in the conversation above it: sent, as written or as you
    /// changed it. Back to what it held before, or your own words in its place: taken back. Anything else (you
    /// moved away with it still there) isn't recorded.
    private func watchWritten(_ wrote: String, before: String, in field: AXUIElement, app: NSRunningApplication?,
                              name: String, partner: String?) {
        writtenWatch?.cancel()
        let log = log
        writtenWatch = Task { @MainActor in
            var last = wrote, landed = false
            let was = before.trimmingCharacters(in: .whitespacesAndNewlines)
            for round in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication == app else { return }
                let now = ReplyWriter.text(in: field).trimmingCharacters(in: .whitespacesAndNewlines)
                // Until the text is seen in the box, the box as it was before means it hasn't gone in yet.
                if !landed {
                    if now != was { landed = true } else if round < 4 { continue } else { return }
                }
                if !now.isEmpty { last = now; if now != was { continue } }
                // Empty, or back to what it was: sent only if it's in the conversation now.
                var shown = false
                if now.isEmpty {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    var seen = ReplyWriter.read(patient: true)?.context
                    if let context = seen, context.above.count < ReplyWriter.fewLines {
                        seen = await ReplyWriter.readPicture(context, field: field) ?? context
                    }
                    let above = (seen?.above.suffix(12) ?? []).joined(separator: " ")
                    shown = WriteMemory.overlap(above, last) >= 0.8
                }
                guard let (outcome, sent) = WriteMemory.outcome(wrote: wrote, before: before, last: last, emptied: shown) else { return }
                WriteMemory.shared.add(.init(app: name, partner: partner, wrote: wrote, sent: sent, outcome: outcome))
                log("write: what you did with it: \(outcome.rawValue)")
                return
            }
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
        // the microphone is starting. Only once the pill has opened, though (it takes about half a second): most
        // microphones are on in a quarter of a second, and changing the words twice while the pill was still
        // opening made it stutter.
        phase = .listening(handsFree: handsFree)
        micLive = false
        // Murmur's cleanup model loads while you speak: unloaded (Ollama lets it go after 30 idle minutes, or for
        // the command model), loading it took most of cleanup's 4 seconds and the words went in untidied.
        if aiCleanup || grammarFix, CleanupModel.shared.inUse {
            let model = CleanupModel.tag
            Task.detached(priority: .utility) { await OllamaClient(model: model).warmUp() }
        }
        hud.show(listeningMode(handsFree: handsFree))
        let attempt = UUID()
        micAttempt = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
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
            let level = result.inputVolume.map { String(format: ", input level %.0f%%", $0 * 100) } ?? ""
            let ready = result.wasReady
                ? String(format: " (ready, with %.1f s from before the key)", result.preRollSeconds) : ""
            log(String(format: "dictation: listening with %@%@%@, on in %.2f s%@", name, result.cleaned ? " (clear voice)" : "",
                       level, result.took, ready))
            if let fellBack = result.fellBack { log("dictation: used the default microphone instead of \(fellBack)") }
            onListening?()
            if let problem = result.clearVoiceProblem { log("dictation: clear voice isn't available with \(name): \(problem)") }
            if let problem = result.plainProblem { log("dictation: can't record the microphone's own sound beside Clear voice: \(problem)") }
            if let retried = result.retried { log("dictation: the microphone started on a second try (first: \(retried))") }
            if let volume = result.inputVolume {
                // Turned down too far to hear you clearly: raised now, for this dictation too.
                if adjustsMicLevel, let device = result.device, let level = MicLevel.atStart(volume),
                   setMicLevel(device, from: volume, to: level, why: "too low to hear you clearly") {
                    lowLevelNotice = nil
                } else {
                    warnIfLow(volume, microphone: result.device?.name)
                }
            }
            guard case .listening(let handsFree) = phase else { return }
            if showingMicStart {
                showingMicStart = false
                hud.show(listeningMode(handsFree: handsFree))
            }
        }
    }

    /// The microphone's input level turned down in System Settings › Sound (under 40 %) makes every word arrive faint,
    /// and nothing after the microphone can bring back what wasn't recorded. Said (at most once a day) when a
    /// dictation comes back empty, where it explains why.
    private func warnIfLow(_ volume: Float, microphone: String?) {
        lowLevelNotice = nil
        guard volume < 0.4 else { return }
        let last = UserDefaults.standard.object(forKey: Self.lowLevelWarnedDefault) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        lowLevelNotice = String(format: "%@ is set to %.0f%% · raise Input level in System Settings › Sound",
                                microphone ?? "Your microphone", volume * 100)
        log(String(format: "dictation: %@'s input level is %.0f%%", microphone ?? "the microphone", volume * 100))
    }

    /// Shown when the dictation in progress comes back empty.
    private var lowLevelNotice: String?

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
            titleAtPress = Self.frontWindowTitle()
            selectionAtPress = Self.selectedText()
            vocabularyAtPress = vocabularyNow()
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
        let cleaned = recorder.cleaned
        let plain = cleaned ? recorder.plainSound() : []
        showingMicStart = false
        guard recorded.count >= minimumSamples else {
            phase = .idle
            hud.hide()
            return
        }
        phase = .transcribing
        let maxGainDB: Float = whisperMode ? 40 : 30
        var leveled = AudioLevel.normalize(recorded, maxGainDB: maxGainDB, cleaned: cleaned)
        log(String(format: "dictation: speech %.0f dBFS, noise %.0f dBFS, noise −%.0f dB, gain +%.0f dB%@%@",
                   leveled.speechDB, leveled.noiseDB, leveled.noiseReducedDB, leveled.gainDB,
                   cleaned ? " (clear voice)" : "", whisperMode ? " (quiet voice)" : ""))
        // What the microphone itself heard, beside Clear voice's sound.
        let own = plain.count >= minimumSamples ? AudioLevel.normalize(plain, maxGainDB: maxGainDB) : nil
        let ownHasVoice = own.map { $0.speechDB - $0.noiseDB >= Self.voiceOverNoiseDB } ?? false
        if let own {
            log(String(format: "dictation: the microphone itself heard speech %.0f dBFS, noise %.0f dBFS",
                       own.speechDB, own.noiseDB))
        }
        // The level for next time, from how loud this voice arrived at the microphone.
        let arrived = cleaned ? own : Optional(leveled)
        if adjustsMicLevel, let arrived, let device = recorder.device,
           let volume = AudioDevices.inputVolume(device.id),
           let level = MicLevel.after(volume: volume, speechDB: arrived.speechDB, noiseDB: arrived.noiseDB,
                                      peakDB: MicLevel.peakDB(cleaned ? plain : recorded)) {
            _ = setMicLevel(device, from: volume, to: level,
                            why: level > volume ? "your voice arrived faint" : "your voice arrived too loud")
        }
        // Clear voice let a soft voice through faint (it takes a whisper for noise): the microphone's own sound
        // instead, with Murmur's own noise removal and boost.
        var backup: [Float]?
        if let own, ownHasVoice {
            if leveled.speechDB < Self.faintThroughClearVoiceDB {
                log(String(format: "dictation: Clear voice let your voice through at only %.0f dBFS; using the "
                           + "microphone's own sound (noise −%.0f dB, gain +%.0f dB)",
                           leveled.speechDB, own.noiseReducedDB, own.gainDB))
                leveled = own
            } else {
                backup = own.samples
            }
        }
        let samples = leveled.samples
        let ownSound = backup
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
        let pressedTitle = titleAtPress
        let detect = detectCommands
        let vocabulary = vocabularyAtPress
        let compare = UserDefaults.standard.bool(forKey: Self.compareDefault)
        // The old way, to compare: without the moment before the key.
        let preRoll = min(samples.count, Int(recorder.lastPreRollSeconds * 16_000))
        let withoutPreRoll = compare ? Array(samples[preRoll...]) : []
        Task { [weak self] in
            guard let self else { return }
            let ready = await transcriber.isReady
            hud.show(ready ? .transcribing : .working(modelStatus))
            let started = Date()
            do {
                var raw = try await transcriber.transcribe(samples, vocabulary: vocabulary)
                // The spotter's proposals: made only over words Parakeet was unsure of.
                let swaps = await transcriber.lastSwaps
                if !swaps.isEmpty {
                    let heard = await transcriber.lastHeard
                    let made = DictationVocabulary.believable(swaps, heard: heard)
                    let kept = swaps.filter { !made.contains($0) }
                    raw = DictationVocabulary.apply(made, to: raw)
                    log("dictation: vocabulary"
                        + (made.isEmpty ? "" : " changed \(made.map(\.description).joined(separator: ", "))")
                        + (kept.isEmpty ? "" : "; kept Parakeet's \(kept.map(\.description).joined(separator: ", "))")
                        + "; unsure words: \(DictationVocabulary.unsure(heard).isEmpty ? "none" : DictationVocabulary.unsure(heard))")
                }
                var text = TextCleanup.basic(raw)
                // Nothing heard in Clear voice's sound: what the microphone itself heard.
                if text.isEmpty, let ownSound {
                    let again = TextCleanup.basic(try await transcriber.transcribe(ownSound, vocabulary: vocabulary))
                    log("dictation: no words in Clear voice's sound; the microphone's own gave \(again.count) characters")
                    if !again.isEmpty {
                        text = again
                        lastSamples = ownSound
                    }
                }
                let seconds = Double(samples.count) / 16_000
                log(String(format: "dictation: %.1f s of audio → %ld characters in %.2f s",
                           seconds, text.count, Date().timeIntervalSince(started)))
                if let note = await transcriber.lastNote { log("dictation: \(note)") }
                if compare {
                    let unsure = DictationVocabulary.unsure(await transcriber.lastHeard)
                    let old = (try? await transcriber.transcribe(withoutPreRoll, pad: false)) ?? ""
                    log("dictation: compare · before: \"\(TextCleanup.basic(old))\" · now: \"\(text)\""
                        + " · unsure words now: \(unsure.isEmpty ? "none" : unsure)")
                }
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
                    } else if let notice = lowLevelNotice {
                        lowLevelNotice = nil
                        UserDefaults.standard.set(Date(), forKey: Self.lowLevelWarnedDefault)
                        hud.flash(notice, seconds: 5, tone: .problem)
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
                                                    hasSelection: selection != nil, router: agent.currentRouter(),
                                                    windowTitle: pressedTitle)
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
                    let provider = RouterChoice.current.provider
                    hud.flash("\(provider) rejected the API key. Change it in Commands & Assistants.", seconds: 4)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
                if decision.intent == .command {
                    // One command at a time: a new one stops the one still running (they took turns on the
                    // screen, each undoing the other's work), and starts once it has.
                    if let running = commandTask {
                        log("command: a new command stops the one still running")
                        agent.stop()
                        running.cancel()
                        await running.value
                    }
                    log("command: \"\(text)\"")
                    DictationHistory.shared.add(text, app: frontApp, kind: .command)
                    hud.show(.working("“\(text.prefix(50))” · Esc stops"))
                    lastCommand = text
                    let agent = agent
                    let explicit = decision.explicit
                    let editable = focus == .textField
                    let selected = selection
                    let run = Task { @MainActor in
                        await agent.run(text, frontApp: frontApp, selection: selected, explicit: explicit,
                                        editable: editable)
                    }
                    commandTask = run
                    await run.value
                    if commandTask == run { commandTask = nil }
                    if hud.isWorking { hud.hide() }
                    return
                }
                lastHeard = text
                lastCleaned = false
                // AI cleanup writes numbers as digits, whatever the model does: "version one point three" →
                // "version 1.3" (Sarvam writes them out in words, and the model was told to leave them).
                if aiCleanup {
                    let numbered = SpokenNumbers.digits(text)
                    if numbered != text { log("dictation: numbers written as digits"); text = numbered; lastCleaned = true }
                }
                var words = text
                let tidy = aiCleanup && DictationCleanup.worthCleaning(text)
                let fix = grammarFix && DictationCleanup.worthFixing(text)
                if tidy || fix {
                    hud.show(.working(tidy ? "Tidying up" : "Fixing grammar"))
                    if let cleaned = await cleanUp(text, tidy: tidy, grammar: fix) {
                        words = cleaned
                        lastCleaned = lastCleaned || cleaned != text
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

    /// AI cleanup (`tidy`) and grammar fixing (`grammar`), one or both in one reply, with Murmur's cleanup model or
    /// the commands' model. Nil — the words are typed as heard — when the model is slow (over 4 s), fails, or replies
    /// with anything but a tidied or grammar-fixed version of what was said.
    private func cleanUp(_ text: String, tidy: Bool, grammar: Bool) async -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        let category = DictationCleanup.category(bundleID: app?.bundleIdentifier, windowTitle: Self.frontWindowTitle())
        let style = cleanupStyle(for: category)
        let (router, modelName) = await cleanupRouter()
        let system = tidy ? DictationCleanup.system(style: style, category: category, grammar: grammar)
                          : DictationCleanup.grammarSystem()
        let turns: [RouterTurn] = tidy ? [.user(DictationCleanup.user(text))] : DictationCleanup.grammarTurns(text)
        let started = Date()
        let reply: String? = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let work = Task {
                let answer = try? await router.chat(system: system, turns: turns, tools: []).text
                once.run { continuation.resume(returning: answer) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                once.run { continuation.resume(returning: nil) }
                work.cancel()
            }
        }
        let took = Date().timeIntervalSince(started)
        let job = tidy && grammar ? "AI cleanup + grammar" : tidy ? "AI cleanup" : "grammar fix"
        let what = tidy ? "\(modelName), \(category.rawValue), \(style.rawValue)" : modelName
        guard let reply else {
            log(String(format: "dictation: %@ (%@) gave nothing in %.1f s: typed as heard", job, what, took))
            // Murmur's model may have been removed or Ollama closed: look again before the next dictation.
            if modelName == CleanupModel.tag { await CleanupModel.shared.refresh() }
            return nil
        }
        guard let cleaned = DictationCleanup.accept(original: text, cleaned: reply, cleanup: tidy, grammar: grammar) else {
            log(String(format: "dictation: %@ (%@) changed more than it may in %.1f s: typed as heard", job, what, took))
            return nil
        }
        log(String(format: "dictation: %@ (%@) in %.1f s%@", job, what, took, cleaned == text ? ", nothing to change" : ""))
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
            // Secure Input held elsewhere no longer stops typing; said once per holder, for the log.
            let holder = SecureInput.holderName()
            if holder != secureHolderLogged {
                if let holder { log("paste: Secure Input is on (held by \(holder)), typing anyway: no password field has the focus") }
                secureHolderLogged = holder
            }
        case .secureInput:
            log("paste: a password field has the focus (Secure Input held by \(SecureInput.holderName() ?? "nobody")), nothing typed")
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
            modelStatus = "Speech model ready (\(model.short), \(model.isLocal ? "on device" : "online"))"
            speechModelState = .ready
            log(String(format: "dictation: %@ ready in %.1f s", model.engine, Date().timeIntervalSince(started)))
            prepareVocabularyIfWanted()
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
        // A dev copy (its own settings suite, beside the installed Murmur) leaves the talk key to the installed one:
        // on 23 Nov a dev copy left open after a tour check heard fn too, and every dictation was typed twice. It
        // listens only when asked (-devListens YES).
        if UserDefaults.standard.string(forKey: "defaultsSuite") != nil, !UserDefaults.standard.bool(forKey: "devListens") {
            log("dictation: a dev copy: the talk key is left to the installed Murmur (-devListens YES to listen)")
            return
        }
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
        recheckTrust()
    }

    /// Accessibility and the key, as the windows show them, published so they redraw when either changes:
    /// `canPaste` and `isListeningForKey` are read straight from macOS, and a grant in System Settings changed nothing
    /// on screen (Home kept saying "Murmur can't type into other apps yet" while dictation worked). Checked every two
    /// seconds, when macOS says the setting changed, and when Murmur comes to the front; each change is logged, the
    /// state at launch too.
    @Published public private(set) var accessibilityAllowed = false
    @Published public private(set) var keyWatched = false
    private var trustChecked = false
    private var trustObservers: [NSObjectProtocol] = []
    private var trustTimer: Timer?

    private func recheckTrust() {
        let trusted = AXIsProcessTrusted(), listening = monitor.isRunning
        guard !trustChecked || trusted != accessibilityAllowed || listening != keyWatched else { return }
        log("dictation: Accessibility \(trusted ? "allowed" : "not allowed"), key \(listening ? "watched" : "not watched")"
            + (trustChecked ? "" : " (at launch)"))
        trustChecked = true
        accessibilityAllowed = trusted
        keyWatched = listening
        // Allowed while the key wasn't being watched (the retry timer stops once it starts): start now.
        if trusted, !listening { retryMonitor() }
    }

    private func watchTrust() {
        guard trustObservers.isEmpty else { return }
        recheckTrust()
        let recheck: (Notification) -> Void = { [weak self] _ in
            // The setting applies a moment after its notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.recheckTrust() }
        }
        trustObservers = [
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main, using: recheck),
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: recheck),
        ]
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.recheckTrust() }
        }
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
        let provider = choice.provider
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "\(provider) API key"
            alert.informativeText = (problem.map { "\($0)\n\n" } ?? "")
                + (choice == .sarvam
                    ? "Used for what you pick Sarvam for: speech-to-text (your recordings go to Sarvam) or commands. "
                        + "From dashboard.sarvam.ai. Stored in your Keychain. Leave empty to remove the key."
                    : "Used only for commands (your words, the front app's name and any selected text). Speech never "
                        + "leaves your Mac. Stored in your Keychain. Leave empty to remove the key.")
            if problem != nil { alert.alertStyle = .warning }
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
            field.placeholderString = choice == .anthropic ? "sk-ant-…" : choice == .sarvam ? "sk_…" : "sk-proj-…"
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
        let provider = choice.provider
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
                self.hud.flash("\(provider) key works with \(choice.model)", seconds: 2.5, tone: .done)
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
