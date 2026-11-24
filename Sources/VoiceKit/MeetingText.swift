import Foundation

/// An answer as it's read out loud: the sentences to say, then extra points.
public struct SpokenAnswer: Equatable, Sendable {
    /// The direct answer, in a line ("ANSWER: …").
    public var headline: String?
    /// The points that complete it, a bullet each ("POINTS: - …"); may hold **bold** for key words.
    public var points: [String]
    /// A short concrete example ("EXAMPLE: …").
    public var example: String?
    /// What to say, a sentence at a time (an answer in the older "SAY: …" shape, or plain text).
    public var say: [String]
    public var also: [String]
    /// Code the answer gives (a function asked for, a fix), each block whole, in order.
    public var code: [AnswerCode]

    public init(say: [String], also: [String], code: [AnswerCode] = [], headline: String? = nil,
                points: [String] = [], example: String? = nil) {
        self.say = say
        self.also = also
        self.code = code
        self.headline = headline
        self.points = points
        self.example = example
    }

    /// Everything to read out, in order, as plain text (for copying and VoiceOver).
    public var spokenText: String {
        let parts = [headline].compactMap { $0 } + points + say + [example].compactMap { $0 }
        return parts.joined(separator: " ").replacingOccurrences(of: "**", with: "")
    }

    public var isEmpty: Bool { headline == nil && points.isEmpty && say.isEmpty && example == nil }
}

/// A block of code in an answer: its language ("python"), and the code.
public struct AnswerCode: Equatable, Sendable {
    public var language: String
    public var text: String

    public init(language: String, text: String) {
        self.language = language
        self.text = text
    }
}

/// One line of a meeting's transcript: what one side said in one stretch of speech.
public struct MeetingLine: Identifiable, Sendable, Equatable {
    public enum Speaker: String, Sendable { case you = "You", them = "Them" }
    public let id: Int
    public let speaker: Speaker
    public var text: String
    /// When it began.
    public let at: Date
    /// Which voice on the call said it (1, 2…), when Murmur could tell (MeetingVoices).
    public var voice: Int?
    /// How long it took to say (0: not known).
    public var seconds: Double

    public init(id: Int, speaker: Speaker, text: String, at: Date, voice: Int? = nil, seconds: Double = 0) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.at = at
        self.voice = voice
        self.seconds = seconds
    }

    /// When it ended.
    public var end: Date { at.addingTimeInterval(seconds) }
}

/// The text side of meeting notes: telling a question from a statement, finding your microphone's echo of the call,
/// and the transcript as the AI reads it.
public enum MeetingText {
    /// Whether a line asks something, so Murmur drafts an answer: a question mark (the speech models write them), or
    /// a sentence that opens the way a question does ("what…", "can you…", "tell me about…").
    public static func isQuestion(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return false }
        if text.contains("?") { return true }
        // The last sentence decides: "We shipped it. How did that go" asks; "How it went is fine." doesn't.
        let sentences = text.split(whereSeparator: { ".!".contains($0) })
        var lastWords = (sentences.last.map(String.init) ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        // "So, how did…", "Okay and can you…": the words that lead into a question don't change it.
        let leadIns: Set<String> = ["so", "and", "okay", "ok", "alright", "right", "well", "now", "then", "um", "uh",
                                    "hmm", "also", "but", "great", "cool", "nice", "yeah", "yes", "sure", "anyway",
                                    "actually", "please", "just"]
        while lastWords.count > 3, leadIns.contains(lastWords[0].trimmingCharacters(in: .punctuationCharacters)) {
            lastWords.removeFirst()
        }
        let last = lastWords.joined(separator: " ")
        guard lastWords.count >= 3 else { return false }
        if phrases.contains(where: { last.contains($0) }) { return true }
        // A request: "Write factorial in Python", "Please explain the cache", "Show me the query".
        let opener = lastWords.first { !["please", "so", "okay", "ok", "now", "and", "then", "just"].contains($0
            .trimmingCharacters(in: .punctuationCharacters)) }?.trimmingCharacters(in: .punctuationCharacters) ?? ""
        if requests.contains(opener) { return true }
        let first = lastWords[0].trimmingCharacters(in: .punctuationCharacters)
        if wh.contains(first) {
            // "What we did was…" is a statement: a question word followed by a subject and no auxiliary.
            let second = lastWords[1].trimmingCharacters(in: .punctuationCharacters)
            return auxiliaries.contains(second) || ["much", "many", "long", "often", "far", "about", "if"].contains(second)
                || ["would", "should", "could", "can", "do", "did"].contains(second)
        }
        if auxiliaries.contains(first) {
            // "Can you…", "Is there…", "Do you…": an auxiliary first and a subject after it.
            let second = lastWords[1].trimmingCharacters(in: .punctuationCharacters)
            return subjects.contains(second)
        }
        return false
    }

