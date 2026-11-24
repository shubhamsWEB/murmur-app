import AgentKit
import AppKit
import FluidAudio
import Foundation

/// Meeting notes: while a call runs, Murmur listens to both sides (the call's sound and your microphone), writes
/// down what's said, keeps notes (summary, decisions, action items) as it goes, and when someone on the call asks a
/// question, drafts an answer and a few things you could say. All of it shows in a panel beside the call, which is
/// kept out of screen sharing; at the end the notes and the transcript are saved to Documents › Murmur Meetings.
///
/// Answering waits for the question to be over: the other side's lines since the last answer make one turn; once
/// they've stopped talking, a quick yes/no from the model says whether the question is finished, and then the
/// answer is written into the panel as it comes. If they carry on within three seconds of an answer, it's answered
/// again with the whole turn. ⌥⌘↩ (or Answer now) answers at once.
///
/// What the meeting is about, your instructions and your documents (Context) go with every answer and the notes.
/// Speech is transcribed with the dictation model (on this Mac, or Sarvam if chosen); the notes and answers come
/// from the model chosen for commands, so with Claude, OpenAI or Sarvam the transcript goes to that provider.
@MainActor
public final class MeetingMode {
    let state = MeetingState()
    /// Telling the call's voices apart, and the last one heard (a short stretch straight after is theirs too).
    private let voiceprints = MeetingVoices()
    private var lastVoice: (voice: Int, until: Date)?
    private let log: (String) -> Void
    private let transcriber: () -> SpeechTranscriber?
    private let router: () -> Router?
    private let microphone: () -> AudioDevices.Input?

    private lazy var panel = MeetingPanel(mode: self)
    private lazy var prompt = MeetingPrompt()

    private var mic: LiveMicrophone?
    private var call: AnyObject?
    private var micFeed: MeetingFeed?
    private var callFeed: MeetingFeed?
    private var pieces: AsyncStream<MeetingPiece>.Continuation?
    private var worker: Task<Void, Never>?
    private var nextID = 0
    private var ticker: Timer?
    private var hotkey: MeetingHotkey?

    // Turn-taking.
    /// The other side's lines since the last answer.
    private var turn: [MeetingLine] = []
    private var turnChanged = Date.distantPast
    private var turnRevision = 0
    private var checkedRevision = -1
    private var checking = false
    /// What the model said about the turn last time it was asked ("wait": still asking; "no": nothing to answer).
    private var lastVerdict: String?

    /// Who turns the meeting's speech into text: its own setting, apart from the AI that answers. The dictation model
    /// (the default), or Sarvam or OpenAI in the cloud, so a meeting's speech needn't be transcribed on this Mac.
    public enum Speech: String, CaseIterable, Sendable {
        case dictation = "", sarvam, openai

        public var display: String {
            switch self {
            case .dictation: return "Same as dictation"
            case .sarvam: return "Sarvam (cloud)"
            case .openai: return "OpenAI \(OpenAITranscriber.model) (cloud)"
            }
        }

        /// The key it needs (nil: none).
        var keyChoice: RouterChoice? {
            switch self {
            case .dictation: return nil
            case .sarvam: return .sarvam
            case .openai: return .openai
            }
        }

        public var hasKey: Bool { keyChoice?.hasKey ?? true }
    }

