import Testing
@testable import AgentKit

/// The check on AI cleanup: a tidied version of what was said gets through; anything the model wrote, answered,
/// translated or dropped doesn't (the words as heard are typed instead).
struct DictationCleanupTests {
    func accept(_ heard: String, _ cleaned: String) -> String? {
        DictationCleanup.accept(original: heard, cleaned: cleaned)
    }

    @Test func fillersRemoved() {
        #expect(accept("um so I was uh thinking we could go tomorrow", "So I was thinking we could go tomorrow.")
                == "So I was thinking we could go tomorrow.")
    }
    @Test func selfCorrection() {
        #expect(accept("let's meet at 5 no 6pm", "Let's meet at 6pm.") == "Let's meet at 6pm.")
    }
    @Test func selfCorrectionLonger() {
        #expect(accept("send it to Rahul sorry I mean send it to Priya", "Send it to Priya.") == "Send it to Priya.")
    }
    @Test func list() {
        let out = "Buy:\n- milk\n- eggs\n- bread"
        #expect(accept("buy first milk second eggs third bread", out) == out)
    }
    @Test func quotesUnwrapped() {
        #expect(accept("see you at the meeting tomorrow", "\"See you at the meeting tomorrow.\"")
                == "See you at the meeting tomorrow.")
    }
    @Test func answeringRejected() {
        #expect(accept("what is the capital of France", "The capital of France is Paris.") == nil)
    }
    @Test func preambleRejected() {
        #expect(accept("see you at the meeting tomorrow", "Here is the tidied text: See you at the meeting tomorrow.") == nil)
    }
    @Test func rewriteRejected() {
        #expect(accept("can you send me the file when you get a chance", "Please share the document at your convenience.") == nil)
    }
    @Test func translationRejected() {
        #expect(accept("main kal office aaunga aur meeting karenge", "I will come to the office tomorrow and we will have a meeting.") == nil)
    }
    @Test func hinglishKept() {
        #expect(accept("um main kal office aaunga", "Main kal office aaunga.") == "Main kal office aaunga.")
    }
    @Test func droppingTooMuchRejected() {
        #expect(accept("I think we should move the launch to next week because the build is not ready", "We should move the launch.") == nil)
    }
    @Test func emptyRejected() { #expect(accept("hello there my friend", "  ") == nil) }
    @Test func shortNotWorthIt() {
        #expect(!DictationCleanup.worthCleaning("ok thanks"))
        #expect(DictationCleanup.worthCleaning("ok thanks see you soon"))
    }
    @Test func categories() {
        #expect(DictationCleanup.category(bundleID: "net.whatsapp.WhatsApp", windowTitle: nil) == .personal)
        #expect(DictationCleanup.category(bundleID: "com.tinyspeck.slackmacgap", windowTitle: nil) == .work)
        #expect(DictationCleanup.category(bundleID: "com.apple.mail", windowTitle: nil) == .email)
        #expect(DictationCleanup.category(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - me@gmail.com - Gmail") == .email)
        #expect(DictationCleanup.category(bundleID: "com.google.Chrome", windowTitle: "WhatsApp") == .personal)
        #expect(DictationCleanup.category(bundleID: "com.apple.Notes", windowTitle: "Notes") == .other)
    }
    @Test func veryCasualOnlyForPersonal() {
        #expect(DictationCleanup.Category.personal.styles.contains(.veryCasual))
        #expect(!DictationCleanup.Category.email.styles.contains(.veryCasual))
    }

}

/// The check on grammar fixing: a grammar fix of what was said gets through; a rewrite, an answer, a "not" that turns
/// the meaning round, a changed number or reordered words don't.
struct GrammarFixTests {
    func fix(_ heard: String, _ fixed: String) -> String? {
        DictationCleanup.accept(original: heard, cleaned: fixed, cleanup: false, grammar: true)
    }
    func both(_ heard: String, _ fixed: String) -> String? {
        DictationCleanup.accept(original: heard, cleaned: fixed, cleanup: true, grammar: true)
    }

