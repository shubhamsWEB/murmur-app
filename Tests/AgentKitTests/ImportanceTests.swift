import Foundation
import Testing
@testable import AgentKit

/// What matters to the user is kept longer and found first; what they only saw isn't kept as memory at all.
struct ImportanceTests {
    func store() -> BrainStore {
        BrainStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("importance-\(UUID().uuidString).sqlite"))
    }

    @Test func importanceComesFromTheModelOrTheSource() {
        let reading = Consolidator.parse("""
            {"memories": [
              {"about": "me", "about_kind": "me", "text": "The user promised Priya the Q3 deck by Friday", "kind": "task", "importance": 9},
              {"about": "Elon Musk", "about_kind": "person", "text": "Elon Musk posted about rockets on X", "kind": "fact", "importance": "2"},
              {"about": "Acme", "about_kind": "organization", "text": "Acme moved its office to Pune", "kind": "fact"}
            ], "promises": []}
            """)
        #expect(reading.memories.map(\.importance) == [0.9, 0.2, BrainModel.Origin.screen.importance])
        #expect(BrainModel.Candidate(about: "me", aboutKind: .me, text: "x", kind: .fact, confidence: 1, origin: .told).importance == 1)
        #expect(Consolidator.keepFrom > 0.2 && Consolidator.keepFrom < 0.45)
    }

    @Test func importantMemoriesFadeSlower() {
        func memory(_ importance: Double, days: Double) -> BrainModel.Memory {
            let at = Date().addingTimeInterval(-days * 86400)
            return BrainModel.Memory(id: 1, entity: 1, text: "x", kind: .fact, slot: nil, confidence: 0.9, created: at,
                                     confirmed: at, expires: nil, pinned: false, origin: .screen, importance: importance)
        }
        #expect(BrainModel.strength(memory(0.9, days: 300)) > BrainModel.strength(memory(0.5, days: 300)) * 1.2)
        // After a year and a half nobody said either again: the unimportant one is gone, the important one isn't.
        #expect(BrainModel.isStale(memory(0.1, days: 550)) && !BrainModel.isStale(memory(0.9, days: 550)))
        // A default-importance memory fades as it always did.
        #expect(abs(BrainModel.strength(memory(0.5, days: 365)) - 0.45) < 0.01)
    }

    @Test func importanceIsKeptAndRaisedWhenSeenAgain() {
        let brain = store()
        func fact(_ importance: Double) -> BrainModel.Candidate {
            BrainModel.Candidate(about: "Priya Shah", aboutKind: .person, text: "Priya Shah leads design at Acme", kind: .fact,
                                 confidence: 0.6, origin: .screen, importance: importance)
        }
        brain.apply([fact(0.5)], item: nil)
        brain.apply([fact(0.8)], item: nil)
        brain.apply([fact(0.4)], item: nil)
        #expect(brain.search("Priya").first?.memory.importance == 0.8)
    }

    @Test func whatMattersRanksFirstAmongEquals() {
        let brain = store()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rank-\(UUID().uuidString).sqlite")
        _ = file
        brain.apply([
            BrainModel.Candidate(about: "Q3 launch", aboutKind: .project, text: "A stranger's Q3 launch went viral on LinkedIn",
                                 kind: .fact, confidence: 0.6, origin: .screen, importance: 0.3),
            BrainModel.Candidate(about: "Q3 launch", aboutKind: .project, text: "Your Q3 launch review is with Priya on Monday",
                                 kind: .event, confidence: 0.6, origin: .screen, importance: 0.9),
        ], item: nil)
        let search = MemorySearch(store: brain, journal: Journal(), vectors: MemoryVectors())
        #expect(search.memories("Q3 launch", vector: nil).first?.memory.text.hasPrefix("Your Q3 launch review") == true)
    }

    @Test func windowsSayHowTheyWereUsed() {
        let now = Date()
        func shot(_ url: String?, _ text: String, sightings: Int = 1) -> Journal.Snapshot {
            Journal.Snapshot(id: 1, app: "Chrome", title: "t", url: url, domain: url.flatMap { URL(string: $0)?.host }?
                .replacingOccurrences(of: "www.", with: "") ?? "", text: text, first: now, last: now, seconds: 60, sightings: sightings)
        }
        let known: (String) -> [String] = { text in text.contains("Priya Shah") ? ["Priya Shah"] : [] }
        let me = ["Shubham Agrawal", "Shubham"]
        #expect(Engagement.tags(shot("https://www.linkedin.com/feed/", "Someone posted about AI"), me: me, known: known)
            == [WindowKind.feed.label, "browsing"])
        #expect(Engagement.tags(shot("https://www.linkedin.com/messaging/thread/1", "Hi Shubham, can we talk?"), me: me, known: known)
            == [WindowKind.conversation.label, "mentions you"])
        #expect(Engagement.tags(shot(nil, "Priya Shah: the deck looks good", sightings: 4), me: me, known: known)
            == [WindowKind.app.label, "people you know: Priya Shah", "came back 4 times"])
        #expect(!Engagement.mentions("Shubhamkar is here", any: me))   // a word, not a name inside another
        let batch = Consolidator.batches([shot("https://www.linkedin.com/feed/", "A post")]) { _ in ["browsing"] }
        #expect(batch[0].text.contains("; how it was used: browsing]"))
        #expect(Consolidator.system(user: ["Shubham Agrawal"]).contains("The user is Shubham Agrawal"))
    }

    @Test func theUsersOwnNamesComeFromTheirCard() {
        let brain = store()
        brain.apply([BrainModel.Candidate(about: "me", aboutKind: .me, text: "Your name is Sam Lee", kind: .fact, confidence: 1,
                                          origin: .contacts)], item: nil)
        let me = brain.entity(named: "me", kind: .me)!
        brain.addAlias("Sam Lee", to: me)
        brain.addAlias("Sam", to: me)
        #expect(Set(brain.meNames()) == ["Sam Lee", "Sam"])
        brain.apply([BrainModel.Candidate(about: "Priya Shah", aboutKind: .person, text: "Priya Shah leads design", kind: .fact,
                                          confidence: 1, origin: .contacts)], item: nil)
        #expect(brain.knownPeople(in: "Met Priya Shah today") == ["Priya Shah"])
    }
}

