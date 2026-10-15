import AppKit
import Combine
import Foundation

/// A skill: instructions for the agent, in the Agent Skills format Claude uses. A folder with a SKILL.md (a short
/// header with its name and description, then the instructions) and any files it points to (references, examples,
/// scripts). "Always" skills go into every command's instructions; "When it fits" ones are listed by description,
/// and the agent loads one (use_skill) when the task matches, or Murmur loads it when your words hit its triggers.
///
/// Murmur reads a few extra header lines, all optional: `always: true` (on for every command unless you change it),
/// `triggers: [word, phrase]` (load it whenever the request says one), `requires: tool` (a command-line tool it
/// needs; off until that's installed), `install: link` (where to get that tool) and `source: link`.
public struct Skill: Identifiable, Sendable, Equatable {
    public enum Mode: String, CaseIterable, Sendable {
        case off, auto, always
        public var display: String {
            switch self {
            case .off: "Off"
            case .auto: "When it fits"
            case .always: "Always"
            }
        }
    }

    public let name: String
    public let description: String
    /// The instructions: SKILL.md after its header.
    public let body: String
    public let folder: URL
    /// Comes with Murmur (can't be removed, only turned off; a skill of yours with the same name replaces it).
    public let builtIn: Bool
    public let triggers: [String]
    public let requires: String?
    public let install: String?
    public let source: String?
    public let defaultMode: Mode
    /// Its other files, relative to its folder.
    public let files: [String]
    public var id: String { name }
}

@MainActor
public final class SkillLibrary: ObservableObject {
    public static let shared = SkillLibrary()

    @Published public private(set) var skills: [Skill] = []
    /// Bumped when a mode changes, so views redraw.
    @Published public private(set) var revision = 0

    private init() { reload() }

