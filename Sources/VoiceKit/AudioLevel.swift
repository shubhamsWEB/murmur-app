import Foundation

/// Brings a recording to a steady speaking level before transcription, so soft speech and whispers are heard as well
/// as normal speech. Speech models are trained mostly on audio at conversational loudness; a whisper on a laptop mic
/// arrives 20–30 dB quieter and is mostly lost.
///
/// Steps: remove DC offset → high-pass at 80 Hz (rumble and fan hum, which would otherwise be boosted too) → measure
/// the speech level (the loudest 5 % of 20 ms frames) and the noise floor (the quietest 10 %) → apply one gain that
/// brings speech to about −20 dBFS, capped at `maxGainDB` and never more than keeps speech clearly above the noise →
/// soft-limit peaks so nothing clips.
enum AudioLevel {
    struct Result {
        let samples: [Float]
        let speechDB: Float
        let noiseDB: Float
        let gainDB: Float
    }

    static func normalize(_ input: [Float], sampleRate: Float = 16_000, maxGainDB: Float) -> Result {
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

        // Frame loudness (20 ms frames).
        let frame = Int(sampleRate / 50)
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame + 1)
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for i in start..<(start + frame) { sum += samples[i] * samples[i] }
            levels.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        guard !levels.isEmpty else { return Result(samples: samples, speechDB: -120, noiseDB: -120, gainDB: 0) }
        let sorted = levels.sorted()
        let speech = max(sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.95))], 1e-6)
        let noise = max(sorted[Int(Float(sorted.count) * 0.10)], 1e-6)
        let speechDB = 20 * log10(speech)
        let noiseDB = 20 * log10(noise)

        // Gain toward −20 dBFS speech, capped, and only boosting when there is speech above the noise.
        let targetDB: Float = -20
        var gainDB = min(maxGainDB, max(0, targetDB - speechDB))
        if speechDB - noiseDB < 6 { gainDB = min(gainDB, 6) }   // nothing but noise: don't turn it into a roar
        let gain = powf(10, gainDB / 20)

        // Apply gain with a soft limiter above 0.8 so peaks round off instead of clipping.
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
        return Result(samples: samples, speechDB: speechDB, noiseDB: noiseDB, gainDB: gainDB)
    }
}
