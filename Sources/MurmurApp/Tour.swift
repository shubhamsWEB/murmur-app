import AppKit
import Observation
import SwiftUI
import VoiceKit

/// A walk around Murmur's window with the starling as the guide. The page dims; the bird flies to the part being
/// explained (tapping the page's name in the sidebar on the way when it's on another page), the spotlight opens
/// around it, and a card unfolds out of the bird: what it is and how it works, with a small drawing of it working.
/// Next folds the card back into the bird and it flies on. Three things are done for real (talk into the box on the
/// card, rewrite its text by voice, press the search keys), and the card waits until Murmur sees you do it; each can
/// be skipped. At the end the bird flies back up to the menu bar, where Murmur lives.
///
/// Starts once after setup, and again from About & Help. With Reduce Motion it doesn't fly: each card simply appears.
@Observable
final class TourModel {
    /// What a stop waits for before Next shows.
    enum Wait: Equatable {
        case next
        /// Something dictated (into the box on the card, or anywhere).
        case dictate
        /// A command done (on the box's text, or anywhere).
        case command
        /// The file-search shortcut pressed.
        case searchKey
        /// Take notes (or Not now) clicked on the meeting offer.
        case offer
    }

    struct Step: Identifiable {
        let id: String
        /// The page shown while the card is open.
        var section: HomeSection
        /// The page's name in the sidebar, which the bird taps on its way (another page).
        var via: TourTarget?
        /// What the spotlight opens around (none: the card in the middle).
        var target: TourTarget?
        let title: String
        let body: String
        var art: TourArt.Kind?
        /// How tall its drawing is.
        var artHeight: CGFloat = 100
        /// The meeting notes, shown for real (the offer card, the panel on one of its tabs) while the card is open.
        var meeting: MeetingDemo.Scene?
        var wait: Wait = .next
        /// What to do, for a stop that waits for you.
        var tryIt: String?
        /// Said once you've done it.
        var done: String?
        /// Text already in the box on the card (a command needs something to work on).
        var practice: String?
        /// The button: "Next" unless it says otherwise.
        var button = "Next"
    }

    /// How long things take (seconds).
    enum Timing {
        static let unfold = 0.55, fold = 0.35, tap = 0.3, leave = 1.3
        static func flight(_ step: Step, first: Bool) -> Double { first ? 1.5 : step.via != nil ? 2.0 : 1.15 }
        /// The first leg of a flight through the sidebar, to the item it taps.
        static func toSidebar(_ step: Step) -> Double { (flight(step, first: false) - tap) * 0.45 }
    }

    private(set) var isOn = false
    private(set) var index = 0
    /// Done what the stop asked for.
    private(set) var stepDone = false
    /// The box on the card.
    var practice = ""
    /// Where each part the tour points at is, in the window's coordinates (`tourTarget`, `.global`).
    var frames: [TourTarget: CGRect] = [:]
    /// Where the overlay's top-left corner is in the window; every frame is moved by it before it's drawn.
    var shift: CGPoint = .zero
    /// The overlay's size: the meeting offer and panel are placed in it as they are on the screen.
    var windowSize: CGSize = .zero
    /// The meeting notes the tour shows: the real offer card and panel, playing a made-up call.
    @ObservationIgnored private(set) var meeting: MeetingDemo?
    /// Where the bird sat on each stop's card (the next flight starts there).
    var perches: [Int: CGPoint] = [:]
    /// No flying (Reduce Motion, and debug snapshots): each card is simply there.
    var frozen = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Bumped when the page should scroll its spotlit part into view.
    private(set) var scrollToken = 0

    /// When this stop began (the bird took off), when its card began folding (Next), and when the bird began flying
    /// off at the end.
    private(set) var started = Date()
    private(set) var folding: Date?
    private(set) var leaving: Date?
    /// The spotlight as the last stop left it.
    private(set) var fromHole: CGRect?

    @ObservationIgnored private weak var app: AppController?
    @ObservationIgnored private weak var home: HomeState?
    @ObservationIgnored private var watcher: Timer?
    @ObservationIgnored private var generation = 0

    static let seenKey = "tourSeen"
    /// Kept with Murmur's settings (a dev run's own suite, never yours).
    static var seen: Bool {
        get { AppSettings.defaults.bool(forKey: seenKey) }
        set { AppSettings.defaults.set(newValue, forKey: seenKey) }
    }

    private(set) var steps: [Step] = []

    var step: Step? { isOn && steps.indices.contains(index) ? steps[index] : nil }
    /// The stops between hello and goodbye, for "3 of 7".
    var count: Int { max(0, steps.count - 2) }

    func start(app: AppController, home: HomeState) {
        self.app = app
        self.home = home
        steps = Self.steps(app: app)
        meeting = meeting ?? MeetingDemo(mode: app.dictation.meeting)
        perches = [:]
        fromHole = nil
        leaving = nil
        isOn = true
        // Seen from the moment it starts: it never starts by itself again, even if Murmur quits halfway.
        Self.seen = true
        go(to: 0)
        log("tour: started (\(steps.count) stops)")
    }

