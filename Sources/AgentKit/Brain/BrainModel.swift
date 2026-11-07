import Foundation

/// The living memory's rules, with no storage or I/O: what a memory is, when a new one confirms, replaces or adds to
/// what's known, how memories fade, and when one is stale. BrainStore keeps them; these decide. Tested on their own
/// (BrainTests).
public enum BrainModel {
    /// What a memory is about.
    public enum EntityKind: String, CaseIterable, Sendable, Codable {
        case person, organization, project, place, topic, me

        public var display: String {
            switch self {
            case .person: return "People"
            case .organization: return "Organizations"
            case .project: return "Projects"
            case .place: return "Places"
            case .topic: return "Topics"
            case .me: return "You"
            }
        }

        /// A kind the model wrote, read leniently ("company" is an organization, "user" is me).
        public static func read(_ text: String) -> EntityKind {
            switch text.lowercased().trimmingCharacters(in: .whitespaces) {
            case "person", "people", "contact", "colleague", "friend", "family": return .person
            case "organization", "organisation", "company", "org", "team", "business", "client": return .organization
            case "project", "deal", "product", "initiative": return .project
            case "place", "location", "city", "address": return .place
            case "me", "user", "self", "i", "the user": return .me
            default: return .topic
            }
        }
    }

    /// What kind of thing a memory says.
    public enum Kind: String, CaseIterable, Sendable, Codable {
        /// Lasting: "Priya works at Acme as a product manager".
        case fact
        /// How two are connected: "Priya is the user's manager".
        case relationship
        /// How the user likes things: "prefers morning meetings".
        case preference
        /// Something on a date: "Design review with Priya on 12 Nov".
        case event
        /// Something to do: "Send Arjun the contract".
        case task
        /// Ongoing work: "Acme deal is in contract review".
        case status

        /// How long until a memory nobody confirms again is worth half as much, in days.
        public var halfLife: Double {
            switch self {
            case .fact, .relationship: return 365
            case .preference: return 180
            case .status: return 45
            case .event, .task: return 30
            }
        }

        public static func read(_ text: String) -> Kind {
            Kind(rawValue: text.lowercased().trimmingCharacters(in: .whitespaces)) ?? .fact
        }
    }

    /// Where a memory came from, as the Memory page says it.
    public enum Origin: String, CaseIterable, Sendable, Codable {
        case told, contacts, calendar, reminders, notes, mail, files, commands, apps, screen

        public var display: String {
            switch self {
            case .told: return "You told Murmur"
            case .contacts: return "Contacts"
            case .calendar: return "Calendar"
            case .reminders: return "Reminders"
            case .notes: return "Notes"
            case .mail: return "Mail"
            case .files: return "Files"
            case .commands: return "Your commands"
            case .apps: return "Connected apps"
            case .screen: return "What you worked on"
            }
        }

        /// How much a memory from here matters by default, when nothing says otherwise: what the user said most, what
        /// they only saw least.
        public var importance: Double {
            switch self {
            case .told: return 1
            case .reminders: return 0.8
            case .calendar: return 0.7
            case .contacts, .commands: return 0.6
            case .notes, .mail, .apps, .files: return 0.55
            case .screen: return 0.45
            }
        }
    }

    /// Something worth remembering, before it's reconciled with what's known.
    public struct Candidate: Sendable, Equatable {
        public var about: String
        public var aboutKind: EntityKind
        public var text: String
        public var kind: Kind
        /// The attribute it fills, when it's the kind of thing a person has one of ("employer", "role", "phone",
        /// "birthday", "city"): a new value replaces the old one instead of sitting beside it.
        public var slot: String?
        /// When it stops being true (an event's end, a task's due date); nil for lasting ones.
        public var expires: Date?
        /// 0 to 1: how sure the source is. Contacts and Calendar are certain; a model reading a note is less so.
        public var confidence: Double
        public var origin: Origin
        /// 0 to 1: how much it matters to the user's own life and work (a promise they made, their manager, their
        /// project) rather than something they only saw (a post in a feed). Important memories last longer and rank
        /// higher; unimportant ones from the screen aren't kept as memories at all.
        public var importance: Double

        public init(about: String, aboutKind: EntityKind, text: String, kind: Kind, slot: String? = nil,
                    expires: Date? = nil, confidence: Double, origin: Origin, importance: Double? = nil) {
            self.about = about
            self.aboutKind = aboutKind
            self.text = text
            self.kind = kind
            self.slot = slot.map(BrainModel.slotKey)
            self.expires = expires
            self.confidence = confidence
            self.origin = origin
            self.importance = min(1, max(0, importance ?? origin.importance))
        }
    }

