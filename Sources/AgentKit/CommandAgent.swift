import AppKit

/// What the command agent needs from the app: asking you, showing answers, pasting, searching your files.
@MainActor
public struct CommandHost {
    /// Ask before an action that changes something. Returns true to go ahead.
    public var confirm: (_ title: String, _ detail: String) async -> Bool
    /// Show an answer to read (not pasted).
    public var showAnswer: (String) -> Void
    /// Paste text where you're typing.
    public var insert: (String) -> Void
    /// Open Murmur's file search with this query.
    public var searchFiles: (String) -> Void
    /// A short status line while it works ("Asking Claude Code…").
    public var progress: (String) -> Void
    /// Log lines.
    public var log: (String) -> Void

    public init(confirm: @escaping (String, String) async -> Bool, showAnswer: @escaping (String) -> Void,
                insert: @escaping (String) -> Void, searchFiles: @escaping (String) -> Void,
                progress: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.confirm = confirm
        self.showAnswer = showAnswer
        self.insert = insert
        self.searchFiles = searchFiles
        self.progress = progress
        self.log = log
    }
}

/// Turns a spoken command into actions: the quick patterns first, then a small local model (Ollama) that picks tools,
/// with Claude Code or Codex as helpers it can consult for harder steps. Murmur stays in charge of every step.
@MainActor
public final class CommandAgent {
    public static let routerModelKey = "routerModel"
    public static let defaultRouterModel = "qwen3:4b"

    public var routerModel: String {
        get { UserDefaults.standard.string(forKey: Self.routerModelKey) ?? Self.defaultRouterModel }
        set { UserDefaults.standard.set(newValue, forKey: Self.routerModelKey) }
    }

    private let host: CommandHost
    private let maxSteps = 6

    public init(host: CommandHost) {
        self.host = host
    }

    /// Runs one spoken command. `selection` is the text selected in the front app, if any.
    public func run(_ utterance: String, frontApp: String?, selection: String?) async {
        let started = Date()
        if let quick = QuickCommands.parse(utterance) {
            host.log("command: quick path → \(quick.tool) \(quick.arguments)")
            let arguments = quick.arguments.mapValues { JSONValue.string($0) }
            let outcome = await execute(quick.tool, arguments)
            host.log(String(format: "command: done in %.2f s: %@", Date().timeIntervalSince(started), outcome.result))
            if !outcome.shown { host.progress(outcome.result) }
            return
        }
        await route(utterance, frontApp: frontApp, selection: selection)
        host.log(String(format: "command: finished in %.2f s", Date().timeIntervalSince(started)))
    }

    // MARK: - Router loop

