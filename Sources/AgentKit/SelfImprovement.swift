import Foundation

/// Self-Improvement Memory: how Murmur's command agent learns from its own mistakes, and keeps track of whether what
/// it learned actually helps. After "Self-Improvement Memory Enables Continual Recursive Self-Improvement" (Yu, Xia et
/// al., Google Cloud AI and Google DeepMind, Nov 2026, arXiv 2611.18856), on the agent's harness (its instructions)
/// rather than on a benchmark.
///
/// The paper's finding: an optimizer that only keeps the improved harness, or only the diagnoses, does worse than
/// one that keeps the whole record: each problem (keyed by its root cause) with every fix tried for it, why, what it
/// was predicted to fix (written down before it was tried), what actually happened, and where (which model, which
/// task). Fixes that regressed are kept too. Reading that record, a later round can tell whether a fix still applies
/// (a harness tuned with one model did worse with another than the untuned one) and keep, revise or drop it.
///
/// Here:
/// - A command that went wrong (steps that failed, an early finish Murmur had to send back, a task it stopped, or
///   you correcting it straight after: "no, I meant…") is a run worth learning from.
/// - The commands' AI reads that run and the whole memory, names the root cause (citing one already in the memory
///   or a new one), and proposes a rule for Murmur to follow from then on, with its reason, when it applies (apps,
///   words in a request), and a prediction of what it will fix. That's one attempt.
/// - The rule goes into the agent's instructions for matching commands. Each time, whether the command then worked
///   is recorded with the model that ran it.
/// - The evidence decides: a rule that doesn't help with a model is turned off for that model; one that doesn't help
///   at all is retired, and the next problem of that kind gets a revised rule that sees why the last one failed.
///   Nothing is deleted except by you (Memory page).
///
/// On this Mac only (Application Support/Murmur/self-improvement.json), as JSON, small: at most 60 problems.
public final class SelfImprovement: @unchecked Sendable {
    public static let shared = SelfImprovement(file: SelfImprovement.defaultFile)

    // MARK: - The record

    /// When a rule applies: in these apps, or for requests with these words. Both empty: every command.
    public struct Scope: Codable, Equatable, Sendable {
        public var apps: [String]
        public var words: [String]

        public init(apps: [String] = [], words: [String] = []) {
            self.apps = apps
            self.words = words
        }
    }

    /// One command a rule was applied to, and whether it then worked.
    public struct Observation: Codable, Equatable, Sendable {
        public var at: Date
        public var model: String
        public var worked: Bool
        public var request: String
    }

    /// One fix tried for a problem: the rule, why, when it applies, what it should fix (written before it's
    /// tried), where it came from, and what happened since.
    public struct Attempt: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var rule: String
        public var rationale: String
        public var scope: Scope
        public var prediction: String
        /// Provenance: the model and app of the run that showed the problem, when, and which round of learning.
        public var model: String
        public var app: String
        public var created: Date
        public var round: Int
        /// The request that showed the problem.
        public var trigger: String
        public var observed: [Observation]
        /// Why it's no longer used (nil while it is).
        public var retired: String?
        /// Models it's off for, because it didn't help there.
        public var notFor: [String]

