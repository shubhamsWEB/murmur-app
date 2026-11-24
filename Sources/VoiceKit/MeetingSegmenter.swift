import Foundation

/// Cuts a running stream of sound (a call, or your microphone) into pieces to transcribe, one per stretch of speech:
/// a piece ends at a pause of `pause` seconds after speech, or at the last short pause once it reaches `longest`
/// seconds (a long speech isn't held back). Stretches with almost no speech (a cough, a click) are dropped.
///
/// Speech is told from quiet by loudness over 30 ms frames against a noise floor that follows the room (it falls at
/// once to a quieter frame and rises slowly), so a fan or a call's hiss isn't taken for a voice.
public struct MeetingSegmenter {
    public let rate: Double
    /// Silence after speech that ends a piece.
    public var pause = 0.6
    /// A piece is cut at its last short pause (or here) once it's this long.
    public var longest = 20.0
    /// Speech a piece needs to be kept.
    public var leastSpeech = 0.35

    private let frame: Int
    private var partial: [Float] = []
    private var piece: [Float] = []
    private var noise: Float = 0.002
    private var voiced = 0
    private var silentRun = 0
    private var heard = false
    /// Where (in `piece`) the latest short pause ended: the place to cut a long piece.
    private var lastPause = 0

    public init(rate: Double) {
        self.rate = rate
        frame = max(1, Int(rate * 0.03))
    }

    private var frameSeconds: Double { Double(frame) / rate }

    /// Adds sound; returns the pieces it finished, in order.
    public mutating func add(_ samples: [Float]) -> [[Float]] {
        var done: [[Float]] = []
        partial.append(contentsOf: samples)
        var start = 0
        while partial.count - start >= frame {
            let chunk = partial[start..<(start + frame)]
            start += frame
            if let finished = take(chunk) { done.append(finished) }
        }
        partial.removeFirst(start)
        return done
    }

    /// What's left at the end, if it holds speech.
    public mutating func flush() -> [Float]? {
        defer { reset() }
        return Double(voiced) * frameSeconds >= leastSpeech ? piece : nil
    }

    /// Seconds of sound held for the piece being made (after a long piece was cut at a pause, what came after the
    /// pause): a piece just finished began this much earlier than its length says.
    public var held: Double { Double(piece.count) / rate }

    /// Someone is speaking now (speech within the last 0.3 s), so a question may not be over yet.
    public var isSpeaking: Bool { heard && Double(silentRun) * frameSeconds < 0.3 }

    /// The loudness of the last frame, 0…1 on a scale from −60 dBFS (silence) to −10 dBFS (loud), for a level meter.
    public private(set) var level: Float = 0

    /// The loudness above which a frame is speech: well above the room's noise, and above −48 dBFS.
    public var threshold: Float { max(noise * 3.2, 0.004) }

    private mutating func take(_ chunk: ArraySlice<Float>) -> [Float]? {
        var sum: Float = 0
        for value in chunk { sum += value * value }
        let rms = (sum / Float(chunk.count)).squareRoot()
        level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 60) / 50))
        let speech = rms > threshold
        if !speech {
            noise = rms < noise ? max(rms, 1e-5) : noise * 0.95 + rms * 0.05
        }
        piece.append(contentsOf: chunk)
        if speech {
            voiced += 1
            silentRun = 0
            heard = true
        } else {
            silentRun += 1
            // A short pause (a quarter second): somewhere a long piece can be cut without splitting a word.
            if heard, Double(silentRun) * frameSeconds >= 0.25 { lastPause = piece.count }
        }
        if !heard {
            // Before anyone speaks, only a moment of lead-in is kept.
            let lead = Int(rate * 0.3)
            if piece.count > lead * 2 { piece.removeFirst(piece.count - lead) }
            return nil
        }
        let seconds = Double(piece.count) / rate
        if Double(silentRun) * frameSeconds >= pause {
            // The end of a stretch of speech; a little of the silence after it stays.
            let keep = piece.count - max(0, silentRun * frame - Int(rate * 0.3))
            let finished = Array(piece[..<keep])
            let enough = Double(voiced) * frameSeconds >= leastSpeech
            reset()
            return enough ? finished : nil
        }
        if seconds >= longest {
            let cut = lastPause > Int(rate * 5) ? lastPause : piece.count
            let finished = Array(piece[..<cut])
            let rest = Array(piece[cut...])
            let enough = Double(voiced) * frameSeconds >= leastSpeech
            reset()
            piece = rest
            heard = !rest.isEmpty
            // The rest was cut out of speech: counted as speech, so its end isn't dropped as a cough.
            if heard { voiced = Int(leastSpeech / frameSeconds) + 1 }
            return enough ? finished : nil
        }
        return nil
    }

    private mutating func reset() {
        piece = []
        voiced = 0
        silentRun = 0
        heard = false
        lastPause = 0
    }
}
