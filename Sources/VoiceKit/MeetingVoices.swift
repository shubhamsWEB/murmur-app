import AVFoundation
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
    /// Two prints closer than this (cosine distance) are one voice. WeSpeaker's prints of one person sit around
    /// 0.2–0.4 apart; of two people, above 0.6.
    static let sameBelow: Float = 0.5
    /// Shorter than this (seconds) and a print says too little.
    static let shortest = 1.0
    /// At most this many voices; past it, a new one is taken as the nearest.
    static let most = 8

    private var diarizer: DiarizerManager?
    private var loading: Task<DiarizerManager, Error>?
    private var voices: [(print: [Float], stretches: Int)] = []

    /// How many voices have spoken so far.
    var count: Int { voices.count }

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
    func reset() { voices = [] }

    /// The voice (1, 2…) that said this stretch (16 kHz), or nil when it's too short or the model isn't here.
    func who(_ samples: [Float]) -> Int? {
        guard let diarizer, Double(samples.count) / 16_000 >= Self.shortest else { return nil }
        // The middle 10 seconds of a longer stretch: what the model takes.
        let window = 160_000
        let clip = samples.count > window
            ? Array(samples[((samples.count - window) / 2)..<((samples.count - window) / 2 + window)]) : samples
        guard let print = try? diarizer.extractSpeakerEmbedding(from: clip), !print.isEmpty else { return nil }
        return place(print)
    }

    /// Puts a print with the voice it's closest to, or makes it a new one.
    func place(_ print: [Float]) -> Int {
        let distances = voices.map { Self.distance($0.print, print) }
        if let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }),
           distances[nearest] < Self.sameBelow || voices.count >= Self.most {
            // The voice's print moves toward this one (a running average).
            let n = Float(voices[nearest].stretches)
            voices[nearest].print = zip(voices[nearest].print, print).map { ($0 * n + $1) / (n + 1) }
            voices[nearest].stretches += 1
            return nearest + 1
        }
        voices.append((print, 1))
        return voices.count
    }

    /// Cosine distance: 0 for the same direction, 1 for unrelated, up to 2.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 2 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }
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
