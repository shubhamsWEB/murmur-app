import Foundation
import Testing
@testable import AgentKit

/// The local model's tool sets: the right ones for what was said, and nothing lost.
struct ToolGroupsTests {
    func pick(_ said: String, browser: Bool = false, selection: Bool = false) -> Set<ToolGroup> {
        ToolGroup.select(QuickCommands.clean(said), frontIsBrowser: browser, hasSelection: selection,
                         codingSession: false, skillsListed: false, mentionsMemory: false)
    }

    @Test func coreIsAlwaysOffered() {
        #expect(ToolGroup.offers("open_app", in: []))
        #expect(ToolGroup.offers("read_screen", in: []))
        #expect(!ToolGroup.offers("browser_click", in: []))
        #expect(ToolGroup.offers("browser_click", in: [.browser]))
        #expect(ToolGroup.offers("some_new_tool", in: []))   // unknown: never hidden
    }
    @Test func noToolInTwoSets() {
        var seen: [String: ToolGroup] = [:]
        for group in ToolGroup.allCases {
            for tool in group.tools {
                #expect(seen[tool] == nil, "\(tool) is in \(seen[tool]?.rawValue ?? "") and \(group.rawValue)")
                #expect(!ToolGroup.core.contains(tool), "\(tool) is core and in \(group.rawValue)")
                seen[tool] = group
            }
        }
    }
    @Test func requests() {
        #expect(pick("open youtube and play lofi").isSuperset(of: [.browser, .system]))
        #expect(pick("what's on my calendar tomorrow").contains(.appData))
        #expect(pick("send a message to Roma on WhatsApp saying I'm late").contains(.messages))
        #expect(pick("turn the volume down") == [.system])
        #expect(pick("remember that Mom is Roma").contains(.memory))
        #expect(pick("create a react app with a login page").contains(.coding))
        #expect(pick("summarise this", selection: true).contains(.text))
        #expect(pick("awaaz kam karo") == [.system])
        #expect(pick("saleshq.ai kholo").contains(.browser))
        #expect(pick("what does this page say", browser: true).contains(.browser))
        #expect(pick("mujhe PDF kholkar do").isEmpty)
        #expect(pick("open my resume").isEmpty)
        #expect(pick("go through my unread emails and tell me what's important").isSuperset(of: [.appData, .messages]))
    }
    @Test func parseNames() {
        #expect(ToolGroup.parse("browser, system") == [.browser, .system])
        #expect(ToolGroup.parse("app_data") == [.appData])
        #expect(ToolGroup.parse("the calendar tools") == [.appData])
        #expect(ToolGroup.parse("web") == [.browser])
        #expect(ToolGroup.parse("nonsense").isEmpty)
    }
    @Test func hintListsOnlyMissing() {
        let hint = ToolGroup.moreToolsHint(loaded: [.browser, .system])
        #expect(!hint.contains("browser ("))
        #expect(hint.contains("messages ("))
        #expect(ToolGroup.moreToolsHint(loaded: Set(ToolGroup.allCases)).isEmpty)
    }
}

struct ConversationMemoryScopeTests {
    @Test func historyIsOnlyUsedForAnExplicitFollowUp() {
        let justNow = Date()
        #expect(!CommandMemory.shouldIncludeConversationContext("Send Neha a WhatsApp message saying hi", lastAt: justNow))
        #expect(!CommandMemory.shouldIncludeConversationContext("Message Rahul on WhatsApp that I am late", lastAt: justNow))
        #expect(CommandMemory.shouldIncludeConversationContext("And also ask her when she is free", lastAt: justNow))
        #expect(CommandMemory.shouldIncludeConversationContext("Send it again", lastAt: justNow))
    }

    @Test func staleCommandsCannotSupplyConversationContext() {
        #expect(!CommandMemory.shouldIncludeConversationContext("Tell him I will call later",
                                                                 lastAt: Date().addingTimeInterval(-301)))
    }
}

