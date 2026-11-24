import Foundation

/// "Write it for me": a tap of the talk key in a text box, and Murmur writes what goes there. It reads the window
/// around the box (the conversation above it, nearest first; a little of what's below), what's already in the box,
/// and what Murmur knows about the user and the people in the thread, and writes, as the user:
///
/// - an empty box: the natural next thing they'd write there (the reply to the newest message, a comment on the post
///   above it, the next line of a document);
/// - a box with an instruction in it ("say yes but not before 3", "polite no"): that, written out, in its place;
/// - a draft: the draft finished and fixed, their words kept;
/// - selected text: that text rewritten as the box asks, or improved.
///
/// Facts only from the screen, the box and memory: no times, numbers or names made up (a gap is left in brackets).
/// Nothing is ever sent: it's in the box, and ⌘Z takes it back.
public enum ReplyWriter {
    /// One piece of text in the window, and where it is (screen coordinates, y down).
    public struct Piece: Equatable, Sendable {
        public var text: String
        public var frame: CGRect
        public init(text: String, frame: CGRect) {
            self.text = text
            self.frame = frame
        }
    }

    /// The box and what's around it.
    public struct Context: Sendable {
        public var app: String
        public var title: String
        /// Oldest first; the last line is the one right above the box.
        public var above: [String]
        /// Nearest first.
        public var below: [String]
        /// What's in the box now.
        public var draft: String
        /// What's selected in it, if anything.
        public var selection: String?
        /// Whose each line of `above` is, when the window shows it (`sides`); empty, or nil for a line, when it
        /// doesn't.
        public var sides: [Side?]

        public init(app: String, title: String, above: [String], below: [String], draft: String, selection: String?,
                    sides: [Side?] = []) {
            self.app = app
            self.title = title
            self.above = above
            self.below = below
            self.draft = draft
            self.selection = selection
            self.sides = sides.count == above.count ? sides : []
        }

        /// The newest lines, for finding what memory knows about them.
        public var recent: String { above.suffix(8).joined(separator: "\n") }
    }

    // MARK: Arranging what was read

    /// What's above the box (oldest first, at most `aboveLimit` characters, the nearest kept) and below it (nearest
    /// first, at most `belowLimit`), each piece once, in reading order. Text beside the box (a send button, the
    /// sender's name on its row) goes with what's above.
    public static func arrange(_ pieces: [Piece], field: CGRect, aboveLimit: Int = 6000,
                               belowLimit: Int = 1200) -> (above: [String], below: [String]) {
        var seen = Set<String>()
        let ordered = pieces.sorted { a, b in
            abs(a.frame.minY - b.frame.minY) < 4 ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
        }
        var above: [String] = [], below: [String] = []
        for piece in ordered where seen.insert(piece.text).inserted {
            if piece.frame.minY >= field.maxY - 2 { below.append(piece.text) } else { above.append(piece.text) }
        }
        var kept: [String] = [], length = 0
        for line in above.reversed() {
            guard length + line.count <= aboveLimit else { break }
            kept.insert(line, at: 0)
            length += line.count
        }
        var after: [String] = []
        length = 0
        for line in below {
            guard length + line.count <= belowLimit else { break }
            after.append(line)
            length += line.count
        }
        return (kept, after)
    }

    // MARK: What Murmur knows

    /// What goes with the box and the window: who the user is, who they're writing to, what memory holds about
    /// that person and this conversation, and how the user really writes in this app.
    public struct Knowledge: Sendable {
        /// Who the user is and how they write (the profile memory keeps).
        public var profile: String?
        /// What's current for them (the daily digest).
        public var digest: String?
        /// Who they're writing to, when the window says.
        public var partner: String?
        /// What memory knows about that person.
        public var dossier: String?
        /// What memory found for this conversation.
        public var memory: String?
        /// Messages the user really sent in this app before (`WriteMemory`).
        public var sent: [String]
        /// What the user changed in what Murmur wrote here lately: its text, then theirs.
        public var corrections: [(wrote: String, sent: String)]