    private static let requests: Set<String> = [
        "write", "implement", "code", "explain", "describe", "show", "give", "list", "design", "build", "create",
        "solve", "find", "calculate", "compare", "define", "walk", "outline", "summarize", "summarise", "optimize",
        "debug", "fix", "reverse", "sort", "convert",
    ]
    private static let wh: Set<String> = ["what", "what's", "how", "how's", "why", "when", "where", "who", "who's",
                                          "which", "whom", "whose"]
    private static let auxiliaries: Set<String> = [
        "is", "are", "was", "were", "do", "does", "did", "can", "could", "would", "will", "should", "shall", "have",
        "has", "had", "may", "might", "am", "isn't", "aren't", "don't", "doesn't", "didn't", "can't", "won't",
    ]
    private static let subjects: Set<String> = ["you", "we", "they", "he", "she", "it", "i", "there", "this", "that",
                                                "your", "the", "anyone", "someone", "everyone"]
    private static let phrases = ["tell me about", "tell me how", "walk me through", "can you explain", "explain how",
                                  "explain why", "what do you think", "your thoughts on", "how would you",
                                  "talk me through", "take me through", "describe how", "describe a time"]

    /// Whether `mine` (from your microphone) is the call's sound picked up again, on speakers rather than headphones:
    /// the same words in the same order, heard at the same moment (`apart`: seconds between the two). A reply that
    /// takes up their words ("Can you share the pricing sheet?" / "Yes, I'll share the pricing sheet") is you
    /// speaking: until 24 Nov such replies were dropped, and your side went missing from the transcript.
    public static func isEcho(_ mine: String, of theirs: String, apart: TimeInterval = 0) -> Bool {
        guard abs(apart) <= 6 else { return false }
        let a = sequence(mine), b = sequence(theirs)
        guard a.count >= 3, b.count >= 3 else { return false }
        return Double(inOrder(a, b)) / Double(max(a.count, b.count)) >= 0.75
    }

    /// How much of `mine` is found in `theirs`, 0…1, in word pairs: the microphone hears the speakers worse than the
    /// call is heard, and cuts it elsewhere, so a whole-line comparison misses some echoes. From Cicada's `EchoMatch`
    /// (github.com/wquguru/cicada, Apache-2.0, © wquguru); a single word counts as itself.
    public static func contained(_ mine: String, in theirs: [String]) -> Double {
        let a = pairs(sequence(mine))
        guard a.count >= 2 else { return 0 }
        let b = Set(theirs.flatMap { pairs(sequence($0)) })
        return Double(a.filter(b.contains).count) / Double(a.count)
    }

    /// Echo by containment: at least this share of your line is in what they said around then.
    public static let containedEcho = 0.6

    /// The echo comes back within this long of the call playing it.
    public static let echoSlack: TimeInterval = 6

    /// The other side's lines being said while `line` was: their time overlaps its, give or take `echoSlack`. A
    /// microphone that hears the speakers doesn't cut where the call does (in a room it rarely hears a pause, so its
    /// stretches run long), so one of your lines can cover several of theirs.
    public static func during(_ line: MeetingLine, in lines: [MeetingLine]) -> [MeetingLine] {
        let from = line.at.addingTimeInterval(-echoSlack), to = line.end.addingTimeInterval(echoSlack)
        return lines.filter { $0.speaker == .them && $0.end >= from && $0.at <= to }
    }

