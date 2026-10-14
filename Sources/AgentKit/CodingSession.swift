import AppKit

/// The Claude Code or Codex session Murmur started in Terminal, so what you say next ("add a login page", "make it
/// dark", "run it") goes to that same session instead of starting a new project. Murmur types your request into
/// the session's Terminal tab and presses Return (it finds the tab by its terminal device); if you closed the tab,
/// it opens the session again in that folder, continuing the conversation.
public struct CodingSession: Codable, Sendable {
    public let helper: String           // AssistantCLI raw value
    public let folder: String
    public let task: String
    /// Where the launcher wrote its terminal device (/dev/ttys004), to find the Terminal tab.
    public let ttyFile: String
    public let started: Date

    public var assistant: AssistantCLI { AssistantCLI(rawValue: helper) ?? .claude }
    public var place: String {
        folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private static let key = "codingSession.current"

    /// The latest session (kept across restarts), if it was started in the last day.
    public static var current: CodingSession? {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let session = try? JSONDecoder().decode(CodingSession.self, from: data),
                  Date().timeIntervalSince(session.started) < 24 * 3600,
                  FileManager.default.fileExists(atPath: session.folder) else { return nil }
            return session
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// One line for the model: what's being built, where, by whom.
    public var summary: String {
        "\(assistant.display) is working on “\(task.prefix(120))” in \(place) (started "
            + RelativeDateTimeFormatter().localizedString(for: started, relativeTo: Date()) + ")."
    }

    /// A new project ("create a new React app", "build another website") rather than a change to this one.
    public static func isNewProject(_ request: String) -> Bool {
        let text = request.lowercased()
        if text.range(of: #"\b(new|another|separate|different|second|fresh) (app|project|website|site|repo|api|tool|bot|game|script|extension)\b"#,
                      options: .regularExpression) != nil { return true }
        // "add a login page to the app", "build a settings screen for it": the project in hand.
        if text.range(of: #"\b(it|its|the app|my app|this app|the project|this project|the site|the website|the code|existing)\b|\b(to|in|for|into|on) (the|my|this|our) \w+"#,
                      options: .regularExpression) != nil { return false }
        return text.range(of: #"^(?:please )?(?:create|build|make|scaffold|set up|setup|generate|bootstrap|spin up|start|code|develop) (?:me |us )?(?:a|an)\b"#,
                          options: .regularExpression) != nil
    }

    /// Sends a follow-up to the session: typed into its Terminal tab while it's still running there, else the session
    /// is opened again in its folder, continuing where it left off.
    @MainActor
    public func send(_ message: String) async -> String {
        let line = message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return "Nothing to send." }
        let tty = (try? String(contentsOfFile: ttyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tty.hasPrefix("/dev/") {
            // Terminal's `do script … in tab` types the text into that tab and presses Return.
            let script = """
            on run argv
              set wanted to item 1 of argv
              set message to item 2 of argv
              tell application "Terminal"
                repeat with w in windows
                  repeat with t in tabs of w
                    if tty of t is wanted then
                      if busy of t is false then return "ENDED"
                      do script message in t
                      delay 0.4
                      do script "" in t
                      set selected of t to true
                      set index of w to 1
                      activate
                      return "SENT"
                    end if
                  end repeat
                end repeat
              end tell
              return "GONE"
            end run
            """
            let output = await MacActions.run("/usr/bin/osascript", ["-e", script, tty, line], timeout: 20)
            if output.contains("SENT") { return "Sent to \(assistant.display) in Terminal: “\(line.prefix(80))”." }
            if output.contains("-1743") || output.localizedCaseInsensitiveContains("not authorized") {
                return "macOS hasn't allowed Murmur to control Terminal (System Settings → Privacy & Security → "
                    + "Automation → Murmur → Terminal). Opening the session again instead. "
                    + (await assistant.resumeSession(line, in: self))
            }
        }
        return await assistant.resumeSession(line, in: self)
    }
}