    /// Next: the card folds into the bird, then it flies to the next stop (or, after the last, off to the menu bar).
    func next() {
        guard isOn, folding == nil, leaving == nil else { return }
        if frozen { return advance() }
        folding = Date()
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.fold) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.advance()
        }
    }

    private func advance() {
        if index + 1 < steps.count { return go(to: index + 1) }
        // The end: up to the menu bar, then gone.
        leaving = Date()
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + (frozen ? 0 : Timing.leave)) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.finish()
        }
    }

    /// Ends it now (Skip tour, Later, Esc, the window closing).
    func finish() {
        guard isOn else { return }
        log("tour: \(index + 1 == steps.count ? "finished" : "ended at \(steps[index].id)")")
        leaveStep()
        generation += 1
        isOn = false
        folding = nil
        leaving = nil
        Self.seen = true
        meeting?.stop()
        home?.section = .home
    }

    func go(to index: Int) {
        leaveStep()
        generation += 1
        fromHole = step.flatMap { hole(for: $0) }
        self.index = index
        stepDone = false
        folding = nil
        started = Date()
        guard let step else { return }
        practice = step.practice ?? ""
        // The page: now, or when the bird taps its name in the sidebar.
        let generation = generation
        let switchAt = step.via == nil || frozen ? 0 : Timing.toSidebar(step) + Timing.tap * 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + switchAt) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.home?.section = step.section
            self.scrollToken += 1
            if let scene = step.meeting { self.meeting?.show(scene, animated: !self.frozen) } else { self.meeting?.stop() }
        }
        if step.wait == .searchKey, let app {
            app.hotkeyTester = { [weak self, weak app] in
                self?.markDone()
                app?.panel.toggle()   // the real thing: the panel opens, as it always does
            }
        }
        // Dictation and commands happen outside SwiftUI's sight: look a few times a second.
        if step.wait != .next {
            watcher = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
    }

    /// Skips the try-it of this stop, as if it had been done.
    func skip() {
        log("tour: skipped \(step?.id ?? "?")")
        next()
    }

    /// The spotlight for a stop: around its target, as it is now.
    func hole(for step: Step) -> CGRect? {
        step.target.flatMap { frame(of: $0) }.map { $0.insetBy(dx: -8, dy: -8) }
    }

    /// A part's frame in the overlay's own coordinates.
    func frame(of target: TourTarget) -> CGRect? {
        switch target {
        case .meetingOffer: return windowSize.width > 0 ? Self.offerFrame(in: windowSize) : nil
        case .meetingPanel: return windowSize.width > 0 ? Self.panelFrame(in: windowSize) : nil
        default: return frames[target]?.offsetBy(dx: -shift.x, dy: -shift.y)
        }
    }

    /// Where the offer card sits: the window's top right, as it sits at the screen's.
    static func offerFrame(in size: CGSize) -> CGRect {
        let card = MeetingDemoOffer.size
        return CGRect(x: size.width - card.width - 22, y: 46, width: card.width, height: card.height)
    }

    /// Where the panel sits: at the right, as it opens beside a call.
    static func panelFrame(in size: CGSize) -> CGRect {
        let width = MeetingDemoPanel.width
        return CGRect(x: size.width - width - 22, y: 46, width: width, height: min(640, size.height - 70))
    }

    /// The panel's tabs moved or appeared: each tab is a quarter of them.
    func tabsMoved(to frame: CGRect) {
        let tabs: [TourTarget] = [.meetingTabLive, .meetingTabNotes, .meetingTabTranscript, .meetingTabContext]
        for (i, tab) in tabs.enumerated() {
            let slice = CGRect(x: frame.minX + frame.width * CGFloat(i) / 4, y: frame.minY, width: frame.width / 4,
                               height: frame.height)
            if frames[tab] != slice { frames[tab] = slice }
        }
    }

    /// Take notes (or Not now) on the offer: the panel opens, as it does.
    func offerAnswered() {
        guard step?.wait == .offer else { return }
        markDone()
        next()
    }

    private func leaveStep() {
        watcher?.invalidate()
        watcher = nil
        if step?.wait == .searchKey { app?.hotkeyTester = nil }
    }

    private func check() {
        guard let step, !stepDone else { return }
        switch step.wait {
        case .next, .searchKey, .offer:
            return
        case .dictate:
            if heard(.dictation) || !practice.trimmingCharacters(in: .whitespaces).isEmpty { markDone() }
        case .command:
            if heard(.command) || (practice != step.practice && !practice.isEmpty) { markDone() }
        }
    }

    private func heard(_ kind: DictationHistory.Item.Kind) -> Bool {
        DictationHistory.shared.items.contains { $0.kind == kind && $0.date > started }
    }

    private func markDone() {
        guard !stepDone else { return }
        withAnimation(.spring(duration: 0.35)) { stepDone = true }
        log("tour: did \(step?.id ?? "?")")
    }

    /// The talk key, as the drawings show it.
    var keyName: String { app?.dictation.key.cap ?? "fn" }

    // MARK: The stops

    static func steps(app: AppController) -> [Step] {
        let dictation = app.dictation
        let key = dictation.key.short
        let command = dictation.commandModifier.symbol
        let search = app.model.hotkey?.display ?? "⇧⌘Space"
        return [
            Step(id: "hello", section: .home, target: nil,
                 title: "Hi, I'm Murmur",
                 body: "I live in your menu bar and work in every app. Let me show you around. It takes two minutes.",
                 button: "Show me around"),
            Step(id: "talk", section: .home, target: .talk,
                 title: "Hold \(key) and talk",
                 body: "Let go, and I type it where your cursor is, in any app.",
                 art: .talk, wait: .dictate,
                 tryIt: "Click the box, hold \(key) and say something.",
                 done: "That's it. It works the same in Mail, Slack, anywhere."),
            Step(id: "ask", section: .home, target: .selection,
                 title: "Or tell me what to do",
                 body: "“Open Slack”, “summarise this”. Select some text first and I rewrite it right where it is.",
                 art: .rewrite, wait: .command,
                 tryIt: "Select the text, hold \(key) \(command) and say “make it polite”.",
                 done: "Rewritten in place.",
                 practice: "hey can u send me the slides from yesterdays meeting when ur free"),
            Step(id: "find", section: .home, target: .sidebarSearch,
                 title: "Find any file by describing it",
                 body: "Press \(search) anywhere: “the rent agreement from last year”. Return opens it.",
                 art: .search, wait: .searchKey,
                 tryIt: "Press \(search).",
                 done: "That's the search panel. Esc closes it."),
            Step(id: "offer", section: .meetings, via: .sidebarMeetings, target: .meetingOffer,
                 title: "When a call starts, I offer to take notes",
                 body: "Once Zoom, Teams, Slack, FaceTime or a call in your browser has had your microphone on for a "
                     + "few seconds, this card appears at the top right of your screen. Ignore it and it goes after "
                     + "half a minute.",
                 meeting: .offer, wait: .offer,
                 tryIt: "Click Take notes on the card.",
                 done: "Taking notes."),
            Step(id: "live", section: .meetings, target: .meetingPanel,
                 title: "Live: what to say, as they ask",
                 body: "I hear both sides of the call. When they finish a question, the answer appears here in large "
                     + "type, ready to read out. ⌥⌘↩ answers at once. Nobody on the call sees this panel: it's left "
                     + "out of screen sharing.",
                 meeting: .live),
            Step(id: "notes", section: .meetings, via: .meetingTabNotes, target: .meetingPanel,
                 title: "Notes, kept up as you talk",
                 body: "A summary, the decisions and who does what, updated every minute or so. When the call ends, a "
                     + "follow-up email is drafted here too.",
                 meeting: .notes),
            Step(id: "transcript", section: .meetings, via: .meetingTabTranscript, target: .meetingPanel,
                 title: "Every line, both sides",
                 body: "What they said and what you said, in order, as it's said.",
                 meeting: .transcript),
            Step(id: "context", section: .meetings, via: .meetingTabContext, target: .meetingPanel,
                 title: "Tell me what it's about",
                 body: "What the meeting is for, how you want answers, and documents like a pricing sheet: answers "
                     + "and notes use them. The AI that writes them is chosen here too.",
                 meeting: .context),
            Step(id: "ended", section: .meetings, target: .meetingsList,
                 title: "Afterwards, it's all here",
                 body: "When the call ends, its notes and transcript are saved on this page and in Documents › "
                     + "Murmur Meetings. Search them by a name, a decision or a number.",
                 meeting: .ended),
            Step(id: "memory", section: .memory, via: .sidebarMemory, target: .remember,
                 title: "I remember your work",
                 body: "Turn this on and I keep what matters from the windows you work in, on this Mac: a page for "
                     + "each person and project, and a brief of your day each morning.",
                 art: .memory),
            Step(id: "ai", section: .memory, target: .aiApps,
                 title: "Your memory in your AI apps",
                 body: "Claude, Cursor and Codex can ask me what you know: “what did I promise Priya?”",
                 art: .aiApps),
            Step(id: "models", section: .commands, via: .sidebarCommands, target: .modelCards,
                 title: "On your Mac, or in the cloud",
                 body: "Pick the AI that does commands, writes meeting notes and drafts replies. On this Mac runs a "
                     + "model through Ollama: free and private, a little slower. Claude, OpenAI and Sarvam are faster "
                     + "and use your own key. Click a card to switch."),
            Step(id: "cloud", section: .commands, target: .cloudPrivacy,
                 title: "What a cloud model sees",
                 body: "Only what the task needs: a command's words, the app in front and text you select; the text "
                     + "around a box when you tap to write; a meeting's transcript for its notes. With On this Mac, "
                     + "nothing leaves. Your keys stay in your Keychain."),
            Step(id: "speech", section: .dictation, via: .sidebarSettings, target: .speechModel,
                 title: "Your voice, turned to text here",
                 body: "Speech to text runs on this Mac, offline: English, Hindi with English, or 25 European languages. "
                     + "Sarvam adds 20 more Indian languages from the cloud: then your recordings go to Sarvam."),
            Step(id: "yours", section: .dictation, target: .grammar,
                 title: "Make me yours",
                 body: "Change the talk key, teach me names I get wrong, and turn on Fix grammar.",
                 art: .grammar),
            Step(id: "bye", section: .home, target: nil,
                 title: "That's everything",
                 body: "Hold \(key) in any app to start. I'm up in the menu bar if you need me.",
                 button: "Done"),
        ]
    }
}

