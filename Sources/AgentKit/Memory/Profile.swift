import Foundation

/// Who the user is and what's going on for them, written by the model that reads memory and kept beside it
/// (brain.sqlite, table `profile`):
///
/// - profile: who they are, refreshed every fourteen days from the last two weeks' days and what they wrote: their role
///   and focus, their tools, their habits, what they're interested in, and how they write. The last one keeps what
///   still holds and changes only what new evidence contradicts or sharpens.
/// - digest: at most about 350 words of what's current, rewritten each day from the last week's days, the pages that
///   matter most and what's open: what they're focused on, their projects, the people around them, decisions and
///   promises, and preferences, each dated. It's put into every command Murmur answers, so Murmur starts from what it
///   knows instead of from nothing.
///
/// Nothing in either comes from anywhere but memory: a line of the digest with a date or number that's in none of its
/// inputs is dropped.
public final class Profile: @unchecked Sendable {
    let db: SQLiteConnection
    /// The app's own, for putting the digest into commands.
    public static let shared = Profile()

    public init(url: URL = BrainStore.defaultURL) {
        db = SQLiteConnection(url: url)
        db.exec("""
            CREATE TABLE IF NOT EXISTS profile(key TEXT PRIMARY KEY, text TEXT NOT NULL, generated REAL NOT NULL,
              model TEXT NOT NULL DEFAULT '', basis TEXT NOT NULL DEFAULT '')
            """)
    }

    public func text(_ key: String) -> (text: String, generated: Date)? {
        db.rows("SELECT text, generated FROM profile WHERE key = ?", [key]).first.map {
            ($0[0], Date(timeIntervalSince1970: Double($0[1]) ?? 0))
        }
    }

    public func set(_ key: String, _ text: String, model: String, basis: String = "", now: Date = Date()) {
        db.exec("""
            INSERT INTO profile(key, text, generated, model, basis) VALUES(?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET text = excluded.text, generated = excluded.generated, model = excluded.model,
              basis = excluded.basis
            """, [key, text, now.timeIntervalSince1970, model, basis])
    }

    public func forgetAll() { db.exec("DELETE FROM profile") }

    /// The digest as it goes into a command: dated, and nothing when it's more than three days old.
    public func digestForPrompt(now: Date = Date(), limit: Int = 2200) -> String? {
        guard let digest = text("digest"), now.timeIntervalSince(digest.generated) < 3 * 86400, !digest.text.isEmpty else { return nil }
        let day = ProfileRules.day(digest.generated)
        return "As of \(day):\n" + String(digest.text.prefix(limit))
    }
}

/// How the profile and the digest are asked for and checked, with no storage or I/O.
public enum ProfileRules {
    public static let profileEvery: TimeInterval = 14 * 86400

    // MARK: Profile

    public static func profileSystem(existing: Bool) -> String {
        let base = """
            Write a profile of one person from the activity their computer recorded over the last two weeks, for an \
            assistant that helps them. Be specific or say nothing: name the projects, people, tools and sites that \
            appear; leave out generic phrases like "works on software" and anything the evidence doesn't show. Ignore \
            time spent in Murmur itself. Second person ("You…"), markdown, with these headings, each only when there is \
            evidence for it:
            ### Role and focus
            Two sentences at most: what they do day to day now, and the one to three projects that are active.
            ### Tools
            Two sentences at most: the tools, languages, platforms and sites they actually use.
            ### Habits
            Two sentences: when they work, how long their focus lasts, what pulls them away. Only patterns seen on \
            several different days.
            ### Interests
            One sentence, only for a topic they return to on at least three different days.
            ### How you write
            Up to four sentences, only from what they wrote and sent: tone, length, punctuation, greetings, how they \
            sound in chat and in email. Quote one short phrase of theirs in backticks.
            """
        return existing ? base + """


            You are given the profile written last time. Keep what still holds, word for word; change only what the new \
            evidence contradicts or sharpens; drop projects and tools that no longer appear. Reply with the whole \
            profile only.
            """ : base + "\n\nReply with the profile only."
    }

