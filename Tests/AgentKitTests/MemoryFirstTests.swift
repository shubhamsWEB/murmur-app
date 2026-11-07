import Foundation
import Testing
@testable import AgentKit

/// On 2026-11-07, after releasing Murmur 1.7, the user asked "what all release we did and have we notified on the
/// LinkedIn and WhatsApp?" and Murmur opened LinkedIn in Chrome instead of answering from memory. Each link of that
/// chain, as a test.
struct MemoryFirstTests {
    static let asked = "What all release we did and have we notified on the LinkedIn and WhatsApp?"

    // MARK: Routing

    @Test func theQuestionGoesToMemoryHoweverItStarts() {
        for said in [Self.asked,
                     "So what all release we did and have we notified on the LinkedIn and WhatsApp?",
                     "Okay Murmur, have we posted about the release on LinkedIn?",
                     "Hey, quick question, did we tell the AI builders group on WhatsApp?",
                     "Can you tell me what we released this week?",
                     "Could you check whether we announced 1.7 on LinkedIn?",
                     "Murmur, what did we ship yesterday?",
                     "Um, did Tanay reply?"] {
            #expect(MemoryRoute.classify(said, hour: 18) == .question, "\(said)")
        }
    }

    @Test func leadInsDontTurnActionsIntoQuestions() {
        for said in ["So open LinkedIn", "Okay, post this on LinkedIn", "Hey Murmur send Roma good morning on WhatsApp",
                     "Can you check the weather tomorrow?"] {
            #expect(MemoryRoute.classify(said, hour: 18) == nil, "\(said)")
        }
    }

    @Test func twoQuestionsInOneAreSeenAsTwo() {
        #expect(MemoryRoute.isCompound(Self.asked))
        #expect(MemoryRoute.isCompound("When is my flight and did I check in?"))
        #expect(!MemoryRoute.isCompound("What did we release in Murmur?"))
        #expect(!MemoryRoute.isCompound("Photos of mom and dad from Goa"))
    }

    @Test func aPartialAnswerIsKept() {
        let partial = "You released Murmur 1.7.0 on Friday. I haven't seen a LinkedIn or WhatsApp post about it. NOT_IN_MEMORY"
        #expect(MemoryRoute.answer(from: partial)?.hasPrefix("You released Murmur 1.7.0") == true)
        #expect(MemoryRoute.answer(from: partial)?.contains("NOT_IN_MEMORY") == false)
        #expect(MemoryRoute.answer(from: "NOT_IN_MEMORY.") == nil)
    }

    @Test func theAgentGetsItsMemoryToolsForWeQuestions() {
        let groups = ToolGroup.select(QuickCommands.clean(Self.asked), frontIsBrowser: false, hasSelection: false,
                                      codingSession: false, skillsListed: false, mentionsMemory: false)
        #expect(groups.contains(.memory))
    }

    // MARK: Capture

    @Test func aLinkedInPostIsKeptAsAPost() {
        let now = Date()
        let post = "Murmur 1.7 is out: memory that keeps the details, and dictation that works everywhere."
        let feed = Journal.Snapshot(id: 1, app: "Google Chrome", title: "Feed | LinkedIn", url: "https://www.linkedin.com/feed/",
                                    domain: "linkedin.com", text: "Shubham Agrawal\nnow\n\(post)\nLike Comment Repost",
                                    first: now, last: now, seconds: 60, sightings: 1, kind: "feed", authored: post, seenAs: "")
        let items = ItemReader.read(feed, me: ["Shubham Agrawal"])
        #expect(items.contains { $0.kind == .post && $0.fields["platform"] == "LinkedIn" && $0.mine })
        #expect(!items.contains { $0.kind == .message })
    }

    @Test func aPostIsNoticedLeavingItsBox() {
        let draft = "Murmur 1.7 is out today with memory that keeps the details"
        // On the page now.
        #expect(ScreenText.posted(before: draft, now: "", in: "Shubham Agrawal\n\(draft)\nLike") == draft)
        // The site said so.
        #expect(ScreenText.posted(before: draft, now: "", in: "Post successful. View post") == draft)
        // A search isn't a post; still in the box isn't posted.
        #expect(ScreenText.posted(before: "murmur ai", now: "", in: "murmur ai results") == nil)
        #expect(ScreenText.posted(before: draft, now: draft + " and more", in: "") == nil)
    }