    /// ~/Library/Application Support/Murmur/Skills: your skills, one folder each.
    public nonisolated static var userFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Murmur/Skills", isDirectory: true)
    }

    /// The ones that come with Murmur, in the app's Resources/Skills.
    nonisolated static var builtInFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Skills", isDirectory: true)
    }

    public func reload() {
        var byName: [String: Skill] = [:]
        if let folder = Self.builtInFolder {
            for skill in Self.load(from: folder, builtIn: true) { byName[skill.name] = skill }
        }
        for skill in Self.load(from: Self.userFolder, builtIn: false) { byName[skill.name] = skill }
        skills = byName.values.sorted {
            if $0.builtIn != $1.builtIn { return $0.builtIn }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        revision += 1
    }

    public func skill(named name: String) -> Skill? {
        let wanted = Self.slug(name)
        return skills.first { $0.name == wanted } ?? skills.first { Self.slug($0.name) == wanted }
    }

    // MARK: Modes

    public func mode(of skill: Skill) -> Skill.Mode {
        UserDefaults.standard.string(forKey: "skills.mode.\(skill.name)").flatMap(Skill.Mode.init(rawValue:))
            ?? skill.defaultMode
    }

    public func setMode(_ mode: Skill.Mode, for skill: Skill) {
        if mode == skill.defaultMode {
            UserDefaults.standard.removeObject(forKey: "skills.mode.\(skill.name)")
        } else {
            UserDefaults.standard.set(mode.rawValue, forKey: "skills.mode.\(skill.name)")
        }
        revision += 1
    }

    /// Where the tool a skill needs is, or nil when it isn't installed. Apps started from the Dock don't get your
    /// shell's PATH, so the usual places are looked at directly.
    public nonisolated static func toolPath(_ tool: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let places = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/bin", "/usr/bin", "/bin"]
        return places.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func isAvailable(_ skill: Skill) -> Bool {
        skill.requires.map { Self.toolPath($0) != nil } ?? true
    }

    /// Why a skill can't run right now ("needs cua-driver, which isn't installed").
    public func unavailableReason(_ skill: Skill) -> String {
        guard let tool = skill.requires, Self.toolPath(tool) == nil else { return "" }
        return "The \(skill.name) skill needs \(tool), which isn't installed on this Mac. Tell the user: they can "
            + "install it\(skill.install.map { " (\($0))" } ?? ""), then it turns on by itself. Until then, work "
            + "with Murmur's own tools."
    }

    // MARK: Into the agent's instructions

    /// The skills part of the instructions for one request: "Always" skills in full, "When it fits" ones whose
    /// triggers the request hits (or that it names) in full, the rest listed for use_skill.
    public func prompt(for utterance: String) -> (text: String, inFull: [String]) {
        let said = " " + utterance.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ",
                                                                     options: .regularExpression) + " "
        var full: [(Skill, String)] = []
        var listed: [Skill] = []
        var missing: [Skill] = []
        for skill in skills {
            let chosen = mode(of: skill)
            guard chosen != .off else { continue }
            guard isAvailable(skill) else { missing.append(skill); continue }
            if chosen == .always {
                full.append((skill, "always on"))
            } else if Self.mentions(said, skill) {
                full.append((skill, "loaded because the request matches it"))
            } else {
                listed.append(skill)
            }
        }
        guard !full.isEmpty || !listed.isEmpty || !missing.isEmpty else { return ("", []) }
        var lines = ["", "", "# Skills",
                     "Skills are the user's standing instructions for how to work. Follow each skill shown in full "
                     + "below on every step. Where a skill says more than the rules above, the skill wins, except "
                     + "that sending, paying, deleting and the like are always asked about first. Where a skill says "
                     + "to run a shell command, use run_command; its other files are read with read_skill_file."]
        for (skill, why) in full {
            lines.append("")
            lines.append(heading(skill, why))
            lines.append(instructions(skill))
        }
        if !listed.isEmpty {
            lines.append("")
            lines.append("Skills to load with use_skill before starting a task they fit (read each description):")
            lines += listed.map { "- \($0.name): \($0.description.prefix(400))" }
        }
        if !missing.isEmpty {
            lines.append("")
            lines.append("Skills that are on but can't run on this Mac yet (if the user asks for one, say why):")
            lines += missing.map { "- \($0.name): needs \($0.requires ?? "a tool"), which isn't installed." }
        }
        return (lines.joined(separator: "\n"), full.map(\.0.name))
    }

    /// "## Skill: cua-driver (always on). cua-driver is at …": the heading of a skill given in full.
    public func heading(_ skill: Skill, _ why: String) -> String {
        var line = "## Skill: \(skill.name) (\(why))"
        if let tool = skill.requires, let path = Self.toolPath(tool) {
            line += "\n`\(tool)` is installed at \(path): call it by that full path in run_command."
        }
        return line
    }

    /// A skill's instructions, with its other files named (cut if very long).
    public func instructions(_ skill: Skill) -> String {
        var text = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 12_000 {
            text = String(text.prefix(12_000)) + "\n… (cut: read_skill_file \(skill.name) SKILL.md for the rest)"
        }
        if !skill.files.isEmpty {
            text += "\nIts other files (read_skill_file): " + skill.files.prefix(30).joined(separator: ", ")
        }
        return text
    }

    private static func mentions(_ said: String, _ skill: Skill) -> Bool {
        let name = skill.name.replacingOccurrences(of: "-", with: " ").lowercased()
        if said.contains(" \(name) skill ") || said.contains(" skill \(name) ") { return true }
        return skill.triggers.contains { trigger in
            let words = trigger.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ",
                                                                  options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return !words.isEmpty && said.contains(" \(words) ")
        }
    }

    /// One of a skill's files, for read_skill_file. Only files inside its folder.
    public func read(_ name: String, file: String) -> String {
        guard let skill = skill(named: name) else { return "No skill called \"\(name)\"." }
        let wanted = file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "SKILL.md" : file
        let base = skill.folder.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(wanted).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else { return "That file isn't part of the \(skill.name) skill." }
        guard let data = try? Data(contentsOf: url), var text = String(data: data, encoding: .utf8) else {
            return "No file \(wanted) in the \(skill.name) skill. Its files: "
                + (["SKILL.md"] + skill.files).joined(separator: ", ")
        }
        if text.count > 20_000 { text = String(text.prefix(20_000)) + "\n… (cut)" }
        return "\(skill.name)/\(wanted) (folder: \(skill.folder.path)):\n\(text)"
    }

    // MARK: Adding and removing

    public func openFolder() {
        try? FileManager.default.createDirectory(at: Self.userFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.userFolder)
    }

    /// Removes one of your skills (to the Trash). Built-in ones can only be turned off.
    public func remove(_ skill: Skill) {
        guard !skill.builtIn else { return }
        try? FileManager.default.trashItem(at: skill.folder, resultingItemURL: nil)
        UserDefaults.standard.removeObject(forKey: "skills.mode.\(skill.name)")
        reload()
    }

    public enum ImportError: LocalizedError {
        case notALink, noSkillFile, tooBig, http(Int)
        public var errorDescription: String? {
            switch self {
            case .notALink: "That isn't a link to a skill. Paste a GitHub link to a skill's folder or its SKILL.md."
            case .noSkillFile: "There's no SKILL.md there."
            case .tooBig: "That skill is too big (over 50 files or 5 MB)."
            case .http(let code): "GitHub answered \(code). Check the link, or try again in a while."
            }
        }
    }

    /// Adds a skill from a link: a GitHub folder or SKILL.md (github.com/…/tree/… or …/blob/…/SKILL.md, or
    /// raw.githubusercontent.com), with every file in its folder, or any other link straight to a SKILL.md.
    /// It replaces one of yours with the same name.
    @discardableResult
    public func add(from link: String) async throws -> Skill {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(), url.scheme?.hasPrefix("http") == true
        else { throw ImportError.notALink }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var parts = url.path.split(separator: "/").map(String.init)
        if host == "github.com" || host == "www.github.com" || host == "raw.githubusercontent.com" {
            guard parts.count >= 2 else { throw ImportError.notALink }
            let owner = parts.removeFirst(), repo = parts.removeFirst()
            if host != "raw.githubusercontent.com", let kind = parts.first, kind == "blob" || kind == "tree" {
                parts.removeFirst()
            }
            if parts.last?.lowercased() == "skill.md" { parts.removeLast() }
            try await fetchGitHubFolder(owner: owner, repo: repo, rest: parts, into: staging)
        } else {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ImportError.http(http.statusCode) }
            try data.write(to: staging.appendingPathComponent("SKILL.md"))
        }
        let skillFile = staging.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { throw ImportError.noSkillFile }
        let header = Self.parse(text).fields
        var name = Self.slug(header["name"] ?? "")
        if name.isEmpty { name = Self.slug(parts.last ?? url.deletingPathExtension().lastPathComponent) }
        if name.isEmpty { name = "skill" }
        try trimmed.write(to: staging.appendingPathComponent(".murmur-source"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: Self.userFolder, withIntermediateDirectories: true)
        let destination = Self.userFolder.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        reload()
        guard let skill = skill(named: name) else { throw ImportError.noSkillFile }
        return skill
    }

    /// Downloads a folder of a GitHub repo through the contents API. The branch may hold slashes ("feature/x"), so
    /// each split of the path into branch and folder is tried until GitHub knows it; no branch means the default one.
    private func fetchGitHubFolder(owner: String, repo: String, rest: [String], into staging: URL) async throws {
        var tries: [(ref: String?, path: String)] = []
        if rest.isEmpty {
            tries = [(nil, "")]
        } else {
            for split in 1...rest.count {
                tries.append((rest[..<split].joined(separator: "/"), rest[split...].joined(separator: "/")))
            }
        }
        for attempt in tries {
            do {
                var budget = (files: 50, bytes: 5_000_000)
                try await download(owner: owner, repo: repo, ref: attempt.ref, path: attempt.path,
                                   into: staging, depth: 0, budget: &budget)
                if FileManager.default.fileExists(atPath: staging.appendingPathComponent("SKILL.md").path) { return }
            } catch ImportError.http(404) {
                // Not this split of branch and folder: try the next.
            } catch ImportError.noSkillFile {
            }
            for item in (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: item)
            }
        }
        throw ImportError.noSkillFile
    }

    private func download(owner: String, repo: String, ref: String?, path: String, into folder: URL, depth: Int,
                          budget: inout (files: Int, bytes: Int)) async throws {
        var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(path)")
        if let ref { components?.queryItems = [URLQueryItem(name: "ref", value: ref)] }
        guard let listURL = components?.url else { throw ImportError.notALink }
        var request = URLRequest(url: listURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ImportError.http(http.statusCode) }
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ImportError.noSkillFile   // a file, not a folder
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in entries {
            guard let name = entry["name"] as? String, !name.hasPrefix("."), !name.contains("/"),
                  let type = entry["type"] as? String else { continue }
            if type == "dir", depth < 3, let sub = entry["path"] as? String {
                try await download(owner: owner, repo: repo, ref: ref, path: sub,
                                   into: folder.appendingPathComponent(name, isDirectory: true), depth: depth + 1,
                                   budget: &budget)
            } else if type == "file", let link = entry["download_url"] as? String, let fileURL = URL(string: link) {
                budget.files -= 1
                budget.bytes -= (entry["size"] as? Int) ?? 0
                guard budget.files >= 0, budget.bytes >= 0 else { throw ImportError.tooBig }
                let (body, reply) = try await URLSession.shared.data(from: fileURL)
                if let http = reply as? HTTPURLResponse, http.statusCode != 200 { throw ImportError.http(http.statusCode) }
                try body.write(to: folder.appendingPathComponent(name))
            }
        }
    }

    // MARK: Reading skill folders

    nonisolated static func load(from root: URL, builtIn: Bool) -> [Skill] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return folders.compactMap { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let parsed = parse(text)
            let name = slug(parsed.fields["name"] ?? "").isEmpty ? slug(folder.lastPathComponent)
                : slug(parsed.fields["name"] ?? "")
            guard !name.isEmpty else { return nil }
            let always = ["true", "yes", "on"].contains((parsed.fields["always"] ?? "").lowercased())
            let triggers = parsed.lists["triggers"]
                ?? (parsed.fields["triggers"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let source = parsed.fields["source"]
                ?? (try? String(contentsOf: folder.appendingPathComponent(".murmur-source"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            return Skill(name: name,
                         description: parsed.fields["description"] ?? firstLine(parsed.body),
                         body: parsed.body,
                         folder: folder,
                         builtIn: builtIn,
                         triggers: triggers.filter { !$0.isEmpty },
                         requires: parsed.fields["requires"].flatMap { $0.isEmpty ? nil : $0 },
                         install: parsed.fields["install"],
                         source: source,
                         defaultMode: always ? .always : .auto,
                         files: otherFiles(in: folder))
        }
    }

    /// "Cua Driver!" → "cua-driver".
    nonisolated static func slug(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private nonisolated static func firstLine(_ body: String) -> String {
        body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
            .first { !$0.isEmpty } ?? ""
    }

    private nonisolated static func otherFiles(in folder: URL) -> [String] {
        let textTypes: Set<String> = ["md", "txt", "json", "yaml", "yml", "csv", "py", "sh", "js", "ts", "swift",
                                      "applescript", "scpt", "rb", "html", "xml"]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let base = folder.standardizedFileURL.path
        var files: [String] = []
        for case let url as URL in walker where textTypes.contains(url.pathExtension.lowercased()) {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if relative != "SKILL.md" { files.append(relative) }
            if files.count >= 50 { break }
        }
        return files.sorted()
    }

    /// The header between the `---` lines (simple YAML: `key: value`, quoted values, `>`/`|` blocks, lists as
    /// `[a, b]` or `- a` lines; `#` lines are comments) and the instructions after it.
    nonisolated static func parse(_ text: String) -> (fields: [String: String], lists: [String: [String]], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[start].trimmingCharacters(in: .whitespaces) == "---",
              let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], [:], text) }
        var fields: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var key: String?
        var block: (folded: Bool, lines: [String])?
        func finishBlock() {
            if let key, let block {
                fields[key] = block.lines.joined(separator: block.folded ? " " : "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            block = nil
        }
        for raw in lines[(start + 1)..<end] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indented = raw.first == " " || raw.first == "\t"
            if trimmed.hasPrefix("#") && !indented { continue }
            if indented || trimmed.isEmpty {
                if block != nil { block?.lines.append(trimmed); continue }
                if let key, trimmed.hasPrefix("- ") {
                    lists[key, default: []].append(unquote(String(trimmed.dropFirst(2))))
                }
                continue
            }
            if trimmed.hasPrefix("- "), let key {
                lists[key, default: []].append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            finishBlock()
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            key = name
            if [">", ">-", ">+", "|", "|-", "|+"].contains(value) {
                block = (value.hasPrefix(">"), [])
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                lists[name] = value.dropFirst().dropLast().split(separator: ",")
                    .map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
            } else if !value.isEmpty {
                fields[name] = unquote(value)
            }
        }
        finishBlock()
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fields, lists, body)
    }

    private nonisolated static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
        }
        return value
    }
}
