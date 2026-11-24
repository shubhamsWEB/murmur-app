import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Who on the call is speaking. Each stretch of the call's sound gets a voice print (FluidAudio's WeSpeaker model, on
/// this Mac: about 30 MB, downloaded once), and stretches whose prints are close are one voice: 1, 2, 3… in the order
/// they first spoke. Your own microphone is never in it (you're "You" already).
///
/// A print needs about a second of speech; a shorter stretch gets no voice of its own (the meeting keeps the last
/// one's, when it follows straight on). Voices are compared with each one's average print, which steadies as it
/// talks more.
actor MeetingVoices {
    /// Shorter than this (seconds) and a print says too little.
    static let shortest = 1.0

    private var diarizer: DiarizerManager?
    private var loading: Task<DiarizerManager, Error>?
    /// Which stretch is whose (`VoiceClusters`: the rules and the numbers behind them).
    private var clusters = VoiceClusters()

    /// How many voices have spoken so far.
    var count: Int { clusters.count }

    /// Downloads (first time only) and loads the voice model. Safe to call more than once.
    func prepare() async throws {
        if diarizer != nil { return }
        if let loading { diarizer = try await loading.value; return }
        let task = Task { () throws -> DiarizerManager in
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            return manager
        }
        loading = task
        do {
            diarizer = try await task.value
            loading = nil
        } catch {
            loading = nil
            throw error
        }
    }

    /// A new meeting: nobody heard yet.
    func reset() { clusters = VoiceClusters() }

    /// Takes a stretch (16 kHz) in. Returns its place among the meeting's stretches and the voice (1, 2…) of every
    /// stretch so far, which can have changed for earlier ones; nil when it's too short to tell or the model isn't
    /// here.
    func hear(_ samples: [Float]) -> (index: Int, voices: [Int?])? {
        guard let heard = print(samples),
              let index = clusters.add(heard: heard, narrow: print(Self.narrowed(samples)),
                                       seconds: Double(samples.count) / 16_000) else { return nil }
        return (index, clusters.voices)
    }

    /// The voice of every stretch so far.
    var voices: [Int?] { clusters.voices }

    /// A stretch (16 kHz) as the parts different people said, in order (`SpeakerTurns`): one part, the whole of it,
    /// when one person spoke throughout, it's too short to hold two turns, or the model isn't here.
    func turns(_ samples: [Float]) -> [Range<Int>] {
        let whole = [0..<samples.count]
        let seconds = Double(samples.count) / 16_000
        guard let diarizer, let model = diarizer.segmentationModel, seconds >= SpeakerTurns.shortestStretch else {
            return whole
        }
        var cuts: [Double] = []
        for start in SpeakerTurns.windows(seconds) {
            let from = min(samples.count, max(0, Int(start * 16_000)))
            let to = min(samples.count, from + Int(SpeakerTurns.window * 16_000))
            guard to > from,
                  let frames = try? diarizer.segmentationProcessor.getSegments(audioChunk: samples[from..<to],
                                                                               segmentationModel: model).segments.first
            else { continue }
            // Frames past the end of the sound are the window's padding.
            let real = min(frames.count, Int((Double(to - from) / 16_000 / SpeakerTurns.frame).rounded(.up)))
            cuts += SpeakerTurns.cuts(Array(frames.prefix(real))).map { $0 + Double(from) / 16_000 }
        }
        let parts = cuts.isEmpty ? whole : SpeakerTurns.parts(samples, cuts: cuts)
        // A second look at each part, by voice, for a change the model missed.
        var more: [Double] = []
        for part in parts {
            for cut in voiceCuts(samples[part]) {
                let at = SpeakerTurns.quietest(near: cut + Double(part.lowerBound) / 16_000, in: samples,
                                               reach: SpeakerTurns.voiceReach)
                more.append(Double(at) / 16_000)
            }
        }
        return more.isEmpty ? parts : SpeakerTurns.parts(samples, cuts: cuts + more)
    }

    /// Where the voice changes in a part, going by the voices already on the call (`SpeakerTurns.cuts(byVoice:)`):
    /// seconds from the part's start. Nothing until two voices are known.
    private func voiceCuts(_ samples: ArraySlice<Float>) -> [Double] {
        let seconds = Double(samples.count) / 16_000
        guard seconds >= SpeakerTurns.voiceShortest, Set(clusters.voices.compactMap { $0 }).count >= 2 else { return [] }
        var windows: [Int?] = []
        var start = 0.0
        while start + SpeakerTurns.voiceWindow <= seconds {
            let from = samples.startIndex + Int(start * 16_000)
            let clip = Array(samples[from..<(from + Int(SpeakerTurns.voiceWindow * 16_000))])
            windows.append(print(clip).flatMap { clusters.likeliest(raw: $0) })
            start += SpeakerTurns.voiceStep
        }
        return SpeakerTurns.cuts(byVoice: windows)
    }

    /// The voice already on the call that a sound is plainly most like, if any (debug runs measure it).
    func likeliest(_ samples: [Float]) -> Int? { print(samples).flatMap { clusters.likeliest(raw: $0) } }

    /// The voice (1, 2…) that said this stretch, for runs that only tell voices apart.
    func who(_ samples: [Float]) -> Int? { hear(samples).flatMap { $0.voices[$0.index] } }

    /// The voiceprint of a stretch (16 kHz), or nil when it's too short or the model isn't here.
    func print(_ samples: [Float]) -> [Float]? {
        guard let diarizer, Double(samples.count) / 16_000 >= Self.shortest else { return nil }
        // The middle 10 seconds of a longer stretch: what the model takes.
        let window = 160_000
        let clip = samples.count > window
            ? Array(samples[((samples.count - window) / 2)..<((samples.count - window) / 2 + window)]) : samples
        guard let print = try? diarizer.extractSpeakerEmbedding(from: clip), !print.isEmpty else { return nil }
        return print
    }

    /// The same sound with nothing above 4 kHz (halved and stretched back), as a phone line or a narrow codec gives:
    /// saved voices are compared in this, so the microphone someone was saved on matters less.
    static func narrowed(_ samples: [Float]) -> [Float] {
        var out = samples
        var i = 0
        while i + 1 < samples.count {
            let a = (samples[i] + samples[i + 1]) / 2
            let b = i + 3 < samples.count ? (samples[i + 2] + samples[i + 3]) / 2 : a
            out[i] = a
            out[i + 1] = (a + b) / 2
            i += 2
        }
        return out
    }

    /// Each voice's print for comparing with saved voices (only voices heard enough to tell: two stretches, or four
    /// seconds).
    func prints() -> [Int: [Float]] {
        var out: [Int: [Float]] = [:]
        for voice in Set(clusters.voices.compactMap { $0 }) {
            let heard = clusters.heard(voice)
            guard heard.stretches >= 2 || heard.seconds >= 4, let print = clusters.centroid(voice, narrow: true) else { continue }
            out[voice] = print
        }
        return out
    }

    /// What remembering a voice learns from.
    func samples(_ voice: Int) -> [(print: [Float], seconds: Double)] { clusters.samples(voice) }
    /// You said two voices are one.
    func merge(_ from: Int, into: Int) { clusters.merge(from, into: into) }

    static func distance(_ a: [Float], _ b: [Float]) -> Float { 1 - VoiceMatching.cosine(a, b) }
}

