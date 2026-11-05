import Foundation
import Testing
@testable import AgentKit

/// Screen memory: what's kept of the windows you worked in, open loops, the time ledger and the chronicle.
struct JournalTests {
    func journal() -> Journal {
        Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).sqlite"))
    }

    let slack = Journal.Capture(app: "Slack", bundle: "com.tinyspeck.slackmacgap", title: "#design",
                                text: "Priya: can you send the Q3 deck by Friday?\nYou: Sure, I'll send it Friday")

    @Test func theSameContentIsKeptOnce() {
        let store = journal()
        let first = store.record(slack, seconds: 30)
        let again = store.record(slack, seconds: 45)
        #expect(first.new && !again.new && first.id == again.id)
        let now = Date().addingTimeInterval(600)
        let pending = store.pending(now: now)
        #expect(pending.count == 1 && pending[0].seconds == 75 && pending[0].sightings == 2)
        store.consolidated([first.id])
        #expect(store.pending(now: now).isEmpty)
        // The chat moves on: the same snapshot, to be read again.
        var other = slack
        other.text += "\nArjun: joined"
        #expect(store.record(other).id == first.id)
        #expect(store.pending(now: now).count == 1)
    }

    @Test func aWindowStillChangingIsOneSnapshot() {
        let store = journal()
        var chat = Journal.Capture(app: "Claude", bundle: "com.anthropic.claudefordesktop", title: "Claude",
                                   text: "Plan the launch for Murmur with the new memory page and connectors")
        let first = store.record(chat, seconds: 5)
        chat.text += "\nHere's a plan: first the memory page, then connectors, then the launch post"
        let second = store.record(chat, seconds: 5)
        #expect(!second.new && second.id == first.id)
        #expect(store.search("launch post").first?.id == first.id)   // the newer text is what's searchable
        // Another conversation in the same window is its own snapshot.
        chat.text = "Weekend trekking near Bangalore: Skandagiri or Kudremukh, and what to pack"
        #expect(store.record(chat).new)
        // The same title in another app is too.
        var other = chat
        other.app = "Notes"
        #expect(store.record(other).new)
    }

    @Test func addressesBecomeSites() {
        let page = Journal.Capture(app: "Safari", bundle: "com.apple.Safari", title: "Inbox",
                                   url: "https://www.mail.google.com/mail/u/0/#inbox", text: "x")
        #expect(page.domain == "mail.google.com")
        #expect(slack.domain == "")
    }

    @Test func timeAddsUpByHourAndPlace() {
        let store = journal()
        let at = Date()
        store.spend(600, app: "Slack", domain: "", at: at)
        store.spend(300, app: "Slack", domain: "", at: at)
        store.spend(1200, app: "Safari", domain: "github.com", at: at)
        let spent = store.time(from: at.addingTimeInterval(-3600), to: at.addingTimeInterval(3600))
        #expect(spent.map(\.name) == ["github.com", "Slack"])
        #expect(spent[1].seconds == 900)
    }

    @Test func promisesOpenConfirmAndClose() {
        let store = journal()
        var result = store.take([Journal.Promise(summary: "Send Priya the Q3 deck", person: "Priya Shah",
                                                 due: Date().addingTimeInterval(86400))], evidence: [1])
        #expect(result.opened == 1)
        // Seen again, worded a little differently: the same loop.
        result = store.take([Journal.Promise(summary: "Send the Q3 deck to Priya", person: "Priya Shah")], evidence: [2])
        #expect(result.opened == 0 && store.loops().count == 1)
        // Someone else's promise is its own loop.
        store.take([Journal.Promise(summary: "Arjun will review the pricing doc", person: "Arjun", mine: false)], evidence: [3])
        #expect(store.loops().count == 2)
        #expect(store.loops().first?.summary == "Send Priya the Q3 deck")   // due soonest first
        // Done, as seen: closed.
        result = store.take([Journal.Promise(summary: "Sent Priya the Q3 deck", person: "Priya", status: "done")], evidence: [4])
        #expect(result.closed == 1)
        #expect(store.loops().map(\.summary) == ["Arjun will review the pricing doc"])
        #expect(store.loops(status: "done").count == 1)
    }

    @Test func oldLoopsAreDropped() {
        let store = journal()
        store.take([Journal.Promise(summary: "Call the bank about the card")], evidence: [], now: Date().addingTimeInterval(-30 * 86400))
        store.take([], evidence: [])
        #expect(store.loops().isEmpty && store.loops(status: "dropped").count == 1)
    }

    @Test func chronicleRollsUp() {
        let store = journal()
        store.setChronicle(.hour, "2026-11-05T09", "You planned the sprint.")
        store.setChronicle(.hour, "2026-11-05T10", "You reviewed the deck with Priya.")
        store.setChronicle(.hour, "2026-11-06T09", "Another day.")
        #expect(store.chronicles(.hour, within: "2026-11-05").map(\.summary)
            == ["You planned the sprint.", "You reviewed the deck with Priya."])
        #expect(store.searchChronicle("when did I review the deck").first?.period == "2026-11-05T10")
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour) = (2026, 3, 7, 14)
        let date = Calendar.current.date(from: parts)!
        #expect(Journal.Level.hour.period(of: date) == "2026-03-07T14")
        #expect(Journal.Level.month.period(of: date) == "2026-03")
        #expect(Journal.Level.day.below == .hour)
    }

    @Test func searchFindsWhatWasSeen() {
        let store = journal()
        store.record(slack)
        store.record(Journal.Capture(app: "Safari", bundle: "", title: "Pricing", url: "https://acme.com/pricing",
                                     text: "Team plan 12 dollars per seat"))
        #expect(store.search("that pricing page with the team plan").first?.title == "Pricing")
        store.forget(app: "acme.com")
        #expect(store.search("pricing").isEmpty)
    }

    @Test func nudgesAreMadeOnce() {
        let store = journal()
        #expect(!store.nudged("brief:2026-11-05"))
        store.nudge("brief:2026-11-05", kind: "morning", title: "Good morning", body: "Two things are due today.")
        store.nudge("brief:2026-11-05", kind: "morning", title: "Again", body: "x")
        #expect(store.nudged("brief:2026-11-05") && store.latestNudges().count == 1)
    }
}

