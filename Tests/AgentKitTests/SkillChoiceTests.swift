import Foundation
import Testing
@testable import AgentKit

/// The skills that come with Murmur, read from their real SKILL.md files, and which ones each request gets.
struct SkillChoiceTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Skills")
    let skills = SkillFiles.load(from: folder, builtIn: true)

    func inFull(_ said: String, cuaInstalled: Bool = false) -> Set<String> {
        let chosen = SkillFiles.choose(skills, for: said, mode: { $0.defaultMode },
                                       available: { $0.requires == nil || cuaInstalled })
        return Set(chosen.full.map(\.0.name))
    }

    @Test func allLoad() {
        #expect(skills.map(\.name).sorted() == ["chats-and-messages", "cua-driver", "email-triage", "filling-forms",
                                               "long-tasks", "online-shopping", "web-research", "working-on-the-mac"])
        for skill in skills {
            #expect(!skill.description.isEmpty, "\(skill.name) has no description")
            #expect(skill.body.count > 200, "\(skill.name) has almost no instructions")
        }
        #expect(skills.first { $0.name == "working-on-the-mac" }?.defaultMode == .always)
        #expect(skills.first { $0.name == "cua-driver" }?.requires == "cua-driver")
    }
    @Test func requestsGetTheirSkills() {
        let always: Set<String> = ["working-on-the-mac"]
        #expect(inFull("open finder") == always)
        #expect(inFull("open slack").contains("chats-and-messages"))   // "slack" is one of its triggers
        #expect(inFull("go through my unread emails and tell me what matters")
                == always.union(["email-triage", "long-tasks"]))
        #expect(inFull("summarise my WhatsApp chat with Roma").contains("chats-and-messages"))
        #expect(inFull("find the cheapest iPhone 16 on Flipkart").contains("online-shopping"))
        #expect(inFull("fill in this form with my details").contains("filling-forms"))
        #expect(inFull("compare the best laptops under one lakh").contains("web-research"))
        #expect(inFull("use the web research skill for this").contains("web-research"))
    }
    @Test func cuaDriverOnlyWhenInstalled() {
        #expect(!inFull("open slack").contains("cua-driver"))
        #expect(inFull("open slack", cuaInstalled: true).contains("cua-driver"))
        let missing = SkillFiles.choose(skills, for: "open slack", mode: { $0.defaultMode },
                                        available: { $0.requires == nil }).missing
        #expect(missing.map(\.name) == ["cua-driver"])
    }
    @Test func turnedOffIsLeftOut() {
        let chosen = SkillFiles.choose(skills, for: "go through my unread emails",
                                       mode: { $0.name == "email-triage" ? .off : $0.defaultMode }, available: { _ in true })
        #expect(!chosen.full.contains { $0.0.name == "email-triage" })
        #expect(!chosen.listed.contains { $0.name == "email-triage" })
    }
}

/// What's shown under an answer.
struct TaskTraceTests {
    @Test func stepsInPlainWords() {
        var trace = TaskTrace(started: Date().addingTimeInterval(-34))
        trace.follow("working-on-the-mac", because: "always on")
        trace.follow("email-triage", because: "matched the request")
        trace.follow("email-triage", because: "loaded for this task")   // once
        trace.record("open_url", ["url": "mail.google.com"], result: "Opened mail.google.com")
        trace.record("browser_click", ["text": "Inbox"], result: "Nothing on the page says \"Inbox\".")
        trace.record("read_whole_page", [:], result: "The whole page, read to the very end")
        trace.record("wait", ["seconds": "2"], result: "Waited 2 s.")
        trace.record("reply", ["text": "You have 3 emails"], result: "Shown.")
        #expect(trace.skills == ["working-on-the-mac", "email-triage"])
        #expect(trace.why["email-triage"] == "matched the request")
        #expect(trace.steps.map(\.text) == ["Opened mail.google.com", "Clicked “Inbox”", "Read the whole page", "Answered"])
        #expect(trace.steps.map(\.worked) == [true, false, true, true])
        #expect(trace.summary() == "2 skills · 3 steps · 1 didn't work · 34 s")
    }
    @Test func emptyWhenNothingHappened() {
        #expect(TaskTrace().isEmpty)
        #expect(TaskTrace.describe("some_new_tool", [:]) == "Some new tool")
    }
}

/// The Gmail "Sent" run of 20 Oct: clicks that did nothing, each followed by a read.
struct GoingNowhereTests {
    @Test func clicksThatChangeNothingAreFailures() {
        #expect(TaskHealth.isFailure("Clicked link “Sent”.\nNothing changed: the page is still “Inbox (46,591)”"))
        var health = TaskHealth()
        let first = health.record([("browser_click", "Clicked “Sent”.\nNothing changed: the page is still “Inbox”"),
                                   ("browser_read", "Browser: Chrome · Inbox · page text…")], openSteps: nil, doneSteps: nil)
        #expect(first == nil)
        let second = health.record([("open_url", "Opened … in the tab.\nNothing changed: the page is still “Inbox”"),
                                    ("wait", "Waited 2 s."), ("browser_read", "page text")], openSteps: nil, doneSteps: nil)
        #expect(second?.contains("#sent") == true)
        #expect(second?.contains("don't ask the user") == true)
    }
}
