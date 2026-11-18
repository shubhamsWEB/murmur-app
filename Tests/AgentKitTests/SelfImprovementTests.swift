import Foundation
import Testing
@testable import AgentKit

/// The self-improvement memory: learning, merging, the selector by model, corrections, reading the AI's reply.
struct SelfImprovementTests {
    func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json") }

    func proposal(_ cause: String, _ rule: String, apps: [String] = [], words: [String] = [], retire: [(id: String, why: String)] = []) -> SelfImprovement.Proposal {
        .init(add: true, rootCause: cause, rule: rule, rationale: "because", scope: .init(apps: apps, words: words), prediction: "fixes it", retire: retire)
    }

    @Test func testLearnScopeAndPersist() {
        let file = temp()
        let sim = SelfImprovement(file: file)
        let changes = sim.learn(proposal("Finishes before typing the reply", "Type the reply before saying done.", apps: ["Slack"], words: ["reply"]), request: "reply to Priya", app: "Slack", model: "claude-haiku-5-5")
        #expect(changes.count == 1)
        #expect(sim.lessons(for: "reply to John", app: "Mail", model: "m").count == 1)       // by words
        #expect(sim.lessons(for: "open the doc", app: "Slack", model: "m").count == 1)       // by app
        #expect(sim.lessons(for: "open the doc", app: "Mail", model: "m").count == 0)
        #expect(sim.lessons(for: "replying", app: nil, model: "m").count == 0)              // whole words
        let again = SelfImprovement(file: file)
        #expect(again.problems.count == 1)
        #expect(again.problems[0].attempts[0].rule == "Type the reply before saying done.")
        #expect(SelfImprovement.prompt(sim.lessons(for: "reply", app: nil, model: "m")) != nil)
    }

    @Test func testMergeReviseKeepsHistory() {
        let sim = SelfImprovement(file: nil)
        sim.learn(proposal("Finishes before typing the reply", "Rule one."), request: "a", app: nil, model: "m")
        sim.learn(proposal("finishes before typing the reply!", "Rule one."), request: "b", app: nil, model: "m")   // same rule: nothing
        #expect(sim.problems[0].attempts.count == 1)
        sim.learn(proposal("Finishes before  typing the reply", "Rule two."), request: "c", app: nil, model: "m")
        #expect(sim.problems.count == 1)
        #expect(sim.problems[0].attempts.count == 2)
        #expect(sim.problems[0].attempts[0].retired != nil)
        #expect(sim.problems[0].current?.rule == "Rule two.")
        #expect(sim.rendered().contains("Rule one."))
        #expect(sim.rendered().contains("Rule two."))
    }

    @Test func testSelectorPerModelAndRetire() {
        let sim = SelfImprovement(file: nil)
        sim.learn(proposal("x", "Do x."), request: "a", app: nil, model: "m")
        let lesson = sim.lessons(for: "anything", app: nil, model: "haiku")
        #expect(lesson.count == 1)
        for _ in 0..<3 { sim.observe(lesson, worked: false, model: "haiku", request: "r") }
        #expect(sim.lessons(for: "anything", app: nil, model: "haiku").count == 0)   // off for haiku
        #expect(sim.lessons(for: "anything", app: nil, model: "sonnet").count == 1)  // still for sonnet
        #expect(sim.problems[0].current?.retired == nil)
        sim.observe(lesson, worked: false, model: "sonnet", request: "r")
        #expect(sim.problems[0].current == nil)                                             // retired: 0 of 4
        #expect(sim.lessons(for: "anything", app: nil, model: "sonnet").count == 0)
        #expect(sim.problems[0].attempts.count == 1)                                 // kept
    }

    @Test func testCorrectionFlipsObservation() {
        let sim = SelfImprovement(file: nil)
        sim.learn(proposal("x", "Do x."), request: "a", app: nil, model: "m")
        let lesson = sim.lessons(for: "q", app: nil, model: "m")
        sim.observe(lesson, worked: true, model: "m", request: "send it")
        sim.correct(lesson, model: "m", request: "send it")
        #expect(sim.problems[0].attempts[0].tally().worked == 0)
        #expect(sim.problems[0].attempts[0].tally().of == 1)
    }

    @Test func testRetireByReview() {
        let sim = SelfImprovement(file: nil)
        sim.learn(proposal("x", "Do x."), request: "a", app: nil, model: "m")
        let id = sim.problems[0].attempts[0].id
        var p = proposal("y", "Do y.")
        p.retire = [(id: id, why: "hurts")]
        sim.learn(p, request: "b", app: nil, model: "m")
        #expect(sim.problems.count == 2)
        #expect(sim.problems[0].current == nil)
        #expect(sim.problems[1].current?.rule == "Do y.")
    }

    @Test func testParse() {
        let reply = """
        Here you go:
        ```json
        {"action": "add", "root_cause": "Clicks before the page loads", "rule": "Wait for the page.", "rationale": "r",
         "scope": {"apps": ["Safari"], "words": ["book", ""]}, "prediction": "p", "retire": [{"id": "a1-5", "why": "w"}, {"x": 1}]}
        ```
        """
        let p = SelfImprovement.proposal(from: reply)
        #expect(p?.add == true)
        #expect(p?.scope.apps == ["Safari"])
        #expect(p?.scope.words == ["book"])
        #expect(p?.retire.count == 1)
        #expect(SelfImprovement.proposal(from: #"{"action":"none"}"#)?.add == false)
        #expect(SelfImprovement.proposal(from: "no json") == nil)
    }

    @Test func testRunAndCorrection() {
        #expect(SelfImprovement.isCorrection("No, I meant the other file"))
        #expect(SelfImprovement.isCorrection("you didn't send it"))
        #expect(SelfImprovement.isCorrection("That's wrong"))
        #expect(!SelfImprovement.isCorrection("note the meeting"))
        #expect(!SelfImprovement.isCorrection("open notes"))
        let ok = SelfImprovement.Run(request: "r", app: nil, window: nil, model: "m", steps: [(tool: "click", text: "c", worked: false)], sentBack: [], stopped: false, answer: nil)
        #expect(!ok.wentWrong)
        var bad = ok
        bad.sentBack = ["said done"]
        #expect(bad.wentWrong)
        #expect(SelfImprovement.shared === SelfImprovement.shared)
        #expect(SelfImprovement(file: nil).reflection(on: bad).contains("FAILED click"))
    }

    @Test func testCap() {
        let sim = SelfImprovement(file: nil)
        for i in 0..<70 { sim.learn(proposal("cause \(i)", "Rule \(i)."), request: "r", app: nil, model: "m", at: Date(timeIntervalSince1970: Double(1_000_000 + i))) }
        #expect(sim.problems.count == 60)
        #expect(!sim.problems.contains { $0.rootCause == "cause 0" })
    }
}
