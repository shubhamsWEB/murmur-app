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
