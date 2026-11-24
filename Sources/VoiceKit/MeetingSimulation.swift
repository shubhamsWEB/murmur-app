import AgentKit
import Foundation

/// Debug runs (`-debugSimulate FOLDER`): many meetings between many people, to set the voice thresholds from numbers.
/// Twenty Sarvam voices (Bulbul v3, Indian English) are four teams of five; fourteen meetings mix them the way real
/// ones do (a team's weekly, two teams together, a few guests, one large call), each person saying six sentences per
/// meeting that they say in no other, on a microphone that differs per person and meeting (clean, phone-band, noisy,
/// quiet). Nobody says a name. Recordings are made once and kept (`FOLDER/mNN/NN-them-person.wav`).
public enum MeetingSimulation {
    static let cast = ["shubh", "aditya", "ritu", "priya", "neha", "rahul", "pooja", "rohan", "simran", "kavya",
                       "amit", "dev", "ishita", "shreya", "ratan", "varun", "manan", "sumit", "roopa", "kabir"]

    /// Who is in each meeting (indices into `cast`: 0–4 team A, 5–9 B, 10–14 C, 15–19 D).
    static let meetings: [[Int]] = [
        [0, 1, 2, 3, 4],                    // 1  A
        [5, 6, 7, 8, 9],                    // 2  B
        [0, 1, 2, 3, 4, 10, 11],            // 3  A + two of C, new
        [10, 11, 12, 13, 14],               // 4  C
        [5, 6, 7, 8, 9, 15, 16],            // 5  B + two of D, new
        [15, 16, 17, 18, 19],               // 6  D
        [0, 1, 2, 3, 4],                    // 7  A again
        [0, 5, 10, 15, 12],                 // 8  one from each team
        [5, 6, 7, 8, 9],                    // 9  B again
        [10, 11, 12, 13, 14, 1, 2],         // 10 C + two of A
        [15, 16, 17, 18, 19, 6, 7, 8],      // 11 D + three of B
        [0, 3, 9, 13, 14, 17, 18],          // 12 a large mixed call
        [0, 1, 2, 3, 4],                    // 13 A a third time
        [4, 5, 11, 19, 15, 12],             // 14 mixed
    ]

