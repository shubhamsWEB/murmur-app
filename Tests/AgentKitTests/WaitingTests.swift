import Foundation
import Testing
@testable import AgentKit

/// What the Memory page shows of what's left to read, and its "Read Now".
@Suite(.serialized) struct WaitingTests {
    @Test func waitingWindowsAreCountedNewestFirst() {
        let journal = Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).sqlite"))
        let now = Date()
        let a = journal.record(Journal.Capture(app: "Slack", bundle: "com.tinyspeck.slackmacgap", title: "#design", url: nil,
                                               text: "Priya: can you send the deck?"), now: now.addingTimeInterval(-600)).id
        let b = journal.record(Journal.Capture(app: "Notes", bundle: "com.apple.Notes", title: "Plan", url: nil,
                                               text: "Ship Murmur 1.6 on Monday"), now: now).id
        var waiting = journal.waiting()
        #expect(waiting.count == 2 && waiting.windows.map(\.id) == [b, a])
        journal.consolidated([a])
        waiting = journal.waiting()
        #expect(waiting.count == 1 && waiting.windows.map(\.id) == [b])
    }

    @Test func readNowIsTakenOnce() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString)")
        let saved = MemoryLog.url
        MemoryLog.url = folder.appendingPathComponent("memory.log")
        defer { MemoryLog.url = saved }
        #expect(!MemoryLog.takeReadingRequest())
        MemoryLog.requestReading()
        #expect(MemoryLog.status()?.text == "Reading starts within a minute")
        #expect(MemoryLog.takeReadingRequest())
        #expect(!MemoryLog.takeReadingRequest())
    }
}
