import Foundation

/// Where the speaker changes inside one stretch of the call. Stretches are cut at pauses, but people often start
/// talking the moment someone else stops ("…what do you think?" "Yeah, so…"), and then one stretch holds two
/// people: it would be written down as one line under one name. The segmentation model (pyannote, through
/// FluidAudio, on this Mac) says, for every sixtieth of a second of a ten-second window, which of up to three
/// people in that window is talking; this turns that into the places to cut. The parts are then transcribed and
/// given a voice separately, like any other stretch.
///
/// Nothing here knows who anyone is: the model's speakers are only "first, second, third in this window". Who a part
/// belongs to is decided afterwards by its voiceprint, so a cut that wasn't needed costs nothing but a line break.
public enum SpeakerTurns {
    /// Seconds per frame of the model's answer (270 samples at 16 kHz).
    public static let frame = 0.016875
    /// The model's window (seconds), and how far apart windows start on a longer stretch: they overlap, so a change
    /// near the end of one is in the middle of the next.
    public static let window = 10.0
    public static let step = 8.0
    /// Someone's turn is cut out only when it's this long (seconds): "Thank you for having us" gets a line of its
    /// own; a "Mm" inside another person's speech stays in their line.
    public static let shortestTurn = 0.6
    /// A stretch shorter than this isn't looked at: there's no room in it for two turns.
    public static let shortestStretch = 2.5
    /// Two cuts closer than this (from overlapping windows) are one.
    public static let sameCut = 1.0
    /// A cut moves to the quietest moment this near it (seconds), so it doesn't land inside a word.
    public static let reach = 0.3

    /// Where each of the model's windows starts (seconds) for a stretch of `seconds`.
    public static func windows(_ seconds: Double) -> [Double] {
        guard seconds > window else { return [0] }
        var starts = Array(stride(from: 0.0, to: seconds - window, by: step))
        starts.append(seconds - window)
        return starts
    }