    static let sentences = [
        "I looked at the numbers again last night and I think we are slightly ahead of the plan for this month.",
        "Can we go back to the previous point for a moment, because I am not sure we agreed on the owner.",
        "The customer asked for a demo next week, so we need the staging environment to be stable by Monday.",
        "From my side the design is ready, I am only waiting for the final copy from the content team.",
        "I would rather ship a smaller version this week than wait another month for the complete feature.",
        "We had three support tickets about the login page yesterday, and all three came from the mobile app.",
        "Let me share what we learned from the interviews, most people did not understand the pricing page.",
        "The build was failing in the morning because of a missing certificate, it is fixed now.",
        "I think the real risk is the migration, we have never moved this much data in a single weekend.",
        "If we move the deadline by one week, we can include the reporting screen that sales keeps asking for.",
        "The vendor replied this morning, they can deliver the hardware in the second week of next month.",
        "I spoke with finance yesterday, the budget for the new hires is approved until the end of the year.",
        "Our response time went up after the last release, so I want to look at the database queries first.",
        "The onboarding flow has too many steps, we lose almost half of the new users on the third screen.",
        "I can take that task, but I will need help from someone who knows the billing system well.",
        "We should write down the decision today, otherwise we will discuss the same thing again next week.",
        "The marketing campaign starts on the fifteenth, so the landing page has to be live two days before.",
        "I tested the new version on my phone and the search is much faster than it was before.",
        "There is one open question about security, we still have to decide where the keys are stored.",
        "Honestly I think we are trying to do too many things at once, we should pick two and finish them.",
        "The partner team wants a weekly update, I suggest we send a short written summary every Friday.",
        "I checked the logs from the weekend, there were no errors after we restarted the second server.",
        "We promised the client a proposal by Thursday, and I have only finished the first half so far.",
        "The new intern starts on Monday, someone should prepare a small project for the first two weeks.",
        "I agree with the direction, but I would like to see the cost before we commit to that approach.",
        "The test coverage is good for the payment module, the notification module still needs work.",
        "Sales closed two more deals this week, both of them asked about the integration with their calendar.",
        "I am travelling on Wednesday and Thursday, so please send me anything urgent before Tuesday evening.",
        "The feedback from the beta group was positive, the only complaint was about the size of the text.",
        "Let us keep this meeting short today, most of the items can be handled over messages afterwards.",
        "We need a clear owner for the documentation, right now everybody assumes somebody else is doing it.",
        "I compared three providers, the second one is cheaper but their support is only available by email.",
        "The quarterly report is due next Friday, I will share a first draft with everyone by Wednesday.",
        "After the update the app uses less memory, which should help the people with older laptops.",
        "I had a call with legal, they want one more change in the terms before we can publish them.",
        "My suggestion is to run the experiment for two weeks and then decide based on the actual results.",
        "The office move is planned for the last weekend of the month, please pack your desks by Friday.",
        "I noticed that the export file has the wrong date format, it should be fixed before the release.",
        "We could reuse the component from the dashboard, it already handles most of what this page needs.",
        "The training session went well, about forty people joined and we got a lot of good questions.",
        "I am worried about the timeline, the review alone usually takes four or five working days.",
        "Let me summarise what I heard, we freeze the scope today and we release on the twentieth.",
        "The analytics show that most people use the app in the evening, between seven and ten at night.",
        "We still owe the customer an answer about the invoice, I will write to them right after this call.",
        "I prefer the second option, it is simpler to explain and it does not need any new infrastructure.",
        "The backup job ran for six hours last night, which is twice as long as it normally takes.",
        "One of the candidates accepted the offer this morning, she can start at the beginning of next month.",
        "Before we close, does anybody have a blocker that the rest of the team should know about today?",
    ]

    enum Microphone: Int, CaseIterable { case clean, phone, noisy, quiet }

