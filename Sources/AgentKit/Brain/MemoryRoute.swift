import Foundation

/// Requests about the user's own world, decided before the agent and its tools come into it, in microseconds:
///
/// - "forget Project Phoenix", "delete this from your memory": forgotten by Murmur itself (the model once called a
///   tool that doesn't exist and said it was done).
/// - "give me my morning brief", "recap my day": the brief, from the same facts as the 9:00 notification.
/// - "when is my flight?", "what did we release in Murmur?", "who is Arjun?": answered from memory, by the model with
///   only what memory found and no tools (it once searched the web, found someone else's changelog and made the rest
///   up). Only when memory has nothing on it does the request go on to the agent as before.
///
/// Rules, not a model: a request routed wrongly here still reaches the agent (an answer memory can't give comes back
/// as "not in memory" and the agent takes over), and one that isn't routed here goes exactly where it went before.
public enum MemoryRoute: Equatable, Sendable {
    case forget
    case brief(evening: Bool)
    case question

    public static func classify(_ utterance: String, hour: Int = Calendar.current.component(.hour, from: Date())) -> MemoryRoute? {
        let words = spoken(utterance)
        let text = " " + words.joined(separator: " ") + " "
        guard !words.isEmpty, words.count <= 40 else { return nil }
        let mentionsMemory = [" your memory ", " my memory ", " from memory ", " in memory ", " the memory ",
                              " you remember ", " you know about "].contains(where: text.contains)

        // Forgetting: said with memory, or "forget" first.
        let forgetting = ["forget", "delete", "remove", "erase", "drop"]
        if words.contains(where: forgetting.contains), mentionsMemory || words.first == "forget" {
            return .forget
        }

        // The brief, or the day's wrap-up.
        let briefs = [" brief ", " briefing ", " recap ", " wrap up ", " wrap-up ", " wrapup ", " what's on today ",
                      " what is on today ", " what do i have today ", " my day ", " plan for today ", " what's due ",
                      " what is due ", " summary of my day ", " summary of yesterday ", " what did i do yesterday "]
        if briefs.contains(where: text.contains), words.count <= 14, !startsWithAction(words) {
            let evening = [" recap ", " wrap up ", " wrap-up ", " wrapup ", " summary of my day "].contains(where: text.contains)
                || (hour >= 17 && text.contains(" my day "))
            return .brief(evening: evening)
        }

        // A question about the user's own world: asked as a question, about them ("my", "I", "we"), not an action,
        // not about the screen ("this page"), not about the outside world.
        // Speech often garbles the start ("We what our releases we did…", "No ma, did we share…"): a question asked
        // anywhere in it counts, not only one that starts with a question word.
        let askedInside = [" did we ", " did i ", " have we ", " have i ", " had we ", " what did ", " what have ",
                           " when did ", " who did ", " whom did ", " did you ", " were we ", " is there any ",
                           " are there any ", " has there ", " what all "].contains(where: text.contains)
        guard let first = words.first, asks.contains(first) || mentionsMemory || askedInside
                || text.contains(" do you remember ") else {
            return nil
        }
        // "Tell the team we shipped 1.7", "remind me to write the notes", "remember my flight is on Friday": something
        // to do. Only "tell me what…", "remind me when…", "remember when…" ask.
        if ["tell", "remind", "remember"].contains(first), !mentionsMemory, !askedInside {
            let wh: Set<String> = ["what", "when", "where", "who", "whom", "which", "how", "whether", "if", "why"]
            let second = words.count > 1 ? words[1] : "", third = words.count > 2 ? words[2] : ""
            let asking: Bool
            switch first {
            // "Tell me what…", "tell me about…" (not "tell Priya what we shipped": that's a message to Priya).
            case "tell": asking = ["me", "us"].contains(second) && (wh.contains(third) || third == "about")
            // "Remind me when…" (not "remind me about the dentist at 5": that's a reminder).
            case "remind": asking = ["me", "us"].contains(second) && wh.contains(third)
            // "Remember when we…" (not "remember my flight is on Friday").
            default: asking = wh.contains(second)
            }
            guard asking else { return nil }
        }
        let theirs = [" my ", " i ", " i'm ", " i've ", " i'll ", " me ", " we ", " we've ", " our ", " us ", " mine "]
            .contains(where: text.contains) || mentionsMemory
            // "Did Tanay reply?", "has Priya written back?": about someone the user wrote to.
            || [" reply ", " replied ", " responded ", " respond ", " get back ", " got back ", " wrote back ", " written back "]
                .contains(where: text.contains)
        guard theirs, !startsWithAction(words) else { return nil }
        // "This" is the screen when it's a thing on it ("this page", "what is this"), not a time ("this week").
        let screen = [" that page ", " the page ", " on screen ", " on the screen ", " here ", " this page ", " this window ",
                      " this tab ", " this screen ", " this email ", " this mail ", " this chat ", " this message ",
                      " this doc ", " this one ", " this video ", " this file ", " selected ", " selection "]
        if (screen.contains(where: text.contains) || text.hasSuffix(" this ")), !mentionsMemory { return nil }
        let outside = [" weather ", " news ", " stock ", " share price ", " price of ", " score ", " exchange rate ",
                       " ip address ", " battery ", " wifi ", " wi-fi ", " volume ", " brightness ", " disk ", " storage ",
                       " version of macos ", " internet ", " google ", " search the web ", " online "]
        if outside.contains(where: text.contains) { return nil }
        // Files are file search's ("where is my resume", "do I have the lease pdf").
        let files = [" file ", " files ", " pdf ", " doc ", " document ", " folder ", " photo ", " photos ", " picture ",
                     " pictures ", " video ", " videos ", " screenshot ", " resume ", " invoice ", " spreadsheet "]
        if files.contains(where: text.contains), !mentionsMemory { return nil }
        return .question
    }