    /// The cuts in one window: `frames` is the model's answer, for each frame whether each of its speakers is
    /// talking (1) or not (0). Returns seconds from the window's start, in order.
    public static func cuts(_ frames: [[Float]]) -> [Double] {
        // Who has each frame: one person, or nobody (silence, or two at once: left to the turns either side).
        var turns: [(speaker: Int, from: Int, to: Int, spoken: Int)] = []
        for (index, frame) in frames.enumerated() {
            let talking = frame.indices.filter { frame[$0] > 0.5 }
            guard talking.count == 1, let speaker = talking.first else { continue }
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1].to = index + 1
                turns[turns.count - 1].spoken += 1
            } else {
                turns.append((speaker, index, index + 1, 1))
            }
        }
        // Turns too short to be someone go, shortest first; the turns either side join when they're one person.
        let least = Int((shortestTurn / frame).rounded())
        while let index = turns.indices.filter({ turns[$0].spoken < least }).min(by: { turns[$0].spoken < turns[$1].spoken }) {
            turns.remove(at: index)
            if index > 0, index < turns.count, turns[index - 1].speaker == turns[index].speaker {
                turns[index - 1].to = turns[index].to
                turns[index - 1].spoken += turns[index].spoken
                turns.remove(at: index)
            }
        }
        guard turns.count > 1 else { return [] }
        // Between two turns: the middle of the gap.
        return (1..<turns.count).map { Double(turns[$0 - 1].to + turns[$0].from) / 2 * frame }
    }

    /// Cuts from all of a stretch's windows as one list: in order, near-duplicates dropped.
    public static func merged(_ cuts: [Double]) -> [Double] {
        var out: [Double] = []
        for cut in cuts.sorted() where out.last.map({ cut - $0 >= sameCut }) ?? true { out.append(cut) }
        return out
    }

    /// The sample to cut at: the middle of the quietest 30 ms within `reach` of `seconds`.
    public static func quietest(near seconds: Double, in samples: [Float], rate: Double = 16_000,
                                reach: Double = SpeakerTurns.reach) -> Int {
        let span = max(1, Int(rate * 0.03))
        let centre = Int(seconds * rate)
        let from = max(0, centre - Int(reach * rate)), to = min(samples.count - span, centre + Int(reach * rate))
        guard from < to else { return min(max(0, centre), samples.count) }
        var best = (at: centre, energy: Float.greatestFiniteMagnitude)
        var start = from
        while start <= to {
            var energy: Float = 0
            for i in start..<(start + span) { energy += samples[i] * samples[i] }
            // Ties go to the place nearest the cut.
            if energy < best.energy || (energy == best.energy && abs(start + span / 2 - centre) < abs(best.at - centre)) {
                best = (start + span / 2, energy)
            }
            start += span / 2
        }
        return best.at
    }

    // MARK: By voice

    /// A second look, for a change the model missed: the stretch is listened to in windows of `voiceWindow` seconds,
    /// `voiceStep` apart, and each is put to the voice already on the call it's plainly most like (or to none).
    public static let voiceWindow = 3.0
    public static let voiceStep = 1.0
    /// Shorter than this and it isn't looked at this way: there's no room for two people's windows.
    public static let voiceShortest = 6.0
    /// These cuts are known less exactly, so the quiet moment is looked for farther off.
    public static let voiceReach = 0.75

    /// Where the voice changes, from each window's voice (nil: couldn't tell): two windows running of one voice,
    /// later two running of another, nothing else decided between them. Seconds from the stretch's start: halfway
    /// between the end of the last window of the first voice and the start of the first of the second.
    public static func cuts(byVoice windows: [Int?]) -> [Double] {
        // Runs of two or more windows of one voice.
        var runs: [(voice: Int, first: Int, last: Int)] = []
        var index = 0
        while index < windows.count {
            guard let voice = windows[index] else { index += 1; continue }
            var end = index
            while end + 1 < windows.count, windows[end + 1] == voice { end += 1 }
            if end > index { runs.append((voice, index, end)) }
            index = end + 1
        }
        var out: [Double] = []
        for (earlier, later) in zip(runs, runs.dropFirst()) where earlier.voice != later.voice {
            // A window of a third voice between them: not a clean handover, left alone.
            let between = windows[(earlier.last + 1)..<later.first].compactMap { $0 }
            guard between.allSatisfy({ $0 == earlier.voice || $0 == later.voice }) else { continue }
            out.append((Double(earlier.last) * voiceStep + voiceWindow + Double(later.first) * voiceStep) / 2)
        }
        return out
    }

    // MARK: Words

    /// How far (seconds) a cut in the words moves to reach the end of a sentence.
    public static let sentenceReach = 1.2

    /// A stretch's words given to its parts by when each was said (its middle against the cuts, in seconds), so the
    /// stretch is transcribed once, whole, and no word is lost or garbled where it's cut. nil when the words and
    /// their times aren't to be had (a speech model that doesn't give them), or don't add up to `whole`.
    public static func texts(_ words: [TimedWord], cuts: [Double], whole: String) -> [String]? {
        guard !words.isEmpty, !cuts.isEmpty else { return nil }
        func letters(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        guard letters(words.map(\.text).joined()) == letters(whole) else { return nil }
        // People mostly take over at the end of a sentence, and the cut is only known to within a few words: it
        // moves to the nearest sentence end within `sentenceReach` seconds, when there is one.
        var ends: [Double] = []
        for (word, next) in zip(words, words.dropFirst()) where word.text.last.map({ ".?!।。".contains($0) }) == true {
            ends.append((word.end + next.start) / 2)
        }
        let moved = cuts.map { cut -> Double in
            guard let nearest = ends.min(by: { abs($0 - cut) < abs($1 - cut) }), abs(nearest - cut) <= sentenceReach
            else { return cut }
            return nearest
        }
        var parts = [[String]](repeating: [], count: cuts.count + 1)
        for word in words {
            let middle = (word.start + word.end) / 2
            parts[moved.filter { $0 <= middle }.count].append(word.text)
        }
        return parts.map { $0.joined(separator: " ") }
    }

    /// The stretch's parts, one per turn: `cuts` in seconds, each moved to a quiet moment; a part shorter than half
    /// `shortestTurn` joins the one before it.
    public static func parts(_ samples: [Float], cuts: [Double], rate: Double = 16_000) -> [Range<Int>] {
        let least = Int(shortestTurn / 2 * rate)
        var edges = [0]
        for cut in merged(cuts) {
            let at = quietest(near: cut, in: samples, rate: rate)
            if at - (edges.last ?? 0) >= least, samples.count - at >= least { edges.append(at) }
        }
        edges.append(samples.count)
        return (1..<edges.count).map { edges[$0 - 1]..<edges[$0] }
    }
}

/// A word and when it was said, in seconds from the start of what was transcribed.
public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(_ text: String, _ start: Double, _ end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}
