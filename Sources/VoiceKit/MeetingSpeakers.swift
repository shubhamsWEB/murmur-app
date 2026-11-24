import Foundation

/// Who said a line, as people see it. `MeetingVoices` keeps raw voice ids (1, 2… in the order a voice was first
/// heard, including a stray cough's); this decides which of them are shown, under which number, and by what name.
///
/// Adapted from Cicada's `SpeakerLabels` and `SpeakerNameGuess` (github.com/wquguru/cicada, Apache-2.0,
/// © wquguru): the five-line rule, the known-voice exception and the evidence check for names. Changed for Murmur:
/// English labels, Devanagari counted like CJK, names from four sources with an order between them.
public enum MeetingSpeakers {
    /// A voice gets a number once it has said this many substantive lines.
    public static let shownAfter = 5

    /// A line long enough to say whose voice it is: three words, or four characters of a script written without
    /// spaces between words. "Yeah." or a stray "." can make a voice of their own; they don't count towards a number.
    public static func substantive(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }
        if words.count >= 3 { return true }
        return text.unicodeScalars.filter { scalar in
            scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7A3).contains(scalar.value) || (0x0900...0x097F).contains(scalar.value)
        }.count >= 4
    }

    /// Voice id → speaker number (1, 2…) for the voices on show. A voice is shown from its `shownAfter`th substantive
    /// line, and only once two voices are, so a one-to-one call stays "Them". `known` voices (remembered, or named by
    /// you) are shown from their first line, and one known voice is enough. Numbers follow the order voices came on
    /// show, so a number never moves once seen.
    public static func numbers(_ lines: [MeetingLine], known: Set<Int> = []) -> [Int: Int] {
        var count: [Int: Int] = [:], reached: [Int: Int] = [:]
        for (index, line) in lines.enumerated() where line.speaker == .them {
            guard let voice = line.voice, reached[voice] == nil else { continue }
            if known.contains(voice) {
                reached[voice] = index
                continue
            }
            guard substantive(line.text) else { continue }
            count[voice, default: 0] += 1
            if count[voice] == shownAfter { reached[voice] = index }
        }
        let shown = reached.keys.sorted { reached[$0]! < reached[$1]! }
        guard shown.count >= 2 || shown.contains(where: known.contains) else { return [:] }
        return Dictionary(uniqueKeysWithValues: shown.enumerated().map { ($1, $0 + 1) })
    }

    /// The other side's only voice in a one-to-one call (numbers hide it, but you still need to be able to name it).
    /// A breath or click can make a second one-line voice: the one voice with substantive speech still counts.
    public static func singleVoice(_ lines: [MeetingLine]) -> Int? {
        let them = lines.filter { $0.speaker == .them }
        let voices = Set(them.compactMap(\.voice))
        if voices.count == 1 { return voices.first }
        let talking = Set(them.filter { substantive($0.text) }.compactMap(\.voice))
        return talking.count == 1 ? talking.first : nil
    }

    /// The voices shown from their first line: those with a name that came from you or from the voice library. A
    /// conversation's or window's guess isn't enough by itself (it is only shown once the voice has a number).
    public static func known(_ names: [Int: VoiceName], lines: [MeetingLine]) -> Set<Int> {
        var known = Set(names.filter { $0.value.source == .library || ($0.value.source == .user && !$0.value.name.isEmpty) }
            .map(\.key))
        // A one-to-one caller you named is shown under that name, though it never gets a number.
        if let only = singleVoice(lines), let name = names[only], !name.name.isEmpty { known.insert(only) }
        return known
    }

    /// What a line's speaker is shown as: "You", a name, "Speaker 2", or "Them". A name shows on a voice that's on
    /// show, or on `single`, a one-to-one call's only voice.
    public static func label(_ line: MeetingLine, numbers: [Int: Int], names: [Int: VoiceName],
                             single: Int? = nil) -> String {
        guard line.speaker == .them else { return "You" }
        guard let voice = line.voice else { return "Them" }
        if let name = names[voice], !name.name.isEmpty, numbers[voice] != nil || single == voice { return name.name }
        if let number = numbers[voice] { return "Speaker \(number)" }
        return "Them"
    }
}

/// A name given to a voice, and where it came from. Higher sources win: you, then the voice library, then the meeting
/// app's window, then the conversation.
public struct VoiceName: Equatable, Sendable, Codable {
    public enum Source: String, Sendable, Codable, Comparable {
        case conversation, window, library, user

        var rank: Int { [.conversation: 0, .window: 1, .library: 2, .user: 3][self]! }
        public static func < (a: Source, b: Source) -> Bool { a.rank < b.rank }
    }

