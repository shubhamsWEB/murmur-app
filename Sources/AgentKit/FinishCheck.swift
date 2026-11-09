import Foundation

/// Whether a command that is about to end has really done what was asked. The model decides when it's finished, and
/// on 9 Nov it decided too early, five ways in a row, on "solve this puzzle" in Chrome: it worked out the answer and
/// called done without entering any of it; it said "I'll enter the numbers next" and stopped; it entered one number
/// and asked whether to go on; it said it "couldn't reliably" do what it had done a minute before. Each check here is
/// about what actually happened in the run (did anything on the screen change?) and what the reply admits ("I haven't
/// filled it in yet"), never about a particular app or puzzle.
public enum FinishCheck {
    /// How the model tried to finish.
    public enum Ending: Sendable { case done, reply, text }

    /// What the run did so far, as far as finishing goes.
    public struct Run: Sendable {
        /// The user wants something done on the screen (filled in, typed, clicked, changed), not to be told something.
        public var wantsScreenWork: Bool
        /// Something on the screen was entered, clicked, typed or changed by this run, and it worked.
        public var changedTheScreen: Bool
        /// Times this run was sent back for finishing without changing the screen.
        public var nothingDoneChecks = 0
        /// Times it was sent back for an answer that says the job isn't finished.
        public var unfinishedChecks = 0
        /// Times it was sent back for asking permission to do what it was asked to do.
        public var permissionChecks = 0
        /// Times it was shown the screen to compare with the request before finishing.
        public var screenChecks = 0
        /// A terminal command ran that may have done the job another way (moved a file, ran a script that writes).
        public var ranCommands = false

        public init(wantsScreenWork: Bool, changedTheScreen: Bool) {
            self.wantsScreenWork = wantsScreenWork
            self.changedTheScreen = changedTheScreen
        }
    }

    /// "fill in the form", "enter the missing numbers", "solve this", "tick all the boxes", "do it", "complete the
    /// board", "type my address here", "bhar do": a request to change something in front of the user. Questions and
    /// requests to be told something aren't (`asksForInformation` covers those and wins).
    public static func asksToChangeScreen(_ utterance: String) -> Bool {
        let text = normalised(utterance)
        return text.range(of: #"\b(fill( in| out| up)?|enter|type|write (in|into|it|them|this|that|here)|input|put (in|it|them)|solve|complete|finish|play (it|this|the|a move)|select|tick|uncheck|check (the|this|that|these|all|every) (box|boxes|option|options|item|items)|set (it|this|that|the)|change|edit|update|correct|mark|insert|paste|replace|toggle|turn (it |this |that )?(on|off)|click|press|tap|submit|apply|drag|move (it|this|that|the)|do (it|this|that|the rest|all|everything|the whole)|carry it out|go ahead|bhar(o| do| dijiye)|likh(o| do)|daal(o| do)|bharna|kar do|karo)\b"#,
                          options: .regularExpression) != nil
    }

    /// A reply that says the job isn't finished: "I solved it, but I haven't filled it in yet", "so far I've entered
    /// one number", "I'll enter the rest next", "the remaining cells are…".
    public static func soundsUnfinished(_ reply: String) -> Bool {
        let text = normalised(reply)
        return text.range(of: #"\b(haven'?t (yet )?(filled|entered|typed|done|finished|completed|clicked|changed|put|added|made|set)|have not (yet )?(filled|entered|typed|done|finished|completed)|not (yet )?(filled|entered|typed|done|finished|completed) (in|it|them|yet)|(isn'?t|is not|not) (finished|complete|done) yet|only (filled|entered|typed|done|did|managed|got|completed) (one|1|a few|some|part)|so far,? (i'?ve|i have) (only )?(filled|entered|typed|done)|i'?ll (now |next |then )?(enter|fill|type|do|finish|complete|continue|start|put)|next,? i'?ll|still (need|have) to|(the )?(remaining|rest of the) (cells|fields|items|numbers|steps|boxes|entries|rows)|before i (enter|fill|continue|go on))\b"#,
                          options: .regularExpression) != nil
    }