    @Test func verbForms() {
        #expect(fix("he go to office every day", "He goes to office every day.") == "He goes to office every day.")
        #expect(fix("they was late for the meeting", "They were late for the meeting.") == "They were late for the meeting.")
        #expect(fix("I have two file to send you", "I have two files to send you.") == "I have two files to send you.")
    }
    @Test func smallWordsAdded() {
        #expect(fix("I going to office tomorrow", "I am going to office tomorrow.") == "I am going to office tomorrow.")
        #expect(fix("she is best developer in team", "She is the best developer in the team.")
                == "She is the best developer in the team.")
    }
    @Test func wordFixedOutright() {
        #expect(fix("yesterday I buy a new laptop", "Yesterday I bought a new laptop.") == "Yesterday I bought a new laptop.")
    }
    @Test func alreadyCorrectKept() {
        #expect(fix("Can you send me the report by Friday?", "Can you send me the report by Friday?")
                == "Can you send me the report by Friday?")
    }
    @Test func rewriteRejected() {
        #expect(fix("can you send me the file when you get a chance", "Please share the document at your convenience.") == nil)
        #expect(fix("I think the build is not ready yet", "In my opinion, the build isn't ready.") == nil)
    }
    @Test func answerRejected() {
        #expect(fix("what is the capital of France", "The capital of France is Paris.") == nil)
        #expect(fix("he go to office every day", "Corrected: He goes to office every day.") == nil)
    }
    @Test func meaningFlipRejected() {
        #expect(fix("I will send the report today", "I will not send the report today.") == nil)
        #expect(fix("I don't need the report today", "I need the report today.") == nil)
    }
    @Test func numberChangeRejected() {
        #expect(fix("the meeting is at 5 pm tomorrow", "The meeting is at 6 pm tomorrow.") == nil)
    }
    @Test func reorderRejected() {
        #expect(fix("tomorrow we will discuss the budget and the hiring plan",
                    "We will discuss the hiring plan and the budget tomorrow.") == nil)
    }
    @Test func droppingRejected() {
        #expect(fix("I think we should move the launch to next week because the build is not ready",
                    "We should move the launch to next week.") == nil)
    }
    @Test func hinglishKept() {
        #expect(fix("main kal office aaunga", "Main kal office aaunga.") == "Main kal office aaunga.")
        #expect(fix("main kal office aaunga aur meeting karenge", "I will come to the office tomorrow and have a meeting.") == nil)
    }
    @Test func withCleanup() {
        #expect(both("um he go to the uh office at 5 no 6pm", "He goes to the office at 6pm.") == "He goes to the office at 6pm.")
        #expect(both("so they was thinking we could go tomorrow", "So they were thinking we could not go tomorrow.") == nil)
    }
    @Test func workedExamplesPassTheCheck() {
        for example in DictationCleanup.grammarExamples {
            #expect(fix(example.heard, example.fixed) == example.fixed)
        }
        #expect(DictationCleanup.grammarTurns("he go home").count == DictationCleanup.grammarExamples.count * 2 + 1)
    }
    /// What Murmur Cleanup (v1) replied with the grammar prompt and examples: each one gets through.
    @Test func modelRepliesAccepted() {
        for (heard, fixed) in [
            ("he go to office every day and he come back late", "He goes to office every day and he comes back late."),
            ("I going to send you two file after the meeting", "I am going to send you two files after the meeting."),
            ("yesterday I buy a new laptop for my brother", "Yesterday I bought a new laptop for my brother."),
            ("She don't know about the deadline yet", "She doesn't know about the deadline yet."),
            ("the team have finished there work and are going home", "The team have finished their work and are going home."),
            ("please remind me to call Rahul at 5 pm tomorrow", "Please remind me to call Rahul at 5 pm tomorrow."),
            ("what is the capital of France", "What is the capital of France?"),
        ] {
            #expect(fix(heard, fixed) == fixed)
        }
        #expect(both("um he go to the uh office at 5 no 6pm tomorrow", "He goes to the office at 6pm tomorrow.")
                == "He goes to the office at 6pm tomorrow.")
        #expect(both("she don't know about the deadline yet um I will tell her", "She don't know about the deadline yet. I will tell her.")
                == "She don't know about the deadline yet. I will tell her.")
    }
    @Test func worthFixing() {
        #expect(!DictationCleanup.worthFixing("ok thanks"))
        #expect(DictationCleanup.worthFixing("he go home"))
    }
    @Test func prompts() {
        let alone = DictationCleanup.grammarSystem()
        #expect(alone.contains("Fix grammar mistakes"))
        #expect(!alone.contains("filler"))
        let combined = DictationCleanup.system(style: .formal, category: .email, grammar: true)
        #expect(combined.contains("5. Fix grammar mistakes"))
        #expect(combined.contains("Apart from fixing grammar, keep every other word"))
        // Cleanup alone is unchanged: Murmur's cleanup model was trained on exactly this.
        let tidy = DictationCleanup.system(style: .formal, category: .email)
        #expect(!tidy.contains("grammar"))
        #expect(tidy.contains("Never do anything else. Keep every other word exactly as spoken"))
    }
}
