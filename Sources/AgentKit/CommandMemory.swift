import Foundation
import SQLite3

/// Murmur's memory of what you asked and what it did, so a command can follow on from the last one ("and also ask
/// when she's coming back": she is Roma, the app WhatsApp) and the model can look back further when it needs to
/// ("what did I send Roma yesterday?").
///
/// Structured, so it stays small and fast: each command is one row (what you said, where, what kind of thing it
/// was, how it went, a one-line summary), its actions are rows, and the people, files, pages, apps and media it
/// touched are entities linked to it. Everything is worked out from the tool calls themselves: no model call, no
/// embedding, no background work; one short transaction per command. The model always gets a few lines (the
/// latest commands and what's in play), and asks for more with `recall`, which reads the store with an index and
/// full-text search. On this Mac only (~/Library/Application Support/Murmur/memory.sqlite), 90 days or 3,000
/// commands, whichever is less.
///
/// It's also how Murmur fits the way you work: what you tell it to remember ("Mom is Roma, on WhatsApp", "from now on
/// open links in Chrome") is kept as facts, and what it notices from your commands (Roma's messages always go on
/// WhatsApp) as learned defaults, worked out on the fly. Both reach the model with every command; your facts win.
/// The Memory page shows all three, each with a way to forget it.
public enum CommandMemory {
    /// One line on the Memory page: a fact you told Murmur, a pattern it noticed, or a recent command.
    public struct Item: Identifiable, Sendable, Equatable {
        public let id: String
        public let text: String
        public let detail: String
    }

    private static let remembersKey = "memory.remembersCommands"

    /// Whether commands are remembered (on unless you turn it off on the Memory page). Facts you tell Murmur are
    /// kept either way.
    public static var remembersCommands: Bool {
        get { UserDefaults.standard.object(forKey: remembersKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: remembersKey) }
    }

    /// One tool call, as remembered: its name, its main arguments and a short result.
    public struct Action: Sendable {
        let tool: String
        let args: [String: String]
        let result: String
    }

    private struct Entity: Hashable {
        let type: String     // person, app, file, page, media, project
        let name: String
        let detail: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var db: OpaquePointer?
    nonisolated(unsafe) private static var opened = false
    nonisolated(unsafe) private static var lastAt: Date?
    private static let keepDays: Double = 90
    private static let keepCommands = 3000

    // MARK: Writing

    /// Remembers one finished command.
    static func record(said: String, app: String?, window: String?, actions: [Action], answer: String?) {
        let summary = summarise(actions, answer: answer)
        let kind = kindOf(actions)
        let outcome = outcomeOf(actions, answer: answer)
        let entities = entitiesOf(actions, app: app)
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        lastAt = now
        guard remembersCommands, let db = open() else { return }
        exec(db, "BEGIN")
        let episode = insert(db, "INSERT INTO episode(at, said, app, window, kind, outcome, summary, result) VALUES(?,?,?,?,?,?,?,?)",
                             [now.timeIntervalSince1970, said, app ?? "", window ?? "", kind, outcome, summary,
                              String((answer ?? actions.last?.result ?? "").prefix(400))])
        for (index, action) in actions.enumerated() {
            let args = (try? JSONSerialization.data(withJSONObject: action.args, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            _ = insert(db, "INSERT INTO action(episode, seq, tool, args, result) VALUES(?,?,?,?,?)",
                       [episode, index, action.tool, args, String(action.result.prefix(240))])
        }
        for entity in entities {
            exec(db, "INSERT INTO entity(type, name, detail, last_seen, uses) VALUES(?,?,?,?,1) "
                 + "ON CONFLICT(type, name) DO UPDATE SET detail = excluded.detail, last_seen = excluded.last_seen, uses = uses + 1",
                 [entity.type, entity.name, entity.detail, now.timeIntervalSince1970])
            exec(db, "INSERT OR IGNORE INTO mention(episode, entity) SELECT ?, id FROM entity WHERE type = ? AND name = ?",
                 [episode, entity.type, entity.name])
        }
        exec(db, "COMMIT")
    }

    /// Forgets the last command, or every command (and with `facts`, what you told Murmur too).
    public static func forget(all: Bool, facts: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return }
        if facts { exec(db, "DELETE FROM fact") }
        if all {
            for table in ["mention", "action", "entity", "episode"] { exec(db, "DELETE FROM \(table)") }
            exec(db, "INSERT INTO episode_fts(episode_fts) VALUES('rebuild')")
            lastAt = nil
        } else {
            exec(db, "DELETE FROM episode WHERE id = (SELECT max(id) FROM episode)")
            tidy(db)
            lastAt = nil
        }
    }

    // MARK: Facts you tell Murmur

    /// Keeps a fact about you or how you like things done, under a short subject ("Roma", "browser", "message
    /// style"). The same subject again replaces it.
    static func remember(subject: String, fact: String) -> String {
        var key = subject.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // The user's own name always lives under one subject, so search can find it.
        if nameSubjects.contains(key) || name(in: fact) != nil {
            key = "my name"
        }
        let text = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !text.isEmpty else { return "Nothing to remember." }
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return "Memory isn't available." }
        exec(db, "INSERT INTO fact(subject, text, source, at) VALUES(?,?,'told',?) "
             + "ON CONFLICT(subject) DO UPDATE SET text = excluded.text, source = 'told', at = excluded.at",
             [key, text, Date().timeIntervalSince1970])
        return "Remembered: \(text)"
    }