        public init(profile: String? = nil, digest: String? = nil, partner: String? = nil, dossier: String? = nil,
                    memory: String? = nil, sent: [String] = [], corrections: [(wrote: String, sent: String)] = []) {
            self.profile = profile
            self.digest = digest
            self.partner = partner
            self.dossier = dossier
            self.memory = memory
            self.sent = sent
            self.corrections = corrections
        }
    }

    /// Who the user is writing to: someone memory knows who is named in the window's title or at the top of the
    /// conversation (`known`: those names, as memory spells them), else a line at the top that reads like a
    /// person's name ("Priya Shah"). nil when the window doesn't say.
    public static func partner(_ context: Context, known: [String], me: [String]) -> String? {
        let mine = Set(me.map { $0.lowercased() })
        // A window that says who each message is from or to has said it.
        if let named = context.above.reversed().lazy.compactMap({ named(in: $0) }).first { return named }
        if let person = known.first(where: { !mine.contains($0.lowercased()) }) { return person }
        let app = context.app.lowercased()
        for line in [context.title] + context.above.prefix(4) {
            let words = line.split(separator: " ")
            guard (1...4).contains(words.count), line.count <= 40, line.lowercased() != app,
                  !mine.contains(line.lowercased()), !saysDate(line),
                  words.allSatisfy({ $0.first?.isUppercase == true && $0.allSatisfy { $0.isLetter || $0 == "." || $0 == "'" || $0 == "-" } })
            else { continue }
            return line
        }
        return nil
    }

    private static func saysDate(_ line: String) -> Bool {
        line.lowercased().split { !$0.isLetter }.contains { dateWords.contains(String($0)) }
    }

    /// The lines of what memory found for `partner` that are about them: ones with their name in (its first word,
    /// three letters or more). Memory searched by a name returns whatever is nearest, and with little on that
    /// person it's mostly about other people: that would be worse than nothing.
    public static func about(_ partner: String, in found: String?) -> String? {
        guard let found, let first = partner.lowercased().split(whereSeparator: { !$0.isLetter }).first, first.count >= 3
        else { return nil }
        let kept = found.split(separator: "\n").filter { $0.lowercased().contains(first) }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }

    /// The user's own messages in this conversation (the lines marked theirs), newest last: how they write here.
    public static func ownLines(_ context: Context, count: Int = 6) -> [String] {
        guard !context.sides.isEmpty else { return [] }
        return Array(zip(context.above, context.sides).filter { $0.1 == .me }.map { spoken($0.0) }.filter { $0.count >= 8 }
            .suffix(count))
    }

    // MARK: Checking what was written

    /// Times, dates, amounts, links and addresses in `reply` that are nowhere in what the model was given (the
    /// window, the box, what memory supplied): made up, however plausible. Small counts ("2 things") don't count.
    public static func unsupported(in reply: String, given: String) -> [String] {
        let source = given.lowercased()
        var found: [String] = []
        let patterns = [#"https?://\S+"#, #"\b[\w.+-]+@[\w-]+\.[\w.]+\b"#, #"\b\d{1,2}[:.]\d{2}\s?(?:am|pm)?\b"#,
                        #"\b\d{1,2}\s?(?:am|pm)\b"#, #"[₹$€£]\s?\d[\d,.]*"#, #"\b\d[\d,.]*\s?(?:%|k|m|lakh|crore|rs|inr|usd)\b"#,
                        #"\b\d{3,}\b"#, #"\b\d{1,2}(?:st|nd|rd|th)\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let text = reply as NSString
            for match in regex.matches(in: reply, range: NSRange(location: 0, length: text.length)) {
                let piece = text.substring(with: match.range).trimmingCharacters(in: .whitespaces)
                let bare = piece.lowercased().replacingOccurrences(of: " ", with: "")
                if !source.replacingOccurrences(of: " ", with: "").contains(bare), !found.contains(where: { $0.contains(piece) }) {
                    found.append(piece)
                }
            }
        }
        return found
    }

    /// What to ask when the first answer had made-up specifics in it.
    public static func recheck(_ reply: String, unsupported: [String]) -> String {
        "You wrote:\n\(reply)\n\nThese are not in anything you were given: \(unsupported.joined(separator: ", ")). "
            + "Write it again without them: say it without the detail, or leave a short gap in square brackets like "
            + "[time] where one is needed. Keep everything else. Answer with the text only."
    }

