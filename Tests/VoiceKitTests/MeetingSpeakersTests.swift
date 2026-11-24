import XCTest
#if canImport(VoiceKit)
@testable import VoiceKit
#else
@testable import Meet
#endif

final class MeetingSpeakersTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var next = 0

    private func line(_ text: String, voice: Int?, at seconds: Double? = nil, you: Bool = false) -> MeetingLine {
        defer { next += 1 }
        return MeetingLine(id: next, speaker: you ? .you : .them, text: text,
                           at: start.addingTimeInterval(seconds ?? Double(next) * 5), voice: voice)
    }

    private func talk(_ voice: Int, _ count: Int) -> [MeetingLine] {
        (0..<count).map { line("this is a real sentence number \($0)", voice: voice) }
    }

    // MARK: Numbers

    func testSubstantiveLines() {
        XCTAssertTrue(MeetingSpeakers.substantive("we ship on Friday"))
        XCTAssertFalse(MeetingSpeakers.substantive("Yeah."))
        XCTAssertFalse(MeetingSpeakers.substantive("okay sure"))
        XCTAssertTrue(MeetingSpeakers.substantive("我们周五发布"))
        XCTAssertTrue(MeetingSpeakers.substantive("कल मिलते हैं"))
    }

    func testAOneToOneCallStaysThem() {
        let lines = talk(1, 12)
        XCTAssertEqual(MeetingSpeakers.numbers(lines), [:])
        XCTAssertEqual(MeetingSpeakers.singleVoice(lines), 1)
        XCTAssertEqual(MeetingSpeakers.label(lines[0], numbers: [:], names: [:]), "Them")
    }

    func testVoicesAreNumberedOnceTwoHaveFiveLines() {
        var lines = talk(4, 5) + talk(2, 4)
        XCTAssertEqual(MeetingSpeakers.numbers(lines), [:], "only one voice has five lines")
        lines += talk(2, 1)
        XCTAssertEqual(MeetingSpeakers.numbers(lines), [4: 1, 2: 2], "numbered in the order they reached five")
        // A third voice with short lines only never shows.
        lines += (0..<9).map { _ in line("Yeah.", voice: 7) }
        XCTAssertEqual(MeetingSpeakers.numbers(lines), [4: 1, 2: 2])
        // And a number never moves once shown.
        lines += talk(7, 5)
        XCTAssertEqual(MeetingSpeakers.numbers(lines), [4: 1, 2: 2, 7: 3])
    }

    func testAKnownVoiceIsShownFromItsFirstLine() {
        let lines = [line("hello", voice: 3)] + talk(1, 2)
        XCTAssertEqual(MeetingSpeakers.numbers(lines, known: [3]), [3: 1])
        let names = [3: VoiceName(name: "Priya", source: .library)]
        XCTAssertEqual(MeetingSpeakers.known(names, lines: lines), [3])
        XCTAssertEqual(MeetingSpeakers.label(lines[0], numbers: [3: 1], names: names), "Priya")
        XCTAssertEqual(MeetingSpeakers.label(lines[1], numbers: [3: 1], names: names), "Them")
    }

    func testAOneToOneCallerYouNamedIsShownByName() {
        let lines = talk(1, 3) + [line(".", voice: 2)]
        let names = [1: VoiceName(name: "Arjun", source: .user)]
        XCTAssertEqual(MeetingSpeakers.singleVoice(lines), 1, "a stray one-line voice doesn't count")
        let known = MeetingSpeakers.known(names, lines: lines)
        XCTAssertEqual(known, [1])
        XCTAssertEqual(MeetingSpeakers.label(lines[0], numbers: MeetingSpeakers.numbers(lines, known: known), names: names),
                       "Arjun")
    }

    func testAGuessAloneDoesNotShowAVoice() {
        let lines = talk(1, 2) + talk(2, 2)
        let names = [1: VoiceName(name: "Priya", source: .conversation), 2: VoiceName(name: "Sam", source: .window)]
        XCTAssertTrue(MeetingSpeakers.known(names, lines: lines).isEmpty)
    }

    func testNameSourcesHaveAnOrder() {
        let you = VoiceName(name: "Priya S", source: .user)
        let guess = VoiceName(name: "Pria", source: .conversation)
        XCTAssertEqual(VoiceName.merge(you, guess), you)
        XCTAssertEqual(VoiceName.merge(guess, you), you)
        XCTAssertEqual(VoiceName.merge(VoiceName(name: "A", source: .window), VoiceName(name: "B", source: .library)).name, "B")
        XCTAssertEqual(VoiceName.merge(nil, guess), guess)
    }

    // MARK: Names from the conversation

    private func meeting() -> (lines: [MeetingLine], numbers: [Int: Int]) {
        next = 0
        var lines: [MeetingLine] = []
        lines.append(line("Hi everyone, thanks for joining today", voice: 1))           // L1
        lines.append(line("Thanks Arjun, can you walk us through the numbers", voice: 2)) // L2
        lines.append(line("Sure, revenue grew twelve percent this quarter", voice: 1))    // L3
        lines.append(line("I'm Priya from finance and I have a question on that", voice: 2)) // L4
        lines.append(line("Go ahead Priya, what would you like to know", voice: 1))       // L5
        lines.append(line("We should invite Rahul to the next review", voice: nil, you: true))        // L6
        lines += talk(1, 4) + talk(2, 4)
        return (lines, MeetingSpeakers.numbers(lines))
    }

    func testTheTranscriptIsNumberedAndLabelled() throws {
        let (lines, numbers) = meeting()
        XCTAssertEqual(numbers, [1: 1, 2: 2])
        let content = try XCTUnwrap(MeetingNameGuess.content(lines, numbers: numbers, names: [:], start: start,
                                                             roster: ["Priya Sharma", "Arjun Mehta"]))
        XCTAssertTrue(content.contains("[L1 00:00 Speaker 1] Hi everyone"))
        XCTAssertTrue(content.contains("[L6 00:25 You] We should invite Rahul"))
        XCTAssertTrue(content.contains("People in this call (from the meeting app): Priya Sharma, Arjun Mehta."))
        // Everyone already named by you: nothing to ask.
        let named = [1: VoiceName(name: "Arjun", source: .user), 2: VoiceName(name: "Priya", source: .library)]
        XCTAssertNil(MeetingNameGuess.content(lines, numbers: numbers, names: named, start: start))
        XCTAssertNil(MeetingNameGuess.content(lines, numbers: [:], names: [:], start: start))
    }

    func testOnlySomeoneSayingTheirOwnNameIsNamed() {
        let (lines, numbers) = meeting()
        let reply = """
            Here you go:
            ```json
            {"speakers": [{"speaker": 2, "name": "Priya", "evidence": "L4"}, {"speaker": "1", "name": "Arjun", "evidence": "L2, L5"}],
             "people": ["Priya", "Arjun", "priya", " "]}
            ```
            """
        let (found, refuted) = MeetingNameGuess.read(reply, lines: lines, numbers: numbers, start: start)
        XCTAssertEqual(found[2]?.name, "Priya")
        XCTAssertEqual(found[2]?.source, .conversation)
        XCTAssertEqual(found[2]?.evidence, "00:15 “I'm Priya from finance and I have a question on that”")
        // "Thanks Arjun" is said by Speaker 2, about someone: it names nobody.
        XCTAssertNil(found[1])
        XCTAssertEqual(refuted[1], "Arjun")
        // Both names are still offered when you name a voice.
        XCTAssertEqual(MeetingNameGuess.people(reply), ["Priya", "Arjun"])
        XCTAssertEqual(MeetingNameGuess.people("no json"), [])
    }

    func testSayingYourOwnName() {
        XCTAssertTrue(MeetingNameGuess.introduces("Hi, I'm Priya from finance.", "Priya Sharma"))
        XCTAssertTrue(MeetingNameGuess.introduces("Hello, my name is Raj and I lead the team", "Raj"))
        XCTAssertTrue(MeetingNameGuess.introduces("I am, uh, Jamie Sevia, I founded Epoch", "Jaime Sevilla"), "spelled by ear")
        XCTAssertTrue(MeetingNameGuess.introduces("Hi, this is Emma from Acme.", "Emma"))
        XCTAssertTrue(MeetingNameGuess.introduces("Myself Rahul, joining from Pune", "Rahul"))
        XCTAssertTrue(MeetingNameGuess.introduces("मेरा नाम अर्जुन है", "अर्जुन"))
        // Someone else's name.
        XCTAssertFalse(MeetingNameGuess.introduces("This is Priya, our new designer.", "Priya"))
        XCTAssertFalse(MeetingNameGuess.introduces("I'm with Priya on this one.", "Priya"))
        XCTAssertFalse(MeetingNameGuess.introduces("I'm curious to hear from Ryan and Jaime.", "Ryan"))
        XCTAssertFalse(MeetingNameGuess.introduces("Thanks, Priya, that was clear.", "Priya"))
        XCTAssertFalse(MeetingNameGuess.introduces("So just to introduce all of the folks, there's Jaime Sevilla, who founded Epoch", "Jaime"))
        XCTAssertFalse(MeetingNameGuess.introduces("I'm Priya's manager.", "Priya"))
        XCTAssertFalse(MeetingNameGuess.introduces("I'm Daniel.", "David"))
    }

    func testANameThatIsNotTheirOwnLineIsRefused() {
        let (lines, numbers) = meeting()
        // L4 is Speaker 2 saying "I'm Priya": it can't name Speaker 1.
        var reply = #"{"speakers": [{"speaker": 1, "name": "Priya", "evidence": "L4"}]}"#
        var result = MeetingNameGuess.read(reply, lines: lines, numbers: numbers, start: start)
        XCTAssertNil(result.found[1])
        XCTAssertEqual(result.refuted[1], "Priya")
        // The user's own line (L6) names nobody on the call.
        reply = #"{"speakers": [{"speaker": 2, "name": "Rahul", "evidence": "L6"}]}"#
        XCTAssertTrue(MeetingNameGuess.read(reply, lines: lines, numbers: numbers, start: start).found.isEmpty)
        // No evidence, or a line that doesn't exist.
        reply = #"{"speakers": [{"speaker": 1, "name": "Arjun"}, {"speaker": 2, "name": "Priya", "evidence": "L900"}]}"#
        result = MeetingNameGuess.read(reply, lines: lines, numbers: numbers, start: start)
        XCTAssertTrue(result.found.isEmpty)
        XCTAssertEqual(result.refuted.count, 2)
        // A speaker not on show, a name too long, or no JSON at all.
        reply = #"{"speakers": [{"speaker": 9, "name": "Ghost", "evidence": "L1"}, {"speaker": 1, "name": "\#(String(repeating: "x", count: 41))", "evidence": "L1"}]}"#
        XCTAssertTrue(MeetingNameGuess.read(reply, lines: lines, numbers: numbers, start: start).found.isEmpty)
        XCTAssertTrue(MeetingNameGuess.read("No one is named.", lines: lines, numbers: numbers, start: start).found.isEmpty)
    }

    func testOneNameForTwoVoicesGoesToTheOneWhoSpokeMore() {
        var (lines, numbers) = meeting()
        lines.append(line("Hello, I'm Priya as well, from legal", voice: 1))
        lines += talk(2, 3)
        numbers = MeetingSpeakers.numbers(lines)
        let reply = #"{"speakers": [{"speaker": 1, "name": "Priya", "evidence": "L\#(15)"}, {"speaker": 2, "name": "priya", "evidence": "L4"}]}"#
        let found = MeetingNameGuess.read(reply, lines: lines, numbers: numbers, start: start).found
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[2]?.name, "priya")
    }

    func testAnEarlierNameIsCheckedAgain() {
        let (lines, _) = meeting()
        let good = VoiceName(name: "Priya", source: .conversation, evidence: "00:15 “I'm Priya from finance…”")
        XCTAssertTrue(MeetingNameGuess.holds(good, voice: 2, in: lines, start: start))
        // The line is no longer voice 3's (it never was).
        XCTAssertFalse(MeetingNameGuess.holds(good, voice: 3, in: lines, start: start))
        // A name from the old rule (addressed nearby) doesn't stand.
        let addressed = VoiceName(name: "Arjun", source: .conversation, evidence: "00:05 “Thanks Arjun, can you walk us…”")
        XCTAssertFalse(MeetingNameGuess.holds(addressed, voice: 1, in: lines, start: start))
        // A line that can no longer be found keeps the name; other sources aren't checked.
        let gone = VoiceName(name: "Priya", source: .conversation, evidence: "59:00 “Something else”")
        XCTAssertTrue(MeetingNameGuess.holds(gone, voice: 3, in: lines, start: start))
        XCTAssertTrue(MeetingNameGuess.holds(VoiceName(name: "X", source: .user), voice: 3, in: lines, start: start))
    }

    // MARK: Voice library

    private func vector(_ seed: Int, size: Int = 256) -> [Float] {
        var g = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        return (0..<size).map { _ in
            g = g &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: g >> 11) % 2000) / 1000 - 1
        }
    }

    /// `v` moved towards `w` by `t` (0…1), as a nearby voice would be.
    private func mix(_ v: [Float], _ w: [Float], _ t: Float) -> [Float] { zip(v, w).map { $0 * (1 - t) + $1 * t } }

    func testMatchingNamesOnlyAClearMatch() throws {
        let priya = VoiceProfile(name: "Priya", print: VoiceMatching.normalized(vector(1))!, samples: 5)
        let arjun = VoiceProfile(name: "Arjun", print: VoiceMatching.normalized(vector(2))!, samples: 5)
        let same = try XCTUnwrap(VoiceMatching.match(mix(vector(1), vector(3), 0.15), in: [priya, arjun]))
        XCTAssertEqual(same.name, "Priya")
        XCTAssertTrue(same.sure)
        XCTAssertGreaterThanOrEqual(same.score, VoiceMatching.auto)
        // Most of the way to another voice (similarity about 0.63): only a suggestion.
        let maybe = try XCTUnwrap(VoiceMatching.match(mix(vector(1), vector(3), 0.55), in: [priya, arjun]))
        XCTAssertEqual(maybe.name, "Priya")
        XCTAssertFalse(maybe.sure)
        XCTAssertNil(VoiceMatching.match(vector(9), in: [priya, arjun]), "a stranger")
        // Two profiles almost alike: no lead, so it only suggests.
        let twin = VoiceProfile(name: "Twin", print: VoiceMatching.normalized(mix(vector(1), vector(4), 0.02))!, samples: 5)
        let close = try XCTUnwrap(VoiceMatching.match(vector(1), in: [priya, twin]))
        XCTAssertFalse(close.sure)
    }

    func testRememberingNeedsEnoughSpeech() throws {
        let p = vector(5)
        XCTAssertNil(VoiceMatching.enroll([(p, 3), (p, 3)]), "two stretches")
        XCTAssertNil(VoiceMatching.enroll([(p, 1.5), (p, 1.5), (p, 2)]), "five seconds")
        let print = try XCTUnwrap(VoiceMatching.enroll([(p, 2), (mix(p, vector(6), 0.1), 2), (p, 30)]))
        XCTAssertEqual(print.count, 256)
        XCTAssertEqual(print.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 0.001)
        XCTAssertGreaterThan(VoiceMatching.cosine(print, p), 0.95)
    }

    func testAProfileLearnsSlowly() {
        let old = VoiceMatching.normalized(vector(7))!
        let fresh = VoiceMatching.normalized(vector(8))!
        let heavy = VoiceMatching.blend(old, samples: 40, with: fresh)
        let light = VoiceMatching.blend(old, samples: 1, with: fresh)
        XCTAssertGreaterThan(VoiceMatching.cosine(heavy, old), VoiceMatching.cosine(light, old))
        // Capped: forty stretches weigh as twenty, so it can still be corrected.
        XCTAssertEqual(VoiceMatching.cosine(heavy, VoiceMatching.blend(old, samples: 20, with: fresh)), 1, accuracy: 0.0001)
    }

    func testTheLibraryIsKeptPrivatelyOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = VoiceLibrary(folder: folder)
        XCTAssertNil(library.remember(name: "  ", print: vector(1), samples: 3))
        let priya = try XCTUnwrap(library.remember(name: "Priya", print: vector(1), samples: 3))
        library.remember(name: "arjun", print: vector(2), samples: 4)
        // The same name again learns instead of adding.
        library.remember(name: "PRIYA", print: vector(1), samples: 2)
        let reread = VoiceLibrary(folder: folder)
        XCTAssertEqual(reread.profiles.map(\.name), ["arjun", "Priya"])
        XCTAssertEqual(reread.profile(priya.id)?.samples, 5)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("voices.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        reread.update(priya.id, notes: "Finance, Bengaluru")
        XCTAssertEqual(VoiceLibrary(folder: folder).profile(priya.id)?.notes, "Finance, Bengaluru")
        reread.forget(priya.id)
        XCTAssertEqual(VoiceLibrary(folder: folder).profiles.map(\.name), ["arjun"])
        reread.forgetAll()
        XCTAssertTrue(VoiceLibrary(folder: folder).profiles.isEmpty)
    }

    // MARK: Echo

    func testEchoByContainment() {
        let theirs = ["so the launch moves to the second week of March because legal needs more time"]
        // The mic heard the end of it, cut differently, with a word wrong.
        XCTAssertGreaterThanOrEqual(MeetingText.contained("week of March because legal need more time", in: theirs),
                                    MeetingText.containedEcho)
        // A real reply that repeats a few of their words is not an echo.
        XCTAssertLessThan(MeetingText.contained("okay so March works for me but I want legal to confirm by Friday",
                                                in: theirs), MeetingText.containedEcho)
        XCTAssertEqual(MeetingText.contained("yes", in: theirs), 0, "too short to tell")
    }

    func testEchoIsComparedWithAllTheySaidMeanwhile() {
        let t = Date(timeIntervalSince1970: 1_000)
        func them(_ id: Int, _ at: Double, _ seconds: Double, _ text: String) -> MeetingLine {
            MeetingLine(id: id, speaker: .them, text: text, at: t.addingTimeInterval(at), voice: 1, seconds: seconds)
        }
        let lines = [
            them(1, 0, 7, "So I think the median future is actually not a very good thing to think about."),
            them(2, 8, 9, "I would much rather talk about individual scenarios and how much chance we put on each."),
            them(3, 18, 8, "For context, we did a similar discussion to this in November three years ago."),
            them(4, 60, 5, "Something said a minute later that has nothing to do with it."),
        ]
        // Twenty seconds of the room: the microphone heard the speakers, cut where it liked, a few words off.
        let heard = MeetingLine(id: 9, speaker: .you, text: "future is actually not a very good thing to think about, I would "
            + "much rather talk about individual scenarios and how much chance we put on each. For context we did a "
            + "similar discussion to this in November", at: t.addingTimeInterval(2), seconds: 20)
        let meanwhile = MeetingText.during(heard, in: lines)
        XCTAssertEqual(meanwhile.map(\.id), [1, 2, 3])
        XCTAssertNil(MeetingText.withoutEcho(heard.text, theirs: meanwhile.map(\.text)))
        // No single line of theirs holds enough of it: why it used to stay in as "You".
        XCTAssertTrue(lines.allSatisfy { MeetingText.contained(heard.text, in: [$0.text]) < MeetingText.containedEcho })
        // What you really said stays, word for word.
        let reply = "I disagree, the median is still the most useful single number we have."
        XCTAssertEqual(MeetingText.withoutEcho(reply, theirs: meanwhile.map(\.text)), reply)
        XCTAssertEqual(MeetingText.withoutEcho("Yes. I'll share the pricing sheet tomorrow.",
                                               theirs: ["Can you share the pricing sheet?"]),
                       "Yes. I'll share the pricing sheet tomorrow.")
        XCTAssertEqual(MeetingText.withoutEcho(reply, theirs: []), reply)
        // You spoke while the speakers played: their sentence goes, yours stays.
        let mixed = "I would much rather talk about individual scenarios and how much chance we put on each. Sorry, can I jump in here?"
        XCTAssertEqual(MeetingText.withoutEcho(mixed, theirs: meanwhile.map(\.text)), "Sorry, can I jump in here?")
        // A scrap of the call the speech model wrote differently on the two sides is still the call.
        let scrap = "I would much rather talk about individual scenarios and how much chance we put on each. Rather individual chance."
        XCTAssertNil(MeetingText.withoutEcho(scrap, theirs: meanwhile.map(\.text)))
    }

    // MARK: Speaker turns

    /// The model's answer for `turns`: (speaker or nil for silence, seconds).
    private func frames(_ turns: [(Int?, Double)]) -> [[Float]] {
        turns.flatMap { speaker, seconds in
            [[Float]](repeating: (0..<3).map { $0 == speaker ? 1 : 0 }, count: Int((seconds / SpeakerTurns.frame).rounded()))
        }
    }

    func testAStretchIsCutWhereTheSpeakerChanges() {
        // One person throughout, pauses and all: nothing to cut.
        XCTAssertEqual(SpeakerTurns.cuts(frames([(0, 4), (nil, 0.4), (0, 3)])), [])
        XCTAssertEqual(SpeakerTurns.cuts([]), [])
        // A question, then the answer with no pause to speak of.
        var cuts = SpeakerTurns.cuts(frames([(0, 6), (nil, 0.2), (1, 3.8)]))
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0], 6.1, accuracy: 0.05)
        // Three people in ten seconds.
        cuts = SpeakerTurns.cuts(frames([(0, 3), (1, 3), (2, 4)]))
        XCTAssertEqual(cuts.count, 2)
        XCTAssertEqual(cuts[0], 3, accuracy: 0.05)
        XCTAssertEqual(cuts[1], 6, accuracy: 0.05)
        // "Mm" in the middle of someone's speech is too short to cut out: it stays one stretch.
        XCTAssertEqual(SpeakerTurns.cuts(frames([(0, 5), (1, 0.4), (0, 4.6)])), [])
        // "Thank you for having us" (a second) gets a line of its own.
        XCTAssertEqual(SpeakerTurns.cuts(frames([(0, 5), (1, 1), (0, 4)])).count, 2)
        // Two people talking at once belongs to neither turn; the cut falls in the middle of it.
        var both = frames([(0, 4)])
        both += [[Float]](repeating: [1, 1, 0], count: Int(1 / SpeakerTurns.frame))
        both += frames([(1, 5)])
        cuts = SpeakerTurns.cuts(both)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0], 4.5, accuracy: 0.05)
    }

    func testLongStretchesAreReadInOverlappingWindows() {
        XCTAssertEqual(SpeakerTurns.windows(6), [0])
        XCTAssertEqual(SpeakerTurns.windows(10), [0])
        XCTAssertEqual(SpeakerTurns.windows(20), [0, 8, 10])
        // The same change seen by two windows is one cut.
        XCTAssertEqual(SpeakerTurns.merged([9.1, 4, 9.4, 15]), [4, 9.1, 15])
    }

    func testCutsLandInTheQuietBetweenWords() {
        // 3 s of sound, 0.2 s of quiet, 3 s of sound; the model says "about 3.2".
        let loud = (0..<48_000).map { Float(sin(Double($0) * 0.3)) * 0.3 }
        let samples = loud + [Float](repeating: 0, count: 3_200) + loud
        let at = SpeakerTurns.quietest(near: 3.2, in: samples)
        XCTAssertTrue((48_000..<51_200).contains(at), "\(at)")
        let parts = SpeakerTurns.parts(samples, cuts: [3.2, 3.3])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].lowerBound, 0)
        XCTAssertEqual(parts[0].upperBound, parts[1].lowerBound)
        XCTAssertEqual(parts[1].upperBound, samples.count)
        // A cut too near an end would leave a part too short to be anyone: not made.
        XCTAssertEqual(SpeakerTurns.parts(samples, cuts: [0.05]).count, 1)
        XCTAssertEqual(SpeakerTurns.parts(samples, cuts: []).count, 1)
    }

    func testAChangeTheModelMissedIsFoundByVoice() {
        // Windows 3 s long, a second apart: voice 1 for a while, two it can't place, then voice 4.
        XCTAssertEqual(SpeakerTurns.cuts(byVoice: [1, 1, 1, nil, nil, 4, 4, 4]), [(2 + 3 + 5) / 2.0])
        XCTAssertEqual(SpeakerTurns.cuts(byVoice: [1, 1, 4, 4]), [(1 + 3 + 2) / 2.0])
        // One voice throughout, one stray window, or nothing decided: no cut.
        XCTAssertEqual(SpeakerTurns.cuts(byVoice: [1, 1, nil, 1, 1, 1]), [])
        XCTAssertEqual(SpeakerTurns.cuts(byVoice: [1, 1, 1, 4, 1, 1]), [])
        XCTAssertEqual(SpeakerTurns.cuts(byVoice: [nil, 1, nil, 4, nil]), [])
        XCTAssertEqual(SpeakerTurns.cuts(byVoice: []), [])
        // A third voice in between isn't a clean handover.
        XCTAssertEqual(SpeakerTurns.cuts(byVoice: [1, 1, 3, 4, 4]), [])
    }

    func testWordsGoToThePartTheyWereSaidIn() {
        let words = [TimedWord("What", 0.1, 0.3), TimedWord("do", 0.3, 0.4), TimedWord("you", 0.4, 0.5),
                     TimedWord("think?", 0.5, 0.9), TimedWord("Yeah,", 1.0, 1.2), TimedWord("so", 1.2, 1.4),
                     TimedWord("I", 1.4, 1.5), TimedWord("agree.", 1.5, 2.0)]
        let whole = "What do you think? Yeah, so I agree."
        XCTAssertEqual(SpeakerTurns.texts(words, cuts: [0.95], whole: whole), ["What do you think?", "Yeah, so I agree."])
        // A cut that lands inside a word: the word goes whole to the side most of it is on.
        XCTAssertEqual(SpeakerTurns.texts(words, cuts: [0.85], whole: whole)?.first, "What do you think?")
        // The cut came three words late: it moves back to the end of the sentence.
        XCTAssertEqual(SpeakerTurns.texts(words, cuts: [1.45], whole: whole), ["What do you think?", "Yeah, so I agree."])
        // No sentence ends anywhere near: the cut stays where it was.
        let run = (0..<8).map { TimedWord("word\($0)", Double($0), Double($0) + 0.8) }
        XCTAssertEqual(SpeakerTurns.texts(run, cuts: [3.9], whole: run.map(\.text).joined(separator: " "))?.first,
                       "word0 word1 word2 word3")
        // No times, or times that aren't this text's: the parts are transcribed by themselves instead.
        XCTAssertNil(SpeakerTurns.texts([], cuts: [0.95], whole: whole))
        XCTAssertNil(SpeakerTurns.texts(words, cuts: [0.95], whole: "Something else entirely."))
        XCTAssertNil(SpeakerTurns.texts(words, cuts: [], whole: whole))
    }

    func testAShortStretchGoesToTheVoiceItIsPlainlyMostLike() {
        // A print as the model gives it that, with the shared part taken out, points along (a, b, c).
        func print(_ a: Float, _ b: Float, _ c: Float = 0) -> [Float] {
            var clean = [Float](repeating: 0, count: VoiceBackground.heard.count)
            clean[0] = a; clean[1] = b; clean[2] = c
            let unit = VoiceMatching.normalized(clean)!, shared = VoiceBackground.heard
            let along = zip(shared, unit).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            let size = shared.reduce(Float(0)) { $0 + $1 * $1 }
            let t = -along + (along * along + 1 - size).squareRoot()
            return zip(shared, unit).map { $0 + t * $1 }
        }
        var clusters = VoiceClusters()
        for _ in 0..<3 { _ = clusters.add(heard: print(3, 0), narrow: nil, seconds: 5) }
        for _ in 0..<3 { _ = clusters.add(heard: print(0, 3), narrow: nil, seconds: 5) }
        XCTAssertEqual(clusters.count, 2)
        // A second and a half, off towards something else but far nearer voice 1 than voice 2: shown as voice 1.
        let short = clusters.add(heard: print(3, 0, 6), narrow: nil, seconds: 1.5)!
        XCTAssertEqual(clusters.voices[short], 1)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.heard(1).stretches, 3, "it isn't part of what voice 1 is known by")
        // Halfway between the two: nobody's.
        var second = VoiceClusters()
        for _ in 0..<3 { _ = second.add(heard: print(3, 0), narrow: nil, seconds: 5) }
        for _ in 0..<3 { _ = second.add(heard: print(0, 3), narrow: nil, seconds: 5) }
        var third = second
        let between = second.add(heard: print(3, 3, 6), narrow: nil, seconds: 1.5)!
        XCTAssertNil(second.voices[between])
        // Unlike both: nobody's.
        let other = third.add(heard: print(0, 0, 3), narrow: nil, seconds: 1.5)!
        XCTAssertNil(third.voices[other])
    }

    // MARK: Record

    func testTheMeetingRecordKeepsLinesVoicesAndNames() throws {
        let (lines, numbers) = meeting()
        let names = [2: VoiceName(name: "Priya", source: .conversation, evidence: "00:15 “I'm Priya…”"),
                     1: VoiceName(name: "", source: .user)]
        let record = MeetingRecord(started: start, ended: start.addingTimeInterval(600), app: "Microsoft Teams",
                                   about: "", lines: lines, numbers: numbers, names: names, notes: "# Q3 review")
        XCTAssertNil(record.about)
        XCTAssertEqual(record.lines[5].side, "you")
        XCTAssertEqual(record.lines[3].t, 15)
        XCTAssertEqual(record.voices.map(\.voice), [1, 2])
        XCTAssertEqual(record.voices[1].name, "Priya")
        XCTAssertEqual(record.voices[1].source, "conversation")
        XCTAssertNil(record.voices[0].name, "a cleared name is no name")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try record.write(under: root)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, MeetingRecord.id(for: start))
        let back = try MeetingRecord.decoder.decode(MeetingRecord.self, from: Data(contentsOf: url))
        XCTAssertEqual(back, record)
    }
}

