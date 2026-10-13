import Foundation

/// Claude Code and Codex, used as helpers Murmur directs. Murmur keeps the plan: it sends one focused sub-task, reads
/// the answer, and decides what to do with it (show it, paste it, act on it). Each CLI runs with your own login
/// (your Claude or ChatGPT subscription); Murmur never sees or stores credentials.
///
/// Both are off until you allow them in the menu, and every run asks you first.
public enum AssistantCLI: String, CaseIterable, Sendable {
    case claude
    case codex

    public var display: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var command: String { rawValue }

    private var allowKey: String { "allow.\(rawValue)" }

    public var isAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: allowKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: allowKey) }
    }

    /// Finds the CLI the way your terminal would (a login shell, so Homebrew, npm and nvm paths count).
    public func locate() async -> URL? {
        let output = await MacActions.run("/bin/zsh", ["-lc", "command -v \(command)"], timeout: 10)
        let path = output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Runs one task headless and returns the final answer text.
    public func run(_ task: String, timeout: TimeInterval = 300) async -> String {
        guard isAllowed else { return "\(display) isn't allowed. Turn it on under Assistants in Murmur's menu." }
        guard let executable = await locate() else {
            return "\(display) isn't installed (no `\(command)` on your PATH)."
        }
        // The login shell's PATH, so node-based CLIs find node.
        let path = await MacActions.run("/bin/zsh", ["-lc", "printf %s \"$PATH\""], timeout: 10)
        var environment = ProcessInfo.processInfo.environment
        if !path.isEmpty { environment["PATH"] = path }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let prompt = "You are helping Murmur, a voice assistant on this Mac. Answer the task directly and concisely; "
            + "your reply is shown to the user or pasted where they are typing.\n\nTask: \(task)"
        switch self {
        case .claude:
            // dontAsk: anything that would need your approval is refused, so the run never stalls on a prompt and
            // can't change files on its own. Answers, reading and research still work.
            return await MacActions.run(executable.path,
                                        ["-p", prompt, "--output-format", "text", "--permission-mode", "dontAsk"],
                                        timeout: timeout, environment: environment, directory: home)
        case .codex:
            let last = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-codex-last.txt")
            try? FileManager.default.removeItem(at: last)
            let printed = await MacActions.run(executable.path,
                                               ["exec", "--skip-git-repo-check", "--sandbox", "read-only",
                                                "--output-last-message", last.path, prompt],
                                               timeout: timeout, environment: environment, directory: home)
            let answer = (try? String(contentsOf: last, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: last)
            return (answer?.isEmpty == false ? answer! : printed)
        }
    }
}
