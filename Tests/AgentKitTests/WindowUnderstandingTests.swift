import Foundation
import Testing
@testable import AgentKit

/// Understanding a window before remembering anything from it: what kind of screen it is, what's content, what the
/// user sent, what a picture of it shows, and what can become an obligation.
struct WindowUnderstandingTests {
    let now = Date()
    func shot(_ app: String, _ url: String?, _ text: String, kind: String = "", authored: String = "", seenAs: String = "")
        -> Journal.Snapshot {
        Journal.Snapshot(id: 1, app: app, title: "t", url: url, domain: url.flatMap { URL(string: $0)?.host }?
            .replacingOccurrences(of: "www.", with: "") ?? "", text: text, first: now, last: now, seconds: 60, sightings: 1,
                         kind: kind, authored: authored, seenAs: seenAs)
    }

    @Test func windowsAreKnownByAppAddressAndContent() {
        func kind(_ app: String, _ url: String? = nil, _ text: String = "") -> WindowKind {
            let domain = url.flatMap { URL(string: $0)?.host }?.replacingOccurrences(of: "www.", with: "") ?? ""
            return WindowKind.of(app: app, domain: domain, url: url, title: "", text: text)
        }
        #expect(kind("Slack") == .conversation)
        #expect(kind("Claude") == .assistant)
        #expect(kind("Xcode") == .work)
        #expect(kind("Google Chrome", "https://mail.google.com/mail/u/0/") == .conversation)
        #expect(kind("Google Chrome", "https://www.linkedin.com/feed/") == .feed)
        #expect(kind("Google Chrome", "https://www.linkedin.com/messaging/thread/2") == .conversation)
        #expect(kind("Google Chrome", "https://linear.app/acme/issue/ENG-1") == .work)
        #expect(kind("Google Chrome", "https://claude.ai/chat/1") == .assistant)
        #expect(kind("Safari", "https://www.google.com/search?q=murmur") == .search)
        #expect(kind("Safari", "https://medium.com/x") == .article)
        #expect(kind("Safari", "https://developer.apple.com/documentation/vision") == .docs)
        // A product's own site, known by what it says: the case that made a demo chat into a promise.
        #expect(kind("Google Chrome", "https://usemurmur.live/", "Murmur. Download for Mac. Features. Free trial. Hi Priya, Thursday works.")
            == .product)
        #expect(kind("Google Chrome", "https://some-blog.dev/post", "A post about Swift") == .page)
        #expect(WindowKind.conversation.canOblige && WindowKind.work.canOblige && !WindowKind.product.canOblige
                && !WindowKind.assistant.canOblige)
    }

    @Test func advertsAreNotContent() {
        let lines: [(text: String, control: Bool)] = [("Priya Shah: the deck looks good", false), ("Promoted", false)]
            + (1...12).map { ("Buy our CRM today \($0)", false) } + [("Arjun: lunch at 1?", false)]
        #expect(ScreenText.content(lines) == ["Priya Shah: the deck looks good", "Arjun: lunch at 1?"])
    }

    @Test func aMessageTheUserSentIsKeptAsTheirs() {
        let chat = "Priya Shah: can you send me the Q3 deck by Friday?\nSure, I'll send it Thursday night."
        #expect(ScreenText.sent(before: "Sure, I'll send it Thurs", now: "", in: chat) == "Sure, I'll send it Thursday night.")
        #expect(ScreenText.sent(before: "Sure, I'll send it Thursday night.", now: "", in: "Priya Shah: thanks") == nil)   // not sent
        #expect(ScreenText.sent(before: "Sure, I'll", now: "Sure, I'll send", in: chat) == nil)   // still writing
        #expect(ScreenText.sent(before: "ok", now: "", in: "ok") == nil)   // one word: not worth it
    }

    @Test func obligationsHaveThreeKindsFromTheRightPlaces() {
        let me = ["Shubham Agrawal", "Shubham"]
        let slack = shot("Slack", nil, "Priya Shah: can you review the pricing doc by Monday?\nArjun: I'll fix the login bug tomorrow",
                         authored: "Sure, I'll send the Q3 deck Thursday night")
        let answer = """
            {"memories": [], "promises": [
              {"summary": "Send Priya the Q3 deck", "person": "Priya Shah", "kind": "promised", "status": "open"},
              {"summary": "Review the pricing doc", "person": "Priya Shah", "kind": "asked", "due": "2999-01-01", "status": "open"},
              {"summary": "Arjun fixes the login bug", "person": "Arjun", "kind": "owed", "status": "open"},
              {"summary": "Book the Goa offsite", "person": "", "kind": "promised", "status": "open"}
            ]}
            """
        let offered = Consolidator.parse(answer).promises
        #expect(offered.map(\.kind) == ["promised", "asked", "owed", "promised"])
        #expect(offered.map(\.mine) == [true, true, false, true])
        let kept = Consolidator.judge(promises: offered, seen: [slack], me: me) { _ in [] }
        // The deck: in what the user sent. The review: asked of them. Arjun's fix: owed to them. The offsite: never said.
        #expect(kept.map(\.summary) == ["Send Priya the Q3 deck", "Review the pricing doc", "Arjun fixes the login bug"])
        // A promise "the user made" that only someone else's line says isn't the user's.
        let noOwnWords = shot("Slack", nil, "Priya Shah: I'll send the Q3 deck myself")
        #expect(Consolidator.judge(promises: [offered[0]], seen: [noOwnWords], me: me) { _ in [] }.isEmpty)
        // Lines starting with the user's name count as theirs too (apps that show names).
        let named = shot("Slack", nil, "Priya Shah: deck?\nShubham Agrawal: I'll send the Q3 deck Thursday")
        #expect(Consolidator.judge(promises: [offered[0]], seen: [named], me: me) { _ in [] }.count == 1)
        // Labels say the three kinds.
        var loop = Journal.Loop(id: 1, summary: "x", person: "", project: "", mine: true, due: nil, status: "open", first: now, last: now)
        loop.kind = "asked"
        #expect(loop.label == "Asked of you")
    }

    @Test func whatTheModelReadsSaysKindSentAndSeen() {
        let snapshot = shot("Google Chrome", "https://usemurmur.live/", "Hi Priya, Thursday works.", kind: "product",
                            authored: "", seenAs: "A product's landing page showing a demo chat (not the user's own content)")
        let text = Consolidator.batches([snapshot]) { Engagement.tags($0, me: []) { _ in [] } }[0].text
        #expect(text.contains("a product's or company's website"))
        #expect(text.contains("Seen as: A product's landing page showing a demo chat"))
        let sent = Consolidator.batches([shot("Slack", nil, "Priya: deck?", authored: "Sure, Thursday")]) { _ in [] }[0].text
        #expect(sent.contains("The user wrote and sent here: Sure, Thursday"))
    }

    @Test func theVisionModelsAnswerIsRead() {
        let seen = WindowVision.parse("""
            {"kind": "product", "seen_as": "A landing page for Murmur showing a sample chat with Priya",
             "user_content": false, "ignore": "the sample chat"}
            """)
        #expect(seen?.kind == .product && seen?.userContent == false)
        #expect(seen?.seenAs == "A landing page for Murmur showing a sample chat with Priya (not the user's own content) Not real content: the sample chat.")
        #expect(WindowVision.parse("{}") == nil)
        #expect(WindowVision.parse("{\"kind\": \"nonsense\", \"seen_as\": \"x\", \"user_content\": true}")?.kind == nil)
    }

    @Test func onlyStrongMacsSee() {
        #expect(WindowVision.capable(memory: 16 << 30, appleSilicon: true))
        #expect(!WindowVision.capable(memory: 8 << 30, appleSilicon: true))
        #expect(!WindowVision.capable(memory: 32 << 30, appleSilicon: false))
        #expect(WindowVision.worthLooking(.product, app: "Google Chrome") && !WindowVision.worthLooking(.assistant, app: "Claude")
                && !WindowVision.worthLooking(.app, app: "Terminal"))
    }

    @Test func aWindowWaitsForTheVisionModelButNotForever() throws {
        let journal = Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("vision-\(UUID().uuidString).sqlite"))
        let kept = journal.record(Journal.Capture(app: "Google Chrome", bundle: "", title: "Murmur", url: "https://usemurmur.live/",
                                                  text: "Hi Priya, Thursday works", kind: "product"), now: now.addingTimeInterval(-600))
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8]).write(to: picture)
        journal.setPicture(kept.id, path: picture.path)
        #expect(journal.pending(now: now).isEmpty)   // waits to be seen
        #expect(journal.waitingPictures().map(\.snapshot.id) == [kept.id])
        journal.understood(kept.id, seenAs: "A product's landing page with a demo chat", kind: .product)
        #expect(!FileManager.default.fileExists(atPath: picture.path))   // seen: the picture is gone
        #expect(journal.pending(now: now).first?.seenAs == "A product's landing page with a demo chat")
        // One the vision model never got to is read anyway after six hours.
        let late = journal.record(Journal.Capture(app: "Preview", bundle: "", title: "Scan", text: "A scanned page of text"),
                                  now: now.addingTimeInterval(-7 * 3600))
        journal.setPicture(late.id, path: picture.path)
        #expect(journal.pending(now: now).contains { $0.id == late.id })
    }

    @Test func oldSettingsStillLoad() throws {
        let old = #"{"to":19,"from":9,"rules":{"pictures":true,"excluded":[]},"weekends":true,"always":true,"enabled":true,"wrap":"18:30","brief":"09:00"}"#
        let settings = try JSONDecoder().decode(ScreenMemorySettings.self, from: Data(old.utf8))
        #expect(settings.enabled && settings.rules.authored && settings.rules.pictures)
    }
}

