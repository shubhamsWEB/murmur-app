import Foundation
import Testing
@testable import AgentKit

/// "Write it for me": what's read round the box, what the model is asked, and what goes in.
struct ReplyWriterTests {
    private func piece(_ text: String, y: CGFloat, x: CGFloat = 100) -> ReplyWriter.Piece {
        .init(text: text, frame: CGRect(x: x, y: y, width: 300, height: 18))
    }

    /// A chat: the thread above the box, oldest first and the newest last; the send button beside it with what's
    /// above; the footer below; each line once.
    @Test func theThreadIsAboveTheBoxNewestLast() {
        let field = CGRect(x: 100, y: 600, width: 500, height: 40)
        let pieces = [piece("Can you send the deck by Friday?", y: 500), piece("Priya", y: 480),
                      piece("Sure, on it", y: 540), piece("Priya", y: 480, x: 400),
                      piece("Send", y: 610, x: 620), piece("Messages are end-to-end encrypted", y: 660)]
        let (above, below) = ReplyWriter.arrange(pieces, field: field)
        #expect(above == ["Priya", "Can you send the deck by Friday?", "Sure, on it", "Send"])
        #expect(below == ["Messages are end-to-end encrypted"])
    }

    /// A long thread: the newest lines are the ones kept.
    @Test func aLongThreadKeepsTheNewest() {
        let pieces = (0..<400).map { piece("message number \($0) in a long thread", y: CGFloat($0)) }
        let (above, _) = ReplyWriter.arrange(pieces, field: CGRect(x: 0, y: 1000, width: 400, height: 30), aboveLimit: 400)
        #expect(above.last == "message number 399 in a long thread")
        #expect(above.count < 20 && !above.contains("message number 0 in a long thread"))
    }

    @Test func theQuestionHasTheScreenTheBoxAndMemory() {
        let context = ReplyWriter.Context(app: "Slack", title: "Priya Shah", above: ["Priya: deck by Friday?"], below: [],
                                          draft: "say yes but not before 3", selection: nil)
        let prompt = ReplyWriter.prompt(context, me: ["You", "Shubham Agrawal"], digest: "### Projects\n- Acme launch: Priya's deck is due Friday",
                                        memory: "Priya Shah: design lead at Acme")
        #expect(prompt.contains("APP: Slack — Priya Shah"))
        #expect(prompt.contains("THE USER (you write as them): Shubham Agrawal") && !prompt.contains("You, also"))
        #expect(prompt.contains("Priya: deck by Friday?\n\n▶ THE BOX has an INSTRUCTION FOR YOU"))
        #expect(prompt.contains("design lead at Acme") && prompt.contains("Acme launch"))
        // The screen first; memory after it, as background (a small model wrote to Priya under a stranger's post).
        #expect(prompt.range(of: "ON THE SCREEN")!.lowerBound < prompt.range(of: "BACKGROUND")!.lowerBound)
        let empty = ReplyWriter.Context(app: "Mail", title: "", above: [], below: [], draft: "", selection: nil)
        #expect(ReplyWriter.prompt(empty, me: [], digest: nil, memory: nil).contains("▶ THE BOX: empty"))
        let draft = ReplyWriter.Context(app: "Mail", title: "", above: [], below: [], draft: "Hi Ananya, thanks for", selection: nil)
        #expect(ReplyWriter.prompt(draft, me: [], digest: nil, memory: nil).contains("THE USER'S DRAFT"))
    }

    /// Only what the screen is about goes in as background: the user's week stays out of a comment on a stranger's
    /// post, even when he shares a surname with someone they know.
    @Test func backgroundIsOnlyWhatTheScreenIsAbout() {
        let digest = "### Projects\n- Murmur: 1.8.1 released Sat 21 Nov.\n### People\n- Priya Shah: reviewing the Acme launch; wants the final pricing sheet."
        let post = ReplyWriter.Context(app: "Google Chrome", title: "LinkedIn", above: [
            "Kunal Shah • 2nd", "Founder at CRED", "Shipped 41 updates this year, none of them big, all of them mattered.",
            "1,204 reactions · 86 comments"], below: [], draft: "", selection: nil)
        #expect(ReplyWriter.relevant(digest, to: post) == nil)
        #expect(!ReplyWriter.prompt(post, me: ["Shubham"], digest: digest, memory: nil).contains("BACKGROUND"))
        let chat = ReplyWriter.Context(app: "Slack", title: "Rahul Mehta (DM)", above: [
            "Rahul Mehta  4:12 PM", "Can you send me the final pricing sheet today?"], below: [], draft: "", selection: nil)
        #expect(ReplyWriter.relevant(digest, to: chat)
                == "### People\n- Priya Shah: reviewing the Acme launch; wants the final pricing sheet.")
        let priya = ReplyWriter.Context(app: "WhatsApp", title: "Priya Shah", above: ["Are you joining on Monday?"],
                                        below: [], draft: "", selection: nil)
        #expect(ReplyWriter.relevant(digest, to: priya)?.contains("Priya Shah: reviewing") == true)
        #expect(ReplyWriter.relevant(digest, to: priya)?.contains("Murmur") == false)
        // The user's own name on the screen says nothing about what the page is about.
        let mail = ReplyWriter.Context(app: "Mail", title: "", above: ["Hi Shubham,", "Are you free this week?"],
                                       below: [], draft: "", selection: nil)
        #expect(ReplyWriter.relevant("- Shubham Agrawal: building Murmur", to: mail, me: ["Shubham Agrawal"]) == nil)
    }

    @Test func instructionsAreToldFromDrafts() {
        for instruction in ["say yes but after 5pm, and ask if he needs the enterprise tier too", "polite no",
                            "tell them I'm out till Monday", "Decline, busy that week", "ask her for the invoice",
                            "thank him and confirm Friday"] {
            #expect(ReplyWriter.isInstruction(instruction), "\(instruction)")
        }
        for draft in ["Hi Ananya, thanks for reaching out", "Sounds good, see you then", "I think we should", "Yes",
                      "Saying goodbye is hard"] {
            #expect(!ReplyWriter.isInstruction(draft), "\(draft)")
        }
    }

    @Test func whatGoesInIsTheTextAlone() {
        let context = ReplyWriter.Context(app: "Slack", title: "", above: ["Priya: deck by Friday?", "Sure, on it"],
                                          below: [], draft: "say yes", selection: nil)
        #expect(ReplyWriter.clean("Here's a reply:\nYes, I'll send it by Friday.", context: context) == "Yes, I'll send it by Friday.")
        #expect(ReplyWriter.clean("“Yes, Friday works.”", context: context) == "Yes, Friday works.")
        #expect(ReplyWriter.clean("<think>she wants the deck</think>Yes, by Friday.", context: context) == "Yes, by Friday.")
        #expect(ReplyWriter.clean("```\nYes, by Friday.\n```", context: context) == "Yes, by Friday.")
        // Saying back what's already there isn't writing anything.
        #expect(ReplyWriter.clean("Sure, on it.", context: context) == nil)
        #expect(ReplyWriter.clean("Say yes", context: context) == nil)
        #expect(ReplyWriter.clean("   ", context: context) == nil)
        // A line that ends in a colon but is the message itself stays.
        #expect(ReplyWriter.clean("Two things:\n1. Yes\n2. Friday", context: context) == "Two things:\n1. Yes\n2. Friday")
    }
}
