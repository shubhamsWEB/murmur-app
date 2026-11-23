import XCTest
#if canImport(VoiceKit)
@testable import VoiceKit
#else
@testable import Meet
#endif

final class MeetingTests: XCTestCase {
    private let rate = 16_000.0

    private func tone(_ seconds: Double, level: Float = 0.1) -> [Float] {
        (0..<Int(seconds * rate)).map { level * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    private func hiss(_ seconds: Double, level: Float = 0.001) -> [Float] {
        (0..<Int(seconds * rate)).map { _ in Float.random(in: -level...level) }
    }

    func testSpeechBetweenPausesIsOnePiece() {
        var segmenter = MeetingSegmenter(rate: rate)
        var pieces = segmenter.add(hiss(1) + tone(2) + hiss(1.2))
        XCTAssertEqual(pieces.count, 1)
        // About the speech, the lead-in and a little of the pause; not the second of quiet before.
        XCTAssertGreaterThan(pieces[0].count, Int(2 * rate))
        XCTAssertLessThan(pieces[0].count, Int(3.0 * rate))
        pieces = segmenter.add(tone(1.5) + hiss(1))
        XCTAssertEqual(pieces.count, 1)
    }

    func testAShortSoundIsDropped() {
        var segmenter = MeetingSegmenter(rate: rate)
        XCTAssertTrue(segmenter.add(hiss(1) + tone(0.1) + hiss(1.5)).isEmpty)
    }

    func testALongSpeechIsCutAtAPause() {
        var segmenter = MeetingSegmenter(rate: rate)
        // 12 s, a short pause, 12 s: cut at the pause once it passes 20 s.
        let pieces = segmenter.add(tone(12) + hiss(0.4) + tone(12))
        XCTAssertEqual(pieces.count, 1)
        XCTAssertLessThan(pieces[0].count, Int(13 * rate))
        XCTAssertNotNil(segmenter.flush())
    }

    func testQuietRoomIsNotSpeech() {
        var segmenter = MeetingSegmenter(rate: rate)
        XCTAssertTrue(segmenter.add(hiss(5, level: 0.003)).isEmpty)
        XCTAssertNil(segmenter.flush())
    }

    func testQuestions() {
        for asked in ["Can you walk me through the design?", "what is your experience with react",
                      "Tell me about a time you disagreed with your manager", "How did that go",
                      "So we shipped it. Why did the latency go up", "Do you have any questions for us"] {
            XCTAssertTrue(MeetingText.isQuestion(asked), asked)
        }
        for said in ["What we did was move it to the edge.", "I think that works.", "How it went is fine.",
                     "Okay?", "Is", "There is a problem with the build."] {
            XCTAssertFalse(MeetingText.isQuestion(said), said)
        }
    }

    func testEcho() {
        XCTAssertTrue(MeetingText.isEcho("we should ship it on friday", of: "I think we should ship it on Friday."))
        XCTAssertFalse(MeetingText.isEcho("sounds good to me", of: "I think we should ship it on Friday."))
        // Your reply takes up their words: that's you speaking, not the call heard again.
        XCTAssertFalse(MeetingText.isEcho("Yes, I'll share the pricing sheet", of: "Can you share the pricing sheet?"))
        XCTAssertFalse(MeetingText.isEcho("we should ship it on friday", of: "So we should ship it on Friday?", apart: 12))
        XCTAssertTrue(MeetingText.isEcho("we should ship it on friday", of: "I think we should ship it on Friday.", apart: 1.5))
    }

    func testTranscriptKeepsTheNewest() {
        let lines = (0..<50).map { MeetingLine(id: $0, speaker: $0 % 2 == 0 ? .them : .you, text: "line \($0)", at: Date()) }
        let text = MeetingText.transcript(lines, limit: 200)
        XCTAssertTrue(text.hasSuffix("You: line 49"))
        XCTAssertFalse(text.contains("line 1\n"))
        XCTAssertLessThanOrEqual(text.count, 200)
    }

    func testNoiseWordsAreDropped() {
        XCTAssertFalse(MeetingText.isWorthKeeping("Thank you."))
        XCTAssertFalse(MeetingText.isWorthKeeping("."))
        XCTAssertTrue(MeetingText.isWorthKeeping("Thank you for joining."))
    }
}

final class MeetingMoreTests: XCTestCase {
    func testSpeakingNow() {
        var segmenter = MeetingSegmenter(rate: 16_000)
        _ = segmenter.add((0..<16_000).map { 0.1 * sin(Float($0) * 0.086) })
        XCTAssertTrue(segmenter.isSpeaking)
        XCTAssertGreaterThan(segmenter.level, 0.5)
        _ = segmenter.add([Float](repeating: 0, count: 8_000))
        XCTAssertFalse(segmenter.isSpeaking)
    }

    func testContextFitsAndKeepsEveryDocument() {
        let long = String(repeating: "word ", count: 10_000)
        let text = MeetingText.context(about: "Release sync", instructions: "Short answers.",
                                       documents: [("plan.md", long), ("notes.txt", "small note")], limit: 4_000)
        XCTAssertLessThanOrEqual(text.count, 4_200)
        XCTAssertTrue(text.contains("About this meeting: Release sync"))
        XCTAssertTrue(text.contains("Document \"plan.md\""))
        XCTAssertTrue(text.contains("small note"))
        XCTAssertEqual(MeetingText.context(about: " ", instructions: "", documents: []), "")
    }

    func testChangedFraction() {
        let a = [UInt8](repeating: 100, count: 400)
        var b = a
        for i in stride(from: 0, to: 200, by: 4) { b[i] = 200 }
        XCTAssertEqual(MeetingText.changedFraction(a, b), 0.5, accuracy: 0.001)
        XCTAssertEqual(MeetingText.changedFraction(a, a), 0)
    }
}

final class SpokenAnswerTests: XCTestCase {
    func testSayAndAlso() {
        let answer = MeetingText.spoken("""
            SAY: Friday still works if both fixes land today. QA needs a day to recheck the login flow.
            ALSO:
            - If QA finds anything new, we ship Monday.
            - Do the release notes need sign-off?
            """)
        XCTAssertEqual(answer.say, ["Friday still works if both fixes land today.", "QA needs a day to recheck the login flow."])
        XCTAssertEqual(answer.also, ["If QA finds anything new, we ship Monday.", "Do the release notes need sign-off?"])
    }

    func testMarkdownLabels() {
        let answer = MeetingText.spoken("**Answer**: I think so. We merge tonight.\n\n**You could also say**:\n- Ask QA first.")
        XCTAssertEqual(answer.headline, "I think so. We merge tonight.")
        XCTAssertEqual(answer.also, ["Ask QA first."])
    }

    func testAnswerPointsExample() {
        let answer = MeetingText.spoken("""
            ANSWER: Yes, Friday still works if both fixes land today.
            POINTS:
            - **QA needs a day** to recheck the login flow.
            - So we merge **by tonight**.
            - If anything new turns up, we ship Monday.
            EXAMPLE: Last release we merged at 9 pm and QA signed off by noon.
            ALSO:
            - Do release notes need sign-off?
            """)
        XCTAssertEqual(answer.headline, "Yes, Friday still works if both fixes land today.")
        XCTAssertEqual(answer.points, ["**QA needs a day** to recheck the login flow.", "So we merge **by tonight**.",
                                       "If anything new turns up, we ship Monday."])
        XCTAssertEqual(answer.example, "Last release we merged at 9 pm and QA signed off by noon.")
        XCTAssertEqual(answer.also, ["Do release notes need sign-off?"])
        XCTAssertTrue(answer.say.isEmpty)
        XCTAssertFalse(answer.spokenText.contains("**"))
    }

    func testBulletsUnderTheAnswerArePoints() {
        let answer = MeetingText.spoken("ANSWER: Two reasons.\n- Latency.\n- Cost.")
        XCTAssertEqual(answer.headline, "Two reasons.")
        XCTAssertEqual(answer.points, ["Latency.", "Cost."])
    }

    func testHalfWritten() {
        let answer = MeetingText.spoken("SAY: Friday still works. QA needs a d")
        XCTAssertEqual(answer.say, ["Friday still works.", "QA needs a d"])
        XCTAssertTrue(answer.also.isEmpty)
    }

    func testPlainText() {
        let answer = MeetingText.spoken("We use Postgres, e.g. for orders. Version 3.5 is live.")
        XCTAssertEqual(answer.say, ["We use Postgres, e.g. for orders.", "Version 3.5 is live."])
    }

    func testAnsweringIsNotALabel() {
        XCTAssertEqual(MeetingText.spoken("Answering that needs the numbers.").say, ["Answering that needs the numbers."])
        XCTAssertEqual(MeetingText.spoken("Also, we can ship Monday.").say, ["Also, we can ship Monday."])
    }
}

final class ScreenQuestionTests: XCTestCase {
    func testAboutTheScreen() {
        for asked in ["What does this chart tell you about churn?", "Can you see my screen?",
                      "Looking at the second slide, what would you cut?", "I'm sharing the dashboard now, thoughts?",
                      "What do you think of these numbers?", "On the screen, which line is the bottleneck?"] {
            XCTAssertTrue(MeetingText.refersToScreen(asked), asked)
        }
        for asked in ["How did the release go?", "Can we ship on Friday?", "Tell me about your last project."] {
            XCTAssertFalse(MeetingText.refersToScreen(asked), asked)
        }
    }
}

final class CodeAnswerTests: XCTestCase {
    func testCodeIsKeptWhole() {
        let answer = MeetingText.spoken("""
            SAY: I'd do it iteratively, so it runs in linear time without deep recursion.
            CODE:
            ```python
            def factorial(n: int) -> int:
                result = 1
                for i in range(2, n + 1):
                    result *= i
                return result
            ```
            ALSO:
            - Raise an error for negative numbers.
            """)
        XCTAssertEqual(answer.say, ["I'd do it iteratively, so it runs in linear time without deep recursion."])
        XCTAssertEqual(answer.code.count, 1)
        XCTAssertEqual(answer.code[0].language, "python")
        XCTAssertTrue(answer.code[0].text.hasPrefix("def factorial(n: int) -> int:\n    result = 1"))
        XCTAssertTrue(answer.code[0].text.hasSuffix("    return result"))
        XCTAssertEqual(answer.also, ["Raise an error for negative numbers."])
    }

    func testCodeStillBeingWritten() {
        let answer = MeetingText.spoken("SAY: Here it is.\n```python\ndef factorial(n):\n    if n < 2:")
        XCTAssertEqual(answer.code.first?.text, "def factorial(n):\n    if n < 2:")
        XCTAssertEqual(answer.say, ["Here it is."])
    }

    func testRequestsAreAnswered() {
        for asked in ["Write a factorial function in Python", "Please explain how the cache works",
                      "Okay, show me the SQL for that", "Implement binary search for me"] {
            XCTAssertTrue(MeetingText.isQuestion(asked), asked)
        }
        XCTAssertFalse(MeetingText.isQuestion("I wrote the cache last week."))
    }
}

final class NotesTests: XCTestCase {
    func testSmallTalkIsLeftOut() {
        for chatter in ["Can you hear me okay?", "Sorry, you're on mute.", "Good morning everyone, how are you?",
                        "Let me share my screen.", "Okay.", "Bye everyone, talk soon."] {
            XCTAssertFalse(MeetingText.isSubstantive(chatter), chatter)
        }
        for point in ["We'll move the Android release to Friday.", "Priya owns the token refresh crash fix.",
                      "Good morning, so the main thing today is that the Android release moved to Friday."] {
            XCTAssertTrue(MeetingText.isSubstantive(point), point)
        }
    }

    func testWordsAndNoChange() {
        let lines = [MeetingLine(id: 0, speaker: .them, text: "Can you hear me?", at: Date()),
                     MeetingLine(id: 1, speaker: .them, text: "The release moves to Friday this week.", at: Date())]
        XCTAssertEqual(MeetingText.substantiveWords(lines), 7)
        XCTAssertTrue(MeetingText.isNoChange(" NO CHANGE. "))
        XCTAssertFalse(MeetingText.isNoChange("## Decisions\n- Ship Friday"))
    }
}

final class EmailTests: XCTestCase {
    func testSubjectAndBody() {
        let email = MeetingText.email("Subject: Android release: Friday plan\n\nHi all,\n\nThanks for today.")
        XCTAssertEqual(email.subject, "Android release: Friday plan")
        XCTAssertEqual(email.body, "Hi all,\n\nThanks for today.")
        XCTAssertEqual(MeetingText.email("Hi all, thanks.").subject, "Follow-up")
    }
}

final class LeadInTests: XCTestCase {
    func testLeadInsDontHideAQuestion() {
        for asked in ["So how did you handle the outage", "Okay, and can you walk us through the design",
                      "Alright, what would you change first", "Great, so tell me about your last project"] {
            XCTAssertTrue(MeetingText.isQuestion(asked), asked)
        }
        XCTAssertFalse(MeetingText.isQuestion("So we shipped it last week."))
    }
}
