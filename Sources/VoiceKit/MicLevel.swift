import Foundation

/// Murmur sets the microphone's input level (System Settings › Sound › Input level) itself, so nobody has to.
///
/// A level turned down (the MacBook's own microphone was at 27 %) makes every word arrive faint, and nothing after
/// the microphone brings back what wasn't recorded: Murmur's gain lifts the hiss with the voice, and soft words and
/// word endings were misheard unless you spoke up. Clear voice used to cover this (macOS's voice processing evens the
/// level out), and since it's off by default, nothing did.
///
/// Two rules. At the start of a dictation, a level under half is raised to 70 % straight away. After each one, the
/// level moves a step toward a voice arriving around −20 dBFS: up a step when the voice came in under −26 dBFS, down a
/// step when it was over −12 dBFS or came close to clipping. A recording with too little voice in it (under 10 dB
/// above the noise) isn't judged. Between 35 % and 95 %, never at either end.
public enum MicLevel {
    /// A level under this is raised at the start of a dictation.
    public static let floor: Float = 0.5
    /// What a level that low is raised to.
    public static let start: Float = 0.7
    public static let highest: Float = 0.95
    public static let lowest: Float = 0.35
    public static let step: Float = 0.1

    /// At the start of a dictation: the level to set first, or nil to leave it.
    public static func atStart(_ volume: Float) -> Float? {
        volume < floor ? start : nil
    }

    /// After a dictation: the next level from how loud the voice arrived (before any gain), or nil to leave it.
    /// `peakDB`: the loudest sample, in dBFS.
    public static func after(volume: Float, speechDB: Float, noiseDB: Float, peakDB: Float) -> Float? {
        guard speechDB - noiseDB >= 10 else { return nil }
        if peakDB > -2 || speechDB > -12 {
            let lower = max(lowest, volume - step)
            return lower < volume - 0.005 ? lower : nil
        }
        if speechDB < -26 {
            let higher = min(highest, volume + step)
            return higher > volume + 0.005 ? higher : nil
        }
        return nil
    }

    /// The loudest sample, in dBFS.
    public static func peakDB(_ samples: [Float]) -> Float {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        return 20 * log10(max(peak, 1e-6))
    }
}
