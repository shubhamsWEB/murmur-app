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

    /// A chat window: other people's messages on the left, yours on the right, a list of chats beside it.
    @Test func yourMessagesAreToldFromTheirsBySide() {
        let field = CGRect(x: 420, y: 800, width: 700, height: 40)
        func bubble(_ text: String, y: CGFloat, mine: Bool, width: CGFloat = 320) -> ReplyWriter.Piece {
            .init(text: text, frame: CGRect(x: mine ? 1180 - width : 400, y: y, width: width, height: 20))
        }
        let pieces = [
            ReplyWriter.Piece(text: "Rahul: see you at 6 then", frame: CGRect(x: 20, y: 300, width: 300, height: 18)),  // the chat list
            ReplyWriter.Piece(text: "Today", frame: CGRect(x: 760, y: 380, width: 60, height: 16)),
            bubble("I built a small app, can you try it and tell me what you think?", y: 420, mine: true, width: 480),
            ReplyWriter.Piece(text: "10:42", frame: CGRect(x: 1130, y: 444, width: 40, height: 12)),
            bubble("Sure, I'll try it tonight", y: 500, mine: false, width: 200),
            bubble("ok thanks", y: 560, mine: true, width: 90),
            bubble("ok thanks", y: 620, mine: false, width: 90),
        ]
        let (above, _) = ReplyWriter.arrange(pieces, field: field)
        let sides = ReplyWriter.sides(of: above, pieces: pieces, field: field)
        func side(_ text: String) -> ReplyWriter.Side? { above.firstIndex(of: text).flatMap { sides[$0] } }
        #expect(side("I built a small app, can you try it and tell me what you think?") == .me)
        #expect(side("Sure, I'll try it tonight") == .them)
        // Not messages, or not in the conversation: a date in the middle, a time, the list of chats.
        #expect(side("Today") == nil && side("10:42") == nil && side("Rahul: see you at 6 then") == nil)
        // The same words from both of you can't be told apart by text: unmarked.
        #expect(side("ok thanks") == nil)

        let context = ReplyWriter.Context(app: "WhatsApp", title: "Rahul", above: above, below: [], draft: "",
                                          selection: nil, sides: sides)
        let prompt = ReplyWriter.prompt(context, me: ["You"], digest: nil, memory: nil)
        #expect(prompt.contains("ME: I built a small app, can you try it and tell me what you think?"))
        #expect(prompt.contains("THEM: Sure, I'll try it tonight"))
        #expect(prompt.contains("\nToday\n"))
    }

    /// A page that isn't two-sided (an email, a document, a thread with names): nothing is marked.
    @Test func aOneSidedWindowIsLeftUnmarked() {
        let field = CGRect(x: 100, y: 600, width: 800, height: 40)
        let pieces = [piece("Priya: can you send the deck by Friday?", y: 400), piece("Lee: I can review it Thursday", y: 440),
                      ReplyWriter.Piece(text: "Tue 24 Nov, 10:42 AM", frame: CGRect(x: 740, y: 400, width: 160, height: 14))]
        let (above, _) = ReplyWriter.arrange(pieces, field: field)
        #expect(ReplyWriter.sides(of: above, pieces: pieces, field: field).allSatisfy { $0 == nil })
        let context = ReplyWriter.Context(app: "Mail", title: "Deck", above: above, below: [], draft: "", selection: nil)
        #expect(!ReplyWriter.prompt(context, me: [], digest: nil, memory: nil).contains("THEM:"))
    }

    /// All Murmur knows goes with the request: who it's to, what memory holds about them, and the user's voice.
    @Test func theRequestCarriesThePersonMemoryAndTheUsersVoice() {
        let context = ReplyWriter.Context(app: "WhatsApp", title: "WhatsApp", above: ["Rahul Verma", "can you try my app?", "sure will try tonight"],
                                          below: [], draft: "", selection: nil, sides: [nil, .me, .them])
        #expect(ReplyWriter.partner(context, known: [], me: ["Shubham Agrawal"]) == "Rahul Verma")
        #expect(ReplyWriter.partner(context, known: ["Shubham Agrawal", "Rahul V"], me: ["Shubham Agrawal"]) == "Rahul V")
        let dated = ReplyWriter.Context(app: "Mail", title: "Mail", above: ["Today", "Mark As Read", "hello there"], below: [], draft: "", selection: nil)
        #expect(ReplyWriter.partner(dated, known: [], me: []) == "Mark As Read" || ReplyWriter.partner(dated, known: [], me: []) == nil)
        #expect(ReplyWriter.ownLines(context) == ["can you try my app?"])
        let knowing = ReplyWriter.Knowledge(profile: "Writes short, lowercase, no sign-offs.", digest: nil, partner: "Rahul Verma",
                                            dossier: "Rahul Verma: college friend; testing Sudoku Clan for the user since 20 Nov",
                                            memory: nil, sent: ["cool, lmk how it goes"],
                                            corrections: [(wrote: "Thank you so much!", sent: "thanks man")])
        let prompt = ReplyWriter.prompt(context, me: ["Shubham Agrawal"], knowing: knowing)
        #expect(prompt.contains("THEY ARE WRITING TO: Rahul Verma"))
        #expect(prompt.contains("WHAT MURMUR'S MEMORY KNOWS ABOUT RAHUL VERMA AND THE USER:\nRahul Verma: college friend"))
        #expect(prompt.contains("- can you try my app?") && prompt.contains("- cool, lmk how it goes"))
        #expect(prompt.contains("- Murmur wrote: Thank you so much!\n  They sent: thanks man"))
        #expect(prompt.contains("Writes short, lowercase"))
        // The window and the box come before everything Murmur adds.
        #expect(prompt.range(of: "▶ THE BOX")!.lowerBound < prompt.range(of: "WHAT MURMUR'S MEMORY")!.lowerBound)
    }

    /// A time, amount or link that's in nothing the model was given is made up.
    @Test func madeUpDetailsAreCaught() {
        let given = "THEM: can we meet on Friday at 4pm? the invoice was ₹12,500\nBACKGROUND: office at 221B Baker Street"
        #expect(ReplyWriter.unsupported(in: "Friday at 4 pm works, and yes ₹12,500 is right.", given: given).isEmpty)
        #expect(ReplyWriter.unsupported(in: "Sure, let's do 5:30pm and I'll send https://cal.com/me", given: given) == ["https://cal.com/me", "5:30pm"])
        #expect(ReplyWriter.unsupported(in: "I have 2 things to add, thanks!", given: given).isEmpty)
        #expect(ReplyWriter.unsupported(in: "It was ₹15,000 I think", given: given) == ["₹15,000"])
        #expect(ReplyWriter.recheck("x", unsupported: ["5:30pm"]).contains("5:30pm"))
    }

    /// What became of what Murmur wrote, and what it learns from it.
    @Test func whatYouSentIsWhatMurmurLearnsFrom() throws {
        // Sent as written; sent after an edit; ⌘Z back to the instruction; replaced by your own words; left there.
        #expect(WriteMemory.outcome(wrote: "Thanks, will do.", before: "", last: "Thanks, will do.", emptied: true)?.0 == .kept)
        let edited = WriteMemory.outcome(wrote: "Thank you so much, I will do that.", before: "", last: "thanks, will do that", emptied: true)
        #expect(edited?.0 == .edited && edited?.sent == "thanks, will do that")
        #expect(WriteMemory.outcome(wrote: "Yes, after 5.", before: "say yes but after 5", last: "say yes but after 5", emptied: false)?.0 == .reverted)
        #expect(WriteMemory.outcome(wrote: "Yes, after 5.", before: "", last: "call me when free", emptied: true)?.0 == .reverted)
        #expect(WriteMemory.outcome(wrote: "Yes, after 5.", before: "", last: "Yes, after 5.", emptied: false) == nil)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-written-\(UUID().uuidString)")
        let memory = WriteMemory(folder: folder)
        memory.add(.init(app: "WhatsApp", partner: "Rahul", wrote: "Thank you so much!", sent: "thanks man", outcome: .edited))
        memory.add(.init(app: "WhatsApp", partner: "Priya", wrote: "Sounds good to me.", sent: "Sounds good to me.", outcome: .kept))
        memory.add(.init(app: "WhatsApp", partner: "Priya", wrote: "No.", sent: nil, outcome: .reverted))
        memory.add(.init(app: "Slack", partner: nil, wrote: "On it, will update by EOD.", sent: "On it, will update by EOD.", outcome: .kept))
        let again = WriteMemory(folder: folder)
        #expect(again.entries.count == 4)
        // To Priya: what was sent to her first, then your own rewrites to others; never another app's, never a revert.
        #expect(again.examples(app: "WhatsApp", partner: "Priya") == ["Sounds good to me.", "thanks man"])
        #expect(again.examples(app: "WhatsApp", partner: nil) == ["thanks man", "Sounds good to me."])
        #expect(again.corrections(app: "WhatsApp").map(\.sent) == ["thanks man"])
        again.forgetAll()
        #expect(WriteMemory(folder: folder).entries.isEmpty)
    }

    /// An app that describes each message for VoiceOver says whose it is: that's believed before anything else.
    @Test func describedMessagesSayWhoseTheyAre() {
        let theirs = "\u{200E}message, Try karta hu, 6:26 PM, \u{200E}Received from Rahul(Shaadi.Com)"
        let mine = "\u{200E}Your message, Bhai ye try kar, Bata kaisa h app, 6:19 PM, \u{200E}Sent to Rahul(Shaadi.Com), Read"
        #expect(ReplyWriter.saidBy(theirs) == .them && ReplyWriter.saidBy(mine) == .me)
        #expect(ReplyWriter.saidBy("Can you send the deck by Friday?") == nil)
        #expect(ReplyWriter.spoken(theirs) == "Try karta hu")
        #expect(ReplyWriter.spoken(mine) == "Bhai ye try kar, Bata kaisa h app")
        #expect(ReplyWriter.spoken("Sure, on it") == "Sure, on it")
        #expect(ReplyWriter.named(in: theirs) == "Rahul(Shaadi.Com)")
        let context = ReplyWriter.Context(app: "WhatsApp", title: "WhatsApp", above: [mine, theirs], below: [], draft: "", selection: nil,
                                          sides: ReplyWriter.sides(of: [mine, theirs], pieces: [], field: .zero))
        #expect(context.sides == [.me, .them])
        #expect(ReplyWriter.partner(context, known: ["Someone Else"], me: []) == "Rahul(Shaadi.Com)")
        #expect(ReplyWriter.ownLines(context) == ["Bhai ye try kar, Bata kaisa h app"])
        let prompt = ReplyWriter.prompt(context, me: [], knowing: .init(partner: "Rahul(Shaadi.Com)"))
        #expect(prompt.contains("ME: Bhai ye try kar, Bata kaisa h app\nTHEM: Try karta hu"))
        // What memory found for a name is kept only where it's about them.
        let found = "- WhatsApp conversation with Roma about wardrobes\n- Rahul asked about referrals at Shaadi.com"
        #expect(ReplyWriter.about("Rahul(Shaadi.Com)", in: found) == "- Rahul asked about referrals at Shaadi.com")
        #expect(ReplyWriter.about("Rahul", in: "- nothing on him") == nil)
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
