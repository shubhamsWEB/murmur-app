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
        let text = " " + utterance.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "' ")).inverted)
            .joined(separator: " ")
            .split(separator: " ").joined(separator: " ") + " "
        let words = text.split(separator: " ").map(String.init)
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
        let asks = ["what", "when", "where", "who", "whom", "which", "how", "did", "do", "does", "have", "has", "is", "are",
                    "was", "were", "can", "could", "tell", "remind", "recall", "remember", "any", "list"]
        guard let first = words.first, asks.contains(first) || mentionsMemory || text.contains(" do you remember ") else {
            return nil
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

    /// "Open…", "send…", "search…": something to do, not a question to answer.
    static func startsWithAction(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
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
            question. Answer in one to four short sentences, directly, with the specifics memory gives (names, dates, \
            times, versions, what changed). Use only what's shown: never guess a time, a date or a detail it doesn't \
            give, and never add anything from general knowledge. Lines marked "exact" are copied from the user's own \
            windows (a booking, a release page): their times, dates and versions win over any other note. Lines marked \
            "what you did" are stretches of the user's work, with when and how long. When two notes disagree, say what \
            the newer one says. \
            If what's shown doesn't answer the question, reply with exactly \(notInMemory) and nothing else.\(name)
            """
    }

    public static func answerRequest(_ utterance: String, memory: String, now: Date = Date()) -> String {
        let when = now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        return "Now: \(when).\n\nQuestion: \(utterance)\n\nWhat Murmur remembers that may answer it:\n\(memory)"
    }

    /// The model's answer, or nil when it said memory doesn't cover the question (or said nothing).
    public static func answer(from text: String) -> String? {
        let clean = ModelOutput.answer(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(notInMemory) else { return nil }
        return clean
    }
}