    private func route(_ utterance: String, frontApp: String?, selection: String?) async {
        let client = OllamaClient(model: routerModel)
        var context = "Front app: \(frontApp ?? "unknown")."
        if let selection, !selection.isEmpty {
            context += "\nSelected text:\n\"\"\"\n\(selection.prefix(4000))\n\"\"\""
        }
        let helpers = AssistantCLI.allCases.filter(\.isAllowed)
        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.systemPrompt(helpers: helpers) + "\n\n" + context],
            ["role": "user", "content": utterance],
        ]
        let tools = Self.tools(helpers: helpers)
        host.progress("Thinking…")
        for step in 0..<maxSteps {
            let reply: OllamaClient.Reply
            do {
                reply = try await client.chat(messages: messages, tools: tools)
            } catch {
                host.log("command: router failed: \(error.localizedDescription)")
                host.showAnswer(error.localizedDescription)
                return
            }
            if reply.toolCalls.isEmpty {
                // A small model sometimes answers in plain text: treat that as the reply.
                let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { host.showAnswer(text) }
                return
            }
            let calls: [[String: Any]] = reply.toolCalls.map { call in
                let function: [String: Any] = ["name": call.name,
                                               "arguments": call.arguments.mapValues { $0.description }]
                return ["function": function]
            }
            let assistant: [String: Any] = ["role": "assistant", "content": reply.content, "tool_calls": calls]
            messages.append(assistant)
            for call in reply.toolCalls {
                host.log("command: step \(step + 1) → \(call.name) \(call.arguments.mapValues(\.description))")
                if call.name == "done" { return }
                let outcome = await execute(call.name, call.arguments)
                if outcome.finished { return }
                messages.append(["role": "tool", "tool_name": call.name, "content": outcome.result])
            }
        }
        host.log("command: stopped after \(maxSteps) steps")
    }

    // MARK: - Tools

    struct Outcome {
        let result: String
        /// The command is complete (an answer was shown or text was pasted).
        var finished = false
        /// The result was already shown to you.
        var shown = false
    }

    private func execute(_ tool: String, _ args: [String: JSONValue]) async -> Outcome {
        func text(_ key: String) -> String { args[key]?.description.trimmingCharacters(in: .whitespaces) ?? "" }
        switch tool {
        case "open_app": return Outcome(result: await MacActions.openApp(text("name")))
        case "quit_app":
            let name = text("name")
            guard let app = MacActions.running(name) else { return Outcome(result: "\"\(name)\" isn't running.") }
            let title = "Quit \(app.localizedName ?? name)?"
            guard await host.confirm(title, "It will ask about any unsaved work, as ⌘Q does.") else {
                return Outcome(result: "You cancelled quitting \(name).", finished: true)
            }
            return Outcome(result: MacActions.quitApp(name))
        case "hide_app": return Outcome(result: MacActions.hideApp(text("name")))
        case "find_apps": return Outcome(result: MacActions.findApps(text("query")))
        case "list_running_apps": return Outcome(result: MacActions.runningApps())
        case "open_folder": return Outcome(result: MacActions.openFolder(text("name")))
        case "search_files":
            host.searchFiles(text("query"))
            return Outcome(result: "Showing file search results for \"\(text("query"))\".", finished: true, shown: true)
        case "open_url": return Outcome(result: MacActions.openURL(text("url")))
        case "web_search": return Outcome(result: MacActions.webSearch(text("query")))
        case "set_volume": return Outcome(result: MacActions.setVolume(Int(args["percent"]?.number ?? 50)))
        case "change_volume": return Outcome(result: MacActions.changeVolume(by: text("direction") == "down" ? -15 : 15))
        case "mute":
            let on = text("on") != "false"
            return Outcome(result: MacActions.mute(on))
        case "brightness": return Outcome(result: MacActions.brightness(up: text("direction") != "down"))
        case "lock_screen": return Outcome(result: MacActions.lockScreen())
        case "screenshot": return Outcome(result: MacActions.screenshot())
        case "list_shortcuts": return Outcome(result: await MacActions.listShortcuts())
        case "run_shortcut":
            let name = text("name")
            guard await host.confirm("Run the shortcut \"\(name)\"?", "Shortcuts can change things on your Mac.") else {
                return Outcome(result: "You cancelled the shortcut.", finished: true)
            }
            host.progress("Running \(name)…")
            return Outcome(result: await MacActions.runShortcut(name, input: args["input"]?.description))
        case "ask_claude", "ask_codex":
            let helper: AssistantCLI = tool == "ask_claude" ? .claude : .codex
            let task = text("task")
            guard helper.isAllowed else { return Outcome(result: "\(helper.display) isn't allowed in Murmur's menu.") }
            guard await host.confirm("Ask \(helper.display)?",
                                     "Murmur will send this to \(helper.display) (uses your subscription):\n\n\(task.prefix(600))")
            else { return Outcome(result: "You declined asking \(helper.display).", finished: true) }
            host.progress("Asking \(helper.display)…")
            let answer = await helper.run(task)
            return Outcome(result: "\(helper.display) answered:\n\(answer.prefix(6000))")
        case "insert_text":
            host.insert(text("text"))
            return Outcome(result: "Pasted.", finished: true, shown: true)
        case "reply":
            host.showAnswer(text("text"))
            return Outcome(result: "Shown.", finished: true, shown: true)
        default:
            return Outcome(result: "Unknown tool \(tool).")
        }
    }

    static func systemPrompt(helpers: [AssistantCLI]) -> String {
        var lines = [
            "You are Murmur, a voice assistant on the user's Mac. The user spoke a command; carry it out with tools.",
            "Rules:",
            "- Respond only with tool calls. Keep it to the fewest steps that do the job.",
            "- Apps: open_app, quit_app, hide_app, find_apps, list_running_apps. Use the app name the user said.",
            "- Files: search_files for finding the user's own files by what they contain; open_folder for standard folders.",
            "- Web: open_url for a site, web_search to search.",
            "- System: set_volume, change_volume, mute, brightness, lock_screen, screenshot.",
            "- Shortcuts: list_shortcuts, run_shortcut.",
            "- To write or rewrite text for the user (a reply, a shorter version of the selection, a translation), "
                + "call insert_text with the finished text only.",
            "- To answer a question, call reply with a short answer.",
        ]
        if !helpers.isEmpty {
            let names = helpers.map { $0 == .claude ? "ask_claude" : "ask_codex" }.joined(separator: " or ")
            lines.append("- For hard reasoning, coding, long writing or anything you are unsure of, call \(names) with a "
                + "self-contained task, then pass the answer on with reply or insert_text.")
        }
        lines.append("- When nothing more is needed, call done.")
        return lines.joined(separator: "\n")
    }

    static func tools(helpers: [AssistantCLI]) -> [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: (String, String)] = [:],
                  required: [String]? = nil) -> [String: Any] {
            var props: [String: Any] = [:]
            for (key, (type, detail)) in properties { props[key] = ["type": type, "description": detail] }
            let parameters: [String: Any] = ["type": "object", "properties": props,
                                             "required": required ?? Array(properties.keys)]
            let function: [String: Any] = ["name": name, "description": description, "parameters": parameters]
            return ["type": "function", "function": function]
        }
        var list: [[String: Any]] = [
            tool("open_app", "Open or switch to an app", ["name": ("string", "app name as spoken")]),
            tool("quit_app", "Quit a running app (asks the user first)", ["name": ("string", "app name")]),
            tool("hide_app", "Hide a running app", ["name": ("string", "app name")]),
            tool("find_apps", "List installed apps matching a name", ["query": ("string", "part of the name")]),
            tool("list_running_apps", "List the apps that are running"),
            tool("open_folder", "Open a standard folder in Finder",
                 ["name": ("string", "downloads, documents, desktop, pictures, music, movies or home")]),
            tool("search_files", "Search the user's files by meaning and show the results",
                 ["query": ("string", "what to look for")]),
            tool("open_url", "Open a website", ["url": ("string", "address, e.g. github.com")]),
            tool("web_search", "Search the web in the browser", ["query": ("string", "search terms")]),
            tool("set_volume", "Set output volume", ["percent": ("number", "0 to 100")]),
            tool("change_volume", "Turn the volume up or down", ["direction": ("string", "up or down")]),
            tool("mute", "Mute or unmute the sound", ["on": ("boolean", "true to mute")]),
            tool("brightness", "Make the screen brighter or dimmer", ["direction": ("string", "up or down")]),
            tool("lock_screen", "Lock the screen"),
            tool("screenshot", "Open the screenshot toolbar"),
            tool("list_shortcuts", "List the user's Shortcuts"),
            tool("run_shortcut", "Run one of the user's Shortcuts (asks first)",
                 ["name": ("string", "shortcut name"), "input": ("string", "optional text input")], required: ["name"]),
            tool("insert_text", "Paste finished text where the user is typing", ["text": ("string", "the text")]),
            tool("reply", "Show a short answer to the user", ["text": ("string", "the answer")]),
            tool("done", "Finish when nothing more is needed"),
        ]
        if helpers.contains(.claude) {
            list.append(tool("ask_claude", "Ask Claude Code (strong reasoning, coding, writing); returns its answer",
                             ["task": ("string", "a complete, self-contained task")]))
        }
        if helpers.contains(.codex) {
            list.append(tool("ask_codex", "Ask Codex (strong reasoning, coding); returns its answer",
                             ["task": ("string", "a complete, self-contained task")]))
        }
        return list
    }
}