/// Qwen3 1.7B's real answer to a LinkedIn feed and a Slack thread (2026-11-05): it took the labels for content.
struct JudgeTests {
    @Test func whatOnlyPassedByIsLeftOutEvenWhenTheModelOverratesIt() {
        let answer = """
            {"memories": [
              {"about": "LinkedIn", "about_kind": "organization", "text": "Browsing LinkedIn feed", "kind": "fact", "importance": 9},
              {"about": "Slack", "about_kind": "platform", "text": "Mentions you in #design channel", "kind": "fact", "importance": 7},
              {"about": "Priya Shah", "about_kind": "person", "text": "Request to send Q3 deck by Friday", "kind": "relationship", "importance": 9},
              {"about": "Shubham", "about_kind": "me", "text": "Will send Q3 deck Thursday night", "kind": "status", "importance": 9},
              {"about": "Satya Nadella", "about_kind": "person", "text": "Satya Nadella announced a Microsoft AI datacenter in Pune", "kind": "fact", "importance": 8}
            ], "promises": [{"summary": "Send Priya the Q3 deck", "person": "Priya Shah", "mine": true, "due": "2026-11-10", "status": "open"}]}
            """
        let now = Date()
        let feed = Journal.Snapshot(id: 1, app: "Google Chrome", title: "Feed | LinkedIn", url: "https://www.linkedin.com/feed/",
                                    domain: "linkedin.com", text: "Satya Nadella: Excited to announce Microsoft's new AI datacenter in Pune.",
                                    first: now, last: now, seconds: 180, sightings: 1)
        let slack = Journal.Snapshot(id: 2, app: "Slack", title: "#design", url: nil, domain: "",
                                     text: "Priya Shah: Shubham, can you send me the Q3 deck by Friday?\nShubham: Sure, Thursday night.",
                                     first: now, last: now, seconds: 360, sightings: 1)
        let kept = Consolidator.judge(Consolidator.parse(answer).memories, seen: [feed, slack], browsing: [1],
                                      me: ["Shubham Agrawal", "Shubham"]) { $0 == "Priya Shah" ? ["Priya Shah"] : [] }
            .filter { $0.importance >= Consolidator.keepFrom }
        #expect(kept.map(\.about) == ["Priya Shah", "Shubham"])
        #expect(Consolidator.parse(answer).promises.first?.summary == "Send Priya the Q3 deck")
    }
}

/// Qwen3 4B's real memories from the Claude app's window (2026-11-05, Murmur's built-in reader): it read the chat
/// list in the sidebar as things the user was doing.
struct GroundingTests {
    let now = Date()

    @Test func sidebarsAndMenusAreNotContent() {
        let titles = ["Kunafa base ingredients and preparation", "Sudden tongue symptoms", "India carbon credit scheme",
                      "Crossbeats Lumex Vista projector", "Projector home screen designs", "Outreach to Whisperflow team"]
        let lines: [(text: String, control: Bool)] = [("New chat", true)] + titles.map { ($0, true) }
            + [("You said: check the memories now", false), ("The built-in model is working", false), ("Copy", true)]
        #expect(ScreenText.content(lines) == ["You said: check the memories now", "The built-in model is working", "Copy"])
        // A few buttons among the text stay (a link in a sentence, "Reply").
        #expect(ScreenText.content([("Reply", true), ("Thanks, see you Monday", false)]).count == 2)
        #expect(ScreenText.chrome.contains("AXLandmarkNavigation"))
    }