struct ConsolidatorTests {
    @Test func readsMemoriesAndPromises() {
        let answer = """
            {"memories": [{"about": "Priya Shah", "about_kind": "person", "text": "Priya Shah leads design at Acme",
                           "kind": "fact", "slot": "role", "expires": ""}],
             "promises": [{"summary": "Send Priya the Q3 deck", "person": "Priya Shah", "project": "Q3", "mine": true,
                           "due": "2999-01-10", "status": "open"},
                          {"summary": "Merged the login fix", "person": "", "mine": true, "status": "Completed"},
                          {"summary": "x", "mine": true, "status": "open"}]}
            """
        let reading = Consolidator.parse(answer)
        #expect(reading.memories.count == 1 && reading.memories[0].origin == .screen)
        #expect(reading.promises.count == 2)
        #expect(reading.promises[0].due != nil && reading.promises[0].status == "open")
        #expect(reading.promises[1].status == "done")
    }

    @Test func batchesFitTheBudget() {
        let now = Date()
        let snapshots = (1...10).map { id in
            Journal.Snapshot(id: Int64(id), app: "Notes", title: "Note \(id)", url: nil, domain: "",
                             text: String(repeating: "word ", count: 600), first: now, last: now, seconds: 120, sightings: 1)
        }
        let batches = Consolidator.batches(snapshots, budget: 3000)
        #expect(batches.count > 1)
        #expect(batches.allSatisfy { $0.text.count <= 3000 })
        #expect(batches.flatMap(\.ids) == (1...10).map(Int64.init))
        #expect(batches[0].text.contains("Notes") && batches[0].text.contains("2 min"))
    }

    @Test func secretsNeverReachTheModel() {
        let now = Date()
        let shot = Journal.Snapshot(id: 1, app: "Mail", title: "Code", url: nil, domain: "",
                                    text: "Your verification code is 482913", first: now, last: now, seconds: 5, sightings: 1)
        #expect(!Consolidator.batches([shot])[0].text.contains("482913"))
    }
}

