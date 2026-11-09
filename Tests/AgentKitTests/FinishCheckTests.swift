import Foundation
import Testing
@testable import AgentKit

/// On 2026-11-09 the user asked Murmur seven times to solve the Sudoku in Chrome and fill it in. It solved it, twice,
/// and entered one number: it called done after only working the answer out, said "I'll enter the numbers next" and
/// stopped, asked whether to go on, entered one number and finished, and on the follow-ups said it "couldn't
/// reliably solve" what it had solved a minute before. The words and commands below are from that run's log.
struct FinishCheckTests {
    // MARK: What the user asked for

    @Test func requestsToChangeTheScreen() {
        for said in ["Solve this local puzzle.", "Solve this to puzzle.", "Enter the missing numbers.", "Do it.",
                     "Do the complete board, not just one number.", "I want you to fill the complete board.",
                     "Fill in this form with my details", "Tick all the boxes", "Type my address here",
                     "Turn it off", "Bhar do saare numbers", "Go ahead"] {
            #expect(FinishCheck.asksToChangeScreen(said), "\(said)")
        }
    }

    @Test func requestsToBeToldOrToOpenAreNot() {
        for said in ["What's on my screen?", "Open Slack", "Summarise this page", "Set a timer for five minutes",
                     "How many unread emails do I have?", "Search my files for the lease", "Play some lofi"] {
            #expect(!FinishCheck.asksToChangeScreen(said), "\(said)")
        }
    }

    // MARK: What the model said when it stopped

    @Test func repliesThatAdmitTheJobIsntDone() {
        for reply in ["I solved the Sudoku, but I haven't filled it in on the board yet. The page has Notes mode on.",
                      "Solving the puzzle now; I'll enter the missing numbers next.",
                      "So far I've filled in one cell.",
                      "I've entered row 1. The remaining cells are below.",
                      "The form isn't finished yet: the address is still to do."] {
            #expect(FinishCheck.soundsUnfinished(reply), "\(reply)")
        }
        for reply in ["Done: all 45 cells are filled in and the board is complete.", "I've filled in every cell.",
                      "Sent the message to Roma.", "The board is solved and filled in."] {
            #expect(!FinishCheck.soundsUnfinished(reply), "\(reply)")
        }
    }

    @Test func askingLeaveIsntARealQuestion() {
        #expect(FinishCheck.asksPermissionToGoOn("Should I turn off Notes mode and enter the numbers?"))
        #expect(FinishCheck.asksPermissionToGoOn("I solved it. Do you want me to fill it in?"))
        #expect(FinishCheck.asksPermissionToGoOn("Shall I continue with the rest?"))
        #expect(!FinishCheck.asksPermissionToGoOn("Which resume do you mean: the PDF or the Word file?"))
        #expect(!FinishCheck.asksPermissionToGoOn("Done, all of it is filled in."))
    }

    // MARK: The runs, replayed

    private func screenJob(changed: Bool) -> FinishCheck.Run {
        FinishCheck.Run(wantsScreenWork: true, changedTheScreen: changed)
    }

    /// 19:57 "Solve this to puzzle": the solver ran, then done, with nothing entered.
    @Test func doneAfterOnlyWorkingItOutIsSentBack() {
        var run = screenJob(changed: false)
        let first = FinishCheck.verdict(.done, reply: "", request: "Solve this to puzzle.", run: &run)
        #expect(first?.message.contains("nothing on the screen has been entered") == true)
        #expect(first?.withScreen == true)
        #expect(FinishCheck.verdict(.done, reply: "", request: "Solve this to puzzle.", run: &run) != nil)
        // Twice is the limit: a job that truly can't be done still ends.
        #expect(FinishCheck.verdict(.done, reply: "", request: "Solve this to puzzle.", run: &run) == nil)
    }

