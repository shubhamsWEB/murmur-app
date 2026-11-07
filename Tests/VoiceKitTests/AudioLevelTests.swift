import Foundation
import Testing
@testable import VoiceKit

/// Soft speech over a fan or a room's hum, the case where Murmur used to need you to speak up: a voice a few dB
/// above the noise was boosted only +6 dB, as if it were noise alone, and reached the model at −42 to −49 dBFS.
struct AudioLevelTests {
    static let rate: Float = 16_000

    /// About three syllables a second between 0.5 s and 3.5 s, voiced (115 Hz and its harmonics).
    static func syllable(_ t: Float) -> Bool { (t > 0.5 && t < 3.5) && sinf(2 * .pi * 3 * t) > -0.2 }

    /// A voice at `speechDB` over fan-like noise (more low end than hiss) at `noiseDB`.
    static func recording(speechDB: Float, noiseDB: Float, seconds: Float = 4) -> [Float] {
        let n = Int(rate * seconds)
        var out = [Float](repeating: 0, count: n)
        var seed: UInt64 = 42
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
        }
        let voice = powf(10, speechDB / 20) * 1.414, hum = powf(10, noiseDB / 20) * 1.732
        var low: Float = 0
        for i in 0..<n {
            let t = Float(i) / rate
            var v: Float = 0
            if syllable(t) {
                for h in 1...12 { v += sinf(2 * .pi * (115 + 10 * sinf(t)) * Float(h) * t) / Float(h) }
                v *= voice / 1.6
            }
            low = 0.97 * low + 0.03 * random() * 6
            out[i] = v + hum * (0.6 * random() + 0.8 * low)
        }
        return out
    }

    static func levels(_ samples: [Float]) -> (speech: Float, pauses: Float) {
        var s: Float = 0, p: Float = 0, sc = 0, pc = 0
        for i in samples.indices {
            if syllable(Float(i) / rate) { s += samples[i] * samples[i]; sc += 1 } else { p += samples[i] * samples[i]; pc += 1 }
        }
        return (10 * log10f(s / Float(sc)), 10 * log10f(p / Float(pc)))
    }

    @Test(arguments: [(Float(-52), Float(-56)), (-48, -52), (-55, -60), (-60, -62)])
    func softSpeechOverNoiseReachesTheModelLoudEnough(speech: Float, noise: Float) {
        let leveled = AudioLevel.normalize(Self.recording(speechDB: speech, noiseDB: noise), maxGainDB: 40)
        let out = Self.levels(leveled.samples)
        #expect(out.speech > -26)                 // was −42 to −49 dBFS
        #expect(leveled.noiseReducedDB > 5)       // the fan, taken down first
        #expect(out.speech - out.pauses > 7)      // and the voice clearly above what's left of it
    }

    @Test func aQuietRoomIsLeftAlone() {
        let leveled = AudioLevel.normalize(Self.recording(speechDB: -30, noiseDB: -75), maxGainDB: 40)
        #expect(leveled.noiseReducedDB == 0)
        #expect(abs(Self.levels(leveled.samples).speech + 21) < 3)
    }

    @Test func soundMacOSAlreadyCleanedIsOnlyLeveled() {
        let leveled = AudioLevel.normalize(Self.recording(speechDB: -45, noiseDB: -58), maxGainDB: 40, cleaned: true)
        #expect(leveled.noiseReducedDB == 0)
        #expect(Self.levels(leveled.samples).speech > -26)
    }

    @Test func onlyNoiseIsNotTurnedIntoARoar() {
        var seed: UInt64 = 7
        let noise = (0..<64_000).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 * 0.002 - 0.001
        }
        #expect(AudioLevel.normalize(noise, maxGainDB: 40).gainDB <= 6)
    }

    @Test func noiseReductionKeepsWhatItDoesntTouch() {
        // A loud voice and almost no noise: what comes out is what went in.
        let clean = Self.recording(speechDB: -20, noiseDB: -90)
        let reduced = NoiseReduction.reduce(clean)
        var difference: Float = 0, energy: Float = 0
        for i in clean.indices where Self.syllable(Float(i) / Self.rate) {
            difference += (reduced.samples[i] - clean[i]) * (reduced.samples[i] - clean[i])
            energy += clean[i] * clean[i]
        }
        #expect(10 * log10f(energy / difference) > 15)   // the voice within 15 dB of unchanged
        #expect(reduced.samples.count == clean.count)
    }

    @Test func theFFTGoesThereAndBack() {
        var re = (0..<512).map { sinf(Float($0) * 0.3) + 0.5 * cosf(Float($0) * 1.7) }
        let original = re
        var im = [Float](repeating: 0, count: 512)
        FFT.transform(&re, &im, inverse: false)
        FFT.transform(&re, &im, inverse: true)
        #expect(zip(re, original).allSatisfy { abs($0 - $1) < 1e-4 })
    }
}