    // MARK: Whose message is whose

    /// Who wrote a line of a conversation.
    public enum Side: String, Sendable { case me = "ME", them = "THEM" }

    /// Whose each of `lines` is, going by where it sits: chat apps put your own messages on the right and other
    /// people's on the left (WhatsApp, Messages, Telegram, Teams and Slack chats, most web chats). Without this the
    /// model sees only a list of sentences, and can answer the user's own message as if someone else had sent it.
    ///
    /// Only the conversation's own column counts (the pieces over the box, not a list of chats beside it), and
    /// only lines of two words or more (a time or a tick on the right isn't a message). Nothing is marked unless
    /// the window really is two-sided: at least one message each side. A line in the middle, or as wide as the
    /// column, is left unmarked.
    public static func sides(of lines: [String], pieces: [Piece], field: CGRect) -> [Side?] {
        let none = lines.map { saidBy($0) }
        let column = pieces.filter { $0.frame.maxY <= field.minY + 2 && $0.frame.midX >= field.minX - 80
            && $0.frame.midX <= field.maxX + 80 }
        guard let left = column.map(\.frame.minX).min(), let right = column.map(\.frame.maxX).max(),
              right - left >= 200 else { return none }
        let width = right - left
        // What sits on each side, of the pieces that read like a message.
        var placed: [(piece: Piece, side: Side)] = []
        for piece in column where saysSomething(piece.text) {
            let before = piece.frame.minX - left, after = right - piece.frame.maxX
            if before < width * 0.12, after - before > width * 0.1 { placed.append((piece, .them)) }
            if after < width * 0.12, before - after > width * 0.1 { placed.append((piece, .me)) }
        }
        // A bubble has its row to itself. Something on the right of a row that also has text on the left (a date
        // beside a sender's name in an email, a button beside a heading) isn't the user's message.
        let lefts = placed.filter { $0.side == .them }.map(\.piece.frame)
        placed.removeAll { entry in
            entry.side == .me && lefts.contains { $0.minY < entry.piece.frame.maxY - 2 && $0.maxY > entry.piece.frame.minY + 2 }
        }
        var side: [String: Side] = [:], unsure = Set<String>()
        for (piece, found) in placed {
            // The same words on both sides ("ok thanks" from each of you): not told apart by text alone.
            if let known = side[piece.text], known != found { unsure.insert(piece.text) }
            side[piece.text] = found
        }
        for text in unsure { side[text] = nil }
        // A line that says whose it is counts before where it sits, and needs no second side to be believed.
        let said = lines.map { saidBy($0) }
        let bySide = side.values.contains(.me) && side.values.contains(.them)
        guard bySide || said.contains(where: { $0 != nil }) else { return none }
        return zip(lines, said).map { line, own in own ?? (bySide ? side[line] : nil) }
    }

    /// Whose a line is when it says so itself. Apps that describe their messages for VoiceOver do: WhatsApp's read
    /// "message, Try karta hu, 6:26 PM, Received from Rahul" and "Your message, …, Sent to Rahul".
    public static func saidBy(_ line: String) -> Side? {
        let text = line.lowercased().filter { $0 != "\u{200E}" && $0 != "\u{200F}" }
        if text.contains("received from ") { return .them }
        if text.hasPrefix("your message") || text.hasPrefix("your ") && text.contains(" sent to ") || text.contains(", sent to ")
            || text.contains("sent by you") { return .me }
        return nil
    }

    /// Who a described message is from or to ("Received from Rahul(Shaadi.Com)" → that name), for knowing who the
    /// user is writing to.
    public static func named(in line: String) -> String? {
        let text = line.filter { $0 != "\u{200E}" && $0 != "\u{200F}" }
        for marker in ["Received from ", "Sent to "] {
            guard let range = text.range(of: marker, options: .caseInsensitive) else { continue }
            let name = text[range.upperBound...].prefix { $0 != "," && $0 != "\n" }.trimmingCharacters(in: .whitespaces)
            if name.count > 1, name.count <= 40 { return name }
        }
        return nil
    }

