import AVFoundation

/// Writes mono Float32 samples to a WAV file (for "Save Last Recording…").
enum WAV {
    static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, value) in samples.enumerated() { channel[i] = value }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }
}
