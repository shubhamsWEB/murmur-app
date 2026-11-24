import Foundation

/// A voice you asked Murmur to remember: the name you gave it and the voiceprint it's recognised by. Kept only on
/// this Mac, in Murmur's Application Support folder, never in a meeting's notes or transcript.
public struct VoiceProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Unit-length WeSpeaker print (256 numbers with FluidAudio's model).
    public var print: [Float]
    /// How many stretches of speech it was learned from (it weighs a new meeting's against them).
    public var samples: Int
    public let created: Date
    public var lastSeen: Date
    /// What you keep about the person: company, role, what to remember.
    public var notes: String
    /// How the print was made (`VoiceMatching.kind`): prints made another way can't be compared and are left alone.
    public var kind: Int?

    public init(id: UUID = UUID(), name: String, print: [Float], samples: Int, created: Date = Date(),
                lastSeen: Date = Date(), notes: String = "", kind: Int? = VoiceMatching.kind) {
        self.kind = kind
        self.id = id
        self.name = name
        self.print = print
        self.samples = samples
        self.created = created
        self.lastSeen = lastSeen
        self.notes = notes
    }
}

/// Recognising people across meetings, by voice. Adapted from Cicada's `SpeakerProfiles` and `SpeakerEnrollment`
/// (github.com/wquguru/cicada, Apache-2.0, © wquguru): its thresholds and rules, kept on the Mac the same way.
///
/// The bar for a name is higher than for telling voices apart in one meeting (0.5): a wrong name in someone's notes is
/// worse than "Speaker 2". At `auto` or above, with a clear lead over the next profile, the voice is named without
/// asking; from `suggest`, Murmur asks.
public enum VoiceMatching {
    public static let auto: Float = 0.76
    public static let suggest: Float = 0.55
    /// The best profile must be this far ahead of the second before it's named without asking.
    public static let margin: Float = 0.10
    /// How prints are made now: the sound narrowed to 4 kHz, the part every voice shares taken out
    /// (`VoiceBackground.narrow`). On 14 simulated meetings of 20 voices: 58 of 62 returning people named, none
    /// wrongly, at these thresholds.
    public static let kind = 2
    /// Remembering a voice needs this much of it from the meeting.
    public static let fewestStretches = 3
    public static let fewestSeconds = 6.0
    /// A long stretch counts as this many seconds, so one monologue doesn't make the whole print.
    public static let longestStretch = 12.0
    /// A profile's old print weighs at most this many stretches against a new meeting's.
    public static let heaviest = 20

    public struct Match: Equatable, Sendable {
        public let profile: UUID
        public let name: String
        public let score: Float
        /// Named without asking; otherwise only suggested.
        public let sure: Bool
    }

    /// The profile `print` matches, if any.
    public static func match(_ print: [Float], in profiles: [VoiceProfile]) -> Match? {
        let scored = profiles.filter { $0.kind == kind }.map { ($0, cosine(print, $0.print)) }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= suggest else { return nil }
        let second = scored.dropFirst().first?.1 ?? -1
        return Match(profile: best.0.id, name: best.0.name, score: best.1, sure: best.1 >= auto && best.1 - second >= margin)
    }

    /// Who the voices of a meeting are, all decided together so that one saved person is given to one voice only: the
    /// best-scoring pairs are settled first. `declined`: (voice, profile) pairs you said no to.
    public static func assign(_ voices: [Int: [Float]], in profiles: [VoiceProfile],
                              declined: Set<String> = []) -> [Int: Match] {
        let usable = profiles.filter { $0.kind == kind }
        var scores: [(voice: Int, profile: Int, score: Float)] = []
        for (voice, print) in voices {
            for (index, profile) in usable.enumerated() where !declined.contains("\(voice) \(profile.id)") {
                scores.append((voice, index, cosine(print, profile.print)))
            }
        }
        scores.sort { $0.score > $1.score }
        var out: [Int: Match] = [:], taken: Set<Int> = []
        for entry in scores where entry.score >= suggest && out[entry.voice] == nil && !taken.contains(entry.profile) {
            // Its lead over the next-best saved voice for this voice (taken or not: a near twin is a reason to ask).
            let other = scores.filter { $0.voice == entry.voice && $0.profile != entry.profile }.map(\.score).max() ?? -1
            let profile = usable[entry.profile]
            out[entry.voice] = Match(profile: profile.id, name: profile.name, score: entry.score,
                                     sure: entry.score >= auto && entry.score - other >= margin)
            taken.insert(entry.profile)
        }
        return out
    }

