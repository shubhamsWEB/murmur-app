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
    /// Paste into the app in front now (not the one you were in when you spoke): after Murmur opened it.
    public var pasteHere: (String) -> Void
    /// Open the file that best matches a description ("my resume pdf"), or show the matches when it isn't clear
    /// which one. Returns what happened, to show.
    public var openFile: (String) async -> String
    /// A short status line while it works ("Asking Claude Code…").
    public var progress: (String) -> Void
    /// Log lines.
    public var log: (String) -> Void

    public init(confirm: @escaping (String, String) async -> Bool, showAnswer: @escaping (String) -> Void,
                insert: @escaping (String) -> Void, searchFiles: @escaping (String) -> Void,
                progress: @escaping (String) -> Void, log: @escaping (String) -> Void,
                pasteHere: @escaping (String) -> Void = { _ in },
                openFile: @escaping (String) async -> String = { _ in "" }) {
        self.confirm = confirm
        self.showAnswer = showAnswer
        self.insert = insert
        self.searchFiles = searchFiles
        self.openFile = openFile
        self.pasteHere = pasteHere
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
    /// A browser opened earlier in this command: web searches and addresses open there.
    private var lastBrowser: AppCatalog.App?
    /// Tools whose result the model needs to read before it can go on. After any other step, the command is done.
    private static let informationTools: Set<String> = [
        "find_apps", "list_running_apps", "list_shortcuts", "ask_claude", "ask_codex",
    ]

    public init(host: CommandHost) {
        self.host = host
    }

    /// Runs one spoken command. `selection` is the text selected in the front app, if any.
    /// `explicit`: you clearly gave a command. When it's only the model's guess and the model just answers (no
    /// action), it was dictation after all: the words are typed instead of shown as an answer.
    /// `editable`: the selection is in a text field, so an edit of it can replace it.
    public func run(_ utterance: String, frontApp: String?, selection: String?, explicit: Bool = true,
                    editable: Bool = false) async {
        let started = Date()
        lastBrowser = nil
        if let selection, !selection.isEmpty, let task = Self.selectionTask(utterance) {
            await transform(selection, instruction: utterance, show: task.shows || !editable)
            host.log(String(format: "command: selection task done in %.2f s", Date().timeIntervalSince(started)))
            return
        }
        if let actions = QuickCommands.parseAll(utterance) {
            var results: [String] = []
            for action in actions {
                // "open chrome and search facebook": after opening a browser, "search" means the web, in it.
                let tool = action.tool == "search_files" && lastBrowser != nil ? "web_search" : action.tool
                host.log("command: quick path → \(tool) \(action.arguments)")
                let outcome = await execute(tool, action.arguments.mapValues { JSONValue.string($0) })
                results.append(outcome.result)
                if outcome.finished { break }
                if actions.count > 1, action.tool == "open_app" {
                    try? await Task.sleep(nanoseconds: 300_000_000)   // let the app come up before the next step
                }
            }
            let summary = results.joined(separator: " ")
            host.log(String(format: "command: done in %.2f s: %@", Date().timeIntervalSince(started), summary))
            host.progress(summary)
            return
        }
        await route(utterance, frontApp: frontApp, selection: selection, explicit: explicit)
        host.log(String(format: "command: finished in %.2f s", Date().timeIntervalSince(started)))
    }

    /// No model to ask, but it sounds like a search ("search my resume", "find the lease"): search your files rather
    /// than show an error.
    private func searchInstead(_ utterance: String) -> Bool {
        let text = QuickCommands.clean(utterance)
        guard let range = text.range(of: #"^(search|find|look for|look up|open|show me|show|get)( for)? "#,
                                     options: .regularExpression) else { return false }
        let query = String(text[range.upperBound...])
        guard !query.isEmpty else { return false }
        host.log("command: no model answered; searching files for \"\(query)\"")
        host.searchFiles(query)
        return true
    }

    // MARK: - Selected text

    public struct SelectionTask: Sendable {
        /// Shown to read (a summary, an explanation, a drafted reply) rather than put in place of the selection.
        public let shows: Bool
    }

    /// "summarise this", "make it more formal", "translate this to Hindi", "explain this": something to do with the
    /// selected text. Verbs that also start ordinary sentences ("make", "fix"…) need "this" / "it" / "selected" too.
    nonisolated public static func selectionTask(_ utterance: String) -> SelectionTask? {
        let text = QuickCommands.clean(utterance)
        let reading = #"^(summari[sz]e|sum up|tl ?dr|explain|what does (this|it) (mean|say)|what is this|what's this|reply to|respond to|answer|draft a reply|write a reply)\b"#
        let editing = #"^(translate|rewrite|rephrase|reword|shorten|condense|simplify|expand|lengthen|proofread|paraphrase)\b"#
        let needsThis = #"^(make|turn|convert|fix|correct|improve|polish|edit|format|clean up|change)\b"#
        let mentionsSelection = text.range(of: #"\b(this|it|that|selection|selected|text|paragraph|sentence|email|message)\b"#,
                                           options: .regularExpression) != nil
        if text.range(of: reading, options: .regularExpression) != nil { return SelectionTask(shows: true) }
        if text.range(of: editing, options: .regularExpression) != nil { return SelectionTask(shows: false) }
        if text.range(of: needsThis, options: .regularExpression) != nil, mentionsSelection {
            return SelectionTask(shows: false)
        }
        return nil
    }

    /// Does what you asked with the selected text: one plain-text answer from the model, no tools. A summary or an
    /// explanation is shown; an edit replaces the selection when it's in a text field (else it's shown to paste).
    private func transform(_ selection: String, instruction: String, show: Bool) async {
        host.progress(show ? "Reading the selected text…" : "Working on the selected text…")
        let system = """
        You help with text the user selected on their Mac. Follow their spoken instruction on the selected text and \
        reply with only the result: no preamble, no quotation marks, no notes about what you did. Keep the text's \
        language unless asked to translate. A summary is at most \(max(30, selection.split(separator: " ").count / 4)) \
        words: a few short sentences or bullet points, never longer than the text. An explanation is short and plain.
        """
        let turns: [RouterTurn] = [.user("Instruction: \(WakeName.strip(instruction) ?? instruction)\n\n"
            + "Selected text:\n\"\"\"\n\(selection.prefix(12_000))\n\"\"\"")]
        var router = currentRouter()
        var reply: RouterReply?
        do {
            reply = try await router.chat(system: system, turns: turns, tools: [])
        } catch {
            host.log("command: \(router.name) failed on the selection: \(error.localizedDescription)")
            RouterDiagnostics.lastError = error.localizedDescription
            if !(router is OllamaRouter) {
                router = OllamaRouter(model: routerModel)
                host.progress("Using the local model…")
                reply = try? await router.chat(system: system, turns: turns, tools: [])
            }
        }
        let text = (reply?.text ?? "")
            .replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            host.showAnswer("Couldn't do that with the selected text. \(RouterDiagnostics.lastError ?? "The model didn't answer.")")
            return
        }
        host.log("command: \(router.name) worked on \(selection.count) selected characters → \(text.count)")
        if show { host.showAnswer(text) } else { host.insert(text) }
    }

    // MARK: - Router loop

    /// The router for this command: the cloud model you chose, else the local one.
    public func currentRouter() -> Router {
        Routers.current(localModel: routerModel)
    }

    private func route(_ utterance: String, frontApp: String?, selection: String?, explicit: Bool) async {
        var context = "Front app: \(frontApp ?? "unknown")."
        if let selection, !selection.isEmpty {
            context += "\nSelected text:\n\"\"\"\n\(selection.prefix(4000))\n\"\"\""
        }
        let helpers = AssistantCLI.allCases.filter(\.isAllowed)
        let system = Self.systemPrompt(helpers: helpers) + "\n\n" + context
        let tools = Self.tools(helpers: helpers)
        var turns: [RouterTurn] = [.user(utterance)]
        var router = currentRouter()
        host.progress("Thinking…")
        for step in 0..<maxSteps {
            let reply: RouterReply
            let asked = Date()
            do {
                reply = try await router.chat(system: system, turns: turns, tools: tools)
                host.log(String(format: "command: %@ step %d took %.2f s", router.name, step + 1,
                                Date().timeIntervalSince(asked)))
            } catch {
                host.log("command: \(router.name) failed: \(error.localizedDescription)")
                RouterDiagnostics.lastError = error.localizedDescription   // a rejected key isn't asked again
                // A cloud model that fails (offline, bad key) hands over to the local model once.
                if !(router is OllamaRouter) {
                    router = OllamaRouter(model: routerModel)
                    host.progress("\(error.localizedDescription) Using the local model…")
                    do {
                        reply = try await router.chat(system: system, turns: turns, tools: tools)
                    } catch {
                        if searchInstead(utterance) { return }
                        host.showAnswer(error.localizedDescription)
                        return
                    }
                } else {
                    if searchInstead(utterance) { return }
                    host.showAnswer(error.localizedDescription)
                    return
                }
            }
            let onlyAnswers = reply.calls.allSatisfy { $0.name == "reply" || $0.name == "done" }
            if !explicit, step == 0, onlyAnswers {
                // A guessed command that only answers: it was dictation. Type the words.
                host.log("command: guessed command only answered; typing the words instead")
                host.insert(utterance)
                return
            }
            if reply.calls.isEmpty {
                // A model sometimes answers in plain text: treat that as the reply.
                let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { host.showAnswer(text) }
                return
            }
            turns.append(.assistant(text: reply.text, calls: reply.calls))
            var needsAnotherLook = false
            var results: [String] = []
            for call in reply.calls {
                host.log("command: step \(step + 1) → \(call.name) \(call.arguments.mapValues(\.description))")
                if call.name == "done" {
                    turns.append(.toolResult(callID: call.id, name: call.name, content: "ok"))
                    continue
                }
                let outcome = await execute(call.name, call.arguments)
                if outcome.finished { return }
                results.append(outcome.result)
                if Self.informationTools.contains(call.name) { needsAnotherLook = true }
                turns.append(.toolResult(callID: call.id, name: call.name, content: outcome.result))
            }
            // Actions only (open, search, volume…): done, without another trip to the model just to say so.
            if !needsAnotherLook {
                if !results.isEmpty { host.progress(results.joined(separator: " ")) }
                return
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
        case "open_app":
            let (result, app) = await MacActions.openAppReturningApp(text("name"))
            if MacActions.isBrowser(app) { lastBrowser = app }
            return Outcome(result: result)
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
        case "open_file":
            host.progress("Finding “\(text("query"))”…")
            return Outcome(result: await host.openFile(text("query")), finished: true)
        case "search_files":
            // "my resume" → "resume": the possessive only adds noise to the search.
            var query = text("query").replacingOccurrences(of: #"^(my|the|all|some) "#, with: "",
                                                           options: [.regularExpression, .caseInsensitive])
            // A CV is a résumé: search for both words.
            if query.range(of: #"\b(cv|resume|résumé)\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
               query.split(separator: " ").count <= 3 {
                query = "resume cv" + (query.lowercased().hasPrefix("cv") || query.lowercased().hasPrefix("resume")
                    ? "" : " " + query)
            }
            host.searchFiles(query)
            return Outcome(result: "Showing file search results for \"\(query)\".", finished: true, shown: true)
        case "open_url": return Outcome(result: MacActions.openURL(text("url"), in: lastBrowser))
        case "web_search": return Outcome(result: MacActions.webSearch(text("query"), in: lastBrowser))
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
        case "write_in_app":
            let appName = text("app")
            let body = text("text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return Outcome(result: "There was nothing to write.") }
            host.progress("Writing in \(appName)…")
            let (opened, ready) = await MacActions.prepareToWrite(in: appName, newDocument: text("new_document") != "false")
            guard ready else {
                host.showAnswer("\(opened)\n\nHere's what I wrote:\n\n\(body)")
                return Outcome(result: opened, finished: true, shown: true)
            }
            host.pasteHere(body)
            host.log("command: wrote \(body.count) characters in \(appName)")
            host.progress("Written in \(appName)")
            return Outcome(result: "Wrote it in \(appName).", finished: true, shown: true)
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
            "- Respond only with tool calls. Call every tool the request needs in ONE response, in order "
                + "(e.g. open_app then web_search). Keep it to the fewest steps.",
            "- Apps: open_app, quit_app, hide_app, find_apps, list_running_apps. Use the app name the user said.",
            "- Opening a file (\"open my resume pdf\"): open_file with the description.",
            "- Files: \"search\", \"find\" or \"look for\" means the user's own files on this Mac: search_files. "
                + "open_folder for standard folders.",
            "- Web: web_search only when the user says web, online, internet or Google, or after opening a browser; "
                + "open_url for a site.",
            "- System: set_volume, change_volume, mute, brightness, lock_screen, screenshot.",
            "- Shortcuts: list_shortcuts, run_shortcut.",
            "- To write something in an app (\"open Notes and write a shopping list\", \"open TextEdit and draft a "
                + "letter to…\"): call write_in_app ONCE with the app and the finished text, written by you in full "
                + "(plain text, a short title line first for notes). Don't call open_app as well. new_document false "
                + "only when the user wants it added to what's already open.",
            "- To write or rewrite text for the user (a reply, a shorter version of the selection, a translation), "
                + "call insert_text with the finished text only.",
            "- To answer a question, call reply with a short answer.",
        ]
        if !helpers.isEmpty {
            let names = helpers.map { $0 == .claude ? "ask_claude" : "ask_codex" }.joined(separator: " or ")
            lines.append("- For hard reasoning, coding, long writing or anything you are unsure of, call \(names) with a "
                + "self-contained task, then pass the answer on with reply or insert_text. Never use \(names) to find, "
                + "search or open the user's files or apps: use open_file, search_files or open_app.")
        }
        lines.append("- When nothing more is needed, call done.")
        return lines.joined(separator: "\n")
    }

    static func tools(helpers: [AssistantCLI]) -> [ToolSpec] {
        func tool(_ name: String, _ description: String, _ properties: [String: (String, String)] = [:],
                  required: [String]? = nil) -> ToolSpec {
            var props: [String: Any] = [:]
            for (key, (type, detail)) in properties { props[key] = ["type": type, "description": detail] }
            let parameters: [String: Any] = ["type": "object", "properties": props,
                                             "required": required ?? Array(properties.keys)]
            return ToolSpec(name: name, description: description, parameters: parameters)
        }
        var list: [ToolSpec] = [
            tool("open_app", "Open or switch to an app", ["name": ("string", "app name as spoken")]),
            tool("quit_app", "Quit a running app (asks the user first)", ["name": ("string", "app name")]),
            tool("hide_app", "Hide a running app", ["name": ("string", "app name")]),
            tool("find_apps", "List installed apps matching a name", ["query": ("string", "part of the name")]),
            tool("list_running_apps", "List the apps that are running"),
            tool("open_folder", "Open a standard folder in Finder",
                 ["name": ("string", "downloads, documents, desktop, pictures, music, movies or home")]),
            tool("open_file", "Open the user's own file that best matches a description, e.g. \"my resume pdf\"",
                 ["query": ("string", "the file as described")]),
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
            tool("write_in_app", "Open an app (Notes, TextEdit, Pages…), start a new note or document, and type the text",
                 ["app": ("string", "app name"), "text": ("string", "the full finished text to write"),
                  "new_document": ("boolean", "true for a new note/document (default), false to add to the open one")],
                 required: ["app", "text"]),
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
