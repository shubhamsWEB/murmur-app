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
    /// The timeline, items, episodes and connections under it all.
    private let graph = MemoryGraph()
    /// When items and episodes were last brought up to date (cheap, no model: every few minutes).
    private var lastStructure = Date.distantPast
    private var settings = ScreenMemorySettings.load()
    private var observer: AXObserver?
    private var observed: pid_t = 0
    private var pending: DispatchWorkItem?
    /// The snapshot in front now, and since when (for its time).
    private var current: (id: Int64, app: String, domain: String, since: Date, kind: WindowKind, sighting: Int64)?
    /// What was being written in each window when it was last read, to notice when it's sent.
    private var drafts: [String: String] = [:]
    /// A feed's page as it read last time: a "your post is live" already on it then says nothing about this draft.
    private var pages: [String: String] = [:]
    private var lightDraft = ""
    /// The window in front (its app and title), whose message box the glance reads.
    private var currentKey = ""
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
    /// Claude or OpenAI couldn't be reached (or refused): the local model reads until then.
    private var cloudPause = Date.distantPast
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
        let marker = MemoryLog.url.deletingLastPathComponent().appendingPathComponent(".screen-memory-reread-6")
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
        // Once: memories rebuilt on the timeline. What was read a window at a time goes; the kept windows get their
        // timeline, items and episodes, and each episode is read as a whole (with its exact items: flights, releases).
        let episodesMarker = MemoryLog.url.deletingLastPathComponent().appendingPathComponent(".screen-memory-episodes-1")
        if !FileManager.default.fileExists(atPath: episodesMarker.path) {
            brain.repairEntities()
            brain.forget(origin: .screen)
            journal.forgetScreenLoops()
            journal.readAgain()
            let windows = graph.backfill(from: journal)
            let items = graph.readItems(from: journal, me: brain.meNames())
            let episodes = graph.segment().count
            FileManager.default.createFile(atPath: episodesMarker.path, contents: Data())
            MemoryLog.write("rebuilt screen memory on a timeline: \(windows) windows, \(items) items (flights, releases, "
                            + "emails, files…), \(episodes) episodes to read")
        }
        // Once: the first timeline's items never got kept (their table's name was taken), so its episodes were read
        // without them (no emails sent, no flight, no project). Items and episodes are made again from the timeline,
        // with emails, releases and flights read the new way, and read again.
        let rebuiltMarker = MemoryLog.url.deletingLastPathComponent().appendingPathComponent(".screen-memory-episodes-2")
        if !FileManager.default.fileExists(atPath: rebuiltMarker.path) {
            brain.forget(itemPrefix: "episode:")
            journal.forgetScreenLoops()
            journal.readAgain()
            graph.rebuild()
            let items = graph.readItems(from: journal, me: brain.meNames())
            let episodes = graph.segment().count
            FileManager.default.createFile(atPath: rebuiltMarker.path, contents: Data())
            MemoryLog.write("made the timeline's items and episodes again: \(items) items (emails you sent, flights, releases, "
                            + "files), \(episodes) episodes to read")
        }
        // Once: the timeline is read again for what the readers learned (your own posts on LinkedIn, a release
        // tagged but not yet published, a tag pushed from the terminal), so what happened before this version counts.
        // In the background, on connections of its own, so watching starts at once; marked done in the memory file
        // itself when it finished (a run cut short runs again: reading the same window twice makes the same items).
        if graph.state("reread-posts-1") == nil {
            let url = journal.url, me = brain.meNames()
            Task.detached(priority: .background) {
                let graph = MemoryGraph(url: url)
                let items = graph.readAllItemsAgain(from: Journal(url: url), me: me)
                graph.setState("reread-posts-1", String(Date().timeIntervalSince1970))
                MemoryLog.write("read the timeline again for posts, tags and releases: \(items) new items")
            }
        }
        // Once: replies awaited are threads now (not open loops), a connecting flight isn't a trip of its own, and
        // memories of a button or a field name go.
        let threadsMarker = MemoryLog.url.deletingLastPathComponent().appendingPathComponent(".screen-memory-threads-1")
        if !FileManager.default.fileExists(atPath: threadsMarker.path) {
            let cleaned = journal.forgetLoops { loop in
                loop.summary.hasPrefix("Reply from ") || graph.isConnectingFlight(in: loop.summary)
            }
            let junk = brain.fromScreen(limit: 5000).filter { EpisodeReader.isJunk(about: $0.about, text: $0.memory.text) }
            for hit in junk { brain.forget(memory: hit.id) }
            let opened = Threads.update(graph: graph)
            FileManager.default.createFile(atPath: threadsMarker.path, contents: Data())
            MemoryLog.write("opened \(opened) threads from what you sent; dropped \(cleaned) loops and \(junk.count) memories that weren't facts")
        }
        // Every start: no "you" twice, no promises to yourself.
        if brain.mergeMe() > 0 { MemoryLog.write("put what was kept under your own name with the rest about you") }
        // Once: build, CI and pull-request states kept as memories before they were left out.
        let passingMarker = MemoryLog.url.deletingLastPathComponent().appendingPathComponent(".screen-passing-1")
        if !FileManager.default.fileExists(atPath: passingMarker.path) {
            let passing = brain.fromScreen(limit: 5000).filter { Consolidator.isPassingState($0.memory.text) }
            for hit in passing { brain.forget(memory: hit.id) }
            FileManager.default.createFile(atPath: passingMarker.path, contents: Data())
            if !passing.isEmpty { MemoryLog.write("forgot \(passing.count) build, CI and pull-request states kept as memories") }
        }
        let projects = brain.mergeProjects()
        if projects > 0 { MemoryLog.write("put \(projects) projects kept under other names (versions, repos) with the one they are") }
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
        // In a conversation or on a feed, a glance every ten seconds at the box being written in alone (cheap): when it
        // empties, a message was sent (or a post published), and the window is read to keep what the user wrote.
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
        structure()
        stayAwake()
        think()
        brief()
        if Date().timeIntervalSince(lastReport) >= 600 {
            let counts = journal.counts()
            let structure = graph.counts()
            MemoryLog.write("last 10 min: \(captures) windows kept, \(skips) not read; \(counts.snapshots) kept in all, "
                            + "\(structure.items) items, \(structure.episodes) episodes (\(structure.unread) to read), "
                            + "\(counts.openLoops) open loops")
            captures = 0
            skips = 0
            lastReport = Date()
        }
    }

    /// Items and episodes brought up to date: what's new on the timeline read by rules (no model, a few milliseconds),
    /// every minute, so an episode that just finished is read within a minute or two.
    private func structure(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastStructure) >= 55 else { return }
        lastStructure = Date()
        let items = graph.readItems(from: journal, me: brain.meNames())
        let finished = graph.segment().count
        let threads = Threads.update(graph: graph)
        if threads > 0 { MemoryLog.write("opened \(threads) threads from what you sent") }
        if items > 0 || finished > 0 { MemoryLog.write("timeline: \(items) new items, \(finished) episodes finished") }
    }

    /// Plugged in with windows waiting: the Mac doesn't sleep by itself until they're read (the display still turns
    /// off and the screen still locks), for at most three hours at a time. Unplugged, or nothing waiting: sleeps as
    /// it always does.
    private func stayAwake() {
        let wanted = Power.now().plugged && Power.now().mayThink && graph.unreadCount() > 0
            && (awake == nil || Date().timeIntervalSince(awakeSince) < 3 * 3600)
        if wanted, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                          reason: "Murmur is reading what you worked on into memories")
            awakeSince = Date()
            MemoryLog.write("keeping the Mac awake (not the display) until the waiting windows are read")
        } else if !wanted, let held = awake, !thinking {
            ProcessInfo.processInfo.endActivity(held)
            awake = nil
            MemoryLog.write("letting the Mac sleep again: " + (graph.unreadCount() == 0 ? "everything is read"
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
    /// The brief, the wrap-up and reminders. Never held back by the battery: without the model (on battery, in Low
    /// Power Mode, when the Mac is hot) they're the facts as they are, which costs nothing. Only waits a minute when
    /// the reader is busy.
    private func brief() {
        guard !thinking else { return }
        let mayThink = Power.now().mayThink
        thinking = true
        Task {
            defer { thinking = false }
            let model = mayThink ? await BrainDistiller.model() : nil
            await Nudges.make(journal: journal, brain: brain, graph: graph, settings: settings, model: model)
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
        graph.stayed(current.sighting, until: current.since.addingTimeInterval(seconds))
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
        let draft = captured.draft, boxes = captured.boxes
        // What was in the message box last time and is now in the conversation, with the box empty: it was sent.
        let key = capture.app + "|" + capture.title
        let kind = WindowKind(rawValue: capture.kind) ?? .app
        // An email leaves no copy in the inbox it goes back to: the box emptying (or the compose window going) is it sent.
        let isMail = ItemReader.mailApps.contains(capture.app) || ItemReader.mailDomains.contains(capture.domain)
        let before = drafts[key] ?? ""
        // (A draft still in one of the window's text boxes wasn't sent: the user only clicked elsewhere.)
        let stillThere = ScreenText.stillWriting(ScreenText.plain(before), in: boxes)
        if kind == .conversation, let sent = ScreenText.sent(before: before, now: draft, in: capture.text, boxes: boxes)
            ?? (isMail && draft.isEmpty && !stillThere && before.split(separator: " ").count >= 3 ? before : nil) {
            capture.authored = sent
            MemoryLog.write("kept a message you sent in \(capture.app)")
        }
        // A post (or a comment) on a feed: the box it was written in emptied, and it's on the page now, or the site
        // said it was posted. A search box empties too, so only something sentence-long counts.
        // Only on a site Murmur knows as somewhere people post (LinkedIn, X, YouTube…): elsewhere what was typed is
        // left as typed.
        if kind == .feed || kind == .video, ItemReader.platform(of: capture.domain) != nil,
           let sent = ScreenText.posted(before: before, now: draft, in: capture.text, boxes: boxes, earlier: pages[key] ?? "") {
            capture.authored = sent
            MemoryLog.write("kept a post you published on \(capture.domain.isEmpty ? capture.app : capture.domain)")
        }
        // A compose window that closed (Mail, Outlook): what was in it was sent.
        // (A compose window renamed by its subject still has the text in its box: not sent.)
        if key != currentKey, draft.isEmpty, let gone = drafts[currentKey], gone.split(separator: " ").count >= 3,
           currentKey.hasPrefix("Mail|") || currentKey.hasPrefix("Microsoft Outlook|"), !ScreenReader.windowExists(currentKey) {
            MemoryLog.write("kept an email you sent from \(currentKey.split(separator: "|").first ?? "Mail")")
            capture.authored = (capture.authored.isEmpty ? "" : capture.authored + "\n") + gone
            drafts[currentKey] = nil
        }
        drafts[key] = draft
        // Only the latest feed's: a page left behind isn't needed (and every video is a page of its own).
        if kind == .feed || kind == .video { pages = [key: capture.text] }
        currentKey = key
        settle(now: now)
        let kept = journal.record(capture, now: now)
        let sighting = graph.sighted(snapshot: kept.id, at: now, app: capture.app, title: capture.title, domain: capture.domain,
                                     kind: capture.kind)
        captures += 1
        if capture.via == "image" { MemoryLog.write("read a picture of \(capture.app) (little text)") }
        current = (kept.id, capture.app, capture.domain, now, kind, sighting)
    }

    /// A message box that just emptied in a conversation: read the window now.
    private func glance() {
        guard settings.rules.authored, let kind = current?.kind, [.conversation, .feed, .video].contains(kind) else { return }
        let draft = ScreenReader.frontDraft()
        // The latest of what's being written, for when it's sent (the last full read may have caught only its start).
        if !draft.isEmpty, !currentKey.isEmpty { drafts[currentKey] = draft }
        if !lightDraft.isEmpty, draft.isEmpty { soon(after: 1) }
        lightDraft = draft
    }

    // MARK: Pictures

    /// The model, as an episode reader asks it.
    nonisolated static func ask(_ model: String, fast: Bool) -> EpisodeReader.Ask {
        { system, user in await Consolidator.chat(system, user, schema: EpisodeReader.schema, model: model, fast: fast, maxTokens: 700) }
    }

    /// A small picture of the window you've stayed in, for the vision model to look at later: only on a Mac that can
    /// run it, for windows whose meaning their text leaves open, within the budget.
    private func takePicture() async {
        guard canSee, settings.rules.pictures, let current, Date().timeIntervalSince(current.since) >= budget.stayed,
              WindowVision.worthLooking(current.kind, app: current.app), !journal.hasPicture(current.id),
              Power.now().mayCapture, let app = ScreenReader.frontApp(),
              ScreenText.appName(app.localizedName ?? "") == current.app else { return }
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
        // Reading with Claude or OpenAI (the user turned it on, with their key): any time, on any Mac, on battery too
        // (the Mac only sends text), the episodes that finished first. Back to the local model when it can't be reached.
        if let provider = settings.cloudReader, Date() >= cloudPause, let ask = CloudReader.ask(provider),
           graph.unreadCount(includePrivate: false) > 0 {
            waiting("")
            thinking = true
            Task {
                defer { thinking = false }
                let started = Date()
                structure(force: true)
                let read = await EpisodeReader.pass(graph: graph, journal: journal, brain: brain, ask: ask, vectors: vectors,
                                                    limit: 20, remote: true) { Power.now().mayCapture }
                if read == 0, graph.unreadCount(includePrivate: false) > 0 {
                    cloudPause = Date().addingTimeInterval(10 * 60)   // offline, or the key refused: the local model meanwhile
                    return
                }
                if let prose = CloudReader.ask(provider, json: false) {
                    await Consolidator.chronicle(journal: journal, model: "", now: Date(), keepGoing: { true }, graph: graph, ask: prose)
                }
                if read > 0 {
                    let name = provider == "openai" ? "OpenAI" : "Claude"
                    MemoryLog.write("read \(read) episodes of what you did with \(name) in "
                                    + String(format: "%.0f s", Date().timeIntervalSince(started)))
                    MemoryLog.setStatus("Read \(read) episodes with \(name) at " + Date().formatted(date: .omitted, time: .shortened))
                }
            }
            return
        }
        guard power.mayThink else {
            waiting(power.lowPower ? "Low Power Mode is on" : power.hot ? "the Mac is hot"
                    : "on battery at \(power.battery ?? 0)% (reads plugged in, or above 50%)")
            return
        }
        let load = cpuLoad() ?? 1
        // "Read Now" on the Memory page: a full round now, while the user is here.
        let asked = MemoryLog.takeReadingRequest()
        // While the user works, on the fly: on a Mac strong enough (Apple silicon, 16 GB or more), plugged in, and not
        // busy, one episode a minute (the one that just finished first), without summaries or pictures: a few seconds
        // of the reader at background priority. On anything less, only while they're away.
        var gentle = false
        if idle() <= 120, !asked {
            guard canSee, power.plugged, load < 0.4, Date().timeIntervalSince(lastGentle) >= 55,
                  graph.unreadCount() > 0 else {
                waiting(canSee && power.plugged ? "other apps are keeping the Mac busy (reads when it's quieter)"
                        : "you're using the Mac (reads after 2 minutes away; while you work only plugged in, on Apple silicon with 16 GB)")
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
                structure(force: true)
                let read = await EpisodeReader.pass(graph: graph, journal: journal, brain: brain, ask: Self.ask(model, fast: false),
                                                    vectors: vectors, limit: 1) { Power.now().mayThink }
                if read > 0 {
                    MemoryLog.write("read \(read) episode while you worked (the Mac was quiet) in "
                                    + String(format: "%.0f s", Date().timeIntervalSince(started)))
                    MemoryLog.setStatus("Read what you did while you worked, at "
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
            structure(force: true)
            let pending = graph.unreadCount()
            let keepGoing: @Sendable () -> Bool = { asked ? Power.now().mayThink
                : Brain.idleSeconds() > 60 && Power.now().mayThink }
            // Plugged in: at full speed. On a well-charged battery: as many windows a round, at background priority.
            let now = Power.now()
            let read = await EpisodeReader.pass(graph: graph, journal: journal, brain: brain, ask: Self.ask(model, fast: now.plugged),
                                                vectors: vectors, limit: now.plugged ? 12 : 6, keepGoing: keepGoing)
            if keepGoing() {
                await Consolidator.chronicle(journal: journal, model: model, now: Date(), keepGoing: keepGoing, graph: graph)
            }
            MemoryLog.write("read \(read) of \(pending) episodes of what you did with \(model) in "
                            + String(format: "%.0f s", Date().timeIntervalSince(started))
                            + (keepGoing() ? "" : " (stopped: you came back, or the power changed)"))
            MemoryLog.setStatus("Read \(read) episodes of your work at " + Date().formatted(date: .omitted, time: .shortened)
                                + (keepGoing() ? "" : "; stopped when you came back"))
            journal.prune()
            graph.prune()
        }
    }
}
