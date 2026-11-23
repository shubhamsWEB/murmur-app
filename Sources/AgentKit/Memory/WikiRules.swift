import Foundation

/// How a page of the wiki is written and checked, with no storage or I/O (`Wiki` keeps pages; `WikiWriter` runs the
/// model). A page is what Murmur knows about one person, project, organization, place or topic, kept as short claims:
///
/// - each claim cites the numbered evidence it was read from (a memory, an episode of work, a window, a connection);
///   one that cites nothing, or whose words, names and numbers aren't in what it cites, is dropped;
/// - each says whose it is (the user's own, the subject's, or someone else's), how it's known (the user did it, said
///   it, it was seen, or it's a guess), and whether it's worth keeping (core, detail; noise is dropped);
/// - it's worded as weakly as the evidence allows ("you and Priya messaged about the launch on 4 Nov", not "Priya is
///   your collaborator"), with dates for what changes;
/// - other pages it touches are linked as [[Name]], only to names memory holds.
///
/// A rewrite doesn't delete: a claim the new page leaves out is marked no longer true (`Wiki.save`), so what was true
/// in June can still be answered.
public enum WikiRules {
    /// One numbered piece of evidence: what it is, when, its text, and where it came from ("memory:12", "episode:84").
    public struct Evidence: Sendable, Equatable {
        public var label: String
        public var when: Date?
        public var text: String
        public var source: String

        public init(label: String, when: Date?, text: String, source: String) {
            self.label = label
            self.when = when
            self.text = text
            self.source = source
        }
    }

    /// A claim as written for a page, before it's kept.
    public struct Draft: Sendable, Equatable {
        public var text: String
        /// "user", "thing" or "other".
        public var whose: String
        /// "did", "said", "seen" or "guess".
        public var basis: String
        /// "core" or "detail".
        public var worth: String
        /// Where it came from: the sources of the evidence it cites ("memory:12"), or "page" for a claim kept as it was.
        public var sources: [String]

        /// Only the user does or says: a claim about someone else, or the subject, was seen (or guessed).
        var consistent: Draft {
            var draft = self
            if whose != "user", basis == "did" || basis == "said" { draft.basis = "seen" }
            return draft
        }

        public init(text: String, whose: String, basis: String, worth: String, sources: [String]) {
            self.text = text
            self.whose = whose
            self.basis = basis
            self.worth = worth
            self.sources = sources
        }
    }

    /// What one rewrite came to: the page's line, its claims, the pages it links, and how many claims were left out
    /// because their evidence didn't hold them.
    public struct Written: Sendable, Equatable {
        public var summary: String
        public var claims: [Draft]
        public var links: [String]
        public var unsupported: Int
    }

    /// The most claims a page keeps, and the most evidence one rewrite reads.
    public static let maxClaims = 10
    public static let maxEvidence = 14

    // MARK: Asking

    public static func system() -> String {
        """
        You keep one page of a person's private memory: what is known about one person, project, organization, place \
        or topic in their life. Rewrite the page from the numbered evidence and the existing page, as JSON:
        {"summary": "...", "claims": [{"text": "...", "whose": "user", "basis": "did", "worth": "core", "sources": [1, 3]}]}

        Each claim is one fact in one sentence of at most 25 words, and lists the numbers of the evidence that shows it. \
        A claim without a number is thrown away. To keep a claim of the existing page as it is, copy it word for word \
        and give sources [0].
        - whose: "user" when it is about the user (what they did, decided, own or plan), "thing" when it is about the \
        page's subject itself, "other" when it is about someone else.
        - basis: "did" when the user did it (sent, built, booked, released, met), "said" when the user wrote or told \
        it, "seen" when it was on screen or came from a source, "guess" when it is an inference, and then the claim \
        says "likely".
        - Use the weakest wording that is still true, and keep every name, date and number: "You and Priya messaged \
        about the launch on 4 Nov" rather than "Priya is your collaborator". A role, an employer or a relationship \
        only when the evidence says so.
        - Reading about something is not using it, and seeing a page is not owning it.
        - Things that change get the date the evidence gives them ("as of 4 Nov 2026"); never "recently" or \
        "currently".
        - When newer evidence says something different from the existing page, leave the old claim out.
        - worth: "core" for what someone helping the user must know, "detail" for useful colour, "noise" for menus, \
        adverts, a site's own pages and lists of features.
        - Write a name from KNOWN NAMES as [[Name]] where a claim mentions it.
        - At most 10 claims, fewer when there is little evidence. The summary is one line of at most 140 characters \
        saying what this is to the user.
        JSON only.
        """
    }