    @Test func aReleaseTaggedInTheTerminalIsARelease() {
        let now = Date()
        let terminal = Journal.Snapshot(id: 2, app: "Terminal", title: "~/IdeaProjects/murmur — -zsh", url: nil, domain: "",
                                        text: "shubham@mac murmur % git tag v1.7.0\nshubham@mac murmur % git push origin v1.7.0\n"
                                            + "To github.com:shubhamsWEB/murmur-app.git\n * [new tag]         v1.7.0 -> v1.7.0\n"
                                            + "shubham@mac murmur % git tag -l\nv1.6.0\nv1.7.0",
                                        first: now, last: now, seconds: 30, sightings: 1)
        let releases = ItemReader.read(terminal, me: []).filter { $0.kind == .release }
        #expect(releases.count == 1)
        #expect(releases.first?.fields["version"] == "1.7.0")
        #expect(releases.first?.project == "murmur")
        // Not a release: a push that was rejected, an assistant suggesting the command, the command in a document.
        func released(_ app: String, _ text: String) -> Bool {
            ItemReader.read(Journal.Snapshot(id: 3, app: app, title: "murmur", url: nil, domain: "", text: text, first: now, last: now,
                                             seconds: 30, sightings: 1), me: []).contains { $0.kind == .release }
        }
        #expect(!released("Terminal", "% git push origin v2.0.0\nTo github.com:me/app.git\n ! [rejected]        v2.0.0 -> v2.0.0 (already exists)"))
        #expect(!released("Terminal", "⏺ When you're ready, you can run gh release create v2.1.0 --notes-file notes.md"))
        #expect(!released("Cursor", "To release:\n git tag v18.3.1\n * [new tag]         v18.3.1 -> v18.3.1"))
        // gh's release address is proof too.
        #expect(released("Terminal", "% gh release create v1.7.1\nhttps://github.com/shubhamsWEB/murmur-app/releases/tag/v1.7.1"))
    }

    // MARK: What was actually on screen on 7 Nov

    @Test func whatsAppIsAChatAppEvenWithItsInvisibleMark() {
        // macOS calls the app "\u{200E}WhatsApp": the mark made it "an app", so nothing sent in it was kept.
        #expect(WindowKind.of(app: "\u{200E}WhatsApp", domain: "", url: nil, title: "\u{200E}WhatsApp", text: "") == .conversation)
        #expect(ScreenText.appName("\u{200E}WhatsApp") == "WhatsApp")
    }

    @Test func aWhatsAppMessageIsFoundAsItReads() {
        let typed = "Hey folks 👋 Excited to share *Murmur 1.7* 🚀 Murmur is a free voice assistant for Mac and Windows."
        let chat = "AI Builders x Blr\nHey folks 👋 Excited to share Murmur 1.7 🚀 Murmur is a free voice assistant for Mac and Windows.\n5:35 PM"
        #expect(ScreenText.sent(before: typed, now: "", in: chat) != nil)
        // Sent as a video's caption: only its end shows, wrapped.
        let caption = "Murmur is a free voice assistant for Mac and Windows. Free and open source. Try it at https://usemurmur.live/"
        #expect(ScreenText.sent(before: caption, now: "", in: "1:00 - 9.6 MB\nFree and open source. Try it at https://\nusemurmur.live/") == caption)
        // Cleared, not sent.
        #expect(ScreenText.sent(before: caption, now: "", in: "Chats\nRoma\nVideo call") == nil)
    }

    @Test func theChatIsNamedByWhatsAppsOwnControls() {
        let now = Date()
        let window = Journal.Snapshot(id: 3, app: "WhatsApp", title: "\u{200E}WhatsApp", url: nil, domain: "",
                                      text: "\u{200E}Chats, 335\n\u{200E}Open call dropdown menu with AI Builders x Blr\n\u{200E}Compose message",
                                      first: now, last: now, seconds: 60, sightings: 1, kind: "conversation",
                                      authored: "Hey folks, Murmur 1.7 is out today", seenAs: "")
        let sent = ItemReader.read(window, me: []).filter { $0.kind == .message }
        #expect(sent.first?.people == ["AI Builders x Blr"])
        #expect(sent.first?.fields["app"] == "WhatsApp")
    }