    /// Empty from `.user`: you said it isn't the guessed person ("Not them"); the voice shows as Speaker N.
    public var name: String
    public var source: Source
    /// Why: the line a conversation name came from ("03:21 “Thanks, Priya…”"), or the library match's score.
    public var evidence: String?

    public init(name: String, source: Source, evidence: String? = nil) {
        self.name = name
        self.source = source
        self.evidence = evidence
    }

    /// `new` takes `old`'s place unless `old` came from a higher source.
    public static func merge(_ old: VoiceName?, _ new: VoiceName) -> VoiceName {
        guard let old, new.source < old.source else { return new }
        return old
    }
}

/// Names from the conversation. The meeting's AI reads the labelled transcript and reports two things: people who
/// say their own name ("Hi, I'm Priya"), and the names of the people taking part. Only the first is ever put on a
/// voice, and only when the line really is that voice's and really says it (`introduces`). The rest are offered when
/// you name someone, spelled right, and nothing more.
///
/// Why so little: in a meeting, a name that's spoken is nearly always someone else's ("Ryan, what do you think?",
/// "as Daniel said", a host reading out the guests). Giving it to the voice that speaks nearby, as Murmur did and
/// Cicada does, named three people on a five-person panel and got all three wrong. A wrong name is worse than
/// "Speaker 2": it goes into the notes, and into the voice library if you save it.
public enum MeetingNameGuess {
    /// The newest lines the AI reads.
    public static let window = 400

    public static let instruction = """
        Two things about the people in this meeting transcript. \
        "speakers": people labelled "Speaker N" who say their own name on a line with their own label ("Hi, I'm \
        Priya", "My name is Raj", "This is Emma from Acme"). Only that: someone being addressed, mentioned, thanked \
        or introduced by another person is not it, however clear it seems who they are. \
        "people": the names of the people who are taking part in the meeting, as far as what's said shows it \
        (addressed, introduced as present, or introducing themselves); not people only talked about. Speech \
        recognition writes names by ear and often misspells them: when a list of the people in the call is given, \
        use its spelling; for a public figure recognisable from the name and what is said, write the name as the \
        news spells it; otherwise as written. Leave out anyone you are unsure of. Reply with only this JSON: \
        {"speakers": [{"speaker": 2, "name": "Priya", "evidence": "L12"}], "people": ["Priya", "Raj Mehta"]}, the \
        evidence being the line where they say their name; empty lists if none.
        """