    /// The words of a described message without the description round them: "message, Try karta hu, 6:26 PM,
    /// Received from Rahul" → "Try karta hu". Anything not in that shape comes back as it is.
    public static func spoken(_ line: String) -> String {
        let text = line.filter { $0 != "\u{200E}" && $0 != "\u{200F}" }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard saidBy(text) != nil,
              let regex = try? NSRegularExpression(pattern: #"^(?:your )?[\w ]*message, (.*?), \d{1,2}[:.]\d{2}(?:\s?[ap]m)?,"#,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return text }
        return String(text[range])
    }

    /// Two words or more that aren't a date or a time: "Tue 24 Nov, 10:42 AM" and "✓✓ 10:42" say nothing.
    static func saysSomething(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        return words.filter { word in
            word.count > 1 && !dateWords.contains(word)
        }.count >= 2
    }

    private static let dateWords: Set<String> = [
        "am", "pm", "today", "yesterday", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "jan", "feb", "mar", "apr",
        "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "at", "on", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december", "edited", "delivered", "read", "seen", "sent",
    ]

    // MARK: Asking

    public static let system = """
        You write the text that goes into the text box the user is in. You write AS the user, in the first person \
        ("I"), TO whoever they're writing to. Answer with that text and nothing else: no preamble, no quotes round \
        it, no notes.

        What to write:
        - THE BOX is empty: the natural next thing the user would write there. In a conversation, the user's reply \
        to the newest message from the other person. Under a post, the user's comment on that post. In a \
        document, what comes next.
        - THE BOX has an INSTRUCTION FOR YOU: never copy the instruction. Write the message it asks for, in its place.
        - THE BOX has THE USER'S DRAFT: finish it and fix it, keeping their own words.
        - Text is SELECTED: rewrite only that, as the box or the conversation suggests; answer with the new text only.

        Reading the screen: the lines just above the box are the newest. Lines near the box may be the user's own \
        messages, already sent: never repeat them. Answer what the other person said, never what the user said.
        When lines are marked "ME:" and "THEM:", ME lines are what the user already sent and THEM lines are the \
        other person's; unmarked lines are names, times or other things on the screen. You are ME. Reply to the \
        newest THEM message, reading it from the user's side: what THEM says they will do is theirs to do, and \
        what the user offered or asked for stays the user's ("my app" in a ME line is the user's app, and is "my \
        app" in your reply too; "I'll try it" in a THEM line means the other person will, so you never write that \
        you will try it). If the newest message is a ME line, don't answer it: write what the user would add next.

        When nothing is marked, work out who said what from the names on the lines, from who the user is, and \
        from what makes sense: the last line on the screen is not always the other person's.

        Writing: in the language of the conversation, the way people write there (short in a chat; a greeting and \
        sign-off in an email only if the thread has them). No emoji unless the thread uses them. When you are \
        shown how the user writes (their own messages, ones they sent before, what they changed in your text), \
        sound like that: their length, their words, their punctuation and capitals, their mix of languages.

        Facts: what's on the screen and in the box, and BACKGROUND: what Murmur's memory knows about the user, \
        this person and what the two of them have been dealing with. Use the background wherever it bears on \
        this conversation, the way an assistant who knows the user would: the real name of the thing being \
        talked about, what was agreed or promised, where something stands, so the reply is specific and right. \
        Leave out background that has nothing to do with this conversation. Never invent a time, date, number, price, link, \
        promise or name; where one is needed and not known, leave a short gap in square brackets, like [time].

        Example. On the screen: "Sam: are you coming to the offsite on Thursday?" The box is empty. You answer: \
        Yes, I'll be there on Thursday.
        Example. On the screen: "ME: I built a small app, can you try it and tell me what you think?" then \
        "THEM: Sure, I'll try it tonight." The box is empty. You answer: Thanks! Let me know what you think.
        Example. On the screen: "Lee: can you review my PR today?" INSTRUCTION FOR YOU: "say tomorrow morning, \
        swamped today". You answer: I'm swamped today, but I'll review it first thing tomorrow morning.
        """

    /// Text in the box that tells Murmur what to write ("say yes but after 5", "polite no", "ask if he needs
    /// it"), not the start of a message: it starts with what to do, or speaks of the other person in the third person.
    public static func isInstruction(_ draft: String) -> Bool {
        let text = draft.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 400 else { return false }
        let verbs = ["say", "tell", "ask", "reply", "respond", "answer", "write", "decline", "accept", "agree", "refuse",
                     "thank", "confirm", "remind", "apologi", "apologise", "apologize", "explain", "suggest", "propose",
                     "invite", "congratulate", "follow up", "polite", "politely", "make it", "draft", "let them know",
                     "let him know", "let her know", "mention", "offer", "request", "push back", "turn down"]
        if verbs.contains(where: { text.hasPrefix($0 + " ") || text.hasPrefix($0 + ",") || text == $0 }) { return true }
        return text.range(of: #"\b(tell|ask|let) (him|her|them)\b"#, options: .regularExpression) != nil
    }

    // MARK: Background

    /// The lines of what memory knows that this screen is about: a line stays when it names someone or something on
    /// the screen (a full name, or its first word: "Priya Shah" for "Priya", never for another "… Shah"), or shares a
    /// plain word with it ("pricing", "offsite"). A heading stays only with a line under it. Without this, a small
    /// model writes the user's week into a comment on a stranger's post.
    public static func relevant(_ background: String?, to context: Context, me: [String] = []) -> String? {
        guard let background, !background.isEmpty else { return nil }
        let screen = ([context.title, context.draft, context.selection ?? ""] + context.above + context.below)
            .joined(separator: "\n")
        let mine = Set(me.flatMap { words(in: $0.lowercased()) })
        let onScreen = Set(words(in: screen.lowercased())).subtracting(mine)
        var kept: [String] = [], heading: String?
        for line in background.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("#") { heading = line; continue }
            guard about(line, onScreen: onScreen, mine: mine) else { continue }
            if let h = heading { kept.append(h); heading = nil }
            kept.append(line)
        }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }

    private static func about(_ line: String, onScreen: Set<String>, mine: Set<String>) -> Bool {
        let tokens = line.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.first?.isUppercase == true {
                // A name: the capitalised words in a row. It's on the screen when its first word is.
                var name = [token]
                while i + 1 < tokens.count, tokens[i + 1].first?.isUppercase == true { i += 1; name.append(tokens[i]) }
                let first = name[0].lowercased()
                if first.count > 2, !mine.contains(first), !common.contains(first), onScreen.contains(first) { return true }
            } else {
                let word = token.lowercased()
                if word.count >= 4, !common.contains(word), onScreen.contains(word) { return true }
            }
            i += 1
        }
        return false
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Words too ordinary to say two texts are about the same thing.
    private static let common: Set<String> = [
        "the", "and", "for", "you", "your", "with", "that", "this", "from", "have", "has", "had", "about", "what",
        "when", "will", "just", "more", "been", "they", "them", "there", "their", "were", "would", "could", "should",
        "into", "over", "only", "also", "than", "then", "some", "like", "need", "needs", "want", "wants", "today",
        "week", "every", "most", "people", "make", "made", "does", "done", "doing", "said", "says", "know", "think",
        "time", "after", "before", "here", "where", "which", "while", "still", "very", "much", "many", "each",
        "other", "these", "those", "being", "yours", "mine", "ours", "back", "good", "great", "thanks", "thank",
        "please", "send", "sent", "reply", "comment", "comments", "message", "messages", "load", "mon", "tue", "wed",
        "thu", "fri", "sat", "sun", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec", "projects", "online",
        "follow", "relevant", "repost", "reactions", "connections",
    ]

    /// The question for the model: what's on the screen, what's in the box, then what memory knows, as background.
    public static func prompt(_ context: Context, me: [String], digest: String?, memory: String?, today: Date = Date()) -> String {
        prompt(context, me: me, knowing: Knowledge(digest: digest, memory: memory), today: today)
    }

    /// The question for the model: the window and the box first, then who the user is writing to and what memory
    /// knows about them and this conversation, then how the user writes (their own messages here, ones they sent
    /// before, what they changed in Murmur's text).
    public static func prompt(_ context: Context, me: [String], knowing: Knowledge, today: Date = Date()) -> String {
        var lines: [String] = []
        let day = DateFormatter.localizedString(from: today, dateStyle: .full, timeStyle: .short)
        lines.append("TODAY: \(day)")
        lines.append("APP: \(context.app)" + (context.title.isEmpty ? "" : " — \(context.title)"))
        let names = me.filter { $0 != "You" && $0.count > 1 }
        if !names.isEmpty { lines.append("THE USER (you write as them): \(names.joined(separator: ", also called "))") }
        if let partner = knowing.partner { lines.append("THEY ARE WRITING TO: \(partner)") }
        lines += ["", "ON THE SCREEN, ABOVE THE BOX (oldest first, newest last):"]
        if context.above.isEmpty {
            lines.append("(nothing)")
        } else if context.sides.isEmpty {
            lines += context.above
        } else {
            lines += zip(context.above, context.sides).map { line, side in side.map { "\($0.rawValue): \(spoken(line))" } ?? line }
        }
        if context.draft.isEmpty {
            lines += ["", "▶ THE BOX: empty"]
        } else if isInstruction(context.draft) {
            lines += ["", "▶ THE BOX has an INSTRUCTION FOR YOU (don't copy it; write the message it asks for):", context.draft]
        } else {
            lines += ["", "▶ THE BOX has THE USER'S DRAFT (finish and fix it):", context.draft]
        }
        if let selection = context.selection { lines += ["", "SELECTED IN THE BOX:", selection] }
        if !context.below.isEmpty { lines += ["", "BELOW THE BOX:"] + context.below }
        // About the person they're writing to: all of it bears on this conversation.
        if let partner = knowing.partner, let dossier = knowing.dossier, !dossier.isEmpty {
            lines += ["", "WHAT MURMUR'S MEMORY KNOWS ABOUT \(partner.uppercased()) AND THE USER:", dossier]
        }
        let background = [knowing.digest, knowing.memory].compactMap { relevant($0, to: context, me: me) }
        if !background.isEmpty {
            lines += ["", "BACKGROUND (from Murmur's memory; use what bears on this conversation):"] + background
        }
        if let profile = knowing.profile, !profile.isEmpty {
            lines += ["", "WHO THE USER IS AND HOW THEY WRITE (for the voice; not for facts to bring up):", String(profile.prefix(1400))]
        }
        let own = ownLines(context)
        if !own.isEmpty || !knowing.sent.isEmpty {
            lines += ["", "HOW THE USER WRITES HERE (their own messages; match their length, tone, language and habits, "
                + "never reuse their content):"]
            lines += (own + knowing.sent.filter { !own.contains($0) }).prefix(9).map { "- \($0)" }
        }
        if !knowing.corrections.isEmpty {
            lines += ["", "WHAT THE USER CHANGED IN WHAT MURMUR WROTE HERE BEFORE (write the way they corrected it):"]
            for change in knowing.corrections { lines += ["- Murmur wrote: \(change.wrote)", "  They sent: \(change.sent)"] }
        }
        lines += ["", "Write what goes in the box, as the user."]
        return lines.joined(separator: "\n")
    }

    /// The model's answer as it goes in the box, or nil when there's nothing usable: its thinking, quotes and
    /// preamble ("Here's a reply:") taken out; nil when it only repeats a line already on the screen or the draft.
    public static func clean(_ answer: String, context: Context) -> String? {
        var text = ModelOutput.answer(answer).trimmingCharacters(in: .whitespacesAndNewlines)
        // A fence round it.
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .filter { !$0.hasPrefix("```") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // "Here's a reply:" and the like, on a line of its own.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, let first = lines.first?.lowercased(), first.hasSuffix(":"), first.count < 60,
           first.range(of: #"^(here('s| is)|sure|reply|response|draft|message|comment)\b"#, options: .regularExpression) != nil {
            text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Quotes round the whole of it.
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] where text.count > 2 && text.hasPrefix(open) && text.hasSuffix(close) {
            let inner = String(text.dropFirst().dropLast())
            if !inner.contains(open) { text = inner.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !text.isEmpty else { return nil }
        let normal = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let mine = normal(text)
        if mine == normal(context.draft) { return nil }
        if mine.count >= 6, context.above.suffix(12).contains(where: { normal($0) == mine }) { return nil }
        return text
    }

}
