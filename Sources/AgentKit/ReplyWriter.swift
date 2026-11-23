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

        public init(app: String, title: String, above: [String], below: [String], draft: String, selection: String?) {
            self.app = app
            self.title = title
            self.above = above
            self.below = below
            self.draft = draft
            self.selection = selection
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

        Writing: in the language of the conversation, the way people write there (short in a chat; a greeting and \
        sign-off in an email only if the thread has them). No emoji unless the thread uses them.

        Facts: only what's on the screen and in the box. BACKGROUND (what Murmur knows about the user) is only for \
        when the conversation is about it; otherwise ignore it. Never invent a time, date, number, price, link, \
        promise or name; where one is needed and not known, leave a short gap in square brackets, like [time].

        Example. On the screen: "Sam: are you coming to the offsite on Thursday?" The box is empty. You answer: \
        Yes, I'll be there on Thursday.
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
        var lines: [String] = []
        let day = DateFormatter.localizedString(from: today, dateStyle: .full, timeStyle: .short)
        lines.append("TODAY: \(day)")
        lines.append("APP: \(context.app)" + (context.title.isEmpty ? "" : " — \(context.title)"))
        let names = me.filter { $0 != "You" && $0.count > 1 }
        if !names.isEmpty { lines.append("THE USER (you write as them): \(names.joined(separator: ", also called "))") }
        lines += ["", "ON THE SCREEN, ABOVE THE BOX (oldest first, newest last):"]
        lines += context.above.isEmpty ? ["(nothing)"] : context.above
        if context.draft.isEmpty {
            lines += ["", "▶ THE BOX: empty"]
        } else if isInstruction(context.draft) {
            lines += ["", "▶ THE BOX has an INSTRUCTION FOR YOU (don't copy it; write the message it asks for):", context.draft]
        } else {
            lines += ["", "▶ THE BOX has THE USER'S DRAFT (finish and fix it):", context.draft]
        }
        if let selection = context.selection { lines += ["", "SELECTED IN THE BOX:", selection] }
        if !context.below.isEmpty { lines += ["", "BELOW THE BOX:"] + context.below }
        let background = [digest, memory].compactMap { relevant($0, to: context, me: me) }
        if !background.isEmpty {
            lines += ["", "BACKGROUND (what Murmur knows; use it only if the conversation is about it):"] + background
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