    /// A print for a voice from its stretches in one meeting (each with its own print and length), or nil when
    /// there's too little of it: at least `fewestStretches` stretches and `fewestSeconds` of speech.
    public static func enroll(_ stretches: [(print: [Float], seconds: Double)]) -> [Float]? {
        let usable = stretches.filter { !$0.print.isEmpty && $0.seconds > 0 }
        guard usable.count >= fewestStretches, usable.reduce(0, { $0 + $1.seconds }) >= fewestSeconds,
              let size = usable.first?.print.count, usable.allSatisfy({ $0.print.count == size }) else { return nil }
        var sum = [Float](repeating: 0, count: size)
        for stretch in usable {
            guard let unit = normalized(stretch.print) else { continue }
            let weight = Float(min(stretch.seconds, longestStretch))
            for i in 0..<size { sum[i] += unit[i] * weight }
        }
        return normalized(sum)
    }

    /// A profile's print after a new meeting confirmed it: the old one weighs its stretches (at most `heaviest`), so a
    /// profile learns but a single meeting can't take it over, and it can still be corrected after years.
    public static func blend(_ old: [Float], samples: Int, with fresh: [Float]) -> [Float] {
        guard old.count == fresh.count, let unit = normalized(fresh) else { return old }
        let weight = Float(min(max(samples, 1), heaviest))
        return normalized(zip(old, unit).map { $0 * weight + $1 }) ?? old
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    public static func normalized(_ v: [Float]) -> [Float]? {
        let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0, length.isFinite else { return nil }
        return v.map { $0 / length }
    }
}

/// The saved voices, in one file only this user can read (0600, its folder 0700), left out of backups.
public final class VoiceLibrary: @unchecked Sendable {
    /// Debug runs keep theirs apart (`-debugVoiceLibrary FOLDER`), so a test never touches your saved voices.
    public static let shared = VoiceLibrary(folder: UserDefaults.standard.string(forKey: "debugVoiceLibrary")
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) })

    private let url: URL
    private let lock = NSLock()
    private var cache: [VoiceProfile]?

    /// `folder`: tests keep theirs apart.
    public init(folder: URL? = nil) {
        let base = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Murmur", isDirectory: true)
        url = base.appendingPathComponent("voices.json")
    }

    /// The profiles, by name.
    public var profiles: [VoiceProfile] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let read = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode([VoiceProfile].self, from: $0) } ?? []
        cache = read.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return cache!
    }

    public func profile(_ id: UUID) -> VoiceProfile? { profiles.first { $0.id == id } }

    /// Remembers a voice under `name` (a profile with that name already learns it instead). nil when the name is empty.
    @discardableResult
    public func remember(name: String, print: [Float], samples: Int) -> VoiceProfile? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let unit = VoiceMatching.normalized(print) else { return nil }
        var all = profiles
        if let index = all.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            all[index].print = VoiceMatching.blend(all[index].print, samples: all[index].samples, with: unit)
            all[index].samples += samples
            all[index].lastSeen = Date()
            save(all)
            return all[index]
        }
        let profile = VoiceProfile(name: name, print: unit, samples: samples)
        save(all + [profile])
        return profile
    }

    /// A meeting confirmed `id` (it matched, or you said yes): it learns this meeting's print of the voice.
    public func learn(_ id: UUID, print: [Float], samples: Int) {
        var all = profiles
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].print = VoiceMatching.blend(all[index].print, samples: all[index].samples, with: print)
        all[index].samples += samples
        all[index].lastSeen = Date()
        save(all)
    }

    public func update(_ id: UUID, name: String? = nil, notes: String? = nil) {
        var all = profiles
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { all[index].name = name }
        if let notes { all[index].notes = notes }
        save(all)
    }

    public func forget(_ id: UUID) { save(profiles.filter { $0.id != id }) }
    public func forgetAll() { save([]) }

    private func save(_ all: [VoiceProfile]) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? Self.encoder.encode(all) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #if os(macOS)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try? target.setResourceValues(values)
            #endif
            cache = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            cache = nil
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
