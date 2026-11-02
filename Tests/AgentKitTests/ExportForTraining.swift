import Foundation
import Testing
@testable import AgentKit

/// What Murmur sends its local model, written out for murmur-models: a model trained for Murmur has to see exactly
/// these rules and tools, in this form. Does nothing unless MURMUR_EXPORT_DIR is set:
///
///     MURMUR_EXPORT_DIR=~/IdeaProjects/murmur-models/data/schema swift test --filter ExportForTraining
///
/// Writes tools.json (every tool, with its set), system_prompts.json (the rules for every combination of tool sets),
/// cleanup_prompts.json (dictation cleanup's instructions for each kind of app and style) and meta.json. With an
/// utterances.jsonl in that folder ({"utterance", "front_is_browser", "has_selection"} per line), also
/// utterances.out.jsonl: for each, the tool sets the local model gets, the quick command that answers it without a
/// model (if one does), and the skills text added to the rules. Skills are Murmur's built-in ones at their default
/// settings, as on a new Mac (not the skills or settings of the Mac it runs on).
struct ExportForTraining {
    @MainActor @Test func export() throws {
        guard let path = ProcessInfo.processInfo.environment["MURMUR_EXPORT_DIR"], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let tools = CommandAgent.tools(helpers: [])
        try write(tools.map { tool -> [String: Any] in
            ["name": tool.name, "description": tool.description, "parameters": tool.parameters,
             "group": ToolGroup.of(tool.name)?.rawValue ?? (ToolGroup.core.contains(tool.name) ? "core" : "other")]
        }, to: folder.appendingPathComponent("tools.json"))

        let all = ToolGroup.allCases
        var prompts: [String: String] = [:]
        var short: [String: String] = [:]
        for mask in 0..<(1 << all.count) {
            let groups = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            prompts[Self.key(groups)] = CommandAgent.systemPrompt(helpers: [], groups: groups)
            short[Self.key(groups)] = CommandAgent.compactPrompt(groups: groups)
        }
        try write(prompts, to: folder.appendingPathComponent("system_prompts.json"))
        // Murmur's own model from v2 on: the short instructions, and the first message with the context in it.
        try write(short, to: folder.appendingPathComponent("compact_prompts.json"))

        var cleanup: [String: String] = [:]
        for category in DictationCleanup.Category.allCases {
            for style in category.styles {
                cleanup["\(category.rawValue)/\(style.rawValue)"] = DictationCleanup.system(style: style, category: category)
            }
        }
        try write(cleanup, to: folder.appendingPathComponent("cleanup_prompts.json"))

        try write(["groups": all.map(\.rawValue),
                   "group_purposes": Dictionary(uniqueKeysWithValues: all.map { ($0.rawValue, $0.purpose) }),
                   "core_tools": ToolGroup.core.sorted(),
                   "tool_count": tools.count,
                   "default_local_model": CommandAgent.defaultRouterModel,
                   "compact_request": CommandAgent.compactRequest("{utterance}", context: "{context}"),
                   "context_window": OllamaClient.contextWindow,
                   "exported_at": ISO8601DateFormatter().string(from: Date())],
                  to: folder.appendingPathComponent("meta.json"))

        let input = folder.appendingPathComponent("utterances.jsonl")
        guard let text = try? String(contentsOf: input, encoding: .utf8) else { return }
        let builtIn = SkillFiles.load(from: Self.repository.appendingPathComponent("Resources/Skills"), builtIn: true)
            .sorted { $0.name < $1.name }
        var lines: [String] = []
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let item = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let utterance = item["utterance"] as? String else { continue }
            let cleaned = QuickCommands.clean(utterance)
            let skills = Self.skillsPrompt(utterance, builtIn)
            let groups = ToolGroup.select(cleaned, frontIsBrowser: item["front_is_browser"] as? Bool ?? false,
                                          hasSelection: item["has_selection"] as? Bool ?? false, codingSession: false,
                                          skillsListed: !skills.text.isEmpty, mentionsMemory: false)
            var out: [String: Any] = ["utterance": utterance, "cleaned": cleaned, "groups": groups.sorted().map(\.rawValue),
                                      "points_at_screen": CommandAgent.pointsAtScreen(utterance),
                                      "skills": skills.text, "skills_in_full": skills.inFull]
            // What CommandAgent runs without a model (its quick path), one action per part of the request.
            if let quick = QuickCommands.parseAll(utterance) {
                out["quick"] = quick.map { ["tool": $0.tool, "arguments": $0.arguments] }
            }
            let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("utterances.out.jsonl"),
                                                         atomically: true, encoding: .utf8)
    }

    /// The murmur-app folder this file is in (Tests/AgentKitTests/…).
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// SkillLibrary.prompt(for:) for these skills at their default settings, with nothing extra installed.
    @MainActor static func skillsPrompt(_ utterance: String, _ skills: [Skill]) -> (text: String, inFull: [String]) {
        let library = SkillLibrary.shared
        let (full, listed, missing) = SkillFiles.choose(skills, for: utterance, mode: { $0.defaultMode },
                                                         available: { $0.requires == nil })
        guard !full.isEmpty || !listed.isEmpty || !missing.isEmpty else { return ("", []) }
        var lines = ["", "", "# Skills",
                     "Skills are the user's standing instructions for how to work. Follow each skill shown in full "
                     + "below on every step. Where a skill says more than the rules above, the skill wins, except "
                     + "that sending, paying, deleting and the like are always asked about first. Where a skill says "
                     + "to run a shell command, use run_command; its other files are read with read_skill_file."]
        for (skill, why) in full {
            lines.append("")
            lines.append(library.heading(skill, why))
            lines.append(library.instructions(skill))
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

    /// "core" for no extra sets, else the sets' names in Murmur's order joined with "+": "apps+browser".
    static func key(_ groups: Set<ToolGroup>) -> String {
        groups.isEmpty ? "core" : groups.sorted().map(\.rawValue).joined(separator: "+")
    }

    private func write(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
