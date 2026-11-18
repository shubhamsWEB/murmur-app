import Foundation
import Testing
@testable import VoiceKit

/// Getting a dictation to Sarvam: pieces under 30 seconds cut between words, a 16-bit WAV, a multipart form.
struct SarvamAudioTests {
    /// Speech-like audio (loud) with a quiet gap at `quietAt` seconds.
    func audio(seconds: Double, quietAt: [Double]) -> [Float] {
        var samples = (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        for at in quietAt {
            for i in Int(at * 16_000)..<min(samples.count, Int((at + 0.4) * 16_000)) { samples[i] = 0 }
        }
        return samples
    }

    @Test func aShortDictationGoesInOnePiece() {
        let samples = audio(seconds: 12, quietAt: [])
        #expect(SarvamAudio.pieces(samples) == [0..<samples.count])
        #expect(SarvamAudio.pieces([]).isEmpty)
    }

    @Test func aLongOneIsCutAtItsPausesUnderThirtySeconds() {
        let samples = audio(seconds: 70, quietAt: [24, 49])
        let pieces = SarvamAudio.pieces(samples)
        #expect(pieces.count == 3)
        #expect(pieces.first?.lowerBound == 0 && pieces.last?.upperBound == samples.count)
        for (a, b) in zip(pieces, pieces.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        for piece in pieces { #expect(Double(piece.count) / 16_000 <= SarvamAudio.maxSeconds) }
        // The first cut lands in the pause at 24 s.
        let cut = Double(pieces[0].upperBound) / 16_000
        #expect(cut > 24 && cut < 24.4)
    }

    @Test func theWavIs16BitMonoAt16kHz() {
        let wav = SarvamAudio.wav([0, 1, -1, 0.5][...])
        #expect(wav.count == 44 + 8)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let bits = wav[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
        #expect(rate == 16_000 && bits == 16)
        let second = wav[46..<48].withUnsafeBytes { $0.loadUnaligned(as: Int16.self).littleEndian }
        #expect(second == Int16.max)
    }

    @Test func theFormCarriesFieldsAndFile() {
        let body = String(decoding: SarvamAudio.form(boundary: "B", fields: [("model", "saaras:v4")], file: Data("x".utf8)), as: UTF8.self)
        #expect(body.contains("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nsaaras:v4\r\n"))
        #expect(body.contains("name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\nx\r\n--B--\r\n"))
    }

    @Test func outputsAndKeyterms() {
        // English letters by default (Hindi came out in Devanagari), on Saaras v4, falling back to v3.
        #expect(SarvamAudio.Output.standard == .latin)
        #expect(SarvamAudio.Output.latin.fields().contains { $0 == ("model", "saaras:v4") })
        #expect(SarvamAudio.Output.latin.fields().contains { $0 == ("mode", "translit") })
        #expect(SarvamAudio.Output.latin.fields(onV3: true).contains { $0 == ("model", "saaras:v3") })
        #expect(SarvamAudio.Output.spoken.fields(onV3: true).first?.1 == "saaras:v4")
        #expect(SarvamAudio.Output.english.takesKeyterms())
        #expect(!SarvamAudio.Output.english.takesKeyterms(onV3: true))
        #expect(SarvamAudio.keyterms(["Sudoku", "Copico"]) == #"["Sudoku","Copico"]"#)
        #expect(SarvamAudio.keyterms([]) == nil)
        #expect(SarvamAudio.keyterms((0..<80).map { "Word\($0)" }).map { $0.components(separatedBy: ",").count } == 50)
    }
}
