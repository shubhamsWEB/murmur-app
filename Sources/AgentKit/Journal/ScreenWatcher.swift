import AppKit
import ApplicationServices
import IOKit.ps

/// How much the Mac can spare: plugged in or on battery (and how full), Low Power Mode, how hot it is.
public enum Power {
    public struct State: Sendable, Equatable {
        public var plugged: Bool
        public var battery: Int?
        public var lowPower: Bool
        public var hot: Bool

        /// Reading windows (cheap) is fine unless the Mac is struggling.
        public var mayCapture: Bool { !lowPower && !hot && (plugged || (battery ?? 100) > 10) }
        /// The model (not cheap): plugged in, or a well-charged battery; never in Low Power Mode or hot.
        public var mayThink: Bool { !lowPower && !hot && (plugged || (battery ?? 0) >= 50) }
    }

    public static func now() -> State {
        var plugged = true, battery: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                plugged = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                if let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    battery = current * 100 / max
                }
            }
        }
        let thermal = ProcessInfo.processInfo.thermalState
        return State(plugged: plugged, battery: battery, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                     hot: thermal == .serious || thermal == .critical)
    }
}

/// Screen memory's helper (`murmur-memory`, a process of its own at background priority): notices when the window
/// you work in changes (no timer polling the screen), keeps what it shows, counts the time, and while you're away
/// (and the Mac can spare it) has the local model read it into memories, promises and the chronicle, and writes the
/// morning brief and evening wrap-up.
@MainActor
public final class ScreenWatcher {
    private let journal = Journal()
    private let brain = BrainStore()
    private var settings = ScreenMemorySettings.load()
    private var observer: AXObserver?
    private var observed: pid_t = 0
    private var pending: DispatchWorkItem?
    /// The snapshot in front now, and since when (for its time).
    private var current: (id: Int64, app: String, domain: String, since: Date, kind: WindowKind)?
    /// What was being written in each window when it was last read, to notice when it's sent.
    private var drafts: [String: String] = [:]
    private var lightDraft = ""
    /// Pictures taken this hour, for the budget.
    private var pictureTimes: [Date] = []
    private let budget = WindowVision.Budget()
    private let canSee = WindowVision.capable()
    private var lastLoad: (busy: Double, total: Double)?
    /// Holding the Mac awake (not its display) while there's reading left and it's plugged in: a locked Mac reads on.
    private var awake: NSObjectProtocol?
    private var awakeSince = Date()
    /// When a batch was last read while the user worked.
    private var lastGentle = Date.distantPast
    private var thinking = false
    private var embedding = false
    private let vectors = MemoryVectors()
    /// A capture under way: another waits for the next change (two at once counted time backwards).
    private var capturing = false
    /// Why the model isn't reading now, logged when it changes.
    private var waitingFor = ""
    private var captures = 0, skips = 0, lastReport = Date()
    private let parent = getppid()

    public init() {}

