import Foundation
import Testing
@testable import AgentKit

/// Deciding before the model what's worth its time: conversations first, browsing not about the user skipped, AI
/// chats only for what the user sent, pages far from what matters skipped, and re-read windows only for what's new.
struct TriageTests {
    let now = Date()
    func shot(_ id: Int64, _ app: String, _ url: String?, _ text: String, seconds: Double = 60, authored: String = "",
              readText: String = "") -> Journal.Snapshot {
        var s = Journal.Snapshot(id: id, app: app, title: "t", url: url,
                                 domain: url.flatMap { URL(string: $0)?.host }?.replacingOccurrences(of: "www.", with: "") ?? "",
                                 text: text, first: now, last: now, seconds: seconds, sightings: 1,
                                 kind: "", authored: authored, seenAs: "")
        s.readText = readText
        return s
    }

    @Test func browsingNotAboutTheUserNeedsNoModel() {
        let feed = shot(1, "Google Chrome", "https://www.linkedin.com/feed/", "Ravi Kumar posted about hiring in Bangalore")
        let aboutMe = shot(2, "Google Chrome", "https://www.linkedin.com/feed/", "Shubham, congrats on the launch!")
        let knownFriend = shot(3, "Safari", "https://medium.com/x", "Priya Shah writes about design systems")
        let plan = Triage.plan([feed, aboutMe, knownFriend], me: ["Shubham"]) { $0.contains("Priya Shah") ? ["Priya Shah"] : [] }
        #expect(plan.read.map(\.id).sorted() == [2, 3])
        #expect(plan.skip.map(\.id) == [1])
    }

    @Test func conversationsComeFirstAndAIChatsOnlyForWhatWasSent() {
        let page = shot(1, "Google Chrome", "https://some-blog.dev/post", "A post about Swift", seconds: 900)
        let slack = shot(2, "Slack", nil, "Priya: can you send the deck?", seconds: 30)
        let claudeEmpty = shot(3, "Claude", nil, "Here is a long answer about databases")
        let claudeAsked = shot(4, "Claude", nil, "Here is a long answer", authored: "Help me plan Priya's offsite")
        let plan = Triage.plan([page, slack, claudeEmpty, claudeAsked], me: ["Shubham"]) { _ in [] }
        #expect(plan.read.first?.id == 2)
        #expect(plan.skip.map(\.id) == [3])
        let asked = plan.read.first { $0.id == 4 }
        #expect(asked?.text.contains("Help me plan Priya's offsite") == true)
        #expect(asked?.text.contains("long answer") == false)
    }

    @Test func pagesFarFromWhatMattersAreSkipped() {
        let far = shot(1, "Google Chrome", "https://some-blog.dev/a", "Cooking pasta at home")
        let near = shot(2, "Google Chrome", "https://some-blog.dev/b", "Swift concurrency in Murmur")
        let unknown = shot(3, "Google Chrome", "https://some-blog.dev/c", "No vector yet")
        let plan = Triage.plan([far, near, unknown], me: ["Shubham"], known: { _ in [] }) { s in
            s.id == 1 ? 0.3 : s.id == 2 ? 0.7 : nil
        }
        #expect(plan.read.map(\.id).sorted() == [2, 3])
        #expect(plan.skip.map(\.id) == [1])
    }

    @Test func reReadWindowsSendOnlyWhatsNew() {
        let old = "Priya: lunch Thursday?\nMe: sure"
        let same = shot(1, "Slack", nil, old + "\nok", readText: old)
        let grown = shot(2, "Slack", nil, old + "\nPriya: also please review the hiring plan before Friday's meeting",
                         readText: old)
        let plan = Triage.plan([same, grown], me: ["Shubham"]) { _ in [] }
        #expect(plan.skip.map(\.id) == [1])
        let read = plan.read.first { $0.id == 2 }
        #expect(read?.text.contains("hiring plan") == true)
        #expect(read?.text.contains("lunch Thursday") == false)
    }

    @Test func centroidIsTheAverageDirection() {
        let a = [Float](repeating: 0, count: 256).enumerated().map { $0.offset == 0 ? Float(1) : 0 }
        let b = [Float](repeating: 0, count: 256).enumerated().map { $0.offset == 1 ? Float(1) : 0 }
        let c = MemoryVectors.similarity(a, b)
        #expect(c == 0)
        #expect(MemoryVectors.similarity(a, a) == 1)
    }
}
