import Foundation
import Testing
@testable import AgentKit

/// The living memory: its rules (BrainModel), what it keeps (BrainStore, on a temporary file), and reading the
/// local model's answers (BrainDistiller.parse).
struct BrainModelTests {
    let day: Double = 86400

    func memory(_ id: Int64, _ text: String, kind: BrainModel.Kind = .fact, slot: String? = nil, confidence: Double = 0.9,
                daysAgo: Double = 0, expires: Date? = nil, pinned: Bool = false, uses: Int = 0) -> BrainModel.Memory {
        let at = Date().addingTimeInterval(-daysAgo * day)
        return BrainModel.Memory(id: id, entity: 1, text: text, kind: kind, slot: slot, confidence: confidence, created: at,
                                 confirmed: at, expires: expires, pinned: pinned, origin: pinned ? .told : .notes, uses: uses)
    }

    func candidate(_ text: String, slot: String? = nil, origin: BrainModel.Origin = .notes) -> BrainModel.Candidate {
        BrainModel.Candidate(about: "Priya Shah", aboutKind: .person, text: text, kind: .fact, slot: slot,
                             confidence: 0.6, origin: origin)
    }

    @Test func sameThingConfirms() {
        let known = [memory(7, "Priya Shah works at Acme as a product manager")]
        #expect(BrainModel.decide(candidate("Priya Shah works at Acme as product manager"), existing: known) == .confirm(7))
    }

    @Test func newValueForASlotReplaces() {
        let known = [memory(3, "Priya Shah works at Acme", slot: "employer")]
        #expect(BrainModel.decide(candidate("Priya Shah joined Globex", slot: "works_at"), existing: known) == .replace(3))
    }

    @Test func whatTheUserSaidWins() {
        let known = [memory(4, "Priya's email is p@home.com", slot: "email", pinned: true)]
        #expect(BrainModel.decide(candidate("Priya's email is priya@acme.com", slot: "email"), existing: known) == .keepTold)
        #expect(BrainModel.decide(candidate("Priya's email is new@x.com", slot: "email", origin: .told), existing: known)
            == .replace(4))
    }

    @Test func somethingNewIsAdded() {
        let known = [memory(1, "Priya Shah works at Acme", slot: "employer")]
        #expect(BrainModel.decide(candidate("Priya Shah has two kids"), existing: known) == .add)
    }

    @Test func memoriesFadeByKind() {
        let fact = memory(1, "a", kind: .fact, confidence: 1, daysAgo: 365)
        let event = memory(2, "b", kind: .event, confidence: 1, daysAgo: 30)
        #expect(abs(BrainModel.strength(fact) - 0.5) < 0.01)
        #expect(abs(BrainModel.strength(event) - 0.5) < 0.01)
        #expect(BrainModel.isStale(memory(3, "c", kind: .status, confidence: 0.6, daysAgo: 120)))
        #expect(!BrainModel.isStale(memory(4, "d", kind: .fact, confidence: 0.6, daysAgo: 120)))
    }

    @Test func usedMemoriesFadeSlower() {
        let unused = memory(1, "a", kind: .status, confidence: 1, daysAgo: 90)
        let used = memory(2, "a", kind: .status, confidence: 1, daysAgo: 90, uses: 4)
        #expect(BrainModel.strength(used) > BrainModel.strength(unused) * 2)
    }

    @Test func expiredIsGoneAndToldNeverFades() {
        #expect(BrainModel.strength(memory(1, "a", expires: Date().addingTimeInterval(-60))) == 0)
        #expect(BrainModel.strength(memory(2, "b", confidence: 0.3, daysAgo: 3000, pinned: true)) == 1)
    }

    @Test func confirmingMakesSurerByLessEachTime() {
        let once = BrainModel.confirmed(confidence: 0.6, by: 0.6)
        let twice = BrainModel.confirmed(confidence: once, by: 0.6)
        #expect(once > 0.6 && twice > once && twice - once < once - 0.6 && twice <= 1)
    }

    @Test func slotsAndNamesAreMatchedLoosely() {
        #expect(BrainModel.slotKey("Works At") == "employer")
        #expect(BrainModel.slotKey("job-title") == "role")
        #expect(BrainModel.slotKey("DOB") == "birthday")
        #expect(BrainModel.nameKey("Dr. Priya  Shah") == "priya shah")
        #expect(BrainModel.EntityKind.read("Company") == .organization)
        #expect(BrainModel.Kind.read("TASK") == .task)
    }

    @Test func secretsAreTakenOut() {
        #expect(BrainModel.hasSecret("Your verification code is 482913"))
        #expect(BrainModel.hasSecret("password: hunter2go"))
        #expect(BrainModel.hasSecret("key sk-ant-abcdefghijklmnop1234"))
        #expect(BrainModel.hasSecret("card 4111 1111 1111 1111"))
        #expect(!BrainModel.hasSecret("Priya Shah is the user's manager at Acme"))
        #expect(BrainModel.redact("OTP 1234 for login").contains("[hidden]"))
    }
}