/// The parts of the window the tour points at.
nonisolated enum TourTarget: String, Hashable, Sendable {
    case talk, ask, selection, writeTap, sidebarSearch, sidebarMeetings, meetingsPage, meetingsSearch, meetingsList
    case meetingOffer, meetingPanel, meetingTabLive, meetingTabNotes, meetingTabTranscript, meetingTabContext
    case sidebarMemory, remember, day, aiApps, modelCards, cloudPrivacy, speechModel
    case sidebarCommands, commandsPage, sidebarSettings, grammar
}

/// The page's coordinate space (kept for the page; the tour itself measures in window coordinates: a named space on
/// a view that reaches under the title bar put every part 28 pt above where it's drawn).
let tourSpace = "murmur.tour"

extension View {
    /// Marks this as a place the tour can point at (and scroll to). nil: nothing.
    @ViewBuilder
    func tourTarget(_ target: TourTarget?) -> some View {
        if let target { modifier(TourTargetModifier(target: target)) } else { self }
    }
}

private struct TourTargetModifier: ViewModifier {
    let target: TourTarget
    @Environment(TourModel.self) private var tour: TourModel?

    func body(content: Content) -> some View {
        content
            .id(target)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                // Always: it reports only when something moves, and a tour started later needs to know.
                // Only the tour's overlay reads these, so nothing else redraws.
                tour?.frames[target] = frame
            }
    }
}

// MARK: - The overlay

private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(max(x, a), b) }
/// Slow, quick, slow.
private func ease(_ x: Double) -> Double {
    let x = clamp(x, 0, 1)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}