    @Test func yourOwnLinkedInPostIsKnownFromItsPage() {
        let seen = Date()
        let text = """
            Akshat Dubey reacted with Celebrate Roma Patel reacted with Insightful
            Boost
            Open control menu for post by Shubham Agrawal
            Feed post
            Promote this post to reach people who matter to you.
            Shubham Agrawal Verified Profile You
            A month ago, Murmur could only type what I said.
            Today it remembers what I'm working on.
            Murmur 1.7 is out, for Mac and Windows. Free, open source, and it runs on your own computer.
            I'd love feedback. 🐦
            10m
            This looks awesome!✨
            AI Explorer
            42m •
            Add a comment...
            44 impressions
            """
        let page = Journal.Snapshot(id: 4, app: "Google Chrome", title: "Post | LinkedIn",
                                    url: "https://www.linkedin.com/posts/shubham-agrawal-950078170_opensource-ai-productivity-ugcPost-7524800656445227008-cuMP/",
                                    domain: "linkedin.com", text: text, first: seen, last: seen, seconds: 10, sightings: 1, kind: "feed")
        let post = ItemReader.ownPost(in: page, me: ["Shubham Agrawal", "Shubham"])
        #expect(post?.key == "post|linkedin|7524800656445227008")
        #expect(post?.body.contains("Murmur 1.7 is out") == true)
        #expect(post?.body.contains("This looks awesome") == false)
        #expect(post.flatMap { $0.when }.map { abs(seen.timeIntervalSince($0) - 42 * 60) < 1 } == true)
        // Someone else's post isn't yours.
        let theirs = Journal.Snapshot(id: 5, app: "Google Chrome", title: "Post | LinkedIn", url: "https://www.linkedin.com/feed/",
                                      domain: "linkedin.com", text: text.replacingOccurrences(of: "Shubham Agrawal", with: "Satya Nadella"),
                                      first: seen, last: seen, seconds: 10, sightings: 1, kind: "feed")
        #expect(ItemReader.ownPost(in: theirs, me: ["Shubham Agrawal"]) == nil)
    }

    @Test func aTagWhoseBuildIsStillRunningIsKeptAsTagged() {
        let now = Date()
        let page = Journal.Snapshot(id: 6, app: "Google Chrome", title: "Release v1.7.0 · shubhamsWEB/murmur-app",
                                    url: "https://github.com/shubhamsWEB/murmur-app/releases/tag/v1.7.0", domain: "github.com",
                                    text: "v1.7.0\nCreate release from tag\n@shubhamsWEB\nshubhamsWEB\ntagged this\nMurmur 1.7.0\nAssets 2\nCreate release\nfrom tag\n7af415d\nnow\nSource code (zip)",
                                    first: now, last: now, seconds: 7, sightings: 1, kind: "work")
        let releases = ItemReader.read(page, me: ["Shubham Agrawal"]).filter { $0.kind == .release }
        #expect(releases.count == 1)
        #expect(releases.first?.fields["status"] == "tagged")
        #expect(releases.first?.title == "Murmur 1.7.0")
        #expect(releases.first?.mine == true)
        // The terminal that ran the push, by what git said back (its newest lines are kept), not by its title: a title
        // names the command while it runs, whether or not it worked.
        let terminal = Journal.Snapshot(id: 7, app: "Terminal",
                                        title: "murmur — git tag -a v1.7.0 -m \"Murmur 1.7.0\" && git push origin v1.7.0 — ssh ◂ git push origin v1.7.0 — 213×59",
                                        url: nil, domain: "",
                                        text: "Last login: Thu Nov  5 18:28:57 on ttys008\nTo https://github.com/shubhamsWEB/murmur-app.git\n"
                                            + " * [new tag]         v1.7.0 -> v1.7.0",
                                        first: now, last: now, seconds: 4, sightings: 1)
        #expect(ItemReader.read(terminal, me: []).contains { $0.kind == .release && $0.fields["version"] == "1.7.0" })
        let running = Journal.Snapshot(id: 8, app: "Terminal", title: terminal.title, url: nil, domain: "",
                                       text: "Last login: Thu Nov  5 18:28:57 on ttys008", first: now, last: now, seconds: 4, sightings: 1)
        #expect(!ItemReader.read(running, me: []).contains { $0.kind == .release })
    }

    // MARK: Answering

    @Test func memoryAnswersBothPartsWithWhatItHas() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("first-\(UUID().uuidString).sqlite")
        let graph = MemoryGraph(url: url)
        let released = Date().addingTimeInterval(-3 * 3600)
        graph.store(MemoryItem(kind: .release, key: "release|murmur-app|1.7.0", title: "Murmur 1.7.0",
                               body: "Release: Murmur 1.7.0", project: "Murmur", when: released,
                               fields: ["version": "1.7.0", "name": "Murmur"], mine: true), snapshot: 1, seen: released)
        let posted = Date().addingTimeInterval(-3600)
        graph.store(MemoryItem(kind: .post, key: "post|linkedin|1", title: "Murmur 1.7 is out",
                               body: "You posted on LinkedIn: Murmur 1.7 is out", when: posted,
                               fields: ["platform": "LinkedIn", "app": "LinkedIn"], mine: true), snapshot: 2, seen: posted)
        let brain = BrainStore(url: url)
        // A compound question isn't answered by the release alone.
        #expect(MemoryRecall.directAnswer(Self.asked, graph: graph) == nil)
        // "We" counts as the user for a single question.
        #expect(MemoryRecall.directAnswer("What did we release?", graph: graph)?.hasPrefix("We released Murmur 1.7.0") == true)
        let lines = MemoryRecall.lines(for: Self.asked, graph: graph, brain: brain)
        #expect(lines.contains { $0.contains("Murmur 1.7.0") })
        #expect(lines.contains { $0.contains("You posted on LinkedIn") && $0.contains("you posted") })
    }
}

