import Foundation

/// Getting a dictation to Sarvam's speech-to-text (Saaras): its REST endpoint takes up to 30 seconds of audio a
/// request, so a longer dictation goes in pieces, each cut at the quietest moment near its end (between words, not
/// in one); each piece is a 16 kHz 16-bit mono WAV, the rate Sarvam works best at, sent as a multipart form.
public enum SarvamAudio {
    /// The longest piece, in seconds: under Sarvam's 30, with room to spare.
    public static let maxSeconds = 28.0
    /// Where in a piece's last stretch a cut may go: the quietest point between this and `maxSeconds`. From 15 s, so
    /// there's nearly always a real pause to cut at, not the middle of a word.
    public static let earliestCut = 15.0
    /// Silence before and after each piece: a speech model drops a word that starts or ends right at the edge of its
    /// audio (Parakeet gets the same after the recording).
    public static let edgeSilence = 0.3

    /// The pieces of `samples` (at `rate`), in order, covering all of it.
    public static func pieces(_ samples: [Float], rate: Double = 16_000) -> [Range<Int>] {
        let longest = Int(maxSeconds * rate), earliest = Int(earliestCut * rate)
        guard samples.count > longest else { return samples.isEmpty ? [] : [0..<samples.count] }
        let window = max(1, Int(0.1 * rate))   // quietness measured over 100 ms
        var pieces: [Range<Int>] = []
        var start = 0
        while samples.count - start > longest {
            // The quietest 100 ms between 15 and 28 seconds into this piece.
            var best = start + longest, quietest = Float.greatestFiniteMagnitude
            var position = start + earliest
            while position + window <= start + longest {
                var energy: Float = 0
                for i in position..<(position + window) { energy += samples[i] * samples[i] }
                if energy < quietest { quietest = energy; best = position + window / 2 }
                position += window / 2
            }
            pieces.append(start..<best)
            start = best
        }
        pieces.append(start..<samples.count)
        return pieces
    }

    /// Samples (−1…1) as a 16-bit PCM mono WAV file, with `edge` seconds of silence before and after.
    public static func wav(_ samples: ArraySlice<Float>, rate: Int = 16_000, edge: Double = 0) -> Data {
        let pad = [Float](repeating: 0, count: Int(edge * Double(rate)))
        let samples = pad[...] + samples + pad[...]
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        data.reserveCapacity(data.count + bytes)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }

    /// A multipart/form-data body: the text fields, then the file.
    public static func form(boundary: String, fields: [(String, String)], file: Data, fileName: String = "audio.wav",
                            contentType: String = "audio/wav") -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
                          + "Content-Type: \(contentType)\r\n\r\n").utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// How Sarvam writes what you say. In English letters unless chosen otherwise: Hindi spoken into Murmur came
    /// out in Devanagari, where people type Hindi and Hinglish in English letters (as the Hinglish model writes it).
    public enum Output: String, CaseIterable, Sendable {
        /// Everything in English letters ("namaste, how are you"): transliteration.
        case latin
        /// Each language in its own script ("नमस्ते, how are you").
        case spoken
        /// Translated to English.
        case english

        public static let standard = Output.latin

        public var display: String {
            switch self {
            case .latin: return "In English letters (Hinglish)"
            case .spoken: return "As spoken (each language in its own script)"
            case .english: return "Translated to English"
            }
        }

        /// The request's model and mode. Saaras v4 first: Sarvam's guide gives it the same modes as v3, its API
        /// reference only v3; `onV3` when v4 refused the mode.
        public func fields(onV3: Bool = false) -> [(String, String)] {
            let model = onV3 && self != .spoken ? "saaras:v3" : "saaras:v4"
            switch self {
            case .spoken: return [("model", model)]
            case .latin: return [("model", model), ("mode", "translit")]
            case .english: return [("model", model), ("mode", "translate")]
            }
        }

        /// Whether terms to listen for can go with it (`keyterms` is Saaras v4's).
        public func takesKeyterms(onV3: Bool = false) -> Bool { self == .spoken || !onV3 }
    }

    /// The languages Sarvam can be told to expect ("unknown": it tells itself), as (code, name).
    public static let languages: [(String, String)] = [
        ("unknown", "Detect automatically"), ("hi-IN", "Hindi"), ("en-IN", "English (India)"), ("bn-IN", "Bengali"),
        ("ta-IN", "Tamil"), ("te-IN", "Telugu"), ("mr-IN", "Marathi"), ("gu-IN", "Gujarati"), ("kn-IN", "Kannada"),
        ("ml-IN", "Malayalam"), ("pa-IN", "Punjabi"), ("od-IN", "Odia"), ("ur-IN", "Urdu"), ("as-IN", "Assamese"),
        ("ne-IN", "Nepali"),
    ]

    /// The `keyterms` field: up to 50 terms of at most 64 characters, as a JSON array.
    public static func keyterms(_ terms: [String]) -> String? {
        let kept = terms.map { String($0.prefix(64)) }.filter { !$0.isEmpty }.prefix(50)
        guard !kept.isEmpty, let data = try? JSONSerialization.data(withJSONObject: Array(kept)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