    static let speechKey = "meeting.speech"
    public static var speechChoice: Speech {
        get { Speech(rawValue: UserDefaults.standard.string(forKey: speechKey) ?? "") ?? .dictation }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: speechKey) }
    }
    private var speech: Speech = .dictation
    private lazy var sarvam = SarvamTranscriber()
    /// What the last answer was for, and when it finished (a continuation within 3 s is answered again with it).
    private var answeredTurn: [MeetingLine] = []
    private var answeredAt: Date?
    private var answerTask: Task<Void, Never>?
    /// The meeting app (its bundle identifier), whose window is the meeting's screen.
    private var appBundle: String?

    // Who's speaking.
    /// Lines when the conversation was last asked for names, and that request.
    private var linesAtNames = 0
    private var namesTask: Task<Void, Never>?
    /// Which of the meeting's stretches (MeetingVoices) each line is, so lines follow when voices are grouped again.
    private var stretchOfLine: [Int: Int] = [:]
    /// Saved people you confirmed for a voice (a yes to "possibly Priya", or Remember this voice), and the
    /// "voice profile" pairs you said no to.
    private var confirmed: [Int: UUID] = [:]
    private var declined: Set<String> = []
    /// What your microphone heard for each of your lines, before any of the call's words were taken out of it: it's
    /// compared again, whole, as more of what they said then is written down.
    private var micHeard: [Int: String] = [:]
    /// The people the meeting app lists (its roster), for spelling names right; empty until it's read.
    var roster: [String] = []
    /// When words were last heard from either side: a meeting you started yourself ends after long silence.
    private var lastWords = Date()

    // Notes.
    private var notesTask: Task<Void, Never>?
    private var linesAtNotes = 0
    private var lastNotes = Date.distantPast

    // Offering notes when a meeting starts.
    /// Started because a meeting app turned on the microphone: it ends when that app lets go of it.
    private var automatic = false
    private var checks: Timer?
    private var seen: (app: String, since: Date)?
    private var prompted: String?
    private var micFreeSince: Date?

    static let offerKey = "meeting.offerNotes"
    static let autoAnswerKey = "meeting.autoAnswer"
    static let instructionsKey = "meeting.instructions"
    static let aiKey = "meeting.ai"

    /// The AI that writes meeting answers and notes; nil: the one chosen for commands. A cloud model takes the work
    /// (and the fan) off this Mac.
    public static var aiChoice: RouterChoice? {
        get { UserDefaults.standard.string(forKey: aiKey).flatMap(RouterChoice.init) }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "", forKey: aiKey) }
    }

    /// Asks for an API key (true when one is saved): set by the app.
    var askForKey: ((RouterChoice) -> Bool)?

    init(log: @escaping (String) -> Void, transcriber: @escaping () -> SpeechTranscriber?,
         router: @escaping () -> Router?, microphone: @escaping () -> AudioDevices.Input?) {
        self.log = log
        self.transcriber = transcriber
        self.router = router
        self.microphone = microphone
        state.autoAnswer = UserDefaults.standard.object(forKey: Self.autoAnswerKey) as? Bool ?? true
        state.instructions = UserDefaults.standard.string(forKey: Self.instructionsKey) ?? ""
        state.ai = Self.aiChoice
        state.speech = Self.speechChoice
    }

    public var isOn: Bool { state.running }

    /// Offer to take notes when a meeting app turns on the microphone (on unless turned off).
    public var offers: Bool {
        get { UserDefaults.standard.object(forKey: Self.offerKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.offerKey)
            if !newValue { prompt.hide() }
            watch()
        }
    }

    /// Looks every few seconds for a meeting app with the microphone on (while offering, or while notes started that
    /// way are running).
    func watch() {
        let wanted = offers || (state.running && automatic)
        if wanted, checks == nil {
            checks = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        } else if !wanted {
            checks?.invalidate()
            checks = nil
        }
    }

    private func check() {
        let app = MicUsers.meetingApp()
        if state.running {
            guard automatic else { return }
            if app != nil {
                micFreeSince = nil
            } else if let since = micFreeSince {
                if Date().timeIntervalSince(since) >= 30 {
                    log("meeting: \(state.app ?? "the meeting app") turned the microphone off; finishing the notes")
                    stop()
                }
            } else {
                micFreeSince = Date()
            }
            return
        }
        guard offers, let app else {
            seen = nil
            prompted = nil
            prompt.hide()
            return
        }
        guard prompted != app else { return }
        if let seen, seen.app == app {
            // On for a few seconds, not a moment's voice search.
            guard Date().timeIntervalSince(seen.since) >= 5 else { return }
            prompted = app
            log("meeting: \(app) has the microphone on; offering notes")
            prompt.show(app: app, start: { [weak self] in self?.start(app: app, automatic: true) },
                        dismiss: { [weak self] in self?.log("meeting: notes not taken for \(app)") })
        } else {
            seen = (app, Date())
        }
    }

    // MARK: - A meeting

    /// Starts listening to the call and your microphone (or shows the notes, when they're already running).
    public func start(app: String? = nil, automatic: Bool = false) {
        prompt.hide()
        guard !state.running, !state.finishing else { panel.show(); return }
        state.reset()
        state.running = true
        let found = MicUsers.meeting()
        state.app = app ?? found?.name
        appBundle = found.flatMap { app == nil || app == $0.name ? $0.bundle : nil }
        self.automatic = automatic
        micFreeSince = nil
        nextID = 0
        turn = []
        answeredTurn = []
        answeredAt = nil
        checkedRevision = -1
        linesAtNotes = 0
        lastNotes = Date()
        lastVoice = nil
        linesAtNames = 0
        namesTask = nil
        stretchOfLine = [:]
        micHeard = [:]
        confirmed = [:]
        declined = []
        roster = []
        lastWords = Date()
        Task { [weak self, voiceprints] in
            await voiceprints.reset()
            let started = Date()
            do {
                try await voiceprints.prepare()
                self?.log(String(format: "meeting: voices told apart (model ready in %.1f s)", Date().timeIntervalSince(started)))
            } catch {
                self?.log("meeting: can't tell voices apart: \(error.localizedDescription)")
            }
        }
        let (stream, continuation) = AsyncStream.makeStream(of: MeetingPiece.self)
        pieces = continuation
        worker = Task { [weak self] in
            for await piece in stream {
                guard let self else { return }
                await transcribe(piece)
            }
        }
        let send: @Sendable (MeetingPiece) -> Void = { _ = continuation.yield($0) }

        let mic = LiveMicrophone()
        do {
            try mic.start(microphone()) { rate in
                let feed = MeetingFeed(speaker: .you, rate: rate, send: send)
                self.micFeed = feed
                return { feed.add($0) }
            }
            self.mic = mic
        } catch {
            state.problem = "Can't hear your microphone: \(error.localizedDescription)"
            log("meeting: microphone: \(error.localizedDescription)")
        }
        if #available(macOS 14.2, *) {
            let call = CallAudio()
            do {
                try call.start { rate in
                    let feed = MeetingFeed(speaker: .them, rate: rate, send: send)
                    self.callFeed = feed
                    return { feed.add($0) }
                }
                self.call = call
            } catch {
                state.problem = "Can't hear the call: \(error.localizedDescription)"
                log("meeting: call sound: \(error.localizedDescription)")
            }
        } else {
            state.problem = "Hearing the call needs macOS 14.2 or later: only your microphone is in these notes."
        }
        hotkey = MeetingHotkey { [weak self] in self?.answerNow() }
        if hotkey == nil { log("meeting: \(MeetingHotkey.display) is taken by another app") }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        panel.show()
        watch()
        speech = Self.speechChoice.hasKey ? Self.speechChoice : .dictation
        if speech != Self.speechChoice {
            state.problem = "\(Self.speechChoice.display) needs an API key: the dictation model transcribes this meeting."
        }
        log("meeting: speech transcribed " + (speech != .dictation ? "by \(speech.display)"
            : (transcriber()?.model.isLocal ?? true) ? "on this Mac (\(transcriber()?.model.rawValue ?? "?"))"
            : "by Sarvam (the dictation model)"))
        log("meeting: notes started" + (state.app.map { " (\($0))" } ?? "") + (automatic ? ", offered" : "")
            + ", answers with \(router()?.name ?? "?")")
        // Is the panel really left out of screen sharing on this Mac?
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.checkSharing()
        }
        // macOS gives silence, not an error, until System Audio Recording is allowed.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, state.running, let callFeed, !callFeed.heardSound else { return }
            state.problem = "No sound from the call yet. If others are talking, allow Murmur under System Settings › "
                + "Privacy & Security › Screen & System Audio Recording (System Audio Recording Only)."
            log("meeting: no sound from the call after a minute")
        }
    }

    /// Stops listening, writes the final notes and saves them.
    public func stop() {
        guard state.running else { return }
        state.running = false
        state.finishing = true
        state.callLevel = 0
        state.micLevel = 0
        ticker?.invalidate()
        ticker = nil
        hotkey?.invalidate()
        hotkey = nil
        mic?.stop()
        mic = nil
        if #available(macOS 14.2, *) { (call as? CallAudio)?.stop() }
        call = nil
        micFeed?.finish()
        callFeed?.finish()
        micFeed = nil
        callFeed = nil
        let worker = self.worker
        let pieces = self.pieces
        self.pieces = nil
        self.worker = nil
        watch()
        Task { [weak self] in
            // What was still being said goes in, then the last notes.
            try? await Task.sleep(nanoseconds: 400_000_000)
            pieces?.finish()
            await worker?.value
            guard let self else { return }
            await answerTask?.value
            await notesTask?.value
            if !state.lines.isEmpty {
                // Names first, so the final notes and the file say who said what.
                await namesTask?.value
                await guessNames(force: true)?.value
                await learnRememberedVoices()
                await writeNotes(final: true)
                save()
            }
            state.finishing = false
            log("meeting: notes finished, \(state.lines.count) lines")
        }
    }

    func showPanel() {
        state.collapsed = false
        state.unread = false
        panel.show()
    }

    /// Folds the panel into a small pill at the top of the screen (it lights up when an answer is ready).
    func collapse() {
        state.collapsed = true
        log("meeting: panel folded")
    }

    func expand() {
        state.collapsed = false
        state.unread = false
    }

    func setLayout(_ layout: MeetingState.Layout) {
        state.layout = layout
        state.collapsed = false
        log("meeting: panel \(layout == .strip ? "near the camera" : "beside the call")")
    }

    func closePanel() {
        panel.hide()
        if !state.running, !state.finishing { state.reset() }
    }

    // MARK: - Controls (the panel and the hotkey)

    func setAutoAnswer(_ on: Bool) {
        state.autoAnswer = on
        UserDefaults.standard.set(on, forKey: Self.autoAnswerKey)
        log("meeting: auto answer \(on ? "on" : "off")")
    }

    func setMicMuted(_ muted: Bool) {
        state.micMuted = muted
        micFeed?.muted = muted
        log("meeting: microphone \(muted ? "muted" : "on") in the notes")
    }

    /// Chooses who transcribes meetings, asking for a key first if it needs one.
    func setSpeech(_ choice: Speech) {
        if let key = choice.keyChoice, !key.hasKey, askForKey?(key) != true {
            state.objectWillChange.send()
            return
        }
        Self.speechChoice = choice
        state.speech = choice
        log("meeting: speech for meetings: \(choice.display)")
    }

    /// Chooses the AI for meeting answers and notes (nil: the commands' AI), asking for a key first if it needs one.
    func setAI(_ choice: RouterChoice?) {
        if let choice, choice != .local, !choice.hasKey, askForKey?(choice) != true {
            state.objectWillChange.send()   // the picker goes back to what it was
            return
        }
        Self.aiChoice = choice
        state.ai = choice
        log("meeting: answers and notes with \(router()?.name ?? "?")" + (choice == nil ? " (the commands' AI)" : ""))
    }

    /// The AI answers and notes come from now, by name ("Claude", "Local model").
    var aiName: String {
        guard let router = router() else { return "your AI for commands" }
        return router is AnthropicRouter ? "Claude (\(AnthropicRouter.thoroughModel))" : router.name
    }

    func setInstructions(_ text: String) {
        state.instructions = text
        UserDefaults.standard.set(text, forKey: Self.instructionsKey)
    }

    /// Answers what the other side said last, now: the turn so far, else their latest lines.
    func answerNow() {
        guard state.running || !state.lines.isEmpty else { return }
        var lines = turn
        if lines.isEmpty {
            let theirs = state.lines.filter { $0.speaker == .them }
            if let last = theirs.last {
                lines = Array(theirs.filter { last.at.timeIntervalSince($0.at) < 30 }.suffix(3))
            }
        }
        guard !lines.isEmpty else {
            state.problem = "Nothing from the other side to answer yet."
            return
        }
        log("meeting: answer now")
        fire(lines, replace: false)
    }

    /// Answers from what's on your screen (the front window's text), with the conversation for context.
    /// Answers about what's on the meeting's screen (a shared slide, chart or page): the other side's latest
    /// question with a picture of the meeting, or, with no question, what's worth saying about what's shown.
    func answerFromScreen() {
        var lines = turn
        if lines.isEmpty {
            let theirs = state.lines.filter { $0.speaker == .them }
            if let last = theirs.last, Date().timeIntervalSince(last.at) < 90 {
                lines = Array(theirs.filter { last.at.timeIntervalSince($0.at) < 30 }.suffix(3))
            }
        }
        log("meeting: answer about the screen")
        fire(lines, replace: false, screen: true)
    }

    func checkSharing() async {
        guard let window = panel.window else { return }
        state.sharing = .checking
        let verdict = await ShareCheck.run(window)
        switch verdict {
        case .hidden:
            state.sharing = .hidden
            log("meeting: the panel is hidden from this Mac's screen capture")
        case .visible:
            state.sharing = .visible
            log("meeting: this Mac's screen capture can see the panel")
        case .unknown(let why):
            state.sharing = .unknown
            log("meeting: couldn't check screen sharing: \(why)")
        }
    }

    // MARK: - Words

    /// With the meeting's AI in the cloud, its speech goes to the cloud too: the meeting AI's own provider when it
    /// transcribes (OpenAI, Sarvam), else Sarvam or OpenAI when there's a key. Claude doesn't transcribe.
    private func transcribe(_ piece: MeetingPiece) async {
        do {
            guard let whole = try await words(piece.samples) else { return }
            // A stretch of the call can hold two people (the next one started without a pause): each one's part
            // gets a line of its own, so nobody's words go under someone else's name.
            let parts = piece.speaker == .them ? await voiceprints.turns(piece.samples) : [0..<piece.samples.count]
            guard parts.count > 1 else {
                let text = TextCleanup.basic(whole.text)
                if MeetingText.isWorthKeeping(text) { await heard(piece, text) }
                return
            }
            log("meeting: \(parts.count) people in one stretch: a line each")
            // Whose words are whose: by when each was said, the stretch transcribed once and whole, when the speech
            // model says when; otherwise each part is transcribed by itself.
            let texts = SpeakerTurns.texts(whole.times, cuts: parts.dropFirst().map { Double($0.lowerBound) / 16_000 },
                                           whole: whole.text)
            let before = nextID
            for (index, part) in parts.enumerated() {
                let samples = Array(piece.samples[part])
                var said = texts?[index]
                if said == nil { said = try await words(samples)?.text }
                let text = TextCleanup.basic(said ?? "")
                guard MeetingText.isWorthKeeping(text) else { continue }
                await heard(MeetingPiece(speaker: .them, samples: samples,
                                         at: piece.at.addingTimeInterval(Double(part.lowerBound) / 16_000),
                                         afterChange: true, first: index == 0), text)
            }
            rejoin(before..<nextID)
        } catch {
            log("meeting: couldn't transcribe: \(error.localizedDescription)")
        }
    }

    /// What was said in `samples`, and when each word was (when the speech model says: Parakeet does). nil when
    /// there's no speech model to ask.
    private func words(_ samples: [Float]) async throws -> (text: String, times: [TimedWord])? {
        switch speech {
        case .sarvam, .openai:
            do {
                let text = speech == .sarvam ? try await sarvam.transcribe(samples)
                    : try await OpenAITranscriber.transcribe(samples)
                return (text, [])
            } catch {
                // The cloud couldn't be reached: this Mac's model for this piece, rather than losing it.
                log("meeting: cloud speech failed (\(error.localizedDescription)); this piece on this Mac")
                guard let transcriber = transcriber(), await transcriber.isReady else { throw error }
                let text = try await transcriber.transcribe(samples)
                return (text, await transcriber.lastTimes)
            }
        case .dictation:
            guard let transcriber = transcriber() else { return nil }
            guard await transcriber.isReady else {
                state.problem = "The speech model isn't ready yet. It's set up under Settings › Speech."
                return nil
            }
            let text = try await transcriber.transcribe(samples)
            return (text, await transcriber.lastTimes)
        }
    }

    /// The parts of one stretch are written down (`ids`: their lines): parts next to each other that turned out to
    /// be one voice are one line again, so a cut that wasn't needed leaves no trace.
    private func rejoin(_ ids: Range<Int>) {
        // A part too short to tell by voice, between two parts of one voice, is that person's too.
        for at in state.lines.indices.dropFirst().dropLast() where state.lines[at].voice == nil
            && state.lines[at].speaker == .them && ids.contains(state.lines[at].id) {
            let earlier = state.lines[at - 1], later = state.lines[at + 1]
            if ids.contains(earlier.id), ids.contains(later.id), earlier.speaker == .them, later.speaker == .them,
               let voice = earlier.voice, voice == later.voice {
                state.lines[at].voice = voice
            }
        }
        var index = 1
        while index < state.lines.count {
            let earlier = state.lines[index - 1], later = state.lines[index]
            if ids.contains(earlier.id), ids.contains(later.id), earlier.speaker == .them, later.speaker == .them,
               let voice = earlier.voice, voice == later.voice {
                state.lines[index - 1].text = earlier.text + " " + later.text
                state.lines[index - 1].seconds = later.end.timeIntervalSince(earlier.at)
                state.lines.remove(at: index)
                if index < linesAtNotes { linesAtNotes -= 1 }
                turn.removeAll { $0.id == later.id }
                if let at = turn.firstIndex(where: { $0.id == earlier.id }) { turn[at] = state.lines[index - 1] }
            } else {
                index += 1
            }
        }
        linesAtNotes = min(linesAtNotes, state.lines.count)
        state.refreshSpeakers()
    }

    /// A stretch's words are known: whose voice it was, then into the transcript.
    private func heard(_ piece: MeetingPiece, _ text: String) async {
        do {
            // Which of them said it: by voice; a stretch too short to tell, straight after one that wasn't, is theirs.
            var voice: Int?
            if piece.speaker == .them {
                let placed = await voiceprints.hear(piece.samples)
                if let placed {
                    stretchOfLine[nextID] = placed.index
                    voice = placed.voices[placed.index]
                    // Hearing more can change who said earlier stretches: those lines move too.
                    regrouped(placed.voices)
                }
                // (Not a part cut off where the speaker changed: whoever it is, it isn't the last one.)
                if voice == nil, let lastVoice, piece.at.timeIntervalSince(lastVoice.until) < 3,
                   !piece.afterChange || piece.first { voice = lastVoice.voice }
                let end = piece.at.addingTimeInterval(Double(piece.samples.count) / 16_000)
                if let voice { lastVoice = (voice, end) } else if piece.afterChange { lastVoice = nil }
                let heard = await voiceprints.count
                if heard != state.voices {
                    state.voices = heard
                    if heard > 1 { log("meeting: \(heard) voices on the call") }
                }
            }
            add(MeetingLine(id: nextID, speaker: piece.speaker, text: text, at: piece.at, voice: voice,
                            seconds: Double(piece.samples.count) / 16_000))
            nextID += 1
            if piece.speaker == .them { await recognise() }
        }
    }

    /// The voices were grouped again: each line follows its stretch, and a voice that's gone (it turned out to be
    /// someone already heard) hands its name on.
    private func regrouped(_ voices: [Int?]) {
        var went: [Int: [Int: Int]] = [:]   // old voice → where its lines are now
        var changed = false
        for index in state.lines.indices {
            let line = state.lines[index]
            guard let stretch = stretchOfLine[line.id], voices.indices.contains(stretch) else { continue }
            let now = voices[stretch]
            guard now != line.voice else { continue }
            if let old = line.voice, let now { went[old, default: [:]][now, default: 0] += 1 }
            state.lines[index].voice = now
            changed = true
        }
        guard changed else { return }
        let left = Set(state.lines.compactMap(\.voice))
        for (old, to) in went where !left.contains(old) {
            guard let into = to.max(by: { $0.value < $1.value })?.key else { continue }
            if let name = state.names[old] { state.names[into] = VoiceName.merge(name, state.names[into] ?? name) }
            state.names[old] = nil
            if confirmed[into] == nil, let profile = confirmed[old] { confirmed[into] = profile }
            confirmed[old] = nil
            if lastVoice?.voice == old { lastVoice?.voice = into }
        }
        state.refreshSpeakers()
    }

    private func add(_ line: MeetingLine) {
        var line = line
        switch line.speaker {
        case .you:
            // On speakers, your microphone hears the call too: that isn't you speaking. It's compared with all they
            // said while it was being heard, not one of their lines: the microphone cuts elsewhere than the call.
            guard let yours = MeetingText.withoutEcho(line.text, theirs: MeetingText.during(line, in: state.lines).map(\.text)) else {
                log("meeting: your microphone picked up the call (speakers?): left out once")
                return
            }
            micHeard[line.id] = line.text
            if yours != line.text {
                log("meeting: your microphone picked up the call under your words: their part left out")
                line.text = yours
            }
        case .them:
            break
        }
        // Lines stay in the order they were said: a long stretch finishes after shorter ones that began later.
        let index = state.lines.lastIndex(where: { $0.at <= line.at }).map { $0 + 1 } ?? 0
        state.lines.insert(line, at: index)
        linesAtNotes = min(linesAtNotes, index)
        if line.speaker == .them {
            // What your microphone heard of this, written down before their line was, goes now.
            for yours in state.lines where yours.speaker == .you && yours.end >= line.at.addingTimeInterval(-MeetingText.echoSlack)
                && yours.at <= line.end.addingTimeInterval(MeetingText.echoSlack) {
                let rest = MeetingText.withoutEcho(micHeard[yours.id] ?? yours.text,
                                                   theirs: MeetingText.during(yours, in: state.lines).map(\.text))
                guard rest != yours.text, let at = state.lines.firstIndex(where: { $0.id == yours.id }) else { continue }
                if let rest {
                    state.lines[at].text = rest
                } else {
                    state.lines.remove(at: at)
                    if at < linesAtNotes { linesAtNotes -= 1 }
                }
            }
        }
        lastWords = Date()
        state.endingIn = nil
        state.refreshSpeakers()
        if line.speaker == .them { joinTurn(line) }
        if state.lines.count - linesAtNames >= 20 { guessNames() }
        writeNotesIfDue()
    }

    // MARK: - Who's speaking

    /// Asks the meeting's AI for the names in what's said, when some voice has no name of yours or the library's;
    /// `force` at the end of the meeting. A voice is named only when it says its own name on its own line
    /// (`MeetingNameGuess.read`); the other names heard are offered when you name someone.
    @discardableResult
    private func guessNames(force: Bool = false) -> Task<Void, Never>? {
        guard namesTask == nil, let router = router(),
              let content = MeetingNameGuess.content(state.lines, numbers: state.numbers, names: state.names,
                                                     start: state.started, roster: roster) else { return nil }
        // An answer being written goes first (a model on this Mac does one thing at a time); names can wait.
        guard force || (state.lines.count - linesAtNames >= 20 && answerTask == nil) else { return nil }
        linesAtNames = state.lines.count
        let lines = state.lines, numbers = state.numbers, start = state.started
        let task = Task { [weak self] in
            defer { self?.namesTask = nil }
            let reply: String
            do {
                reply = ModelOutput.answer(try await Self.collect(router.write(
                    system: MeetingNameGuess.instruction + "\n\n" + content, prompt: "Reply with the JSON only.",
                    maxTokens: 400, thorough: false)))
            } catch {
                self?.log("meeting: speaker names: \(error.localizedDescription)")
                return
            }
            guard let self else { return }
            let (found, refuted) = MeetingNameGuess.read(reply, lines: lines, numbers: numbers, start: start)
            // Earlier conversation names that no longer hold go, as do names given without evidence.
            for (voice, name) in state.names where name.source == .conversation {
                if refuted[voice] == name.name || !MeetingNameGuess.holds(name, voice: voice, in: state.lines, start: start) {
                    state.names[voice] = nil
                }
            }
            for (voice, name) in found { setName(voice, name) }
            let people = MeetingNameGuess.people(reply)
            if !people.isEmpty, people != state.people { state.people = people }
            log("meeting: speaker names: \(found.count) said their own name, \(refuted.count) not kept, "
                + "\(people.count) names heard")
        }
        namesTask = task
        return task
    }

    /// Gives a voice a name unless it already has one from a higher source (you, then the library, the window, the
    /// conversation).
    private func setName(_ voice: Int, _ name: VoiceName) {
        let merged = VoiceName.merge(state.names[voice], name)
        guard merged != state.names[voice] else { return }
        state.names[voice] = merged
        state.refreshSpeakers()
    }

    /// Compares the call's voices with the ones you asked Murmur to remember, from everything heard of each so far
    /// and all together (one saved person is one voice): a clear match names the voice, a likely one is offered
    /// ("possibly Priya"). Done again as more is heard, so a name can arrive, or change, during the meeting; a name
    /// you gave is never touched.
    private func recognise() async {
        let profiles = VoiceLibrary.shared.profiles
        guard !profiles.isEmpty else { return }
        var prints = await voiceprints.prints()
        // Voices you named, and saved people you confirmed for a voice, are settled.
        for (voice, name) in state.names where name.source == .user { prints[voice] = nil }
        let settled = Set(confirmed.values)
        let matches = VoiceMatching.assign(prints, in: profiles.filter { !settled.contains($0.id) }, declined: declined)
        var found = confirmed
        for (voice, name) in state.names where name.source == .library && matches[voice]?.sure != true {
            state.names[voice] = nil
        }
        var offers: [Int: VoiceMatching.Match] = [:]
        for (voice, match) in matches {
            if match.sure {
                found[voice] = match.profile
                let name = VoiceName(name: match.name, source: .library,
                                     evidence: "\(Int((match.score * 100).rounded())) % like the voice you saved")
                if state.names[voice] != name {
                    if state.names[voice]?.name != match.name { log("meeting: a remembered voice is on the call") }
                    setName(voice, name)
                }
            } else {
                offers[voice] = match
            }
        }
        if state.suggestions != offers { state.suggestions = offers }
        state.profiles = found
        state.refreshSpeakers()
    }

    /// The meeting has ended: each remembered voice that was on the call learns from it.
    private func learnRememberedVoices() async {
        for (voice, profile) in state.profiles {
            let samples = await voiceprints.samples(voice)
            guard let print = VoiceMatching.enroll(samples) else { continue }
            VoiceLibrary.shared.learn(profile, print: print, samples: samples.count)
        }
    }

    /// You named a voice (an empty name: "Not them", it shows as Speaker N).
    func rename(_ voice: Int, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.names[voice] = VoiceName(name: name, source: .user)
        state.suggestions[voice] = nil
        state.refreshSpeakers()
        log("meeting: you named a voice")
    }

    /// You said two voices are one person: `from`'s lines become `into`'s.
    func merge(_ from: Int, into: Int) {
        guard from != into else { return }
        joined(from, into: into)
        Task { [weak self, voiceprints] in
            await voiceprints.merge(from, into: into)
            await self?.recognise()
        }
        log("meeting: you merged two voices")
    }

    /// Two voices are one (you said so, or their voiceprints came together): `from`'s lines, name and saved-voice
    /// match become `into`'s.
    private func joined(_ from: Int, into: Int) {
        for index in state.lines.indices where state.lines[index].voice == from { state.lines[index].voice = into }
        if let name = state.names[from] { state.names[into] = VoiceName.merge(name, state.names[into] ?? name) }
        state.names[from] = nil
        state.suggestions[from] = nil
        if confirmed[into] == nil, let profile = confirmed[from] { confirmed[into] = profile }
        confirmed[from] = nil
        if state.profiles[into] == nil, let profile = state.profiles[from] { state.profiles[into] = profile }
        state.profiles[from] = nil
        if lastVoice?.voice == from { lastVoice?.voice = into }
        state.refreshSpeakers()
    }

    /// Yes or no to "possibly Priya".
    func answerSuggestion(_ voice: Int, yes: Bool) {
        guard let match = state.suggestions.removeValue(forKey: voice) else { return }
        guard yes else {
            declined.insert("\(voice) \(match.profile)")
            return
        }
        confirmed[voice] = match.profile
        state.profiles[voice] = match.profile
        setName(voice, VoiceName(name: match.name, source: .user))
    }

    /// Why a voice can't be remembered yet, or nil when it can.
    func cantRemember(_ voice: Int) async -> String? {
        guard let name = state.names[voice]?.name, !name.isEmpty else { return "Name this person first." }
        let stretches = await voiceprints.samples(voice)
        if VoiceMatching.enroll(stretches) == nil {
            return "Murmur needs to hear a bit more of them: at least 3 sentences, about 6 seconds."
        }
        return nil
    }

    /// Remembers a named voice, so later meetings recognise it. Returns what to tell you.
    func remember(_ voice: Int) async -> String {
        if let why = await cantRemember(voice) { return why }
        guard let name = state.names[voice]?.name else { return "Name this person first." }
        let stretches = await voiceprints.samples(voice)
        guard let print = VoiceMatching.enroll(stretches),
              let profile = VoiceLibrary.shared.remember(name: name, print: print, samples: stretches.count) else {
            return "Couldn't remember this voice."
        }
        confirmed[voice] = profile.id
        state.profiles[voice] = profile.id
        state.names[voice] = VoiceName(name: name, source: .user)
        state.refreshSpeakers()
        log("meeting: a voice was remembered")
        return "Murmur will recognise \(name) in your next meetings."
    }

    // MARK: - Turn-taking

    private func joinTurn(_ line: MeetingLine) {
        // Still talking during the answer, or carrying on within three seconds of it: the answer was early, so it's
        // written again for the whole turn.
        let continuing = !answeredTurn.isEmpty && state.autoAnswer
            && (answerTask != nil || answeredAt.map { line.at.timeIntervalSince($0) < 3 } ?? false)
        if continuing, turn.isEmpty {
            answerTask?.cancel()
            answerTask = nil
            turn = answeredTurn
            state.replaceNext = true
            log("meeting: they carried on; answering again")
        }
        turn.append(line)
        // With auto answer off, the turn is only what Answer now would answer: their last few lines.
        if !state.autoAnswer, turn.count > 4 { turn.removeFirst(turn.count - 4) }
        turnChanged = Date()
        turnRevision += 1
    }

    /// Four times a second: the level meters, and whether a turn is ready to answer.
    ///
    /// Once they've paused: a last line that plainly asks something is answered at once. Otherwise a cloud AI
    /// decides from the conversation whether they asked the user something ("answer"), are still asking ("wait"), or
    /// said nothing for the user to answer ("no"), so questions without a question mark or in an unusual shape
    /// ("I'd love to hear how you handled the outage") are answered too. With a model on this Mac, a pause decides.
    private func tick() {
        state.setLevels(call: callFeed?.level ?? 0, mic: micFeed?.level ?? 0)
        endIfSilent()
        guard state.autoAnswer, !turn.isEmpty, answerTask == nil, !checking else { return }
        let quiet = Date().timeIntervalSince(turnChanged)
        // Wait for them to stop (a call that never goes quiet, like background noise, doesn't hold it up for long).
        if callFeed?.speaking == true, quiet < 4 { return }
        // Their line arrives once they've paused (0.6 s) and it's been transcribed: a further 0.6 s of quiet.
        guard quiet >= 0.6 else { return }
        let text = turn.map(\.text).joined(separator: " ")
        let asks = turn.contains { MeetingText.isQuestion($0.text) } || MeetingText.isQuestion(text)
        if let last = turn.last, MeetingText.isQuestion(last.text) {
            fire(turn, replace: state.consumeReplace())
            return
        }
        guard let router = router() else { return }
        if router is OllamaRouter {
            if asks, quiet >= 1.5 {
                fire(turn, replace: state.consumeReplace())
            } else if quiet >= 8 {
                log("meeting: not answering (no question heard): \"\(text.prefix(80))\"")
                turn = []
            }
            return
        }
        if checkedRevision == turnRevision {
            if lastVerdict == "wait", quiet >= 3 { fire(turn, replace: state.consumeReplace()) }
            if lastVerdict == "no", quiet >= 8 { turn = [] }
            return
        }
        // Too little to be a question ("Okay.", "Right, yes."): wait for more, then let it go.
        guard asks || MeetingText.substantiveWords(turn) >= 4 else {
            if quiet >= 8 { turn = [] }
            return
        }
        checking = true
        checkedRevision = turnRevision
        lastVerdict = nil
        let revision = turnRevision
        let user = "Conversation so far (newest last):\n\(MeetingText.transcript(state.lines, limit: 4_000, label: state.label))\n\n"
            + "What the other side said since the last answer: \"\(text)\""
        Task { [weak self] in
            let verdict = await router.choose(system: Self.decideSystem, user: user, field: "decision",
                                              options: ["answer", "wait", "no"], timeout: 3)
            guard let self else { return }
            checking = false
            guard revision == turnRevision, !turn.isEmpty, answerTask == nil else { return }
            lastVerdict = verdict
            switch verdict {
            case "answer":
                fire(turn, replace: state.consumeReplace())
            case "wait":
                log("meeting: they're still asking")
            case "no":
                log("meeting: nothing to answer: \"\(text.prefix(80))\"")
            default:
                // No verdict (the check failed or timed out): answer what looks like a question.
                if asks { fire(turn, replace: state.consumeReplace()) }
            }
        }
    }

    /// A meeting you started yourself (a call in a browser, the room) ends after `silentMinutes` with no words from
    /// anyone, after a 30 s countdown in the panel; words, not sound, keep it going, so hold music doesn't. A meeting
    /// Murmur started because a meeting app turned on its microphone ends when that app lets go instead.
    private func endIfSilent() {
        guard state.running, !automatic, Self.silentMinutes > 0 else { return }
        let left = Int((Double(Self.silentMinutes) * 60 + 30 - Date().timeIntervalSince(lastWords)).rounded(.up))
        if left > 30 {
            if state.endingIn != nil { state.endingIn = nil }
            return
        }
        if left <= 0 {
            log("meeting: nobody spoke for \(Self.silentMinutes) minutes; ended")
            stop()
            return
        }
        if state.endingIn != left { state.endingIn = left }
    }

    /// Keep going: the silence countdown starts again.
    func keepGoing() {
        lastWords = Date()
        state.endingIn = nil
    }

    static let silentMinutesKey = "meeting.silentMinutes"
    /// Minutes without words before a meeting you started yourself ends (0: never). 10 unless set.
    public static var silentMinutes: Int {
        get { UserDefaults.standard.object(forKey: silentMinutesKey) as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: silentMinutesKey) }
    }

    /// Writes an answer for `lines` into the panel (a new one, or over the last when they carried on).
    /// `screen`: look at the meeting's screen too (also when the question is about it: "this chart", "the slide").
    private func fire(_ lines: [MeetingLine], replace: Bool, screen: Bool = false) {
        let asked = lines.map(\.text).joined(separator: " ")
        if !lines.isEmpty {
            log(String(format: "meeting: answering %.1f s after their last line came in", Date().timeIntervalSince(turnChanged)))
        }
        answeredTurn = lines
        answeredAt = nil
        turn = []
        respond(.answer, question: asked.isEmpty ? "What's on the screen?" : asked,
                request: asked.isEmpty
                    ? "Nobody has asked anything yet: say what's being shown on the meeting's screen and what the user "
                        + "could say about it."
                    : "What the other side just asked: \"\(asked)\"",
                screen: screen || MeetingText.refersToScreen(asked), replace: replace)
    }

    /// A streamed reply, whole.
    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await piece in stream { text += piece }
        return text
    }

    // MARK: - Follow-up email

    /// Drafts a follow-up email from the notes (after the meeting): thanks, what was decided, who does what, the next
    /// step. Shown under Notes, and added to the saved notes file.
    func draftEmail() {
        guard let router = router(), !state.draftingEmail, !(state.notesText.isEmpty && state.lines.isEmpty) else { return }
        state.draftingEmail = true
        log("meeting: drafting a follow-up email")
        var prompt = contextText.isEmpty ? "" : "\(contextText)\n\n"
        prompt += state.notesText.isEmpty
            ? "The meeting (newest last):\n\(MeetingText.transcript(state.lines.filter { MeetingText.isSubstantive($0.text) }, label: state.label))"
            : "The meeting's notes:\n\(state.notesText)"
        Task { [weak self] in
            guard let self else { return }
            defer { state.draftingEmail = false }
            do {
                let reply = ModelOutput.answer(try await Self.collect(router.write(system: Self.emailSystem,
                                                                                   prompt: prompt, maxTokens: 1_500,
                                                                                   thorough: true)))
                let email = MeetingText.email(reply)
                state.email = MeetingEmail(subject: email.subject, body: email.body)
                if let saved = state.saved, let handle = try? FileHandle(forWritingTo: saved) {
                    handle.seekToEndOfFile()
                    handle.write(Data("\n## Follow-up email\n\n**Subject:** \(email.subject)\n\n\(email.body)\n".utf8))
                    try? handle.close()
                }
            } catch {
                state.problem = "Couldn't draft the email: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Quick actions (the panel's buttons and the Ask box)

    /// What to say next, from where the conversation is now (no question needed).
    func whatToSay() {
        log("meeting: what should I say")
        respond(.sayNext, question: "What should I say?",
                request: "Nobody asked the user anything directly. From where the conversation is now, suggest what the "
                    + "user could say next to move it forward or add something useful.", screen: false, replace: false)
    }

    /// Sharp questions the user could ask now.
    func followUpQuestions() {
        log("meeting: follow-up questions")
        respond(.followUps, question: "Follow-up questions",
                request: "Suggest questions the user could ask now.", screen: false, replace: false)
    }

    /// The meeting so far, for when you lost the thread.
    func recap() {
        log("meeting: recap")
        respond(.recap, question: "Recap so far", request: "Recap the meeting so far.", screen: false, replace: false,
                transcriptLimit: 20_000)
    }

    /// A question you type: asked privately, answered with the meeting (and its screen, when it's about it).
    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        log("meeting: asked")
        respond(.asked, question: question,
                request: "The user asks you privately (they didn't say this in the meeting): \"\(question)\"",
                screen: MeetingText.refersToScreen(question), replace: false)
    }

    /// Writes a reply of `kind` into the panel: the meeting's context and conversation, the request, and (with
    /// `screen`) a picture or the text of the meeting's screen.
    private func respond(_ kind: MeetingAnswer.Kind, question: String, request: String, screen looks: Bool,
                         replace: Bool, transcriptLimit: Int = 12_000) {
        guard let router = router() else { return }
        answerTask?.cancel()
        let index = replace ? state.restartLastAnswer(question: question)
            : state.beginAnswer(question: question, kind: kind)
        // All of the meeting's context and documents, and a long stretch of the conversation: complete, precise
        // answers first.
        var base = contextText.isEmpty ? "" : "\(contextText)\n\n"
        base += "Conversation so far (newest last):\n\(MeetingText.transcript(state.lines, limit: transcriptLimit, label: state.label))\n\n"
        base += request
        let system = kind.system
        let bundle = appBundle
        let opening = base
        answerTask = Task { [weak self] in
            guard let self else { return }
            var prompt = opening
            var image: Data?
            if looks {
                state.markScreen(index, looking: true)
                if let picture = await MeetingScreen.capture(bundle: bundle) {
                    if router.looksAtImages {
                        image = picture.jpeg
                        prompt += "\n\nA picture of the meeting's screen is attached (\(picture.title)): what's being "
                            + "shown or shared now. Use it when the question is about what's on it."
                        log("meeting: looked at the screen (a picture, to \(router.name))")
                    } else if let text = ScreenControl.recognise(picture.image) {
                        prompt += "\n\nText read from the meeting's screen (\(picture.title)), top to bottom; charts and "
                            + "pictures aren't described, only their words and numbers:\n\(text.prefix(6_000))"
                        log("meeting: looked at the screen (its text, read on this Mac)")
                    }
                } else {
                    state.problem = "Couldn't see the meeting's screen. Allow Murmur under System Settings › Privacy & "
                        + "Security › Screen & System Audio Recording."
                    log("meeting: couldn't capture the screen")
                }
                guard !Task.isCancelled else { return }
                state.markScreen(index, looking: false)
            }
            await write(router: router, system: system, prompt: prompt, image: image, into: index)
            guard !Task.isCancelled else { return }
            if kind == .answer { answeredAt = Date() }
            answerTask = nil
            writeNotesIfDue()
        }
    }

    /// Streams the model's answer into answer `index`.
    private func write(router: Router, system: String, prompt: String, image: Data? = nil, into index: Int) async {
        var text = ""
        let started = Date()
        var first: TimeInterval?
        do {
            for try await piece in router.write(system: system, prompt: prompt, image: image, maxTokens: 3_000,
                                                thorough: true) {
                if Task.isCancelled { return }
                if first == nil {
                    first = Date().timeIntervalSince(started)
                }
                text += piece
                state.updateAnswer(index, text: text)
            }
            state.updateAnswer(index, text: ModelOutput.answer(text), done: true)
            announce(index)
            log(String(format: "meeting: answered (%@): first words in %.1f s, done in %.1f s, %d characters of prompt",
                       router.name, first ?? 0, Date().timeIntervalSince(started), prompt.count))
        } catch {
            guard !Task.isCancelled else { return }
            state.updateAnswer(index, text: text, done: true)
            state.problem = "Couldn't draft an answer: \(error.localizedDescription)"
            log("meeting: answer failed: \(error.localizedDescription)")
        }
    }

    /// VoiceOver reads a finished answer out (when it's running); a hidden panel's pill lights up.
    private func announce(_ index: Int) {
        guard state.answers.indices.contains(index) else { return }
        if state.collapsed { state.unread = true }
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let say = state.answers[index].spoken.spokenText
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Answer ready. \(say)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Notes

    private var contextText: String {
        MeetingText.context(about: state.about, instructions: state.instructions,
                            documents: state.documents.map { ($0.name, $0.text) })
    }

    /// Every minute or so of new talk, when no answer is being written (a model on this Mac does one thing at a time).
    /// When enough of substance has been said since the last update: about a paragraph's worth (80 words, not small
    /// talk) after a minute and a half, or a lot (250 words) after 45 seconds.
    private func writeNotesIfDue() {
        guard state.running, notesTask == nil, answerTask == nil, linesAtNotes <= state.lines.count else { return }
        let words = MeetingText.substantiveWords(state.lines[linesAtNotes...])
        let since = Date().timeIntervalSince(lastNotes)
        guard (words >= 80 && since >= 90) || (words >= 250 && since >= 45) else { return }
        notesTask = Task { [weak self] in
            await self?.writeNotes(final: false)
            self?.notesTask = nil
        }
    }

    /// Updates the notes from what's new since the last update (the final notes read the whole meeting again).
    /// Small talk and call logistics are left out of what the AI reads; it can answer NO CHANGE.
    private func writeNotes(final: Bool) async {
        guard let router = router() else { return }
        let start = min(linesAtNotes, state.lines.count)
        linesAtNotes = state.lines.count
        lastNotes = Date()
        let substantive = state.lines.filter { MeetingText.isSubstantive($0.text) }
        let earlier = state.lines[..<start].filter { MeetingText.isSubstantive($0.text) }
        let fresh = state.lines[start...].filter { MeetingText.isSubstantive($0.text) }
        guard final ? !substantive.isEmpty : !fresh.isEmpty else { return }
        state.writingNotes = true
        defer { state.writingNotes = false }
        var prompt = contextText.isEmpty ? "" : "\(contextText)\n\n"
        prompt += speakersNote
        if final {
            prompt += state.notesText.isEmpty ? "" : "Notes taken during the meeting:\n\(state.notesText)\n\n"
            prompt += "The whole meeting (newest last):\n\(MeetingText.transcript(substantive, limit: 30_000, label: state.label))\n\n"
            prompt += "The meeting has ended. Write the final notes from the whole meeting, with a title line (# …) "
                + "naming what it was actually about."
        } else {
            prompt += state.notesText.isEmpty ? "No notes yet.\n\n" : "Notes so far:\n\(state.notesText)\n\n"
            if !earlier.isEmpty {
                prompt += "Just before, for context (already in the notes):\n"
                    + "\(MeetingText.transcript(Array(earlier.suffix(6)), limit: 1_500, label: state.label))\n\n"
            }
            prompt += "New since the notes were last updated:\n\(MeetingText.transcript(fresh, limit: 10_000, label: state.label))\n\n"
            prompt += "Update the notes with what's new and worth keeping, and reply with the whole notes. If nothing "
                + "new is worth noting, reply exactly: NO CHANGE"
        }
        do {
            // The final notes cover the whole meeting: room for a long one, so they don't stop mid-sentence.
            let reply = ModelOutput.answer(try await Self.collect(router.write(system: Self.notesSystem, prompt: prompt,
                                                                               maxTokens: final ? 8_000 : 3_000,
                                                                               thorough: true)))
            if !final, MeetingText.isNoChange(reply) {
                log("meeting: notes: nothing new worth noting")
                return
            }
            state.setNotes(reply)
            log("meeting: notes \(final ? "finished" : "updated") from \(final ? substantive.count : fresh.count) lines")
        } catch {
            state.problem = "Couldn't write the notes: \(error.localizedDescription)"
            log("meeting: notes failed: \(error.localizedDescription)")
        }
    }

    /// Who the transcript's labels are, for the notes: the labels in use now, so a label from earlier notes that has
    /// since changed (a voice got a name, two voices turned out to be one person) isn't carried on.
    private var speakersNote: String {
        var labels: [String] = []
        for line in state.lines {
            let label = state.label(line)
            if !labels.contains(label) { labels.append(label) }
        }
        guard labels.count > 1 else { return "" }
        return "The speakers, as labelled in the transcript now: \(labels.joined(separator: ", ")). Notes written "
            + "earlier may use a label that isn't in this list any more: say who it is from the transcript, or leave "
            + "the name out.\n\n"
    }

    /// Where meeting notes are saved: Documents › Murmur Meetings.
    public static var folder: URL? {
        // Debug runs (`-debugMeetingsFolder FOLDER`) keep their meetings out of yours.
        if let debug = UserDefaults.standard.string(forKey: "debugMeetingsFolder") {
            return URL(fileURLWithPath: (debug as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Murmur Meetings", isDirectory: true)
    }

    private func save() {
        guard let folder = Self.folder else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let name = "\(stamp.string(from: state.started)) \(state.app ?? "Meeting").md"
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var text = state.notesText.isEmpty ? "# Meeting notes\n" : state.notesText
        text += "\n\n## Transcript\n\n"
        text += state.lines.map { "**\(time.string(from: $0.at)) \(state.label($0)):** \($0.text)" }
            .joined(separator: "\n\n")
        text += "\n"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
            try text.write(to: url, atomically: true, encoding: .utf8)
            state.saved = url
            log("meeting: notes saved to \(folder.lastPathComponent)/\(url.lastPathComponent)")
        } catch {
            state.problem = "Couldn't save the notes: \(error.localizedDescription)"
        }
        // The meeting as data too (lines, voices and names), for what comes next: playing a line back, renaming
        // speakers afterwards, notes that point at lines.
        if let root = MeetingRecord.folder {
            let record = MeetingRecord(started: state.started, ended: Date(), app: state.app, about: state.about,
                                       lines: state.lines, numbers: state.numbers, names: state.names,
                                       notes: state.notesText)
            do {
                lastRecord = try record.write(under: root)
            } catch {
                log("meeting: couldn't keep the meeting's record: \(error.localizedDescription)")
            }
        }
    }

    /// Where the last meeting's record went (debug runs print it).
    private(set) var lastRecord: URL?

    // MARK: - Debug

    /// `-debugMeeting FOLDER`: plays its recordings (by name, in order) through the meeting as if they'd been heard:
    /// "NN-you-…" as your microphone, anything else as the call ("NN-them-person": the person is who really spoke,
    /// for checking). Each is transcribed, given a voice, checked for echo, then the names are asked for and the notes
    /// written, as at the end of a meeting, and the record saved. Nothing is captured from the Mac.
    /// `voicesOnly`: no transcription, names from the conversation or notes (a simulation of many meetings, where only
    /// who is told apart and recognised matters): every recording counts as a real sentence.
    /// `nameRest`: voices on show that nothing named get the name you'd type; `remember`: these people's voices are
    /// then remembered, as the button would.
    @discardableResult
    public func runScript(_ files: [URL], voicesOnly: Bool = false, nameRest: Bool = false,
                          remember keep: [String] = []) async -> URL? {
        guard !state.running, !state.finishing else { return nil }
        state.reset()
        state.app = "Scripted meeting"
        speech = Self.speechChoice.hasKey ? Self.speechChoice : .dictation
        nextID = 0
        linesAtNotes = 0
        // Voices only: the conversation isn't real, so it isn't asked for names.
        linesAtNames = voicesOnly ? Int.max / 2 : 0
        lastVoice = nil
        stretchOfLine = [:]
        micHeard = [:]
        confirmed = [:]
        declined = []
        roster = []
        await voiceprints.reset()
        do { try await voiceprints.prepare() } catch { log("meeting script: no voice model: \(error)") }
        var at = state.started
        // Who really said each line kept ("03-them-emma": emma).
        var said: [Int: String] = [:]
        for file in files {
            guard let samples = AudioFile16k.read(file) else {
                log("meeting script: couldn't read \(file.lastPathComponent)")
                continue
            }
            let parts = file.deletingPathExtension().lastPathComponent.lowercased().split(separator: "-").map(String.init)
            let speaker: MeetingLine.Speaker = parts.contains("you") ? .you : .them
            let piece = MeetingPiece(speaker: speaker, samples: samples, at: at)
            let before = nextID
            if voicesOnly {
                await heard(piece, "this is sentence number \(nextID + 1) of the meeting")
            } else {
                await transcribe(piece)
            }
            at = at.addingTimeInterval(Double(samples.count) / 16_000 + 0.5)
            if nextID > before, speaker == .them, parts.count >= 3 { said[before] = parts[2] }
            if !voicesOnly {
                let line = state.lines.last.map { "\(state.label($0)) (voice \($0.voice.map(String.init) ?? "-")): \($0.text)" }
                log("meeting script: \(file.deletingPathExtension().lastPathComponent) │ \(line ?? "(nothing kept)")")
            }
        }
        if !voicesOnly {
            await notesTask?.value
            await namesTask?.value
            await guessNames(force: true)?.value
        }
        // Whose lines each voice ended up with (after any merging), and the lines left without a voice.
        var spoke: [Int: [String: Int]] = [:], unvoiced: [String: Int] = [:]
        for line in state.lines {
            guard let person = said[line.id] else { continue }
            if let voice = line.voice { spoke[voice, default: [:]][person, default: 0] += 1 } else { unvoiced[person, default: 0] += 1 }
        }
        for (voice, people) in spoke.sorted(by: { $0.key < $1.key }) {
            let shown = state.numbers[voice] != nil || state.single == voice
            log("meeting script: final voice \(voice) \(shown ? "shown" : "hidden") = "
                + people.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
        }
        if !unvoiced.isEmpty {
            log("meeting script: final no voice = " + unvoiced.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
                .joined(separator: " "))
        }
        // What the voice library said before anything is named by hand.
        for (voice, name) in state.names.sorted(by: { $0.key < $1.key }) {
            log("meeting script: voice \(voice) → \(name.name.isEmpty ? "(none)" : name.name) [\(name.source.rawValue)]"
                + (name.evidence.map { " \($0)" } ?? ""))
        }
        for (voice, maybe) in state.suggestions.sorted(by: { $0.key < $1.key }) {
            log("meeting script: voice \(voice) is possibly \(maybe.name) (\(Int(maybe.score * 100)) %)")
        }
        await learnRememberedVoices()
        if nameRest {
            for voice in spoke.keys.sorted() where (state.names[voice]?.name ?? "").isEmpty
                && (state.numbers[voice] != nil || state.single == voice) {
                guard let person = spoke[voice]?.max(by: { $0.value < $1.value })?.key else { continue }
                rename(voice, to: person.prefix(1).uppercased() + person.dropFirst())
                log("meeting script: voice \(voice) named by hand: \(person)")
            }
        }
        let wanted = keep.map { $0.lowercased() }
        for (voice, name) in state.names.sorted(by: { $0.key < $1.key }) where wanted.contains(name.name.lowercased())
            && state.profiles[voice] == nil {
            let told = await remember(voice)
            log("meeting script: remember \(name.name): \(told)")
        }
        if !voicesOnly {
            await writeNotes(final: true)
            save()
        }
        log("meeting script: done, \(state.lines.count) lines, record at \(lastRecord?.path ?? "-")")
        return voicesOnly ? nil : lastRecord
    }

    /// Adds documents to the meeting's context (up to five), read on this Mac.
    func addDocuments() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.message = "Documents for this meeting: an agenda, a spec, notes"
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK else { return }
        for url in open.urls where state.documents.count < 5 {
            guard !state.documents.contains(where: { $0.url == url }) else { continue }
            if let text = MeetingDocuments.text(url) {
                state.documents.append(MeetingDocument(url: url, text: text))
            } else {
                state.problem = "Couldn't read the text in \(url.lastPathComponent)."
            }
        }
    }

    static let answerSystem = """
        You help the user during a live meeting or call. In the transcript, "You" is the user and the other people are \
        "Them", "Speaker 1", "Speaker 2" or their names; it's speech-to-text, so expect misheard words. The user glances at your answer and says it out \
        loud, live, so it must be quick to scan and natural to say, and complete, precise and correct. Reply in \
        exactly this shape, plain text, no preamble; use **bold** only for the one or two key words in a line:
        ANSWER: the direct answer in one short sentence the user can say first, in the first person.
        POINTS:
        - the rest of the answer, two to six bullets in the order you'd say them: the reasoning or how it works, the \
        specifics (facts, numbers, names, steps), and the trade-offs or caveats that matter. Each bullet is one \
        short spoken sentence (about 8 to 20 words) that starts with its key idea. Cover every part of the question \
        (if they asked two things, answer both, in the order asked), and get every fact, number, name, definition \
        and technical detail exactly right. Nothing generic, no filler, no stock openers ("Great question", \
        "Certainly"). A quick factual question may need only one or two points.
        EXAMPLE: one short concrete example, only when it makes the answer clearer.
        CODE: only when the question asks for code (write or fix a function, a query, a command) or a problem on \
        the screen needs it: the complete code in one fenced block with its language (```python), working as \
        written, with short comments only where they help. Then the POINTS walk through the approach out loud: the \
        idea, why it works, and its time and space cost, not the code line by line.
        ALSO:
        - two or three short bullets: a point to add, a follow-up, or a question back (for code: an edge case, \
        another approach, or how to test it).
        Use the meeting's context and documents when they're given, what was said, and general knowledge. If the \
        answer depends on facts you don't have (numbers, dates, the user's own experience), say in a point what to \
        check or fill in rather than inventing it. When a picture or the text of the meeting's screen comes with \
        the question, answer from what it shows (read charts' numbers and trends, slides' points) and say which \
        part you mean. Follow the user's instructions when they're given.
        """

    static let followUpSystem = """
        You help the user during a live meeting or call. In the transcript, "You" is the user and the other people are \
        "Them", "Speaker 1", "Speaker 2" or their names; it's speech-to-text, so expect misheard words. Suggest questions the user could ask now: sharp, \
        specific to what was actually said, the kind a thoughtful person would ask to clarify, go deeper or move \
        things forward. Reply in exactly this shape, plain text, **bold** only for a key word:
        ANSWER: one short sentence on what's worth digging into right now.
        ALSO:
        - three to five questions, each short and ready to ask out loud as written.
        Use the meeting's context when given. No generic questions that would fit any meeting.
        """

    static let recapSystem = """
        You help the user during a live meeting or call. In the transcript, "You" is the user and the other people are \
        "Them", "Speaker 1", "Speaker 2" or their names; it's speech-to-text, so expect misheard words. Recap the meeting so far for someone who lost the \
        thread for a few minutes. Reply in exactly this shape, plain text, **bold** only for key words:
        ANSWER: what the meeting is about, in one short sentence.
        POINTS:
        - what's been covered, in order, one short bullet per topic, with the specifics (names, numbers, decisions), \
        ending with where the conversation is right now.
        ALSO:
        - decisions, commitments and open questions so far, one short bullet each.
        Skip small talk and logistics. No generic lines.
        """

    static let emailSystem = """
        Write the follow-up email the user sends after this meeting, from them to the people they met. Warm, short \
        and specific, in their voice: thank them in one line, then what was agreed, who's doing what and by when \
        (only what was actually said), and the next step. Plain text, short paragraphs or a few bullets, no \
        placeholders except [Name] for a greeting you can't know. Reply in exactly this shape:
        Subject: a specific subject line
        (blank line)
        the email
        """

    static let decideSystem = """
        You watch a live meeting transcript (speech-to-text, so expect misheard words and missing punctuation). \
        "You" is the user; the other people are "Them", "Speaker 1", "Speaker 2" or their names. Decide one thing about what the other side said since the \
        last answer:
        "answer": they asked the user something, or asked them to explain, describe, show or do something (however \
        it's phrased: "tell me about…", "I'd love to hear how you…", "walk us through…", "what's your take"), and \
        they've finished asking.
        "wait": they're plainly still in the middle of asking (the sentence breaks off, or they're listing parts).
        "no": nothing for the user to answer: a statement, small talk, or talking to someone else.
        """

    static let finishedSystem = """
        You watch a live meeting transcript (speech-to-text) and decide one thing: has the other side finished \
        asking their question, so it's time to answer ("finished"), or are they plainly still in the middle of it \
        ("still asking": the sentence breaks off, or they've started listing parts and haven't finished)? When \
        unsure, say "finished".
        """

    static let notesSystem = """
        You are an excellent note-taker sitting in on the user's meeting. In the transcript, "You" is the user and the \
        other people are "Them", "Speaker 1", "Speaker 2" or their names; it's speech-to-text, so fix obvious mishearings from context and ignore \
        fragments that make no sense.
        Say who said or will do something only by the label on their lines, exactly as written. Never work out a \
        name for "Speaker 2" or "Them" from what others call them, never give anyone a gender, role or title that \
        wasn't stated, and never credit the user ("You") with a point from someone else's line. When it isn't \
        clear who said something, state the point without a name.
        Note only what someone would want to look back at: what was decided, who will do what and by when, the \
        facts, numbers, names, dates and terms that came up, problems raised and how they were resolved, and \
        questions left open. Leave out small talk, greetings, audio and screen-sharing logistics, filler, repeats, \
        and anything said only in passing. Never write generic lines like "The team discussed the project" or "They \
        talked about next steps": every bullet states the actual point, in a few plain words, with the specifics.
        Shape the notes to what the meeting actually is:
        - an interview: "## Questions asked", each question with the gist of how the user answered and anything the \
        interviewer reacted to; then "## About the role and team" for what they told the user; then "## Follow-ups".
        - a working meeting or stand-up: "## Decisions", "## Action items" ("- [ ] Who: what, by when if said"), \
        then a "##" section per real topic, named after it, and "## Open questions".
        - a call with a customer or partner: "## Their needs", "## Concerns", "## What we offered", "## Next steps".
        Leave out any section with nothing in it. Use the meeting's context when it's given. Short, specific \
        bullets. Reply with the notes only, in Markdown.
        """
}

/// One stretch of speech, ready to transcribe.
struct MeetingPiece: Sendable {
    let speaker: MeetingLine.Speaker
    let samples: [Float]
    let at: Date
    /// One person's part of a stretch that held several (`SpeakerTurns`), and whether it's the first of them.
    var afterChange = false
    var first = true
}

/// One side's sound on its way to the transcript: cut into stretches of speech, each turned to 16 kHz and sent on.
final class MeetingFeed: @unchecked Sendable {
    let speaker: MeetingLine.Speaker
    private let rate: Double
    private let send: @Sendable (MeetingPiece) -> Void
    private let lock = NSLock()
    private var segmenter: MeetingSegmenter
    private var sound = false
    private var finished = false
    private var isMuted = false
    private let work = DispatchQueue(label: "murmur.meeting.pieces", qos: .utility)

    init(speaker: MeetingLine.Speaker, rate: Double, send: @escaping @Sendable (MeetingPiece) -> Void) {
        self.speaker = speaker
        self.rate = rate
        self.send = send
        segmenter = MeetingSegmenter(rate: rate)
    }

    /// Whether anything but digital silence has come in.
    var heardSound: Bool { lock.withLock { sound } }
    /// Someone on this side is speaking now.
    var speaking: Bool { lock.withLock { !isMuted && segmenter.isSpeaking } }
    /// The current loudness, 0…1, for the meter.
    var level: Float { lock.withLock { isMuted ? 0 : segmenter.level } }

    /// Muted: nothing from this side goes into the notes (what was being said is dropped).
    var muted: Bool {
        get { lock.withLock { isMuted } }
        set {
            lock.withLock {
                isMuted = newValue
                if newValue { _ = segmenter.flush() }
            }
        }
    }

    /// On the audio thread: only the cutting happens here; the rest on a queue of its own.
    func add(_ samples: [Float]) {
        let (done, held): ([[Float]], Double) = lock.withLock {
            guard !finished, !isMuted else { return ([], 0) }
            if !sound, samples.contains(where: { abs($0) > 1e-5 }) { sound = true }
            let done = segmenter.add(samples)
            return (done, segmenter.held)
        }
        for (index, piece) in done.enumerated() { deliver(piece, held: index == done.count - 1 ? held : 0) }
    }

    /// What was still being said when the meeting stopped.
    func finish() {
        let last: [Float]? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return isMuted ? nil : segmenter.flush()
        }
        if let last { deliver(last) }
    }

    /// `held`: sound that came after the piece and is already waiting for the next one (a long piece is cut at its
    /// last pause, not where it ends), so the piece began that much earlier.
    private func deliver(_ piece: [Float], held: Double = 0) {
        let at = Date().addingTimeInterval(-held - Double(piece.count) / rate)
        let rate = self.rate, speaker = self.speaker, send = self.send
        work.async {
            let samples = rate == 16_000 ? piece : ((try? AudioConverter().resample(piece, from: rate)) ?? [])
            guard !samples.isEmpty else { return }
            send(MeetingPiece(speaker: speaker, samples: samples, at: at))
        }
    }
}

/// A follow-up email drafted after the meeting.
struct MeetingEmail: Equatable {
    var subject: String
    var body: String
}

/// A document given to the meeting, with its text.
struct MeetingDocument: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let text: String
    var name: String { url.lastPathComponent }
}

/// One drafted answer.
struct MeetingAnswer: Identifiable, Equatable {
    /// What was asked for: an answer to the other side, or one of the panel's quick actions.
    enum Kind {
        case answer, sayNext, followUps, recap, asked

        /// The heading over the extra points.
        var alsoTitle: String {
            switch self {
            case .followUps: return "Questions you could ask"
            case .recap: return "Decisions and open questions"
            default: return "You could also say"
            }
        }

        @MainActor var system: String {
            switch self {
            case .followUps: return MeetingMode.followUpSystem
            case .recap: return MeetingMode.recapSystem
            default: return MeetingMode.answerSystem
            }
        }
    }

    let id: Int
    var question: String
    var text: String
    var blocks: [MarkdownBlocks.Block]
    var writing: Bool
    var kind: Kind = .answer
    /// The answer as it's read out: sentences to say, then extra points.
    var spoken = SpokenAnswer(say: [], also: [])
    /// The meeting's screen went with the question (a picture, or its text); `looking` while it's being captured.
    var usedScreen = false
    var looking = false
    /// Code (an answer from the screen): drawn as Markdown rather than as sentences.
    var hasCode: Bool { !spoken.code.isEmpty }

    static func == (a: MeetingAnswer, b: MeetingAnswer) -> Bool {
        a.id == b.id && a.question == b.question && a.text == b.text && a.writing == b.writing
            && a.usedScreen == b.usedScreen && a.looking == b.looking
    }
}

@MainActor
final class MeetingState: ObservableObject {
    enum Tab: Hashable { case live, notes, transcript, context }
    enum Sharing: Equatable { case unchecked, checking, hidden, visible, unknown }
    enum Layout: String { case card, strip }

    @Published var running = false
    @Published var finishing = false
    @Published var app: String?
    @Published var started = Date()
    @Published var lines: [MeetingLine] = []
    @Published var answers: [MeetingAnswer] = []
    /// Which answer is shown (the newest unless you stepped back).
    @Published var shown = 0
    @Published var notesText = ""
    @Published var notes: [MarkdownBlocks.Block] = []
    @Published var writingNotes = false
    @Published var problem: String?
    @Published var saved: URL?
    @Published var tab: Tab = .live
    @Published var copied = false
    @Published var autoAnswer = true
    @Published var micMuted = false
    /// How many voices on the call have spoken (MeetingVoices).
    @Published var voices = 0
    /// Voice → the name it's shown under, and where that came from (you, the voice library, the meeting app's
    /// window, the conversation). Voice → speaker number for the voices on show (`MeetingSpeakers.numbers`).
    @Published var names: [Int: VoiceName] = [:]
    @Published var numbers: [Int: Int] = [:]
    /// A remembered voice this one may be ("possibly Priya, 63 %"), waiting for a yes.
    @Published var suggestions: [Int: VoiceMatching.Match] = [:]
    /// Names heard in the conversation (the people taking part, as far as it shows): offered when you name a voice,
    /// never put on one by Murmur.
    @Published var people: [String] = []
    /// Voice → the remembered profile it was matched to (learns from this meeting when it ends).
    var profiles: [Int: UUID] = [:]
    /// A meeting you started yourself, nobody heard for a long while: seconds until it ends by itself.
    @Published var endingIn: Int?
    @Published var callLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var about = ""
    @Published var instructions = ""
    @Published var documents: [MeetingDocument] = []
    @Published var sharing: Sharing = .unchecked
    @Published var email: MeetingEmail?
    @Published var draftingEmail = false
    /// The AI for answers and notes (nil: the commands' AI).
    @Published var ai: RouterChoice?
    /// Who transcribes meetings (its own setting, apart from the AI).
    @Published var speech: MeetingMode.Speech = .dictation
    /// How the panel sits: a card beside the call, or a wide strip at the top of the screen, near the camera (your
    /// eyes stay close to it while you read an answer out).
    @Published var layout: Layout = Layout(rawValue: UserDefaults.standard.string(forKey: "meeting.layout") ?? "") ?? .card {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "meeting.layout") }
    }
    /// Folded into a small pill at the top of the screen; it lights up when an answer is ready.
    @Published var collapsed = false
    @Published var unread = false
    /// How see-through the window is while you're not pointing at it: 35 % to 100 %.
    @Published var opacity: Double = {
        let saved = UserDefaults.standard.double(forKey: "meeting.opacity")
        return saved >= 0.35 && saved <= 1 ? saved : 1
    }() {
        didSet { UserDefaults.standard.set(opacity, forKey: "meeting.opacity") }
    }
    /// Solid while the pointer is on it, so it's clear when you look; see-through otherwise.
    @Published var solidOnHover: Bool = UserDefaults.standard.object(forKey: "meeting.solidOnHover") as? Bool ?? true {
        didSet { UserDefaults.standard.set(solidOnHover, forKey: "meeting.solidOnHover") }
    }
    @Published var hovering = false
    /// The window's opacity now.
    var shownOpacity: Double { hovering && solidOnHover ? 1 : opacity }

    /// The answer's text size (A− / A+, ⌘− / ⌘+): 15 to 30 points.
    @Published var textSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "meeting.textSize")
        return saved >= 15 && saved <= 30 ? CGFloat(saved) : 19
    }() {
        didSet { UserDefaults.standard.set(Double(textSize), forKey: "meeting.textSize") }
    }
    /// The next answer goes over the last one (they carried on talking).
    var replaceNext = false
    private var nextAnswerID = 0

    /// Who said a line, as the transcript shows it ("You", "Them", "Speaker 2", a name).
    func label(_ line: MeetingLine) -> String {
        MeetingSpeakers.label(line, numbers: numbers, names: names, single: single)
    }

    /// The other side's only voice in a one-to-one call, so it can be named though it has no number.
    var single: Int? { numbers.isEmpty ? MeetingSpeakers.singleVoice(lines) : nil }

    /// The voices on show again, after a line or a name changed.
    func refreshSpeakers() {
        let fresh = MeetingSpeakers.numbers(lines, known: MeetingSpeakers.known(names, lines: lines))
        if fresh != numbers { numbers = fresh }
    }

    func reset() {
        voices = 0
        names = [:]
        numbers = [:]
        suggestions = [:]
        people = []
        profiles = [:]
        endingIn = nil
        running = false
        finishing = false
        app = nil
        started = Date()
        lines = []
        answers = []
        shown = 0
        notesText = ""
        notes = []
        writingNotes = false
        problem = nil
        saved = nil
        tab = .live
        micMuted = false
        callLevel = 0
        micLevel = 0
        about = ""
        documents = []
        sharing = .unchecked
        replaceNext = false
        collapsed = false
        unread = false
        email = nil
        draftingEmail = false
    }

    func biggerText() { textSize = min(30, textSize + 2) }
    func smallerText() { textSize = max(15, textSize - 2) }

    func consumeReplace() -> Bool {
        defer { replaceNext = false }
        return replaceNext && !answers.isEmpty
    }

    /// A new answer, shown; returns its index.
    func beginAnswer(question: String, kind: MeetingAnswer.Kind = .answer) -> Int {
        nextAnswerID += 1
        answers.append(MeetingAnswer(id: nextAnswerID, question: question, text: "", blocks: [], writing: true,
                                     kind: kind))
        shown = answers.count - 1
        return shown
    }

    /// The last answer, written again for a longer question; returns its index.
    func restartLastAnswer(question: String) -> Int {
        guard !answers.isEmpty else { return beginAnswer(question: question) }
        let index = answers.count - 1
        answers[index].question = question
        answers[index].text = ""
        answers[index].blocks = []
        answers[index].spoken = SpokenAnswer(say: [], also: [])
        answers[index].usedScreen = false
        answers[index].writing = true
        shown = index
        return index
    }

    func markScreen(_ index: Int, looking: Bool) {
        guard answers.indices.contains(index) else { return }
        answers[index].usedScreen = true
        answers[index].looking = looking
    }

    func updateAnswer(_ index: Int, text: String, done: Bool = false) {
        guard answers.indices.contains(index) else { return }
        answers[index].text = text
        answers[index].spoken = MeetingText.spoken(text)
        if done { answers[index].writing = false }
    }

    func setNotes(_ text: String) {
        notesText = text
        notes = MarkdownBlocks.parse(text)
    }

    /// Meter levels, only when they've moved enough to see.
    func setLevels(call: Float, mic: Float) {
        if abs(call - callLevel) > 0.04 { callLevel = call }
        if abs(mic - micLevel) > 0.04 { micLevel = mic }
    }
}
