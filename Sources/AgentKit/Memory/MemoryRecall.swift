import Foundation

/// Finding what the user's own world holds for a question, from the top down: what's certain first (a flight's
/// departure, a release's version and day, read from the windows), then the episodes that match (what the user did,
/// when, for how long, how it ended), then how what the question names is connected (the projects someone is in,
/// what the user did with a project), each line saying where it comes from. The living memory's facts come after
/// (`Brain.ask`), so an answer is built on what was seen before what was inferred.
public enum MemoryRecall {
    static func says(_ text: String, _ words: [String]) -> Bool {
        let lower = " " + text.lowercased() + " "
        return words.contains { lower.contains($0) }
    }

    static let aboutTravel = [" flight", " fly ", " flying", " trip", "travel", "check-in", "check in", "checkin", "boarding",
                              " pnr", "airport", " plane", " depart", "itinerary", " booking", " booked"]
    static let aboutReleases = ["release", "released", " ship", "shipped", "launch", "version", "publish", "changelog",
                                "what's new", "whats new", "went out", " v1", " v2", "deployed"]
    static let aboutPriorities = ["focus", "priorit", "what should i", "what do i need to", "waiting on", "waiting for",
                                  "follow up", "follow-up", "followup", "pending", "replied", "reply", "respond", "my turn",
                                  "owe", "get back to", "who do i need", "what's open", "whats open", "to do today", "important"]
    static let aboutEmail = [" email", "emailed", " mail", "mailed", "wrote to", "write to", " sent ", "send to", "sent to",
                             " replied", "reply to", "message to", "messaged"]
    static let aboutDoing = ["what did i", "what was i", "worked on", "working on", "what have i", "did i ", "how long",
                             "spent", "yesterday", "today", "this morning", "this afternoon", "this evening", "last week",
                             "this week", "on monday", "on tuesday", "on wednesday", "on thursday", "on friday",
                             "on saturday", "on sunday", "recap", "my day", "where did my time", "busy with", "been doing"]

    /// Telling people about something: posting, announcing, sharing, notifying, on a feed or in a chat.
    static let aboutSharing = [" notified", " notify", " posted", " post ", " posts", " posting", " shared", " share ",
                               " announced", " announce", " tweeted", " tweet", " told ", " tell ", " informed", " inform ",
                               " linkedin", " whatsapp", " slack", " twitter", " x.com", " instagram", " facebook",
                               " telegram", " discord", " reddit", " product hunt", " threads"]
    static let aboutDoingWe = ["what did we", "what have we", "did we ", "have we ", "had we ", "what all", "we did",
                               "we've done", "we have done", "we worked", "we shipped"]