struct NudgeTests {
    @Test func briefAndWrapAreMadeOncePerDay() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nudge-\(UUID().uuidString).sqlite")
        let journal = Journal(url: file), brain = BrainStore(url: file)
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (2026, 11, 5, 9, 30)
        let morning = Calendar.current.date(from: parts)!
        journal.take([Journal.Promise(summary: "Send Priya the Q3 deck", person: "Priya", due: morning.addingTimeInterval(3600 * 2))],
                     evidence: [], now: morning)
        let facts = Nudges.briefFacts(journal: journal, brain: brain, now: morning)
        #expect(facts.contains("Send Priya the Q3 deck"))
        var settings = ScreenMemorySettings()
        settings.enabled = true
        await Nudges.make(journal: journal, brain: brain, settings: settings, model: nil, now: morning)
        await Nudges.make(journal: journal, brain: brain, settings: settings, model: nil, now: morning.addingTimeInterval(60))
        let made = journal.unseenNudges()
        #expect(made.filter { $0.kind == "brief" }.count == 1)
        #expect(made.contains { $0.kind == "due" && $0.body.contains("Q3 deck") })
        #expect(!made.contains { $0.kind == "wrap" })   // 9:30 is before 18:30
        journal.seen(nudge: made[0].key)
        #expect(journal.unseenNudges().count == made.count - 1)
        // A Mac opened at night doesn't get the morning's brief.
        parts.day = 6; parts.hour = 22
        let night = Calendar.current.date(from: parts)!
        await Nudges.make(journal: journal, brain: brain, settings: settings, model: nil, now: night)
        #expect(!journal.nudged("brief:2026-11-06"))
    }

    @Test func readingHours() {
        var settings = ScreenMemorySettings()
        settings.enabled = true
        settings.always = false
        (settings.from, settings.to, settings.weekends) = (9, 19, false)
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour) = (2026, 11, 5, 10)   // a Thursday
        let thursday = Calendar.current.date(from: parts)!
        #expect(settings.readsNow(thursday))
        #expect(!settings.readsNow(thursday.addingTimeInterval(10 * 3600)))
        #expect(!settings.readsNow(thursday.addingTimeInterval(2 * 86400)))   // Saturday
        settings.enabled = false
        #expect(!settings.readsNow(thursday))
    }
}

struct RecallTests {
    @Test func addsWhatTheCommandIsAbout() {
        let journal = Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("recall-\(UUID().uuidString).sqlite"))
        journal.take([Journal.Promise(summary: "Send Priya the Q3 deck", person: "Priya")], evidence: [])
        let today = Journal.Level.day.period(of: Date())
        journal.setChronicle(.hour, today + "T10", "You reviewed the pricing doc with Arjun.")
        journal.record(Journal.Capture(app: "Safari", bundle: "", title: "Pricing", url: "https://acme.com/pricing",
                                       text: "Team plan 12 dollars per seat"))
        #expect(Recall.context(journal, for: "open Safari").isEmpty)
        #expect(Recall.context(journal, for: "what did I promise Priya?").contains { $0.contains("Q3 deck") })
        #expect(Recall.context(journal, for: "what did I work on today").contains { $0.contains("pricing doc") })
        #expect(Recall.context(journal, for: "find that page I saw about the team plan").contains { $0.contains("acme.com") })
        let answer = Recall.answer(journal, for: "Priya")
        #expect(answer.contains { $0.contains("You promised") })
    }
}

struct MemoryServerTests {
    @Test func answersLikeAnMCPServer() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("server-\(UUID().uuidString).sqlite")
        let brain = BrainStore(url: file), journal = Journal(url: file)
        brain.apply([BrainModel.Candidate(about: "Priya Shah", aboutKind: .person, text: "Priya Shah leads design at Acme",
                                          kind: .fact, confidence: 0.9, origin: .contacts)], item: nil)
        journal.take([Journal.Promise(summary: "Send Priya the Q3 deck", person: "Priya")], evidence: [])
        let server = MemoryServer(brain: brain, journal: journal)
        let hello = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        #expect((hello?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let list = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        #expect(((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count == 6)
        func call(_ name: String, _ arguments: [String: Any]) -> String {
            let reply = server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
            return (((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        #expect(call("search_memory", ["query": "who is Priya"]).contains("leads design"))
        #expect(call("get_open_loops", [:]).contains("Q3 deck"))
        #expect(call("get_chronicle", ["period": "2001-01-01"]).contains("Nothing recorded"))
        #expect((server.handle(["jsonrpc": "2.0", "id": 4, "method": "nope"])?["error"]) != nil)
    }
}
