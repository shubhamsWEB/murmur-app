import Foundation

/// Adds Murmur's memory to the AI apps on this Mac (Claude Desktop, Claude Code, Cursor, Codex, VS Code, Windsurf,
/// Gemini CLI, LM Studio, Cline), so they can ask it what the user did, who someone is and what was promised, and
/// installs a skill that tells them how. At every launch while "Share memory with AI apps" is on (it is unless the
/// user turns it off): an app installed since gets it, and an entry pointing at an older copy of Murmur is updated.
/// Turned off, every entry and skill Murmur added goes, and nothing else in those files changes.
///
/// - Only an app that's on this Mac (its settings folder exists) is touched.
/// - Only Murmur's own entry ("murmur", running murmur-memory) is written or removed; one the user made by that name
///   for something else is left alone, and so is a file Murmur can't read as JSON (one with comments).
/// - Each file is copied once, before Murmur first changes it (`<file>.murmur-backup`).
/// - Only an installed Murmur registers (in Applications), never a build being worked on.
/// - An app that's open picks it up the next time it starts.
public enum MCPRegistration {
    public static let serverName = "murmur"
    static let defaultsKey = "memory.shareWithAIApps"

    /// Whether the user wants it (on unless they turned it off).
    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    public enum Format: Sendable, Equatable {
        /// A JSON file, the entry under this key ("mcpServers"), with `type: stdio` when the app wants it.
        case json(key: String, typed: Bool)
        /// Codex's config.toml: `[mcp_servers.murmur]`.
        case toml
    }

    public struct Client: Sendable, Equatable {
        public let name: String
        /// The settings folder that says the app is on this Mac.
        public let folder: String
        /// Its MCP settings file.
        public let file: String
        public let format: Format
    }

    /// The apps Murmur knows how to add itself to, under `home`.
    public static func clients(home: String = NSHomeDirectory()) -> [Client] {
        let support = home + "/Library/Application Support"
        return [
            Client(name: "Claude Desktop", folder: support + "/Claude", file: support + "/Claude/claude_desktop_config.json",
                   format: .json(key: "mcpServers", typed: false)),
            Client(name: "Claude Code", folder: home + "/.claude", file: home + "/.claude.json", format: .json(key: "mcpServers", typed: true)),
            Client(name: "Cursor", folder: home + "/.cursor", file: home + "/.cursor/mcp.json", format: .json(key: "mcpServers", typed: false)),
            Client(name: "Codex", folder: home + "/.codex", file: home + "/.codex/config.toml", format: .toml),
            Client(name: "VS Code", folder: support + "/Code/User", file: support + "/Code/User/mcp.json", format: .json(key: "servers", typed: true)),
            Client(name: "Windsurf", folder: home + "/.codeium/windsurf", file: home + "/.codeium/windsurf/mcp_config.json",
                   format: .json(key: "mcpServers", typed: false)),
            Client(name: "Gemini CLI", folder: home + "/.gemini", file: home + "/.gemini/settings.json", format: .json(key: "mcpServers", typed: false)),
            Client(name: "LM Studio", folder: home + "/.lmstudio", file: home + "/.lmstudio/mcp.json", format: .json(key: "mcpServers", typed: false)),
            Client(name: "Cline", folder: support + "/Code/User/globalStorage/saoudrizwan.claude-dev",
                   file: support + "/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
                   format: .json(key: "mcpServers", typed: false)),
        ]
    }

    /// Where skills go, for the assistants that read them.
    public static func skillFolders(home: String = NSHomeDirectory()) -> [(app: String, folder: String)] {
        [("Claude Code", home + "/.claude"), ("Codex", home + "/.codex"), ("agents", home + "/.agents")]
    }

    // MARK: Editing settings files (no I/O)

    /// Whether an entry is Murmur's own (it runs murmur-memory).
    static func isOurs(_ entry: Any?) -> Bool {
        guard let entry = entry as? [String: Any] else { return false }
        return (entry["command"] as? String ?? "").hasSuffix("/murmur-memory")
    }

