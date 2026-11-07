import Foundation
import Testing
@testable import AgentKit

/// The memory's foundation: items read by rules (a flight's departure exactly as the page has it, a release with its
/// notes), the timeline cut into episodes, and what's derived kept with what it came from.
struct MemoryFoundationTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()
    static func date(_ text: String) -> Date { ScreenDates.formatter("yyyy-MM-dd HH:mm", calendar).date(from: text)! }
    static let seen = date("2026-11-06 21:40")

    static func window(_ id: Int64 = 1, app: String = "Google Chrome", title: String, url: String? = nil, text: String,
                       first: Date = seen, seconds: Double = 120, authored: String = "", document: String? = nil) -> Journal.Snapshot {
        var snapshot = Journal.Snapshot(id: id, app: app, title: title, url: url,
                                        domain: url.flatMap { URL(string: $0)?.host }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "",
                                        text: text, first: first, last: first.addingTimeInterval(seconds), seconds: seconds,
                                        sightings: 1)
        snapshot.authored = authored
        snapshot.document = document
        return snapshot
    }

    /// The itinerary as IndiGo's site showed it (2026-11-06): the departure is 10:15, check-in closes 09:15, web
    /// check-in opened 10:15 on the 6th. The model once read 11:35.
    static let itinerary = window(title: "Itinerary - Google Chrome", url: "https://www.goindigo.in/book/itinerary.html", text: """
        CHECK FLIGHT STATUS | Sun, 08 Nov | Your | Itinerary | Hello | Shubham Agrawal | Your itinerary is generated
        BLR RPR | 08 Nov, 26 | 1 Pax | Confirmed | Departure Flight | BLR | BENGALURU (T1) | 1 Stop | RPR | RAIPUR
        Passengers and Add-ons | Fast Forward | Check-in closes | 09:15 | 10:15 | Sun, 08 Nov 2026 | 6E 537 | 6E 7575
        Web Check-in | Check-in online for free 48hrs to 60mins before the flight | Starts on 10:15, Fri 06 Nov
        PNR: K7QX2M
        """)

    @Test func aFlightKeepsItsDepartureAsThePageHasIt() throws {
        let items = ItemReader.read(Self.itinerary, me: ["Shubham Agrawal"], calendar: Self.calendar)
        let flight = try #require(items.first { $0.kind == .flight })
        #expect(items.filter { $0.kind == .flight }.count == 1)   // 6E 7575 is the connection, not another trip
        #expect(flight.fields["number"] == "6E 537")
        #expect(flight.fields["departs"] == "2026-11-08 10:15")
        #expect(flight.fields["check-in closes"] == "2026-11-08 09:15")
        #expect(flight.fields["check-in opens"] == "2026-11-06 10:15")
        #expect(flight.fields["from"] == "Bengaluru" && flight.fields["to"] == "Raipur")
        #expect(flight.fields["connecting"] == "6E 7575")
        #expect(flight.fields["reference"] == "K7QX2M")
        #expect(flight.mine)
        #expect(flight.key == "flight|6e537|2026-11-08")
        #expect(flight.body.contains("Departs: Sun 8 Nov 2026, 10:15"))
    }

    @Test func aFlightLaidOutWithLabels() throws {
        let page = Self.window(title: "Booking confirmed", url: "https://www.airindia.com/booking", text: """
            Booking confirmed. Hello Shubham Agrawal. Booking reference: ABC123
            AI 2805  Delhi (DEL) → Mumbai (BOM)
            Mon, 16 Nov 2026
            Departure 06:05  Terminal 3
            Arrival 08:20  Terminal 2
            Boarding time 05:25. Gate closes 25 minutes before departure.
            """)
        let flight = try #require(ItemReader.read(page, me: ["Shubham"], calendar: Self.calendar).first { $0.kind == .flight })
        #expect(flight.fields["departs"] == "2026-11-16 06:05")
        #expect(flight.fields["arrives"] == "2026-11-16 08:20")
        #expect(flight.fields["from"] == "Delhi" && flight.fields["to"] == "Mumbai")
        #expect(flight.fields["boarding"] == "2026-11-16 05:25")
        #expect(flight.fields["reference"] == "ABC123")
    }

    @Test func anOfferIsNoFlight() {
        let offers = Self.window(title: "Flight Offers, Deals | IndiGo", url: "https://www.goindigo.in/offers",
                                 text: "Use Code: 6EMLE Get flat 10% off on flights to Maldives. Book flights and earn BluChips.")
        #expect(ItemReader.read(offers, me: ["Shubham"], calendar: Self.calendar).allSatisfy { $0.kind != .flight })
    }

    /// GitHub's release page, as Chrome's accessibility tree reads it.
    static let release = window(title: "Release Murmur 1.6.0 · shubhamsWEB/murmur-app · GitHub",
                                url: "https://github.com/shubhamsWEB/murmur-app/releases/tag/v1.6.0", text: """
        Murmur 1.6.0
        Latest
        shubhamsWEB released this Nov 6
        v1.6.0
        a811f46
        What's new on the Mac
        Memory: Murmur's second brain. Murmur now remembers who's who, what's coming up and what you told it.
        Remember what you work on. Murmur reads the window you're working in and turns it into memories.
        Morning brief and evening wrap-up.
        Assets 4
        Murmur-1.6.0.dmg
        """)

    @Test func aReleaseKeepsItsVersionDayAndNotes() throws {
        let item = try #require(ItemReader.read(Self.release, me: ["Shubham Agrawal"], calendar: Self.calendar).first { $0.kind == .release })
        #expect(item.title == "Murmur 1.6.0")
        #expect(item.project == "Murmur")
        #expect(item.mine)
        #expect(item.key == "release|murmur-app|1.6.0")
        #expect(item.when.map { ScreenDates.dayKey($0, calendar: Self.calendar) } == "2026-11-06")
        #expect(item.fields["notes"]?.contains("second brain") == true)
        #expect(item.fields["notes"]?.contains("Murmur-1.6.0.dmg") == false)
    }

    @Test func codeAndTerminalsNameTheirProject() {
        let editor = Self.window(app: "Cursor", title: "ScreenWatcher.swift — murmur-app", text: "func capture() async { }")
        let terminal = Self.window(app: "Terminal", title: "shubham@mac: ~/IdeaProjects/murmur — -zsh — 120×40", text: "git status")
        let xcode = Self.window(app: "Xcode", title: "Journal.swift", text: "x", document: "/Users/shubham/IdeaProjects/murmur/Sources/Journal.swift")
        #expect(ItemReader.read(editor, me: [], calendar: Self.calendar).first?.project == "murmur-app")
        #expect(ItemReader.read(terminal, me: [], calendar: Self.calendar).first?.project == "murmur")
        #expect(ItemReader.read(xcode, me: [], calendar: Self.calendar).first?.project == "murmur")
        #expect(BrainModel.projectCore("murmur-app") == BrainModel.projectCore("murmur"))
    }

    @Test func issuesEmailAndSentMessages() throws {
        let issue = Self.window(title: "Fix the brief · Issue #12 · shubhamsWEB/murmur-app",
                                url: "https://github.com/shubhamsWEB/murmur-app/issues/12", text: "Open")
        #expect(ItemReader.read(issue, me: [], calendar: Self.calendar).first?.key == "issue|shubhamsweb/murmur-app#12")
        let mail = Self.window(title: "Q3 deck review - shubham@gmail.com - Gmail", url: "https://mail.google.com/mail/u/0/#inbox/abc",
                               text: "Priya Sharma <priya@acme.com>\nto me\nCan you send the deck by Friday?")
        let email = try #require(ItemReader.read(mail, me: ["Shubham Agrawal"], calendar: Self.calendar).first { $0.kind == .email })
        #expect(email.title == "Q3 deck review" && email.actor == "Priya Sharma")
        let chat = Self.window(app: "WhatsApp", title: "Priya Sharma", text: "Priya: see you tomorrow", authored: "Sure, I'll send it Thursday")
        let sent = try #require(ItemReader.read(chat, me: [], calendar: Self.calendar).first { $0.kind == .message })
        #expect(sent.people == ["Priya Sharma"] && sent.fields["text"] == "Sure, I'll send it Thursday")
    }

    @Test func daysAndTimesAreReadExactly() {
        let reference = Self.date("2026-11-06 12:00")
        let days = ScreenDates.find(in: "Sun, 08 Nov 2026 · Nov 9 · 2026-12-01 · 05/01/2027 · 30 Feb", reference: reference,
                                    calendar: Self.calendar).map { ScreenDates.dayKey($0.date, calendar: Self.calendar) }
        #expect(days == ["2026-11-08", "2026-11-09", "2026-12-01", "2027-01-05"])
        #expect(ScreenDates.find(in: "2 Jan", reference: reference, calendar: Self.calendar).first.map {
            ScreenDates.dayKey($0.date, calendar: Self.calendar) } == "2027-01-02")   // no year: the next one
        #expect(ScreenDates.times(in: "at 6:05 pm, 22:40 hrs, v1.6.0, 3.14").map { "\($0.hour):\($0.minute)" } == ["18:5", "22:40"])
    }

    // MARK: Episodes

    static func sighting(_ id: Int64, _ start: String, minutes: Double, app: String, context: String, project: String = "",
                         kind: WindowKind = .work) -> Episodes.Sighting {
        let begin = date(start)
        return Episodes.Sighting(id: id, snapshot: id, start: begin, end: begin.addingTimeInterval(minutes * 60), app: app,
                                 title: "\(app) \(id)", domain: "", kind: kind, context: context, project: project)
    }

    @Test func oneTaskAcrossAppsIsOneEpisode() {
        let sightings = [
            Self.sighting(1, "2026-11-06 10:00", minutes: 20, app: "Cursor", context: "project:murmur", project: "murmur"),
            Self.sighting(2, "2026-11-06 10:20", minutes: 1, app: "Slack", context: "person:priya", kind: .conversation),
            Self.sighting(3, "2026-11-06 10:21", minutes: 5, app: "Terminal", context: "project:murmur", project: "murmur"),
            Self.sighting(4, "2026-11-06 10:26", minutes: 4, app: "Google Chrome", context: "site:developer.apple.com", kind: .docs),
            Self.sighting(5, "2026-11-06 10:30", minutes: 10, app: "Google Chrome", context: "project:murmur", project: "murmur"),
            // Then a long talk with Priya, and after an hour away, something else.
            Self.sighting(6, "2026-11-06 10:41", minutes: 12, app: "Slack", context: "person:priya", kind: .conversation),
            Self.sighting(7, "2026-11-06 12:00", minutes: 30, app: "Keynote", context: "app:keynote"),
        ]
        let episodes = Episodes.segment(sightings, now: Self.date("2026-11-06 12:20"))
        #expect(episodes.map(\.sightings) == [[1, 2, 3, 4, 5], [6], [7]])
        #expect(episodes[0].project == "murmur" && episodes[0].final)
        #expect(episodes[1].context == "person:priya" && episodes[1].final)
        #expect(!episodes[2].final)   // still going
        #expect(abs(episodes[0].seconds - 40 * 60) < 1)
    }

    @Test func aFeedBreaksTheWork() {
        let sightings = [
            Self.sighting(1, "2026-11-06 10:00", minutes: 20, app: "Cursor", context: "project:murmur", project: "murmur"),
            Self.sighting(2, "2026-11-06 10:20", minutes: 15, app: "Google Chrome", context: "site:youtube.com", kind: .video),
            Self.sighting(3, "2026-11-06 10:35", minutes: 10, app: "Cursor", context: "project:murmur", project: "murmur"),
        ]
        #expect(Episodes.segment(sightings, now: Self.date("2026-11-07 10:00")).map(\.sightings) == [[1], [2], [3]])
    }

    // MARK: Store

    @Test func itemsAndEpisodesAreKeptWithWhatTheyCameFrom() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graph-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        let graph = MemoryGraph(url: url)
        let start = Self.date("2026-11-06 10:00")
        let code = journal.record(Journal.Capture(app: "Cursor", bundle: "x", title: "ScreenWatcher.swift — murmur-app",
                                                  text: "func capture() async { let power = Power.now() }"), now: start)
        let rel = journal.record(Journal.Capture(app: "Google Chrome", bundle: "y", title: Self.release.title, url: Self.release.url,
                                                 text: Self.release.text), now: start.addingTimeInterval(1200))
        let s1 = graph.sighted(snapshot: code.id, at: start, app: "Cursor", title: "ScreenWatcher.swift — murmur-app", domain: "", kind: "work")
        graph.stayed(s1, until: start.addingTimeInterval(1190))
        let s2 = graph.sighted(snapshot: rel.id, at: start.addingTimeInterval(1200), app: "Google Chrome", title: Self.release.title,
                               domain: "github.com", kind: "page")
        graph.stayed(s2, until: start.addingTimeInterval(1500))
        #expect(graph.readItems(from: journal, me: ["Shubham Agrawal"], now: start.addingTimeInterval(1600), calendar: Self.calendar) >= 2)
        let finished = graph.segment(now: start.addingTimeInterval(4000))
        #expect(finished.count == 1)
        let episode = try #require(graph.episode(id: finished[0]))
        #expect(episode.project == "murmur")
        #expect(Set(graph.items(ofEpisode: episode.id).map(\.item.kind)) == [.code, .release])
        #expect(graph.searchItems("murmur release").first?.item.kind == .release)
        #expect(graph.unread().map(\.id) == [episode.id])
        // Cutting again changes nothing finished.
        #expect(graph.segment(now: start.addingTimeInterval(5000)).isEmpty)
        #expect(graph.counts().episodes == 1)
    }

    // MARK: Reading an episode

    @Test func whatTheModelWritesIsCheckedAgainstTheWindows() {
        let source = Self.itinerary.text + "\n" + Self.release.text
        #expect(EpisodeReader.detailsFound("Flight 6E 537 departs 10:15 on 8 Nov", in: source))
        #expect(!EpisodeReader.detailsFound("Flight 6E 537 departs 11:35 on 8 Nov", in: source))
        #expect(!EpisodeReader.detailsFound("Murmur 1.7.0 was released", in: source))
        #expect(EpisodeReader.detailsFound("Murmur 1.6 was released on Nov 6", in: source))
        #expect(!EpisodeReader.detailsFound("Released in December", in: source))
        #expect(EpisodeReader.quoteFound("Murmur now remembers who's who, what's coming up", in: source))
        #expect(EpisodeReader.quoteFound("Murmur remembers who's who, what's coming up", in: source))   // a word dropped
        #expect(!EpisodeReader.quoteFound("Murmur forgets everything you told it", in: source))
        let result = EpisodeReader.parse("""
            {"title": "Releasing Murmur 1.6.0", "summary": "You published Murmur 1.6.0 on GitHub.", "outcome": "released",
             "memories": [
              {"about": "Murmur", "about_kind": "project", "text": "Murmur remembers who's who and what's coming up.",
               "kind": "fact", "importance": 8, "quote": "Murmur now remembers who's who, what's coming up"},
              {"about": "Murmur", "about_kind": "project", "text": "Murmur 2.0 adds a Windows memory.",
               "kind": "fact", "importance": 8, "quote": "Murmur 2.0 adds Windows memory"}],
             "promises": [{"summary": "Send Priya the deck", "kind": "promised", "status": "open", "quote": "I'll send the deck"}]}
            """, source: source)
        #expect(result.title == "Releasing Murmur 1.6.0")
        #expect(result.memories.map(\.text) == ["Murmur remembers who's who and what's coming up."])
        #expect(result.promises.isEmpty)   // its words aren't there
        // No quote at all: every detail has to be there.
        let unquoted = EpisodeReader.parse("""
            {"title": "x", "summary": "", "outcome": "", "memories": [
              {"about": "Murmur", "about_kind": "project", "text": "Murmur 1.6.0 has a morning brief and evening wrap-up.", "kind": "fact", "importance": 7},
              {"about": "Murmur", "about_kind": "project", "text": "Murmur 1.6.2 has a morning brief.", "kind": "fact", "importance": 7}],
             "promises": []}
            """, source: source)
        #expect(unquoted.memories.map(\.text) == ["Murmur 1.6.0 has a morning brief and evening wrap-up."])
        #expect(result.unsupported == 2)
    }

    @Test func anEpisodeIsReadOnceIntoMemoryPlansAndConnections() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("episode-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url), graph = MemoryGraph(url: url), brain = BrainStore(url: url)
        let me = try #require(brain.entity(named: "You", kind: .me))
        brain.addAlias("Shubham Agrawal", to: me)
        let start = Self.date("2026-11-06 21:00")
        let book = journal.record(Journal.Capture(app: "Google Chrome", bundle: "c", title: Self.itinerary.title, url: Self.itinerary.url,
                                                  text: Self.itinerary.text), now: start)
        let rel = journal.record(Journal.Capture(app: "Google Chrome", bundle: "c", title: Self.release.title, url: Self.release.url,
                                                 text: Self.release.text), now: start.addingTimeInterval(400))
        let a = graph.sighted(snapshot: book.id, at: start, app: "Google Chrome", title: Self.itinerary.title, domain: "goindigo.in", kind: "page")
        graph.stayed(a, until: start.addingTimeInterval(300))
        let b = graph.sighted(snapshot: rel.id, at: start.addingTimeInterval(400), app: "Google Chrome", title: Self.release.title,
                              domain: "github.com", kind: "page")
        graph.stayed(b, until: start.addingTimeInterval(900))
        let now = Self.date("2026-11-06 22:00")
        graph.readItems(from: journal, me: brain.meNames(), now: now, calendar: Self.calendar)
        graph.segment(now: now)
        let asked = Counter()
        let read = await EpisodeReader.pass(graph: graph, journal: journal, brain: brain, ask: { system, user in
            await asked.add(user)
            return #"{"title": "Booking a flight and releasing Murmur", "summary": "", "outcome": "done", "memories": [], "promises": []}"#
        }, now: now, calendar: Self.calendar)
        #expect(read >= 1)
        #expect(await asked.count >= 1)
        #expect(await asked.last.contains("Departs: Sun 8 Nov 2026, 10:15"))
        // The flight as a plan with its time, and its check-in deadlines.
        let plans = journal.loops(limit: 20).filter { $0.kind == "plan" }
        #expect(plans.contains { $0.summary.contains("6E 537") && $0.due == Self.date("2026-11-08 10:15") })
        #expect(plans.contains { $0.summary.hasPrefix("Check-in closes") && $0.due == Self.date("2026-11-08 09:15") })
        // The release as a memory about the project, and the user connected to it.
        let memories = brain.fromScreen(limit: 20)
        #expect(memories.contains { $0.memory.text.hasPrefix("Released Murmur 1.6.0 on Fri 6 Nov 2026") })
        let project = try #require(brain.entity(named: "Murmur", kind: .project))
        #expect(graph.edges(of: project).contains { $0.rel == "released" }, "\(graph.edges(of: me)) \(project) \(graph.db.rows("SELECT id, kind, name, key, aliases FROM entity", []))")
        // Read once.
        #expect(graph.unread().isEmpty)
    }

    @Test func questionsAboutTheUsersWorldAreAnsweredFromWhatWasSeen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recall-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url), graph = MemoryGraph(url: url), brain = BrainStore(url: url)
        brain.addAlias("Shubham Agrawal", to: try #require(brain.entity(named: "You", kind: .me)))
        let start = Self.date("2026-11-06 21:00")
        for (index, window) in [Self.itinerary, Self.release].enumerated() {
            let at = start.addingTimeInterval(Double(index) * 1200)
            let kept = journal.record(Journal.Capture(app: window.app, bundle: "c", title: window.title, url: window.url, text: window.text), now: at)
            graph.stayed(graph.sighted(snapshot: kept.id, at: at, app: window.app, title: window.title, domain: window.domain, kind: "page"),
                         until: at.addingTimeInterval(600))
        }
        let now = Self.date("2026-11-07 09:00")
        graph.readItems(from: journal, me: brain.meNames(), now: now, calendar: Self.calendar)
        graph.segment(now: now)
        await EpisodeReader.pass(graph: graph, journal: journal, brain: brain, ask: { _, user in
            user.contains("Murmur 1.6.0")
                ? #"{"title": "Releasing Murmur 1.6.0", "summary": "You published Murmur 1.6.0 on GitHub.", "outcome": "released", "memories": [], "promises": []}"#
                : #"{"title": "Checking the itinerary for 6E 537", "summary": "", "outcome": "booked", "memories": [], "promises": []}"#
        }, now: now, calendar: Self.calendar)
        func ask(_ question: String) -> String {
            MemoryRecall.lines(for: question, graph: graph, brain: brain, now: now, calendar: Self.calendar).joined(separator: "\n")
        }
        let flight = ask("When is my flight?")
        #expect(flight.contains("Departs: Sun 8 Nov 2026, 10:15") && !flight.contains("11:35"))
        #expect(flight.contains("Check-in closes: 2026-11-08 09:15"))
        let release = ask("Which app did I release recently?")
        #expect(release.hasPrefix("- Release: Murmur 1.6.0"))
        #expect(release.contains("second brain"))
        let yesterday = ask("What did I do yesterday?")
        #expect(yesterday.contains("Releasing Murmur 1.6.0") && yesterday.contains("Checking the itinerary for 6E 537"))
        let project = ask("What's going on with Murmur?")
        #expect(project.contains("you released it"))
        #expect(ask("What's the weather like?").isEmpty)
        // Answered at once, without a model.
        func direct(_ question: String) -> String? { MemoryRecall.directAnswer(question, graph: graph, now: now, calendar: Self.calendar) }
        #expect(direct("When is my flight?") == "Flight 6E 537 Bengaluru to Raipur departs tomorrow at 10:15. Check-in closes at 09:15. It connects to 6E 7575.")
        #expect(direct("Which app did I release recently?")?.hasPrefix("You released Murmur 1.6.0 on Friday 6 November: What's new on the Mac") == true)
        #expect(direct("What did I do yesterday?")?.contains("Releasing Murmur 1.6.0 (10 min)") == true)
        #expect(direct("Who is Priya?") == nil)
    }

    @Test func readingWithClaudeIsOffUntilChosenAndNeedsAKey() throws {
        // Settings saved before the choice existed still load, with it off.
        let old = try JSONDecoder().decode(ScreenMemorySettings.self, from: Data(#"{"enabled": true, "rules": {"excluded": []}, "always": true, "from": 9, "to": 19, "weekends": true, "brief": "09:00", "wrap": "18:30"}"#.utf8))
        #expect(old.enabled && old.cloudReader == nil)
        CloudReader.keys = [:]
        #expect(CloudReader.ask("anthropic") == nil)
        let line = CloudReader.handoff(anthropic: "sk-test", anthropicModel: "claude-haiku-5-5", workspace: nil, openai: nil,
                                       openaiModel: "gpt-6-luna")
        CloudReader.keys = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        defer { CloudReader.keys = [:] }
        #expect(CloudReader.available("anthropic") && !CloudReader.available("openai"))
        #expect(CloudReader.ask("anthropic") != nil && CloudReader.ask("openai") == nil && CloudReader.ask("local") == nil)
    }

    @Test func whatMustStayOnTheMacIsNeverSent() {
        let bank = Self.window(title: "HDFC Bank NetBanking", url: "https://netbanking.hdfcbank.com/netbanking/", text: "Balance 1,20,000")
        let tax = Self.window(title: "e-Filing | Income Tax Department", url: "https://eportal.incometax.gov.in/iec/foservices", text: "Return")
        let lab = Self.window(app: "Preview", title: "Lab Report - Thyroid.pdf", text: "TSH 3.2")
        let id = Self.window(title: "Form", url: "https://example.com/kyc", text: "Name Shubham, PAN ABCDE1234F")
        for window in [bank, tax, lab, id] { #expect(CloudPrivacy.sensitive(window) != nil, "\(window.title)") }
        #expect(CloudPrivacy.sensitive(Self.release) == nil && CloudPrivacy.sensitive(Self.itinerary) == nil)
        let scrubbed = CloudPrivacy.scrub("""
            Mail priya@acme.com or call +91 98450 12345. PNR: K7QX2M. Booking reference ABC123.
            https://example.com/track?token=abc123&id=9 departs 2026-11-08 10:15, flight 6E 537, v1.6.0
            """)
        #expect(!scrubbed.contains("priya@acme.com") && !scrubbed.contains("98450") && !scrubbed.contains("K7QX2M")
                && !scrubbed.contains("ABC123") && !scrubbed.contains("token="))
        #expect(scrubbed.contains("2026-11-08 10:15") && scrubbed.contains("6E 537") && scrubbed.contains("v1.6.0"))
    }

    @Test func claudeNeverGetsAPrivateEpisode() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("private-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url), graph = MemoryGraph(url: url), brain = BrainStore(url: url)
        let start = Self.date("2026-11-06 10:00")
        let kept = journal.record(Journal.Capture(app: "Google Chrome", bundle: "c", title: "HDFC Bank NetBanking",
                                                  url: "https://netbanking.hdfcbank.com/x", text: "Account balance and statement"), now: start)
        graph.stayed(graph.sighted(snapshot: kept.id, at: start, app: "Google Chrome", title: "HDFC Bank NetBanking",
                                   domain: "netbanking.hdfcbank.com", kind: "page"), until: start.addingTimeInterval(600))
        graph.segment(now: start.addingTimeInterval(3600))
        let asked = Counter()
        let read = await EpisodeReader.pass(graph: graph, journal: journal, brain: brain, ask: { _, user in
            await asked.add(user); return "{}"
        }, remote: true, now: start.addingTimeInterval(3600), calendar: Self.calendar)
        let sent = await asked.count
        #expect(read == 0 && sent == 0)
        #expect(graph.unreadCount(includePrivate: false) == 0 && graph.unreadCount() == 1)   // the local model reads it
    }

    @Test func howThingsStandFadesInDaysWhatLastsDoesnt() {
        let now = Date()
        func memory(_ kind: BrainModel.Kind, origin: BrainModel.Origin = .screen, days: Double, expires: Date? = nil,
                    importance: Double = 0.6) -> BrainModel.Memory {
            BrainModel.Memory(id: 1, entity: 1, text: "x", kind: kind, slot: nil, confidence: 0.6,
                              created: now.addingTimeInterval(-days * 86400), confirmed: now.addingTimeInterval(-days * 86400),
                              expires: expires, pinned: false, origin: origin, importance: importance)
        }
        #expect(!BrainModel.isStale(memory(.status, days: 3), now: now))
        #expect(BrainModel.isStale(memory(.status, days: 10), now: now))           // "preparing the release": gone in a week or so
        #expect(BrainModel.isStale(memory(.task, days: 25), now: now))
        #expect(!BrainModel.isStale(memory(.fact, days: 60), now: now))            // "Released Murmur 1.6.0" lasts
        #expect(!BrainModel.isStale(memory(.status, origin: .notes, days: 10), now: now))
        #expect(!BrainModel.isStale(memory(.event, days: 30, expires: now.addingTimeInterval(86400)), now: now))   // until its day
        #expect(BrainModel.isStale(memory(.event, days: 1, expires: now.addingTimeInterval(-60)), now: now))
    }

    // MARK: As the user's Mac shows them (2026-11-07)

    /// Gmail's thread of an email the user sent, as Chrome's accessibility tree reads it, with Chrome's tab list on top.
    static let sentThread = window(title: "Murmur, an open-source voice computer I built - shubhama664@gmail.com - Gmail - Google Chrome – Shubham",
                                   url: "https://mail.google.com/mail/u/0/#sent/abc", text: """
        New tab
        Tab search
        Open Gemini in Chrome
        Murmur: hold a key and say it - Memory usage - 378 MB
        Tanay Kothari | LinkedIn - High memory usage - 1.4 GB
        Close
        {"mode":"full","isActive":true,"isUserDisabled":false}
        None selected
        of
        594
        Print all
        In new window
        Murmur, an open-source voice computer I built
        Not important
        Reply
        Forward
        Hi Tanay,
        I'm Shubham, a software engineer at Ford in Bengaluru. My answer so far is Murmur (usemurmur.live), an open-source voice assistant.
        https://www.google.com/url?q= http://github.com/shubhamsWEB/
        murmur-app&source=gmail&ust=
        1794090533660000&sa=E
        Show details
        to
        tanay
        shubhama664@gmail.com
        """, first: date("2026-11-07 04:12"))

    @Test func anEmailTheUserSentIsRememberedWithWhomAndWhat() throws {
        let email = try #require(ItemReader.read(Self.sentThread, me: ["Shubham Agrawal"], calendar: Self.calendar).first { $0.kind == .email })
        #expect(email.mine && email.people == ["Tanay"] && email.actor == "me")
        #expect(email.title == "Murmur, an open-source voice computer I built")
        #expect(email.body.hasPrefix("You emailed Tanay: Murmur, an open-source voice computer I built"))
        #expect(email.fields["start"]?.hasPrefix("Hi Tanay, I'm Shubham, a software engineer at Ford") == true)
        // The browser's own words and Google's redirects are gone from what's read.
        let clean = ScreenText.clean(Self.sentThread.text)
        #expect(!clean.contains("Memory usage") && !clean.contains("Tab search") && !clean.contains("isActive") && !clean.contains("Print all"))
        #expect(clean.contains("Hi Tanay,") && !clean.contains("&sa=E"))
        #expect(ScreenText.cleanTitle("(6714) How to build an local Ai memory - YouTube – Audio playing - High memory usage - 952 MB - Google Chrome – Shubham")
                == "How to build an local Ai memory - YouTube")
    }

    @Test func aSentListIsEveryEmailSent() {
        let sent = Self.window(title: "Sent Mail - shubhama664@gmail.com - Gmail", url: "https://mail.google.com/mail/u/0/#sent", text: """
            To: info , I got lost on thetrost.com — and I think other shoppers do too , 3:09 AM , Hi Harshal, I was on thetrost.com recently as a shopper.
            To: Lenovo 2 , Lenovo Case 2033528661 , Nov 2 , Hi Manjunath, I approve the requested change.
            """, first: Self.date("2026-11-07 04:12"))
        let emails = ItemReader.read(sent, me: ["Shubham"], calendar: Self.calendar).filter { $0.kind == .email }
        #expect(emails.map(\.people) == [["Harshal"], ["Lenovo 2"]])
        #expect(emails.allSatisfy { $0.mine })
        #expect(emails[0].when == Self.date("2026-11-07 03:09"))
        #expect(emails[1].when.map { ScreenDates.dayKey($0, calendar: Self.calendar) } == "2026-11-02")
    }

    @Test func itemsAreKeptBesideTheLivingMemorysSources() throws {
        // The living memory's own "item" table came first on a real Mac: the timeline's items have their own.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("beside-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let brain = BrainStore(url: url), graph = MemoryGraph(url: url)
        #expect(graph.store(MemoryItem(kind: .email, key: "email|x", title: "x", mine: true), snapshot: 1, seen: Date(), calendar: Self.calendar))
        #expect(graph.items([.email]).count == 1)
        _ = brain.changed(source: "notes", items: ["a": ("h", "A note")], complete: true)
        brain.read(source: "notes", key: "a", hash: "h")
        #expect(brain.changed(source: "notes", items: ["a": ("h", "A note")], complete: true).isEmpty)   // sources still keep what they read
    }

    @Test func aReleaseListIsEachRelease() {
        let list = Self.window(title: "Releases · shubhamsWEB/murmur-app", url: "https://github.com/shubhamsWEB/murmur-app/releases", text: """
            Edit: Murmur 1.3.0
            Delete: Murmur 1.3.0
            Releases
            Draft a new release
            Murmur 1.5.1
            Latest
            @github-actions
            github-actions
            released this
            Tag v1.5.1
            Commit a93f56b
            What's new on Windows
            AI cleanup can now use Murmur's own cleanup model on your PC, as it does on the Mac.
            Assets 7
            Murmur 1.5.0
            Tag v1.5.0
            Commit dc0ece5
            Two small models trained for Murmur, downloaded through Ollama and run entirely on your Mac.
            """)
        let releases = ItemReader.read(list, me: ["Shubham Agrawal"], calendar: Self.calendar).filter { $0.kind == .release }
        #expect(releases.map(\.title) == ["Murmur 1.5.1", "Murmur 1.5.0"])
        #expect(releases.allSatisfy { $0.mine })
        #expect(releases[0].fields["notes"]?.hasPrefix("What's new on Windows AI cleanup") == true)
        let tag = Self.window(title: "Release v1.6.0 · shubhamsWEB/murmur-app", url: "https://github.com/shubhamsWEB/murmur-app/releases/tag/v1.6.0",
                              text: "Create release from tag\n@shubhamsWEB\nshubhamsWEB tagged this\nMurmur 1.6.0")
        // A tag not published yet is kept as tagged, never as released.
        let tagged = ItemReader.read(tag, me: ["Shubham Agrawal"], calendar: Self.calendar).filter { $0.kind == .release }
        #expect(tagged.count == 1 && tagged[0].fields["status"] == "tagged" && tagged[0].title == "Murmur 1.6.0" && tagged[0].mine)
        #expect(ItemReader.newerVersion("1.10.0", than: "1.9.2") && !ItemReader.newerVersion("1.5.0", than: "1.5.1"))
    }

    // MARK: Threads

    @Test func whatTheUserSentBecomesAThreadAnAssistantCanActOn() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("threads-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let brain = BrainStore(url: url), journal = Journal(url: url), graph = MemoryGraph(url: url)
        let sent = Self.date("2026-11-07 03:58")
        let kept = journal.record(Journal.Capture(app: "Google Chrome", bundle: "c", title: Self.sentThread.title, url: Self.sentThread.url,
                                                  text: Self.sentThread.text.replacingOccurrences(of: "an open-source voice assistant.",
                                                                            with: "an open-source voice assistant.\nI'd love to build this at Wispr. I've applied for Product Engineer, New Products and Design Engineer, and I'm happy to relocate to SF.")),
                                  now: sent)
        graph.stayed(graph.sighted(snapshot: kept.id, at: sent, app: "Google Chrome", title: Self.sentThread.title, domain: "mail.google.com",
                                   kind: "conversation"), until: sent.addingTimeInterval(120))
        graph.readItems(from: journal, me: ["Shubham Agrawal"], now: sent.addingTimeInterval(300), calendar: Self.calendar)
        #expect(Threads.update(graph: graph, now: sent.addingTimeInterval(300)) == 1)
        let thread = try #require(graph.threads().first)
        #expect(thread.person == "Tanay" && thread.status == .waiting && thread.followUp == sent.addingTimeInterval(4 * 86400))
        // The model's notes, checked: what the email doesn't say (a role, a company's other name) goes.
        await Threads.enrich(graph: graph, journal: journal, brain: brain, ask: { _, _ in
            #"{"title": "Joining Wispr: pitch to Tanay", "ask": "A walkthrough of Murmur, and to build it at Wispr", "details": ["Applied for Product Engineer, New Products and Design Engineer", "Happy to relocate to SF", "Tanay is the CEO of Wispr Flow"], "organization": "Wispr", "role": "CEO", "goal": "job search", "follow_up_days": 4, "importance": 9}"#
        }, now: sent.addingTimeInterval(300))
        let notes = try #require(graph.threads().first)
        #expect(notes.title == "Joining Wispr: pitch to Tanay" && notes.organization == "Wispr" && notes.role.isEmpty)
        #expect(notes.details == ["Applied for Product Engineer, New Products and Design Engineer", "Happy to relocate to SF"])
        #expect(notes.goal == "job search" && notes.priority(now: sent) >= 7)
        // Four days on, no reply: time to follow up; and it's what to focus on.
        let later = sent.addingTimeInterval(5 * 86400)
        Threads.update(graph: graph, now: later)
        #expect(graph.threads().first?.status == .nudge)
        let focus = MemoryRecall.directAnswer("What should I focus on today?", graph: graph, now: later, calendar: Self.calendar)
        #expect(focus?.hasPrefix("Follow up: Tanay (Wispr), Joining Wispr: pitch to Tanay") == true)
        #expect(MemoryRoute.classify("Did Tanay reply?", hour: 10) == .question)
        // His reply, seen in the same thread: the user's turn.
        let reply = Self.window(2, title: Self.sentThread.title, url: "https://mail.google.com/mail/u/0/#inbox/abc", text: """
            Murmur, an open-source voice computer I built
            Tanay Kothari <tanay@wispr.ai>
            to me
            Hi Shubham, happy to see a walkthrough. Does Thursday work?
            """, first: later)
        for item in ItemReader.read(reply, me: ["Shubham Agrawal"], calendar: Self.calendar) {
            graph.store(item, snapshot: 2, seen: later, calendar: Self.calendar)
        }
        Threads.update(graph: graph, now: later.addingTimeInterval(60))
        #expect(graph.threads().first?.status == .yourTurn)
        #expect(graph.threads().first?.lastAction == "Tanay Kothari replied")
    }
}

actor Counter {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
    var count: Int { texts.count }
    var last: String { texts.joined(separator: "\n") }
}
