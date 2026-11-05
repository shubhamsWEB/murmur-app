import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads what you worked on into the living memory, with the local model in Ollama (nothing leaves the Mac):
///
/// - snapshots, a batch at a time → memories (people, projects, facts, through BrainModel's rules) and promises
///   (open loops, opened and closed by what's seen);
/// - each finished hour → a few sentences of what you did; the hours of a day → the day; days → the month; months →
///   the year (the chronicle).
///
/// Runs in the screen-memory helper, in the background, when the Mac can spare it (`ScreenWatcher` decides when).
public enum Consolidator {
    // MARK: Batches

    /// Snapshots as the model reads them, in batches of about `budget` characters: when, where, how long, then what
    /// the window said (each cut to what fits).
    public static func batches(_ snapshots: [Journal.Snapshot], budget: Int = 7000,
                               tags: (Journal.Snapshot) -> [String] = { _ in [] }) -> [(text: String, ids: [Int64])] {
        var out: [(String, [Int64])] = []
        var text = "", ids: [Int64] = []
        for snapshot in snapshots {
            let minutes = Int((snapshot.seconds / 60).rounded())
            let when = snapshot.first.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            let place = snapshot.domain.isEmpty ? snapshot.app : "\(snapshot.app), \(snapshot.domain)"
            let labels = tags(snapshot)
            let head = "[\(when), \(place)\(minutes > 0 ? ", \(minutes) min" : "")\(labels.isEmpty ? "" : "; how it was used: " + labels.joined(separator: ", "))] \(snapshot.title)"
            var body = BrainModel.redact(String(snapshot.text.prefix(max(400, budget / 4))))
            if !snapshot.seenAs.isEmpty { body = "Seen as: \(snapshot.seenAs)\n" + body }
            if !snapshot.authored.isEmpty {
                body += "\nThe user wrote and sent here: \(BrainModel.redact(String(snapshot.authored.suffix(1500))))"
            }
            let part = "\(head)\n\(body)\n\n"
            if !text.isEmpty, text.count + part.count > budget {
                out.append((text, ids))
                text = ""
                ids = []
            }
            text += String(part.prefix(budget))
            ids.append(snapshot.id)
        }
        if !text.isEmpty { out.append((text, ids)) }
        return out
    }

    // MARK: Memories and promises

    /// What's read off the screen becomes a memory from this importance (0 to 1; the model rates 0 to 10).
    public static let keepFrom = 0.4

