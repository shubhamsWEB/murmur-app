import Foundation

/// Takes the steady background out of a recording (a fan, an air conditioner, a laptop's hum, a busy room's murmur)
/// so soft speech can be raised without raising the noise with it. Used when macOS's own voice processing isn't on.
///
/// How: the recording in 32 ms slices (512 samples at 16 kHz, half overlapping) → the noise's spectrum from the
/// quietest fifth of them, where you weren't speaking → in every slice, each frequency kept by how far it stands
/// above that noise (a Wiener-style gain), never below −18 dB so what's left sounds natural rather than "watery",
/// and smoothed over time so a word's tail isn't cut → the slices back together. Speech well above the noise passes
/// through all but unchanged; a pause loses most of its hiss.
enum NoiseReduction {
    struct Result {
        let samples: [Float]
        /// How much quieter the background is afterwards, in dB (0 when nothing was done).
        let reducedDB: Float
    }

    static let size = 512
    static let hop = 256
    /// The least a frequency is kept: −18 dB.
    static let floorGain: Float = 0.125

    static func reduce(_ input: [Float]) -> Result {
        let size = Self.size, hop = Self.hop
        guard input.count >= size * 4 else { return Result(samples: input, reducedDB: 0) }
        // √Hann for analysis and synthesis: at half overlap the two multiply to a window that sums to one.
        let window = (0..<size).map { sqrtf(0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(size))) }
        let padded = [Float](repeating: 0, count: hop) + input + [Float](repeating: 0, count: size)
        let count = (padded.count - size) / hop + 1
        let bins = size / 2 + 1

        // Every slice's spectrum, and its loudness.
        var re = [[Float]](), im = [[Float]](), energy = [Float]()
        re.reserveCapacity(count); im.reserveCapacity(count); energy.reserveCapacity(count)
        var fr = [Float](repeating: 0, count: size), fi = [Float](repeating: 0, count: size)
        for f in 0..<count {
            let start = f * hop
            var e: Float = 0
            for i in 0..<size {
                let v = padded[start + i] * window[i]
                fr[i] = v; fi[i] = 0
                e += v * v
            }
            FFT.transform(&fr, &fi, inverse: false)
            re.append(Array(fr[0..<bins])); im.append(Array(fi[0..<bins]))
            energy.append(e)
        }

        // The noise: the average power of each frequency over the quietest fifth of the slices.
        let quiet = Set(energy.indices.sorted { energy[$0] < energy[$1] }.prefix(max(4, count / 5)))
        var noise = [Float](repeating: 0, count: bins)
        for f in quiet { for b in 0..<bins { noise[b] += re[f][b] * re[f][b] + im[f][b] * im[f][b] } }
        for b in 0..<bins { noise[b] = noise[b] / Float(quiet.count) + 1e-12 }
        let noiseEnergy = quiet.reduce(Float(0)) { $0 + energy[$1] } / Float(quiet.count)
        // Next to no noise (a quiet room, a good microphone): leave the recording alone.
        guard noiseEnergy / Float(size) > 1e-9 else { return Result(samples: input, reducedDB: 0) }

        // Each frequency's gain, slice by slice: Wiener-style, with a floor, and released slowly so the end of a
        // word fades instead of being cut.
        var output = [Float](repeating: 0, count: padded.count)
        var previous = [Float](repeating: 1, count: bins)
        var before: Float = 0, after: Float = 0
        for f in 0..<count {
            for b in 0..<bins {
                let power = re[f][b] * re[f][b] + im[f][b] * im[f][b]
                let snr = max(power / noise[b] - 1, 0)          // what stands above the noise
                var gain = snr / (snr + 1.5)                    // a little more than Wiener: hiss goes, speech stays
                gain = max(gain, previous[b] * 0.6)             // release over ~3 slices (about 50 ms)
                gain = max(gain, floorGain)
                previous[b] = gain
                fr[b] = re[f][b] * gain; fi[b] = im[f][b] * gain
            }
            // The other half of the spectrum mirrors the first (the signal is real).
            for b in 1..<(size / 2) { fr[size - b] = fr[b]; fi[size - b] = -fi[b] }
            FFT.transform(&fr, &fi, inverse: true)
            let start = f * hop
            for i in 0..<size { output[start + i] += fr[i] * window[i] }
            if quiet.contains(f) {
                before += energy[f]
                var e: Float = 0
                for i in 0..<size { e += (fr[i] * window[i]) * (fr[i] * window[i]) }
                after += e
            }
        }
        let samples = Array(output[hop..<(hop + input.count)])
        let reduced = after > 0 ? 10 * log10f(before / after) : 0
        return Result(samples: samples, reducedDB: max(0, reduced))
    }
}

/// A plain radix-2 FFT, in place: small and fast enough for a dictation (a minute of audio is a few milliseconds).
enum FFT {
    static func transform(_ re: inout [Float], _ im: inout [Float], inverse: Bool) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var length = 2
        while length <= n {
            let angle = (inverse ? 2 : -2) * Float.pi / Float(length)
            let wr = cosf(angle), wi = sinf(angle)
            var start = 0
            while start < n {
                var cr: Float = 1, ci: Float = 0
                for k in 0..<(length / 2) {
                    let a = start + k, b = a + length / 2
                    let tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    let next = cr * wr - ci * wi
                    ci = cr * wi + ci * wr
                    cr = next
                }
                start += length
            }
            length <<= 1
        }
        if inverse {
            let scale = 1 / Float(n)
            for i in 0..<n { re[i] *= scale; im[i] *= scale }
        }
    }
}
