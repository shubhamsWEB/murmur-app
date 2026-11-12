import Testing
@testable import VoiceKit

/// From the 9–11 Nov logs: the MacBook's microphone at 27 %, the voice arriving at −30 to −36 dBFS once Clear voice
/// was off, and words misheard unless spoken up.
struct MicLevelTests {
    @Test func aLevelTurnedDownIsRaisedAtOnce() {
        #expect(MicLevel.atStart(0.27) == 0.7)
        #expect(MicLevel.atStart(0.49) == 0.7)
        #expect(MicLevel.atStart(0.5) == nil)
        #expect(MicLevel.atStart(0.8) == nil)
    }

    @Test func aFaintVoiceMovesTheLevelUpAStep() {
        // 11 Nov: speech −32 dBFS, noise −63 dBFS.
        let next = MicLevel.after(volume: 0.7, speechDB: -32, noiseDB: -63, peakDB: -14)
        #expect(next.map { abs($0 - 0.8) < 0.001 } == true)
        // Never past 95 %.
        #expect(MicLevel.after(volume: 0.95, speechDB: -32, noiseDB: -63, peakDB: -14) == nil)
        #expect(MicLevel.after(volume: 0.9, speechDB: -32, noiseDB: -63, peakDB: -14) == 0.95)
    }

    @Test func aLoudOrClippingVoiceMovesItDown() {
        #expect(MicLevel.after(volume: 0.8, speechDB: -10, noiseDB: -60, peakDB: -6).map { abs($0 - 0.7) < 0.001 } == true)
        #expect(MicLevel.after(volume: 0.8, speechDB: -18, noiseDB: -60, peakDB: -1).map { abs($0 - 0.7) < 0.001 } == true)
        // Never under 35 %.
        #expect(MicLevel.after(volume: 0.35, speechDB: -10, noiseDB: -60, peakDB: -1) == nil)
    }

    @Test func aGoodLevelOrTooLittleVoiceIsLeftAlone() {
        #expect(MicLevel.after(volume: 0.7, speechDB: -20, noiseDB: -60, peakDB: -8) == nil)
        // Mostly noise (a cough, nothing said): not judged.
        #expect(MicLevel.after(volume: 0.7, speechDB: -50, noiseDB: -55, peakDB: -30) == nil)
    }

    @Test func thePeakIsTheLoudestSample() {
        #expect(abs(MicLevel.peakDB([0.1, -0.5, 0.25]) - (-6.02)) < 0.01)
        #expect(MicLevel.peakDB([]) < -100)
    }
}