struct MessageIntentTests {
    @Test func explicitRecipientWinsForCommonMessagePhrasings() {
        #expect(MessageIntent.explicitTarget(in: "Send a message to Neha on WhatsApp saying hello")
            == .init(recipient: "neha", app: "WhatsApp"))
        #expect(MessageIntent.explicitTarget(in: "Text Rahul that I will be late")
            == .init(recipient: "rahul", app: nil))
        #expect(MessageIntent.explicitTarget(in: "Send Neha a WhatsApp message saying hello")
            == .init(recipient: "neha", app: "WhatsApp"))
        #expect(MessageIntent.explicitTarget(in: "WhatsApp pe Priya ko bolo main aa raha hoon")
            == .init(recipient: "priya", app: "WhatsApp"))
        #expect(MessageIntent.explicitTarget(in: "Priya ko WhatsApp pe hi bolo")
            == .init(recipient: "priya", app: "WhatsApp"))
    }

    @Test func theMessageItselfIsNeverTheRecipient() {
        #expect(MessageIntent.explicitTarget(in: "Message Rahul that I sent the file to Priya on WhatsApp")
            == .init(recipient: "rahul", app: nil))
        #expect(MessageIntent.explicitTarget(in: "Tell Neha that I am going to Mumbai saying bye")?.recipient == "neha")
        #expect(MessageIntent.explicitTarget(in: "Abhi Priya ko WhatsApp pe bolo") == nil)
    }

    @Test func pronounFollowUpDoesNotInventANewRecipient() {
        #expect(MessageIntent.explicitTarget(in: "And also ask her when she is free") == nil)
        #expect(MessageIntent.explicitTarget(in: "Send it again") == nil)
    }

    @Test func spokenRecipientAndAppOverrideModelArguments() {
        #expect(MessageIntent.authoritativeTarget(in: "Send Neha a WhatsApp message saying hello",
                                                   modelRecipient: "Roma", modelApp: "Slack")
            == .init(recipient: "Neha", app: "WhatsApp"))
        #expect(MessageIntent.authoritativeTarget(in: "Text Neha that I am late",
                                                   modelRecipient: "Roma", modelApp: "WhatsApp")
            == .init(recipient: "Neha", app: "WhatsApp"))
        // The same person: written as the model wrote it.
        #expect(MessageIntent.authoritativeTarget(in: "Text neha sharma that I am late",
                                                   modelRecipient: "Neha Sharma", modelApp: "")
            == .init(recipient: "Neha Sharma", app: nil))
    }
}

/// Fitting the conversation into the local model's context.
struct ContextBudgetTests {
    func call(_ name: String) -> RouterCall { RouterCall(id: name, name: name, arguments: ["q": .string("x")]) }
    func step(_ n: Int, page: Int) -> [RouterTurn] {
        [.assistant(text: "", calls: [call("browser_read")]),
         .toolResult(callID: "browser_read", name: "browser_read", content: "page \(n) " + String(repeating: "w", count: page))]
    }

    @Test func fittingIsUnchanged() {
        let turns: [RouterTurn] = [.user("open slack")] + step(1, page: 100)
        #expect(ContextBudget.fit(turns, fixed: 1000, window: 8000).count == turns.count)
    }
    @Test func oldPagesShrinkFirst() {
        let turns: [RouterTurn] = [.user("go through my mail")] + step(1, page: 9000) + step(2, page: 9000)
        let out = ContextBudget.fit(turns, fixed: 1000, window: 6500)
        #expect(out.count == turns.count)
        guard case .toolResult(_, _, let old) = out[2], case .toolResult(_, _, let latest) = out[4] else {
            Issue.record("shape"); return
        }
        #expect(old.count < 500)
        #expect(latest.count > 8000)
    }
    @Test func oldestStepsGoWhole() {
        var turns: [RouterTurn] = [.user("go through my mail")]
        for n in 1...30 { turns += step(n, page: 350) }
        let out = ContextBudget.fit(turns, fixed: 2000, window: 6000)
        #expect(ContextBudget.tokens(out) <= 6000 - 2000 - 1500)
        guard case .user(let first) = out[0] else { Issue.record("request lost"); return }
        #expect(first.hasPrefix("go through my mail"))
        #expect(first.contains("left out"))
        if case .assistant = out[1] {} else { Issue.record("a result right after the request") }
        guard case .toolResult(_, _, let last) = out[out.count - 1] else { Issue.record("latest lost"); return }
        #expect(last.hasPrefix("page 30"))
    }
    @Test func hugeLatestPageIsCut() {
        let turns: [RouterTurn] = [.user("summarise this page")] + step(1, page: 60_000)
        let out = ContextBudget.fit(turns, fixed: 3000, window: 8192)
        #expect(ContextBudget.tokens(out) <= 8192 - 3000 - 1500 + 200)
        guard case .toolResult(_, _, let page) = out[2] else { Issue.record("shape"); return }
        #expect(page.hasPrefix("page 1"))
    }
    @Test func stateGoesLast() {
        let withResult = ContextBudget.appendingState("[ ] step", to: [.user("hi")] + step(1, page: 10))
        guard case .toolResult(_, _, let content) = withResult.last else { Issue.record("shape"); return }
        #expect(content.hasSuffix("[ ] step"))
        let afterUser = ContextBudget.appendingState("[ ] step", to: [.user("hi")])
        guard case .user(let text) = afterUser.last else { Issue.record("shape"); return }
        #expect(text.hasPrefix("hi") && text.hasSuffix("[ ] step"))
        #expect(ContextBudget.appendingState("", to: [.user("hi")]).count == 1)
    }
}