    /// A small repeatable random source (the same meetings every run).
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func unit() -> Float { Float(next() % 1_000_000) / 1_000_000 }
    }

    /// The recordings of every meeting, in speaking order: (file name, voice, sentence, microphone).
    static func plan() -> [[(name: String, speaker: String, text: String, mic: Microphone)]] {
        var random = Random(state: 20261124)
        var used = [Int](repeating: 0, count: cast.count)   // sentences each person has said so far
        return meetings.enumerated().map { m, people in
            var turns: [(Int, String, Microphone)] = []
            for person in people {
                let mic = Microphone(rawValue: random.below(Microphone.allCases.count))!
                for _ in 0..<6 {
                    // Each person walks the sentences from their own starting point, so no two say the same ones in
                    // the same order and nobody repeats a sentence across meetings.
                    let text = sentences[(person * 7 + used[person]) % sentences.count]
                    used[person] += 1
                    turns.append((person, text, mic))
                }
            }
            // Speaking order: shuffled, as people take turns.
            for i in stride(from: turns.count - 1, to: 0, by: -1) { turns.swapAt(i, random.below(i + 1)) }
            _ = m
            return turns.enumerated().map { i, turn in
                (String(format: "%02d-them-%@", i + 1, cast[turn.0]), cast[turn.0], turn.1, turn.2)
            }
        }
    }

    /// Makes the recordings that aren't there yet, with your Sarvam key. Returns the meetings' folders in order, or
    /// nil with a reason logged.
    @MainActor
    public static func prepare(in folder: URL, log: (String) -> Void) async -> [URL]? {
        guard let key = Keychain.get(SarvamTranscriber.keyAccount), !key.isEmpty else {
            log("simulate: no Sarvam key in Murmur")
            return nil
        }
        let plan = plan()
        var folders: [URL] = [], made = 0, characters = 0
        for (m, clips) in plan.enumerated() {
            let dir = folder.appendingPathComponent(String(format: "m%02d", m + 1), isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            folders.append(dir)
            for clip in clips {
                let url = dir.appendingPathComponent(clip.name + ".wav")
                if FileManager.default.fileExists(atPath: url.path) { continue }
                var samples: [Float]?
                for attempt in 0..<4 where samples == nil {
                    do {
                        samples = try await speak(clip.text, voice: clip.speaker, key: key, scratch: dir)
                    } catch {
                        log("simulate: \(clip.name): \(error.localizedDescription)" + (attempt < 3 ? ", trying again" : ""))
                        try? await Task.sleep(nanoseconds: UInt64(2 + attempt * 3) * 1_000_000_000)
                    }
                }
                guard let samples else {
                    log("simulate: gave up on \(clip.name)")
                    return nil
                }
                var random = Random(state: UInt64(m * 1000 + made + 7))
                try? wav(through(clip.mic, samples, random: &random)).write(to: url)
                made += 1
                characters += clip.text.count
            }
            log("simulate: meeting \(m + 1) of \(plan.count) ready (\(clips.count) recordings, \(Set(clips.map(\.speaker)).count) people)")
        }
        log("simulate: \(made) recordings made now (\(characters) characters of Sarvam speech), \(plan.reduce(0) { $0 + $1.count }) in all")
        return folders
    }

    /// One sentence in a Sarvam voice, as 16 kHz samples.
    private static func speak(_ text: String, voice: String, key: String, scratch: URL) async throws -> [Float] {
        var request = URLRequest(url: URL(string: "https://api.sarvam.ai/text-to-speech")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "language_code": "en-IN", "model": "bulbul:v3", "speaker": voice,
            "speech_sample_rate": 16000, "output_audio_codec": "wav",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audio = (object["audios"] as? [String])?.first, let bytes = Data(base64Encoded: audio) else {
            throw NSError(domain: "simulate", code: status, userInfo: [NSLocalizedDescriptionKey:
                "Sarvam speech answered \(status)"])
        }
        let temp = scratch.appendingPathComponent(".speech-\(UUID().uuidString).wav")
        try bytes.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let samples = AudioFile16k.read(temp), samples.count > 8000 else {
            throw NSError(domain: "simulate", code: 1, userInfo: [NSLocalizedDescriptionKey: "unreadable speech"])
        }
        return samples
    }

    /// A recording as a person's microphone on a call would give it.
    static func through(_ mic: Microphone, _ samples: [Float], random: inout Random) -> [Float] {
        func noise(_ input: [Float], snr: Float) -> [Float] {
            let power = input.reduce(0) { $0 + $1 * $1 } / Float(max(input.count, 1))
            let level = (power / pow(10, snr / 10)).squareRoot() * 1.73   // uniform noise of that power
            return input.map { $0 + (random.unit() * 2 - 1) * level }
        }
        switch mic {
        case .clean:
            return samples
        case .phone:
            // A phone line: nothing above 4 kHz (halved and stretched back), a little noise.
            var out = [Float](repeating: 0, count: samples.count)
            var i = 0
            while i + 1 < samples.count {
                let a = (samples[i] + samples[i + 1]) / 2
                let b = i + 3 < samples.count ? (samples[i + 2] + samples[i + 3]) / 2 : a
                out[i] = a
                out[i + 1] = (a + b) / 2
                i += 2
            }
            return noise(out, snr: 28)
        case .noisy:
            return noise(samples, snr: 16)
        case .quiet:
            return noise(samples.map { $0 * 0.25 }, snr: 20)
        }
    }

    /// 16 kHz, 16-bit, one channel.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le(36 + bytes); data.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(16000)); le(UInt32(32000)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(bytes)
        for s in samples { le(Int16(max(-1, min(1, s)) * 32767)) }
        return data
    }
}