/// Quick, a little past, settled.
private func springOut(_ x: Double) -> Double {
    let x = clamp(x, 0, 1)
    return 1 - pow(1 - x, 3) * cos(x * 3.2)
}
private func mix(_ a: CGFloat, _ b: CGFloat, _ f: Double) -> CGFloat { a + (b - a) * CGFloat(f) }
private func mix(_ a: CGRect, _ b: CGRect, _ f: Double) -> CGRect {
    CGRect(x: mix(a.minX, b.minX, f), y: mix(a.minY, b.minY, f), width: mix(a.width, b.width, f),
           height: mix(a.height, b.height, f))
}

/// Everything over the window: the dim with its spotlight, the bird and the card. Clicks reach the page only through
/// the spotlight.
struct TourOverlay: View {
    @Bindable var tour: TourModel
    /// The card as drawn (its height depends on the stop).
    @State private var card = CGSize(width: 340, height: 300)
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: {
                        tour.shift = $0
                    }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { tour.windowSize = $0 }
                TimelineView(.animation(minimumInterval: 1 / 60, paused: tour.frozen)) { context in
                    if let step = tour.step {
                        scene(step, at: context.date, in: geometry.size)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onExitCommand { tour.finish() }
    }

    @ViewBuilder
    private func scene(_ step: TourModel.Step, at now: Date, in size: CGSize) -> some View {
        let window = CGRect(origin: .zero, size: size)
        let first = tour.index == 0
        let fly = tour.frozen ? 0 : TourModel.Timing.flight(step, first: first)
        let u = now.timeIntervalSince(tour.started)
        let target = tour.hole(for: step).map { $0.intersection(window.insetBy(dx: 4, dy: 4)) }
            .flatMap { $0.isNull || $0.width < 8 ? nil : $0 }
        let place = Self.place(card: card, beside: target, in: size)
        let origin = CGPoint(x: place.x - card.width / 2, y: place.y - card.height / 2)
        let perch = CGPoint(x: origin.x + 44, y: origin.y - 20)
        let off = CGPoint(x: size.width + 70, y: -70)
        let from = first ? off : tour.perches[tour.index - 1] ?? perch
        let via = step.via.flatMap { tour.frame(of: $0) }.map { CGPoint(x: $0.maxX - 30, y: $0.minY + 2) }
        let flight = Self.flight(from: from, via: via, to: perch, u: u, fly: fly, first: first)
        let leaving = tour.leaving.map { now.timeIntervalSince($0) / TourModel.Timing.leave }
        let bird = leaving.map { Self.leg(from: perch, to: off, f: $0, lift: 160) } ?? flight
        // The card: grows out of the bird, its words a beat later; folds back, words first.
        let opened = fly == 0 ? 1 : clamp((u - fly) / TourModel.Timing.unfold, 0, 1)
        let folded = tour.folding.map { clamp(now.timeIntervalSince($0) / TourModel.Timing.fold, 0, 1) }
            ?? (leaving != nil ? 1 : 0)
        let scale = folded > 0 ? 0.06 + 0.94 * (1 - ease(folded)) : 0.08 + 0.92 * springOut(opened)
        let cardOpacity = folded > 0 ? 1 - Self.ramp(folded, 0.35, 1) : Self.ramp(opened, 0, 0.35)
        let words = folded > 0 ? 1 - Self.ramp(folded, 0, 0.35) : Self.ramp(opened, 0.45, 0.9)
        // The spotlight follows the bird: to the sidebar item it taps, then to the place.
        let hole = spotlight(step, target: target, u: u, fly: fly)
        let dim = first ? (fly == 0 ? 1 : Self.ramp(u, 0.2, 1.2)) : leaving.map { 1 - clamp($0, 0, 1) } ?? 1
        ZStack(alignment: .topLeading) {
            SpotlightShape(hole: hole ?? .zero)
                .fill(shade.opacity(shadeStrength * dim), style: FillStyle(eoFill: true))
                .contentShape(SpotlightShape(hole: hole ?? .zero), eoFill: true)
                .onTapGesture {}   // a click beside the spotlight does nothing
            if let hole, hole.width > 3 {
                Glow(frame: hole, breathe: tour.frozen ? 1 : (sin(now.timeIntervalSinceReferenceDate * 2.6) + 1) / 2)
                    .allowsHitTesting(false)
            }
            if let scene = step.meeting { meeting(scene, u: u, fly: fly, in: size) }
            TourCard(tour: tour, step: step, words: words)
                .frame(width: step.target == nil ? 380 : 340)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { card = $0 }
                .scaleEffect(scale, anchor: UnitPoint(x: 44 / max(card.width, 1), y: -8 / max(card.height, 1)))
                .opacity(cardOpacity)
                .position(place)
                .allowsHitTesting(opened >= 1 && folded == 0)
                .onChange(of: perch) { tour.perches[tour.index] = perch }
                .onAppear { tour.perches[tour.index] = perch }
            if let tap = bird.tapping, tap > 0.2 {
                Circle().strokeBorder(Theme.accent.opacity(1 - tap), lineWidth: 2)
                    .frame(width: 12 + 36 * tap, height: 12 + 36 * tap)
                    .position(x: bird.point.x, y: bird.point.y + 14)
                    .allowsHitTesting(false)
            }
            FlyingStarling(flap: now.timeIntervalSinceReferenceDate * 2 * .pi * 4.2, flying: bird.flying,
                           facingLeft: bird.flying && bird.direction.dx < -0.01, bank: Self.bank(bird))
                .frame(width: 56, height: 56)
                .position(x: bird.point.x, y: bird.point.y + Self.bob(bird, at: now, still: tour.frozen))
                .allowsHitTesting(false)
        }
    }

    /// The meeting notes, for real, over the dim: the offer card at the top right when a call starts, then the panel
    /// beside the call. The offer slides in once the bird is on its way; the panel slides in when the offer is
    /// taken, stays put from tab to tab, and slides away when the call has ended.
    @ViewBuilder
    private func meeting(_ scene: MeetingDemo.Scene, u: Double, fly: Double, in size: CGSize) -> some View {
        if let demo = tour.meeting {
            let before = tour.index > 0 ? tour.steps[tour.index - 1].meeting : nil
            let panelBefore = before.map { $0 != .offer && $0 != .ended } ?? false
            switch scene {
            case .offer:
                let shown = fly == 0 ? 1 : Self.ramp(u, fly * 0.6, fly * 0.6 + 0.45)
                let frame = TourModel.offerFrame(in: size)
                MeetingDemoOffer(take: { tour.offerAnswered() }, later: { tour.offerAnswered() })
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX + 30 * (1 - shown), y: frame.midY)
                    .opacity(shown)
                    .allowsHitTesting(shown >= 1 && !tour.stepDone)
            case .ended:
                let gone = fly == 0 || !panelBefore ? 1 : Self.ramp(u, 0, 0.45)
                if gone < 1 { panel(demo, in: size, shown: 1 - gone) }
            default:
                panel(demo, in: size, shown: panelBefore || fly == 0 ? 1 : Self.ramp(u, 0.05, 0.5))
            }
        }
    }