    private static let nameSubjects: Set<String> = ["name", "my name", "user name", "user's name", "username", "full name",
                                                    "own name", "user", "me", "owner", "the user's name"]

    /// "My name is Shubham Agrawal", "call me Shubham", "I'm Shubham" → the name.
    static func name(in fact: String) -> String? {
        let text = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"(?i)^(my (full )?name is|my name's|call me|i am|i'm|the user's name is|user's name is|name:)\s+"#,
                                     options: .regularExpression) else { return nil }
        let name = text[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " .,!\"'"))
        // A name, not "call me at five": a few words, the first capitalised.
        guard let first = name.first, first.isUppercase, name.split(separator: " ").count <= 5 else { return nil }
        return name
    }

    /// The user's own name, when they told Murmur ("my name is Shubham Agrawal", "call me Shubham"): used to find
    /// their own documents ("my resume", "my Aadhaar card").
    public static func ownerName() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return nil }
        for row in rows(db, "SELECT subject, text FROM fact WHERE source = 'told' ORDER BY at DESC", []) {
            if let found = name(in: row[1]) { return found }
            if nameSubjects.contains(row[0]), row[1].split(separator: " ").count <= 4 { return row[1] }
        }
        return nil
    }

    /// Drops the facts whose subject or text has these words.
    static func unremember(_ words: String) -> String {
        let wanted = words.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return "Which one?" }
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return "Memory isn't available." }
        let gone = rows(db, "SELECT text FROM fact WHERE source = 'told' AND (subject = ? OR lower(text) LIKE ?)",
                        [wanted, "%\(wanted)%"]).map { $0[0] }
        exec(db, "DELETE FROM fact WHERE source = 'told' AND (subject = ? OR lower(text) LIKE ?)", [wanted, "%\(wanted)%"])
        return gone.isEmpty ? "There was nothing about \"\(words)\" to forget." : "Forgot: " + gone.joined(separator: "; ")
    }

    /// What you told Murmur, newest first.
    public static func toldFacts() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return [] }
        return rows(db, "SELECT id, text, at FROM fact WHERE source = 'told' ORDER BY at DESC", []).map {
            Item(id: "fact:\($0[0])", text: $0[1], detail: "")
        }
    }

    /// Patterns in your commands, worked out now (nothing stored but the ones you dismissed): who you message where,
    /// the sites and apps you go back to. Only clear patterns: three times or more, and the same way four times in five.
    public static func learned() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return [] }
        return learnedItems(db)
    }

    /// The latest commands, newest first.
    public static func recentCommands(limit: Int = 8) -> [Item] {
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return [] }
        return rows(db, "SELECT id, said, summary, at FROM episode ORDER BY id DESC LIMIT ?", [limit]).map {
            Item(id: "episode:\($0[0])", text: $0[1], detail: "\($0[2]) · \(ago($0[3]))")
        }
    }

    /// Forgets one item from the Memory page: a fact, a learned pattern (it stays dismissed), or a command.
    public static func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "fact": exec(db, "DELETE FROM fact WHERE id = ?", [Int(parts[1]) ?? -1])
        case "learned":
            exec(db, "INSERT INTO fact(subject, text, source, at) VALUES(?, '', 'dismissed', ?) "
                 + "ON CONFLICT(subject) DO UPDATE SET source = 'dismissed'", ["learned:" + parts[1], Date().timeIntervalSince1970])
        case "episode":
            exec(db, "DELETE FROM episode WHERE id = ?", [Int(parts[1]) ?? -1])
            tidy(db)
        default: break
        }
    }

    private static func learnedItems(_ db: OpaquePointer) -> [Item] {
        let dismissed = Set(rows(db, "SELECT subject FROM fact WHERE source = 'dismissed'", []).map { $0[0] })
        var items: [Item] = []
        // Who you message where.
        let messages = rows(db, """
            SELECT lower(json_extract(args, '$.to')), json_extract(args, '$.to'), json_extract(args, '$.app'), count(*)
            FROM action WHERE tool = 'send_message' AND json_extract(args, '$.app') != ''
            GROUP BY 1, lower(json_extract(args, '$.app')) ORDER BY 1, 4 DESC
            """, [])
        var seen = Set<String>()
        for person in Set(messages.map { $0[0] }).sorted() {
            let rowsFor = messages.filter { $0[0] == person }
            let total = rowsFor.reduce(0) { $0 + (Int($1[3]) ?? 0) }
            guard let top = rowsFor.first, let count = Int(top[3]), total >= 3, Double(count) / Double(total) >= 0.8 else { continue }
            let key = "message:\(person)"
            guard !dismissed.contains("learned:" + key), seen.insert(key).inserted else { continue }
            items.append(Item(id: "learned:" + key, text: "Messages \(top[1]) on \(top[2])",
                              detail: "\(count) of \(total) messages"))
        }
        // Sites and apps you go back to (the last 30 days).
        let since = Date().timeIntervalSince1970 - 30 * 86400
        let opened = rows(db, """
            SELECT a.tool, coalesce(json_extract(a.args, '$.url'), json_extract(a.args, '$.name')) FROM action a
            JOIN episode e ON e.id = a.episode WHERE e.at > ? AND a.tool IN ('open_url', 'open_app')
            """, [since])
        var counts: [String: (label: String, count: Int)] = [:]
        for row in opened {
            let label: String
            if row[0] == "open_url" {
                var address = row[1].lowercased()
                if !address.contains("://") { address = "https://" + address }
                guard let host = URL(string: address)?.host?.replacingOccurrences(of: "www.", with: "") else { continue }
                label = host
            } else {
                label = row[1]
            }
            guard !label.isEmpty else { continue }
            counts[label.lowercased(), default: (label, 0)].count += 1
        }
        for (key, value) in counts.sorted(by: { $0.value.count > $1.value.count }) where value.count >= 3 {
            let id = "often:\(key)"
            guard !dismissed.contains("learned:" + id) else { continue }
            items.append(Item(id: "learned:" + id, text: "Often opens \(value.label)", detail: "\(value.count) times this month"))
            if items.count >= 8 { break }
        }
        return Array(items.prefix(8))
    }

    // MARK: Preferences: memory as every command uses it

    /// What memory means for the command at hand, read once per command and applied by the actions themselves, on
    /// every path (the quick one without a model too): your name for your documents, your browser for links, who
    /// "Mom" is and where you message each person. What no action can apply on its own is in `notes`, for the
    /// model, and a request that mentions it goes to the model (`touches`).
    public struct Preferences: Sendable {
        /// Your name ("Shubham Agrawal").
        public var owner: String?
        /// The browser for links and searches ("Chrome").
        public var browser: String?
        /// Nicknames to people: "mom" → "Roma".
        public var aliases: [String: String] = [:]
        /// Where each person is messaged: "roma" → "WhatsApp" (what you said first, then what Murmur noticed).
        public var chatApps: [String: String] = [:]
        /// Everything you told Murmur, as you said it.
        public var notes: [String] = []
        /// Words that point at something in memory.
        var cues: Set<String> = []

        /// The person a name or nickname means: "Mom" → "Roma".
        public func person(_ said: String) -> String {
            let key = said.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^my "#, with: "",
                                                                                                options: .regularExpression)
            return aliases[key] ?? said
        }

        /// The app a person is messaged on.
        public func chatApp(for person: String) -> String? {
            let key = person.lowercased()
            return chatApps[key] ?? chatApps[String(key.split(separator: " ").first ?? "")]
        }

        /// Whether the request mentions someone or something in memory (a nickname, a person, a subject you taught
        /// Murmur): then the model, which sees all of memory, handles it rather than a quick pattern.
        public func touches(_ utterance: String) -> Bool {
            let lower = utterance.lowercased()
            let words = Set(lower.split { !$0.isLetter }.map(String.init))
            return !cues.isDisjoint(with: words) || aliases.keys.contains { $0.contains(" ") && lower.contains($0) }
        }
    }

    private static let chatAppNames = ["whatsapp": "WhatsApp", "slack": "Slack", "telegram": "Telegram", "signal": "Signal",
                                       "imessage": "Messages", "messages": "Messages", "teams": "Teams", "discord": "Discord"]
    private static let browserNames = ["chrome": "Chrome", "safari": "Safari", "arc": "Arc", "brave": "Brave",
                                       "edge": "Edge", "firefox": "Firefox", "opera": "Opera", "vivaldi": "Vivaldi"]
    private static let plainWords: Set<String> = [
        "my", "the", "a", "an", "to", "of", "in", "on", "is", "and", "for", "with", "at", "it", "me", "i", "be", "always",
        "never", "use", "open", "opens", "link", "links", "message", "messages", "style", "short", "name", "browser",
        "keep", "make", "write", "reply", "replies", "please", "from", "now", "app", "apps",
    ]

    /// Memory, read for one command.
    public static func preferences() -> Preferences {
        lock.lock(); defer { lock.unlock() }
        var prefs = Preferences()
        guard let db = open() else { return prefs }
        for row in rows(db, "SELECT subject, text FROM fact WHERE source = 'told' ORDER BY at DESC", []) {
            let subject = row[0], text = row[1], lower = text.lowercased()
            prefs.notes.append(text)
            if let owner = name(in: text) {
                if prefs.owner == nil { prefs.owner = owner }
                continue
            }
            // "Open links in Chrome", "browser: Safari".
            if prefs.browser == nil, subject.contains("browser")
                || lower.range(of: #"\b(link|links|browser|web|site|sites|page|pages|url|search)\b"#, options: .regularExpression) != nil,
               let found = browserNames.first(where: { lower.range(of: "\\b\($0.key)\\b", options: .regularExpression) != nil }) {
                prefs.browser = found.value
                continue
            }
            // "Mom is Roma, on WhatsApp", "my boss is Rahul Mehta", "Roma is my mom".
            var person: String?
            if let found = groups(#"^(?i:my )?((?i:[a-z][a-z' ]{0,20}?)) is (?i:my )?([A-Z][\p{L}]+(?: [A-Z][\p{L}]+)?)"#, text) {
                prefs.aliases[found[0].lowercased()] = found[1]
                person = found[1]
            } else if let found = groups(#"^([A-Z][\p{L}]+(?: [A-Z][\p{L}]+)?) is my ((?i:[a-z][a-z ]{0,20}))"#, text) {
                prefs.aliases[found[1].lowercased().trimmingCharacters(in: .whitespaces)] = found[0]
                person = found[0]
            } else if let found = groups(#"([A-Z][\p{L}]+(?: [A-Z][\p{L}]+)?)\b.*\b(?i:on|via|over) (?i:whatsapp|slack|telegram|signal|imessage|messages|teams|discord)\b"#, text) {
                person = found[0]
            }
            // "Message Asha on Slack": the verb isn't part of the name.
            if let said = person, let first = said.split(separator: " ").first,
               ["message", "text", "send", "ping", "email", "call", "whatsapp", "dm", "tell"].contains(first.lowercased()) {
                let rest = said.split(separator: " ").dropFirst().joined(separator: " ")
                person = rest.isEmpty ? nil : rest
            }
            if let person {
                for word in person.lowercased().split(separator: " ") { prefs.cues.insert(String(word)) }
                if let app = chatAppNames.first(where: { lower.range(of: "\\b\($0.key)\\b", options: .regularExpression) != nil }) {
                    prefs.chatApps[person.lowercased()] = app.value
                }
            }
            // Anything else you taught Murmur: its subject words point at it.
            for word in subject.split(separator: " ").map(String.init) where word.count > 2 && !plainWords.contains(word) {
                prefs.cues.insert(word)
            }
        }
        for alias in prefs.aliases.keys {
            for word in alias.split(separator: " ").map(String.init) where !plainWords.contains(word) { prefs.cues.insert(word) }
        }
        // Where you've been messaging people, when you didn't say.
        for (person, app, _, _) in learnedChatApps(db) where prefs.chatApps[person] == nil {
            prefs.chatApps[person] = app
        }
        return prefs
    }

    /// The first match's capture groups.
    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Who you've messaged where: (person, app, times on that app, times in all), for a clear habit only.
    private static func learnedChatApps(_ db: OpaquePointer) -> [(String, String, Int, Int)] {
        let messages = rows(db, """
            SELECT lower(json_extract(args, '$.to')), json_extract(args, '$.app'), count(*)
            FROM action WHERE tool = 'send_message' AND json_extract(args, '$.app') != ''
            GROUP BY 1, lower(json_extract(args, '$.app')) ORDER BY 1, 3 DESC
            """, [])
        var out: [(String, String, Int, Int)] = []
        for person in Set(messages.map { $0[0] }).sorted() {
            let forPerson = messages.filter { $0[0] == person }
            let total = forPerson.reduce(0) { $0 + (Int($1[2]) ?? 0) }
            guard let top = forPerson.first, let count = Int(top[2]), total >= 3, Double(count) / Double(total) >= 0.8 else { continue }
            out.append((person, top[1], count, total))
        }
        return out
    }

    // MARK: Reading

    /// Seconds since the last command finished.
    public static var sinceLast: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        if !opened { _ = open() }
        return lastAt.map { Date().timeIntervalSince($0) }
    }

    /// What the model always gets, in a few lines: the latest commands (last two hours) and what's in play (the
    /// people, files, pages and apps of the last day, most recent first).
    static func workingSet() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return nil }
        let now = Date().timeIntervalSince1970
        let recent = rows(db, "SELECT id, at, app, said, summary, outcome FROM episode WHERE at > ? ORDER BY id DESC LIMIT 5",
                          [now - 2 * 3600]).reversed()
        let things = rows(db, "SELECT type, name, detail, last_seen FROM entity WHERE last_seen > ? ORDER BY last_seen DESC LIMIT 8",
                          [now - 24 * 3600])
        let told = rows(db, "SELECT text FROM fact WHERE source = 'told' ORDER BY at DESC LIMIT 20", []).map { $0[0] }
        let noticed = learnedItems(db)
        guard !recent.isEmpty || !things.isEmpty || !told.isEmpty || !noticed.isEmpty else { return nil }
        var lines: [String] = []
        if !told.isEmpty {
            lines.append("The user told you (follow these over everything else):")
            lines.append(contentsOf: told.map { "- \($0)" })
        }
        if !noticed.isEmpty {
            lines.append("Noticed from their commands (defaults when they don't say otherwise): "
                         + noticed.map { "\($0.text) (\($0.detail))" }.joined(separator: "; "))
        }
        if !recent.isEmpty {
            lines.append("Latest commands (oldest first):")
            for row in recent {
                lines.append("#\(row[0]) \(ago(row[1])) in \(row[2].isEmpty ? "?" : row[2]): \"\(row[3])\" → \(row[4]) [\(row[5])]")
            }
        }
        if !things.isEmpty {
            lines.append("In play: " + things.map { row in
                "\(row[0]) \(row[1])" + (row[2].isEmpty || row[2] == row[1] ? "" : " (\(row[2].prefix(70)))") + " \(ago(row[3]))"
            }.joined(separator: "; "))
        }
        lines.append("Older history: call recall.")
        return lines.joined(separator: "\n")
    }

    /// The model's look further back: commands matching the words (people, files, pages, what was said or
    /// answered), optionally of one kind and within some days, newest first, with what each did.
    static func recall(_ query: String, kind: String, days: Double) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return "Memory isn't available." }
        let since = Date().timeIntervalSince1970 - max(days, 0.01) * 86400
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        var found: [[String]]
        let kindFilter = kind.isEmpty || kind == "any" ? "" : " AND e.kind = '\(kind.filter(\.isLetter))'"
        if words.isEmpty {
            found = rows(db, "SELECT e.id, e.at, e.app, e.said, e.summary, e.outcome, e.result FROM episode e WHERE e.at > ?\(kindFilter) "
                         + "ORDER BY e.id DESC LIMIT 15", [since])
        } else {
            let match = words.map { "\"\($0)\"*" }.joined(separator: " OR ")
            found = rows(db, """
                SELECT e.id, e.at, e.app, e.said, e.summary, e.outcome, e.result FROM episode e
                WHERE e.at > ?\(kindFilter) AND (e.id IN (SELECT rowid FROM episode_fts WHERE episode_fts MATCH ?)
                   OR e.id IN (SELECT m.episode FROM mention m JOIN entity n ON n.id = m.entity WHERE \(words.map { _ in "lower(n.name) LIKE ?" }.joined(separator: " OR "))))
                ORDER BY e.id DESC LIMIT 15
                """, ([since, match] as [Any]) + words.map { "%\($0)%" as Any })
        }
        guard !found.isEmpty else { return "Nothing in memory\(words.isEmpty ? "" : " about \"\(query)\"") from the last \(Int(max(days, 1))) days." }
        return found.map { row in
            var line = "#\(row[0]) \(when(row[1])) in \(row[2].isEmpty ? "?" : row[2]): \"\(row[3])\" → \(row[4]) [\(row[5])]"
            if !row[6].isEmpty, !row[4].contains(row[6].prefix(40)) { line += "\n    result: \(row[6].prefix(240))" }
            return line
        }.joined(separator: "\n")
    }

    /// "and also ask when she's coming back", "tell him too", "do it again", "send it", said within a few minutes
    /// of a command: it follows on from it, so it's a command too (it was typed into the box as dictation).
    public static func isFollowUp(_ utterance: String) -> Bool {
        guard let since = sinceLast, since < 300 else { return false }
        let text = QuickCommands.clean(utterance)
        // Follow-ups are short and say what to do: "and also ask her…", "send it", "tell him too". A sentence that
        // only starts with "Also" or "And" ("Also I noticed a bug…") is dictation.
        guard text.split(separator: " ").count <= 20 else { return false }
        return text.range(of: #"^(and|also|and also|then|and then|plus|oh and|one more thing|after that) (please )?(ask|tell|send|message|text|whatsapp|open|play|pause|stop|search|find|show|remind|reply|call|email|ping|close|quit|turn|set|check|add|delete|forward|share|save|copy|paste|summari[sz]e|translate|write|type|book|schedule|do)\b|^(tell|ask|send|message|text|reply to|remind|let|call|ping|email|show|give) (her|him|them|it|that|those)\b|^(do it|do that|same thing|do it again|try again|undo that|send it|send that|open it|play it|paste it)\b"#,
                          options: .regularExpression) != nil
    }

    /// The files opened in the last day, newest first (their names).
    public static func recentFiles() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let db = open() else { return [] }
        return rows(db, "SELECT name FROM entity WHERE type = 'file' AND last_seen > ? ORDER BY last_seen DESC LIMIT 10",
                    [Date().timeIntervalSince1970 - 24 * 3600]).map { $0[0] }
    }

    /// "forget that", "forget the last command": .last. "clear your memory", "forget everything": .all.
    public static func forgetRequest(_ utterance: String) -> Bool? {
        let text = QuickCommands.clean(utterance)
        if text.range(of: #"^(forget|clear|erase|wipe|delete) (everything|all|all of it|your memory|the memory|my history|the history|what you remember|all my commands)\b"#,
                      options: .regularExpression) != nil { return true }
        if text.range(of: #"^(forget|delete|erase) (that|this|it|the last (command|one|thing|message)|what i (just )?(said|asked))$"#,
                      options: .regularExpression) != nil { return false }
        return nil
    }

    // MARK: Structure from the tool calls

    private static let looking: Set<String> = [
        "read_screen", "browser_read", "browser_scroll", "browser_tabs", "wait", "app_dictionary", "find_apps",
        "list_running_apps", "list_shortcuts", "recall",
    ]

    private static func kindOf(_ actions: [Action]) -> String {
        for action in actions where !looking.contains(action.tool) {
            switch action.tool {
            case "send_message": return "message"
            case "open_file", "search_files", "open_folder": return "file"
            case "open_url", "web_search", "site_search", "browser_click", "browser_type", "browser_switch_tab": return "web"
            case "media_control": return "media"
            case "calendar_events", "reminders_list": return "calendar"
            case "write_in_app", "insert_text", "replace_selection", "type_text": return "write"
            case "build_with_agent", "coding_followup", "ask_claude", "ask_codex": return "code"
            case "open_app", "quit_app", "hide_app": return "app"
            case "reply": continue
            default:
                if action.tool.hasPrefix("set_") || ["mute", "set_volume", "change_volume", "brightness", "lock_screen",
                                                     "open_settings"].contains(action.tool) { return "setting" }
            }
        }
        return actions.contains { $0.tool == "reply" } ? "answer" : "other"
    }

    private static func outcomeOf(_ actions: [Action], answer: String?) -> String {
        let last = (actions.last?.result ?? "").lowercased()
        if last.contains("chose not to") || last.contains("cancelled") || last.contains("said no") || last.contains("declined") {
            return "declined"
        }
        if answer != nil { return "answered" }
        if last.contains("couldn't") || last.contains("failed") || last.contains("error") || last.contains("can't") { return "problem" }
        return actions.isEmpty ? "nothing done" : "done"
    }

    /// One line on what the command did: "messaged Roma on WhatsApp: “hi”; opened interview.mp4".
    private static func summarise(_ actions: [Action], answer: String?) -> String {
        var parts: [String] = []
        for action in actions where !looking.contains(action.tool) {
            let a = action.args
            let part: String
            switch action.tool {
            case "send_message": part = "messaged \(a["to"] ?? "?") on \(a["app"].flatMap { $0.isEmpty ? nil : $0 } ?? "chat"): “\((a["text"] ?? "").prefix(80))”"
            case "open_file": part = "opened \(openedName(action) ?? a["query"] ?? "a file")"
            case "open_url": part = "opened \(a["url"] ?? "a page")"
            case "web_search": part = "searched the web for “\(a["query"] ?? "")”"
            case "site_search": part = "searched \(a["site"] ?? "a site") for “\(a["query"] ?? "")”"
            case "search_files": part = "searched files for “\(a["query"] ?? "")”"
            case "media_control": part = "\(a["action"] ?? "played") media"
            case "calendar_events":
                let days = Int(Double(a["days"] ?? "1") ?? 1)
                part = "read the calendar for \(a["start"] ?? "today")" + (days > 1 ? " and the \(days - 1) days after" : "")
            case "reminders_list": part = "read reminders"
            case "open_app": part = "opened \(a["name"] ?? "an app")"
            case "quit_app": part = "quit \(a["name"] ?? "an app")"
            case "write_in_app": part = "wrote in \(a["app"] ?? "an app")"
            case "browser_click": part = "clicked “\((a["text"] ?? "").prefix(40))”"
            case "reply": part = "answered: “\((a["text"] ?? "").prefix(100))”"
            case "build_with_agent": part = "started building: \((a["task"] ?? "").prefix(60))"
            case "coding_followup": part = "told the coding session: \((a["message"] ?? "").prefix(60))"
            default: part = action.tool.replacingOccurrences(of: "_", with: " ")
            }
            if parts.last != part { parts.append(part) }
        }
        if parts.isEmpty, let answer { parts.append("answered: “\(answer.prefix(100))”") }
        return parts.isEmpty ? "nothing" : parts.prefix(5).joined(separator: "; ")
    }

    private static func entitiesOf(_ actions: [Action], app: String?) -> [Entity] {
        var found: [Entity] = []
        if let app, !app.isEmpty { found.append(Entity(type: "app", name: app, detail: "")) }
        for action in actions {
            let a = action.args
            switch action.tool {
            case "send_message":
                if let to = a["to"], !to.isEmpty { found.append(Entity(type: "person", name: to, detail: a["app"] ?? "")) }
                if let chat = a["app"], !chat.isEmpty { found.append(Entity(type: "app", name: chat, detail: "")) }
            case "open_file":
                if let name = openedName(action) { found.append(Entity(type: "file", name: name, detail: a["query"] ?? "")) }
            case "open_url", "web_search", "site_search":
                let page = a["url"] ?? [a["site"], a["query"]].compactMap { $0 }.joined(separator: ": ")
                if !page.isEmpty { found.append(Entity(type: "page", name: String(page.prefix(120)), detail: "")) }
            case "open_app", "write_in_app":
                if let name = a["name"] ?? a["app"], !name.isEmpty { found.append(Entity(type: "app", name: name, detail: "")) }
            case "media_control":
                found.append(Entity(type: "media", name: String(action.result.prefix(80)), detail: ""))
            case "build_with_agent", "coding_followup":
                if let folder = a["folder_name"], !folder.isEmpty { found.append(Entity(type: "project", name: folder, detail: "")) }
            default: break
            }
        }
        return Array(Set(found))
    }

    /// "Opened interview.mp4." / "Playing interview.mp4." → interview.mp4
    private static func openedName(_ action: Action) -> String? {
        guard let range = action.result.range(of: #"^(Opened|Playing) (.+?)\.?$"#, options: .regularExpression) else { return nil }
        let text = String(action.result[range])
        return text.replacingOccurrences(of: #"^(Opened|Playing) "#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    // MARK: SQLite

    private static func open() -> OpaquePointer? {
        if opened { return db }
        opened = true
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Murmur")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(folder.appendingPathComponent("memory.sqlite").path, &handle) == SQLITE_OK else { return nil }
        db = handle
        for statement in [
            "PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL", "PRAGMA foreign_keys = ON",
            """
            CREATE TABLE IF NOT EXISTS episode(id INTEGER PRIMARY KEY, at REAL NOT NULL, said TEXT NOT NULL, app TEXT,
              window TEXT, kind TEXT, outcome TEXT, summary TEXT, result TEXT)
            """,
            "CREATE INDEX IF NOT EXISTS episode_at ON episode(at)",
            """
            CREATE TABLE IF NOT EXISTS action(episode INTEGER NOT NULL REFERENCES episode(id) ON DELETE CASCADE,
              seq INTEGER, tool TEXT, args TEXT, result TEXT)
            """,
            "CREATE INDEX IF NOT EXISTS action_episode ON action(episode)",
            """
            CREATE TABLE IF NOT EXISTS entity(id INTEGER PRIMARY KEY, type TEXT NOT NULL, name TEXT NOT NULL COLLATE NOCASE, detail TEXT,
              last_seen REAL, uses INTEGER, UNIQUE(type, name))
            """,
            "CREATE INDEX IF NOT EXISTS entity_seen ON entity(last_seen)",
            """
            CREATE TABLE IF NOT EXISTS mention(episode INTEGER NOT NULL REFERENCES episode(id) ON DELETE CASCADE,
              entity INTEGER NOT NULL REFERENCES entity(id) ON DELETE CASCADE, PRIMARY KEY(episode, entity))
            """,
            "CREATE INDEX IF NOT EXISTS mention_entity ON mention(entity)",
            """
            CREATE TABLE IF NOT EXISTS fact(id INTEGER PRIMARY KEY, subject TEXT NOT NULL UNIQUE, text TEXT NOT NULL,
              source TEXT NOT NULL, at REAL)
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS episode_fts USING fts5(said, summary, result, content='episode',
              content_rowid='id', tokenize='unicode61 remove_diacritics 2')
            """,
            """
            CREATE TRIGGER IF NOT EXISTS episode_ai AFTER INSERT ON episode BEGIN
              INSERT INTO episode_fts(rowid, said, summary, result) VALUES (new.id, new.said, new.summary, new.result); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS episode_ad AFTER DELETE ON episode BEGIN
              INSERT INTO episode_fts(episode_fts, rowid, said, summary, result) VALUES ('delete', old.id, old.said, old.summary, old.result); END
            """,
        ] { exec(handle!, statement) }
        // Keep it small: 90 days, 3,000 commands.
        exec(handle!, "DELETE FROM episode WHERE at < ?", [Date().timeIntervalSince1970 - keepDays * 86400])
        exec(handle!, "DELETE FROM episode WHERE id <= (SELECT max(id) FROM episode) - ?", [keepCommands])
        tidy(handle!)
        if let last = rows(handle!, "SELECT max(at) FROM episode", []).first?.first, let seconds = Double(last) {
            lastAt = Date(timeIntervalSince1970: seconds)
        }
        return db
    }

    /// People, files and pages no command mentions any more go too.
    private static func tidy(_ db: OpaquePointer) {
        exec(db, "DELETE FROM entity WHERE id NOT IN (SELECT entity FROM mention)")
    }

    private static func bind(_ statement: OpaquePointer?, _ values: [Any]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            case let number as Double: sqlite3_bind_double(statement, position, number)
            default: sqlite3_bind_text(statement, position, "\(value)", -1, transient)
            }
        }
    }

    @discardableResult
    private static func exec(_ db: OpaquePointer, _ sql: String, _ values: [Any] = []) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private static func insert(_ db: OpaquePointer, _ sql: String, _ values: [Any]) -> Int64 {
        exec(db, sql, values)
        return sqlite3_last_insert_rowid(db)
    }

    private static func rows(_ db: OpaquePointer, _ sql: String, _ values: [Any]) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var out: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            out.append((0..<count).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }

    private static func ago(_ seconds: String) -> String {
        guard let at = Double(seconds) else { return "" }
        let minutes = Int((Date().timeIntervalSince1970 - at) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 24 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / (24 * 60)) d ago"
    }

    private static func when(_ seconds: String) -> String {
        guard let at = Double(seconds) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: at))
    }
}