/// Debug runs: recordings through the voice telling-apart, in order, as one call's stretches: which voice each was
/// taken for. Each file is one stretch by one person.
public enum MeetingVoicesCheck {
    public static func run(_ files: [URL]) async -> [(name: String, voice: Int?, seconds: Double)] {
        let voices = MeetingVoices()
        do { try await voices.prepare() } catch { return files.map { ($0.lastPathComponent, nil, 0) } }
        var out: [(String, Int?, Double)] = []
        for file in files {
            guard let samples = AudioFile16k.read(file) else { out.append((file.lastPathComponent, nil, 0)); continue }
            out.append((file.deletingPathExtension().lastPathComponent, await voices.who(samples), Double(samples.count) / 16_000))
        }
        return out
    }
}

extension MeetingVoicesCheck {
    /// Debug runs: how far apart the voiceprints of recordings are, by who said them (the third part of a name like
    /// "03-them-emma"): for each pair of people, the nearest, middle and farthest distance between their recordings
    /// (a person against themself: between their own). What `VoiceClusters.sameBelow` should sit between.
    public static func distances(_ files: [URL]) async -> [String] {
        let voices = MeetingVoices()
        do { try await voices.prepare() } catch { return ["no voice model: \(error.localizedDescription)"] }
        var prints: [(person: String, print: [Float])] = []
        for file in files {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-").map(String.init)
            guard parts.count >= 3, parts[1] == "them", let samples = AudioFile16k.read(file),
                  let print = await voices.print(samples) else { continue }
            prints.append((parts[2], print))
        }
        let people = Array(Set(prints.map(\.person))).sorted()
        var out = ["\(prints.count) recordings of \(people.count) people"]
        var same: [Float] = [], other: [Float] = []
        var pairs: [(String, [Float])] = [], own: [(String, [Float])] = []
        for (i, a) in people.enumerated() {
            for b in people[i...] {
                var all: [Float] = []
                for (x, p) in prints.enumerated() where p.person == a {
                    for (y, q) in prints.enumerated() where q.person == b && (a != b || y > x) {
                        all.append(MeetingVoices.distance(p.print, q.print))
                    }
                }
                guard !all.isEmpty else { continue }
                all.sort()
                if a == b { same += all; own.append((a, all)) } else { other += all; pairs.append(("\(a)–\(b)", all)) }
            }
        }
        same.sort()
        other.sort()
        func at(_ sorted: [Float], _ share: Double) -> Float {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
        }
        out.append(String(format: "same person, two recordings (%d): median %.2f  90%% %.2f  99%% %.2f  max %.2f",
                          same.count, at(same, 0.5), at(same, 0.9), at(same, 0.99), same.last ?? 0))
        out.append(String(format: "two people (%d): min %.2f  1%% %.2f  5%% %.2f  median %.2f",
                          other.count, other.first ?? 0, at(other, 0.01), at(other, 0.05), at(other, 0.5)))
        for cut in [Float(0.30), 0.35, 0.40, 0.45, 0.50] {
            let split = same.filter { $0 >= cut }.count, merged = other.filter { $0 < cut }.count
            out.append(String(format: "cut %.2f: %.1f%% of same-person pairs farther (split), %.2f%% of two-people pairs closer (merged)",
                              cut, 100 * Double(split) / Double(max(same.count, 1)),
                              100 * Double(merged) / Double(max(other.count, 1))))
        }
        for (person, all) in own.sorted(by: { $0.1.last! > $1.1.last! }).prefix(6) {
            out.append(String(format: "most varied │ %@ │ median %.2f  max %.2f", person, all[all.count / 2], all.last!))
        }
        for (pair, all) in pairs.sorted(by: { $0.1[$0.1.count / 2] < $1.1[$1.1.count / 2] }).prefix(12) {
            out.append(String(format: "most alike │ %@ │ min %.2f  median %.2f  max %.2f", pair, all[0],
                              all[all.count / 2], all.last!))
        }
        return out
    }
}