    /// Whether the question is about the user themselves (or their team): "I", "my", "we", "our", "us".
    static func aboutTheUser(_ lower: String) -> Bool {
        let text = " " + lower.replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression) + " "
        return [" i ", " my ", " me ", " we ", " our ", " us ", " i've ", " we've ", " mine ", " ours "].contains(where: text.contains)
    }

    /// The apps and sites a question names ("on LinkedIn and WhatsApp"), as they appear in items' fields.
    static func namedPlaces(_ query: String) -> [String] {
        let lower = " " + query.lowercased() + " "
        let places: [(String, [String])] = [
            ("linkedin", [" linkedin", " linked in"]), ("whatsapp", [" whatsapp", " whats app"]), ("slack", [" slack"]),
            ("x", [" twitter", " tweet", " x.com", " on x "]), ("instagram", [" instagram", " insta "]),
            ("facebook", [" facebook"]), ("telegram", [" telegram"]), ("discord", [" discord"]), ("reddit", [" reddit"]),
            ("product hunt", [" product hunt", " producthunt"]), ("threads", [" threads"]), ("messages", [" imessage", " sms"]),
            ("mail", [" email", " mail", " gmail"]),
        ]
        return places.filter { $0.1.contains(where: lower.contains) }.map(\.0)
    }

    /// Whether a command asks about the user's own trips, releases or work (then what's certain goes into its context).
    public static func isAboutTheUsersWork(_ text: String) -> Bool {
        says(text, aboutTravel) || says(text, aboutReleases) || says(text, aboutDoing) || says(text, aboutDoingWe)
            || (says(text, aboutSharing) && aboutTheUser(text.lowercased()))
    }

    /// What the user put out (posts on feeds, messages and emails they sent) and what Murmur sent for them, newest
    /// first: on the places the question names, else all of it. "Have we notified on LinkedIn and WhatsApp?" is
    /// answered from these, or by saying none was seen.
    static func sharedByTheUser(for query: String, graph: MemoryGraph, since: Date? = nil, limit: Int = 8) -> [MemoryGraph.StoredItem] {
        let places = namedPlaces(query)
        let all = graph.items([.post, .message, .email], limit: 200).filter(\.item.mine)
            .filter { since == nil || ($0.item.when ?? $0.last) >= since! }
            .sorted { ($0.item.when ?? $0.last) > ($1.item.when ?? $1.last) }
        guard !places.isEmpty else { return Array(all.prefix(limit)) }
        let onThem = all.filter { stored in
            let at = [stored.item.fields["app"], stored.item.fields["platform"], stored.item.fields["url"], stored.item.key]
                .compactMap { $0?.lowercased() }.joined(separator: " ")
            return places.contains { place in
                place == "mail" ? stored.item.kind == .email : at.contains(place == "x" ? "x.com" : place)
                    || (place == "x" && at.contains("twitter"))
            }
        }
        return Array(onThem.prefix(limit))
    }

    /// Emails the user sent that a question is about: to someone it names, or on a day it names; the latest first.
    static func sentEmails(for query: String, graph: MemoryGraph, now: Date, calendar: Calendar) -> [MemoryGraph.StoredItem] {
        let sent = graph.items([.email, .message], limit: 120).filter(\.item.mine).sorted { ($0.item.when ?? $0.last) > ($1.item.when ?? $1.last) }
        let words = Set(BrainModel.keywords(query))
        let named = sent.filter { stored in stored.item.people.contains { person in
            BrainModel.nameKey(person).split(separator: " ").contains { words.contains(String($0)) } } }
        if !named.isEmpty { return named }
        if let span = span(of: query, now: now, calendar: calendar) {
            return sent.filter { let at = $0.item.when ?? $0.last; return at >= span.from && at < span.to }
        }
        return Array(sent.prefix(5))
    }

    /// An answer that needs no model: the question is about the user's next flight, what they released, or what they
    /// did on a day, and what was seen answers it exactly. Nil when a model has to put it together.
    public static func directAnswer(_ question: String, graph: MemoryGraph, now: Date = Date(),
                                    calendar: Calendar = .current) -> String? {
        // Only something asked of memory gets a ready answer ("what did I do yesterday?" is the brief's): "tell the team
        // we shipped 1.7" is something to do.
        guard MemoryRoute.classify(question) != nil else { return nil }
        let lower = question.lowercased()
        // Several questions at once: a ready answer to one would drop the others; the model answers them all.
        if MemoryRoute.isCompound(question) { return nil }
        let theirs = aboutTheUser(lower)
        func day(_ date: Date) -> String {
            calendar.isDate(date, inSameDayAs: now) ? "today"
                : calendar.isDate(date, inSameDayAs: now.addingTimeInterval(86400)) ? "tomorrow"
                : ScreenDates.formatter("EEEE d MMMM", calendar).string(from: date)
        }
        func time(_ stamp: String?) -> String? {
            stamp.flatMap { ScreenDates.formatter("yyyy-MM-dd HH:mm", calendar).date(from: $0) }.map {
                ScreenDates.formatter("HH:mm", calendar).string(from: $0)
            }
        }
        // "When is my flight?", "what time do I fly", "when does check-in close".
        if says(question, aboutTravel), let next = graph.upcoming(now: now, limit: 1).first, next.item.kind == .flight,
           let departs = next.item.when {
            let fields = next.item.fields
            var answer = "\(next.item.title) departs \(day(departs)) at \(fields["departure time"] ?? ScreenDates.formatter("HH:mm", calendar).string(from: departs))"
            if let arrives = time(fields["arrives"]) { answer += ", landing at \(arrives)" }
            answer += "."
            if let closes = time(fields["check-in closes"]) { answer += " Check-in closes at \(closes)." }
            if let opens = fields["check-in opens"].flatMap({ ScreenDates.formatter("yyyy-MM-dd HH:mm", calendar).date(from: $0) }), opens > now {
                answer += " Web check-in opens \(day(opens)) at \(ScreenDates.formatter("HH:mm", calendar).string(from: opens))."
            }
            if let connecting = fields["connecting"] { answer += " It connects to \(connecting)." }
            return answer
        }
        // "What should I focus on?", "who am I waiting on?", "did Tanay reply?".
        if says(question, aboutPriorities) {
            let named = graph.threads(matching: question, limit: 3, now: now)
            let open = named.isEmpty ? graph.openThreads(now: now, limit: 5) : named
            guard !open.isEmpty else { return nil }
            let turn = open.filter { $0.status == .yourTurn }, nudge = open.filter { $0.status == .nudge }
            let waiting = open.filter { $0.status == .waiting }
            func who(_ thread: MemoryThread) -> String {
                thread.person + (thread.organization.isEmpty ? "" : " (\(thread.organization))")
            }
            var parts: [String] = []
            if !turn.isEmpty { parts.append("Your turn: " + turn.map { "\(who($0)), \($0.title) (\($0.lastAction.lowercased()))" }.joined(separator: "; ") + ".") }
            if !nudge.isEmpty { parts.append("Follow up: " + nudge.map { "\(who($0)), \($0.title), no reply since \(day($0.lastAt))" }.joined(separator: "; ") + ".") }
            if !waiting.isEmpty {
                parts.append("Waiting on: " + waiting.map { thread in
                    "\(who(thread)) about \(thread.title)" + (thread.followUp.map { ", follow up \(day($0))" } ?? "")
                }.joined(separator: "; ") + ".")
            }
            return parts.joined(separator: " ")
        }
        // "Did I email Tanay?", "who did I email today?".
        if says(question, aboutEmail), theirs {
            let sent = sentEmails(for: question, graph: graph, now: now, calendar: calendar)
            guard !sent.isEmpty else { return nil }
            return sent.prefix(4).map { stored -> String in
                let item = stored.item, at = item.when ?? stored.last
                let to = item.people.isEmpty ? "" : " \(item.people.joined(separator: ", "))"
                return "You \(item.kind == .email ? "emailed" : "messaged")\(to) \(day(at) == "today" ? "today" : "on " + day(at)): \"\(item.title)\"."
            }.joined(separator: " ")
        }
        // "What did I release?", "which app did I ship recently?", "what's in the latest version?".
        if says(question, aboutReleases), theirs {
            // The newest first: by the day it was released, else by its version.
            func released(_ stored: MemoryGraph.StoredItem) -> Date? {
                stored.item.when ?? (["terminal", "tag"].contains(stored.item.fields["source"] ?? "") ? stored.first : nil)
            }
            let releases = ItemReader.uniqueReleases(graph.items([.release], limit: 30).filter(\.item.mine)).sorted { a, b in
                if let x = released(a), let y = released(b), x != y { return x > y }
                return ItemReader.newerVersion(a.item.fields["version"] ?? "", than: b.item.fields["version"] ?? "")
            }
            if let latest = releases.first {
                let item = latest.item
                let who = lower.contains(" we ") || lower.contains(" our ") ? "We" : "You"
                let tagged = item.fields["status"] == "tagged" || item.fields["source"] == "terminal"
                var answer = "\(who) \(tagged ? "tagged" : "released") \(item.title)"
                if let when = released(latest) { answer += " \(day(when) == "today" ? "today" : "on " + day(when))" }
                if tagged { answer += " (Murmur saw the tag; its published release page wasn't seen)" }
                let notes = (item.fields["notes"] ?? "").split(separator: " ").prefix(30).joined(separator: " ")
                answer += notes.isEmpty ? "." : ": \(notes)\(notes.hasSuffix(".") ? "" : "…")"
                if releases.count > 1 { answer += " Before that: " + releases.dropFirst().prefix(2).map(\.item.title).joined(separator: ", ") + "." }
                return answer
            }
        }
        // "What did I do yesterday?", "what did I work on this morning?".
        if says(question, aboutDoing), let span = span(of: question, now: now, calendar: calendar) {
            let episodes = graph.episodes(from: span.from, to: span.to).filter { $0.seconds >= 5 * 60 }
            guard !episodes.isEmpty else { return nil }
            let top = episodes.sorted { $0.seconds > $1.seconds }.prefix(6).sorted { $0.start < $1.start }
            let total = episodes.reduce(0) { $0 + $1.seconds }
            return "\(minutes(total)) of work: " + top.map { "\($0.name) (\(minutes($0.seconds)))" }.joined(separator: "; ") + "."
        }
        return nil
    }

    /// The span a question is about ("yesterday", "this morning", "last week", "on Tuesday"), nil when it doesn't say.
    static func span(of query: String, now: Date, calendar: Calendar) -> (from: Date, to: Date)? {
        let lower = query.lowercased()
        let today = calendar.startOfDay(for: now)
        if lower.contains("yesterday") { return (today.addingTimeInterval(-86400), today) }
        if lower.contains("this morning") { return (today, today.addingTimeInterval(12 * 3600)) }
        if lower.contains("this afternoon") { return (today.addingTimeInterval(12 * 3600), today.addingTimeInterval(18 * 3600)) }
        if lower.contains("this evening") || lower.contains("tonight") { return (today.addingTimeInterval(17 * 3600), now) }
        if lower.contains("today") { return (today, now) }
        if lower.contains("last week") {
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            return (start.addingTimeInterval(-7 * 86400), start)
        }
        if lower.contains("this week") { return (calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today, now) }
        let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let index = days.firstIndex(where: { lower.contains("on " + $0) || lower.contains($0 + "'s") || lower.contains("last " + $0) }) {
            // The last such day before today.
            for back in 1...7 {
                let day = today.addingTimeInterval(Double(-back) * 86400)
                if calendar.component(.weekday, from: day) == index + 1 { return (day, day.addingTimeInterval(86400)) }
            }
        }
        return nil
    }

    static func minutes(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    public static func line(_ episode: MemoryGraph.StoredEpisode, calendar: Calendar = .current) -> String {
        let when = ScreenDates.formatter("EEE d MMM, HH:mm", calendar).string(from: episode.start) + "–"
            + ScreenDates.formatter("HH:mm", calendar).string(from: episode.end)
        var text = "- \(when) (\(minutes(episode.seconds))): \(episode.name)"
        if !episode.summary.isEmpty { text += ". \(episode.summary)" }
        if !episode.outcome.isEmpty { text += " Outcome: \(episode.outcome)." }
        let places = episode.apps.prefix(3).joined(separator: ", ")
        return text + " [what you did, in \(places)]"
    }

    static func line(_ stored: MemoryGraph.StoredItem, calendar: Calendar) -> String {
        if stored.item.mine, [.post, .message].contains(stored.item.kind) {
            let at = ScreenDates.formatter("EEE d MMM, HH:mm", calendar).string(from: stored.item.when ?? stored.first)
            let label = stored.item.kind == .post ? "you posted" : "you sent"
            return "- \(at): " + stored.item.body.replacingOccurrences(of: "\n", with: "; ") + " [\(label); exact]"
        }
        let seen = ScreenDates.formatter("d MMM", calendar).string(from: stored.last)
        let where_ = stored.item.fields["url"].flatMap { URL(string: $0)?.host } ?? stored.item.fields["repository"] ?? stored.item.kind.rawValue
        return "- " + stored.item.body.replacingOccurrences(of: "\n", with: "; ") + " [seen on screen, \(where_), \(seen); exact]"
    }

    /// Lines for a question about the user's world, the most certain first; empty when nothing here applies.
    public static func lines(for query: String, graph: MemoryGraph, brain: BrainStore, vectors: MemoryVectors? = nil,
                             vector: [Float]? = nil, now: Date = Date(), calendar: Calendar = .current, limit: Int = 14) -> [String] {
        var lines: [String] = []
        var shownItems = Set<Int64>(), shownEpisodes = Set<Int64>()
        func add(_ stored: MemoryGraph.StoredItem) {
            guard !shownItems.contains(stored.id) else { return }
            shownItems.insert(stored.id)
            lines.append(line(stored, calendar: calendar))
        }
        func add(_ episode: MemoryGraph.StoredEpisode) {
            guard !shownEpisodes.contains(episode.id) else { return }
            shownEpisodes.insert(episode.id)
            lines.append(line(episode, calendar: calendar))
        }
        // 0. Open business with people: threads with whom the question names, or all that need the user, ranked.
        var shownThreads = Set<Int64>()
        func add(_ thread: MemoryThread) {
            guard !shownThreads.contains(thread.id) else { return }
            shownThreads.insert(thread.id)
            lines.append(Threads.line(thread, now: now, calendar: calendar))
        }
        for thread in graph.threads(matching: query, limit: 3, now: now) { add(thread) }
        if says(query, aboutPriorities) { for thread in graph.openThreads(now: now, limit: 6) { add(thread) } }
        // 1. What's certain: flights and releases, when the question is about them.
        if says(query, aboutTravel) {
            let coming = graph.upcoming(now: now, limit: 4)
            for stored in coming { add(stored) }
            if coming.isEmpty { for stored in graph.items([.flight, .booking], limit: 3) { add(stored) } }
        }
        if says(query, aboutReleases) {
            let releases = ItemReader.uniqueReleases(graph.items([.release], limit: 30)).sorted {
                ItemReader.newerVersion($0.item.fields["version"] ?? "", than: $1.item.fields["version"] ?? "")
            }
            let mine = releases.filter(\.item.mine)
            for stored in (mine.isEmpty ? releases : mine).prefix(4) { add(stored) }
        }
        // Emails the user sent: to whom the question names, else on the day it names, else the latest.
        if says(query, aboutEmail) {
            for stored in sentEmails(for: query, graph: graph, now: now, calendar: calendar).prefix(5) { add(stored) }
        }
        // What the user put out (posts, messages, emails), when the question is about telling people: the latest on
        // the places it names, each with its day, so the answer can set them against the release (or say none came
        // after it).
        if says(query, aboutSharing) {
            for stored in sharedByTheUser(for: query, graph: graph) { add(stored) }
        }
        // 2. Items whose words match (an email's subject, a file, an issue), pages last.
        let matching = graph.searchItems(query, limit: 10)
        for stored in matching.filter({ $0.item.kind != .page }).prefix(4) { add(stored) }
        // 3. What the user did: the episodes of the span the question names, else those that match its words and
        //    meaning.
        if let span = span(of: query, now: now, calendar: calendar), says(query, aboutDoing) || says(query, ["what", "which"]) {
            let episodes = graph.episodes(from: span.from, to: span.to).filter { $0.seconds >= 120 }
            for episode in episodes.sorted(by: { $0.seconds > $1.seconds }).prefix(8).sorted(by: { $0.start < $1.start }) { add(episode) }
        }
        var found = graph.searchEpisodes(query, limit: 5)
        if let vector, let vectors {
            let near = MemorySearch.kept(vectors.search(vector, kinds: [.episode], limit: 6, floor: MemorySearch.floor))
            let ids = MemoryVectors.fuse([found.map(\.id), near.map(\.ref)])
            let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
            found = ids.sorted { $0.value > $1.value }.compactMap { byID[$0.key] ?? graph.episode(id: $0.key) }
        }
        for episode in found.prefix(4) { add(episode) }
        // 4. How what the question names is connected.
        for entity in brain.entities(namedIn: query, limit: 2) {
            lines += connections(of: entity.id, name: entity.name, graph: graph, calendar: calendar)
        }
        var unique: [String] = []
        for line in lines where !unique.contains(line) { unique.append(line) }
        return Array(unique.prefix(limit))
    }

    /// What an entity is connected to: "You worked on Murmur: 14 h, last Fri 6 Nov; you released it on 6 Nov; Priya
    /// Sharma is in it", with its latest episodes.
    public static func connections(of entity: Int64, name: String, graph: MemoryGraph, calendar: Calendar = .current) -> [String] {
        let edges = graph.edges(of: entity, limit: 24)
        guard !edges.isEmpty else { return [] }
        var parts: [String] = []
        func day(_ date: Date) -> String { ScreenDates.formatter("EEE d MMM", calendar).string(from: date) }
        for edge in edges {
            let other = edge.src == entity ? edge.dst : edge.src
            guard let (otherName, otherKind) = graph.entityName(other) else { continue }
            let you = otherKind == "me"
            switch edge.rel {
            case "worked_on" where you: parts.append("you worked on it for \(minutes(edge.weight * 3600)) in all, last on \(day(edge.last))")
            case "released" where you: parts.append("you released it (last on \(day(edge.last)))")
            case "talked_with" where you: parts.append("you talked with them, last on \(day(edge.last))")
            case "involved_in" where edge.src == entity: parts.append("part of \(otherName)")
            case "involved_in": parts.append("\(otherName) is in it")
            default: continue
            }
        }
        guard !parts.isEmpty else { return [] }
        var lines = ["- \(name): " + parts.prefix(6).joined(separator: "; ") + " [connections seen on screen]"]
        if let core = Optional(BrainModel.projectCore(name)), !core.isEmpty {
            lines += graph.episodes(ofProject: core, limit: 3).filter { $0.seconds >= 120 }.map { line($0, calendar: calendar) }
        }
        return lines
    }
}
