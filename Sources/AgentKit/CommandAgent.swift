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
    /// Put text in place of the selection in the app you were in. Returns false when it plainly didn't take (the
    /// selection is in text you can't edit: a web page, a received email, a PDF), so the result is shown instead.
    public var replaceSelection: (String) async -> Bool
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
                openFile: @escaping (String) async -> String = { _ in "" },
                replaceSelection: ((String) async -> Bool)? = nil) {
        self.confirm = confirm
        self.showAnswer = showAnswer
        self.insert = insert
        self.replaceSelection = replaceSelection ?? { text in insert(text); return true }
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
    private let maxSteps = 16
    /// A browser opened earlier in this command: web searches and addresses open there.
    private var lastBrowser: AppCatalog.App?
    /// Tools whose result the model needs to read before it can go on (the screen, a list, a helper's answer).
    /// A step without any of them is the last one, unless the model is still working (no `done` yet and it looked).
    private static let informationTools: Set<String> = [
        "find_apps", "list_running_apps", "list_shortcuts", "ask_claude", "ask_codex", "read_screen", "run_command",
    ]
    /// A click on one of these asks you first.
    private static let riskyWords = #"(?i)\b(send|delete|remove|buy|purchase|pay|place order|checkout|check out|post|publish|submit|transfer|unsubscribe|sign out|log out|confirm|book|reply all)\b"#

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

    // MARK: - Building

    /// Hands a build to Claude Code (or Codex): asks you first (it writes files and uses your subscription), makes a
    /// new project folder and opens the session in Terminal, where you watch it and answer its questions.
    private func build(_ task: String, helper requested: String, folderName: String) async -> Outcome {
        host.progress("Getting a coding agent ready…")
        var candidates: [AssistantCLI] = requested == "codex" ? [.codex, .claude] : [.claude, .codex]
        if requested == "claude" { candidates = [.claude, .codex] }
        var chosen: AssistantCLI?
        for helper in candidates {
            if await helper.locate() != nil {
                chosen = helper
                break
            }
        }
        guard let helper = chosen else {
            host.showAnswer("To build software Murmur hands the work to Claude Code or Codex, and neither is "
                + "installed.\n\nInstall Claude Code:  npm install -g @anthropic-ai/claude-code\nor Codex:  "
                + "npm install -g @openai/codex\n\nThen sign in once in Terminal (run `claude` or `codex`).")
            return Outcome(result: "No coding agent installed.", finished: true, shown: true)
        }
        let folder = AssistantCLI.newProjectFolder(for: task, name: folderName.isEmpty ? nil : folderName)
        let place = folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        // "Start without asking" (Commands & AI → Helpers) skips the dialog.
        let approved = AssistantCLI.autoApprove ? true
            : await host.confirm("Build this with \(helper.display)?",
                                 "“\(task)”\n\nIn a new folder: \(place)\n\n\(helper.display) opens in Terminal and works "
                                 + "there with your subscription. It edits files in that folder on its own and asks "
                                 + "you before running commands.")
        guard approved else { return Outcome(result: "You cancelled the build.", finished: true) }
        if AssistantCLI.autoApprove { host.log("command: starting \(helper.display) without asking (auto-approve on)") }
        let result = await helper.startSession(task, in: folder)
        host.log("command: \(result)")
        host.progress(result.hasPrefix("Started") ? "\(helper.display) is building it in Terminal" : result)
        return Outcome(result: result, finished: true)
    }

    // MARK: - Selected text

    public struct SelectionTask: Sendable {
        /// Shown to read (a summary, an explanation, a drafted reply) rather than put in place of the selection.
        public let shows: Bool
    }

    /// "summarise this", "make it more formal", "translate this to Hindi", "explain this": one thing to do with the
    /// selected text, answered in one step. A request that goes on to do more with the result ("summarise this and
    /// add it to Notes", "translate this and email it to Riya") isn't one: the router plans those (`route`), with
    /// the selection in hand. Verbs that also start ordinary sentences ("make", "fix"…) need "this" / "it" too.
    nonisolated public static func selectionTask(_ utterance: String) -> SelectionTask? {
        guard let task = selectionInstruction(utterance) else { return nil }
        return goesFurther(QuickCommands.clean(utterance)) ? nil : task
    }

    /// Whether the words are an instruction about the selected text at all, one step or several (for telling a
    /// command from dictation while text is selected).
    nonisolated public static func isAboutSelection(_ utterance: String) -> Bool {
        selectionInstruction(utterance) != nil
    }

    /// More than the edit itself: a second action, or somewhere else for the result to go.
    nonisolated static func goesFurther(_ text: String) -> Bool {
        let nextAction = #"\b(and|then|and then)\b.*\b(add|put|save|send|paste|write|create|make|open|email|mail|share|post|copy|insert|append|store|note|attach|tweet|message|text|search|google|look up|read)\b"#
        let destination = #"\b(in|into|to|on|onto|as)\s+(a\s+|an\s+|my\s+|the\s+)?(new\s+)?(notes?|apple notes|textedit|pages|word|docs?|google docs|document|file|mail|email|gmail|outlook|slack|whatsapp|messages|imessage|telegram|teams|discord|reminders?|calendar|notion|obsidian|todo|to-do|clipboard|desktop|downloads)\b"#
        return text.range(of: nextAction, options: .regularExpression) != nil
            || text.range(of: destination, options: .regularExpression) != nil
    }

    nonisolated static func selectionInstruction(_ utterance: String) -> SelectionTask? {
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
        let text = ModelOutput.answer(reply?.text ?? "")
        guard !text.isEmpty else {
            host.showAnswer("Couldn't do that with the selected text. \(RouterDiagnostics.lastError ?? "The model didn't answer.")")
            return
        }
        host.log("command: \(router.name) worked on \(selection.count) selected characters → \(text.count)")
        if show {
            host.showAnswer(text)
        } else if !(await host.replaceSelection(text)) {
            // The selection is in text that can't be edited (a web page, a received email): show it to read or paste.
            host.log("command: the selection didn't change after pasting; showing the result instead")
            host.showAnswer(text)
        }
    }

    // MARK: - Router loop

    /// The router for this command: the cloud model you chose, else the local one.
    public func currentRouter() -> Router {
        Routers.current(localModel: routerModel)
    }

    private func route(_ utterance: String, frontApp: String?, selection: String?, explicit: Bool) async {
        var context = "Front app: \(frontApp ?? "unknown")."
        if let selection, !selection.isEmpty {
            context += "\nSelected text (what \"this\", \"it\" and \"the selection\" mean):\n\"\"\"\n\(selection.prefix(8000))\n\"\"\""
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
                let text = ModelOutput.answer(reply.text)
                if !text.isEmpty { host.showAnswer(text) }
                return
            }
            turns.append(.assistant(text: reply.text, calls: reply.calls))
            var needsAnotherLook = false
            var finishedNow = false
            var results: [String] = []
            for call in reply.calls {
                host.log("command: step \(step + 1) → \(call.name) \(call.arguments.mapValues(\.description))")
                if call.name == "done" {
                    turns.append(.toolResult(callID: call.id, name: call.name, content: "ok"))
                    finishedNow = true
                    continue
                }
                let outcome = await execute(call.name, call.arguments)
                if outcome.finished { return }
                results.append(outcome.result)
                if Self.informationTools.contains(call.name) { needsAnotherLook = true }
                turns.append(.toolResult(callID: call.id, name: call.name, content: outcome.result))
            }
            // Actions only (open, search, volume…), or the model said done: finished, without another trip to the
            // model just to say so. Otherwise it looked at something (the screen, a list) and goes on from there.
            if !needsAnotherLook || finishedNow {
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

    /// "… on chrome": use that browser for this and the next web steps.
    private func useBrowser(_ value: JSONValue?) {
        guard let name = value?.description.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let app = AppCatalog.shared.resolve(name), MacActions.isBrowser(app) else { return }
        lastBrowser = app
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
        case "open_url":
            useBrowser(args["browser"])
            return Outcome(result: MacActions.openURL(text("url"), in: lastBrowser))
        case "web_search":
            useBrowser(args["browser"])
            return Outcome(result: MacActions.webSearch(text("query"), in: lastBrowser))
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
            let approved = AssistantCLI.autoApprove ? true
                : await host.confirm("Ask \(helper.display)?",
                                     "Murmur will send this to \(helper.display) (uses your subscription):\n\n\(task.prefix(600))")
            guard approved else { return Outcome(result: "You declined asking \(helper.display).", finished: true) }
            host.progress("Asking \(helper.display)…")
            let answer = await helper.run(task)
            return Outcome(result: "\(helper.display) answered:\n\(answer.prefix(6000))")
        case "build_with_agent":
            return await build(text("task"), helper: text("helper"), folderName: text("folder_name"))
        case "open_settings": return Outcome(result: MacActions.openSettings(text("pane")))
        case "site_search":
            useBrowser(args["browser"])
            return Outcome(result: MacActions.siteSearch(text("site"), text("query"), in: lastBrowser))
        case "read_screen":
            host.progress("Looking at the screen…")
            let screen = await ScreenControl.read()
            host.log("command: screen has \(screen.split(separator: "\n").count - 2) things")
            return Outcome(result: screen)
        case "click":
            let id = Int(args["id"]?.number ?? 0)
            let what = ScreenControl.name(of: id) ?? "[\(id)]"
            if what.range(of: Self.riskyWords, options: .regularExpression) != nil {
                guard await host.confirm("Click \(what)?", "This may send, buy, post or delete something.") else {
                    return Outcome(result: "You said no to clicking \(what).", finished: true)
                }
            }
            host.progress("Clicking \(what)…")
            return Outcome(result: await ScreenControl.click(id))
        case "type_text":
            let words = text("text")
            if let id = args["into"]?.number, id > 0 {
                _ = await ScreenControl.focus(Int(id))
            }
            host.pasteHere(words)
            try? await Task.sleep(nanoseconds: 350_000_000)
            if text("submit") == "true" {
                _ = ScreenControl.press("return")
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            return Outcome(result: "Typed \(words.count) characters\(text("submit") == "true" ? " and pressed Return" : "").")
        case "press_keys":
            let result = ScreenControl.press(text("keys"))
            try? await Task.sleep(nanoseconds: 300_000_000)
            return Outcome(result: result)
        case "wait":
            let seconds = min(max(args["seconds"]?.number ?? 1, 0.2), 6)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return Outcome(result: "Waited \(seconds) s.")
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
        case "replace_selection":
            let body = text("text")
            if await host.replaceSelection(body) {
                return Outcome(result: "Replaced the selected text.", finished: true, shown: true)
            }
            host.showAnswer(body)
            return Outcome(result: "The selected text can't be edited there; showed the result instead.",
                           finished: true, shown: true)
        case "run_command":
            return await runCommand(text("command"), purpose: text("purpose"))
        case "reply":
            host.showAnswer(text("text"))
            return Outcome(result: "Shown.", finished: true, shown: true)
        default:
            return Outcome(result: "Unknown tool \(tool).")
        }
    }

    /// A shell command the model asked for: reading commands run at once, anything else is shown to you first.
    private func runCommand(_ command: String, purpose: String) async -> Outcome {
        guard !command.isEmpty else { return Outcome(result: "No command given.") }
        if ShellCommand.usesSudo(command) {
            return Outcome(result: "Murmur doesn't run commands as administrator (sudo). Tell the user the command so "
                + "they can run it in Terminal themselves.")
        }
        if !ShellCommand.isReadOnly(command) {
            let detail = (purpose.isEmpty ? "" : purpose + "\n\n") + command
            guard await host.confirm("Run this command?", detail) else {
                return Outcome(result: "The user chose not to run it.", finished: true)
            }
        }
        host.progress("Running a command…")
        let result = await ShellCommand.run(command)
        host.log("command: ran `\(command)` → exit \(result.status), \(result.output.count) characters")
        var summary = result.timedOut ? "Stopped after 60 s." : "Exit status \(result.status)."
        summary += result.output.isEmpty ? " No output." : "\nOutput:\n\(result.output)"
        return Outcome(result: summary)
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
            "- Mac settings and updates: open_settings (\"check for updates\" → software update); then read_screen "
                + "and click if the user asked for a specific switch.",
            "- System: set_volume, change_volume, mute, brightness, lock_screen, screenshot.",
            "- Shortcuts: list_shortcuts, run_shortcut.",
            "- Building or changing software (an app, website, script, API, project; \"create a React app…\"): call "
                + "build_with_agent with the user's full request. It starts Claude Code or Codex in Terminal to build "
                + "it. Never web_search or open a browser for that.",
            "- You can see and use the front app like a person: read_screen lists its window's buttons, links and "
                + "fields as [n]; click n; type_text (into field n, submit true to press Return); press_keys "
                + "(\"return\", \"cmd+l\", \"cmd+n\", \"down\", \"pagedown\"); wait. Use them for any task the other "
                + "tools don't cover, step by step: act, then read_screen in the SAME response to see the result, and "
                + "go on until the whole request is done. Numbers change on every read: only use numbers from the "
                + "latest read_screen. When everything is done, call done.",
            "- Websites: open the result page directly when you can: site_search (YouTube, Amazon, GitHub, Maps, "
                + "Wikipedia…) or open_url with a search URL; then read_screen and click what the user wants "
                + "(\"the first video\": the first link that is a video title, not an ad or a channel).",
            "- Clicking send, buy, post or delete asks the user; only do it when they asked for it.",
            "- To write something in an app (\"open Notes and write a shopping list\", \"open TextEdit and draft a "
                + "letter to…\"): call write_in_app ONCE with the app and the finished text, written by you in full "
                + "(plain text, a short title line first for notes). Don't call open_app as well. new_document false "
                + "only when the user wants it added to what's already open.",
            "- Selected text (below, when there is any) is what \"this\", \"it\" and \"the selection\" mean. Do the "
                + "whole request in one go: write the summary, translation or rewrite yourself, then put it where the "
                + "user asked. In place of the selection: replace_selection. In another app: write_in_app (\"summarise "
                + "this and add it to Notes\" → write_in_app with app Notes and your summary as the text). To read: "
                + "reply. Never answer that you can't put it somewhere: use the tools.",
            "- To write text where the user is typing (no selection to replace), call insert_text with the finished "
                + "text only.",
            "- Terminal: run_command runs a shell command on this Mac and gives you its output (anything that changes "
                + "something is shown to the user first). Use it for what the other tools don't cover: disk space, "
                + "battery, Wi-Fi details, file operations (copy, move, zip, convert an image with sips), git, "
                + "installed tools. One command at a time; read the output, then go on or reply with the answer. "
                + "Never use sudo.",
            "- Don't give up after one try: when a step fails, try another way (another tool, read_screen and click, "
                + "or run_command). Only reply that something can't be done once the tools truly can't do it.",
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
            tool("open_url", "Open a website, in a named browser if the user said one (\"open youtube on chrome\")",
                 ["url": ("string", "address, e.g. github.com or youtube.com"),
                  "browser": ("string", "browser to use, e.g. Chrome; empty for the default")], required: ["url"]),
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
            tool("build_with_agent", "Start a Claude Code (or Codex) session in Terminal that builds software in a new "
                 + "project folder", ["task": ("string", "the user's full request"),
                                      "helper": ("string", "claude or codex; empty for the default"),
                                      "folder_name": ("string", "short folder name, optional")], required: ["task"]),
            tool("open_settings", "Open a System Settings pane (software update, wifi, bluetooth, battery, display, "
                 + "sound, privacy, keyboard…) or \"app store updates\"", ["pane": ("string", "the pane")]),
            tool("site_search", "Search a website in the browser (youtube, google, amazon, github, maps, wikipedia, "
                 + "reddit, linkedin, spotify…)", ["site": ("string", "the site"), "query": ("string", "what to search")]),
            tool("read_screen", "See the front app's window: its buttons, links and fields, numbered"),
            tool("click", "Click element [n] from the latest read_screen", ["id": ("number", "the element's number")]),
            tool("type_text", "Type text into the front app (optionally into field [n] first; submit presses Return)",
                 ["text": ("string", "what to type"), "into": ("number", "field number from read_screen, optional"),
                  "submit": ("boolean", "press Return afterwards")], required: ["text"]),
            tool("press_keys", "Press a key or shortcut in the front app", ["keys": ("string", "e.g. return, cmd+l, down")]),
            tool("wait", "Wait for a page or app to load", ["seconds": ("number", "0.5 to 6")]),
            tool("write_in_app", "Open an app (Notes, TextEdit, Pages…), start a new note or document, and type the text",
                 ["app": ("string", "app name"), "text": ("string", "the full finished text to write"),
                  "new_document": ("boolean", "true for a new note/document (default), false to add to the open one")],
                 required: ["app", "text"]),
            tool("insert_text", "Paste finished text where the user is typing", ["text": ("string", "the text")]),
            tool("replace_selection", "Put finished text in place of the user's selected text (a translation, a "
                 + "rewrite, a fix)", ["text": ("string", "the finished text")]),
            tool("run_command", "Run a shell command on the Mac (zsh, in the home folder) and return its output",
                 ["command": ("string", "the command"),
                  "purpose": ("string", "one short line on what it does, shown when the user is asked")],
                 required: ["command"]),
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
