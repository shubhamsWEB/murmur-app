import Foundation

/// Telling a call's voices apart from their voiceprints. Every stretch heard is kept, and the whole meeting is
/// grouped again as each one arrives (stretches joined pair by pair, closest first, until no two groups are within
/// `sameBelow` on average), so an early mistake isn't kept: a voice heard as two people at first becomes one, and a
/// stretch put with the wrong person moves. Each group keeps the number (1, 2…) most of its stretches had before, so
/// a voice's number doesn't change as the grouping does.
///
/// Why not decide each stretch as it comes (as Cicada does, and Murmur did): measured on 14 simulated meetings of
/// 5–8 people on different microphones, deciding once gave 94 % of lines to the right person with 11 people split in
/// two; grouping the whole meeting again, 99 % with 2.
public struct VoiceClusters: Sendable {
    /// Two groups closer than this on average (cosine distance, shared part of the prints taken out) are one voice.
    public static let sameBelow: Float = 0.5
    /// A stretch by itself is a voice only when it's this long (seconds): a short one unlike everyone ("Yeah.", a
    /// cough) is left without a voice rather than made a speaker.
    public static let newVoiceSeconds = 2.0
    /// Past this many stretches the meeting is grouped again only every few stretches (it takes longer as it grows).
    public static let everyTime = 160

    struct Stretch: Sendable {
        /// The print as heard and with the sound narrowed to 4 kHz, each with the shared part taken out, unit length.
        var heard: [Float]
        var narrow: [Float]?
        var seconds: Double
        /// The voice it's with now (nil: none).
        var voice: Int?
        /// Stretches you said are one person share a tie, and are kept together however the grouping goes.
        var tie: Int?
        /// Not grouped with anyone (short, or unlike everyone enough to stand apart), but plainly more like one voice
        /// than any other (`likeliest`): it's shown as theirs, and isn't part of what that voice is known by.
        var loose = false
    }

    /// A stretch left out of every group is still given to the voice it's most like when that voice is within
    /// `looseBelow` of it and the next voice is at least `looseLead` farther: "which of the people here is this?"
    /// is an easier question than "is this the same person?", and a short "Daniel, tell us your story" should carry
    /// its speaker's name. On the simulation's 492 recordings, each against the others in its meeting, the nearest
    /// voice was the right one every time.
    public static let looseBelow: Float = 0.6
    public static let looseLead: Float = 0.15

    private(set) var stretches: [Stretch] = []
    private var nextVoice = 1
    private var nextTie = 1

    public init() {}

    /// How many voices there are.
    public var count: Int { Set(stretches.compactMap(\.voice)).count }

    /// Takes a stretch in (its print as heard, and of the same sound narrowed, when there is one) and groups the
    /// meeting again. Returns the stretch's index, or nil when the print can't be used.
    public mutating func add(heard: [Float], narrow: [Float]?, seconds: Double) -> Int? {
        guard let print = VoiceBackground.remove(VoiceBackground.heard, from: heard) else { return nil }
        stretches.append(Stretch(heard: print, narrow: narrow.flatMap { VoiceBackground.remove(VoiceBackground.narrow, from: $0) },
                                 seconds: seconds, voice: nil))
        if stretches.count <= Self.everyTime || stretches.count % 5 == 0 {
            regroup()
        } else {
            // Between groupings: with the voice it's nearest to, if it's near enough.
            let index = stretches.count - 1
            var best: (voice: Int, distance: Float)?
            for voice in Set(stretches.compactMap(\.voice)) {
                guard let centre = centroid(voice, narrow: false) else { continue }
                let distance = 1 - VoiceMatching.cosine(centre, print)
                if distance < (best?.distance ?? Self.sameBelow) { best = (voice, distance) }
            }
            stretches[index].voice = best?.voice
            adopt()
        }
        return stretches.count - 1
    }

    /// The voice a print (as heard, shared part taken out) is most like, when it's plainly one of them
    /// (`looseBelow`, `looseLead`); with one voice only, near enough is enough.
    public func likeliest(_ print: [Float]) -> Int? {
        var scored: [(voice: Int, distance: Float)] = []
        for voice in Set(stretches.filter { !$0.loose }.compactMap(\.voice)) {
            guard let centre = centroid(voice, narrow: false) else { continue }
            scored.append((voice, 1 - VoiceMatching.cosine(centre, print)))
        }
        scored.sort { $0.distance < $1.distance }
        guard let best = scored.first, best.distance < Self.looseBelow else { return nil }
        if scored.count > 1, scored[1].distance - best.distance < Self.looseLead { return nil }
        return best.voice
    }

    /// The same for a print straight from the model (the shared part still in it).
    public func likeliest(raw print: [Float]) -> Int? {
        VoiceBackground.remove(VoiceBackground.heard, from: print).flatMap { likeliest($0) }
    }

    /// The voice of each stretch, by index (nil: none).
    public var voices: [Int?] { stretches.map(\.voice) }