    /// What's left of `mine` (what your microphone heard) once the call's own words are taken out, given what they
    /// said meanwhile: nil when it's all the call; otherwise your words, without the sentences that are the call's.
    ///
    /// Mostly the call (the same words in order as one of their lines, or most of its word pairs found in theirs):
    /// only sentences with next to nothing of theirs in them are yours ("Sorry, can I jump in?" said over the
    /// speakers). Mostly yours: only a long sentence that's nearly all theirs goes, because answering someone often
    /// repeats their words ("Yes, I'll share the pricing sheet").
    public static func withoutEcho(_ mine: String, theirs: [String]) -> String? {
        guard !theirs.isEmpty else { return mine }
        if theirs.contains(where: { isEcho(mine, of: $0) }) { return nil }
        let share = contained(mine, in: theirs)
        guard share > 0 else { return mine }
        let mostly = share >= containedEcho
        let sentences = Self.sentences(mine)
        guard sentences.count > 1 else { return mostly ? nil : mine }
        let kept = sentences.filter { sentence in
            let words = sequence(sentence).count, found = contained(sentence, in: theirs)
            if mostly { return words >= yoursWords && found <= yoursShare && wordsFound(sentence, in: theirs) < yoursWordsShare }
            return words < echoSentenceWords || found < echoSentence
        }
        if kept.count == sentences.count { return mine }
        let rest = kept.joined(separator: " ")
        return isWorthKeeping(rest) ? rest : nil
    }

    /// In a line that's partly yours, one sentence is the call's only when it's this long (words) and this much of
    /// it is theirs.
    static let echoSentenceWords = 6
    static let echoSentence = 0.8
    /// In a line that's mostly the call, a sentence is yours when it's this long and no more than this much of it is
    /// theirs (a sentence of the call the microphone misheard still shares more than that).
    static let yoursWords = 3
    static let yoursShare = 0.2
    /// …and fewer than this share of its words are in what they said at all: "You're in lockdown" against their
    /// "you're lockdown and…" shares no pair of words, and is still the call.
    static let yoursWordsShare = 0.6

    /// The share of `mine`'s words found anywhere in `theirs`.
    static func wordsFound(_ mine: String, in theirs: [String]) -> Double {
        let words = sequence(mine)
        guard !words.isEmpty else { return 0 }
        let said = Set(theirs.flatMap { sequence($0) })
        return Double(words.filter(said.contains).count) / Double(words.count)
    }

    private static func pairs(_ words: [String]) -> [String] {
        words.count < 2 ? words : (0..<words.count - 1).map { "\(words[$0]) \(words[$0 + 1])" }
    }