struct BrainDistillerTests {
    @Test func readsTheModelsJSON() {
        let answer = """
            Sure! {"memories": [
              {"about": "Arjun Mehta", "about_kind": "colleague", "text": "Arjun Mehta leads design at Globex",
               "kind": "fact", "slot": "Role", "expires": ""},
              {"about": "user", "about_kind": "me", "text": "The user has to send the Q3 deck to Arjun",
               "kind": "task", "slot": "", "expires": "2999-01-10"},
              {"about": "", "about_kind": "person", "text": "No subject here at all", "kind": "fact"},
              {"about": "Old", "about_kind": "topic", "text": "A party that already happened", "kind": "event",
               "expires": "2001-01-01"}
            ]}
            """
        let found = BrainDistiller.parse(answer, origin: .mail)
        #expect(found.count == 2)
        #expect(found[0].aboutKind == .person && found[0].slot == "role" && found[0].confidence == 0.6)
        #expect(found[1].aboutKind == .me && found[1].kind == .task && found[1].expires != nil)
        #expect(found.allSatisfy { $0.origin == .mail })
    }

    @Test func nothingWorthKeeping() {
        #expect(BrainDistiller.parse(#"{"memories": []}"#, origin: .notes).isEmpty)
        #expect(BrainDistiller.parse("no json here", origin: .notes).isEmpty)
    }
}

struct BrainStoreTests {
    func store() -> BrainStore {
        BrainStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString).sqlite"))
    }

    func fact(_ about: String, _ text: String, slot: String? = nil, kind: BrainModel.Kind = .fact,
              origin: BrainModel.Origin = .contacts, expires: Date? = nil) -> BrainModel.Candidate {
        BrainModel.Candidate(about: about, aboutKind: .person, text: text, kind: kind, slot: slot, expires: expires,
                             confidence: 0.9, origin: origin)
    }

    @Test func learnsConfirmsAndReplaces() {
        let brain = store()
        var applied = brain.apply([fact("Priya Shah", "Priya Shah works at Acme", slot: "employer"),
                                   fact("Priya Shah", "Priya Shah's birthday is 4 March", slot: "birthday")], item: "contacts:1")
        #expect(applied.added == 2)
        applied = brain.apply([fact("priya shah", "Priya Shah works at Acme")], item: "contacts:1")
        #expect(applied.confirmed == 1)
        applied = brain.apply([fact("Priya Shah", "Priya Shah works at Globex", slot: "employer")], item: "contacts:1")
        #expect(applied.replaced == 1)
        let people = brain.entities(kind: .person)
        #expect(people.count == 1)
        let texts = brain.memories(of: people[0].id).map(\.text)
        #expect(texts.contains("Priya Shah works at Globex") && !texts.contains("Priya Shah works at Acme"))
        #expect(brain.changes().contains { $0.what == "updated" })
    }

    @Test func findsByNameAndWords() {
        let brain = store()
        brain.apply([fact("Arjun Mehta", "Arjun Mehta leads design at Globex"),
                     fact("Priya Shah", "Priya Shah plays tennis on Sundays")], item: nil)
        #expect(brain.search("what do you know about Arjun?").first?.about == "Arjun Mehta")
        #expect(brain.search("who plays tennis").first?.memory.text.contains("tennis") == true)
        #expect(brain.search("quantum physics").isEmpty)
    }

    @Test func keepsNoSecrets() {
        let brain = store()
        let applied = brain.apply([fact("Bank", "Your verification code is 482913", origin: .mail)], item: nil)
        #expect(applied.total == 0)
    }

    @Test func forgetsWhatWasDeletedAtTheSource() {
        let brain = store()
        _ = brain.changed(source: "contacts", items: ["1": ("a", "Priya"), "2": ("b", "Arjun")], complete: true)
        brain.apply([fact("Priya Shah", "Priya Shah works at Acme")], item: "contacts:1")
        brain.apply([fact("Arjun Mehta", "Arjun Mehta works at Globex")], item: "contacts:2")
        brain.read(source: "contacts", key: "1", hash: "a")
        brain.read(source: "contacts", key: "2", hash: "b")
        // Unchanged: nothing to read again. Changed: read again. Gone: forgotten.
        let fresh = brain.changed(source: "contacts", items: ["1": ("a2", "Priya")], complete: true)
        #expect(fresh == ["1"])
        #expect(brain.entities().map(\.name) == ["Priya Shah"])
        #expect(brain.changes().contains { $0.what == "forgot" })
    }

    @Test func tidyArchivesWhatsExpired() {
        let brain = store()
        brain.apply([fact("me", "Coming up: dentist", kind: .event, expires: Date().addingTimeInterval(-3600)),
                     fact("me", "Your name is Sam Lee")], item: nil)
        #expect(brain.tidy() == 1)
        #expect(brain.counts().memories == 1)
    }

    @Test func upcomingIsSoonestFirst() {
        let brain = store()
        let soon = Date().addingTimeInterval(3600), later = Date().addingTimeInterval(86400 * 3)
        brain.apply([BrainModel.Candidate(about: "me", aboutKind: .me, text: "Coming up: design review", kind: .event,
                                          expires: later, confidence: 1, origin: .calendar),
                     BrainModel.Candidate(about: "me", aboutKind: .me, text: "To do: send the deck", kind: .task,
                                          expires: soon, confidence: 1, origin: .reminders)], item: nil)
        #expect(brain.upcoming().map(\.memory.text) == ["To do: send the deck", "Coming up: design review"])
    }

    @Test func sourcesRememberTheirSwitch() {
        let brain = store()
        #expect(brain.source("notes", enabledByDefault: false).enabled == false)
        brain.setSource("notes", enabled: true)
        brain.synced("notes", status: "Up to date", items: 12, enabled: true)
        let state = brain.source("notes", enabledByDefault: false)
        #expect(state.enabled && state.items == 12 && state.status == "Up to date")
    }
}
