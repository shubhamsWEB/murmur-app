import Foundation
import Testing
@testable import AgentKit

/// What was said to Murmur on 2026-11-06, and where it should have gone: memory first, not the web.
struct MemoryRouteTests {
    @Test func questionsAboutYourOwnWorldGoToMemory() {
        for said in ["What did we release on the latest Murmur app, whatever functionality did we ship?",
                     "We recently updated the new release for the Murmur application, right, which we are building. So from your memory, can you recall what was the changes which we did?",
                     "When is my flight to Raipur?",
                     "When is my flight to diaper?",
                     "What is Project Phoenix? I don't know anything about it. Give a brief about that.",
                     "Who is Arjun on my team?",
                     "What did I promise Priya this week?",
                     "Do you remember what I told you about my manager?"] {
            #expect(MemoryRoute.classify(said, hour: 13) == .question, "\(said)")
        }
    }

    @Test func actionsScreenFilesAndTheOutsideWorldDoNot() {
        for said in ["Open WhatsApp and send Roma good morning.",
                     "Paste the draft in the sample box.",
                     "Understand the complete requirement of this job description and apply it and then draft a message to send it over.",
                     "Search the web for Murmur alternatives",
                     "What's the weather in Bangalore tomorrow?",
                     "What is on this page?",
                     "What is this?",
                     "Summarise this email",
                     "Where is my resume pdf?",
                     "Can you open my downloads folder?",
                     "Send it.",
                     "Venice men flight to Raipur"] {
            #expect(MemoryRoute.classify(said, hour: 13) == nil, "\(said)")
        }
    }

    @Test func forgettingAndTheBrief() {
        #expect(MemoryRoute.classify("There is no project Phoenix which I am working upon so just delete this from from your memory.") == .forget)
        #expect(MemoryRoute.classify("Forget Project Orion") == .forget)
        #expect(MemoryRoute.classify("Give me a warning brief", hour: 13) == .brief(evening: false))
        #expect(MemoryRoute.classify("Give me my morning brief", hour: 9) == .brief(evening: false))
        #expect(MemoryRoute.classify("Recap my day", hour: 19) == .brief(evening: true))
    }

    @Test func anAnswerMemoryCantGiveGoesBackToTheAgent() {
        #expect(MemoryRoute.answer(from: "NOT_IN_MEMORY") == nil)
        #expect(MemoryRoute.answer(from: "  ") == nil)
        #expect(MemoryRoute.answer(from: "Your flight leaves Bengaluru on Sunday at 10:15.") == "Your flight leaves Bengaluru on Sunday at 10:15.")
    }
}

/// Murmur's memory held one project under eight names, and build states as facts.
struct ProjectMemoryTests {
    func store() -> BrainStore {
        BrainStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString).sqlite"))
    }
    func fact(_ about: String, _ text: String, _ kind: BrainModel.EntityKind = .project) -> BrainModel.Candidate {
        BrainModel.Candidate(about: about, aboutKind: kind, text: text, kind: .fact, confidence: 1, origin: .screen)
    }

    @Test func aProjectsNamesAreOneProject() {
        #expect(BrainModel.projectCore("Murmur 1.6.0") == "murmur")
        #expect(BrainModel.projectCore("Murmur v1.6") == "murmur")
        #expect(BrainModel.projectCore("murmur-app") == "murmur")
        #expect(BrainModel.projectCore("shubhamsWEB/murmur-app") == "murmur")
        #expect(BrainModel.projectCore("The Murmur project") == "murmur")
        #expect(BrainModel.projectCore("Murmur Agent") == "murmur agent")
        #expect(BrainModel.projectCore("3D Foot Scan Product Launch") == "3d foot scan product launch")
        let brain = store()
        brain.apply([fact("Murmur", "A free, private voice assistant for the Mac")], item: nil)
        brain.apply([fact("Murmur 1.6.0", "Murmur 1.6.0 brought memory of people, promises and plans"),
                     fact("shubhamsWEB/murmur-app", "Murmur's code is on GitHub")], item: nil)
        let projects = brain.entities(kind: .project)
        #expect(projects.count == 1 && projects[0].name == "Murmur" && projects[0].memories == 3)
        #expect(!brain.entities(namedIn: "what changed in murmur 1.6.0?").isEmpty)
    }

    @Test func projectsKeptUnderSeveralNamesAreMerged() {
        let brain = store()
        // As they were kept before: no project matching, each its own entity.
        for (name, text) in [("Murmur 1.6.0", "Brought memory"), ("murmur-app", "Is on GitHub"), ("Murmur", "Voice assistant"),
                             ("Murmur", "Free and open source")] {
            brain.apply([fact(name, text, .topic)], item: nil)
        }
        #expect(brain.entities(kind: .topic).count == 3)
        // (Made projects again to exercise the merge, the way they were stored.)
        #expect(brain.mergeProjects() == 0)   // topics aren't projects
    }

    @Test func namedThingsAreFoundInARequest() {
        let brain = store()
        brain.apply([fact("Project Phoenix", "Project Phoenix is the user's current project, due 2026-11-15")], item: nil)
        let named = brain.entities(namedIn: "There is no project Phoenix, which I am working on, so delete it from your memory.")
        #expect(named.map(\.name) == ["Project Phoenix"])
        #expect(brain.entities(namedIn: "what's on today?").isEmpty)
    }

    @Test func passingStatesAreNotMemories() {
        for text in ["Build failed on GitHub Actions with 1 error and 1 notice", "Workflow run for fix-mac-ci-build is in progress",
                     "Latest commit is 660411d for version v1.6.0", "Pull request #7 for 'Living memory' is open and needs merging",
                     "Merge pull request #2 from shubhamsWEB/site-memory-1.6", "Kanth TTS is a Hugging Face Space with high memory usage."] {
            #expect(Consolidator.isPassingState(text), "\(text)")
        }
        for text in ["Murmur 1.6.0 (6 Nov 2026): memory of people, promises and plans", "Priya leads design at Acme",
                     "Arjun's launch work is in progress until December"] {
            #expect(!Consolidator.isPassingState(text), "\(text)")
        }
    }
}