/// Noticing a task going nowhere.
struct TaskHealthTests {
    @Test func failures() {
        #expect(TaskHealth.isFailure("Couldn't click “Send”."))
        #expect(TaskHealth.isFailure("No tab matches \"inbox\"."))
        #expect(TaskHealth.isFailure("Nothing on the page says “Compose”."))
        #expect(TaskHealth.isFailure("Script error: Mail got an error"))
        #expect(TaskHealth.isFailure("Exit status 1.\nOutput:\nls: x: No such file"))
        #expect(!TaskHealth.isFailure("Exit status 0. No output."))
        #expect(!TaskHealth.isFailure("Noted (3 notes)."))
        #expect(!TaskHealth.isFailure("Clicked “Inbox”."))
        #expect(!TaskHealth.isFailure("Opened github.com"))
    }
    @Test func twoFailuresNudgeOnce() {
        var health = TaskHealth()
        #expect(health.record([("browser_click", "Couldn't click “Send”.")], openSteps: nil, doneSteps: nil) == nil)
        let nudge = health.record([("click", "There's no [12] on the screen.")], openSteps: nil, doneSteps: nil)
        #expect(nudge?.contains("another route") == true)
        #expect(health.record([("click", "There's no [9].")], openSteps: nil, doneSteps: nil) == nil)
        #expect(health.record([("click", "There's no [3].")], openSteps: nil, doneSteps: nil)?.contains("Four") == true)
    }
    @Test func successResets() {
        var health = TaskHealth()
        _ = health.record([("click", "Couldn't click it.")], openSteps: nil, doneSteps: nil)
        _ = health.record([("click", "Clicked “Inbox”.")], openSteps: nil, doneSteps: nil)
        #expect(health.record([("click", "Couldn't click it.")], openSteps: nil, doneSteps: nil) == nil)
        #expect(health.failuresInARow == 1)
    }
    @Test func notesDontCount() {
        var health = TaskHealth()
        _ = health.record([("click", "Couldn't click it.")], openSteps: nil, doneSteps: nil)
        #expect(health.record([("note", "No reply from HDFC yet")], openSteps: nil, doneSteps: nil) == nil)
        #expect(health.failuresInARow == 1)
    }
    @Test func listNotMoving() {
        var health = TaskHealth()
        var nudges = 0
        for _ in 0..<9 {
            if health.record([("browser_read", "page text")], openSteps: 5, doneSteps: 2) != nil { nudges += 1 }
        }
        #expect(nudges == 1)
        var moving = TaskHealth()
        for done in 0..<12 {
            #expect(moving.record([("browser_read", "page text")], openSteps: 12 - done, doneSteps: done) == nil)
        }
    }
}

/// Unfinished tasks kept on disk for "continue".
@Suite(.serialized) struct TaskResumeTests {
    init() {
        TaskResume.file = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-test-\(UUID().uuidString)/unfinished-task.json")
        TaskResume.reload()
    }

    @Test func survivesARestart() {
        let task = TaskResume.Pending(request: "go through my unread emails",
                                      steps: [.init(text: "open inbox", done: true), .init(text: "read HDFC", done: false)],
                                      notes: ["Amazon: order shipped"])
        TaskResume.save(task)
        TaskResume.reload()   // as if Murmur had quit
        #expect(TaskResume.hasPending)
        let back = TaskResume.take()
        #expect(back?.request == task.request)
        #expect(back?.steps == task.steps)
        #expect(back?.notes == task.notes)
        TaskResume.reload()
        #expect(!TaskResume.hasPending)   // taken once
    }
    @Test func finishedOrOldIsNotPending() {
        TaskResume.save(.init(request: "x", steps: [.init(text: "a", done: true)], notes: []))
        #expect(!TaskResume.hasPending)
        TaskResume.save(.init(request: "x", steps: [.init(text: "a", done: false)], notes: [],
                              at: Date().addingTimeInterval(-3 * 24 * 3600)))
        #expect(!TaskResume.hasPending)
        TaskResume.save(.init(request: "x", steps: [.init(text: "a", done: false)], notes: []))
        #expect(TaskResume.hasPending)
        TaskResume.clear()
        TaskResume.reload()
        #expect(!TaskResume.hasPending)
    }
    @Test func resumeWords() {
        #expect(TaskResume.isResume("continue"))
        #expect(TaskResume.isResume("aage badho"))
        #expect(TaskResume.isResume("okay, carry on."))
        #expect(!TaskResume.isResume("continue the story about the dragon who lived in a cave"))
    }
}