        /// "worked 4 of 5"
        public func tally(model: String? = nil) -> (worked: Int, of: Int) {
            let seen = observed.filter { model == nil || $0.model == model }
            return (seen.filter(\.worked).count, seen.count)
        }
    }

    /// A recurring problem, keyed by its root cause, with every fix tried for it in order.
    public struct Problem: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var rootCause: String
        public var attempts: [Attempt]

        /// The fix in use (the latest one not retired).
        public var current: Attempt? { attempts.last { $0.retired == nil } }
    }

    private let lock = NSLock()
    private var store: [Problem] = []
    private let file: URL?
    private static let keepProblems = 60

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder.memory.decode([Problem].self, from: data) {
            store = saved
        }
    }

    static var defaultFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("self-improvement.json")
    }

    /// Learn from mistakes (on unless turned off on the Memory page).
    public static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "selfImprovement.on") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "selfImprovement.on") }
    }

    public var problems: [Problem] { lock.withLock { store } }

    // MARK: - Using what was learned

    /// A rule in use for a command.
    public struct Lesson: Sendable, Equatable {
        public let problem: String
        public let attempt: String
        public let rule: String
    }

    /// The rules for a command: the problems' current fixes whose scope matches the request or the app, not turned
    /// off for this model, the best-proven first.
    public func lessons(for request: String, app: String?, model: String, limit: Int = 6) -> [Lesson] {
        let words = Self.words(request)
        let app = (app ?? "").lowercased()
        return lock.withLock {
            store.compactMap { problem -> (Lesson, Int)? in
                guard let attempt = problem.current, !attempt.notFor.contains(model) else { return nil }
                let scope = attempt.scope
                let byApp = !app.isEmpty && scope.apps.contains { !$0.isEmpty && app.contains($0.lowercased()) }
                let byWords = scope.words.contains { word in
                    let parts = Self.words(word)
                    return !parts.isEmpty && parts.allSatisfy(words.contains)
                }
                let everywhere = scope.apps.isEmpty && scope.words.isEmpty
                guard byApp || byWords || everywhere else { return nil }
                let tally = attempt.tally()
                return (Lesson(problem: problem.id, attempt: attempt.id, rule: attempt.rule), tally.worked * 2 - tally.of)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
        }
    }

    /// The rules, as they go into the agent's instructions.
    public static func prompt(_ lessons: [Lesson]) -> String? {
        guard !lessons.isEmpty else { return nil }
        return "Rules Murmur learned from its own earlier mistakes on tasks like this (follow them unless the user's "
            + "request says otherwise):\n" + lessons.map { "- \($0.rule)" }.joined(separator: "\n")
    }

    // MARK: - What happened

    /// Records how a command went for each rule it used, and lets the evidence decide: a rule that hasn't helped
    /// with this model (worked under half the time, in 3 or more tries) is turned off for it; one that hasn't helped
    /// with any model (4 or more tries) is retired. Returns what changed, for the log.
    @discardableResult
    public func observe(_ lessons: [Lesson], worked: Bool, model: String, request: String, at: Date = Date()) -> [String] {
        guard !lessons.isEmpty else { return [] }
        var changes: [String] = []
        lock.withLock {
            for lesson in lessons {
                guard let p = store.firstIndex(where: { $0.id == lesson.problem }),
                      let a = store[p].attempts.firstIndex(where: { $0.id == lesson.attempt }) else { continue }
                store[p].attempts[a].observed.append(Observation(at: at, model: model, worked: worked,
                                                                 request: String(request.prefix(120))))
                changes += judge(p, a, model: model)
            }
        }
        save()
        return changes
    }

    /// A command that looked fine turned out wrong (you corrected it straight after): its observations become
    /// "didn't work", and the evidence is weighed again.
    @discardableResult
    public func correct(_ lessons: [Lesson], model: String, request: String) -> [String] {
        guard !lessons.isEmpty else { return [] }
        let request = String(request.prefix(120))
        var changes: [String] = []
        lock.withLock {
            for lesson in lessons {
                guard let p = store.firstIndex(where: { $0.id == lesson.problem }),
                      let a = store[p].attempts.firstIndex(where: { $0.id == lesson.attempt }),
                      let o = store[p].attempts[a].observed.lastIndex(where: { $0.request == request && $0.model == model })
                else { continue }
                store[p].attempts[a].observed[o].worked = false
                changes += judge(p, a, model: model)
            }
        }
        save()
        return changes
    }

    /// The selector, for one attempt (called holding the lock): off for a model it hasn't helped (under half, in 3
    /// or more tries with it), retired when it hasn't helped at all (under half, in 4 or more tries).
    private func judge(_ p: Int, _ a: Int, model: String) -> [String] {
        var changes: [String] = []
        let attempt = store[p].attempts[a]
        let here = attempt.tally(model: model)
        if here.of >= 3, Double(here.worked) / Double(here.of) < 0.5, !attempt.notFor.contains(model) {
            store[p].attempts[a].notFor.append(model)
            changes.append("off for \(model) (worked \(here.worked) of \(here.of)): \(attempt.rule)")
        }
        let all = attempt.tally()
        if attempt.retired == nil, all.of >= 4, Double(all.worked) / Double(all.of) < 0.5 {
            store[p].attempts[a].retired = "didn't help: worked \(all.worked) of \(all.of) times"
            changes.append("retired (worked \(all.worked) of \(all.of)): \(attempt.rule)")
        }
        return changes
    }

    // MARK: - Learning

    /// What the commands' AI proposes after reading a run that went wrong and the whole memory.
    public struct Proposal: Equatable, Sendable {
        public var add: Bool
        public var rootCause: String
        public var rule: String
        public var rationale: String
        public var scope: Scope
        public var prediction: String
        /// Earlier attempts the evidence says to stop using, with why.
        public var retire: [(id: String, why: String)]

        public static func == (a: Proposal, b: Proposal) -> Bool {
            a.add == b.add && a.rootCause == b.rootCause && a.rule == b.rule && a.rationale == b.rationale
                && a.scope == b.scope && a.prediction == b.prediction && a.retire.map(\.id) == b.retire.map(\.id)
        }
    }

    /// Adds a proposal to the memory: under the root cause it cites (merged when it's the same text), or a new one.
    /// A current rule for that root cause is retired as revised (its history stays). Returns what changed, for the
    /// log.
    @discardableResult
    public func learn(_ proposal: Proposal, request: String, app: String?, model: String, at: Date = Date()) -> [String] {
        var changes: [String] = []
        lock.withLock {
            for (id, why) in proposal.retire {
                for p in store.indices {
                    if let a = store[p].attempts.firstIndex(where: { $0.id == id && $0.retired == nil }) {
                        store[p].attempts[a].retired = "retired after review: \(why)"
                        changes.append("retired: \(store[p].attempts[a].rule)")
                    }
                }
            }
            let rule = proposal.rule.trimmingCharacters(in: .whitespacesAndNewlines)
            let cause = proposal.rootCause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard proposal.add, !rule.isEmpty, !cause.isEmpty else { return }
            let key = Self.key(cause)
            let round = (store.flatMap(\.attempts).map(\.round).max() ?? 0) + 1
            let attempt = Attempt(id: "a\(round)-\(Int(at.timeIntervalSince1970) % 100_000)", rule: rule,
                                  rationale: proposal.rationale, scope: proposal.scope, prediction: proposal.prediction,
                                  model: model, app: app ?? "", created: at, round: round,
                                  trigger: String(request.prefix(160)), observed: [], retired: nil, notFor: [])
            if let p = store.firstIndex(where: { Self.key($0.rootCause) == key || $0.id == key }) {
                if let a = store[p].attempts.lastIndex(where: { $0.retired == nil }) {
                    if store[p].attempts[a].rule == rule { return }   // the same rule again: nothing new
                    store[p].attempts[a].retired = "revised after it didn't prevent: \(request.prefix(80))"
                }
                store[p].attempts.append(attempt)
                changes.append("revised \"\(store[p].rootCause)\": \(rule)")
            } else {
                store.append(Problem(id: key, rootCause: cause, attempts: [attempt]))
                changes.append("learned \"\(cause)\": \(rule)")
            }
            // Small: the problems not touched for longest go first.
            if store.count > Self.keepProblems {
                store.sort { ($0.attempts.last?.created ?? .distantPast) > ($1.attempts.last?.created ?? .distantPast) }
                store.removeLast(store.count - Self.keepProblems)
            }
        }
        save()
        return changes
    }

    public func forget(_ problem: String) {
        lock.withLock { store.removeAll { $0.id == problem } }
        save()
    }

    public func forgetAll() {
        lock.withLock { store = [] }
        save()
    }

    // MARK: - The memory as the AI reads it

    /// Every problem with its full history (the paper's finding: the whole record, not only the latest rule or the
    /// diagnosis), newest problems first, cut to `limit` characters.
    public func rendered(limit: Int = 12_000, now: Date = Date()) -> String {
        let problems = lock.withLock { store }
        guard !problems.isEmpty else { return "(empty: nothing learned yet)" }
        let days = { (date: Date) in max(0, Int(now.timeIntervalSince(date) / 86_400)) }
        var out = ""
        for problem in problems.reversed() {
            var block = "Root cause: \(problem.rootCause)\n"
            for (index, attempt) in problem.attempts.enumerated() {
                let tally = attempt.tally()
                let byModel = Dictionary(grouping: attempt.observed, by: \.model)
                    .map { model, seen in "\(model) \(seen.filter(\.worked).count)/\(seen.count)" }
                    .sorted().joined(separator: ", ")
                block += "  Attempt \(index + 1) [id \(attempt.id)], round \(attempt.round), \(days(attempt.created)) days ago, "
                    + "from a run with \(attempt.model) in \(attempt.app.isEmpty ? "?" : attempt.app) (\"\(attempt.trigger.prefix(80))\"):\n"
                block += "    Rule: \(attempt.rule)\n    Why: \(attempt.rationale)\n"
                block += "    Applies: apps \(attempt.scope.apps.joined(separator: ", ")); words \(attempt.scope.words.joined(separator: ", "))\n"
                block += "    Predicted: \(attempt.prediction)\n"
                block += "    Observed: " + (tally.of == 0 ? "not applied yet" : "worked \(tally.worked) of \(tally.of) (\(byModel))") + "\n"
                if !attempt.notFor.isEmpty { block += "    Off for: \(attempt.notFor.joined(separator: ", "))\n" }
                block += "    Status: " + (attempt.retired ?? "in use") + "\n"
            }
            if out.count + block.count > limit { break }
            out += block
        }
        return out
    }

    // MARK: - Runs

    /// A command as Murmur saw it, for deciding whether it went wrong and for the AI to read.
    public struct Run: Sendable {
        public var request: String
        public var app: String?
        public var window: String?
        public var model: String
        public var steps: [(tool: String, text: String, worked: Bool)]
        /// Times Murmur sent the model back before finishing, and why ("finished without changing the screen").
        public var sentBack: [String]
        public var stopped: Bool
        public var answer: String?
        /// What you said next, when it corrected this command ("no, I meant the other file").
        public var correction: String?
        public var lessons: [Lesson]

        public init(request: String, app: String?, window: String?, model: String,
                    steps: [(tool: String, text: String, worked: Bool)], sentBack: [String], stopped: Bool,
                    answer: String?, correction: String? = nil, lessons: [Lesson] = []) {
            self.request = request
            self.app = app
            self.window = window
            self.model = model
            self.steps = steps
            self.sentBack = sentBack
            self.stopped = stopped
            self.answer = answer
            self.correction = correction
            self.lessons = lessons
        }

        /// Whether it went wrong: corrected, stopped, sent back, or more than one failed step (one failed step that
        /// was then worked around is normal).
        public var wentWrong: Bool {
            correction != nil || stopped || !sentBack.isEmpty || steps.filter { !$0.worked }.count >= 2
        }

        /// The run as the AI reads it.
        public var report: String {
            var text = "Request: \"\(request)\"\nIn: \(app ?? "?")" + (window.map { " — \($0.prefix(80))" } ?? "")
                + "\nModel: \(model)\n"
            if !lessons.isEmpty { text += "Rules it was given: " + lessons.map { "[\($0.attempt)] \($0.rule)" }.joined(separator: " | ") + "\n" }
            text += "Steps:\n" + (steps.isEmpty ? "  (none)\n"
                : steps.suffix(30).map { "  \($0.worked ? "ok" : "FAILED") \($0.tool): \($0.text.prefix(160))" }.joined(separator: "\n") + "\n")
            if !sentBack.isEmpty { text += "Sent back before finishing: " + sentBack.joined(separator: "; ") + "\n" }
            if stopped { text += "The task was stopped before it finished.\n" }
            if let answer { text += "Answer shown: \(answer.prefix(300))\n" }
            if let correction { text += "The user's next words, correcting it: \"\(correction)\"\n" }
            return text
        }
    }

    /// Whether what you said right after a command corrects it: "no, I meant…", "that's wrong", "try again", "you
    /// didn't send it".
    public static func isCorrection(_ said: String) -> Bool {
        let lower = said.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(no\b|nope\b|not that|not this|wrong|that'?s (not|wrong)|that is (not|wrong)|you (didn'?t|did not|missed|forgot)|i (said|meant|asked)|try again|do it again|that didn'?t work|it didn'?t|it did not|still (not|didn'?t|wrong)|undo)"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    static let reflectSystem = """
        You improve Murmur, a Mac assistant that does what its user asks by calling tools (clicking, typing, opening \
        apps and pages, sending messages, reading the screen). A command just went wrong. You get the run, and \
        Murmur's self-improvement memory: every earlier problem, each rule tried for it, why, what it was predicted \
        to fix, and what actually happened since, by model. Use that evidence: a rule that was applied in this run \
        and failed anyway, or that worked for one model and not another, should be revised, not repeated.
        1. Diagnose the root cause: what in Murmur's approach went wrong (not the user's fault, not a one-off \
        outage). If it is one of the memory's root causes, cite it with exactly the same words; otherwise name a \
        new one in a short reusable phrase (like "finishes before entering the answer").
        2. Propose one rule for Murmur to follow from now on: one or two imperative sentences, specific and \
        checkable, general enough to help other requests of this kind, with no private details (names, messages, \
        numbers from this run).
        3. Say when it applies: app names, and/or two to five words that requests of this kind contain.
        4. Predict, before it's tried, which future requests it will fix and what will go differently.
        5. If the evidence shows an earlier rule hurting, list it in "retire" with why.
        If no rule could have prevented this (no network, a missing permission, the user changed their mind), \
        reply with "action": "none".
        Reply with JSON only:
        {"action": "add" or "none", "root_cause": "...", "rule": "...", "rationale": "...", \
        "scope": {"apps": ["..."], "words": ["..."]}, "prediction": "...", "retire": [{"id": "...", "why": "..."}]}
        """

    /// The request to the AI after a run went wrong: the run, and the whole memory.
    public func reflection(on run: Run) -> String {
        "The run that went wrong:\n\(run.report)\nMurmur's self-improvement memory:\n\(rendered())"
    }

    /// The AI's reply, read: the JSON object in it (code fences and stray text around it are fine).
    public static func proposal(from reply: String) -> Proposal? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let json = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any]
        else { return nil }
        let text = { (key: String) in (json[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let scope = json["scope"] as? [String: Any] ?? [:]
        let list = { (key: String) in ((scope[key] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty } }
        let retire = ((json["retire"] as? [Any]) ?? []).compactMap { item -> (id: String, why: String)? in
            guard let entry = item as? [String: Any], let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return (id, entry["why"] as? String ?? "")
        }
        return Proposal(add: text("action").lowercased() == "add", rootCause: text("root_cause"), rule: text("rule"),
                        rationale: text("rationale"), scope: Scope(apps: list("apps"), words: list("words")),
                        prediction: text("prediction"), retire: retire)
    }

    // MARK: - Small things

    static func key(_ cause: String) -> String {
        cause.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private func save() {
        guard let file else { return }
        let snapshot = lock.withLock { store }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.memory.encode(snapshot) { try? data.write(to: file, options: .atomic) }
    }
}

private extension JSONEncoder {
    static var memory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var memory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