    /// The model's promises checked the same way, and more strictly (a promise says the user owes something): only from
    /// a conversation or the user's own work (`Engagement.isConversation`), with its words in that window, and with
    /// someone the user knows or who's in that conversation. A demo on a product's website, an article, a feed: never.
    public static func judge(promises: [Journal.Promise], seen: [Journal.Snapshot], me: [String] = [],
                             known: (String) -> [String]) -> [Journal.Promise] {
        let talks = seen.filter(Engagement.isConversation)
        func words(_ text: String) -> Set<String> {
            Set(BrainModel.keywords(text).map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 })
        }
        // The user's own bookings and appointments (a flight, a doctor, a delivery): from a page that's theirs, one
        // that names them ("Hello Shubham Agrawal", the passenger), never an offer, a feed or an AI chat; with a date,
        // and its words on that page.
        let theirs = seen.filter { window in
            let kind = WindowKind.of(window)
            return ![.feed, .search, .video, .assistant, .article].contains(kind)
                && Engagement.mentions(window.title + "\n" + window.text, any: me)
        }
        func plan(_ promise: Journal.Promise) -> Bool {
            guard promise.due != nil else { return false }
            let claims = words(promise.summary).subtracting(glue).filter { $0.count >= 3 }
            return theirs.contains { window in
                let present = words(window.title + "\n" + window.text)
                let found = claims.filter { word in present.contains(word) || present.contains { $0.hasPrefix(word.prefix(5)) } }
                return claims.isEmpty || Double(found.count) / Double(claims.count) >= 0.5
            }
        }
        let plans = promises.filter { $0.kind == "plan" && plan($0) }
        let promises = promises.filter { $0.kind != "plan" }
        guard !talks.isEmpty else { return plans }
        // The user's own lines in a conversation: what they sent, and lines that start with their name or "You:".
        let speakers = (me.map { $0.lowercased() } + ["you", "me"]).map { $0 + ":" }
        func usersOwn(_ window: Journal.Snapshot) -> String {
            let lines = window.text.split(separator: "\n").filter { line in
                let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
                return speakers.contains { lower.hasPrefix($0) }
            }
            return window.authored + "\n" + lines.joined(separator: "\n")
        }
        return promises.filter { promise in
            // With the user themselves: no one else is owed anything.
            if !promise.person.isEmpty, me.contains(where: { Journal.samePerson($0, promise.person) }) { return false }
            let claims = words(promise.summary).subtracting(glue).filter { $0.count >= 3 }
            return talks.contains { window in
                // A promise the user made has to be in their own words; one asked of them or owed to them, in the
                // conversation.
                let source = promise.kind == "promised" ? usersOwn(window) : window.title + "\n" + window.text + "\n" + window.authored
                let present = words(source)
                let found = claims.filter { word in present.contains(word) || present.contains { $0.hasPrefix(word.prefix(5)) } }
                guard claims.isEmpty || Double(found.count) / Double(claims.count) >= 0.5 else { return false }
                guard !promise.person.isEmpty else { return true }
                let first = BrainModel.nameKey(promise.person).split(separator: " ").first.map(String.init) ?? ""
                let conversation = (window.title + "\n" + window.text).lowercased()
                return !known(promise.person).isEmpty || (!first.isEmpty && conversation.contains(first))
            }
        } + plans
    }

    // MARK: The user's own bookings

    /// A page that's the user's own booking, order or appointment: it names them, says what kind of thing it is, and
    /// has a date on it. Not a feed, a search, a video, an article or an AI chat.
    static func looksLikeBooking(_ window: Journal.Snapshot, me: [String]) -> Bool {
        guard ![.feed, .search, .video, .article, .assistant].contains(WindowKind.of(window)) else { return false }
        let text = (window.title + "\n" + window.text).lowercased()
        guard Engagement.mentions(text, any: me) else { return false }
        let words = ["itinerary", "booking", "pnr", "reservation", "confirmation", "appointment", "e-ticket", "ticket",
                     "boarding", "check-in", "checkin", "order details", "your order", "delivery", "check in"]
        guard words.contains(where: text.contains) else { return false }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return months.contains { text.contains(" \($0)") } || text.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    static func planSystem(today: Date) -> String {
        let day = today.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return """
            This page is the user's own booking, order or appointment. List what the user has coming up from it, as \
            JSON: {"plans": [{"what": "...", "when": "YYYY-MM-DD HH:mm"}]}. One entry for the event itself (what it \
            is, with its number and from where to where, as the page says it) and one for each deadline before it that \
            the page gives a time for (when online check-in opens, when check-in or bag drop closes, when to arrive). \
            Dates and times exactly as on the page; the year from the page, or from today: \(day). Nothing from offers \
            or adverts. An empty list when there is no booking.
            """
    }

    /// The plans one booking page holds, asked of the model on their own (a small model gets dates right that way,
    /// and wrong inside the long reading), and checked against the page.
    static func plans(in window: Journal.Snapshot, model: String, fast: Bool, now: Date) async -> [Journal.Promise] {
        let page = window.title + "\n" + String(window.text.prefix(3500))
        guard let content = await chat(planSystem(today: now), page, schema: nil, model: model, fast: fast,
                                       maxTokens: 300) else { return [] }
        return checkedPlans(content, page: page, now: now)
    }

    /// What the model said is coming up, kept only where the page agrees: its day and its time are on the page, it
    /// hasn't happened yet, and a deadline comes before the event it belongs to (and says which event).
    static func checkedPlans(_ content: String, page: String, now: Date) -> [Journal.Promise] {
        let answer = ModelOutput.answer(content)
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any],
              let list = object["plans"] as? [[String: Any]] else { return [] }
        let times = DateFormatter()
        times.dateFormat = "yyyy-MM-dd HH:mm"
        times.locale = Locale(identifier: "en_US_POSIX")
        let text = page.lowercased()
        func onPage(_ date: Date) -> Bool {
            let formats = ["dd MMM", "d MMM", "MMM d", "MMM dd", "d MMMM", "dd MMMM", "MMMM d", "yyyy-MM-dd", "dd/MM/yyyy",
                           "dd-MM-yyyy", "dd.MM.yyyy"]
            let day = formats.contains { format in
                let f = DateFormatter()
                f.dateFormat = format
                f.locale = Locale(identifier: "en_US_POSIX")
                return text.contains(f.string(from: date).lowercased())
            }
            let clock = DateFormatter()
            clock.locale = Locale(identifier: "en_US_POSIX")
            clock.dateFormat = "HH:mm"
            let h24 = clock.string(from: date)
            clock.dateFormat = "h:mm"
            let h12 = clock.string(from: date)
            return day && (text.contains(h24) || text.contains(h12 + " am") || text.contains(h12 + " pm")
                           || text.contains(h12 + "am") || text.contains(h12 + "pm"))
        }
        var found: [(what: String, when: Date)] = []
        for entry in list.prefix(6) {
            let what = ((entry["what"] ?? entry["summary"]) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let written = ((entry["when"] ?? entry["due"]) as? String ?? "").replacingOccurrences(of: "T", with: " ")
            guard what.count >= 4, what.count <= 160, !BrainModel.hasSecret(what),
                  let when = times.date(from: String(written.prefix(16))), when > now, onPage(when) else { continue }
            found.append((what, when))
        }
        guard let event = found.first else { return [] }
        let deadlines = found.dropFirst().filter { $0.when < event.when }
        // "Check-in closes" says nothing on its own: for which flight.
        let named = event.what.split(separator: ",").first.map(String.init) ?? event.what
        return [Journal.Promise(summary: event.what, mine: true, due: event.when, kind: "plan")]
            + deadlines.map { deadline in
                let what = deadline.what.rangeOfCharacter(from: .decimalDigits) == nil ? "\(deadline.what): \(named)" : deadline.what
                return Journal.Promise(summary: what, mine: true, due: deadline.when, kind: "plan")
            }
    }

    /// The attributes someone has one of at a time: a new value replaces the old.
    static let singleValued: Set<String> = ["employer", "company", "role", "title", "job", "city", "location", "home",
                                            "phone", "email", "birthday", "manager", "team", "school", "partner",
                                            "spouse", "address", "timezone", "name", "nickname"]

    /// "Viewed…", "Visited…", "Browsed…": what was looked at, not what's true.
    static func isActivity(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let starts = ["viewed ", "visited ", "browsed ", "looked at ", "opened ", "watched ", "scrolled ", "searched for ",
                      "checked ", "was viewing ", "was browsing ", "is viewing ", "is browsing ", "has viewed ", "has visited "]
        if starts.contains(where: lower.hasPrefix) { return true }
        if [" is checking the status", " is considering ", " was considering "].contains(where: lower.contains) { return true }
        let inside = [" viewed ", " visited ", " browsed ", " was viewing ", " is viewing ", " looked at "]
        return inside.contains { lower.contains($0) } && lower.split(separator: " ").count <= 14
    }

    /// The words of the Mac's own dictionary (macOS has one: /usr/share/dict/words), for names that aren't names.
    static let dictionary: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        // Lowercase entries only: "Priya" isn't one, "voice" is; capitalised ones are names already ("Rose").
        return Set(text.split(separator: "\n").filter { $0.first?.isLowercase == true }.map(String.init))
    }()

    static func isCommonWord(_ name: String) -> Bool {
        let words = name.lowercased().split(separator: " ")
        guard words.count == 1, let word = words.first else { return false }
        return dictionary.contains(String(word)) || ["information", "voice", "press", "home", "notifications", "messaging",
                                                     "jobs", "network", "post", "repost", "follow", "connect"].contains(String(word))
    }

    /// Two memories this close in meaning, about the same thing, say the same thing (EmbeddingGemma 2: rewordings of
    /// one fact score 0.87 to 0.90, different facts about the same person up to 0.81).
    public static let sameMeaning: Float = 0.86

    /// Memories that repeat one already kept (or one earlier in the same batch) in other words: out, and the kept one
    /// counts as seen again.
    static func repeats(_ memories: [BrainModel.Candidate], brain: BrainStore, vectors: MemoryVectors, me: [String])
        async -> (fresh: [BrainModel.Candidate], repeated: [Int64]) {
        guard !memories.isEmpty, LocalReader.embedderInstalled else { return (memories, []) }
        let mine = Set(me.map { BrainModel.nameKey($0) })
        func who(_ memory: BrainModel.Candidate) -> String {
            memory.aboutKind == .me || mine.contains(BrainModel.nameKey(memory.about)) ? "You" : memory.about
        }
        guard let made = await LocalReader.embed(memories.map { who($0) + ": " + $0.text }, query: false),
              made.count == memories.count else { return (memories, []) }
        var fresh: [BrainModel.Candidate] = [], kept: [(String, [Float])] = [], repeated: [Int64] = []
        for (memory, raw) in zip(memories, made) {
            let vector = MemoryVectors.cut(raw)
            let name = BrainModel.nameKey(who(memory))
            if kept.contains(where: { $0.0 == name && MemoryVectors.similarity($0.1, vector) >= sameMeaning }) { continue }
            let earlier = vectors.search(vector, kinds: [.memory], limit: 3, floor: sameMeaning).first { hit in
                brain.aboutName(memory: hit.ref).map { BrainModel.nameKey($0) == name } ?? false
            }
            if let earlier { repeated.append(earlier.ref); continue }
            kept.append((name, vector))
            fresh.append(memory)
        }
        return (fresh, repeated)
    }

    /// Words any summary may use without having read them.
    static let glue: Set<String> = ["user", "user's", "shubham", "you", "your", "also", "now", "today", "currently", "working",
                                    "works", "work", "uses", "using", "wants", "plans", "planning", "needs", "about", "asked",
                                    "said", "says", "told", "will", "would", "should", "can", "could", "being", "been", "into",
                                    "over", "after", "before", "next", "last", "new", "via", "app", "team"]

    /// The model's memories checked against what was actually seen, without the model (a small one takes the labels
    /// for content): a memory about the app or site itself, or echoing how a window was used, goes; one found only in
    /// windows you were browsing, about someone who isn't you or a person you know, counts for at most 3 in 10.
    public static func judge(_ memories: [BrainModel.Candidate], seen: [Journal.Snapshot], browsing: Set<Int64>,
                             me: [String], known: (String) -> [String]) -> [BrainModel.Candidate] {
        let places = Set(seen.flatMap { [$0.app.lowercased(), $0.domain.lowercased(),
                                          $0.domain.split(separator: ".").first.map { String($0).lowercased() } ?? ""] })
            .subtracting([""])
        let echoes = ["browsing", "mentions you", "people you know", "came back", "how it was used"]
        let mine = Set(me.map { $0.lowercased() })
        let source = seen.map { $0.title + "\n" + $0.text }.joined(separator: "\n").lowercased()
        // Words as compared: "Murmur's" is "murmur".
        func words(_ text: String) -> Set<String> {
            Set(BrainModel.keywords(text).map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 })
        }
        let sourceWords = words(source)
        // The same sentence written for several different things: made up, not read (a small model does it).
        var sameText: [String: Int] = [:]
        for memory in memories { sameText[memory.text.lowercased(), default: 0] += 1 }
        return memories.compactMap { memory in
            let about = memory.about.lowercased(), text = memory.text.lowercased()
            if places.contains(about) || places.contains(about.replacingOccurrences(of: " ", with: "")) { return nil }
            if echoes.contains(where: text.contains) { return nil }
            // What the user looked at isn't a fact about their world ("Viewed LinkedIn profile of…"): the day's
            // record already has it.
            if isActivity(text) { return nil }
            // Someone whose "name" is an ordinary word ("Voice", "Press", "Information": a page's buttons and
            // headings), unless the user knows them.
            if memory.aboutKind == .person, isCommonWord(about), known(memory.about).isEmpty, !mine.contains(about) { return nil }
            if (sameText[text] ?? 0) > 1 { return nil }
            // What it's about has to have been on the screen (a sidebar's chat titles aren't read any more), unless it's
            // the user.
            let isUser = memory.aboutKind == .me || mine.contains(about) || mine.contains(where: { about.hasPrefix($0) })
            let aboutWords = words(about).filter { $0.count >= 4 }
            let textWords = words(text)
            if !isUser, !aboutWords.isEmpty, aboutWords.isDisjoint(with: sourceWords) { return nil }
            // And most of what it says has to have been on the screen: "…is in progress and has options for further
            // configuration" about a chat's title wasn't.
            let claims = textWords.subtracting(words(about)).subtracting(Self.glue).filter { $0.count >= 3 }
            if claims.count >= 2 {
                let found = claims.filter { word in sourceWords.contains(word) || sourceWords.contains { $0.hasPrefix(word.prefix(5)) } }
                if Double(found.count) / Double(claims.count) < 0.5 { return nil }
            }
            // About the user, but only a website, article or feed says it, and it never names them: reading about
            // something isn't being part of it ("associated with the Mem0 project" from Mem0's own site).
            if isUser, !claims.isEmpty {
                let supporting = seen.filter { window in
                    let present = words(window.title + "\n" + window.text)
                    let found = claims.filter { word in present.contains(word) || present.contains { $0.hasPrefix(word.prefix(5)) } }
                    return Double(found.count) / Double(claims.count) >= 0.5
                }
                if !supporting.isEmpty, supporting.allSatisfy({ window in
                    !WindowKind.of(window).canOblige && WindowKind.of(window) != .assistant
                        && !Engagement.mentions(window.text + " " + window.title, any: me)
                }) { return nil }
            }
            var memory = memory
            let isMe = memory.aboutKind == .me || mine.contains(about) || mine.contains(where: { about.hasPrefix($0) })
            let isKnown = !known(memory.about).isEmpty
            let from = seen.filter { $0.text.lowercased().contains(about) || $0.title.lowercased().contains(about) }
            if !isMe, !isKnown, !from.isEmpty, from.allSatisfy({ browsing.contains($0.id) }) {
                memory.importance = min(memory.importance, 0.3)
            }
            return memory
        }
    }

    static func system(today: Date = Date(), user: [String] = []) -> String {
        let day = today.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        let who = user.isEmpty ? "" : " The user is \(user.joined(separator: ", also called "))."
        return """
            You read the text of windows the user worked in on their Mac (chats, email, documents, pages, issues), with \
            when and where, and write down what their assistant should remember. Today is \(day).\(who)

            Most of what anyone sees is not about them: a feed, news, other people's posts. The square brackets before \
            each window say when, where and how it was used ("browsing": a feed or news, keep only what concerns the \
            user; "mentions you"; "people you know"). They are not content: never write a memory about the app, the \
            site, or how it was used. What the user wrote, was asked, or decided matters most.

            "memories": durable facts about the user's world: who people are and how they relate to the user, what \
            projects are about and where they stand, decisions, dates that matter, the user's preferences. One short \
            sentence each, naming who or what it's about. Same fields as always: about, about_kind (person, \
            organization, project, place, topic or me), text, kind (fact, relationship, preference, event, task or \
            status), slot, expires (YYYY-MM-DD or empty), and
            "importance" (0 to 10): how much it matters to the user's own life and work. 9-10: the user's own \
            commitments, decisions, deadlines, health of their projects; 7-8: people they work or live with and how \
            they relate to the user, their own plans and preferences; 4-6: useful facts about their organizations, \
            clients, tools; 1-3: things they only came across (a post in a feed, news, someone they don't know). \
            Anything that names the user, their projects or people they know matters more than what doesn't.

            "promises": obligations, only from conversations and the user's own work (never from a website, an article, \
            a feed, an AI chat or an example): kind "promised" when the user said they'd do something ("I'll send the \
            deck by Friday", best seen in what the user wrote and sent), "asked" when someone asked the user to do \
            something ("can you review the doc?": the user owes it), "owed" when someone said they'd do something for \
            the user. summary (a short sentence: "Send Priya the Q3 deck"), person, project, kind, due (YYYY-MM-DD or \
            empty), status ("open", or "done" when the text shows it was done: sent, replied, merged, paid, shipped).

            Never write what the user looked at or visited ("Viewed X's profile", "Visited a page"): only what is \
            true. Never a person whose name is a word on the page ("Voice", "Press"). Say each thing once.

            "plans" go in "promises" too, with kind "plan": the user's own bookings and appointments, seen on a page \
            that is theirs (it names them: their itinerary, order, ticket or appointment): a flight, train, hotel, \
            doctor, delivery, event. Summary with what and where ("Flight 6E 537 Bengaluru to Raipur, T1"), due as \
            "YYYY-MM-DD HH:mm" (when it happens), and one more plan for each deadline before it ("Web check-in opens \
            for 6E 537", "Check-in closes for 6E 537"). Never from offers, adverts or search results.

            Skip ads, menus, code listings, boilerplate, and anything you'd have to guess. Nothing from passwords or \
            codes. At most 5 memories and 4 promises, each text at most 15 words; empty lists when nothing is worth \
            keeping. JSON only.
            """
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "memories": BrainDistiller.schema["properties"].flatMap { ($0 as? [String: Any])?["memories"] } ?? [:],
            "promises": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "summary": ["type": "string"], "person": ["type": "string"], "project": ["type": "string"],
                        "kind": ["type": "string"], "due": ["type": "string"], "status": ["type": "string"],
                    ],
                    "required": ["summary", "kind", "status"],
                ],
            ],
        ],
        "required": ["memories", "promises"],
    ]

    public struct Reading: Sendable {
        public var memories: [BrainModel.Candidate]
        public var promises: [Journal.Promise]
    }

    /// What the model wrote, read leniently: memories as BrainDistiller reads them, and promises.
    public static func parse(_ content: String, now: Date = Date()) -> Reading {
        let memories = BrainDistiller.parse(content, origin: .screen, now: now)
        let answer = ModelOutput.answer(content)
        var list: [[String: Any]] = []
        if let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
           let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any] {
            list = object["promises"] as? [[String: Any]] ?? []
        }
        let dates = DateFormatter()
        dates.dateFormat = "yyyy-MM-dd"
        dates.locale = Locale(identifier: "en_US_POSIX")
        let times = DateFormatter()
        times.dateFormat = "yyyy-MM-dd HH:mm"
        times.locale = Locale(identifier: "en_US_POSIX")
        let promises = list.prefix(8).compactMap { entry -> Journal.Promise? in
            let summary = (entry["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard summary.count >= 6, summary.count <= 200, !BrainModel.hasSecret(summary) else { return nil }
            // "2026-11-08 10:15": then; "2026-11-08": through that day.
            let written = (entry["due"] as? String ?? "").replacingOccurrences(of: "T", with: " ")
            let due = times.date(from: String(written.prefix(16)))
                ?? dates.date(from: String(written.prefix(10))).map { $0.addingTimeInterval(86400 - 1) }
            let status = (entry["status"] as? String ?? "open").lowercased()
            var kind = (entry["kind"] as? String ?? "").lowercased()
            if !["promised", "asked", "owed", "plan"].contains(kind) { kind = (entry["mine"] as? Bool ?? true) ? "promised" : "owed" }
            return Journal.Promise(summary: summary, person: entry["person"] as? String ?? "",
                                   project: entry["project"] as? String ?? "", mine: kind != "owed",
                                   due: due, status: ["done", "completed", "closed"].contains(status) ? "done" : "open", kind: kind)
        }
        return Reading(memories: memories, promises: promises)
    }

    // MARK: Chronicle

    static func chronicleSystem(_ level: Journal.Level) -> String {
        let span: String
        switch level {
        case .hour: span = "one hour of the user's work, from the windows they worked in"
        case .day: span = "one day of the user's work, from summaries of its hours"
        case .month: span = "one month of the user's work, from summaries of its days"
        case .year: span = "one year of the user's work, from summaries of its months"
        }
        return """
            Summarise \(span), for the user's own record. Write two to four plain sentences in the second person \
            ("You reviewed…"): what they worked on, with whom, what got done, and what was left open. Name the \
            projects, people, documents and sites. No headings, no lists, no guesses, nothing from passwords or codes.
            """
    }

    // MARK: Running

    /// One pass: reads up to `batchesPerPass` batches of settled snapshots into memories and promises, then writes the
    /// chronicle for finished hours, days and months. `keepGoing` is asked before each model call (stop when the user
    /// comes back or the Mac runs low). Returns how many snapshots were read.
    @discardableResult
    public static func pass(journal: Journal, brain: BrainStore, model: String, batchesPerPass: Int = 3,
                            vectors: MemoryVectors? = nil, fast: Bool = false, summaries: Bool = true,
                            now: Date = Date(), keepGoing: () -> Bool = { true }) async -> Int {
        var read = 0
        let me = brain.meNames()
        // Triage first (no model): what's worth the model's time, best first, and only what's new in each.
        let waiting = journal.pending(limit: 200, now: now)
        let mattering = vectors.flatMap { $0.centroid(of: brain.importantMemoryIDs()) }
        let plan = Triage.plan(waiting, me: me, known: { brain.knownPeople(in: $0) }) { snapshot in
            guard let mattering, let vector = vectors?.vector(.snapshot, snapshot.id) else { return nil }
            return MemoryVectors.similarity(vector, mattering)
        }
        if !plan.skip.isEmpty {
            journal.consolidated(plan.skip.map(\.id))
            let reasons = Dictionary(grouping: plan.skip, by: \.why).map { "\($0.value.count) \($0.key)" }.sorted()
            MemoryLog.write("didn't need the model for \(plan.skip.count) windows: " + reasons.joined(separator: "; "))
            read += plan.skip.count
        }
        let pending = Array(plan.read.prefix(60))
        let byID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        let browsing = Set(pending.filter(Engagement.isBrowsing).map(\.id))
        let tagged = batches(pending) { snapshot in
            Engagement.tags(snapshot, me: me) { text in brain.knownPeople(in: text) }
        }
        for batch in tagged.prefix(batchesPerPass) {
            guard keepGoing() else { return read }
            guard let content = await chat(system(today: now, user: me), batch.text, schema: schema, model: model,
                                           fast: fast, maxTokens: 600) else { break }
            var reading = parse(content, now: now)
            // What only passed by (a post in a feed, news about strangers) isn't kept as a memory: it stays in what
            // was seen, for two weeks.
            let seen = reading.memories.count
            reading.memories = judge(reading.memories, seen: batch.ids.compactMap { byID[$0] }, browsing: browsing, me: me) {
                brain.knownPeople(in: $0)
            }.filter { $0.importance >= keepFrom }
            if reading.memories.count < seen {
                MemoryLog.write("left out \(seen - reading.memories.count) unimportant things (only seen, not about you)")
            }
            // A slot is for what a person has one of; "status" or "activity" would let the next window's trivia
            // replace what mattered ("booking a flight" replaced by "checking the payment status").
            for index in reading.memories.indices where !(reading.memories[index].slot.map { singleValued.contains($0.lowercased()) } ?? true) {
                reading.memories[index].slot = nil
            }
            if let vectors {
                let (fresh, repeated) = await repeats(reading.memories, brain: brain, vectors: vectors, me: me)
                if !repeated.isEmpty || fresh.count < reading.memories.count {
                    brain.confirm(repeated, now: now)
                    MemoryLog.write("left out \(reading.memories.count - fresh.count) things already known, in other words")
                }
                reading.memories = fresh
            }
            let item = "screen:\(batch.ids.first ?? 0)-\(batch.ids.last ?? 0)"
            let applied = brain.apply(reading.memories, item: item, now: now)
            // The user's own bookings in this batch (a flight, an appointment), each asked about on its own.
            for window in batch.ids.compactMap({ byID[$0] }).filter({ looksLikeBooking($0, me: me) }).prefix(2) {
                guard keepGoing() else { break }
                let found = await plans(in: window, model: model, fast: fast, now: now)
                if !found.isEmpty { MemoryLog.write("found \(found.count) plans on your booking (\(window.domain))") }
                reading.promises += found
            }
            let offered = reading.promises.count
            reading.promises = judge(promises: reading.promises, seen: batch.ids.compactMap { byID[$0] }, me: me) {
                brain.knownPeople(in: $0)
            }
            if reading.promises.count < offered {
                MemoryLog.write("left out \(offered - reading.promises.count) promises not from a conversation or your own work")
            }
            let loops = journal.take(reading.promises, evidence: batch.ids, now: now)
            MemoryLog.write("batch of \(batch.ids.count) windows: \(reading.memories.count) memories (\(applied.added) new, "
                            + "\(applied.confirmed) confirmed, \(applied.replaced) updated), \(reading.promises.count) promises "
                            + "(\(loops.opened) opened, \(loops.closed) closed)")
            journal.consolidated(batch.ids)
            read += batch.ids.count
        }
        if summaries { await chronicle(journal: journal, model: model, now: now, keepGoing: keepGoing) }
        return read
    }

    /// Writes the summaries still missing: the last day's finished hours, then yesterday, last month and last year
    /// once their parts exist.
    static func chronicle(journal: Journal, model: String, now: Date, keepGoing: () -> Bool) async {
        let calendar = Calendar.current
        // Hours: each finished hour of the last 24 with something seen in it.
        for back in (1...24).reversed() {
            guard keepGoing() else { return }
            guard let start = calendar.dateInterval(of: .hour, for: now.addingTimeInterval(Double(-back) * 3600)) else { continue }
            let period = Journal.Level.hour.period(of: start.start)
            guard journal.chronicle(.hour, period) == nil else { continue }
            let seen = journal.snapshots(from: start.start, to: start.end, limit: 80)
            guard seen.reduce(0, { $0 + $1.seconds }) >= 120 || seen.count >= 3 else { continue }
            let text = batches(seen, budget: 6000).first?.text ?? ""
            if let summary = await chat(chronicleSystem(.hour), text, schema: nil, model: model) {
                journal.setChronicle(.hour, period, clean(summary), now: now)
                MemoryLog.write("wrote the summary of \(period)")
            }
        }
        // Rollups: yesterday from its hours, last month from its days, last year from its months.
        let rollups: [(Journal.Level, Date)] = [
            (.day, now.addingTimeInterval(-86400)),
            (.month, calendar.date(byAdding: .month, value: -1, to: now) ?? now),
            (.year, calendar.date(byAdding: .year, value: -1, to: now) ?? now),
        ]
        for (level, date) in rollups {
            guard keepGoing(), let below = level.below else { return }
            let period = level.period(of: date)
            guard journal.chronicle(level, period) == nil else { continue }
            let parts = journal.chronicles(below, within: period)
            guard !parts.isEmpty else { continue }
            let text = parts.map { "\($0.period): \($0.summary)" }.joined(separator: "\n").prefix(7000)
            if let summary = await chat(chronicleSystem(level), String(text), schema: nil, model: model) {
                journal.setChronicle(level, period, clean(summary), now: now)
            }
        }
    }

    static func clean(_ text: String) -> String {
        BrainModel.redact(ModelOutput.answer(text)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One local-model call: its answer, or nil when Ollama couldn't be asked.
    static func chat(_ system: String, _ user: String, schema: [String: Any]?, model: String, fast: Bool = false,
                     maxTokens: Int = 900) async -> String? {
        if model == LocalReader.name {
            return await LocalReader.ask(system: system, user: user, json: schema != nil, maxTokens: maxTokens, fast: fast)
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 240
        var body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": "5m",
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "options": ["temperature": 0, "num_predict": maxTokens, "num_ctx": 8192],
        ]
        if let schema { body["format"] = schema }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        let started = Date()
        do {
            let (reply, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
                  let message = json["message"] as? [String: Any], let content = message["content"] as? String else {
                MemoryLog.write("Ollama (\(model)) answered HTTP \(status): \(String(decoding: reply.prefix(300), as: UTF8.self))")
                return nil
            }
            MemoryLog.write("Ollama (\(model)) answered in " + String(format: "%.1f s", Date().timeIntervalSince(started))
                            + ", \(content.count) characters")
            return content
        } catch {
            MemoryLog.write("Ollama (\(model)) couldn't be asked: \(error.localizedDescription)")
            return nil
        }
    }
}
