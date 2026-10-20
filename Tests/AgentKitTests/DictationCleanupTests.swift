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