    /// "03:21" for `at` in a meeting that started at `start`.
    public static func clock(_ at: Date, from start: Date) -> String {
        let seconds = max(0, Int(at.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// The transcript as the AI reads it: the newest `window` lines, "[L12 03:41 Speaker 2] text". nil when no voice
    /// is on show (nothing to name), or every voice on show already has a name you gave it.
    public static func content(_ lines: [MeetingLine], numbers: [Int: Int], names: [Int: VoiceName],
                               start: Date, roster: [String] = []) -> String? {
        guard !numbers.isEmpty else { return nil }
        if numbers.keys.allSatisfy({ names[$0]?.source == .user || names[$0]?.source == .library }) { return nil }
        var out = "Meeting transcript. Speakers: You = the user; Speaker N = one person on the other side, told apart "
            + "by voice; Them = someone on the other side, not identified.\n"
        if !roster.isEmpty { out += "People in this call (from the meeting app): \(roster.joined(separator: ", ")).\n" }
        for (index, line) in lines.suffix(window).enumerated() {
            let who = line.speaker == .you ? "You" : line.voice.flatMap { numbers[$0] }.map { "Speaker \($0)" } ?? "Them"
            out += "[L\(index + 1) \(clock(line.at, from: start)) \(who)] \(line.text)\n"
        }
        return out
    }

    /// The names in the AI's reply that hold, by voice id, and those that don't (`refuted`: to be dropped, an
    /// earlier copy too): a name holds when its evidence line is that voice's own and says it (`introduces`). A name
    /// given to two voices goes to the one with more lines.
    public static func read(_ reply: String, lines all: [MeetingLine], numbers: [Int: Int],
                            start: Date) -> (found: [Int: VoiceName], refuted: [Int: String]) {
        guard let object = jsonObject(reply), let list = object["speakers"] as? [[String: Any]] else { return ([:], [:]) }
        let voiceOf = Dictionary(uniqueKeysWithValues: numbers.map { ($1, $0) })
        let lines = Array(all.suffix(window))
        func spoken(_ voice: Int) -> Int { all.filter { $0.voice == voice }.count }
        var found: [Int: VoiceName] = [:], refuted: [Int: String] = [:]
        for item in list {
            guard let number = (item["speaker"] as? Int) ?? Int("\(item["speaker"] ?? "")".filter(\.isNumber)),
                  let voice = voiceOf[number],
                  let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 40 else { continue }
            // "L52" or "L52, L53": the first line named.
            let evidence = (item["evidence"] as? String) ?? "\(item["evidence"] ?? "")"
            guard let index = Int(String(evidence.drop(while: { !$0.isNumber }).prefix(while: \.isNumber))).map({ $0 - 1 }),
                  lines.indices.contains(index), lines[index].speaker == .them, lines[index].voice == voice,
                  introduces(lines[index].text, name) else {
                refuted[voice] = name
                continue
            }
            if let other = found.first(where: { $0.value.name.caseInsensitiveCompare(name) == .orderedSame })?.key {
                if spoken(other) >= spoken(voice) { continue }
                found[other] = nil
            }
            let line = lines[index]
            let quote = line.text.count > 60 ? String(line.text.prefix(60)) + "…" : line.text
            found[voice] = VoiceName(name: name, source: .conversation,
                                     evidence: "\(clock(line.at, from: start)) “\(quote)”")
        }
        return (found, refuted)
    }

    /// The people the AI says are taking part ("people"), for offering when you name a voice: trimmed, no repeats.
    public static func people(_ reply: String) -> [String] {
        guard let object = jsonObject(reply), let list = object["people"] as? [Any] else { return [] }
        var out: [String] = []
        for item in list {
            guard let name = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  name.count <= 40, !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            out.append(name)
        }
        return Array(out.prefix(12))
    }

    /// Words that come before your own name when you say who you are.
    static let openers: [[String]] = [
        ["i'm"], ["i", "am"], ["my", "name", "is"], ["my", "name's"], ["myself"], ["this", "is"],
        ["mera", "naam"], ["मेरा", "नाम"], ["मैं"], ["main"], ["je", "m'appelle"], ["me", "llamo"], ["ich", "bin"],
        ["ich", "heiße"], ["mi", "chiamo"],
    ]
    /// "This is Priya" can be someone else being introduced: it counts only as "This is Priya from…/here/speaking".
    static let afterThisIs: Set<String> = ["from", "here", "speaking", "calling", "with", "at"]

    /// Whether `text` has its speaker saying their own name: an opener ("I'm", "my name is"…), then the name as the
    /// speech model wrote it (which can be a letter or two off the real spelling).
    public static func introduces(_ text: String, _ name: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        guard let wanted = name.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init),
              wanted.count >= 2 else { return false }
        for start in words.indices {
            for opener in openers where words[start...].starts(with: opener) {
                // Straight after it ("I'm, uh, Priya" too): "I'm with Priya on this" isn't an introduction.
                var after = start + opener.count
                while after < words.count, ["uh", "um", "er", "like"].contains(words[after]) { after += 1 }
                guard after < words.count else { continue }
                for at in after...after where !words[at].hasSuffix("'s") && alike(words[at], wanted) {
                    if opener == ["this", "is"] {
                        // The word after the name (first and last name skipped over).
                        let next = words[(at + 1)...].prefix(2)
                        guard next.contains(where: afterThisIs.contains) else { continue }
                    }
                    return true
                }
            }
        }
        return false
    }

    /// The same name allowing for how speech models spell ("Jamie" for Jaime, "Rhea" for Ria): the same first
    /// letter and at most two letters different (one in a three-letter name).
    static func alike(_ heard: String, _ name: String) -> Bool {
        if heard == name { return true }
        let shorter = min(heard.count, name.count)
        guard heard.first == name.first, shorter >= 3 else { return false }
        return distance(Array(heard), Array(name)) <= (shorter >= 4 ? 2 : 1)
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(previous + (x == y ? 0 : 1), row[j] + 1, above + 1)
                previous = above
            }
        }
        return row[b.count]
    }

    /// Whether an earlier conversation name still stands by the same rule: its evidence line is found again, and is
    /// still that voice's (lines move between voices as more is heard). Kept when the line can't be found (it may
    /// have scrolled out of the window).
    public static func holds(_ name: VoiceName, voice: Int, in lines: [MeetingLine], start: Date) -> Bool {
        guard name.source == .conversation, let evidence = name.evidence, let open = evidence.firstIndex(of: "“") else {
            return true
        }
        let clock = evidence[..<open].trimmingCharacters(in: .whitespaces)
        let quote = String(evidence[evidence.index(after: open)...].dropLast().prefix(while: { $0 != "…" }))
        guard let index = lines.firstIndex(where: { self.clock($0.at, from: start) == clock && $0.text.hasPrefix(quote) })
        else { return true }
        return lines[index].voice == voice && introduces(lines[index].text, name.name)
    }

    /// The JSON object in a reply: a fence or a sentence around it is fine.
    static func jsonObject(_ reply: String) -> [String: Any]? {
        guard let a = reply.firstIndex(of: "{"), let b = reply.lastIndex(of: "}"), a < b,
              let data = String(reply[a...b]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