/// The web stays shut for a question about the user's own past, unless they ask Murmur to go and look.
struct LookingElsewhereTests {
    @Test func pastQuestionsDontGoToTheWeb() {
        for said in ["Did we send an update in LinkedIn regarding the new Murmur launch version?",
                     "Murmur, uh did we share all the details of the new release, one point seven Murmur, to LinkedIn and WhatsApp."] {
            #expect(MemoryRoute.classify(said, hour: 18) == .question, "\(said)")
            #expect(MemoryRoute.aboutThePast(said), "\(said)")
            #expect(!MemoryRoute.asksToLook(said), "\(said)")
        }
        #expect(MemoryRoute.looksElsewhere.contains("web_search") && MemoryRoute.looksElsewhere.contains("open_url"))
    }

    @Test func askingToLookOrHowToStillMayUseTheWeb() {
        #expect(MemoryRoute.asksToLook("Check LinkedIn whether we posted about 1.7"))
        #expect(MemoryRoute.asksToLook("Can you see if Tanay replied in my mail?"))
        #expect(!MemoryRoute.aboutThePast("How do I change my wallpaper?"))
    }
}

/// What was said, read against what memory knows: the 7 Nov transcripts.
struct HearingTests {
    static let names = [Grounding.Name("AI Builders x Blr", what: "you wrote to them on WhatsApp"),
                        Grounding.Name("Tanay Kothari", what: "person"), Grounding.Name("Tanay", what: "person"),
                        Grounding.Name("Murmur", what: "project"), Grounding.Name("Raipur", what: "place")]
    /// A small dictionary, so the test doesn't depend on the Mac's.
    static func isWord(_ word: String) -> Bool {
        ["builder", "book", "draft", "a", "message", "to", "post", "about", "the", "newest", "murmur", "update", "in",
         "whatsapp", "diaper", "flight", "my", "is", "when", "did", "reply", "share", "release", "seven", "point", "one"]
            .contains(word)
    }

    @Test func aMisheardGroupIsReadAsTheOneYouWriteTo() {
        let heard = "Draft a message to post about the newest murmur update in the CI Builder WhatsApp book."
        let result = Grounding.ground(heard, names: Self.names, isWord: Self.isWord)
        #expect(result.fixes.contains { $0.heard == "CI Builder" && $0.meant == "AI Builders x Blr" })
        #expect(result.text.contains("AI Builders x Blr WhatsApp"))
        #expect(result.note?.contains("CI Builder") == true)
    }

    @Test func versionsSaidAloudBecomeNumbers() {
        let result = Grounding.ground("did we share the new release, one point seven Murmur, to LinkedIn", names: Self.names,
                                      isWord: Self.isWord)
        #expect(result.text.contains("1.7 Murmur"))
        #expect(Grounding.versions(in: "version two point one point zero").text == "version 2.1.0")
        #expect(Grounding.versions(in: "one of seven people").text == "one of seven people")
    }

    @Test func realWordsAndRightNamesAreLeftAlone() {
        // "diaper" is a word: it may have been meant, so it's left for the model.
        #expect(Grounding.ground("When is my flight to diaper?", names: Self.names, isWord: Self.isWord).fixes.isEmpty)
        #expect(Grounding.ground("Did Tanay reply?", names: Self.names, isWord: Self.isWord).fixes.isEmpty)
        // A name that isn't a word, close to one memory holds, is corrected.
        let tanai = Grounding.ground("Did Tanai reply?", names: Self.names, isWord: Self.isWord)
        #expect(tanai.text == "Did Tanay reply?")
        // Only the name is misheard, never the small word before it.
        let tana = Grounding.ground("Did we send an email to Tana regarding Marmar?", names: Self.names, isWord: Self.isWord)
        #expect(tana.text == "Did we send an email to Tanay regarding Murmur?")
    }
}

