import AppKit

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

    /// Start Claude Code / Codex without Murmur's "Go ahead?" dialog: builds open in Terminal at once, and helper
    /// questions are sent straight away. (Inside the session the agent still asks before running commands.)
    public static var autoApprove: Bool {
        get { UserDefaults.standard.bool(forKey: "assistants.autoApprove") }
        set { UserDefaults.standard.set(newValue, forKey: "assistants.autoApprove") }
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

    // MARK: Building

    /// Where new projects go: the first of ~/Developer, ~/Projects, ~/IdeaProjects, ~/code that exists, else
    /// ~/Murmur Projects.
    public static func projectsFolder() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in ["Developer", "Projects", "IdeaProjects", "code", "Code"] {
            var isFolder: ObjCBool = false
            let url = home.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue { return url }
        }
        return home.appendingPathComponent("Murmur Projects")
    }

    /// A new, unused folder for this task: "create a react app with a hello world page" → react-app-hello-world.
    public static func newProjectFolder(for task: String, name: String? = nil) -> URL {
        let filler: Set<String> = ["a", "an", "the", "with", "and", "for", "me", "my", "create", "build", "make",
                                   "new", "simple", "basic", "small", "scaffold", "set", "up", "setup", "generate",
                                   "write", "start", "please", "page", "of", "to", "in", "that", "which", "using"]
        let source = (name?.isEmpty == false ? name! : task).lowercased()
        let words = source.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let kept = (name?.isEmpty == false ? words : words.filter { !filler.contains($0) }).prefix(5)
        let slug = kept.isEmpty ? "murmur-project" : kept.joined(separator: "-")
        let base = projectsFolder()
        var folder = base.appendingPathComponent(slug)
        var number = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = base.appendingPathComponent("\(slug)-\(number)")
            number += 1
        }
        return folder
    }

    /// Starts an interactive session in Terminal, in `folder` (created, with git), with the spoken request as its
    /// first message. You watch it work and answer its questions there; file edits go ahead on their own, commands
    /// ask first (Claude Code's acceptEdits, Codex's --full-auto).
    @MainActor
    public func startSession(_ task: String, in folder: URL) async -> String {
        guard let executable = await locate() else {
            return "\(display) isn't installed (no `\(command)` on your PATH)."
        }
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return "Couldn't make \(folder.path): \(error.localizedDescription)"
        }
        let prompt = """
        You were started by Murmur, the user's voice assistant, from this spoken request:

        "\(task)"

        Build it in the current folder (\(folder.path)); it's new and empty. Choose sensible defaults instead of asking \
        (for a React app: Vite + React + TypeScript). Set the project up, write the code, install what it needs, \
        and check that it builds and runs. Finish by telling the user how to start it.
        """
        let stamp = Int(Date().timeIntervalSince1970)
        let support = files.temporaryDirectory.appendingPathComponent("murmur-sessions", isDirectory: true)
        try? files.createDirectory(at: support, withIntermediateDirectories: true)
        let promptFile = support.appendingPathComponent("task-\(stamp).md")
        let launcher = support.appendingPathComponent("\(folder.lastPathComponent)-\(stamp).command")
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let start: String
        switch self {
        case .claude:
            start = "exec \(quoted(executable.path)) --permission-mode acceptEdits \"$(cat \(quoted(promptFile.path)))\""
        case .codex:
            start = "exec \(quoted(executable.path)) --full-auto \"$(cat \(quoted(promptFile.path)))\""
        }
        let script = """
        #!/bin/zsh -l
        # Started by Murmur: \(display) building "\(task.replacingOccurrences(of: "\n", with: " ").prefix(80))"
        cd \(quoted(folder.path)) || exit 1
        git init -q 2>/dev/null
        printf '\\e]0;%s\\a' \(quoted("Murmur · \(display) · \(folder.lastPathComponent)"))
        \(start)
        """
        do {
            try prompt.write(to: promptFile, atomically: true, encoding: .utf8)
            try script.write(to: launcher, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        } catch {
            return "Couldn't prepare the session: \(error.localizedDescription)"
        }
        // A .command file opens in Terminal and runs there: no Automation permission needed.
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([launcher], withApplicationAt: terminal, configuration: configuration)
        } catch {
            return "Couldn't open Terminal: \(error.localizedDescription)"
        }
        return "Started \(display) in Terminal, building in \(folder.path)."
    }
}
