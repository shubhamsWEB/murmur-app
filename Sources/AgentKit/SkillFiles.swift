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

/// Reading skill folders and choosing the skills for a request: plain Foundation, so it's tested on its own (with the
/// skills that come with Murmur) and SkillLibrary keeps only what needs the app.
public enum SkillFiles {
    /// "summarise my emails" → said with spaces round every word, for matching triggers.
    static func said(_ utterance: String) -> String {
        " " + utterance.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression) + " "
    }

    /// The skills for one request: "Always" ones and "When it fits" ones whose triggers the request hits (or that
    /// it names) go in full, with why; the other "When it fits" ones are listed for use_skill; ones whose tool
    /// isn't installed are named as missing. Skills turned off are left out.
    public static func choose(_ skills: [Skill], for utterance: String, mode: (Skill) -> Skill.Mode,
                              available: (Skill) -> Bool)
        -> (full: [(Skill, String)], listed: [Skill], missing: [Skill]) {
        let spoken = said(utterance)
        var full: [(Skill, String)] = []
        var listed: [Skill] = []
        var missing: [Skill] = []
        for skill in skills {
            let chosen = mode(skill)
            guard chosen != .off else { continue }
            guard available(skill) else { missing.append(skill); continue }
            if chosen == .always {
                full.append((skill, "always on"))
            } else if mentions(spoken, skill) {
                full.append((skill, "loaded because the request matches it"))
            } else {
                listed.append(skill)
            }
        }
        return (full, listed, missing)
    }

    static func mentions(_ said: String, _ skill: Skill) -> Bool {
        let name = skill.name.replacingOccurrences(of: "-", with: " ").lowercased()
        if said.contains(" \(name) skill ") || said.contains(" skill \(name) ") { return true }
        return skill.triggers.contains { trigger in
            let words = trigger.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ",
                                                                  options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return !words.isEmpty && said.contains(" \(words) ")
        }
    }

    static func load(from root: URL, builtIn: Bool) -> [Skill] {
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
    static func slug(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func firstLine(_ body: String) -> String {
        body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func otherFiles(in folder: URL) -> [String] {
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
    static func parse(_ text: String) -> (fields: [String: String], lists: [String: [String]], body: String) {
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

    private static func unquote(_ value: String) -> String {
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