    /// The evidence as the model reads it: the page, today, the names it may link, the claims it has, and each piece
    /// of evidence numbered from 1, oldest first.
    public static func prompt(title: String, kind: String, aliases: [String], existing: [String], evidence: [Evidence],
                              known: [String], today: Date, calendar: Calendar = .current) -> String {
        let day = formatter("EEE d MMM yyyy", calendar)
        var lines = ["PAGE: \(title) (\(kind))" + (aliases.isEmpty ? "" : "; also called " + aliases.prefix(4).joined(separator: ", ")),
                     "TODAY: " + day.string(from: today)]
        if !known.isEmpty { lines.append("KNOWN NAMES: " + known.prefix(40).joined(separator: ", ")) }
        lines.append("EXISTING PAGE:")
        lines += existing.isEmpty ? ["(new page)"] : existing.prefix(maxClaims + 2).map { "- " + $0 }
        lines.append("EVIDENCE:")
        for (index, item) in evidence.prefix(maxEvidence).enumerated() {
            let when = item.when.map { ", " + day.string(from: $0) } ?? ""
            lines.append("[\(index + 1)] (\(item.label)\(when)) " + item.text.replacingOccurrences(of: "\n", with: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// The JSON schema a local model is held to.
    public static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "claims": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"], "whose": ["type": "string"], "basis": ["type": "string"],
                        "worth": ["type": "string"], "sources": ["type": "array", "items": ["type": "integer"]],
                    ],
                    "required": ["text", "sources"],
                ],
            ],
        ],
        "required": ["summary", "claims"],
    ]

    // MARK: The user, as the user

    /// Text about the user without the user as someone they worked with: a model reading their screen (where Claude
    /// and their chats call them by name) writes "with Claude and Shubham" and "with Shubham", as if Shubham were
    /// another person. Their names come out of "with…" ("with Claude"), and "Shubham's" is "your".
    public static func withoutSelf(_ text: String, me names: [String]) -> String {
        let names = names.filter { $0.count >= 3 && !["you", "me"].contains($0.lowercased()) }.sorted { $0.count > $1.count }
        guard !names.isEmpty, !text.isEmpty else { return text }
        let name = "(?:" + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
        var out = text
        for (pattern, template) in [
            (#"(?i)\b(with|alongside)\s+\#(name)\s+and\s+"#, "$1 "),                    // "with Shubham and Roma" → "with Roma"
            (#"(?i)(?:,\s*|\s+and\s+)\#(name)\b(?!')"#, ""),                          // "with Claude and Shubham" → "with Claude"
            (#"(?i)\s+(?:with|alongside|together with)\s+\#(name)\b(?!')"#, ""),       // "… with Shubham" → "…"
            (#"\b\#(name)'s\b"#, "your"),
        ] {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out.replacingOccurrences(of: #"\s+([,.;])"#, with: "$1", options: .regularExpression)
    }

    // MARK: Checking

    /// The JSON object in an answer; when the answer was cut off (out of tokens), the part of it that was finished:
    /// up to the last value that closed, with what was still open closed after it.
    static func jsonObject(in answer: String) -> [String: Any]? {
        func parse(_ text: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        guard let start = answer.firstIndex(of: "{") else { return nil }
        if let end = answer.lastIndex(of: "}"), start < end, let object = parse(String(answer[start...end])) { return object }
        let text = Array(answer[start...])
        var open: [Character] = [], inString = false, escaped = false
        var cuts: [(end: Int, open: [Character])] = []
        for (index, character) in text.enumerated() {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{", "[": open.append(character)
            case "}", "]":
                guard !open.isEmpty else { return nil }
                open.removeLast()
                if !open.isEmpty { cuts.append((index, open)) }
            default: break
            }
        }
        for cut in cuts.reversed().prefix(30) {
            let closers = cut.open.reversed().map { $0 == "{" ? "}" : "]" }.joined()
            if let object = parse(String(text[...cut.end]) + closers) { return object }
        }
        return nil
    }

    /// What the model wrote, kept only where the evidence holds it: noise out; a claim citing nothing, or citing
    /// numbers that aren't there, out; a claim kept "as it was" that isn't on the page, out; a claim whose words or
    /// numbers aren't in what it cites, out; links only to names memory holds; the same claim once.
    public static func check(_ content: String, title: String, aliases: [String] = [], existing: [String],
                             evidence: [Evidence], known: [String]) -> Written? {
        guard let object = jsonObject(in: ModelOutput.answer(content)) else { return nil }
        let list = object["claims"] as? [[String: Any]] ?? []
        let usable = Array(evidence.prefix(maxEvidence))
        let names = Set(([title] + aliases).flatMap { words($0) })
        let knownByKey = Dictionary(known.map { (BrainModel.nameKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(existing.map(normal))
        var claims: [Draft] = [], unsupported = 0, links: [String] = [], seen: [Set<String>] = []
        for entry in list.prefix(maxClaims * 2) {
            var text = (entry["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let worth = (entry["worth"] as? String ?? "detail").lowercased()
            guard !text.isEmpty, worth != "noise", text.count <= 260, !BrainModel.hasSecret(text) else { continue }
            let numbers = (entry["sources"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
            // Links: [[Priya Shah]] stays when memory knows the name (spelled as memory has it); otherwise plain words.
            text = relink(text, known: knownByKey, linked: &links)
            // A known name written plainly is linked too (a small model seldom links).
            text = autolink(text, known: known, linked: &links)
            let plain = unlinked(text)
            // A claim of the existing page, word for word, stays as it was whatever it cites (a small model cites the
            // newest evidence for it, which would drop it, and a dropped claim would be marked no longer true).
            let onPage = kept.contains(normal(plain)) || kept.contains(normal(text))
            if onPage || numbers == [0] || (numbers.contains(0) && numbers.allSatisfy { $0 == 0 }) {
                guard onPage else { unsupported += 1; continue }
                claims.append(Draft(text: text, whose: whose(entry), basis: basis(entry, text: plain),
                                    worth: worth == "core" ? "core" : "detail", sources: ["page"]).consistent)
                continue
            }
            let cited = numbers.filter { $0 >= 1 && $0 <= usable.count }
            guard !cited.isEmpty else { unsupported += 1; continue }
            // What it cites, with the dates the evidence was shown with ("Thu 12 Nov 2026"): a claim may date itself
            // from them.
            let source = cited.map { index -> String in
                let item = usable[index - 1]
                let when = item.when.map { [Self.formatter("EEE d MMM yyyy", .current).string(from: $0),
                                            Self.formatter("yyyy-MM-dd", .current).string(from: $0)].joined(separator: " ") } ?? ""
                return item.text + " " + item.label + " " + when
            }.joined(separator: "\n")
            guard holds(source, plain, ignoring: names) else { unsupported += 1; continue }
            let key = BrainModel.keywords(plain)
            if seen.contains(where: { BrainModel.similarity($0, key) >= 0.8 }) { continue }
            seen.append(key)
            claims.append(Draft(text: text, whose: whose(entry), basis: basis(entry, text: plain),
                                worth: worth == "core" ? "core" : "detail",
                                sources: unique(cited.map { usable[$0 - 1].source })).consistent)
            if claims.count >= maxClaims { break }
        }
        var summary = BrainModel.redact((object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        summary = unlinked(summary)
        if summary.count > 160 { summary = String(summary.prefix(157)) + "…" }
        guard !claims.isEmpty else {
            return unsupported > 0 || !list.isEmpty ? Written(summary: "", claims: [], links: [], unsupported: unsupported) : nil
        }
        // The summary has to be about what the claims hold: one with words none of them has is the model's own.
        let claimWords = claims.reduce(into: Set<String>()) { $0.formUnion(BrainModel.keywords(unlinked($1.text))) }
        let everything = claimWords.joined(separator: " ") + " " + evidence.map(\.text).joined(separator: " ") + " " + existing.joined(separator: " ")
        if !summary.isEmpty, !holds(everything, summary, ignoring: names) {
            summary = ""
        }
        return Written(summary: summary, claims: claims, links: unique(links),
                       unsupported: unsupported)
    }

    /// Whether `source` holds what `claim` says: most of its content words (by the start of each word: "released"
    /// holds "release"), and every number in it (a version, a day, an amount).
    static func holds(_ source: String, _ claim: String, ignoring names: Set<String>) -> Bool {
        let present = words(source)
        let content = words(claim).subtracting(names).subtracting(glue).filter { $0.count >= 3 }
        if !content.isEmpty {
            let found = content.filter { word in present.contains(word) || present.contains { $0.hasPrefix(String(word.prefix(5))) } }
            guard Double(found.count) / Double(content.count) >= 0.5 else { return false }
        }
        let haystack = source.lowercased()
        for number in numbers(in: claim) where !haystack.contains(number) {
            // "4 Nov 2026" written from "2026-11-04": the day and the year are each in the source.
            guard number.count <= 2 || number.count == 4, haystack.range(of: #"\b0?\#(number)\b"#, options: .regularExpression) != nil
            else { return false }
        }
        return true
    }

    /// Numbers a claim states: "1.7.0", "6E", "2026", "45".
    static func numbers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:[.:,]\d+)*"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        }
    }

    /// The same values once, in order.
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func words(_ text: String) -> Set<String> {
        Set(BrainModel.keywords(unlinked(text)).map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 })
    }

    /// Words any claim may use without the evidence having them.
    static let glue: Set<String> = ["user", "user's", "you", "your", "yours", "also", "likely", "probably", "about", "with",
                                    "from", "this", "that", "they", "their", "them", "has", "have", "had", "was", "were",
                                    "will", "would", "and", "the", "for", "into", "onto", "over", "after", "before", "as",
                                    "of", "on", "messaged", "message", "messages", "exchanged", "talked", "discussed",
                                    "worked", "work", "working", "page", "date", "dated"]

    static func whose(_ entry: [String: Any]) -> String {
        let value = (entry["whose"] as? String ?? entry["subject"] as? String ?? "").lowercased()
        switch value {
        case "user", "me", "you": return "user"
        case "other", "third_party", "someone": return "other"
        default: return "thing"
        }
    }

    /// How it's known; a "guess" that doesn't say so is said as one.
    static func basis(_ entry: [String: Any], text: String) -> String {
        let value = (entry["basis"] as? String ?? "").lowercased()
        switch value {
        case "did", "observed_action": return "did"
        case "said", "user_stated", "told": return "said"
        case "guess", "inferred": return "guess"
        default: return "seen"
        }
    }

    /// A claim as compared: lowercase, links and punctuation gone, spaces single.
    static func normal(_ text: String) -> String {
        let plain = unlinked(text).lowercased()
        return String(String.UnicodeScalarView(plain.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? $0 : " "
        })).split(separator: " ").joined(separator: " ")
    }

    /// "[[Priya Shah]] reviewed it" → "Priya Shah reviewed it".
    public static func unlinked(_ text: String) -> String {
        text.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
    }

    /// Links kept only to names memory holds, spelled as memory has them; the rest become plain words.
    static func relink(_ text: String, known: [String: String], linked: inout [String]) -> String {
        // A link that's only part of a word ("[[Sudoku]]-V2") is no link.
        let text = text.replacingOccurrences(of: #"(?<=[\w-])\[\[([^\[\]]{1,80})\]\]|\[\[([^\[\]]{1,80})\]\](?=[\w-])"#,
                                             with: "$1$2", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\[\]]{1,80})\]\]"#) else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: out), let inner = Range(match.range(at: 1), in: out) else { continue }
            let name = String(out[inner])
            if let real = known[BrainModel.nameKey(name)] {
                out.replaceSubrange(whole, with: "[[\(real)]]")
                linked.append(real)
            } else {
                out.replaceSubrange(whole, with: name)
            }
        }
        return out
    }

    /// The first plain mention of each known name, as a link: "agreed with Rahul Mehta" → "agreed with [[Rahul Mehta]]".
    /// The longest names first, so "Acme Launch" wins over "Acme"; never inside a link already there.
    static func autolink(_ text: String, known: [String], linked: inout [String]) -> String {
        var out = text
        for name in known.filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let regex = try? NSRegularExpression(pattern: #"(?<![\[\w-])"# + escaped + #"(?![\]\w-])"#, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                  let range = Range(match.range, in: out) else { continue }
            // Not inside [[…]] already.
            let before = out[..<range.lowerBound]
            if let open = before.range(of: "[[", options: .backwards), before[open.upperBound...].range(of: "]]") == nil { continue }
            out.replaceSubrange(range, with: "[[\(name)]]")
            linked.append(name)
        }
        return out
    }

    // MARK: Showing

    /// A page as text, for a model or the user: its line, then its claims (the core ones first), each with how it's
    /// known and, for the sources, where to open them.
    public static func render(title: String, kind: String, summary: String, claims: [(text: String, basis: String, worth: String, sources: [String])],
                              updated: Date?, sources: Bool, calendar: Calendar = .current) -> String {
        var lines = ["\(title) (\(kind))" + (summary.isEmpty ? "" : ": \(summary)")]
        let ordered = claims.filter { $0.worth == "core" } + claims.filter { $0.worth != "core" }
        for claim in ordered {
            let how = ["did": "you did", "said": "you said", "guess": "a guess", "seen": "seen"][claim.basis] ?? "seen"
            let from = sources && !claim.sources.isEmpty ? "; " + claim.sources.joined(separator: ", ") : ""
            lines.append("- \(claim.text) (\(how)\(from))")
        }
        if let updated { lines.append("(page updated " + formatter("d MMM yyyy", calendar).string(from: updated) + ")") }
        return lines.joined(separator: "\n")
    }

    static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