    public func run() -> Never {
        MemoryLog.write("helper started (pid \(getpid()), Murmur \(parent)): " + describe(settings))
        // Once: memories made from the screen before menus and sidebars were left out, and before what's written was
        // checked against what was seen, go; the windows are read again under the new rules.
        let marker = MemoryLog.url.deletingLastPathComponent().appendingPathComponent(".screen-memory-reread-5")
        if !FileManager.default.fileExists(atPath: marker.path) {
            brain.forget(origin: .screen)
            journal.forgetScreenLoops()   // and the promises taken from a product's website
            brain.mergeMe()               // the user's own contact card, kept as someone else
            journal.readAgain()
            FileManager.default.createFile(atPath: marker.path, contents: Data())
            MemoryLog.write("forgot the memories made from the screen by the earlier rules; reading the kept windows again")
        }
        // Once: bookings seen before plans were read from them (a flight's itinerary) are read again.
        let plansMarker = MemoryLog.url.deletingLastPathComponent().appendingPathComponent(".screen-plans-1")
        if !FileManager.default.fileExists(atPath: plansMarker.path) {
            let me = brain.meNames()
            let bookings = journal.snapshots(from: Date().addingTimeInterval(-14 * 86400), to: Date(), limit: 3000)
                .filter { Consolidator.looksLikeBooking($0, me: me) }.map(\.id)
            journal.readAgain(bookings)
            FileManager.default.createFile(atPath: plansMarker.path, contents: Data())
            if !bookings.isEmpty { MemoryLog.write("reading \(bookings.count) booking pages again for what you have coming up") }
        }
        // Every start: no "you" twice, no promises to yourself.
        if brain.mergeMe() > 0 { MemoryLog.write("put what was kept under your own name with the rest about you") }
        journal.forgetLoops(with: brain.meNames())
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.watch(app)
                self?.soon()
            }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle() }
            }
        }
        watch(NSWorkspace.shared.frontmostApplication)
        soon()
        // Once a minute: settings, the window you're still in (a chat keeps changing), the parent, the model.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.minute() }
        }
        // In a conversation, a glance every ten seconds at the message box alone (cheap): when it empties, a message
        // was sent, and the window is read to keep what the user wrote.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.glance() }
        }
        MemoryLog.write(canSee ? "this Mac can run the vision model in the background (plugged in, away and quiet only)"
                               : "this Mac reads windows from their structure and text (the vision model needs Apple silicon with 16 GB)")
        RunLoop.main.run()
        exit(0)
    }

    private func minute() {
        if getppid() != parent { exit(0) }   // Murmur quit: so does its helper
        settings = ScreenMemorySettings.load()
        if !settings.enabled { exit(0) }
        if idle() < 60 { soon(after: 0) } else { settle() }
        Task { await takePicture() }
        stayAwake()
        think()
        brief()
        if Date().timeIntervalSince(lastReport) >= 600 {
            let counts = journal.counts()
            MemoryLog.write("last 10 min: \(captures) windows kept, \(skips) not read; \(counts.snapshots) kept in all, "
                            + "\(journal.pending(limit: 1000).count) waiting to be read, \(counts.openLoops) open loops")
            captures = 0
            skips = 0
            lastReport = Date()
        }
    }

    /// Plugged in with windows waiting: the Mac doesn't sleep by itself until they're read (the display still turns
    /// off and the screen still locks), for at most three hours at a time. Unplugged, or nothing waiting: sleeps as
    /// it always does.
    private func stayAwake() {
        let wanted = Power.now().plugged && Power.now().mayThink && !journal.pending(limit: 1).isEmpty
            && (awake == nil || Date().timeIntervalSince(awakeSince) < 3 * 3600)
        if wanted, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                          reason: "Murmur is reading what you worked on into memories")
            awakeSince = Date()
            MemoryLog.write("keeping the Mac awake (not the display) until the waiting windows are read")
        } else if !wanted, let held = awake, !thinking {
            ProcessInfo.processInfo.endActivity(held)
            awake = nil
            MemoryLog.write("letting the Mac sleep again: " + (journal.pending(limit: 1).isEmpty ? "everything is read"
                                                              : "unplugged, or three hours were enough for now"))
        }
    }

    private func describe(_ settings: ScreenMemorySettings) -> String {
        "on \(settings.enabled), \(settings.always ? "always" : "\(settings.from)-\(settings.to)"), pictures "
            + "\(settings.rules.pictures), \(settings.rules.excluded.count) excluded"
    }

    /// Logs why the model is waiting, once each time the reason changes.
    private func waiting(_ reason: String) {
        guard reason != waitingFor else { return }
        waitingFor = reason
        if !reason.isEmpty { MemoryLog.write("reading waits: \(reason)") }
        MemoryLog.setStatus(reason.isEmpty ? "Reading now" : "Waiting: \(reason)")
    }

    /// The morning brief, the evening wrap-up and reminders, when it's their time (one short model call each).
    private func brief() {
        guard !thinking, Power.now().mayThink else { return }
        thinking = true
        Task {
            defer { thinking = false }
            await Nudges.make(journal: journal, brain: brain, settings: settings, model: await BrainDistiller.model())
        }
    }

    nonisolated private func idle() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Watches the front app for a new window or tab (its title changes): a capture follows.
    private func watch(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != observed else { return }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        observed = app.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let watcher = Unmanaged<ScreenWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.soon() }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(created, element, name as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    /// A capture in a moment: changes come in bursts (switching tabs fires several), and only where you settle counts.
    private func soon(after delay: Double = 1.5) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // The watcher as a constant: Swift 6.2 (Xcode 26.0) won't send the weak, changeable `self` into a task, and
            // says so as "ambiguous use of init(name:priority:operation:)".
            MainActor.assumeIsolated {
                guard let watcher = self else { return }
                Task { await watcher.capture() }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Counts the time on the window you were in, up to now.
    private func settle(now: Date = Date()) {
        guard let current else { return }
        let seconds = max(0, min(now.timeIntervalSince(current.since), 300))   // away from the Mac doesn't count
        journal.stayed(current.id, seconds: seconds, now: now)
        journal.spend(seconds, app: current.app, domain: current.domain, at: now)
        self.current = nil
    }

    private func capture() async {
        guard !capturing else { soon(); return }
        capturing = true
        defer { capturing = false }
        let power = Power.now()
        guard settings.readsNow(), power.mayCapture, !screenLocked() else { settle(); return }
        let captured = await ScreenReader.capture(rules: settings.rules, plugged: power.plugged)
        let now = Date()   // after reading the window (a picture takes a moment)
        guard let captured else {
            skips += 1
            settle()
            return
        }
        var capture = captured.capture
        let draft = captured.draft
        // What was in the message box last time and is now in the conversation, with the box empty: it was sent.
        let key = capture.app + "|" + capture.title
        let kind = WindowKind(rawValue: capture.kind) ?? .app
        if kind == .conversation, let sent = ScreenText.sent(before: drafts[key] ?? "", now: draft, in: capture.text) {
            capture.authored = sent
            MemoryLog.write("kept a message you sent in \(capture.app)")
        }
        drafts[key] = draft
        settle(now: now)
        let kept = journal.record(capture, now: now)
        captures += 1
        if capture.via == "image" { MemoryLog.write("read a picture of \(capture.app) (little text)") }
        current = (kept.id, capture.app, capture.domain, now, kind)
    }

    /// A message box that just emptied in a conversation: read the window now.
    private func glance() {
        guard settings.rules.authored, current?.kind == .conversation, idle() < 30 else { lightDraft = ""; return }
        let draft = ScreenReader.frontDraft()
        if !lightDraft.isEmpty, draft.isEmpty { soon(after: 1) }
        lightDraft = draft
    }

    // MARK: Pictures

    /// A small picture of the window you've stayed in, for the vision model to look at later: only on a Mac that can
    /// run it, for windows whose meaning their text leaves open, within the budget.
    private func takePicture() async {
        guard canSee, settings.rules.pictures, let current, Date().timeIntervalSince(current.since) >= budget.stayed,
              WindowVision.worthLooking(current.kind, app: current.app), !journal.hasPicture(current.id),
              Power.now().mayCapture, let app = ScreenReader.frontApp(), app.localizedName == current.app else { return }
        pictureTimes = pictureTimes.filter { $0 > Date().addingTimeInterval(-3600) }
        guard pictureTimes.count < budget.perHour, Journal.picturesSize() < budget.maxBytes,
              let jpeg = await ScreenReader.thumbnail(of: app, side: budget.side) else { return }
        try? FileManager.default.createDirectory(at: Journal.pictures, withIntermediateDirectories: true)
        let file = Journal.pictures.appendingPathComponent("\(current.id).jpg")
        guard (try? jpeg.write(to: file)) != nil else { return }
        journal.setPicture(current.id, path: file.path)
        pictureTimes.append(Date())
    }

    /// Whether other programs are keeping the processors busy (more than half of them, since the last look).
    /// How busy the processors were since the last look, 0 to 1 (nil the first time).
    private func cpuLoad() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let busy = Double(ticks.0) + Double(ticks.1) + Double(ticks.3), total = busy + Double(ticks.2)
        defer { lastLoad = (busy, total) }
        guard let last = lastLoad, total > last.total else { return nil }
        return (busy - last.busy) / (total - last.total)
    }

    private func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: Thinking

    /// When you've been away two minutes and the Mac can spare it: the model reads what was seen, writes the chronicle,
    /// and the brief or wrap-up when it's time. Stops as soon as you're back.
    private func think() {
        guard !thinking else { return }
        let power = Power.now()
        // Vectors for what's new (cheap: a few milliseconds a sentence), whenever the Mac can spare that much.
        if power.mayCapture, LocalReader.embedderInstalled, !embedding {
            embedding = true
            let search = MemorySearch(store: brain, journal: journal, vectors: vectors)
            Task.detached(priority: .background) { [weak self] in
                let made = await search.catchUp(batches: 4) { await LocalReader.embed($0, query: false) }
                if made > 0 { MemoryLog.write("gave \(made) memories and windows their vectors (search by meaning)") }
                await MainActor.run { self?.embedding = false }
            }
        }
        guard power.mayThink else {
            waiting(power.lowPower ? "Low Power Mode is on" : power.hot ? "the Mac is hot"
                    : "on battery at \(power.battery ?? 0)% (reads plugged in, or above 50%)")
            return
        }
        let load = cpuLoad() ?? 1
        // "Read Now" on the Memory page: a full round now, while the user is here.
        let asked = MemoryLog.takeReadingRequest()
        // While the user works: only on a Mac strong enough (Apple silicon, 16 GB or more), plugged in, and quiet,
        // one batch every three minutes, without summaries or pictures. On anything less, only while they're away.
        var gentle = false
        if idle() <= 120, !asked {
            guard canSee, power.plugged, load < 0.25, Date().timeIntervalSince(lastGentle) >= 180,
                  !journal.pending(limit: 1).isEmpty else {
                waiting("you're using the Mac (reads after 2 minutes away)")
                return
            }
            gentle = true
            lastGentle = Date()
        }
        guard load <= 0.5 || asked else { waiting("other apps are keeping the Mac busy"); return }
        waiting("")
        thinking = true
        Task {
            // A round in progress isn't cut short by the Mac going to sleep (a minute or two, then it sleeps as usual).
            let round = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                              reason: "Murmur is finishing reading a few windows")
            defer { thinking = false; ProcessInfo.processInfo.endActivity(round) }
            if gentle {
                guard let model = await BrainDistiller.model() else { return }
                let started = Date()
                let read = await Consolidator.pass(journal: journal, brain: brain, model: model, batchesPerPass: 1,
                                                   vectors: vectors, summaries: false) { Power.now().mayThink }
                if read > 0 {
                    MemoryLog.write("read \(read) windows while you worked (the Mac was quiet) in "
                                    + String(format: "%.0f s", Date().timeIntervalSince(started)))
                    MemoryLog.setStatus("Read \(read) windows while you worked, at "
                                        + Date().formatted(date: .omitted, time: .shortened))
                }
                return
            }
            // First the vision model looks at the windows waiting with a picture (strong Macs only), one at a time.
            if canSee, let eyes = await WindowVision.model() {
                var looked = 0
                for (snapshot, path) in journal.waitingPictures(limit: budget.perRound) {
                    guard Brain.idleSeconds() > 60, Power.now().mayThink, let jpeg = FileManager.default.contents(atPath: path) else { break }
                    if let seen = await WindowVision.look(at: jpeg, snapshot: snapshot, model: eyes) {
                        journal.understood(snapshot.id, seenAs: seen.seenAs, kind: seen.kind)
                        looked += 1
                    } else {
                        break
                    }
                }
                if looked > 0 { MemoryLog.write("the vision model looked at \(looked) windows (\(eyes))") }
            }
            guard let model = await BrainDistiller.model() else {
                waiting("no model to read with (Ollama has no general model)")
                return
            }
            let started = Date()
            let pending = journal.pending(limit: 1000).count
            let keepGoing: @Sendable () -> Bool = { asked ? Power.now().mayThink
                : Brain.idleSeconds() > 60 && Power.now().mayThink }
            // Plugged in: at full speed. On a well-charged battery: as many windows a round, at background priority.
            let now = Power.now()
            let read = await Consolidator.pass(journal: journal, brain: brain, model: model,
                                               batchesPerPass: now.plugged || (now.battery ?? 0) >= 50 ? 6 : 3,
                                               vectors: vectors, fast: now.plugged, keepGoing: keepGoing)
            MemoryLog.write("read \(read) of \(pending) waiting windows with \(model) in "
                            + String(format: "%.0f s", Date().timeIntervalSince(started))
                            + (keepGoing() ? "" : " (stopped: you came back, or the power changed)"))
            MemoryLog.setStatus("Read \(read) windows at " + Date().formatted(date: .omitted, time: .shortened)
                                + (keepGoing() ? "" : "; stopped when you came back"))
            journal.prune()
        }
    }
}
