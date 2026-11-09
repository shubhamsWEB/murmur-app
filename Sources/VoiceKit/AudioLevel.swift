import Foundation

/// Brings a recording to a steady speaking level before transcription, so soft speech and whispers are heard as well
/// as normal speech. Speech models are trained mostly on audio at conversational loudness; a whisper on a laptop mic
/// arrives 20–30 dB quieter and is mostly lost.
///
/// Steps: remove DC offset → high-pass at 80 Hz (rumble and fan hum, which would otherwise be boosted too) → measure
/// the speech level (the loudest 5 % of 20 ms frames) and the noise floor (the quietest 10 %) → when there's
/// background noise and macOS hasn't already cleaned the sound, take it out (NoiseReduction), mix some of the
/// original back in (a tenth to a quarter), and measure again → apply one gain that brings speech to about −20 dBFS, capped at `maxGainDB`
/// → soft-limit peaks so nothing clips.
///
/// Soft speech in a noisy room is the case this is for: a voice only a few dB above a fan used to get no more than
/// +6 dB, as if it were only noise, and reached the model too faint to be heard. Now the noise goes first, and only a
/// recording with nothing above the noise at all (under 3 dB) is held back.
///
/// What it doesn't do, from the research on speech models: change the voice more than it must. Noise removal leaves
/// small distortions in the voice, and those cost a modern speech model more than the noise did (Iwamoto et al.,
/// Interspeech 2022; studies of Whisper and Parakeet found denoised audio recognised worse in every case tested).
/// Mixing some of the original back ("observation adding", from the same paper) takes most of that cost away. A
/// word-by-word boost that was here (soft words raised up to 12 dB) went for the same reason: it reshaped every
/// word, and one steady gain is all the model needs.
enum AudioLevel {
    /// How much of the original goes back under noise-reduced sound: a quarter when the voice stands 10 dB or more
    /// above the noise, down to a tenth when it barely stands out (there the noise, not the distortion, is what
    /// costs the most).
    static func observationShare(speechOverNoiseDB: Float) -> Float {
        0.10 + 0.15 * min(1, max(0, (speechOverNoiseDB - 3) / 7))
    }

    struct Result {
        let samples: [Float]
        let speechDB: Float
        let noiseDB: Float
        let gainDB: Float
        /// How much quieter the background was made, in dB (0 when it wasn't touched).
        var noiseReducedDB: Float = 0
    }

    /// `cleaned`: macOS's voice processing already took the noise out (and set the level), so only the level is
    /// checked here.
    static func normalize(_ input: [Float], sampleRate: Float = 16_000, maxGainDB: Float, cleaned: Bool = false) -> Result {
        guard input.count > 320 else { return Result(samples: input, speechDB: -120, noiseDB: -120, gainDB: 0) }
        var samples = input

        // DC offset.
        var mean: Float = 0
        for v in samples { mean += v }
        mean /= Float(samples.count)

        // One-pole high-pass at 80 Hz.
        let rc = 1 / (2 * Float.pi * 80)
        let dt = 1 / sampleRate
        let alpha = rc / (rc + dt)
        var previousIn = samples[0] - mean
        var previousOut: Float = 0
        for i in 0..<samples.count {
            let x = samples[i] - mean
            let y = alpha * (previousOut + x - previousIn)
            samples[i] = y
            previousIn = x
            previousOut = y
        }

        // Frame loudness (20 ms frames), and the speech and noise levels from them.
        let frame = Int(sampleRate / 50)
        func measure(_ samples: [Float]) -> (levels: [Float], speech: Float, noise: Float) {
            var levels: [Float] = []
            levels.reserveCapacity(samples.count / frame + 1)
            var start = 0
            while start + frame <= samples.count {
                var sum: Float = 0
                for i in start..<(start + frame) { sum += samples[i] * samples[i] }
                levels.append((sum / Float(frame)).squareRoot())
                start += frame
            }
            guard !levels.isEmpty else { return ([], 1e-6, 1e-6) }
            let sorted = levels.sorted()
            return (levels, max(sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.95))], 1e-6),
                    max(sorted[Int(Float(sorted.count) * 0.10)], 1e-6))
        }
        var (levels, speech, noise) = measure(samples)
        guard !levels.isEmpty else { return Result(samples: samples, speechDB: -120, noiseDB: -120, gainDB: 0) }
        let speechDB = 20 * log10(speech)
        let noiseDB = 20 * log10(noise)

        // Background noise worth taking out: what the boost would bring up to where it's heard (above −55 dBFS
        // afterwards), when it's within 30 dB of the speech. Out first, and the levels again.
        var reducedDB: Float = 0
        let boost = min(maxGainDB, max(0, -20 - speechDB))
        if !cleaned, noiseDB + boost > -55, speechDB - noiseDB < 30 {
            let reduced = NoiseReduction.reduce(samples)
            if reduced.reducedDB > 1 {
                // Observation adding: some of the original under the cleaned sound.
                let share = observationShare(speechOverNoiseDB: speechDB - noiseDB)
                let original = samples
                samples = zip(reduced.samples, original).map { (1 - share) * $0 + share * $1 }
                (levels, speech, noise) = measure(samples)
                // How much quieter the background really is, with the original mixed back.
                reducedDB = max(0, noiseDB - 20 * log10(noise))
            }
        }
        let cleanSpeechDB = 20 * log10(speech)
        let cleanNoiseDB = 20 * log10(noise)

        // Gain toward −20 dBFS speech, capped. Held to +6 dB only when nothing at all stands above the noise (under
        // 3 dB, after the noise was taken out): that's a room, not a voice, and isn't worth turning into a roar.
        let targetDB: Float = -20
        var gainDB = min(maxGainDB, max(0, targetDB - cleanSpeechDB))
        if cleanSpeechDB - cleanNoiseDB < 3 { gainDB = min(gainDB, 6) }
        let gain = powf(10, gainDB / 20)

        // One gain, with a soft limiter above 0.8 so peaks round off instead of clipping.
        for i in 0..<samples.count {
            let v = samples[i] * gain
            let a = abs(v)
            if a > 0.8 {
                let over = (a - 0.8) / 0.2
                samples[i] = (v < 0 ? -1 : 1) * (0.8 + 0.2 * tanhf(over))
            } else {
                samples[i] = v
            }
        }
        return Result(samples: samples, speechDB: speechDB, noiseDB: noiseDB, gainDB: gainDB, noiseReducedDB: reducedDB)
    }
}