    /// Groups every stretch again and gives the groups their numbers.
    private mutating func regroup() {
        let n = stretches.count
        guard n > 0 else { return }
        // Average-linkage clustering: distances between groups kept in a table, the two closest joined each round.
        var members: [[Int]] = (0..<n).map { [$0] }
        var alive = [Bool](repeating: true, count: n)
        var table = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) {
                let d = 1 - VoiceMatching.cosine(stretches[i].heard, stretches[j].heard)
                table[i * n + j] = d
                table[j * n + i] = d
            }
        }
        while true {
            var best: (a: Int, b: Int, d: Float)?
            for a in 0..<n where alive[a] {
                for b in (a + 1)..<max(n, a + 1) where alive[b] {
                    let d = table[a * n + b]
                    if d < (best?.d ?? Self.sameBelow) { best = (a, b, d) }
                }
            }
            guard let join = best else { break }
            let (a, b) = (join.a, join.b)
            let na = Float(members[a].count), nb = Float(members[b].count)
            for k in 0..<n where alive[k] && k != a && k != b {
                let d = (na * table[a * n + k] + nb * table[b * n + k]) / (na + nb)
                table[a * n + k] = d
                table[k * n + a] = d
            }
            members[a] += members[b]
            alive[b] = false
        }
        // Groups holding stretches you said are one person are one group.
        var all = (0..<n).filter { alive[$0] }.map { members[$0] }
        var holder: [Int: Int] = [:]   // tie → the group that has it
        var g = 0
        while g < all.count {
            if let tie = all[g].compactMap({ stretches[$0].tie }).first(where: { holder[$0] != nil }),
               let into = holder[tie] {
                all[into] += all[g]
                for t in all[g].compactMap({ stretches[$0].tie }) { holder[t] = into }
                all.remove(at: g)
                // Indices after g moved down by one.
                for (t, at) in holder where at > g { holder[t] = at - 1 }
            } else {
                for t in all[g].compactMap({ stretches[$0].tie }) { holder[t] = g }
                g += 1
            }
        }
        // Groups worth a voice: more than one stretch, or one long enough to be someone.
        let groups = all.filter { $0.count > 1 || stretches[$0[0]].seconds >= Self.newVoiceSeconds }
        // Each keeps the number most of its stretches had; the biggest overlaps choose first.
        var claims: [(group: Int, voice: Int, shared: Int)] = []
        for (g, group) in groups.enumerated() {
            var had: [Int: Int] = [:]
            for index in group { if let voice = stretches[index].voice { had[voice, default: 0] += 1 } }
            claims += had.map { (g, $0.key, $0.value) }
        }
        claims.sort { ($0.shared, -$0.voice) > ($1.shared, -$1.voice) }
        var number = [Int?](repeating: nil, count: groups.count)
        var taken: Set<Int> = []
        for claim in claims where number[claim.group] == nil && !taken.contains(claim.voice) {
            number[claim.group] = claim.voice
            taken.insert(claim.voice)
        }
        for index in stretches.indices {
            stretches[index].voice = nil
            stretches[index].loose = false
        }
        // New groups are numbered in the order first heard.
        for g in groups.indices.sorted(by: { (groups[$0].min() ?? 0) < (groups[$1].min() ?? 0) }) {
            let voice = number[g] ?? nextVoice
            if number[g] == nil { nextVoice += 1 }
            for index in groups[g] { stretches[index].voice = voice }
        }
        adopt()
    }

    /// Stretches left without a voice go to the one they're plainly most like (`likeliest`).
    private mutating func adopt() {
        let alone = stretches.indices.filter { stretches[$0].voice == nil }
        guard !alone.isEmpty else { return }
        let found = alone.map { ($0, likeliest(stretches[$0].heard)) }
        for (index, voice) in found where voice != nil {
            stretches[index].voice = voice
            stretches[index].loose = true
        }
    }

    /// You said two voices are one person: `from`'s stretches are `into`'s, now and as the grouping changes.
    public mutating func merge(_ from: Int, into: Int) {
        guard from != into else { return }
        let both = stretches.indices.filter { stretches[$0].voice == from || stretches[$0].voice == into }
        guard both.contains(where: { stretches[$0].voice == from }) else { return }
        let ties = Set(both.compactMap { stretches[$0].tie })
        let tie = ties.min() ?? nextTie
        if ties.isEmpty { nextTie += 1 }
        for index in stretches.indices where both.contains(index) || stretches[index].tie.map(ties.contains) == true {
            stretches[index].tie = tie
        }
        for index in both { stretches[index].voice = into }
    }

    /// A voice's average print, unit length: as heard (for telling voices apart) or narrowed (for saved voices).
    public func centroid(_ voice: Int, narrow: Bool) -> [Float]? {
        let prints = stretches.filter { $0.voice == voice && !$0.loose }.compactMap { narrow ? $0.narrow : $0.heard }
        guard let size = prints.first?.count else { return nil }
        var sum = [Float](repeating: 0, count: size)
        for print in prints where print.count == size { for i in 0..<size { sum[i] += print[i] } }
        return VoiceMatching.normalized(sum)
    }

    /// Seconds of speech heard from a voice, and in how many stretches.
    public func heard(_ voice: Int) -> (seconds: Double, stretches: Int) {
        let own = stretches.filter { $0.voice == voice && !$0.loose }
        return (own.reduce(0) { $0 + $1.seconds }, own.count)
    }

    /// What remembering a voice learns from: its stretches' narrowed prints and lengths.
    public func samples(_ voice: Int) -> [(print: [Float], seconds: Double)] {
        stretches.filter { $0.voice == voice && !$0.loose }
            .compactMap { stretch in stretch.narrow.map { ($0, stretch.seconds) } }
    }
}