/// Telling voices apart by grouping the whole meeting again as each stretch arrives.
final class VoiceClustersTests: XCTestCase {
    private var seed: UInt64 = 42
    private func random(_ size: Int = 256) -> [Float] {
        (0..<size).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
        }
    }
    private func unit(_ v: [Float]) -> [Float] { VoiceMatching.normalized(v)! }
    /// A stretch of `voice`: the voice plus some noise.
    private func stretch(_ voice: [Float], noise: Float = 0.3) -> [Float] {
        unit(zip(unit(voice), unit(random())).map { $0 + $1 * noise })
    }

    func testPeopleTakingTurnsAreToldApart() {
        let people = [unit(random()), unit(random()), unit(random())]
        var clusters = VoiceClusters()
        var said: [(person: Int, stretch: Int)] = []
        for round in 0..<6 {
            for (person, voice) in people.enumerated() {
                let print = stretch(voice)
                if let index = clusters.add(heard: print, narrow: print, seconds: 4) { said.append((person, index)) }
                _ = round
            }
        }
        let voices = clusters.voices
        for person in 0..<3 {
            XCTAssertEqual(Set(said.filter { $0.person == person }.map { voices[$0.stretch] }), [person + 1],
                           "numbered in the order first heard, one voice each")
        }
        XCTAssertEqual(clusters.count, 3)
        XCTAssertEqual(clusters.heard(1).stretches, 6)
        XCTAssertEqual(clusters.heard(1).seconds, 24)
        XCTAssertEqual(clusters.samples(2).count, 6)
        XCTAssertNotNil(clusters.centroid(3, narrow: true))
    }

    func testAShortStretchUnlikeEveryoneGetsNoVoice() {
        var clusters = VoiceClusters()
        let a = unit(random())
        XCTAssertEqual(clusters.add(heard: a, narrow: nil, seconds: 4), 0)
        let cough = clusters.add(heard: unit(random()), narrow: nil, seconds: 1.2)
        XCTAssertEqual(clusters.voices[cough!], nil)
        let other = clusters.add(heard: unit(random()), narrow: nil, seconds: 2.5)
        XCTAssertEqual(clusters.voices[other!], 2)
        XCTAssertEqual(clusters.voices[0], 1)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertNil(clusters.centroid(1, narrow: true), "no narrowed print was given")
    }

    func testNumbersStayAsTheMeetingIsGroupedAgain() {
        let a = unit(random()), b = unit(random())
        var clusters = VoiceClusters()
        _ = clusters.add(heard: stretch(a), narrow: nil, seconds: 3)
        _ = clusters.add(heard: stretch(b), narrow: nil, seconds: 3)
        for _ in 0..<10 {
            _ = clusters.add(heard: stretch(b), narrow: nil, seconds: 3)
            _ = clusters.add(heard: stretch(a), narrow: nil, seconds: 3)
            XCTAssertEqual(clusters.voices[0], 1)
            XCTAssertEqual(clusters.voices[1], 2)
        }
    }

    func testVoicesYouMergedStayMerged() {
        let a = unit(random()), b = unit(random())
        var clusters = VoiceClusters()
        _ = clusters.add(heard: stretch(a), narrow: nil, seconds: 3)
        _ = clusters.add(heard: stretch(b), narrow: nil, seconds: 3)
        clusters.merge(2, into: 1)
        XCTAssertEqual(clusters.voices, [1, 1])
        // Heard again later, b is still with a.
        let later = clusters.add(heard: stretch(b), narrow: nil, seconds: 3)
        XCTAssertEqual(clusters.voices[later!], 1)
        XCTAssertEqual(clusters.count, 1)
    }

    func testSavedPeopleAreMatchedTogether() {
        let priya = VoiceProfile(name: "Priya", print: unit(random()), samples: 6)
        let arjun = VoiceProfile(name: "Arjun", print: unit(random()), samples: 6)
        let old = VoiceProfile(name: "Old", print: priya.print, samples: 6, kind: nil)
        // Voice 1 is Priya clearly; voice 2 is rather like Priya too, but she's taken: it's only offered Arjun if it
        // is like him, and here it isn't; voice 3 is Arjun.
        let voices: [Int: [Float]] = [1: stretch(priya.print, noise: 0.3), 2: stretch(priya.print, noise: 1.1),
                                      3: stretch(arjun.print, noise: 0.4), 4: unit(random())]
        let matches = VoiceMatching.assign(voices, in: [priya, arjun, old])
        XCTAssertEqual(matches[1]?.name, "Priya")
        XCTAssertEqual(matches[1]?.sure, true)
        XCTAssertEqual(matches[3]?.name, "Arjun")
        XCTAssertNil(matches[2], "Priya is one voice only")
        XCTAssertNil(matches[4], "a stranger")
        XCTAssertFalse(matches.values.contains { $0.name == "Old" }, "a print made the old way isn't compared")
        // You said voice 1 isn't Priya: she's free for voice 2, as a question (it's only rather like her).
        let again = VoiceMatching.assign(voices, in: [priya, arjun], declined: ["1 \(priya.id)"])
        XCTAssertNil(again[1])
        XCTAssertEqual(again[2]?.name, "Priya")
        XCTAssertEqual(again[2]?.sure, false)
    }
}
