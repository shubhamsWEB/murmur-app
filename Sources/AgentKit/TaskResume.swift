import Foundation

/// A big task that ran out of steps or time: its request, task list and notes, kept so "continue" (or "carry on",
/// "aage badho", "jaari rakho") picks it up where it stopped instead of starting over. Kept for two hours, in memory.
public enum TaskResume {
    public struct Pending: Sendable {
        public let request: String
        public let steps: [(text: String, done: Bool)]
        public let notes: [String]
        public let at: Date
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: Pending?

    public static func save(_ task: Pending) {
        lock.lock(); defer { lock.unlock() }
        pending = task
    }

    /// The unfinished task, if there's one from the last two hours; taken, so it resumes once.
    public static func take() -> Pending? {
        lock.lock(); defer { lock.unlock() }
        guard let task = pending, Date().timeIntervalSince(task.at) < 2 * 3600 else { return nil }
        pending = nil
        return task
    }

    public static var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let task = pending else { return false }
        return Date().timeIntervalSince(task.at) < 2 * 3600
    }

    /// "Continue", "carry on", "keep going", "finish it", "go on with the emails", "aage badho", "jaari rakho".
    public static func isResume(_ utterance: String) -> Bool {
        let text = QuickCommands.clean(utterance)
        guard text.split(separator: " ").count <= 5 else { return false }   // "continue the story about…" is dictation
        return text.range(of: #"^(ok(ay)? |yes |haan |han )?(please )?(continue|carry on|keep going|resume|finish (it|that|this|the rest|the task|up)|do the rest|keep at it|pick (it )?up where you (left off|stopped)|jaari rakho|jari rakho|aage badho|aage karo|continue karo|chalu rakho|baaki (bhi )?karo|baki (bhi )?karo|poora karo|pura karo)\b"#,
                          options: .regularExpression) != nil
    }
}
