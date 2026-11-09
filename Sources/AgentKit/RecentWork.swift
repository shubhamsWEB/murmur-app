import Foundation

/// The last few commands in each window, with what they worked out, for the next command there. A follow-up that
/// isn't a literal "continue" ("do it", "do the complete board, not just one number", "fill all of them", "now the
/// rest") used to start from nothing: on 9 Nov the model had solved the puzzle twice, and the next command, with no
/// trace of that, said it "couldn't reliably solve" it. Kept in memory only, for half an hour; the next command in
/// the same window sees them as context (it decides whether the new request builds on them).
public enum RecentWork {
    public struct Entry: Sendable, Equatable {
        public let request: String
        public let window: String
        public let at: Date
        /// What it showed the user at the end, if anything.
        public let answer: String?
        /// What it worked out on the way: outputs of commands it ran, its notes.
        public let workedOut: [String]
        /// Whether it changed anything on the screen.
        public let acted: Bool

        public init(request: String, window: String, at: Date = Date(), answer: String?, workedOut: [String], acted: Bool) {
            self.request = request
            self.window = window
            self.at = at
            self.answer = answer
            self.workedOut = workedOut
            self.acted = acted
        }
    }

    public static let keptFor: TimeInterval = 30 * 60
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []

    public static func record(_ entry: Entry) {
        guard !entry.window.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        entries = Array(entries.filter { Date().timeIntervalSince($0.at) < keptFor }.suffix(12))
    }

    /// The commands in this window in the last half hour, oldest first, at most `limit`.
    public static func recent(in window: String, now: Date = Date(), limit: Int = 3) -> [Entry] {
        guard !window.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        return Array(entries.filter { $0.window == window && now.timeIntervalSince($0.at) < keptFor }.suffix(limit))
    }

    public static func clear() {
        lock.lock(); defer { lock.unlock() }
        entries = []
    }

    /// For the model: the earlier commands in this window and what they worked out, so a follow-up builds on them.
    public static func context(_ entries: [Entry], now: Date = Date()) -> String? {
        guard !entries.isEmpty else { return nil }
        var lines = ["Earlier commands in this same window (newest last). If the new request follows on from them "
            + "(\"do it\", \"all of it\", \"the rest\", \"not just one\"), it means the same job: build on what was "
            + "worked out below instead of starting over, check the screen for what's already done, and finish it."]
        for entry in entries {
            let minutes = max(0, Int(now.timeIntervalSince(entry.at) / 60))
            lines.append("- \(minutes == 0 ? "Just now" : "\(minutes) min ago"): \"\(entry.request.prefix(200))\""
                + (entry.acted ? " (it changed things on screen)" : " (nothing on screen was changed)"))
            for item in entry.workedOut.suffix(2) {
                lines.append("  Worked out: \(item.prefix(1500))")
            }
            if let answer = entry.answer, !answer.isEmpty {
                lines.append("  It ended with: \"\(answer.prefix(600))\"")
            }
        }
        return lines.joined(separator: "\n")
    }
}