    private func panel(_ demo: MeetingDemo, in size: CGSize, shown: Double) -> some View {
        let frame = TourModel.panelFrame(in: size)
        return MeetingDemoPanel(demo: demo) { tour.tabsMoved(to: $0) }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX + 40 * (1 - shown), y: frame.midY)
            .opacity(shown)
    }

    /// The dim: warm ink over a light page; over a dark page, ink barely shows, so black and stronger.
    private var shade: Color { scheme == .dark ? .black : Color(red: 0.133, green: 0.118, blue: 0.110) }
    private var shadeStrength: Double { scheme == .dark ? 0.58 : 0.40 }

    /// Where the spotlight is u seconds into a stop.
    private func spotlight(_ step: TourModel.Step, target: CGRect?, u: Double, fly: Double) -> CGRect? {
        guard fly > 0 else { return target }
        if let via = step.via.flatMap({ tour.frame(of: $0) })?.insetBy(dx: -4, dy: -4) {
            let first = TourModel.Timing.toSidebar(step), tap = TourModel.Timing.tap
            if u < first { return tour.fromHole.map { mix($0, via, ease(u / first)) } ?? via }
            if u < first + tap { return via }
            guard let target else { return nil }
            return mix(via, target, springOut((u - first - tap) / (fly - first - tap)))
        }
        guard let target else {
            // To the middle: the last spotlight closes.
            guard let last = tour.fromHole, u < 0.5 else { return nil }
            let k = 1 - Self.ramp(u, 0, 0.45)
            return CGRect(x: last.midX - last.width * k / 2, y: last.midY - last.height * k / 2,
                          width: last.width * k, height: last.height * k)
        }
        let from = tour.fromHole ?? CGRect(x: target.midX, y: target.midY, width: 0, height: 0)
        return mix(from, target, springOut(u / fly))
    }

    /// Tilted into the climb or the dive, a little.
    static func bank(_ bird: Bird) -> Double {
        guard bird.flying else { return 0 }
        let dy = Double(bird.direction.dy), dx = abs(Double(bird.direction.dx)) + 0.001
        return clamp(atan2(dy, dx) * 57.3 * 0.35, -22, 22)
    }

    /// A hop while it taps; a slow breath while it sits.
    static func bob(_ bird: Bird, at now: Date, still: Bool) -> CGFloat {
        if let tap = bird.tapping { return CGFloat(-sin(tap * .pi) * 7) }
        if bird.flying || still { return 0 }
        return CGFloat(sin(now.timeIntervalSinceReferenceDate * 2.2) * 0.8)
    }

    static func ramp(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = clamp((x - a) / (b - a), 0, 1)
        return t * t * (3 - 2 * t)
    }

    struct Bird {
        var point: CGPoint
        var direction: CGVector
        var flying: Bool
        /// Tapping the sidebar item (0…1), between the flight's two legs.
        var tapping: Double?
    }

    /// One leg of a flight: a curve up and over, slow at both ends.
    static func leg(from a: CGPoint, to b: CGPoint, f: Double, lift: CGFloat) -> Bird {
        let e = CGFloat(ease(f))
        let c = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - lift)
        let x = (1 - e) * (1 - e) * a.x + 2 * (1 - e) * e * c.x + e * e * b.x
        let y = (1 - e) * (1 - e) * a.y + 2 * (1 - e) * e * c.y + e * e * b.y
        let dx = 2 * (1 - e) * (c.x - a.x) + 2 * e * (b.x - c.x)
        let dy = 2 * (1 - e) * (c.y - a.y) + 2 * e * (b.y - c.y)
        return Bird(point: CGPoint(x: x, y: y), direction: CGVector(dx: dx, dy: dy), flying: f > 0 && f < 1)
    }

    /// The bird u seconds into a stop: flying (through the sidebar item it taps), then perched on the card.
    static func flight(from: CGPoint, via: CGPoint?, to: CGPoint, u: Double, fly: Double, first: Bool) -> Bird {
        guard fly > 0, u < fly else { return Bird(point: to, direction: .zero, flying: false) }
        if let via {
            let tap = TourModel.Timing.tap
            let first = (fly - tap) * 0.45, second = fly - tap - first
            if u < first { return leg(from: from, to: via, f: u / first, lift: 50) }
            if u < first + tap {
                return Bird(point: via, direction: .zero, flying: false, tapping: (u - first) / tap)
            }
            return leg(from: via, to: to, f: (u - first - tap) / second, lift: 60)
        }
        return leg(from: from, to: to, f: u / fly, lift: first ? 40 : 70)
    }

    /// Where the card's centre goes: beside the spotlight, inside the window, covering as little of it as it can
    /// (right, left, below, above; the first that covers none of it, else the one that covers least). Room is left
    /// above it for the bird.
    static func place(card: CGSize, beside hole: CGRect?, in window: CGSize) -> CGPoint {
        let gap: CGFloat = 26, margin: CGFloat = 24, bird: CGFloat = 34
        guard let hole else { return CGPoint(x: window.width / 2, y: window.height / 2 + 14) }
        func clampY(_ y: CGFloat) -> CGFloat {
            min(max(y, margin + bird + card.height / 2), window.height - margin - card.height / 2)
        }
        func clampX(_ x: CGFloat) -> CGFloat {
            min(max(x, margin + card.width / 2), window.width - margin - card.width / 2)
        }
        let candidates = [
            CGPoint(x: clampX(hole.maxX + gap + card.width / 2), y: clampY(hole.midY)),
            CGPoint(x: clampX(hole.minX - gap - card.width / 2), y: clampY(hole.midY)),
            CGPoint(x: clampX(hole.midX), y: clampY(hole.maxY + gap + bird + card.height / 2)),
            CGPoint(x: clampX(hole.midX), y: clampY(hole.minY - gap - card.height / 2)),
        ]
        func covered(_ centre: CGPoint) -> CGFloat {
            let frame = CGRect(x: centre.x - card.width / 2, y: centre.y - card.height / 2 - bird, width: card.width,
                               height: card.height + bird)
            let overlap = frame.intersection(hole)
            guard !overlap.isNull else { return 0 }
            // Over a side, the card hides the start or end of every line (a row's title); over the top or bottom
            // edge it hides a margin, and the bird sits there anyway.
            let acrossTheLines = overlap.height >= hole.height * 0.8
            return overlap.width * overlap.height * (acrossTheLines ? 4 : 1)
        }
        return candidates.first { covered($0) == 0 } ?? candidates.min { covered($0) < covered($1) } ?? candidates[0]
    }
}