    private static func sequence(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    /// How many words the two have in the same order (the longest common subsequence).
    private static func inOrder(_ a: [String], _ b: [String]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = x == y ? diagonal + 1 : max(row[j + 1], row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }



    /// The transcript as the AI reads it, newest last, cut from the start to fit `limit` characters.
    public static func transcript(_ lines: [MeetingLine], limit: Int = 14_000,
                                  label: (MeetingLine) -> String = { $0.speaker.rawValue }) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        var kept: [String] = []
        var total = 0
        for line in lines.reversed() {
            let row = "[\(formatter.string(from: line.at))] \(label(line)): \(line.text)"
            if total + row.count + 1 > limit { break }
            kept.append(row)
            total += row.count + 1
        }
        return kept.reversed().joined(separator: "\n")
    }

    /// What the AI knows about the meeting besides what's said: what it's about, your instructions, and your
    /// documents' text, cut to `limit` characters (documents share what's left after the rest, in order).
    public static func context(about: String, instructions: String, documents: [(name: String, text: String)],
                               limit: Int = 24_000) -> String {
        var parts: [String] = []
        let about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty { parts.append("About this meeting: \(about)") }
        if !instructions.isEmpty { parts.append("The user's instructions: \(instructions)") }
        var room = limit - parts.reduce(0) { $0 + $1.count + 2 }
        for (index, document) in documents.enumerated() where room > 200 {
            let share = room / (documents.count - index)
            let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let kept = text.count > share - document.name.count - 40 ? String(text.prefix(max(0, share - document.name.count - 60))) + " […]" : text
            let part = "Document \"\(document.name)\":\n\(kept)"
            parts.append(part)
            room -= part.count + 2
        }
        return parts.joined(separator: "\n\n")
    }

    /// The share of sampled pixels that differ between two pictures of the same size (RGBA bytes) by more than
    /// `threshold` in any channel: how Murmur tells whether a screen capture shows its panel.
    public static func changedFraction(_ a: [UInt8], _ b: [UInt8], threshold: Int = 24) -> Double {
        let pixels = min(a.count, b.count) / 4
        guard pixels > 0 else { return 0 }
        var changed = 0
        for pixel in 0..<pixels {
            let i = pixel * 4
            for channel in 0..<3 where abs(Int(a[i + channel]) - Int(b[i + channel])) > threshold {
                changed += 1
                break
            }
        }
        return Double(changed) / Double(pixels)
    }

    /// An answer as it's read out: what to say, a sentence at a time, and the extra points. The model is asked for
    /// "SAY: … ALSO: - …"; Markdown (bold labels, "Answer:", "You could also say:") and plain text are read too, and a
    /// half-written answer (still streaming) splits the same way, its last sentence unfinished.
    public static func spoken(_ text: String) -> SpokenAnswer {
        // Code first: fenced blocks (a block still being written counts), taken out of what's said.
        var code: [AnswerCode] = []
        var prose: [String] = []
        var block: AnswerCode?
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = block {
                    code.append(AnswerCode(language: open.language, text: open.text))
                    block = nil
                } else {
                    block = AnswerCode(language: String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased(),
                                      text: "")
                }
                continue
            }
            if block != nil {
                block!.text += block!.text.isEmpty ? raw : "\n" + raw
            } else if !["code:", "code"].contains(trimmed.lowercased()) {
                prose.append(raw)
            }
        }
        if let open = block, !open.text.isEmpty { code.append(open) }
        enum Section { case none, say, headline, points, example, also }
        var section = Section.none
        var say: [String] = [], also: [String] = [], points: [String] = []
        var headline: [String] = [], example: [String] = []
        for raw in prose {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Labels are read without their bold ("**Answer:**"); the text keeps it, for key words.
            let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            let lower = plain.lowercased()
            let labels: [(Section, [String])] = [
                (.headline, ["answer:", "answer"]), (.say, ["say:", "say"]),
                (.points, ["points:", "key points:", "points", "key points"]),
                (.example, ["example:", "for example:", "example"]),
                (.also, ["also:", "you could also say:", "you could also say", "also"]),
            ]
            if let (found, rest) = labels.lazy.compactMap({ entry in label(lower, plain, entry.1).map { (entry.0, $0) } }).first {
                section = found
                if !rest.isEmpty { line = rest } else { continue }
                if let bullet = bulletText(line) { line = bullet }
                switch found {
                case .headline: headline.append(line)
                case .say: say.append(line)
                case .points: points.append(line)
                case .example: example.append(line)
                case .also, .none: also.append(line)
                }
                continue
            }
            let bullet = bulletText(line)
            switch section {
            case .also: also.append(bullet ?? line)
            case .points: points.append(bullet ?? line)
            case .example: example.append(bullet ?? line)
            case .headline:
                // Bullets under the answer are its points.
                if let bullet { points.append(bullet); section = .points } else { headline.append(line) }
            case .say:
                // Bullets after what to say are extra points (the older shape).
                if let bullet { also.append(bullet) } else { say.append(line) }
            case .none:
                if let bullet { points.append(bullet) } else { say.append(line) }
            }
        }
        let head = headline.joined(separator: " ")
        let instance = example.joined(separator: " ")
        return SpokenAnswer(say: sentences(say.joined(separator: " ").replacingOccurrences(of: "**", with: "")),
                            also: also.map { $0.replacingOccurrences(of: "**", with: "") }, code: code,
                            headline: head.isEmpty ? nil : head, points: points, example: instance.isEmpty ? nil : instance)
    }

    /// The text after a label that starts the line ("SAY: …", "Answer: …"), or nil.
    private static func label(_ lower: String, _ line: String, _ labels: [String]) -> String? {
        for label in labels where lower.hasPrefix(label) {
            let rest = line.dropFirst(label.count)
            // "Answer" alone, or followed by ":" — not "Answering…" or "Also, we…".
            if label.hasSuffix(":") || rest.isEmpty || rest.hasPrefix(":") {
                return rest.drop { $0 == ":" || $0 == " " }.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "• ", "* ", "– "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot < line.index(line.startIndex, offsetBy: min(3, line.count)),
           line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Text in sentences: a break after ".", "!" or "?" followed by a space (not inside "e.g." or "3.5").
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?".contains(character), index + 1 < characters.count, characters[index + 1] == " " else { continue }
            let word = current.split(separator: " ").last.map(String.init)?.lowercased() ?? ""
            if ["e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "dr.", "approx."].contains(word) { continue }
            let next = characters[(index + 2)...].first { $0 != " " }
            guard let next, next.isUppercase || next.isNumber || "\"“'‘(".contains(next) else { continue }
            out.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// Whether a question is about what's on the screen (a shared slide, chart or page): "what does this chart
    /// show", "on the slide", "can you see my screen", "the numbers here". Then a picture of the meeting goes with it.
    public static func refersToScreen(_ text: String) -> Bool {
        let lower = text.lowercased()
        let things = "slide|slides|chart|graph|diagram|screen|table|figure|deck|dashboard|page|graphic|image|picture|"
            + "spreadsheet|sheet|doc|document|code|numbers|data|plot|visual|mockup|design|presentation|whiteboard"
        let patterns = [
            "\\b(this|that|these|those|the|my|our|your)\\s+(\\w+\\s+)?(\(things))\\b",
            "\\b(on|in)\\s+(the|my|this|your)\\s+screen\\b",
            "\\b(i'?m|we'?re|i am|we are)\\s+shar(ing)\\b",
            "\\bshared\\s+(screen|slide|deck|doc)",
            "\\b(can|do)\\s+you\\s+see\\b",
            "\\b(see|showing|shown|looking at)\\s+(here|now|on)\\b",
            "\\bwhat (do|can) you see\\b",
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// Whether a line carries something worth noting: a few words that aren't call logistics or small talk ("can
    /// you hear me", "you're on mute", "good morning", "let me share my screen", "bye everyone").
    public static func isSubstantive(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 4 else { return false }
        let lower = text.lowercased()
        let chatter = [
            "can you hear me", "can everyone hear", "you're on mute", "you are on mute", "you're muted", "am i audible",
            "is my screen visible", "let me share my screen", "can you see my screen", "one sec", "one second",
            "give me a second", "give me a minute", "good morning", "good afternoon", "good evening", "how are you",
            "how's it going", "nice to meet you", "thanks for joining", "thank you for joining", "bye everyone",
            "see you", "talk soon", "have a good", "sorry, go ahead", "no, go ahead", "you go first", "my internet",
            "my connection", "you're breaking up", "you froze", "let's wait for", "we'll wait for", "few more minutes",
        ]
        guard chatter.contains(where: { lower.contains($0) }) else { return true }
        // Chatter, unless there's more to the line than that ("Good morning, so the release moved to Friday").
        return words.count >= 12
    }

    /// The words of the substantive lines, for telling when enough has been said to update the notes.
    public static func substantiveWords(_ lines: some Collection<MeetingLine>) -> Int {
        lines.filter { isSubstantive($0.text) }.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// The reply that means the notes need no change.
    public static func isNoChange(_ reply: String) -> Bool {
        let bare = reply.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
        return bare == "NO CHANGE" || bare == "NOTHING NEW" || bare.isEmpty
    }

    /// An email the model wrote as "Subject: …" then the body: its subject and body (no subject line: a plain one).
    public static func email(_ text: String) -> (subject: String, body: String) {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        var subject = "Follow-up"
        if let first = lines.first, first.lowercased().hasPrefix("subject:") {
            subject = first.dropFirst("subject:".count).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject.isEmpty ? "Follow-up" : subject, body)
    }

    /// A line worth keeping: speech models write a lone "Thank you." or "." for noise.
    public static func isWorthKeeping(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        let bare = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return !["thank you", "thanks", "you", "bye", "uh", "um", "hmm", "mm"].contains(bare)
    }
}
