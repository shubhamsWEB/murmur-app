import Foundation

/// A big task that didn't finish: its request, task list and notes, kept so "continue" (or "carry on", "aage badho",
/// "jaari rakho") picks it up where it stopped instead of starting over. Saved to disk as it goes (each time the list
/// or the notes change), so it survives Murmur quitting, a crash or a restart; kept for two days, on this Mac only
/// (~/Library/Application Support/Murmur/unfinished-task.json). A task that finishes clears it.
public enum TaskResume {
    public struct Step: Codable, Sendable, Equatable {
        public let text: String
        public let done: Bool
        public init(text: String, done: Bool) {
            self.text = text
            self.done = done
        }
    }

    public struct Pending: Codable, Sendable, Equatable {
        public let request: String
        public let steps: [Step]
        public let notes: [String]
        public let at: Date
        /// The answer it gave, when it finished with one.
        public let answer: String?
        /// It finished (with an answer): "continue" goes further from that answer, for half an hour.
        public let finished: Bool?

        public init(request: String, steps: [Step], notes: [String], at: Date = Date(), answer: String? = nil,
                    finished: Bool? = nil) {
            self.request = request
            self.steps = steps
            self.notes = notes
            self.at = at
            self.answer = answer
            self.finished = finished
        }

        public var openSteps: Int { steps.filter { !$0.done }.count }
    }

    /// How long an unfinished task waits for "continue".
    public static let keptFor: TimeInterval = 2 * 24 * 3600
    /// How long a finished one can still be taken further.
    public static let finishedKeptFor: TimeInterval = 30 * 60

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Pending?
    nonisolated(unsafe) private static var loaded = false
    /// Where it's kept; tests point it elsewhere.
    nonisolated(unsafe) public static var file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Murmur/unfinished-task.json")
    }()

    /// Keeps the task as it stands (called whenever its list or notes change, and when it stops early).
    public static func save(_ task: Pending) {
        lock.lock(); defer { lock.unlock() }
        cached = task
        loaded = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(task) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic])
    }

    /// The task finished (or was replaced by a new one): nothing to continue.
    public static func clear() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        loaded = true
        try? FileManager.default.removeItem(at: file)
    }

    /// The unfinished task, if there's one from the last two days; taken, so it resumes once (it's saved again as
    /// the resumed task goes on).
    public static func take() -> Pending? {
        lock.lock(); defer { lock.unlock() }
        guard let task = current() else { return nil }
        cached = nil
        try? FileManager.default.removeItem(at: file)
        return task
    }

    public static var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return current() != nil
    }

    /// The saved task if it's recent and has steps left. Call with the lock held.
    private static func current() -> Pending? {
        if !loaded {
            loaded = true
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            cached = (try? Data(contentsOf: file)).flatMap { try? decoder.decode(Pending.self, from: $0) }
        }
        guard let task = cached else { return nil }
        let age = Date().timeIntervalSince(task.at)
        if task.finished == true { return age < finishedKeptFor ? task : nil }
        return age < keptFor && task.openSteps > 0 ? task : nil
    }

    /// Forget what was read, so the next look reads the file again (tests).
    static func reload() {
        lock.lock(); defer { lock.unlock() }
        loaded = false
        cached = nil
    }

    /// "Continue", "carry on", "keep going", "finish it", "go on", "read the rest", "aage badho", "jaari rakho",
    /// "aage batao".
    public static func isResume(_ utterance: String) -> Bool {
        let text = QuickCommands.clean(utterance)
        guard text.split(separator: " ").count <= 5 else { return false }   // "continue the story about…" is dictation
        return text.range(of: #"^(ok(ay)? |yes |haan |han )?(please )?(continue|carry on|keep going|resume|finish (it|that|this|the rest|the task|up)|do the rest|keep at it|pick (it )?up where you (left off|stopped)|jaari rakho|jari rakho|aage badho|aage karo|continue karo|chalu rakho|baaki (bhi )?karo|baki (bhi )?karo|poora karo|pura karo|go on|keep reading|read (the )?rest|read more|aage batao|aage padho|baaki batao|baki batao)\b"#,
                          options: .regularExpression) != nil
    }
}