/// The window with a rounded hole in it.
nonisolated struct SpotlightShape: Shape {
    var hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if hole.width > 1, hole.height > 1 {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12), style: .continuous)
        }
        return path
    }
}

/// A thin coral edge round the spotlight, with a soft glow that breathes.
private struct Glow: View {
    let frame: CGRect
    let breathe: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.accent.opacity(0.35 * (0.55 + 0.45 * breathe)), lineWidth: 6)
                .blur(radius: 5)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.accent, lineWidth: 1.5)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
    }
}

/// The starling of the app icon, in flight: a coral wing beating above and below the body, turned the way it flies
/// and tilted into the turn. Perched, it's the icon itself.
struct FlyingStarling: View {
    let flap: Double
    let flying: Bool
    var facingLeft = false
    var bank: Double = 0

    var body: some View {
        if flying {
            Canvas { context, size in
                let unit = min(size.width, size.height) / 100
                context.translateBy(x: size.width / 2, y: size.height / 2)
                context.scaleBy(x: facingLeft ? -unit : unit, y: unit)
                context.rotate(by: .degrees(bank))
                context.translateBy(x: -50, y: -56)
                let up = (sin(flap) + 1) / 2
                func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * up }
                var wing = Path()
                wing.move(to: CGPoint(x: 38, y: 58))
                wing.addQuadCurve(to: CGPoint(x: m(26, 22), y: m(76, 10)), control: CGPoint(x: m(28, 30), y: m(70, 30)))
                wing.addQuadCurve(to: CGPoint(x: 60, y: 57), control: CGPoint(x: m(44, 46), y: m(66, 44)))
                wing.closeSubpath()
                let wingColor = Color(red: 1.0, green: 0.549, blue: 0.502)
                let downstroke = sin(flap) < 0
                if !downstroke { context.fill(wing, with: .color(wingColor)) }
                drawBody(&context)
                if downstroke { context.fill(wing, with: .color(wingColor)) }
            }
        } else {
            StarlingMark(.color, legs: true)
        }
    }

    /// The icon's tail, body, head, beak, eye and sound-wave stripe (`StarlingMark`'s geometry).
    private func drawBody(_ context: inout GraphicsContext) {
        var tail = Path()
        tail.move(to: CGPoint(x: 30, y: 58)); tail.addLine(to: CGPoint(x: 12, y: 47)); tail.addLine(to: CGPoint(x: 16, y: 67))
        tail.closeSubpath()
        var beak = Path()
        beak.move(to: CGPoint(x: 78, y: 40.5)); beak.addLine(to: CGPoint(x: 89, y: 44)); beak.addLine(to: CGPoint(x: 78, y: 47.5))
        beak.closeSubpath()
        var stripe = Path()
        stripe.move(to: CGPoint(x: 31, y: 60))
        stripe.addQuadCurve(to: CGPoint(x: 40, y: 60), control: CGPoint(x: 35.5, y: 52))
        stripe.addQuadCurve(to: CGPoint(x: 49, y: 60), control: CGPoint(x: 44.5, y: 68))
        stripe.addQuadCurve(to: CGPoint(x: 58, y: 60), control: CGPoint(x: 53.5, y: 52))
        let coral = Color(red: 1.0, green: 0.435, blue: 0.380)
        let ink = Color(red: 0.133, green: 0.118, blue: 0.110)
        context.fill(tail, with: .color(Color(red: 0.886, green: 0.333, blue: 0.290)))
        context.fill(Path(ellipseIn: CGRect(x: 24, y: 41, width: 48, height: 38)), with: .color(coral))
        context.fill(Path(ellipseIn: CGRect(x: 53, y: 29, width: 26, height: 26)), with: .color(coral))
        context.fill(beak, with: .color(ink))
        context.fill(Path(ellipseIn: CGRect(x: 66.4, y: 36.4, width: 5.2, height: 5.2)), with: .color(ink))
        context.stroke(stripe, with: .color(Color(red: 1.0, green: 0.965, blue: 0.937)),
                       style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
    }
}