/// Every task starts with what memory knows about it, whichever model plans it.
struct TaskBriefTests {
    @Test func theBriefSaysWhoItNamesAndWhatYouDid() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brief-\(UUID().uuidString).sqlite")
        let graph = MemoryGraph(url: url), brain = BrainStore(url: url)
        let sent = Date().addingTimeInterval(-3600)
        graph.store(MemoryItem(kind: .message, key: "message|whatsapp|1", title: "Hey folks, Murmur 1.7 is out",
                               body: "You sent to AI Builders x Blr in WhatsApp: Hey folks, Murmur 1.7 is out", actor: "me",
                               people: ["AI Builders x Blr"], when: sent, fields: ["app": "WhatsApp", "to": "AI Builders x Blr"],
                               mine: true), snapshot: 1, seen: sent)
        let grounding = Grounding.Result(text: "Send the Murmur video to AI Builders x Blr",
                                         fixes: [Grounding.Fix(heard: "CI Builder", meant: "AI Builders x Blr", why: "you wrote to them on WhatsApp")])
        let brief = TaskBrief.make(grounding, graph: graph, brain: brain, prefs: CommandMemory.Preferences()) ?? ""
        #expect(brief.contains("\"CI Builder\" → \"AI Builders x Blr\""))
        #expect(brief.contains("AI Builders x Blr: you last wrote to them on WhatsApp"))
        #expect(brief.contains("you sent to AI Builders x Blr on WhatsApp: Hey folks, Murmur 1.7 is out"))
    }
}

/// The one way into memory: what it finds for the user's own questions, built from what their memory held on 7 Nov.
struct BrainRecallTests {
    static func index() -> MemoryIndex {
        MemoryIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent("recall-\(UUID().uuidString).sqlite"))
    }
    static let calendar = Calendar(identifier: .gregorian)
    static func at(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }
    static let now = at("2026-11-07 18:30")

    static func memory() -> MemoryIndex {
        let index = index()
        index.put([
            .init(source: "thread:1", kind: .conversation, actor: "me", at: at("2026-11-07 03:00"),
                  title: "Voice Agent Loop for the Mac (Open Source)", text: "You emailed Jason. Status: waiting for their reply.",
                  entities: ["Jason", "Murmur"], prior: 0.9),
            .init(source: "item:73", kind: .did, actor: "me", at: at("2026-11-06 03:46"), title: "Murmur 1.5.1",
                  text: "Release: Murmur 1.5.1 Repository: shubhamsWEB/murmur-app", entities: ["Murmur"], prior: 1.0),
            .init(source: "episode:84", kind: .did, actor: "me", at: at("2026-11-07 17:37"), title: "Releasing Murmur 1.7.0",
                  text: "Shubham worked on the release of Murmur 1.7.0. Outcome: Released. (6 min, in Claude, Terminal)",
                  entities: ["murmur"], prior: 0.85),
            .init(source: "item:310", kind: .did, actor: "me", at: at("2026-11-07 17:22"), title: "You posted on LinkedIn",
                  text: "You posted on LinkedIn: Murmur 1.7 is out, for Mac and Windows.", entities: ["LinkedIn"], prior: 1.0),
            .init(source: "item:259", kind: .did, actor: "me", at: at("2026-11-07 03:58"),
                  title: "Murmur, an open-source voice computer I built", text: "You emailed Tanay: Murmur, an open-source voice computer I built",
                  entities: ["Tanay"], prior: 1.0),
            .init(source: "memory:337", kind: .fact, actor: "me", at: at("2026-11-07 19:06"), title: "About you",
                  text: "To do: Clean up my room (due Sun, 8 Nov)", prior: 0.9),
            .init(source: "snapshot:9", kind: .saw, actor: "other", at: at("2026-11-07 16:00"), title: "Chrome: Feed | LinkedIn",
                  text: "Bain is hiring AI Engineers in India", entities: ["Google Chrome", "linkedin.com"], prior: 0.3),
        ])
        return index
    }

    func found(_ question: String, names: [String] = ["Tanay", "Jason"]) -> [String] {
        BrainRecall(index: Self.memory(), vectors: nil).recall(question, names: names, now: Self.now, calendar: Self.calendar)
            .found.map(\.record.source)
    }

    @Test func releasingIsFoundForReleaseAndTheNewestComesFirst() {
        let sources = found("What did we release on the latest Murmur app?")
        #expect(sources.first == "episode:84")
        #expect(sources.firstIndex(of: "episode:84")! < (sources.firstIndex(of: "item:73") ?? 99))
    }

    @Test func bothPartsOfATwoPartQuestionAreFound() {
        let sources = found("What all release we did and have we notified on LinkedIn and WhatsApp?")
        #expect(sources.prefix(4).contains("episode:84"))
        #expect(sources.prefix(4).contains("item:310"))
        // What was done ranks above what was merely seen on a feed.
        #expect(sources.firstIndex(of: "item:310")! < (sources.firstIndex(of: "snapshot:9") ?? 99))
    }

    @Test func aPersonNamedFindsWhatYouSentThem() {
        #expect(found("Did we send an email to Tanay regarding Murmur?").first == "item:259")
    }

    @Test func whatIsOwedIsFoundWithoutItsWords() {
        #expect(found("What are the things I need to do?").first == "memory:337")
    }

    @Test func nothingRelevantIsNothing() {
        #expect(found("What is the capital of Peru?").isEmpty)
    }

    @Test func versionsMatchWhateverTheirLength() {
        #expect(MemoryIndex.versionKeys("Murmur 1.7.0") == ["v1_7", "v1_7_0"])
        #expect(found("Did we ship 1.7?").contains("episode:84"))
    }

    @Test func aQuestionReadsWithoutHowItWasSaid() {
        let reading = BrainRecall.read("Murmur, uh did we share the latest 1.7 update on LinkedIn?", names: [], now: Self.now)
        #expect(reading.aboutTheUser && reading.latest)
        #expect(!reading.terms.contains("murmur") || reading.terms.contains("share"))
        #expect(BrainRecall.parts("What did we release, and have we posted it on LinkedIn?").count == 2)
        #expect(BrainRecall.parts("Photos of mom and dad").count == 1)
    }

    @Test func herschelIsHeardAsHarshal() {
        let names = [Grounding.Name("Harshal", what: "you wrote to them on email")]
        let result = Grounding.ground("Is there any reply from Herschel", names: names, isWord: { ["herschel", "reply", "there", "from"].contains($0) })
        #expect(result.text == "Is there any reply from Harshal")
    }
}