extension MeetingVoicesCheck {
    /// Debug runs: every recording's voiceprint written out, one JSON object a line (name, seconds, the print as
    /// heard, and the print of the same recording with everything above 4 kHz taken out), so ways of telling voices
    /// apart can be tried on them away from the Mac. Returns how many were written.
    public static func export(_ files: [URL], to url: URL) async -> Int {
        let voices = MeetingVoices()
        do { try await voices.prepare() } catch { return 0 }
        var lines: [String] = []
        func list(_ print: [Float]?) -> String {
            "[" + (print ?? []).map { String(format: "%.4f", $0) }.joined(separator: ",") + "]"
        }
        for file in files {
            guard let samples = AudioFile16k.read(file) else { continue }
            let narrow = MeetingVoices.narrowed(samples)
            let name = file.deletingPathExtension().lastPathComponent
            lines.append(String(format: "{\"name\":\"%@\",\"seconds\":%.2f,\"print\":%@,\"narrow\":%@}", name,
                                Double(samples.count) / 16_000, list(await voices.print(samples)),
                                list(await voices.print(narrow))))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return lines.count
    }
}

/// An audio file as 16 kHz mono samples (its first channel).
enum AudioFile16k {
    static func read(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0] else { return nil }
        let raw = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rate = file.processingFormat.sampleRate
        let samples = rate == 16_000 ? raw : ((try? AudioConverter().resample(raw, from: rate)) ?? [])
        return samples.isEmpty ? nil : samples
    }
}