    /// A reply that stops to ask for permission to do what was asked: "Shall I fill in the rest?", "Should I turn off
    /// Notes mode and enter the numbers?", "Do you want me to continue?". Not a real question about which one ("Which
    /// resume do you mean?"), which the user has to answer.
    public static func asksPermissionToGoOn(_ reply: String) -> Bool {
        let text = normalised(reply)
        guard text.contains("?") else { return false }
        return text.range(of: #"\b(shall i|should i|do you want me to|would you like me to|want me to|can i go ahead|may i go ahead|is it ok(ay)? (if|to)|ok(ay)? to (go ahead|continue|proceed)|go ahead\?|proceed\?|continue\?)\b"#,
                          options: .regularExpression) != nil
            // A question with a real choice for the user ("which puzzle…?", "the easy one or the fiendish one?").
            && text.range(of: #"\b(which|what|who|where|when)\b|\bor\b[^.!]*\?"#, options: .regularExpression) == nil
    }

    /// Why the model can't finish yet, if it can't: the message it's sent back with, and whether the screen as it
    /// is now goes with it. Nil: let it finish. `reply` is the text it was going to show (empty for done). Each check
    /// is made at most twice (permission and the screen once), so a job that truly can't be done still ends, with
    /// the model saying why.
    public static func verdict(_ ending: Ending, reply: String, request: String,
                               run: inout Run) -> (message: String, withScreen: Bool)? {
        guard run.wantsScreenWork else { return nil }
        // A real question for the user ("Which file do you mean?", "Notes or answers?") goes to them: only they can
        // answer it, and what they say next carries the task on. Asking leave to do the job isn't one.
        if ending != .done, isQuestion(reply), !asksPermissionToGoOn(reply) { return nil }
        let asked = "The user asked: \"\(request.prefix(300))\"."
        if !run.changedTheScreen, run.nothingDoneChecks < 2 {
            run.nothingDoneChecks += 1
            let otherWay = run.ranCommands
                ? " If a command you ran already did it (a file moved, a setting written), call done." : ""
            return ("Not finished: nothing on the screen has been entered or changed yet. \(asked) Working the answer "
                + "out isn't doing it: put it on the screen now. Click the field, cell or control by its [n] (read_screen "
                + "lists them, with their names) and press_keys or type_text; enter many in one step, and press_keys "
                + "takes a sequence (\"5 tab 7 tab 2\"). If something gets in the way (a mode, a dialog, a setting), "
                + "deal with it and go on. Only if it truly can't be done here, reply saying exactly what stops you."
                + otherWay, true)
        }
        if ending != .done, soundsUnfinished(reply), run.unfinishedChecks < 2 {
            run.unfinishedChecks += 1
            return ("Not finished: your reply says the job isn't done yet (\"\(reply.prefix(160))\"). \(asked) Keep "
                + "going until all of it is done; you have more steps. Do the rest now, many in each step. Reply only "
                + "when it's all done, or with exactly what stops you.", true)
        }
        if ending != .done, asksPermissionToGoOn(reply), run.permissionChecks < 1 {
            run.permissionChecks += 1
            return ("Don't ask: the user already asked you to do this. \(asked) Go ahead and finish it. (Murmur asks the "
                + "user itself before anything that sends, deletes or pays.) Ask only when you truly need them to "
                + "choose between things, and say what the choices are.", true)
        }
        // Something changed, but maybe one item of forty: before the last word, the request against the screen.
        if run.changedTheScreen, run.screenChecks < 1 {
            run.screenChecks += 1
            return ("Before finishing, check the screen below against the request. \(asked) Is every part of it done "
                + "on the screen, not just started (every field, cell, item or step it covers)? If so, finish again "
                + "the same way. If anything is left, do it now, many in each step.", true)
        }
        return nil
    }

    /// A terminal command that changes the user's things (moves, copies, deletes, writes, opens, converts, changes a
    /// setting), as opposed to one that only looks or works something out (a calculation, a script printing an
    /// answer, a scratch file in /tmp). What's inside a heredoc is the script, not commands.
    public static func commandChangesThings(_ command: String) -> Bool {
        var lines: [Substring] = []
        var heredocEnd: String?
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            if let end = heredocEnd {
                if line.trimmingCharacters(in: .whitespaces) == end { heredocEnd = nil }
                continue
            }
            lines.append(line)
            if let match = line.range(of: #"<<-?\s*['"]?([A-Za-z_]+)['"]?"#, options: .regularExpression) {
                heredocEnd = String(line[match]).replacingOccurrences(of: #"<<-?\s*['"]?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"['"]"#, with: "", options: .regularExpression)
            }
        }
        let shell = lines.joined(separator: "\n")
        let changing = #"(^|[;&|(`]\s*|\s)(mv|cp|rm|mkdir|rmdir|touch|ln|chmod|chown|zip|unzip|tar|ditto|rsync|sips|osascript|open|shortcuts|killall|kill|defaults\s+write|git\s+(commit|push|checkout|reset|mv|rm|add|merge|rebase)|brew|npm|pip3?|launchctl|pmset|networksetup|scutil|curl\s+[^|;]*\s-[oO]|wget)\b"#
        if shell.range(of: changing, options: .regularExpression) != nil { return true }
        // Writing to a file that isn't scratch: "> ~/notes.txt", ">> report.md" (not 2>&1, /dev/null or /tmp).
        let writes = #"(?<![0-9&])>>?\s*(?!&|\s*/dev/null|\s*/tmp/|\s*/private/tmp/|\s*\$TMPDIR)\S"#
        return shell.range(of: writes, options: .regularExpression) != nil
    }

    /// Short plain text as key presses ("4" → ["4"], "Go 2" → ["shift+g", "o", "space", "2"]), for a place that
    /// listens for keys rather than taking pasted text. Nil when it's long, or has a character with no plain key
    /// (a newline, an accent, an emoji): that's pasted.
    public static func keysForTyping(_ text: String) -> [String]? {
        guard !text.isEmpty, text.count <= 40 else { return nil }
        var keys: [String] = []
        for character in text {
            switch character {
            case "a"..."z", "0"..."9", ",", ".", "/", "-", "=": keys.append(String(character))
            case "A"..."Z": keys.append("shift+" + character.lowercased())
            case " ": keys.append("space")
            default: return nil
            }
        }
        return keys
    }

    /// "5 tab 7 tab 2", "down down return", "cmd+a, delete": the keys to press, in order, split at spaces. One
    /// combination ("cmd+shift+n", "cmd + l", "cmd+,") is one key press, as before; a lone "," is the comma key.
    public static func keySequence(_ keys: String) -> [String] {
        let joined = keys.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\+\s*"#, with: "+", options: .regularExpression)
        return joined.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map { token -> String in
            var key = String(token)
            // "cmd+a," in "cmd+a, delete": the comma separates; "cmd+," and "," are the comma key.
            if key.count > 1, key.hasSuffix(","), !key.hasSuffix("+,") { key.removeLast() }
            return key
        }.filter { !$0.isEmpty }
    }

    /// Whether a key combination is one of Murmur's own shortcuts: pressing it from a command would start Murmur
    /// again (or stop it) rather than do anything in the user's app. The same keys in any order and spelling.
    public static func isOwnShortcut(_ combo: String, shortcuts: [String]) -> Bool {
        let pressed = keySet(combo)
        guard pressed.count > 1 else { return false }
        return shortcuts.contains { keySet($0) == pressed }
    }

    private static func keySet(_ combo: String) -> Set<String> {
        let aliases = ["command": "cmd", "⌘": "cmd", "control": "ctrl", "⌃": "ctrl", "option": "opt", "alt": "opt",
                       "⌥": "opt", "⇧": "shift"]
        return Set(combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+")
            .map { aliases[String($0)] ?? String($0) })
    }

    /// A reply that asks the user something: it ends with a question, or opens with one.
    static func isQuestion(_ reply: String) -> Bool {
        let lines = reply.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.last?.hasSuffix("?") == true { return true }
        guard let first = lines.first, let mark = first.firstIndex(of: "?") else { return false }
        return !first[..<mark].contains(".")
    }

    /// Lowercased, curly apostrophes made straight.
    static func normalised(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
    }
}

/// Whether a run is getting somewhere, step by step, so it may have more steps than a plain command: a long job
/// (forty fields, a whole board, a list of thirty items) shouldn't stop at the step limit while every step is still
/// doing work.
public struct StepProgress: Sendable {
    /// Per step: did it change the screen with something that worked, and did anything fail?
    public private(set) var steps: [(changed: Bool, failed: Bool)] = []
    /// Steps added on top of the plain budget so far.
    public private(set) var extended = 0
    /// Steps in a row that only looked (screenshots, reading the screen or page) and did nothing. On 9 Nov a small
    /// model asked the same screenshot the same question twenty times, never acting, until the time ran out.
    public private(set) var lookingStreak = 0

    public init() {}

    public mutating func record(changed: Bool, failed: Bool, onlyLooked: Bool = false) {
        steps.append((changed, failed))
        lookingStreak = onlyLooked ? lookingStreak + 1 : 0
    }

    /// After this many steps of only looking, the model is told to act on what it has read.
    public static let lookingNudgeAt = 4
    /// After this many, the run stops and says what it found, rather than looking until the time runs out.
    public static let lookingStopAt = 8

    /// What the model is told after `lookingNudgeAt` steps of only looking.
    public static let lookingNudge = "You've looked at the screen several times in a row without doing anything. "
        + "What you need is in what you've already read: the page's cells, fields and buttons, with their names and "
        + "[n]. Stop looking and act now: click by [n], press_keys (a sequence for many entries), type_text; if "
        + "something must be worked out first, run_command can compute it. If it truly can't be done, reply saying "
        + "exactly what stops you."

    /// More steps, when the last few each changed the screen and none failed. `by` at a time, up to `limit` in all.
    public mutating func moreSteps(by: Int, limit: Int) -> Int? {
        let recent = steps.suffix(3)
        guard recent.count == 3, recent.allSatisfy({ $0.changed && !$0.failed }), extended + by <= limit else { return nil }
        extended += by
        return by
    }
}