/// What the 1.7.1 review found, each case as it was found.
struct ReviewFixesTests {
    // MARK: Commands stay commands

    @Test func tellingAndRemindingAreThingsToDo() {
        #expect(MemoryRoute.classify("Tell the team on Slack that we shipped 1.7") == nil)
        #expect(MemoryRoute.classify("Remind me to write the release notes") == nil)
        #expect(MemoryRoute.classify("Remember my flight is on Friday") == nil)
        #expect(MemoryRoute.classify("Tell me what we released yesterday") == .question)
        #expect(MemoryRoute.classify("Remind me when my flight is") == .question)
        // No ready answer for something to do, even with a release in memory.
        let graph = MemoryGraph(url: FileManager.default.temporaryDirectory.appendingPathComponent("tell-\(UUID().uuidString).sqlite"))
        graph.store(MemoryItem(kind: .release, key: "release|murmur|1.7.0", title: "Murmur 1.7.0", body: "Release: Murmur 1.7.0",
                               project: "Murmur", when: Date(), fields: ["version": "1.7.0", "name": "Murmur"], mine: true),
                    snapshot: 1, seen: Date())
        #expect(MemoryRecall.directAnswer("Tell the team on Slack that we shipped 1.7", graph: graph) == nil)
    }

    @Test func onlyQuestionsAboutWhatTheUserDidShutTheWeb() {
        for open in ["Tell me how to change my wallpaper", "How much is a flight to Goa for me next week?",
                     "Did India win the match yesterday? I didn't watch it.", "Has Apple released iOS 19 yet? My phone hasn't updated.",
                     "Do I have any unread messages on LinkedIn?", "Has my Amazon order shipped?",
                     "What did we ship yesterday? Post it on LinkedIn.", "Check LinkedIn whether we posted it"] {
            #expect(!MemoryRoute.shutsOutTheWeb(open), "\(open)")
        }
        for shut in ["What all release we did and have we notified on the LinkedIn and WhatsApp?",
                     "Did we send an update in LinkedIn regarding the new Murmur launch version?",
                     "We what our releases we did and have we notified on LinkedIn and WhatsApp",
                     "Did Tanay reply?", "What did I send to Tanay on email today"] {
            #expect(MemoryRoute.shutsOutTheWeb(shut), "\(shut)")
        }
    }

