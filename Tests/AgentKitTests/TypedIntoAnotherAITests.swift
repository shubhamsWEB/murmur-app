import Testing
@testable import AgentKit

/// What you say into another AI's text box, or at length into any text box, is typed: on 23 Nov two dictations into
/// Claude ran as commands for Murmur instead, and neither was typed.
struct TypedIntoAnotherAITests {
    let long = "Check if the new functionality is working as expected and also the onboarding flow covers that as well. "
        + "So I found one gap in the onboarding right now everything is perfect but it's just that let's say if we want "
        + "to actually show how the one tap feature works there is no actual UI to show"

    @Test func intoClaudeItsTyped() {
        #expect(IntentClassifier.typed("Ab jo murmur ki website hai usko bhi update kar do aur release karo",
                                       focus: .textField, frontApp: "Claude", windowTitle: "Claude") != nil)
        #expect(IntentClassifier.typed("Start with P2 P1 and complete all the tasks in version 1.3",
                                       focus: .textField, frontApp: "Claude", windowTitle: nil) != nil)
        #expect(IntentClassifier.typed("summarise what we decided", focus: .textField, frontApp: "Google Chrome",
                                       windowTitle: "Claude - Murmur website") != nil)
        #expect(IntentClassifier.typed("fix the failing test", focus: .textField, frontApp: "Cursor", windowTitle: nil) != nil)
    }

    @Test func longIsTypedAnywhere() {
        #expect(IntentClassifier.typed(long, focus: .textField, frontApp: "Slack", windowTitle: nil) != nil)
    }

    @Test func stillACommandWhenItsOne() {
        // Named, a short known command, nowhere to type, or short in an ordinary app: the usual rules decide.
        #expect(IntentClassifier.typed("Murmur, open Slack", focus: .textField, frontApp: "Claude", windowTitle: nil) == nil)
        #expect(IntentClassifier.typed("open Slack", focus: .textField, frontApp: "Claude", windowTitle: nil) == nil)
        #expect(IntentClassifier.typed(long, focus: .notText, frontApp: "Finder", windowTitle: nil) == nil)
        #expect(IntentClassifier.typed("check my messages from Priya", focus: .textField, frontApp: "Slack",
                                       windowTitle: nil) == nil)
    }
}