    /// A memory as it's kept.
    public struct Memory: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var entity: Int64
        public var text: String
        public var kind: Kind
        public var slot: String?
        public var confidence: Double
        public var created: Date
        /// When a source last said it again.
        public var confirmed: Date
        public var expires: Date?
        /// Told by the user: never fades, and nothing a source says replaces it.
        public var pinned: Bool
        public var origin: Origin
        /// How many times Murmur used it in an answer. A memory that keeps being used fades more slowly, the way
        /// recalling something keeps it.
        public var uses: Int
        public var importance: Double

        public init(id: Int64, entity: Int64, text: String, kind: Kind, slot: String?, confidence: Double, created: Date,
                    confirmed: Date, expires: Date?, pinned: Bool, origin: Origin, uses: Int = 0, importance: Double = 0.5) {
            self.id = id
            self.entity = entity
            self.text = text
            self.kind = kind
            self.slot = slot
            self.confidence = confidence
            self.created = created
            self.confirmed = confirmed
            self.expires = expires
            self.pinned = pinned
            self.origin = origin
            self.uses = uses
            self.importance = importance
        }
    }

    /// What to do with a candidate, given what's known about the same thing.
    public enum Decision: Equatable, Sendable {
        /// It says what a memory already says: that memory is confirmed (and becomes surer).
        case confirm(Int64)
        /// It's a newer value for the same slot: it replaces that memory.
        case replace(Int64)
        /// The user said otherwise: what they said stands, and this is dropped.
        case keepTold
        /// Something new.
        case add
    }

    /// Reconciles a candidate with the memories about the same entity.
    public static func decide(_ candidate: Candidate, existing: [Memory]) -> Decision {
        let words = keywords(candidate.text)
        if let same = existing.first(where: { similarity(words, keywords($0.text)) >= 0.7 }) {
            return .confirm(same.id)
        }
        if let slot = candidate.slot, let filled = existing.first(where: { $0.slot == slot }) {
            return filled.pinned && candidate.origin != .told ? .keepTold : .replace(filled.id)
        }
        return .add
    }

    /// How much a memory is worth now, 0 to 1: its confidence, halved every half-life since a source last said it.
    /// Each use in an answer stretches its half-life by a quarter (up to three times as long). Zero once it's
    /// expired; one for what the user told Murmur.
    public static func strength(_ memory: Memory, now: Date = Date()) -> Double {
        if let expires = memory.expires, expires < now { return 0 }
        if memory.pinned { return 1 }
        // Seen on screen with a known end (a flight, a deadline): whole until then, gone after.
        if memory.origin == .screen, memory.expires != nil { return memory.confidence }
        let days = max(0, now.timeIntervalSince(memory.confirmed) / 86400)
        // Importance stretches it (a commitment, a close colleague: up to 1.75 times) or shortens it (something only
        // seen: down to 0.4 times); each use stretches it by a quarter more.
        // What the screen says about how things stand ("the user is preparing the release"), a task or an event seen
        // there, is true for days, not months: it lasts while the screen keeps saying it (each sighting confirms it),
        // and fades in about a week (a status) or two (a task, an event) once it stops.
        let base: Double
        switch (memory.origin, memory.kind) {
        case (.screen, .status): base = 3
        case (.screen, .task), (.screen, .event): base = 7
        default: base = memory.kind.halfLife
        }
        let halfLife = base * (0.25 + 1.5 * min(1, max(0.1, memory.importance)))
            * (1 + 0.25 * Double(min(max(memory.uses, 0), 8)))
        return memory.confidence * pow(0.5, days / halfLife)
    }

    /// A short, stable fingerprint of what something says (FNV-1a), to notice when it changed.
    public static func fingerprint(_ parts: [String?]) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in parts.map({ $0 ?? "" }).joined(separator: "\u{1f}").utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return String(value, radix: 16)
    }

    // MARK: Secrets

    private static let secretPatterns: [NSRegularExpression] = [
        // Keys and tokens: long runs of letters, digits and dashes with a known prefix, or bearer/api key labels.
        #"\b(sk|pk|rk|ghp|gho|ghs|ghu|ghr|github_pat|xox[abpr]|AKIA|ASIA|AIza|ya29|glpat|npm|hf)[-_A-Za-z0-9]{12,}"#,
        // "password: …", "token=…", or a label then a value with a digit in it ("bearer eyJ0…", "password is hunter22");
        // not "the password-field fix" or "a 1M token context window".
        #"(?i)\b(api[_ -]?key|secret|token|bearer|password|passcode|passwd|pwd)\b(?:\s*[:=]\s*["']?[^\s"']{6,}|(?:\s+is)?\s+(?=[^\s]*\d)[^\s]{6,})"#,
        // A secret in an environment variable or a config line: "export AWS_SECRET_ACCESS_KEY=…", "GH_TOKEN: …".
        #"\b[A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD|CREDENTIALS?|AUTH)[A-Z0-9_]*\s*[:=]\s*["']?[^\s"']{6,}"#,
        // A password in an address: "postgres://user:pass@host".
        #"\b[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s@/]+@"#,
        // One-time codes: "code is 482913", "OTP: 4829".
        #"(?i)\b(otp|code|pin|verification)\b[^\n\d]{0,20}\d{4,8}\b"#,
        // Private keys.
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// The text with passwords, keys, one-time codes and card numbers taken out, before the model reads it or
    /// anything is kept.
    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in secretPatterns {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                      withTemplate: "[hidden]")
        }
        // Card numbers: thirteen to nineteen digits that pass the card check digit (not a post's id in a link).
        if let cards = try? NSRegularExpression(pattern: #"\b(?:\d[ -]?){12,18}\d\b"#) {
            for match in cards.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let digits = result[range].compactMap(\.wholeNumberValue)
                let grouped = result[range].contains { $0 == " " || $0 == "-" }
                if (13...19).contains(digits.count), grouped || digits.count <= 16, luhn(digits) {
                    result.replaceSubrange(range, with: "[hidden]")
                }
            }
        }
        // A wallet's recovery phrase (twelve or more of its words in a row).
        for range in RecoveryWords.phrases(in: result).reversed() { result.replaceSubrange(range, with: "[hidden]") }
        return result
    }

    /// The card number check digit (Luhn).
    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            let value = offset % 2 == 1 ? digit * 2 : digit
            sum += value > 9 ? value - 9 : value
        }
        return sum % 10 == 0
    }

    /// Holds something that must never be remembered.
    public static func hasSecret(_ text: String) -> Bool { redact(text) != text }

    /// Below this a memory is stale: it's archived (gone from answers and the page, still there to come back if a
    /// source says it again).
    public static let staleBelow = 0.12

    public static func isStale(_ memory: Memory, now: Date = Date()) -> Bool {
        strength(memory, now: now) < staleBelow
    }

    /// Confirming a memory makes it surer, by less each time.
    public static func confirmed(confidence: Double, by incoming: Double) -> Double {
        min(1, confidence + (1 - confidence) * max(incoming, 0.2) * 0.5)
    }

    // MARK: Words

    private static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "to", "of", "and", "or", "in", "on", "at", "for", "with",
        "as", "by", "it", "its", "this", "that", "has", "have", "had", "user", "user's", "users", "their", "his", "her",
        "they", "he", "she", "from", "will", "who", "which",
    ]

    /// The words that carry a sentence's meaning, lowercased.
    public static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) })
    }

    /// Overlap of two sets of words (Jaccard), 0 to 1.
    public static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// A slot's name, so "Employer", "employer " and "works_at" match.
    public static func slotKey(_ slot: String) -> String {
        let key = slot.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        switch key {
        case "works_at", "company", "workplace", "job_company": return "employer"
        case "job_title", "title", "position", "job": return "role"
        case "phone_number", "mobile", "number": return "phone"
        case "email_address", "mail": return "email"
        case "lives_in", "location", "home_city": return "city"
        case "dob", "date_of_birth", "born": return "birthday"
        default: return key
        }
    }

    /// A name as it's matched: lowercased, without titles or spare spaces.
    /// A project's own name without what changes or decorates it: "Murmur 1.6.0", "Murmur v1.6", "murmur-app",
    /// "shubhamsWEB/murmur-app" and "the Murmur project" are all "murmur". One project, one entity.
    public static func projectCore(_ name: String) -> String {
        var text = name.lowercased()
        if let slash = text.lastIndex(of: "/") { text = String(text[text.index(after: slash)...]) }   // owner/repo
        text = text.replacingOccurrences(of: #"\b(v(ersion)?\s?)?\d+(\.\d+)+[a-z0-9.-]*\b"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[-_.]"#, with: " ", options: .regularExpression)
        var words = text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        if words.first == "the" { words.removeFirst() }
        while let last = words.last, ["app", "application", "project", "repo", "repository", "website", "site", "release",
                                      "beta"].contains(last), words.count > 1 { words.removeLast() }
        return words.joined(separator: " ")
    }

    public static func nameKey(_ name: String) -> String {
        var words = name.lowercased().split { $0.isWhitespace || $0 == "." || $0 == "," }.map(String.init)
        while let first = words.first, ["mr", "mrs", "ms", "dr", "prof", "sir"].contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }
}