/// Reading a whole page for a summary.
struct PageDigestTests {
    func wants(_ said: String) -> Bool { PageDigest.wantsWholePage(QuickCommands.clean(said)) }

    @Test func wholePageRequests() {
        #expect(wants("summarise this page"))
        #expect(wants("give me a summary of this article"))
        #expect(wants("what's this post about"))
        #expect(wants("explain this thread and its comments"))
        #expect(wants("read the whole page and tell me the main points"))
        #expect(wants("is page ka saar batao"))
        #expect(wants("summarize it"))
        #expect(!wants("summarise my unread emails"))
        #expect(!wants("open youtube and play lofi"))
        #expect(!wants("what's on my calendar tomorrow"))
    }
    @Test func partsBreakAtParagraphs() {
        let paragraph = String(repeating: "word ", count: 300)   // 1,500 characters
        let text = (0..<10).map { "Para \($0). " + paragraph }.joined(separator: "\n\n")
        let parts = PageDigest.parts(text, size: 4000)
        #expect(parts.count >= 4)
        #expect(parts.allSatisfy { $0.count <= 4000 })
        #expect(parts.allSatisfy { $0.hasPrefix("Para ") })
        #expect(parts.joined(separator: " ").filter { $0 == "w" }.count == text.filter { $0 == "w" }.count)
        #expect(PageDigest.parts("short", size: 4000) == ["short"])
    }
    @Test func requestsAboutAllOfAList() {
        func all(_ said: String) -> Bool { PageDigest.wantsEverything(QuickCommands.clean(said)) }
        #expect(all("how many unread emails do I have"))
        #expect(all("list all my pending invoices"))
        #expect(all("which one is the cheapest"))
        #expect(all("reply to every comment"))
        #expect(all("what's the latest message from Rahul"))
        #expect(all("saare messages padho"))
        #expect(all("summarise this page"))
        #expect(!all("open youtube and play lofi"))
        #expect(!all("turn the volume down"))
        #expect(!all("click the sign in button"))
    }
    @Test func screensJoinWithoutTheOverlap() {
        // Scrolled a screenful: the last lines read are the first of the new screen.
        #expect(PageDigest.merge(["a", "b", "c", "d"], ["c", "d", "e", "f"]) == ["a", "b", "c", "d", "e", "f"])
        // A header that stays at the top of every screen.
        #expect(PageDigest.merge(["From", "a", "b", "c"], ["From", "b", "c", "d"]) == ["From", "a", "b", "c", "d"])
        // The screen didn't move: nothing added.
        #expect(PageDigest.merge(["a", "b", "c"], ["a", "b", "c"]) == ["a", "b", "c"])
        // Lines that repeat in the list ("Reply") stay, outside the overlap.
        #expect(PageDigest.merge(["Riya", "Reply", "Sam"], ["Sam", "Reply", "Neha", "Reply"])
                == ["Riya", "Reply", "Sam", "Reply", "Neha", "Reply"])
        // Nothing shared: the screen jumped, it goes after.
        #expect(PageDigest.merge(["a", "b"], ["x", "y"]) == ["a", "b", "x", "y"])
        #expect(PageDigest.merge([], ["x"]) == ["x"])
        #expect(PageDigest.lines("  one \n\n two\n") == ["one", "two"])
    }
    @Test func scrollingToolsAreAlwaysOffered() {
        #expect(ToolGroup.offers("scroll", in: []))
        #expect(ToolGroup.offers("read_everything", in: []))
    }
    @Test func oneLongLineStillSplits() {
        let parts = PageDigest.parts(String(repeating: "x", count: 10_000), size: 3000)
        #expect(parts.count == 4)
        #expect(parts.joined().count == 10_000)
    }
}

