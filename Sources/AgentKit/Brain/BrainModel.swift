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
        case told, contacts, calendar, reminders, notes, mail, files, commands

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

        public init(about: String, aboutKind: EntityKind, text: String, kind: Kind, slot: String? = nil,
                    expires: Date? = nil, confidence: Double, origin: Origin) {
            self.about = about
            self.aboutKind = aboutKind
            self.text = text
            self.kind = kind
            self.slot = slot.map(BrainModel.slotKey)
            self.expires = expires
            self.confidence = confidence
            self.origin = origin
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

        public init(id: Int64, entity: Int64, text: String, kind: Kind, slot: String?, confidence: Double, created: Date,
                    confirmed: Date, expires: Date?, pinned: Bool, origin: Origin, uses: Int = 0) {
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
        let days = max(0, now.timeIntervalSince(memory.confirmed) / 86400)
        let halfLife = memory.kind.halfLife * (1 + 0.25 * Double(min(max(memory.uses, 0), 8)))
        return memory.confidence * pow(0.5, days / halfLife)
    }

    // MARK: Secrets

    private static let secretPatterns: [NSRegularExpression] = [
        // Keys and tokens: long runs of letters, digits and dashes with a known prefix, or bearer/api key labels.
        #"\b(sk|pk|rk|ghp|gho|ghs|xox[abpr]|AKIA|AIza|ya29|glpat|npm)[-_A-Za-z0-9]{12,}"#,
        #"(?i)\b(api[_ -]?key|secret|token|bearer|password|passcode|passwd|pwd)\b\s*[:=]?\s*\S{6,}"#,
        // One-time codes: "code is 482913", "OTP: 4829".
        #"(?i)\b(otp|code|pin|verification)\b[^\n\d]{0,20}\d{4,8}\b"#,
        // Card numbers.
        #"\b(?:\d[ -]?){13,19}\b"#,
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
        return result
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
    public static func nameKey(_ name: String) -> String {
        var words = name.lowercased().split { $0.isWhitespace || $0 == "." || $0 == "," }.map(String.init)
        while let first = words.first, ["mr", "mrs", "ms", "dr", "prof", "sir"].contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }
}