    @Test func madeUpMemoriesAreLeftOut() {
        // The window as read now: the sidebar's titles are gone, the conversation stays.
        let window = Journal.Snapshot(id: 1, app: "Claude", title: "Claude", url: nil, domain: "",
                                      text: "You said: Shubham Agrawal here, check the memories now\nPress\n"
                                          + "Claude: The built-in model ran on Metal and wrote the summary of 22:00. "
                                          + "Murmur's screen memory kept 241 windows.",
                                      first: now, last: now, seconds: 120, sightings: 2)
        let answer = """
            {"memories": [
              {"about": "Kunafa base ingredients and preparation", "about_kind": "topic", "text": "Kunafa base ingredients and preparation are in progress and have options for further configuration.", "kind": "status", "importance": 6},
              {"about": "India carbon credit scheme", "about_kind": "topic", "text": "Shubham Agrawal is researching the India carbon credit scheme", "kind": "status", "importance": 6},
              {"about": "Press", "about_kind": "topic", "text": "Shubham interacted with Press multiple times in the Claude app on Thursday, 7 November 2026.", "kind": "fact", "importance": 7},
              {"about": "LinkedIn post about AI SDLC talk", "about_kind": "topic", "text": "Career move: pitching Murmur", "kind": "fact", "importance": 5},
              {"about": "Blackjack at Pinup Casino", "about_kind": "topic", "text": "Career move: pitching Murmur", "kind": "fact", "importance": 5},
              {"about": "Murmur", "about_kind": "project", "text": "Murmur's screen memory kept 241 windows", "kind": "status", "importance": 7},
              {"about": "me", "about_kind": "me", "text": "The built-in model ran on Metal for Murmur", "kind": "status", "importance": 6}
            ], "promises": []}
            """
        let kept = Consolidator.judge(Consolidator.parse(answer).memories, seen: [window], browsing: [],
                                      me: ["Shubham Agrawal", "Shubham"]) { _ in [] }
        #expect(kept.map(\.about) == ["Murmur", "me"])
    }
}

/// The real case (2026-11-05): "Send Priya the Q3 deck" was a demo message on a product's website, and became a promise.
struct PromiseTests {
    let now = Date()
    func window(_ app: String, _ url: String?, _ text: String) -> Journal.Snapshot {
        Journal.Snapshot(id: 1, app: app, title: "t", url: url, domain: url.flatMap { URL(string: $0)?.host }?
            .replacingOccurrences(of: "www.", with: "") ?? "", text: text, first: now, last: now, seconds: 60, sightings: 1)
    }
    /// Priya asking for the deck: asked of the user (their own promise needs their own words: WindowUnderstandingTests).
    let deck = Journal.Promise(summary: "Send Priya the Q3 deck", person: "Priya Shah", kind: "asked")

    @Test func aDemoOnAWebsiteIsNotAPromise() {
        let site = window("Google Chrome", "https://usemurmur.live/", "Hi Priya, Thursday works. I'll send the Q3 deck by Friday.")
        #expect(Consolidator.judge(promises: [deck], seen: [site]) { _ in [] }.isEmpty)
        let article = window("Safari", "https://medium.com/some-post", "Send Priya the Q3 deck, said the manager in our story.")
        #expect(Consolidator.judge(promises: [deck], seen: [article]) { _ in ["Priya Shah"] }.isEmpty)
    }

    @Test func aConversationIs() {
        let slack = window("Slack", nil, "Priya Shah: can you send me the Q3 deck by Friday?\nShubham: Sure, Thursday night.")
        #expect(Consolidator.judge(promises: [deck], seen: [slack]) { _ in [] }.count == 1)
        let gmail = window("Google Chrome", "https://mail.google.com/mail/u/0/#inbox/1", "Priya: please send the Q3 deck")
        #expect(Consolidator.judge(promises: [deck], seen: [gmail]) { _ in [] }.count == 1)
        let dm = window("Google Chrome", "https://www.linkedin.com/messaging/thread/9", "Priya: send the Q3 deck when you can")
        #expect(Consolidator.judge(promises: [deck], seen: [dm]) { _ in [] }.count == 1)
    }

    @Test func itsWordsAndItsPersonHaveToBeThere() {
        let slack = window("Slack", nil, "Arjun: lunch tomorrow?")
        #expect(Consolidator.judge(promises: [deck], seen: [slack]) { _ in [] }.isEmpty)   // never said there
        let stranger = window("Slack", nil, "Someone: can you send the Q3 deck?")
        #expect(Consolidator.judge(promises: [deck], seen: [stranger]) { _ in [] }.isEmpty)   // Priya isn't in it, nor known
        #expect(Consolidator.judge(promises: [deck], seen: [stranger]) { _ in ["Priya Shah"] }.count == 1)   // known
    }
}