/// "Continue" after a finished answer: for half an hour (in TaskResumeTests' file, run one at a time).
extension TaskResumeTests {
    @Test func recentAnswerCanGoFurther() {
        TaskResume.save(.init(request: "summarise this page", steps: [], notes: [], answer: "It's about…", finished: true))
        TaskResume.reload()
        #expect(TaskResume.hasPending)
        #expect(TaskResume.take()?.answer == "It's about…")
    }
    @Test func oldAnswerIsNot() {
        TaskResume.save(.init(request: "summarise this page", steps: [], notes: [],
                              at: Date().addingTimeInterval(-40 * 60), answer: "x", finished: true))
        #expect(!TaskResume.hasPending)
    }
    @Test func moreResumeWords() {
        #expect(TaskResume.isResume("keep reading"))
        #expect(TaskResume.isResume("read the rest"))
        #expect(TaskResume.isResume("aage batao"))
        #expect(!TaskResume.isResume("aur batao"))
        #expect(!TaskResume.isResume("what else"))
    }
}

/// A PDF in the browser, read from the file: which pages a request means.
struct PDFTextTests {
    @Test func pagesAskedFor() {
        #expect(PDFText.pages("10", of: 21) == [10])
        #expect(PDFText.pages("5-7", of: 21) == [5, 6, 7])
        #expect(PDFText.pages("3, 8", of: 21) == [3, 8])
        #expect(PDFText.pages("page 4 to 6", of: 21) == [4, 5, 6])
        #expect(PDFText.pages("30", of: 21).isEmpty)
    }
    @Test func pagesARequestNames() {
        #expect(PDFText.pagesMentioned("Summarize the page 10 of this PDF.") == "10")
        #expect(PDFText.pagesMentioned("explain pages 5 to 7") == "5 to 7")
        #expect(PDFText.pagesMentioned("Did you read all the 21 pages?") == "")
        #expect(PDFText.pagesMentioned("Understand and summarize this PDF.") == "")
    }
    @Test func whatIsAPDF() {
        #expect(PDFText.isPDF(url: "https://arxiv.org/pdf/2610.12345", title: "Cache Engineering for Agents"))
        #expect(PDFText.isPDF(url: "file:///Users/me/Downloads/paper.pdf", title: ""))
        #expect(!PDFText.isPDF(url: "https://mail.google.com/mail/u/0/#inbox", title: "Inbox"))
        #expect(PDFText.joined([(2, " text ")], of: 3) == "--- Page 2 of 3 ---\ntext")
    }
}

/// Screen vision's text side: screenshots riding in tool results, and positions from the vision model in pixels.
struct VisionTextTests {
    @Test func screenshotsInToolResults() {
        let split = VisionText.split("Screenshot of Mail.\n" + VisionText.marker("ab12") + "\nmore " + VisionText.marker("cd34"))
        #expect(split.ids == ["ab12", "cd34"])
        #expect(!split.text.contains("[[screenshot"))
        #expect(VisionText.kept(["a", "b", "c"]) == ["b", "c"])
        #expect(VisionText.split("no pictures here").ids.isEmpty)
    }
    @Test func positionsInPixels() {
        let point = VisionText.pixels(relativeX: 500, y: 250, width: 1280, height: 800)
        #expect(point.x == 640 && point.y == 200)
        #expect(VisionText.inPixels("- Send (button) at (500, 250)", width: 1280, height: 800)
                == "- Send (button) at (640, 200)")
        let found = VisionText.location(in: #"{"x": 512, "y": 300}"#)
        #expect(found?.x == 512 && found?.y == 300)
        #expect(VisionText.location(in: #"{"none": true}"#) == nil)
        let box = VisionText.location(in: "[100, 200, 300, 400]")
        #expect(box?.x == 200 && box?.y == 300)
        #expect(VisionText.location(in: "I can't see it") == nil)
    }
    @Test func screensWithLittleOnThemGetALook() {
        #expect(CommandAgent.seesLittle("App: Figma · Window: x\nText on screen:\nok\nThings to press or type into:\n[1] button \"Share\""))
        let busy = "App: Mail\nText on screen:\n" + String(repeating: "Hello there. ", count: 30)
            + "\nThings to press or type into:\n[1] a\n[2] b\n[3] c\n[4] d\n[5] e"
        #expect(!CommandAgent.seesLittle(busy))
        #expect(ToolGroup.offers("look", in: []))
        #expect(ToolGroup.offers("click_on", in: []))
    }
}