    @Test func anOfferAloneIsNoAnswerToACommand() {
        #expect(MemoryRoute.answer(from: "NOT_IN_MEMORY. Want me to check LinkedIn?") == nil)
        #expect(MemoryRoute.answer(from: "I haven't seen a LinkedIn post about it. Want me to check?") == nil)
        // To a question about the user's past, "not seen" is the answer.
        #expect(MemoryRoute.answer(from: "I haven't seen a LinkedIn post about it since 5 Nov.", notSeenAnswers: true)
                == "I haven't seen a LinkedIn post about it since 5 Nov.")
        #expect(MemoryRoute.answer(from: "You released Murmur 1.7.0 today. I haven't seen a LinkedIn post about it.")
                == "You released Murmur 1.7.0 today. I haven't seen a LinkedIn post about it.")
    }

    // MARK: Hearing names, not rewriting words

    @Test func addressesCodeAndMessagesKeepTheirWords() {
        let names = HearingTests.names + [Grounding.Name("Harshal", what: "person")]
        let isWord = HearingTests.isWord
        #expect(Grounding.ground("Open github.com/tanai/ledgr", names: names, isWord: isWord).text == "Open github.com/tanai/ledgr")
        // The name to whom is heard right; what's to be said is the user's.
        let told = Grounding.ground("Tell Tanai that the Herschel deal is done", names: names, isWord: isWord)
        #expect(told.text == "Tell Tanay that the Herschel deal is done")
        #expect(Grounding.ground("Is there any reply from Herschel", names: names, isWord: isWord).text == "Is there any reply from Harshal")
    }

    // MARK: Secrets

    @Test func secretsInTerminalsAndRecoveryPhrasesAreHidden() {
        #expect(!BrainModel.redact("export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCY").contains("wJalr"))
        #expect(!BrainModel.redact("GH_TOKEN=ghx_abcdef1234567890 gh release create").contains("abcdef1234"))
        #expect(!BrainModel.redact("token github_pat_11ABCDEFG0123456789_abcdefghij").contains("github_pat_11"))
        #expect(!BrainModel.redact("DATABASE_URL=postgres://admin:hunter22@db.local/app").contains("hunter22"))
        let phrase = "abandon ability able about above absent absorb abstract absurd abuse access accident"
        #expect(!BrainModel.redact("Wallet: \(phrase) and more").contains("absorb"))
        #expect(!BrainModel.redact("card 4111 1111 1111 1111 exp 12/29").contains("4111 1111"))
        #expect(!BrainModel.redact("password: correcthorse").contains("correcthorse"))
        // Ordinary words, and numbers that aren't cards, are left alone.
        for kept in ["We shipped Murmur 1.7 today, and the launch post went out on LinkedIn in the evening.",
                     "The Mac test build passed, so the password-field fix compiles.",
                     "Kimi K2.7 does agentic coding, with a 1M token context window.",
                     "Secret Channel Exposed", "no API key needed",
                     "linkedin.com/feed/update/urn:li:activity:7392481234567890123",
                     String(repeating: "word ", count: 30)] {
            #expect(BrainModel.redact(kept) == kept, "\(kept)")
        }
    }

    // MARK: What was sent and posted

    @Test func aDraftLeftInItsBoxIsNotSent() {
        let draft = "Congratulations on the launch, this is a great milestone for the team"
        // The box still holds it (the user clicked elsewhere): the page's text has it only because the box does.
        #expect(ScreenText.posted(before: draft, now: "", in: "Comments\n\(draft)\nPost", boxes: [draft]) == nil)
        #expect(ScreenText.sent(before: "Sure, I'll send it Thursday night.", now: "", in: "Sure, I'll send it Thursday night.",
                                boxes: ["Sure, I'll send it Thursday night."]) == nil)
        // The box emptied and it's on the page: posted.
        #expect(ScreenText.posted(before: draft, now: "", in: "Shubham Agrawal\n\(draft)\nLike", boxes: [""]) == draft)
    }

    @Test func someoneElsesPostIsNotTheUsers() {
        let draft = "I'm happy to share that I'm starting a new position"
        let theirs = "I'm happy to share that I'm starting a new position as Staff Engineer at Acme Corp!"
        // What's kept is what the user wrote, never the other person's longer line.
        #expect(ScreenText.posted(before: draft, now: "", in: "Priya Shah\n\(theirs)\nLike") != theirs)
        // A "post shared" that was on the page before says nothing about this draft.
        let page = "Post shared\nFeed"
        #expect(ScreenText.posted(before: draft, now: "", in: page, earlier: page) == nil)
    }

    // MARK: The second look

    @Test func theSecondLookStaysFixed() {
        // "that" right after the verb is what's sent.
        #expect(Grounding.ground("Send that to Tanai", names: HearingTests.names, isWord: HearingTests.isWord).text == "Send that to Tanay")
        // Messages and reminders, not questions.
        #expect(MemoryRoute.classify("Tell Priya what we shipped this week") == nil)
        #expect(MemoryRoute.classify("Remind me about the dentist tomorrow at 5") == nil)
        #expect(MemoryRoute.classify("Remind me of the standup at 10") == nil)
        #expect(MemoryRoute.classify("Tell me about Project Phoenix") == .question)
        // Something to do if not: its tools stay open.
        #expect(!MemoryRoute.shutsOutTheWeb("Did we post about 1.7? If not, post it on LinkedIn"))
        #expect(!MemoryRoute.shutsOutTheWeb("Have we told the group? Otherwise send them the link"))
        #expect(MemoryRoute.shutsOutTheWeb("What was I working on yesterday?"))
        // A recap that names what, not when, isn't only the last day.
        #expect(BrainRecall.read("What did we do about the Harshal deal?", names: [], now: BrainRecallTests.now).span == nil)
        // Money isn't a version.
        #expect(BrainRecall.highestVersion(in: "Murmur 1.7.0 released. Price USD 4.99") == "1.7.0")
        #expect(BrainRecall.highestVersion(in: "Total 2499.00") == nil)
        // A post with a mention in it, and a long post shown cut short, still count as posted.
        let congrats = "Congrats Priya Sharma, well deserved on the new role!"
        #expect(ScreenText.posted(before: congrats, now: "", in: "Comments\nCongrats\nPriya Sharma\n, well deserved on the new role!") == congrats)
        let long = String(repeating: "Murmur 1.7 is out for Mac and Windows, free and open source, and it runs on your own computer. ", count: 3)
        #expect(ScreenText.posted(before: long, now: "", in: "Shubham Agrawal\n" + long.prefix(140) + "…more\nLike") == long.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Memory search

    @Test func whatMurmurDidIsEachItsOwn() {
        let index = BrainRecallTests.index()
        index.putMurmur([(BrainRecallTests.now, "sent a message to Roma on WhatsApp", "murmur:1:0"),
                         (BrainRecallTests.now, "sent a message to Tanay on WhatsApp", "murmur:2:0"),
                         (BrainRecallTests.now, "sent a message to Jason on WhatsApp", "murmur:3:0")])
        let found = BrainRecall(index: index, vectors: nil).recall("What messages did Murmur send for me?", names: [], now: BrainRecallTests.now)
        #expect(found.found.filter { $0.record.source.hasPrefix("murmur:") }.count == 3)
        // Forgotten in Murmur's history: gone from the index.
        index.putMurmur([(BrainRecallTests.now, "sent a message to Roma on WhatsApp", "murmur:1:0")])
        #expect(index.id(of: "murmur:2:0") == nil && index.id(of: "murmur:1:0") != nil)
    }

    @Test func aPromiseKeptIsNoLongerOwed() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("owed-\(UUID().uuidString).sqlite")
        let journal = Journal(url: url)
        journal.take([Journal.Promise(summary: "Send Tanay the deck", person: "Tanay")], evidence: [])
        let index = MemoryIndex(url: url)
        index.sync()
        #expect(index.owed().count == 1)
        // Done without anything else about it changing (the same length of status, the same last-seen time).
        if let loop = journal.loops(status: "open", limit: 5).first { journal.set(loop: loop.id, status: "done") }
        index.sync()
        #expect(index.owed().isEmpty)
        #expect(index.count() == 1)   // still remembered
    }

    @Test func aPriceIsNotAVersion() {
        #expect(BrainRecall.highestVersion(in: "Release plan: budget ₹2,499.00") == nil)
        #expect(BrainRecall.highestVersion(in: "Meet at 10.30 tomorrow") == nil)
        #expect(BrainRecall.highestVersion(in: "Releasing Murmur 1.7.0") == "1.7.0")
        #expect(BrainRecall.highestVersion(in: "tagged v1.6.2 and v1.7.1") == "1.7.1")
    }

    @Test func whatDidIDoMeansTheLastDay() {
        let reading = BrainRecall.read("What did I do?", names: [], now: BrainRecallTests.now)
        #expect(reading.recap && reading.span != nil)
        #expect(!BrainRecall(index: BrainRecallTests.memory(), vectors: nil).recall("What did I do?", names: [], now: BrainRecallTests.now).isEmpty)
        // "What's new?" asks; it isn't a word to search for.
        #expect(BrainRecall.read("What's new?", names: [], now: BrainRecallTests.now).terms.isEmpty)
    }
}