/// Qwen3 4B's real memory from the user's Mac (2026-11-06): reading mem0.ai's website became "associated with" it.
struct AboutTheUserTests {
    let now = Date()

    @Test func readingAboutSomethingIsNotBeingPartOfIt() {
        let site = Journal.Snapshot(id: 1, app: "Google Chrome", title: "Mem0 - The Memory Layer for AI Agents",
                                    url: "https://mem0.ai/", domain: "mem0.ai",
                                    text: "Mem0 is the memory layer for AI agents that remember users. Get started free. Pricing.",
                                    first: now, last: now, seconds: 120, sightings: 2)
        let profile = Journal.Snapshot(id: 2, app: "Google Chrome", title: "Shubham Agrawal | LinkedIn",
                                       url: "https://www.linkedin.com/in/shubham-agrawal/", domain: "linkedin.com",
                                       text: "Shubham Agrawal. Software engineer at Ford. Building AI agents with memory.",
                                       first: now, last: now, seconds: 60, sightings: 1)
        let memories = Consolidator.parse("""
            {"memories": [
              {"about": "Shubham Agrawal", "about_kind": "me", "text": "Shubham Agrawal is associated with the Mem0 AI project, which builds AI agents that remember users", "kind": "fact", "importance": 9},
              {"about": "Shubham Agrawal", "about_kind": "me", "text": "Shubham Agrawal is a software engineer at Ford building AI agents with memory", "kind": "fact", "importance": 9}
            ], "promises": []}
            """).memories
        let kept = Consolidator.judge(memories, seen: [site, profile], browsing: [1, 2], me: ["Shubham Agrawal", "Shubham"]) { _ in [] }
        #expect(kept.map(\.text) == ["Shubham Agrawal is a software engineer at Ford building AI agents with memory"])
    }
}