// MARK: - The card

private struct TourCard: View {
    @Bindable var tour: TourModel
    let step: TourModel.Step
    /// How far its words have come in (they follow the card out of the bird).
    let words: Double

    private var last: Bool { tour.index + 1 == tour.steps.count }
    private var waiting: Bool { step.wait != .next && !tour.stepDone }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let art = step.art {
                TourArt(kind: art, frozen: tour.frozen, keyName: tour.keyName)
                    .frame(height: step.artHeight)
                    .id(step.id)   // each stop's drawing starts from its beginning
                    .padding(.bottom, 16)
            }
            Text(step.title).font(.system(size: 18, weight: .semibold)).tracking(-0.3)
            Text(step.body)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink2)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            if let tryIt = step.tryIt { tryBox(tryIt).padding(.top, 14) }
            HStack(spacing: 12) {
                if tour.index > 0, !last {
                    Text("\(tour.index) of \(tour.count)").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
                if !last {
                    Button(tour.index == 0 ? "Later" : "Skip tour") { tour.finish() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                }
                if !waiting {
                    Button(step.button) { tour.next() }
                        .buttonStyle(.murmurPrimaryCompact)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip this one") { tour.skip() }
                        .buttonStyle(.murmurSecondaryCompact)
                }
            }
            .padding(.top, 16)
        }
        .opacity(words)
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 18)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
    }

    @ViewBuilder
    private func tryBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: tour.stepDone ? "checkmark.circle.fill" : "hand.point.right.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(tour.stepDone ? Theme.good : Theme.accentText)
                    .frame(width: 16)
                Text(tour.stepDone ? (step.done ?? "Done.") : text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tour.stepDone ? Theme.good : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if step.practice != nil || step.wait == .dictate {
                TextField(step.wait == .dictate ? "Click here, then hold the key and talk" : "",
                          text: $tour.practice, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(2...3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.page))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tour.stepDone ? Theme.good.opacity(0.6) : Theme.control))
            }
            if !tour.stepDone { Waiting(frozen: tour.frozen) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tour.stepDone ? Theme.good.opacity(0.08) : Theme.accentTint.opacity(0.6)))
    }
}

/// "Waiting for you" with a breathing dot.
private struct Waiting: View {
    let frozen: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: frozen)) { context in
            let t = frozen ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * 3) + 1) / 2
            HStack(spacing: 7) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7).opacity(0.35 + 0.65 * t)
                Text("Waiting for you…").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
            }
        }
    }
}

// MARK: - The animations

/// A small drawing of the feature working, on a loop.
struct TourArt: View {
    enum Kind {
        case talk, rewrite, search, memory, aiApps, grammar
    }

    let kind: Kind
    let frozen: Bool
    var keyName = "fn"
    @State private var start = Date()

    /// Played once, then held on its last frame; the AI apps' dots keep flowing.
    private var period: Double {
        kind == .aiApps ? 3 : 3.6
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: frozen)) { context in
            // Still: the moment that shows it done.
            let elapsed = context.date.timeIntervalSince(start)
            let p = frozen ? 0.86 : kind == .aiApps ? elapsed.truncatingRemainder(dividingBy: period) / period
                : min(elapsed / period, 0.97)
            stage(p)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardAlt))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stage(_ p: Double) -> some View {
        switch kind {
        case .talk: TalkArt(p: p, key: keyName)
        case .rewrite: RewriteArt(p: p)
        case .search: SearchArt(p: p)
        case .memory: MemoryArt(p: p)
        case .aiApps: AIAppsArt(p: p)
        case .grammar: GrammarArt(p: p)
        }
    }
}

/// 0 before `from`, 1 after `to`, eased between.
private func ramp(_ p: Double, _ from: Double, _ to: Double) -> Double {
    let x = min(max((p - from) / (to - from), 0), 1)
    return x * x * (3 - 2 * x)
}

/// The first `fraction` of `text`, for typing.
private func typed(_ text: String, _ fraction: Double) -> String {
    String(text.prefix(Int((Double(text.count) * fraction).rounded())))
}

/// A line of text in a box, with a caret.
private struct Field: View {
    let text: String
    var placeholder = ""
    var caret = true
    var highlight = false

    var body: some View {
        HStack(spacing: 1) {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: 11.5))
                .foregroundStyle(text.isEmpty ? Theme.ink3 : Theme.ink)
                .padding(.horizontal, highlight ? 2 : 0)
                .background(highlight ? Theme.accent.opacity(0.22) : .clear)
                .lineLimit(2)
            if caret { Rectangle().fill(Theme.accentText).frame(width: 1.5, height: 14) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Murmur thinking: three dots.
private struct Dots: View {
    let p: Double

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                let wave = (sin((p * 18) - Double(i) * 0.9) + 1) / 2
                Circle().fill(Theme.accent).frame(width: 6, height: 6).opacity(0.3 + 0.7 * wave)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.accentTint))
    }
}

private struct Bubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText)
            Text("“\(text)”").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.line))
    }
}

private struct TalkArt: View {
    let p: Double
    let key: String