    /// A JSON settings file with Murmur's entry in it: nil when nothing needs to change, or the file can't be read as
    /// JSON, or the name is taken by someone else's entry.
    public static func addingJSON(to text: String?, key: String, typed: Bool, command: String) -> String? {
        var root: [String: Any] = [:]
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
            root = object
        }
        var servers = root[key] as? [String: Any] ?? [:]
        if root[key] != nil, root[key] as? [String: Any] == nil { return nil }
        if let existing = servers[serverName], !isOurs(existing) { return nil }
        var entry: [String: Any] = ["command": command, "args": ["mcp"]]
        if typed { entry["type"] = "stdio" }
        if let existing = servers[serverName] as? [String: Any], NSDictionary(dictionary: existing).isEqual(to: entry) { return nil }
        servers[serverName] = entry
        root[key] = servers
        return serialize(root)
    }

    /// The file without Murmur's entry: nil when it has none (or can't be read).
    public static func removingJSON(from text: String?, key: String) -> String? {
        guard let text, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              var servers = object[key] as? [String: Any], isOurs(servers[serverName]) else { return nil }
        servers[serverName] = nil
        var root = object
        root[key] = servers
        return serialize(root)
    }

    static func serialize(_ root: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Codex's config.toml with `[mcp_servers.murmur]` in it (replacing Murmur's own block, keeping everything else);
    /// nil when nothing needs to change or the name is someone else's.
    public static func addingTOML(to text: String?, command: String) -> String? {
        let block = "[mcp_servers.\(serverName)]\ncommand = \(tomlString(command))\nargs = [\"mcp\"]\n"
        let existing = text ?? ""
        if let range = tomlBlock(in: existing) {
            let current = String(existing[range])
            guard current.contains("murmur-memory") else { return nil }
            guard current.trimmingCharacters(in: .whitespacesAndNewlines) != block.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            var out = existing
            out.replaceSubrange(range, with: block)
            return out
        }
        let separator = existing.isEmpty || existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
        return existing + separator + block
    }

    /// The file without Murmur's block: nil when it has none.
    public static func removingTOML(from text: String?) -> String? {
        guard let text, let range = tomlBlock(in: text), text[range].contains("murmur-memory") else { return nil }
        var out = text
        out.removeSubrange(range)
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out
    }

    /// Where `[mcp_servers.murmur]` starts, up to the next table or the end.
    static func tomlBlock(in text: String) -> Range<String.Index>? {
        let header = "[mcp_servers.\(serverName)]"
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { return nil }
        var end = start + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        // Blank lines before the next table stay with it.
        var last = end
        while last > start + 1, lines[last - 1].trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
        lines = Array(lines)
        let lower = text.index(text.startIndex, offsetBy: lines[..<start].reduce(0) { $0 + $1.count + 1 })
        let upperOffset = lines[..<last].reduce(0) { $0 + $1.count + 1 }
        let upper = text.index(text.startIndex, offsetBy: min(upperOffset, text.count))
        return lower..<upper
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: The skill

    /// The skill Murmur installs: what its memory is, which tool to use when, and the local API for an assistant
    /// that runs commands.
    public static let skill = """
        ---
        name: murmur-memory
        description: The user's personal memory from Murmur (what they did, saw, wrote and promised on this Mac; the people and projects in their life). Use it before asking the user who someone is, what they're working on, what they decided or what they owe, and to recall what they did on a day.
        ---

        # Murmur memory

        \(MemoryServer.instructions)

        ## Without MCP tools

        While Murmur's screen memory is on, the same tools answer over HTTP on this Mac. Read the port and the token
        from Murmur's folder, then call a tool by its name:

        ```sh
        DIR="$HOME/Library/Application Support/Murmur"
        PORT=$(cat "$DIR/memory-api-port"); TOKEN=$(cat "$DIR/memory-api-token")
        curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/search_memory?query=quarterly+report"
        curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/open_records?ids=snapshot:744"
        curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/tools"
        ```

        If the port file isn't there, screen memory is off: say so, and don't guess what memory would have said.
        """

    // MARK: Doing it

    /// What was done: the apps that have Murmur now, and what was left alone and why.
    public struct Outcome: Sendable, Equatable {
        public var added: [String] = []
        public var already: [String] = []
        public var skipped: [String] = []
        public var removed: [String] = []
    }

    static let markerFile = BrainStore.defaultURL.deletingLastPathComponent().appendingPathComponent("mcp-registered.json")

    /// The memory helper inside this copy of Murmur, when it's an installed one.
    public static func installedHelper(bundle: URL = Bundle.main.bundleURL) -> String? {
        let path = bundle.standardizedFileURL.path
        let home = NSHomeDirectory()
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") else { return nil }
        let helper = bundle.appendingPathComponent("Contents/Helpers/murmur-memory").path
        return FileManager.default.isExecutableFile(atPath: helper) ? helper : nil
    }

    /// Adds Murmur to every AI app found (when `enabled`), or takes it out of every one it was added to.
    @discardableResult
    public static func sync(enabled: Bool = MCPRegistration.enabled, helper: String? = installedHelper(),
                            home: String = NSHomeDirectory()) -> Outcome {
        var outcome = Outcome()
        let manager = FileManager.default
        var marked = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: markerFile))) as? [String] ?? [])
        if enabled, let helper {
            for client in clients(home: home) {
                guard manager.fileExists(atPath: client.folder) else { continue }
                let text = try? String(contentsOfFile: client.file, encoding: .utf8)
                let changed: String?
                switch client.format {
                case let .json(key, typed): changed = addingJSON(to: text, key: key, typed: typed, command: helper)
                case .toml: changed = addingTOML(to: text, command: helper)
                }
                guard let changed else {
                    let has = text.map { $0.contains(helper) } ?? false
                    if has { outcome.already.append(client.name); marked.insert(client.file) }
                    else { outcome.skipped.append(client.name) }
                    continue
                }
                if let text, !manager.fileExists(atPath: client.file + ".murmur-backup") {
                    try? text.write(toFile: client.file + ".murmur-backup", atomically: true, encoding: .utf8)
                }
                try? manager.createDirectory(atPath: (client.file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if (try? changed.write(toFile: client.file, atomically: true, encoding: .utf8)) != nil {
                    outcome.added.append(client.name)
                    marked.insert(client.file)
                } else {
                    outcome.skipped.append(client.name)
                }
            }
            for (_, folder) in skillFolders(home: home) where manager.fileExists(atPath: folder) {
                let skill = folder + "/skills/murmur-memory/SKILL.md"
                if (try? String(contentsOfFile: skill, encoding: .utf8)) != Self.skill {
                    try? manager.createDirectory(atPath: (skill as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try? Self.skill.write(toFile: skill, atomically: true, encoding: .utf8)
                }
                marked.insert(skill)
            }
        } else if !enabled {
            for client in clients(home: home) where marked.contains(client.file) {
                let text = try? String(contentsOfFile: client.file, encoding: .utf8)
                let changed: String?
                switch client.format {
                case let .json(key, _): changed = removingJSON(from: text, key: key)
                case .toml: changed = removingTOML(from: text)
                }
                if let changed, (try? changed.write(toFile: client.file, atomically: true, encoding: .utf8)) != nil {
                    outcome.removed.append(client.name)
                }
                marked.remove(client.file)
            }
            for path in marked where path.hasSuffix("/murmur-memory/SKILL.md") {
                try? manager.removeItem(atPath: (path as NSString).deletingLastPathComponent)
                marked.remove(path)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: Array(marked).sorted()) {
            try? manager.createDirectory(at: markerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: markerFile)
        }
        return outcome
    }

    /// The AI apps that have Murmur's memory now.
    public static func registered(home: String = NSHomeDirectory()) -> [String] {
        let marked = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: markerFile))) as? [String] ?? [])
        return clients(home: home).filter { marked.contains($0.file) }.map(\.name)
    }
}