extension MeetingVoicesCheck {
    /// Debug runs: how well a stretch is cut where the speaker changes (`SpeakerTurns`). Recordings of one person
    /// each ("03-them-emma", in one meeting's folder) are joined end to end, with no pause, as one stretch: the last
    /// seconds of one and the first of the next. Two different people: the cut should be where they join. The same
    /// person twice: no cut is needed (one made there costs only a line break).
    public static func turns(_ files: [URL], most: Int = 150) async -> [String] {
        let voices = MeetingVoices()
        do { try await voices.prepare() } catch { return ["no voice model: \(error.localizedDescription)"] }
        struct Clip { let meeting: String, person: String, url: URL }
        let clips: [Clip] = files.compactMap { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-").map(String.init)
            guard parts.count >= 3, parts[1] == "them" else { return nil }
            return Clip(meeting: url.deletingLastPathComponent().lastPathComponent, person: parts[2], url: url)
        }
        // The meeting's voices are known first, as they would be a few minutes in.
        var truth: [URL: Int] = [:]
        for clip in clips {
            if let samples = AudioFile16k.read(clip.url), let voice = await voices.who(samples) { truth[clip.url] = voice }
        }
        // A short piece of each recording (its second and a half from 0.3 s): which voice is it taken for?
        var shortRight = 0, shortWrong = 0, shortNone = 0
        for clip in clips {
            guard let voice = truth[clip.url], let samples = AudioFile16k.read(clip.url), samples.count > 30_000 else { continue }
            let taken = await voices.likeliest(Array(samples[4_800..<28_800]))
            if taken == nil { shortNone += 1 } else if taken == voice { shortRight += 1 } else { shortWrong += 1 }
        }
        var changes = 0, found = 0, extra = 0, off: [Double] = []
        var same = 0, sameCut = 0, seconds = 0.0, stretches = 0
        func joined(_ a: Clip, _ b: Clip) -> (samples: [Float], at: Double)? {
            guard let first = AudioFile16k.read(a.url), let second = AudioFile16k.read(b.url) else { return nil }
            let head = Array(first.suffix(8 * 16_000)), tail = Array(second.prefix(8 * 16_000))
            return (head + tail, Double(head.count) / 16_000)
        }
        for (index, clip) in clips.enumerated() where changes < most || same < most {
            let later = clips[(index + 1)...].prefix(12).filter { $0.meeting == clip.meeting }
            if changes < most, let other = later.first(where: { $0.person != clip.person }), let made = joined(clip, other) {
                let started = Date()
                let parts = await voices.turns(made.samples)
                seconds += Date().timeIntervalSince(started)
                stretches += 1
                changes += 1
                let cuts = parts.dropFirst().map { Double($0.lowerBound) / 16_000 }
                if let nearest = cuts.min(by: { abs($0 - made.at) < abs($1 - made.at) }), abs(nearest - made.at) <= 0.75 {
                    found += 1
                    off.append(abs(nearest - made.at))
                    extra += cuts.count - 1
                } else {
                    extra += cuts.count
                }
            }
            if same < most, let other = later.first(where: { $0.person == clip.person }), let made = joined(clip, other) {
                same += 1
                if await voices.turns(made.samples).count > 1 { sameCut += 1 }
            }
        }
        off.sort()
        return [
            "changes \(changes) found \(found) extra \(extra) same \(same) sameCut \(sameCut) "
                + "shortRight \(shortRight) shortWrong \(shortWrong) shortNone \(shortNone)",
            String(format: "how far from the change: median %.2f s, worst %.2f s",
                   off.isEmpty ? 0 : off[off.count / 2], off.last ?? 0),
            String(format: "%.0f ms a stretch of about 16 s", stretches == 0 ? 0 : seconds / Double(stretches) * 1_000),
        ]
    }
}