    /// What was said, as plain lowercase words, without how speech starts: "So, what all releases did we do?",
    /// "Okay Murmur, have we posted it?", "Hey, quick question, did Tanay reply?" are asked from their first real word
    /// (the question once went past memory because it started with "so").
    static func spoken(_ utterance: String) -> [String] {
        var said = utterance.lowercased().replacingOccurrences(of: "’", with: "'")
        if let rest = WakeName.strip(said), !rest.isEmpty { said = rest }
        var words = said
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "' ")).inverted)
            .joined(separator: " ")
            .split(separator: " ").map(String.init)
        let filler: Set<String> = ["so", "okay", "ok", "hey", "hi", "hello", "murmur", "and", "also", "um", "uh", "umm", "erm",
                                   "well", "right", "alright", "actually", "basically", "listen", "now", "yo", "quick",
                                   "question", "just", "please", "oh", "hmm", "yeah", "yes", "no", "ma", "acha",
                                   "accha", "achha"]
        while let first = words.first, filler.contains(first), words.count > 1 { words.removeFirst() }
        // "Can you tell me…", "could you check whether…", "I want to know…", "do you know…": the question comes after.
        let openers = [["can", "you", "tell", "me"], ["could", "you", "tell", "me"], ["can", "you", "check"],
                       ["could", "you", "check"], ["i", "want", "to", "know"], ["i", "wanted", "to", "know"],
                       ["i", "wanna", "know"], ["tell", "me"], ["do", "you", "know"], ["let", "me", "know"],
                       ["check"], ["confirm"]]
        for opener in openers where words.count > opener.count + 1 && Array(words.prefix(opener.count)) == opener {
            let rest = Array(words.dropFirst(opener.count).drop { ["if", "whether", "that"].contains($0) })
            // Only when what follows is itself a question ("…tell me what we released", not "…tell me a joke").
            if let next = rest.first, asks.contains(next) { words = rest }
            break
        }
        return words
    }

    /// Words a question about the user's world starts with.
    static let asks: Set<String> = ["what", "when", "where", "who", "whom", "which", "how", "did", "do", "does", "have", "has",
                                    "had", "is", "are", "was", "were", "can", "could", "tell", "remind", "recall", "remember",
                                    "any", "list"]

    /// More than one question in one breath: "what did we release, and have we posted it on LinkedIn?". Each part is
    /// answered (or said not to be in memory); a ready answer to one part alone would drop the rest.
    public static func isCompound(_ utterance: String) -> Bool {
        let text = " " + spoken(utterance).joined(separator: " ") + " "
        let joined = #" (and|also|plus|or) (also )?(have|has|had|did|do|does|was|were|is|are|what|when|who|which|how|where|whether|if) "#
        return text.range(of: joined, options: .regularExpression) != nil
    }

    /// The user asked Murmur to go and look ("check LinkedIn whether we posted it", "search my mail", "see if…"):
    /// then the question may be answered from the app or site, not only from memory.
    public static func asksToLook(_ utterance: String) -> Bool {
        let text = " " + spoken(utterance).joined(separator: " ") + " "
        let look = #" (check|checking|look|looking|search|google|browse|verify|confirm|open|go to|visit|see if|see whether|find out|look up|online|on the web|on the internet|on the site|on the page) "#
        return text.range(of: look, options: .regularExpression) != nil
    }

    /// A question about what the user did ("did we post it?", "what did we release?", "have I told Priya?", "has
    /// Tanay replied?"): the user (or someone they wrote to) doing something in the past. Not a question about the
    /// world ("did India win?", "has my order shipped?") or how to do something ("how do I change my wallpaper?"),
    /// which the web may well answer.
    public static func aboutThePast(_ utterance: String) -> Bool {
        let text = " " + spoken(utterance).joined(separator: " ") + " "
        let done = "did|do|sent|send|posted|post|released|release|shipped|launched|told|tell|notified|notify|announced|shared|share|"
            + "replied|promised|emailed|messaged|wrote|published|tagged|pushed|said|made|worked|finished|completed"
        let patterns = [
            #" did (we|i) "#, #" (we|i) (\#(done)) "#, #" (have|had) (we|i) "#, #" (we've|i've|we'd|i'd) "#,
            #" (was|were) (we|i) "#,
            #" what all (we|i) "#,
            // Someone the user wrote to answering: "did Tanay reply?", "has Priya written back?".
            #" (did|has|have) (\w+ ){1,2}(reply|replied|respond|responded|write back|written back|wrote back|get back|got back) "#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Something to do in the same breath ("what did we ship yesterday? Post it on LinkedIn"): its tools stay open.
    public static func hasAction(_ utterance: String) -> Bool {
        let clauses = utterance.components(separatedBy: CharacterSet(charactersIn: ".?!;\n"))
            .flatMap { $0.components(separatedBy: " and then ") }.flatMap { $0.components(separatedBy: " then ") }
        // A clause after the first that tells Murmur to do something ("…? Post it on LinkedIn", "…and then remind me").
        let more: Set<String> = ["post", "publish", "tweet", "announce", "notify", "forward", "remind", "tell"]
        // "If not, post it", "otherwise send them the link": the condition goes, what's to do stays.
        let conditions: [[String]] = [["if", "not"], ["if", "no"], ["if", "so"], ["if", "yes"], ["otherwise"], ["else"],
                                      ["if", "we", "haven't"], ["if", "i", "haven't"], ["if", "we", "didn't"], ["if", "i", "didn't"],
                                      ["if", "not", "then"], ["then"]]
        return clauses.contains { clause in
            var words = spoken(clause)
            for condition in conditions.sorted(by: { $0.count > $1.count }) where Array(words.prefix(condition.count)) == condition {
                words.removeFirst(condition.count)
                break
            }
            return startsWithAction(words) || (words.first.map(more.contains) == true && words.dropFirst().first != "me")
        }
    }

    /// The web and the browser stay shut for this request: a question about the user's own past that doesn't ask
    /// Murmur to go and look, and has nothing to do in it.
    public static func shutsOutTheWeb(_ utterance: String) -> Bool {
        classify(utterance) == .question && aboutThePast(utterance) && !asksToLook(utterance) && !hasAction(utterance)
    }

    /// Tools that go outside memory to the web or a browser: shut for a question about the user's own past.
    public static let looksElsewhere: Set<String> = ["web_search", "site_search", "open_url", "browser_click", "browser_type",
                                                     "browser_switch_tab", "browser_scroll"]

    /// "Open…", "send…", "search…": something to do, not a question to answer.
    static func startsWithAction(_ words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let actions: Set<String> = ["open", "send", "message", "text", "call", "email", "mail", "play", "pause", "search",
                                    "google", "find", "look", "go", "visit", "create", "make", "write", "draft", "book",
                                    "buy", "order", "set", "turn", "start", "stop", "close", "quit", "show", "type",
                                    "paste", "copy", "move", "rename", "save", "share", "schedule", "add", "build", "run",
                                    "install", "download", "upload", "reply", "summarise", "summarize", "translate"]
        // "Can you open…", "could you send…", "please search…".
        let skip: Set<String> = ["can", "could", "would", "will", "please", "you", "kindly", "just", "murmur", "hey"]
        let meaningful = words.drop { skip.contains($0) }
        return meaningful.first.map(actions.contains) ?? false
    }

    /// What the model answering from memory is told: only what memory found, no tools, and a fixed word when it
    /// doesn't cover the question, so the agent can take over.
    public static let notInMemory = "NOT_IN_MEMORY"

    public static func answerPrompt(user: [String]) -> String {
        let name = user.first.map { " The user is \($0)." } ?? ""
        return """
            You answer the user's question about their own life and work from what Murmur remembers, shown below the \
            question. Answer in one to five short sentences, directly, with the specifics memory gives (names, dates, \
            times, versions, what changed, where it was posted or sent). Use only what's shown: never guess a time, a \
            date or a detail it doesn't give, and never add anything from general knowledge. Lines marked "exact" are \
            copied from the user's own windows (a booking, a release page): their times, dates and versions win over \
            any other note. Lines marked "what you did" are stretches of the user's work; "you posted", "you sent" and \
            "Murmur did" lines are things the user (or Murmur for them) actually did. When two notes disagree, say what \
            the newer one says. \
            A question can have several parts ("what did we release, and have we posted about it?"): answer every part \
            memory covers, and for a part it doesn't, say plainly that Murmur hasn't seen it (for example "I haven't \
            seen a LinkedIn post about it since then"), using the coverage line to say since when Murmur has been \
            watching. Never say something didn't happen: only that Murmur didn't see it. When a part isn't covered, end \
            with a short offer to check where it would show ("Want me to check LinkedIn?"), and don't check yourself. \
            Reply with exactly \(notInMemory) and nothing else only when what's shown answers no part of the \
            question at all.\(name)
            """
    }

    public static func answerRequest(_ utterance: String, memory: String, coverage: String? = nil, now: Date = Date()) -> String {
        let when = now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        let watched = coverage.map { "\n\nCoverage: \($0)" } ?? ""
        return "Now: \(when).\n\nQuestion: \(utterance)\(watched)\n\nWhat Murmur remembers that may answer it:\n\(memory)"
    }

    /// The model's answer, or nil when it said memory doesn't cover the question (or said nothing). An answer that
    /// only says what wasn't seen or offers to check ("I haven't seen that. Want me to check LinkedIn?") answers a
    /// question about the user's past (`notSeenAnswers`: "did we post it?" → "I haven't seen a post since 5 Nov");
    /// for anything else it answers nothing, and the agent takes the request, which may well be something to do.
    public static func answer(from text: String, notSeenAnswers: Bool = false) -> String? {
        let clean = ModelOutput.answer(text).replacingOccurrences(of: notInMemory, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard clean.split(separator: " ").count >= 3 else { return nil }
        let nothing = #"(?i)^(want me to|should i|shall i|do you want me|would you like me|i can check|let me know)|haven'?t seen|have not seen|don'?t see|do not see|didn'?t see|no record|not in (my |murmur'?s )?memory|doesn'?t show|does not show|nothing (about|on|in)"#
        let sentences = clean.components(separatedBy: CharacterSet(charactersIn: ".?!\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard notSeenAnswers || sentences.contains(where: { $0.range(of: nothing, options: .regularExpression) == nil }) else {
            return nil
        }
        // As the model wrote it, without the word and without what it left in front (". Want me to…").
        let written = ModelOutput.answer(text).replacingOccurrences(of: notInMemory, with: "")
        return String(written.drop { $0.isWhitespace || $0.isPunctuation }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
