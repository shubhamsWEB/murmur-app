import Foundation
import Testing
@testable import AgentKit

/// What the Memory page showed on 2026-11-06: the user twice ("You" and "Shubham Agrawal"), "Voice" and "Press" as
/// people, "Viewed LinkedIn profile of…", three wordings of one fact, and a promise to the user from the user.
struct YouOnceTests {
    func store() -> BrainStore {
        BrainStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString).sqlite"))
    }
    func fact(_ about: String, _ kind: BrainModel.EntityKind, _ text: String, _ origin: BrainModel.Origin = .screen)
        -> BrainModel.Candidate {
        BrainModel.Candidate(about: about, aboutKind: kind, text: text, kind: .fact, confidence: 1, origin: origin)
    }

    @Test func theUserIsOneEntity() {
        let brain = store()
        // The user's own contact card read before the user was known: a person of their name.
        brain.apply([fact("Shubham Agrawal", .person, "Shubham Agrawal's email: s@example.com", .contacts)], item: nil)
        let me = brain.entity(named: "me", kind: .me)!
        brain.addAlias("Shubham Agrawal", to: me)
        brain.addAlias("Shubham", to: me)
        #expect(brain.mergeMe() == 1)
        #expect(brain.entities(kind: .person).isEmpty)
        #expect(brain.memories(of: me).count == 1)
        // And from now on the screen's "Shubham Agrawal" is the user too.
        brain.apply([fact("Shubham Agrawal", .person, "Shubham Agrawal builds Murmur")], item: nil)
        #expect(brain.entities(kind: .person).isEmpty)
        #expect(brain.memories(of: me).count == 2)
        #expect(brain.fromScreen().map(\.about) == ["You"])
    }

    @Test func lookingIsNotKnowing() {
        #expect(Consolidator.isActivity("Viewed LinkedIn profile of Shubham Agrawal, software engineer, on LinkedIn."))
        #expect(Consolidator.isActivity("Visited Hugging Face Space multiple times"))
        #expect(Consolidator.isActivity("Shubham viewed the Kanth TTS space on Hugging Face"))
        #expect(!Consolidator.isActivity("Priya leads design at Acme"))
        #expect(!Consolidator.isActivity("Murmur's build script fails on the signing step"))
    }

    @Test func wordsOnAPageAreNotPeople() {
        #expect(Consolidator.isCommonWord("Voice") && Consolidator.isCommonWord("Press") && Consolidator.isCommonWord("Information"))
        #expect(!Consolidator.isCommonWord("Priya") && !Consolidator.isCommonWord("Arjun Sawhney"))
        let now = Date()
        let page = Journal.Snapshot(id: 1, app: "Google Chrome", title: "Kanth TTS", url: "https://huggingface.co/spaces/x",
                                    domain: "huggingface.co", text: "Voice. Press to record. Kanth TTS by Lakshay1201, text to speech.",
                                    first: now, last: now, seconds: 120, sightings: 1)
        let kept = Consolidator.judge([fact("Voice", .person, "Voice is a text to speech record"),
                                       fact("Lakshay1201", .person, "Lakshay1201 made Kanth TTS, text to speech")],
                                      seen: [page], browsing: [], me: ["Shubham"]) { _ in [] }
        #expect(kept.map(\.about) == ["Lakshay1201"])
    }

    @Test func noPromisesToYourself() {
        let now = Date()
        let terminal = Journal.Snapshot(id: 1, app: "Terminal", title: "murmur", url: nil, domain: "",
                                        text: "Shubham: fix the build error before the release", first: now, last: now,
                                        seconds: 300, sightings: 1)
        let selfish = Journal.Promise(summary: "Fix the build error", person: "Shubham Agrawal", kind: "asked")
        #expect(Consolidator.judge(promises: [selfish], seen: [terminal], me: ["Shubham Agrawal", "Shubham"]) { _ in [] }.isEmpty)
    }
}