    public static func profilePrompt(existing: String?, days: [(period: String, summary: String)], written: [String],
                                     names: [String]) -> String {
        var lines: [String] = []
        if !names.isEmpty { lines.append("THEIR NAME: " + names.joined(separator: ", ")) }
        if let existing, !existing.isEmpty { lines += ["PROFILE WRITTEN LAST TIME:", existing, ""] }
        lines.append("THEIR DAYS (summaries, oldest first):")
        lines += days.map { "\($0.period): \($0.summary)" }
        if !written.isEmpty {
            lines += ["", "WHAT THEY WROTE AND SENT (their own words):"]
            lines += written.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }
        } else {
            lines += ["", "(Nothing they wrote is given: leave out \"How you write\". The days above are Murmur's summaries, "
                      + "not their writing.)"]
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Digest

    public static func digestSystem(today: Date) -> String {
        """
        Write a short memory digest for an assistant that will read it before every request from this person. It is \
        rewritten from scratch each day from what's below: today is \(day(today)). Second person ("You…"), markdown, \
        with these headings, each only when there is something under it:
        ### Now
        ### Projects
        ### People
        ### Decisions and promises
        ### Preferences
        Rules: a dash per fact, short. Put the date on anything that can change ("[18 Nov] Released Murmur 1.8.0"), \
        never "recently" or "currently". A promise under STILL OPEN is not done: write it as still to do ("Send…", \
        not "Sent…"), and overdue only when the inputs mark it overdue. When the \
        inputs show something changed, keep only the newest. Leave out what is finished or no longer matters. Names, \
        versions and deadlines, not generalities. Facts only: never advice or instructions ("prepare…", "make \
        sure…", "continue…"). Preferences only when the inputs say the user prefers something. At most 350 words. \
        Reply with the digest only.
        """
    }

    public static func digestPrompt(days: [(period: String, summary: String)], pages: [String], open: [String],
                                    today: Date? = nil) -> String {
        var lines = today.map { ["TODAY: " + day($0), ""] } ?? []
        lines.append("THE LAST DAYS (newest last):")
        lines += days.map { "\($0.period): \($0.summary)" }
        if !pages.isEmpty {
            lines += ["", "WHAT MEMORY KNOWS (the pages that matter most):"]
            lines += pages
        }
        if !open.isEmpty {
            lines += ["", "STILL OPEN (not done yet):"]
            lines += open.map { "- " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    /// The digest as kept: secrets out, at most `words` words, and a line whose dates or numbers are in none of the
    /// inputs dropped (the model's own).
    public static func checkDigest(_ content: String, inputs: String, me: [String] = [], words limit: Int = 380,
                                   perSection: Int = 6) -> String {
        let mine = Set(me.map { $0.lowercased() }.filter { $0.count >= 3 })
        var answer = BrainModel.redact(ModelOutput.answer(content)).trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = CloudReader.cutOff.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.hasSuffix(marker) { answer = unfinishedEndRemoved(String(answer.dropLast(marker.count))) }
        let haystack = inputs.lowercased()
        var kept: [String] = [], count = 0, heading = "", bullets = false
        var said: [Set<String>] = [], inSection = 0
        for raw in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { heading = line.lowercased(); bullets = false; inSection = 0 }
            if line.hasPrefix("#") || line.isEmpty { kept.append(line); continue }
            let bullet = line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
            // A piece of a line that broke ("(US) DUNS request." under the bullets) says nothing alone.
            if !bullet, bullets { continue }
            bullets = bullets || bullet
            // The user isn't one of their own people.
            if heading.contains("people"), let who = line.drop(while: { "-*• ".contains($0) }).split(separator: ":").first,
               mine.contains(String(who).trimmingCharacters(in: CharacterSet(charactersIn: "*_ ")).lowercased()) { continue }
            // Under Preferences, only what says a preference (a small model files anything there).
            if heading.contains("preference"), !statesPreference(line) { continue }
            let numbers = WikiRules.numbers(in: line).filter { $0.count >= 2 }
            let invented = numbers.contains { number in
                !haystack.contains(number) && haystack.range(of: #"\b0?\#(number)\b"#, options: .regularExpression) == nil
            }
            if invented { continue }
            let fact = withoutAdvice(line)
            if fact.isEmpty || fact == "-" || isFiller(fact) { continue }
            let key = BrainModel.keywords(WikiRules.unlinked(fact))
            if said.contains(where: { BrainModel.similarity($0, key) >= 0.6 }) { continue }
            if inSection >= perSection { continue }
            said.append(key)
            inSection += 1
            let length = fact.split(separator: " ").count
            guard count + length <= limit else { break }
            count += length
            kept.append(fact)
        }
        // Headings left with nothing under them go.
        var out: [String] = []
        for (index, line) in kept.enumerated() {
            if line.hasPrefix("#") {
                let next = kept[(index + 1)...].first { !$0.isEmpty }
                if next == nil || next?.hasPrefix("#") == true { continue }
            }
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words that start advice, not a fact ("Prepare for the meeting", "Make sure…").
    static let advice: Set<String> = ["prepare", "ensure", "continue", "prioritise", "prioritize", "confirm", "await",
                                      "focus", "remember", "consider", "try", "remind", "avoid", "stay"]
    /// Two words that start advice when the first alone doesn't ("Make sure…", "Don't forget…").
    static let advicePairs: Set<String> = ["make sure", "don't forget", "keep an", "be sure", "follow up", "follow-up on",
                                           "check that"]

    /// A cut-off answer without its unfinished end: the last line back to its last whole sentence, or gone.
    static func unfinishedEndRemoved(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let last = lines.popLast() else { return text }
        // The last sentence end followed by more (a backwards regex search isn't the last match everywhere).
        let ends = (try? NSRegularExpression(pattern: #"[.!?)](?=\s)"#))?
            .matches(in: last, range: NSRange(last.startIndex..., in: last)) ?? []
        if let stop = ends.last.flatMap({ Range($0.range, in: last) }) {
            lines.append(String(last[..<stop.upperBound]))
        }
        return lines.joined(separator: "\n")
    }

    /// Whether a line says what someone likes or wants ("prefers…", "likes…", "always…", "wants…").
    static func statesPreference(_ line: String) -> Bool {
        line.lowercased().range(of: #"\b(prefer\w*|like[sd]?|dislike[sd]?|love[sd]?|hate[sd]?|want[sd]?|rather|always|never|favou?rite|instead of|style)\b"#,
                                options: .regularExpression) != nil
    }

    /// "None specified", "N/A", or only a date: says nothing.
    static func isFiller(_ line: String) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
        if lower.range(of: #"^(none|n/?a|nothing|no \w+)( (specified|yet|known|noted|today))?\.?$"#, options: .regularExpression) != nil { return true }
        let dateWords: Set<String> = ["mon", "tue", "wed", "thu", "fri", "sat", "sun", "monday", "tuesday", "wednesday", "thursday",
                                      "friday", "saturday", "sunday", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep",
                                      "oct", "nov", "dec", "today", "is", "it", "date"]
        let words = lower.split { !$0.isLetter }.map(String.init)
        return words.allSatisfy { dateWords.contains($0) }
    }

    /// A line with its sentences of advice taken out ("Final pricing sheet due 20 Nov. Await confirmation." → the
    /// first sentence).
    static func withoutAdvice(_ line: String) -> String {
        let marked = line.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\u{1}", options: .regularExpression)
        var kept: [String] = []
        for (index, part) in marked.split(separator: "\u{1}").enumerated() {
            var sentence = String(part).trimmingCharacters(in: .whitespaces)
            var lead = sentence
            if index == 0, lead.hasPrefix("- ") { lead.removeFirst(2) }
            // "Priya Shah: Await confirmation." — what follows a name's colon.
            if let colon = lead.firstIndex(of: ":"), lead.distance(from: lead.startIndex, to: colon) <= 40 {
                lead = String(lead[lead.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            let words = lead.split(separator: " ").prefix(2).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            if advice.contains(words.first ?? "") || advicePairs.contains(words.joined(separator: " ")) {
                // A sentence that's only advice goes; the name before its colon goes with it when nothing else is left.
                if index == 0, sentence.contains(":"), lead != sentence { sentence = String(sentence.prefix { $0 != ":" }) + ":" }
                else { continue }
            }
            kept.append(sentence)
        }
        let out = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return out.hasSuffix(":") ? "" : out
    }

    /// The profile as kept: "How you write" only from what they wrote (a small model describes Murmur's own summaries
    /// otherwise), a quote only when it's theirs, and no sentence with a number none of the inputs has.
    public static func checkProfile(_ content: String, inputs: String = "", written: [String] = []) -> String {
        var answer = BrainModel.redact(ModelOutput.answer(content)).trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = CloudReader.cutOff.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.hasSuffix(marker) { answer = unfinishedEndRemoved(String(answer.dropLast(marker.count))) }
        let theirs = written.joined(separator: "\n").lowercased()
        let haystack = inputs.lowercased()
        var out: [String] = [], writing = false
        for raw in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                writing = line.lowercased().contains("write")
                if writing, written.isEmpty { continue }
                out.append(line)
                continue
            }
            if writing, written.isEmpty { continue }
            guard !inputs.isEmpty else { out.append(line); continue }
            let marked = line.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\u{1}", options: .regularExpression)
            let sentences = marked.split(separator: "\u{1}").map(String.init).filter { sentence in
                let numbers = WikiRules.numbers(in: sentence)
                let invented = numbers.contains { number in
                    haystack.range(of: #"(?<![\d.])"# + NSRegularExpression.escapedPattern(for: number) + #"(?![\d])"#,
                                   options: .regularExpression) == nil
                }
                if invented { return false }
                // `a quote`: only one they wrote.
                let quotes = sentence.split(separator: "`", omittingEmptySubsequences: false).enumerated()
                    .filter { $0.offset % 2 == 1 }.map { $0.element.lowercased() }
                return quotes.allSatisfy { theirs.contains($0) }
            }
            out.append(sentences.joined(separator: " "))
        }
        // Headings left with nothing under them go.
        var kept: [String] = []
        for (index, line) in out.enumerated() {
            if line.hasPrefix("#"), out[(index + 1)...].first(where: { !$0.isEmpty }).map({ $0.hasPrefix("#") }) ?? true { continue }
            if line.isEmpty, kept.last?.isEmpty ?? true { continue }
            kept.append(line)
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(separator: " ")
        return words.count <= 420 ? text : words.prefix(420).joined(separator: " ")
    }

    static func day(_ date: Date) -> String { WikiRules.formatter("EEE d MMM yyyy", .current).string(from: date) }
}

/// Writes the profile and the digest when they're due, with the model that reads memory.
public enum ProfileWriter {
    /// One round: the digest once a day (when there's a day or a page to write it from), the profile every fourteen
    /// days (when there are three days to write it from). Returns what was written.
    @discardableResult
    public static func pass(profile: Profile, journal: Journal, wiki: Wiki, brain: BrainStore, graph: MemoryGraph,
                            ask: EpisodeReader.Ask, model: String, remote: Bool, now: Date = Date(),
                            calendar: Calendar = .current, again: Bool = false,
                            keepGoing: () -> Bool = { true }) async -> [String] {
        // `again`: both written now, due or not (`murmur-memory knowledge 3 again`, to check a change on real memory).
        var written: [String] = []
        // The user is "you", never someone they worked with ("with Shubham", in days read before that was fixed).
        let me = brain.meNames()
        let days = Array(journal.latestChronicles(.day, limit: 14).reversed())
            .map { (period: $0.period, summary: WikiRules.withoutSelf($0.summary, me: me)) }
        let today = Journal.Level.day.period(of: now, calendar: calendar)
        // Digest: today's, once (its day changes at midnight).
        let digestDay = profile.text("digest").map { Journal.Level.day.period(of: $0.generated, calendar: calendar) }
        let pages = wiki.list(limit: 40)
            .sorted { $0.kind == "me" ? true : $1.kind == "me" ? false : $0.updated > $1.updated }
            .prefix(12).compactMap { wiki.page(id: $0.id) }
        if keepGoing(), again || digestDay != today, !days.isEmpty || !pages.isEmpty {
            let lines = pages.map { page in
                "- \(page.kind == "me" ? "You" : page.title) (\(page.kind)): \(page.summary) "
                    + page.claims.filter { $0.worth == "core" }.prefix(3).map { WikiRules.unlinked($0.text) }.joined(separator: " ")
            }
            // Overdue is worked out here, not by the model (it got the day wrong).
            let open = journal.loops(limit: 12).map { loop in
                "\(loop.label): \(loop.summary)" + (loop.due.map { due in
                    due < now ? " (was due \(ProfileRules.day(due)), overdue)" : " (due \(ProfileRules.day(due)))"
                } ?? "")
            }
                + graph.openThreads(now: now, limit: 8).map { Threads.line($0, now: now) }
            var prompt = ProfileRules.digestPrompt(days: Array(days.suffix(7)), pages: lines.map { WikiRules.withoutSelf($0, me: me) },
                                                   open: open, today: now)
            if remote { prompt = CloudPrivacy.scrub(prompt) }
            if let content = await ask(ProfileRules.digestSystem(today: now), prompt) {
                let digest = ProfileRules.checkDigest(content, inputs: prompt, me: brain.meNames())
                if digest.count >= 40 {
                    profile.set("digest", digest, model: model, now: now)
                    written.append("digest")
                    MemoryLog.write("wrote today's digest (\(digest.split(separator: " ").count) words)")
                }
            }
        }
        // Profile: every fourteen days, from at least three days.
        let last = profile.text("profile")
        if keepGoing(), days.count >= 3, again || last.map({ now.timeIntervalSince($0.generated) >= ProfileRules.profileEvery }) ?? true {
            // What they wrote and sent (their own words), never to Claude or OpenAI.
            let since = now.addingTimeInterval(-14 * 86400)
            let samples = remote ? [] : journal.snapshots(from: since, to: now, limit: 400)
                .map { ScreenText.confirmed($0.authored) }.filter { $0.count >= 20 }
                .suffix(30).map { BrainModel.redact(String($0.suffix(240))) }
            var prompt = ProfileRules.profilePrompt(existing: last?.text, days: days, written: Array(samples),
                                                    names: brain.meNames().filter { $0 != "You" })
            if remote { prompt = CloudPrivacy.scrub(prompt) }
            if let content = await ask(ProfileRules.profileSystem(existing: last != nil), String(prompt.prefix(14000))) {
                // Checked against what it was written from, not the last profile: a number made up once would last.
                let fresh = ProfileRules.profilePrompt(existing: nil, days: days, written: Array(samples),
                                                       names: brain.meNames().filter { $0 != "You" })
                let text = ProfileRules.checkProfile(content, inputs: fresh, written: Array(samples))
                if text.count >= 60 {
                    profile.set("profile", text, model: model, now: now)
                    written.append("profile")
                    MemoryLog.write("wrote your profile (\(text.split(separator: " ").count) words)")
                }
            }
        }
        return written
    }
}