    var body: some View {
        let down = p > 0.08 && p < 0.62
        HStack(spacing: 14) {
            Text(key)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(down ? .white : Theme.ink)
                .frame(width: 50, height: 46)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(down ? Theme.accent : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.control))
                .shadow(color: .black.opacity(down ? 0 : 0.12), radius: 0, y: down ? 0 : 3)
                .offset(y: down ? 2 : 0)
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    let level = down ? (sin(p * 60 + Double(i) * 1.3) + 1) / 2 : 0
                    Capsule().fill(down ? Theme.accent : Theme.control).frame(width: 3, height: 5 + 18 * level)
                }
            }
            .frame(width: 36)
            Field(text: typed("Running ten minutes late, start without me", ramp(p, 0.62, 0.9)),
                  placeholder: "Mail · Reply", caret: p > 0.6)
        }
        .padding(.horizontal, 16)
    }
}

private struct RewriteArt: View {
    let p: Double

    var body: some View {
        let before = "hey can u send me the slides when ur free"
        let after = "Could you send me the slides when you have a moment?"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Bubble(text: "make it polite").opacity(ramp(p, 0.14, 0.22))
                if p > 0.24, p < 0.5 { Dots(p: p) }
            }
            .frame(height: 28)
            if p < 0.5 {
                Field(text: before, caret: false, highlight: p > 0.06)
            } else {
                Field(text: typed(after, ramp(p, 0.5, 0.8)), caret: p < 0.82)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct SearchArt: View {
    let p: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                Text(typed("rent agreement from last year", ramp(p, 0.04, 0.36)))
                    .font(.system(size: 12)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line))
            result("doc.richtext", "Rent Agreement 2025.pdf", "Documents", ramp(p, 0.42, 0.5), chosen: p > 0.7)
            result("doc.text", "Lease renewal notes.docx", "Downloads", ramp(p, 0.5, 0.58), chosen: false)
        }
        .padding(.horizontal, 16)
    }

    private func result(_ symbol: String, _ name: String, _ folder: String, _ shown: Double, chosen: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.accentText)
            Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            Text(folder).font(.system(size: 10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
            Spacer()
            if chosen { Text("↩ Open").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accentText) }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(chosen ? Theme.accentTint : .clear))
        .opacity(shown)
    }
}

private struct MemoryArt: View {
    let p: Double

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                window("Slack", "Pricing by Fri?", ramp(p, 0.02, 0.1), drift: ramp(p, 0.3, 0.5))
                window("Mail", "Acme launch", ramp(p, 0.08, 0.16), drift: ramp(p, 0.34, 0.54))
                window("Docs", "Pricing v3", ramp(p, 0.14, 0.22), drift: ramp(p, 0.38, 0.58))
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accentTint).frame(width: 18, height: 18)
                        .overlay(Text("P").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.accentText))
                    Text("Priya Shah").font(.system(size: 12, weight: .semibold))
                }
                claim("Leads design at Acme", ramp(p, 0.56, 0.62))
                claim("Pricing sheet due Fri", ramp(p, 0.64, 0.7))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
            .opacity(ramp(p, 0.48, 0.56))
        }
        .padding(.horizontal, 14)
    }

    private func window(_ app: String, _ text: String, _ shown: Double, drift: Double) -> some View {
        HStack(spacing: 5) {
            Text(app).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 30, alignment: .leading)
            Text(text).font(.system(size: 10.5)).lineLimit(1)
        }
        .padding(.horizontal, 7).frame(width: 128, height: 22, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
        .opacity(shown * (1 - 0.55 * drift))
        .offset(x: 10 * drift)
    }

    private func claim(_ text: String, _ shown: Double) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Circle().fill(Theme.accent).frame(width: 4, height: 4).padding(.top, 5)
            Text(text).font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
        }
        .opacity(shown)
    }
}

private struct AIAppsArt: View {
    let p: Double

    var body: some View {
        let apps = ["Claude", "Cursor", "Codex"]
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(apps.enumerated()), id: \.offset) { i, name in
                    Text(name).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(Theme.card))
                        .overlay(Capsule().strokeBorder(i == 0 && p > 0.1 ? Theme.accent : Theme.line))
                }
            }
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let y = CGFloat(i - 1) * 34
                    Path { path in path.move(to: CGPoint(x: 0, y: 46 + y)); path.addLine(to: CGPoint(x: 70, y: 46)) }
                        .stroke(Theme.control, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    let t = (p * 2 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        .position(x: 70 * t, y: 46 + y * (1 - t))
                }
            }
            .frame(width: 70, height: 92)
            StarlingMark(.color).frame(width: 36, height: 36)
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("“What did I promise Priya?”").font(.system(size: 10.5, weight: .medium))
                    .opacity(ramp(p, 0.1, 0.2))
                Text("The pricing sheet, by Friday.").font(.system(size: 10.5)).foregroundStyle(Theme.good)
                    .opacity(ramp(p, 0.5, 0.6))
            }
            .frame(width: 128, alignment: .leading)
        }
        .padding(.horizontal, 14)
    }
}

private struct GrammarArt: View {
    let p: Double

    var body: some View {
        let on = p > 0.25
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Fix grammar").font(.system(size: 11.5, weight: .medium))
                Capsule().fill(on ? Theme.accent : Theme.control).frame(width: 30, height: 17)
                    .overlay(Circle().fill(.white).padding(2).offset(x: on ? 6.5 : -6.5))
            }
            ZStack(alignment: .leading) {
                Field(text: "me and him was going to the store", caret: false)
                    .opacity(1 - ramp(p, 0.45, 0.6))
                Field(text: "He and I were going to the store.", caret: false)
                    .opacity(ramp(p, 0.5, 0.65))
            }
        }
        .padding(.horizontal, 16)
    }
}