    /// 19:58 "Enter the missing numbers": "I'll enter the missing numbers next", with nothing entered.
    @Test func aPromiseToDoItNextIsSentBack() {
        var run = screenJob(changed: false)
        #expect(FinishCheck.verdict(.reply, reply: "Solving the puzzle now; I'll enter the missing numbers next.",
                                    request: "Enter the missing numbers.", run: &run) != nil)
    }

    /// 19:58 "Do it": one number entered, then "I haven't filled it in yet… Should I turn off Notes mode…?"
    @Test func admittingItsUnfinishedIsSentBackEvenWithSomethingEntered() {
        var run = screenJob(changed: true)
        let reply = "I solved the Sudoku, but I haven't filled it in on the board yet. The page has Notes mode on. "
            + "Should I turn off Notes mode and enter the numbers?"
        let back = FinishCheck.verdict(.reply, reply: reply, request: "Do it.", run: &run)
        #expect(back?.message.contains("isn't done yet") == true)
    }

    /// 19:59 "Yes, do it": Notes off, one 5 entered, then a cheerful text answer. The screen is checked once.
    @Test func aQuietPartialFinishGetsOneLookAtTheScreen() {
        var run = screenJob(changed: true)
        let reply = "Entered 5 in row 1, column 3."
        let back = FinishCheck.verdict(.text, reply: reply, request: "Do it.", run: &run)
        #expect(back?.message.contains("check the screen below against the request") == true)
        #expect(back?.withScreen == true)
        // It looked and says it's done: that's its call.
        #expect(FinishCheck.verdict(.text, reply: reply, request: "Do it.", run: &run) == nil)
    }

    /// 20:00 "I want you to fill the complete board": "I can't reliably click the individual cells", nothing entered.
    @Test func givingUpWithoutTryingIsSentBack() {
        var run = screenJob(changed: false)
        let reply = "I couldn't fill the board yet. I read the puzzle, but I can't reliably click the individual cells."
        #expect(FinishCheck.verdict(.reply, reply: reply, request: "I want you to fill the complete board.", run: &run) != nil)
    }

    /// 21:51 "So all this" (said "Solve this"): the model asked what was meant, and the question was held back to
    /// read the rest of the page, then the command ended with nothing shown. A question for the user is a question.
    @Test func aClarifyingQuestionIsRecognised() {
        #expect(FinishCheck.isQuestion("I'm not sure what you mean by \"So all this.\" Could you say it again? For "
            + "example, do you want me to solve the Sudoku, or tell you something about it?"))
        #expect(FinishCheck.isQuestion("Which file do you mean?"))
        #expect(!FinishCheck.isQuestion("The board is filled in. Is anything else needed? Probably not."))
        #expect(!FinishCheck.isQuestion("Done."))
    }

    @Test func aRealQuestionGoesToTheUser() {
        var run = screenJob(changed: false)
        #expect(FinishCheck.verdict(.reply, reply: "Which of the two forms do you mean, the visa one or the bank one?",
                                    request: "Fill in this form", run: &run) == nil)
    }

    @Test func permissionIsAskedForOnlyOnce() {
        var run = screenJob(changed: true)
        run.screenChecks = 1
        let ask = "Everything's filled except the signature. Shall I type your name there?"
        #expect(FinishCheck.verdict(.reply, reply: ask, request: "Fill in this form", run: &run) != nil)
        #expect(FinishCheck.verdict(.reply, reply: ask, request: "Fill in this form", run: &run) == nil)
    }

    @Test func questionsAndOtherJobsAreLeftAlone() {
        var run = FinishCheck.Run(wantsScreenWork: false, changedTheScreen: false)
        #expect(FinishCheck.verdict(.done, reply: "", request: "What's on my screen?", run: &run) == nil)
        #expect(FinishCheck.verdict(.reply, reply: "I haven't found it yet.", request: "Open Slack", run: &run) == nil)
    }

    @Test func aCommandThatMayHaveDoneItCanFinish() {
        var run = screenJob(changed: false)
        run.ranCommands = true
        let back = FinishCheck.verdict(.done, reply: "", request: "Move this file to the Desktop", run: &run)
        #expect(back?.message.contains("If a command you ran already did it") == true)
    }

    // MARK: Commands that change things, and ones that only work something out

    @Test func workingSomethingOutIsntChangingAnything() {
        // The run's own commands: a solver in a heredoc, a scratch file in /tmp, a look around.
        let solver = """
            python3 - <<'EOF'
            g=["390800600","478090231"]
            import os
            os.remove("nothing")  # inside the script: not a shell command
            print(g)
            EOF
            """
        #expect(!FinishCheck.commandChangesThings(solver))
        #expect(!FinishCheck.commandChangesThings("cat > /tmp/sudoku.py << 'EOF'\ng = [[3,9,0]]\nEOF\npython3 /tmp/sudoku.py"))
        #expect(!FinishCheck.commandChangesThings("ls ~ 2>/dev/null | head -50"))
        #expect(!FinishCheck.commandChangesThings("python3 /tmp/s.py 2>&1"))
        #expect(!FinishCheck.commandChangesThings("df -h"))
    }

    @Test func movingWritingOrOpeningIsChanging() {
        #expect(FinishCheck.commandChangesThings("mv ~/Downloads/a.pdf ~/Desktop/"))
        #expect(FinishCheck.commandChangesThings("echo hello > ~/notes.txt"))
        #expect(FinishCheck.commandChangesThings("sips -s format png in.heic --out out.png"))
        #expect(FinishCheck.commandChangesThings("open -a Safari https://example.com"))
        #expect(FinishCheck.commandChangesThings("cd ~/project && git commit -am 'fix'"))
        #expect(FinishCheck.commandChangesThings("defaults write com.apple.dock autohide -bool true"))
    }

    // MARK: Keys

    @Test func keySequences() {
        #expect(FinishCheck.keySequence("5 tab 7 tab 2") == ["5", "tab", "7", "tab", "2"])
        #expect(FinishCheck.keySequence("cmd + l") == ["cmd+l"])
        #expect(FinishCheck.keySequence("cmd+shift+n") == ["cmd+shift+n"])
        #expect(FinishCheck.keySequence("cmd+,") == ["cmd+,"])
        #expect(FinishCheck.keySequence("cmd+a, delete") == ["cmd+a", "delete"])
        #expect(FinishCheck.keySequence(",") == [","])
        #expect(FinishCheck.keySequence("  return ") == ["return"])
    }

    /// 19:56: the local model pressed cmd+shift+space, Murmur's own shortcut.
    @Test func murmursOwnShortcut() {
        let own = ["cmd+shift+space"]
        #expect(FinishCheck.isOwnShortcut("cmd+shift+space", shortcuts: own))
        #expect(FinishCheck.isOwnShortcut("shift+command+space", shortcuts: own))
        #expect(FinishCheck.isOwnShortcut("⌘+⇧+space", shortcuts: own))
        #expect(!FinishCheck.isOwnShortcut("cmd+space", shortcuts: own))
        #expect(!FinishCheck.isOwnShortcut("space", shortcuts: own))
    }

    // MARK: More steps while it's getting somewhere

    @Test func stepsGrowWhileEveryStepDoesSomething() {
        var progress = StepProgress()
        progress.record(changed: true, failed: false)
        progress.record(changed: true, failed: false)
        #expect(progress.moreSteps(by: 12, limit: 66) == nil)   // only two steps so far
        progress.record(changed: true, failed: false)
        #expect(progress.moreSteps(by: 12, limit: 66) == 12)
        #expect(progress.extended == 12)
    }

    @Test func noMoreStepsForAJobGoingNowhere() {
        var progress = StepProgress()
        for _ in 0..<3 { progress.record(changed: true, failed: false) }
        progress.record(changed: false, failed: false)
        #expect(progress.moreSteps(by: 12, limit: 66) == nil)
        var failing = StepProgress()
        for _ in 0..<3 { failing.record(changed: true, failed: true) }
        #expect(failing.moreSteps(by: 12, limit: 66) == nil)
        var capped = StepProgress()
        for _ in 0..<3 { capped.record(changed: true, failed: false) }
        #expect(capped.moreSteps(by: 12, limit: 10) == nil)
    }

    /// 22:00: twenty steps of screenshots and screen reads, asking the same question, never acting.
    @Test func onlyLookingIsCounted() {
        var progress = StepProgress()
        for _ in 0..<StepProgress.lookingNudgeAt { progress.record(changed: false, failed: false, onlyLooked: true) }
        #expect(progress.lookingStreak == StepProgress.lookingNudgeAt)
        // Acting (or scrolling) between looks starts the count again.
        progress.record(changed: true, failed: false)
        #expect(progress.lookingStreak == 0)
        for _ in 0..<StepProgress.lookingStopAt { progress.record(changed: false, failed: false, onlyLooked: true) }
        #expect(progress.lookingStreak >= StepProgress.lookingStopAt)
        #expect(StepProgress.lookingNudgeAt < StepProgress.lookingStopAt)
    }

    /// 22:44: digits pasted into Sudoku cells went nowhere (the grid listens for keys); typed as keys instead.
    @Test func shortPlainTextBecomesKeys() {
        #expect(FinishCheck.keysForTyping("4") == ["4"])
        #expect(FinishCheck.keysForTyping("Go 2") == ["shift+g", "o", "space", "2"])
        #expect(FinishCheck.keysForTyping("a.b-c") == ["a", ".", "b", "-", "c"])
        // Pasted as before: a newline, an accent, an emoji, or long text.
        #expect(FinishCheck.keysForTyping("line one\nline two") == nil)
        #expect(FinishCheck.keysForTyping("café") == nil)
        #expect(FinishCheck.keysForTyping("👍") == nil)
        #expect(FinishCheck.keysForTyping(String(repeating: "a", count: 41)) == nil)
        #expect(FinishCheck.keysForTyping("") == nil)
    }

    /// 22:45: "…Want me to go ahead?" was held back once as asking permission; then done ended the run with nothing shown.
    @Test func wantMeToGoAheadIsAskingPermission() {
        #expect(FinishCheck.asksPermissionToGoOn("I can re-read the givens and enter the digits. Want me to go ahead?"))
        #expect(!FinishCheck.asksPermissionToGoOn("Which puzzle do you want me to solve, the easy or the fiendish one?"))
    }

    // MARK: Follow-ups in the same window

    @Test func theNextCommandHereSeesWhatWasWorkedOut() {
        RecentWork.clear()
        let window = "Google Chrome — Sudoku Arena - Google Chrome – Shubham"
        RecentWork.record(.init(request: "Solve this to puzzle.", window: window, at: Date().addingTimeInterval(-90),
                                answer: nil, workedOut: ["Exit status 0. Output: True 395812674 487596231"], acted: false))
        RecentWork.record(.init(request: "Write a reply", window: "Mail — Inbox", answer: nil, workedOut: [], acted: true))
        let here = RecentWork.recent(in: window)
        #expect(here.count == 1)
        let context = RecentWork.context(here) ?? ""
        #expect(context.contains("Solve this to puzzle."))
        #expect(context.contains("395812674"))
        #expect(context.contains("nothing on screen was changed"))
        #expect(!context.contains("Write a reply"))
    }

    @Test func oldWorkIsForgotten() {
        RecentWork.clear()
        RecentWork.record(.init(request: "Fill the form", window: "Safari — Form", at: Date().addingTimeInterval(-3600),
                                answer: nil, workedOut: [], acted: true))
        #expect(RecentWork.recent(in: "Safari — Form").isEmpty)
        #expect(RecentWork.context([]) == nil)
    }

    // MARK: Reading a page's controls

    @Test func namedControlsKeepTheirNameAndState() {
        #expect(PageLines.control(role: "AXCell", name: "Row 1, column 3, empty", inner: "", state: nil)
                == "Row 1, column 3, empty (cell)")
        #expect(PageLines.control(role: "AXCell", name: "Row 2, column 1", inner: "4", state: nil)
                == "Row 2, column 1: 4 (cell)")
        #expect(PageLines.control(role: "AXCell", name: "Row 1, column 1, 3", inner: "3", state: nil)
                == "Row 1, column 1, 3 (cell)")
        #expect(PageLines.control(role: "AXCheckBox", name: "Notes", inner: "ON", state: "on")
                == "Notes: ON (checkbox, on)")
        #expect(PageLines.control(role: "AXSwitch", name: "Notes", inner: "", state: "off") == "Notes (switch, off)")
        #expect(PageLines.control(role: "AXTextField", name: "Email", inner: "", state: "") == "Email (text field, empty)")
        #expect(PageLines.control(role: "AXTextField", name: "Email", inner: "", state: "a@b.com")
                == "Email (text field: \"a@b.com\")")
    }

    @Test func unnamedOrWordyThingsReadAsBefore() {
        #expect(PageLines.control(role: "AXCell", name: nil, inner: "3", state: nil) == nil)
        #expect(PageLines.control(role: "AXStaticText", name: "Hello", inner: "", state: nil) == nil)
        let card = String(repeating: "A long description of a product card. ", count: 4)
        #expect(PageLines.control(role: "AXButton", name: "Product", inner: card, state: nil) == nil)
        #expect(PageLines.toggleState(1) == "on" && PageLines.toggleState(0) == "off" && PageLines.toggleState(nil) == nil)
    }
}
