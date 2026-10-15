import AppKit

/// A file the search found for a description, best first: what the model sees to pick the one the user means.
public struct FileCandidate: Sendable {
    public let path: String
    public let kind: String
    public let modified: Date
    public let excerpt: String?
    /// The search's own score, for ordering and for telling a clear winner from a close call.
    public let score: Double

    public init(path: String, kind: String, modified: Date, excerpt: String?, score: Double) {
        self.path = path
        self.kind = kind
        self.modified = modified
        self.excerpt = excerpt
        self.score = score
    }
}

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
    /// Open the settings where a model for commands is chosen (Commands & AI).
    public var openModelSettings: () -> Void = {}
    /// Ask before an action, with the choice to allow it for the rest of the task or always (that kind). Nil kind: a
    /// question that can only be answered once (a payment), or the task as a whole (`.task` lets it run on its own).
    public var approve: (_ kind: Permission?, _ title: String, _ detail: String) async -> Approval = { _, _, _ in .no }
    /// The search's best matches for a description of a file (the same search the Search page runs), best first.
    public var findFiles: (String) async -> [FileCandidate] = { _ in [] }

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
    /// Steps for a plain command; a task list raises it (a few steps per item), up to `stepCap`.
    private let maxSteps = 24
    private let stepCap = 90
    /// The longest a command may run, however many steps are left.
    private let timeCap: TimeInterval = 8 * 60

    /// One line of the model's task list.
    struct PlanStep: Equatable {
        var text: String
        var done: Bool
    }

    /// The model's task list for this command: written when it starts a big request and rewritten as it learns
    /// (more emails to open, a step that isn't needed, a sign-in in the way). It and the notes are shown to the model
    /// on every step, so they survive older page text being cut.
    private var plan: [PlanStep] = []
    /// What the model found along the way, for the final answer ("HDFC: card bill ₹12,340 due 20 Oct").
    private var notes: [String] = []
    /// A browser opened earlier in this command: web searches and addresses open there.
    private var lastBrowser: AppCatalog.App?
    /// The browser this command opened a page in (a named one, else the default browser), so later steps act in
    /// that window even before it comes to the front.
    private var openedIn: String?
    private var browserInUse: String? { lastBrowser?.bundleID ?? openedIn }
    /// This command has put a page up: later pages load in that tab rather than new ones.
    private var openedPage = false
    /// The user said yes to sending a message in this command: Return in a chat app doesn't ask again.
    private var messageApproved = false
    /// Messages already sent in this command (what send_message sent): the same words aren't sent again.
    private var sentMessages: [String] = []
    /// Where you were typing when you spoke: the app, the field, and in a browser the tab. A command that goes off to
    /// another page or app to copy something comes back here to paste it.
    private struct InputTarget {
        let app: NSRunningApplication
        let field: AXUIElement?
        let tab: String?
    }
    private var inputTarget: InputTarget?

    /// Memory, read once for this command: applied by the actions on every path.
    private var prefs = CommandMemory.Preferences()
    /// What this command did, for memory: each tool call with its main arguments and result.
    private var did: [CommandMemory.Action] = []
    /// The model is working this command (not the quick path).
    private var routing = false
    /// Files offered to the model to pick from in this command: opening one of them is its choice, not a stale memory.
    private var offered: Set<String> = []
    /// The user let this task run on its own ("Allow for This Task"): no more questions until it ends (payments
    /// still ask).
    private var taskApproved = false
    /// Asked at the start of a big task already (when its plan was first written).
    private var askedForTask = false
    /// Matches were offered and nothing has opened yet: the model owes a pick (or a reply that none fits).
    private var awaitingPick = false
    /// What the user said for the command running now.
    private var utterance = ""
    /// The answer shown for this command, if any (for memory).
    private let shown: Shown
    private final class Shown { var answer: String? }
    /// Whether each browser's pages can be scripted, checked once per command.
    private var pageAccess: [String: Bool] = [:]
    /// Tools after which the screen is different: the step's last result shows the model the new screen.
    /// Tools that only bring something up: on their own, they rarely finish a request with more than one part.
    private static let openingTools: Set<String> = [
        "open_app", "open_url", "web_search", "site_search", "open_settings", "open_folder", "read_screen", "wait",
        "browser_read", "browser_tabs", "browser_scroll", "browser_back", "plan",
    ]

    /// "open saleshq.ai and summarise the website", "go to YouTube, then play lofi": a second part after the first.
    nonisolated static func hasMoreThanOneStep(_ utterance: String) -> Bool {
        let text = QuickCommands.clean(utterance)
        return text.range(of: #"(\band\b|\bthen\b|,)\s*(then\s+)?(also\s+)?[a-z]+"#, options: .regularExpression) != nil
            && text.split(separator: " ").count >= 4
    }

    /// The user's name (from memory) when a file search is for their own document: "my resume", "my Aadhaar card",
    /// "PAN card", "my passport", "salary slip". Nil otherwise, or when Murmur doesn't know their name.
    nonisolated public static func ownerForPersonalFile(_ query: String) -> String? {
        let text = query.lowercased()
        let personal = text.range(of: #"\b(resume|résumé|cv|aadhaa?r|pan( card)?|passport|licen[cs]e|id card|identity|voter|salary|pay ?slip|offer letter|appointment letter|relieving letter|experience letter|bank statement|certificate|marksheet|mark sheet|degree|transcript|itr|form 16|insurance|visa|birth certificate)\b"#,
                                   options: .regularExpression) != nil
        return personal ? CommandMemory.preferences().owner : nil
    }

    /// "get me the updates on my last LinkedIn post", "how many stars does it have": the user wants to be told
    /// something, so the command isn't done until an answer is shown.
    nonisolated static func asksForInformation(_ utterance: String) -> Bool {
        let text = QuickCommands.clean(utterance)
        return text.range(of: #"^(what|whats|how|who|whose|when|where|which|why|is|are|was|were|do|does|did|can|could|tell me|get me|give me|find out|check|summari[sz]e|read|list|any)\b|\b(updates?|status|latest|news|summary|how many|how much|reactions?|comments|likes|views|impressions|price|weather|score)\b"#,
                          options: .regularExpression) != nil
    }

    /// "open this video", "play that", "what's this error", "click here", "the one I'm watching": the request points
    /// at something on the screen, so the model gets a look at it before it does anything.
    nonisolated static func pointsAtScreen(_ utterance: String) -> Bool {
        let text = QuickCommands.clean(utterance)
        return text.range(of: #"\b(this|that|these|those)\b(?! (morning|afternoon|evening|night|week|weekend|month|year|time|way)\b)|\b(first|second|third|fourth|fifth|last|top|next) (one|video|file|result|item|song|link|clip|movie|photo|picture|document|pdf)\b|\bhere\b|\bon (my |the )?screen\b|\b(i'?m|i am) (watching|looking at|reading|seeing|on|playing|listening to)\b|\bthe one\b|\bcurrent (video|page|tab|song|file|window)\b"#,
                          options: .regularExpression) != nil
    }

    /// Page and screen dumps are thousands of characters each and slow every later step (a slow step is a timed-out
    /// one): keep the latest two in full and cut older ones down.
    nonisolated static func compacted(_ turns: [RouterTurn]) -> [RouterTurn] {
        var keep = 2
        var out = turns
        for index in out.indices.reversed() {
            guard case .toolResult(let id, let name, let content) = out[index], content.count > 1200 else { continue }
            if keep > 0 { keep -= 1; continue }
            out[index] = .toolResult(callID: id, name: name, content: String(content.prefix(500))
                + "\n… (older page text cut; read the page again if you need it)")
        }
        return out
    }

    private static let screenChangingTools: Set<String> = [
        "open_app", "open_url", "web_search", "site_search", "open_settings", "open_folder", "click", "press_keys",
        "type_text", "write_in_app", "browser_click", "browser_type", "browser_scroll", "browser_switch_tab",
        "browser_back",
    ]
    /// A click on one of these asks you first.
    private static let riskyWords = #"(?i)\b(send|delete|remove|buy|purchase|pay|place order|checkout|check out|post|publish|submit|transfer|unsubscribe|sign out|log out|confirm|book|reply all)\b"#

    public init(host: CommandHost) {
        // Every answer shown is remembered with the command that gave it.
        let shown = Shown()
        var host = host
        let show = host.showAnswer
        host.showAnswer = { text in
            shown.answer = text
            show(text)
        }
        self.host = host
        self.shown = shown
    }

    /// Runs one spoken command. `selection` is the text selected in the front app, if any.
    /// `explicit`: you clearly gave a command. When it's only the model's guess and the model just answers (no
    /// action), it was dictation after all: the words are typed instead of shown as an answer.
    /// `editable`: the selection is in a text field, so an edit of it can replace it.
    public func run(_ utterance: String, frontApp: String?, selection: String?, explicit: Bool = true,
                    editable: Bool = false) async {
        let started = Date()
        // In Finder what's selected is files (⌘C copies their names, which looked like selected text): they reach
        // the model as Finder's selection instead.
        let selection = ScreenControl.workingApp()?.bundleIdentifier == "com.apple.finder" ? nil : selection
        // Where the command happens, for the log: the app and the window you're looking at.
        host.log("command: in \(ScreenControl.workingApp()?.localizedName ?? "?"), window \"\(ScreenControl.frontWindowTitle() ?? "")\"")
        self.utterance = utterance
        routing = false
        offered = []
        awaitingPick = false
        plan = []
        notes = []
        taskApproved = false
        askedForTask = false
        lastBrowser = nil
        pageAccess = [:]
        openedIn = nil
        openedPage = false
        messageApproved = false
        sentMessages = []
        did = []
        shown.answer = nil
        let app = ScreenControl.workingApp()?.localizedName ?? frontApp
        let window = ScreenControl.frontWindowTitle()
        // "forget that", "clear your memory".
        if let all = CommandMemory.forgetRequest(utterance) {
            if all, !(await host.confirm("Clear Murmur's memory?",
                                         "Every command it remembers, and everything you told it, is deleted from this Mac.")) {
                return
            }
            CommandMemory.forget(all: all, facts: all)
            host.showAnswer(all ? "Done. My memory is empty now." : "Forgotten.")
            return
        }
        defer { CommandMemory.record(said: utterance, app: app, window: window, actions: did, answer: shown.answer) }
        prefs = CommandMemory.preferences()
        inputTarget = await captureInputTarget()
        if let selection, !selection.isEmpty, let task = Self.selectionTask(utterance) {
            await transform(selection, instruction: utterance, show: task.shows || !editable)
            host.log(String(format: "command: selection task done in %.2f s", Date().timeIntervalSince(started)))
            return
        }
        // A request about someone or something in memory ("open Mom's photos") goes to the model, which sees it all.
        let quick = prefs.touches(utterance) ? nil : QuickCommands.parseAll(utterance)
        if quick == nil, prefs.touches(utterance) { host.log("command: mentions something in memory; the model handles it") }
        if let actions = quick {
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

    /// The matches, for the model to pick from: name, kind, folder, date, a line from inside, and the path to open.
    nonisolated static func describe(_ files: [FileCandidate], for query: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var lines = ["Files matching “\(query)”, best match first. Open the one the user asked for: open_file with its exact "
                     + "path. If none of them is it, reply saying so (or search_files to show them all)."]
        for (index, file) in files.enumerated() {
            let url = URL(fileURLWithPath: file.path)
            let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            var line = "\(index + 1). \(url.lastPathComponent) · \(file.kind) · in \(folder) · modified "
                + file.modified.formatted(date: .abbreviated, time: .omitted)
            if let excerpt = file.excerpt?.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""),
               !excerpt.isEmpty {
                line += " · “\(excerpt.prefix(140))”"
            }
            lines.append(line + "\n   path: \(file.path)")
        }
        return lines.joined(separator: "\n")
    }

    /// What to say when a command needs a model and there's none: Ollama isn't on this Mac and no cloud key worked.
    public nonisolated static let needsModel =
        "Commands like this need a model. Install Ollama, or add a Claude or OpenAI key in Commands & AI."

    /// The earlier file a query names: its path or exact name, or every word of the query found in the name.
    nonisolated static func earlierFile(_ query: String, recent: [String]) -> String? {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let asked = fold((query as NSString).lastPathComponent)
        let words = asked.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        return recent.first { name in
            let file = fold(name)
            return file == asked || (!words.isEmpty && words.allSatisfy { file.contains($0) })
        }
    }

    /// The user means the file from before: "it", "that", "again", "wahi", "phir se", or a word from its name.
    nonisolated static func pointsBack(_ utterance: String, to name: String) -> Bool {
        let text = QuickCommands.clean(utterance)
        if text.range(of: #"\b(it|that|this|same|again|previous|last|earlier|wahi|wohi|vahi|wo|woh|vo|voh|usko|use|usse|isko|ise|yahi|phir se|fir se|dobara|pichl[ia]|abhi wal[ia])\b"#,
                      options: .regularExpression) != nil { return true }
        // Case, accents and doubled letters folded: "aadhaar" said, "Aadhar.pdf" named.
        let fold: (String) -> String = { text in
            var out = ""
            for ch in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) where out.last != ch {
                out.append(ch)
            }
            return out
        }
        let generic: Set<String> = ["pdf", "pdfs", "doc", "docx", "file", "document", "copy", "final", "new", "untitled"]
        let nameWords = fold((name as NSString).deletingPathExtension)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count > 2 && !generic.contains($0) }
        let said = Set(fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return nameWords.contains { said.contains($0) }
    }

    /// The words that describe the file in what was said: "mujhe PDF kholkar do" → "PDF", "open my lease pdf" →
    /// "my lease pdf" (the file search drops "my" and reads "pdf" as the kind).
    nonisolated static func fileWords(_ utterance: String) -> String {
        let drop: Set<String> = [
            "open", "opens", "launch", "show", "find", "get", "bring", "up", "pull", "me", "please", "pls", "for", "can",
            "you", "could", "would", "murmur", "hey", "the", "a", "an", "mujhe", "muje", "mujhko", "humein", "hume",
            "ko", "do", "de", "dena", "dijiye", "dijie", "karo", "kar", "kare", "karein", "karna", "kholo", "khol",
            "kholkar", "kholke", "kholiye", "kholna", "kholdo", "dikhao", "dikha", "dikhaiye", "dhundo", "dhoondo",
            "dhundho", "dhoondho", "zara", "jara", "ek", "toh", "to", "na", "mera", "meri", "mere", "apna", "apni",
            "apne", "wala", "wali", "wale", "ka", "ki", "ke", "se", "hai",
        ]
        let words = QuickCommands.clean(utterance).split(separator: " ").map(String.init)
        let kept = words.filter { !drop.contains($0.lowercased()) }
        return kept.isEmpty ? utterance : kept.joined(separator: " ")
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
        // A change to what's being built ("add a login page", "make it dark", "run it"): the same session.
        if let session = CodingSession.current, !CodingSession.isNewProject(task) {
            return await followUp(task, in: session)
        }
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
        let approved = await allow(.coding, "Build this with \(helper.display)?",
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

    /// A request for the coding session already running: typed into its Terminal tab (or the session reopened).
    private func followUp(_ message: String, in session: CodingSession) async -> Outcome {
        host.progress("Sending it to \(session.assistant.display)…")
        let result = await session.send(message)
        host.log("command: coding follow-up → \(result.hasPrefix("Sent") ? "sent to the running session" : "reopened the session")")
        host.progress(result.hasPrefix("Sent") ? "Sent to \(session.assistant.display)" : result)
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
        """ + (prefs.notes.isEmpty ? "" : "\nWhat the user told you about themselves and how they like things (follow it "
            + "where it applies):\n" + prefs.notes.prefix(20).map { "- \($0)" }.joined(separator: "\n"))
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
        routing = true
        let now = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        var context = "Now: \(now) (\(TimeZone.current.identifier))."
        context += "\nFront app (where the user is): \(frontApp ?? "unknown")."
        if let title = ScreenControl.frontWindowTitle(), !title.isEmpty { context += " Its window: \"\(title.prefix(150))\"." }
        if let picked = MacActions.finderSelection() { context += "\nSelected in Finder:\n\(picked)" }
        if let memory = CommandMemory.workingSet() {
            context += "\nMemory (what \"she\", \"him\", \"it\", \"also\", \"again\" and \"that\" refer to):\n\(memory)"
        }
        if let session = CodingSession.current {
            context += "\nCoding session: \(session.summary) Requests about that project (\"add a login page\", "
                + "\"make it dark\", \"fix the error\", \"run it\", \"ask Claude to add tests\") go to it with "
                + "coding_followup, not build_with_agent. A new, different project is build_with_agent."
        }
        if let browser = BrowserControl.inFront(), let tab = await BrowserControl.currentTab(in: browser) {
            context += "\nBrowser tab in front: \(tab.title.prefix(120)) — \(tab.url.prefix(300))"
        }
        // "this video", "the first one", or anything said in Finder or a player: look at the screen before acting.
        let working = ScreenControl.workingApp()?.bundleIdentifier ?? ""
        let screenApps: Set<String> = ["com.apple.finder", MacActions.quickTime, "com.colliderli.iina", "org.videolan.vlc",
                                       "com.apple.Music", "com.apple.TV", "com.apple.Preview"]
        if selection?.isEmpty ?? true, Self.pointsAtScreen(utterance) || screenApps.contains(working) {
            context += "\n" + (await lookAtScreen())
        }
        if let selection, !selection.isEmpty {
            context += "\nSelected text (what \"this\", \"it\" and \"the selection\" mean):\n\"\"\"\n\(selection.prefix(8000))\n\"\"\""
        }
        let helpers = AssistantCLI.allCases.filter(\.isAllowed)
        let system = Self.systemPrompt(helpers: helpers) + "\n\n" + context
        let tools = Self.tools(helpers: helpers)
        var turns: [RouterTurn] = [.user(utterance)]
        var router = currentRouter()
        host.progress("Thinking…")
        var lastSignature = ""
        var repeats = 0
        // Whether anything beyond opening an app or a page has happened: "open saleshq.ai and summarise it" isn't
        // done when the page is open, however soon the model says so.
        var didMoreThanOpen = false
        var checksBeforeDone = 0
        var planChecks = 0
        var nudgedForTools = false
        let hasMoreSteps = Self.hasMoreThanOneStep(utterance)
        let wantsAnswer = Self.asksForInformation(utterance)
        let began = Date()
        var budget = maxSteps
        for step in 0..<stepCap {
            // A task list buys a few steps per item; nothing runs past the time cap.
            if !plan.isEmpty { budget = min(stepCap, max(maxSteps, plan.count * 6 + 10)) }
            if step >= budget || Date().timeIntervalSince(began) > timeCap {
                host.log("command: stopped at step \(step + 1) (budget \(budget), \(Int(Date().timeIntervalSince(began))) s)")
                await wrapUp(router: router, system: system + taskState, turns: turns, tools: tools)
                return
            }
            var answer: RouterReply?
            let asked = Date()
            let stepSystem = system + taskState
            do {
                answer = try await router.chat(system: stepSystem, turns: Self.compacted(turns), tools: tools)
                host.log(String(format: "command: %@ step %d took %.2f s", router.name, step + 1,
                                Date().timeIntervalSince(asked)))
            } catch {
                host.log("command: \(router.name) failed at step \(step + 1): \(error.localizedDescription)")
                RouterDiagnostics.lastError = error.localizedDescription   // a rejected key isn't asked again
                // Too slow, or the connection dropped: ask the same model once more before giving up on it.
                if let failure = error as? RouterError, case .unreachable = failure {
                    host.progress("Still working… (step \(step + 1))")
                    answer = try? await router.chat(system: stepSystem, turns: Self.compacted(turns), tools: tools)
                }
                // A cloud model that still fails (offline, bad key) hands over to the local model.
                if answer == nil, !(router is OllamaRouter) {
                    router = OllamaRouter(model: routerModel)
                    host.progress("\(error.localizedDescription) Using the local model…")
                    answer = try? await router.chat(system: stepSystem, turns: Self.compacted(turns), tools: tools)
                }
                if answer == nil {
                    if step == 0, searchInstead(utterance) { return }
                    // No model at all: say so plainly and open the page where one is set up.
                    if router is OllamaRouter, !OllamaProbe.isInstalled {
                        host.log("command: no model for this (Ollama isn't installed, no cloud key worked)")
                        host.showAnswer(Self.needsModel)
                        host.openModelSettings()
                        return
                    }
                    host.showAnswer(step == 0 ? error.localizedDescription
                        : "I stopped partway: \(error.localizedDescription) Try asking again.")
                    return
                }
            }
            guard let reply = answer else { return }
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
                if !text.isEmpty { host.showAnswer(text); return }
                // Nothing at all: ask once more rather than stop silently half-way.
                if nudgedForTools { await wrapUp(router: router, system: system + taskState, turns: turns, tools: tools); return }
                nudgedForTools = true
                turns.append(.user("Continue the request with tool calls: the next step, reply with the answer, or done."))
                continue
            }
            turns.append(.assistant(text: reply.text, calls: reply.calls))
            var finishedNow = false
            var results: [String] = []
            var changedScreen = false
            var looked = false
            for (index, call) in reply.calls.enumerated() {
                host.log("command: step \(step + 1) → \(call.name) \(call.arguments.mapValues(\.description))")
                // The task list still has open steps: done, or a final reply, would leave the request half done.
                if call.name == "done" || call.name == "reply", planChecks < 3, plan.contains(where: { !$0.done }) {
                    planChecks += 1
                    let open = plan.filter { !$0.done }.map { "[ ] \($0.text)" }.joined(separator: "\n")
                    host.log("command: \(call.name) with \(plan.filter { !$0.done }.count) steps open; going on")
                    turns.append(.toolResult(callID: call.id, name: call.name, content:
                        "Not finished: your task list still has open steps:\n\(open)\nDo them now. If one turned out "
                        + "unnecessary or impossible, call plan with the updated list (mark it [x] and say why in a note). "
                        + "Then give the final answer from your notes."))
                    continue
                }
                if call.name == "done", awaitingPick {
                    // "open_file" and "done" in one response: the matches came back, nothing has opened yet.
                    host.log("command: done before picking from the matches; asking for the pick")
                    turns.append(.toolResult(callID: call.id, name: call.name, content:
                        "Not done: nothing has opened yet. Pick the user's file from the matches above and call open_file "
                        + "with its exact path, or reply that none of them is it."))
                    continue
                }
                if call.name == "done" {
                    if checksBeforeDone < 2, let why = notDoneYet(utterance, step: step, checks: checksBeforeDone,
                                                                  didMoreThanOpen: didMoreThanOpen,
                                                                  hasMoreSteps: hasMoreSteps, wantsAnswer: wantsAnswer) {
                        // Check before stopping: show the model the request, where things stand and the screen.
                        checksBeforeDone += 1
                        host.log("command: done at step \(step + 1), checking it first (\(checksBeforeDone))")
                        let screen = await screenAfterChange(reply.calls.first?.name ?? "")
                        turns.append(.toolResult(callID: call.id, name: call.name, content: why + screen))
                        host.progress("Checking it's all done…")
                        continue
                    }
                    turns.append(.toolResult(callID: call.id, name: call.name, content: "ok"))
                    finishedNow = true
                    continue
                }
                // reply ends the command, so a reply with more steps after it in the same response is a progress
                // note ("Opening your post…"), not the answer: show it and go on.
                if call.name == "reply",
                   reply.calls[(index + 1)...].contains(where: { $0.name != "done" && $0.name != "reply" }) {
                    host.progress(String(call.arguments["text"]?.description.prefix(140) ?? ""))
                    turns.append(.toolResult(callID: call.id, name: call.name, content:
                        "Noted as progress, not shown as the answer: reply finishes the command, so keep it for the final answer."))
                    continue
                }
                if !Self.openingTools.contains(call.name) { didMoreThanOpen = true }
                let outcome = await execute(call.name, call.arguments)
                if outcome.finished { return }
                if call.name == "open_file" {
                    awaitingPick = outcome.result.hasPrefix("Files matching")
                } else if call.name == "reply" || call.name == "search_files" {
                    awaitingPick = false
                }
                results.append(outcome.result)
                // A look counts only if nothing changed the screen after it.
                if Self.screenChangingTools.contains(call.name) { changedScreen = true; looked = false }
                if call.name == "read_screen" || call.name == "browser_read" { looked = true }
                var content = outcome.result
                // The last call of a step that changed the screen carries a fresh look at it, so the model sees
                // where it is (a page that loaded, a dialog that opened) without spending a step to ask.
                if index == reply.calls.count - 1, changedScreen, !looked, !finishedNow {
                    content += await screenAfterChange(call.name)
                }
                turns.append(.toolResult(callID: call.id, name: call.name, content: content))
            }
            if !results.isEmpty { host.progress(results.last ?? "") }
            // Finished only when the model says so (done, or a tool that finishes: an answer, pasted text).
            // A step of actions alone ("open YouTube") is a step, not the end: the model goes on from what it sees.
            if finishedNow { return }
            // Going round in circles (the same calls again and again): stop rather than loop to the limit.
            let signature = reply.calls.map { call in
                call.name + call.arguments.keys.sorted().map { "\($0)=\(call.arguments[$0]?.description ?? "")" }.joined(separator: ",")
            }.joined(separator: "|")
            let browsing = reply.calls.allSatisfy { Self.browsingTools.contains($0.name) }
            repeats = signature == lastSignature && !browsing ? repeats + 1 : 0
            lastSignature = signature
            if repeats >= 2 {
                host.log("command: the same step three times; stopping")
                await wrapUp(router: router, system: system + taskState, turns: turns, tools: tools)
                return
            }
            if let current = plan.firstIndex(where: { !$0.done }) {
                host.progress("Step \(current + 1) of \(plan.count): \(plan[current].text.prefix(60))…")
            } else {
                host.progress("Working… (step \(step + 2))")
            }
        }
        host.log("command: stopped after \(stepCap) steps")
        await wrapUp(router: router, system: system + taskState, turns: turns, tools: tools)
    }

    /// Money moving: always asked, whatever was allowed.
    private static let moneyWords = #"(?i)\b(pay|payment|buy|purchase|place order|checkout|check out|transfer|send money|donate|subscribe)\b"#

    /// Whether to go ahead with an action of this kind: always allowed, allowed for this task, or the user's answer
    /// (which can allow it for the task or for good). Anything about money asks every time.
    private func allow(_ kind: Permission, _ title: String, _ detail: String) async -> Bool {
        let money = (title + " " + detail).range(of: Self.moneyWords, options: .regularExpression) != nil
        if !money, kind.alwaysAllowed {
            host.log("command: \(title) → allowed (always: \(kind.rawValue))")
            return true
        }
        if !money, taskApproved {
            host.log("command: \(title) → allowed (for this task)")
            return true
        }
        let answer = await host.approve(money ? nil : kind, title, detail)
        host.log("command: \(title) → \(answer)")
        switch answer {
        case .no: return false
        case .once: return true
        case .task: taskApproved = true; return true
        case .always: kind.alwaysAllowed = true; return true
        }
    }

    /// The start of a big task (its first plan): one question for the whole of it, so it can run on its own.
    private func askForTask() async {
        guard !askedForTask, !taskApproved else { return }
        askedForTask = true
        guard !Permission.allCases.allSatisfy(\.alwaysAllowed) else { return }
        let steps = plan.prefix(8).map { "• \($0.text)" }.joined(separator: "\n")
        let answer = await host.approve(nil, "Let Murmur do this on its own?",
            "\(steps)\n\nIt will click, type and use your apps without asking again until it's done. "
            + "Anything that pays or buys still asks.")
        host.log("command: run the task on its own → \(answer)")
        if answer == .task || answer == .always { taskApproved = true }
    }

    /// Moving through pages and lists: the same call again is progress (the next screenful), not a loop.
    private static let browsingTools: Set<String> = [
        "browser_scroll", "browser_read", "browser_back", "read_screen", "wait", "note", "plan",
    ]

    /// The task list and notes, added to the instructions on every step.
    private var taskState: String {
        guard !plan.isEmpty || !notes.isEmpty else { return "" }
        var lines: [String] = []
        if !plan.isEmpty {
            lines.append("\nYour task list (keep it current with plan; [x] done, [ ] to do):")
            lines += plan.map { "\($0.done ? "[x]" : "[ ]") \($0.text)" }
        }
        if !notes.isEmpty {
            lines.append("\nYour notes so far (the final answer comes from these):")
            var total = 0
            for note in notes.reversed() {
                total += note.count
                if total > 9000 { lines.append("- … earlier notes cut"); break }
                lines.append("- \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "[x] open the inbox\n[ ] open the HDFC email": the model's list as steps.
    nonisolated static func parsePlan(_ text: String) -> [PlanStep] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: #"^([-*•]|\d+[.)])\s*"#, with: "", options: .regularExpression)
            var done = false
            if let range = line.range(of: #"^\[(x|X|✓|✔)\]\s*"#, options: .regularExpression) {
                done = true; line.removeSubrange(range)
            } else if let range = line.range(of: #"^\[ ?\]\s*"#, options: .regularExpression) {
                line.removeSubrange(range)
            } else if line.hasPrefix("✓ ") || line.hasPrefix("✔ ") {
                done = true; line.removeFirst(2)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : PlanStep(text: String(line.prefix(160)), done: done)
        }
    }

    /// Why a command the model calls done isn't done yet, if it isn't: the model sees this and the screen, then goes
    /// on (or calls done again). Nil: it's done.
    private func notDoneYet(_ utterance: String, step: Int, checks: Int, didMoreThanOpen: Bool, hasMoreSteps: Bool,
                            wantsAnswer: Bool) -> String? {
        let asked = "The user asked: \"\(utterance)\"."
        if wantsAnswer {
            // An answer would have finished the command already: none has been given.
            return "Not done yet. \(asked) They want to be told something, and you haven't told them. Read what's "
                + "needed (browser_read, browser_scroll or browser_click to get to it, read_screen outside the browser), "
                + "then call reply with the actual answer: the numbers, names or text they asked for."
        }
        if hasMoreSteps, !didMoreThanOpen {
            return "Not done yet. \(asked) So far you only opened something. Do the rest now: to summarise, explain "
                + "or answer something about the page, use the text on the screen below (read again or scroll for "
                + "more) and reply with the answer. Then call done."
        }
        if step >= 1, checks == 0 {
            return "Before finishing, check the work. \(asked) Compare every part of it with the screen below. If "
                + "it's all done, call done again. If anything is missing or didn't work, do it now."
        }
        return nil
    }

    /// Out of steps, or going round in circles: rather than stop without a word, the model says what it found and
    /// what's left; failing that, the user is told it stopped.
    private func wrapUp(router: Router, system: String, turns: [RouterTurn], tools: [ToolSpec]) async {
        var turns = turns
        turns.append(.user("Stop here. Call reply now: in two or three sentences, what you found or did for the "
            + "request, with any answer you have, and what's still left to do."))
        let replyOnly = tools.filter { $0.name == "reply" }
        if let last = try? await router.chat(system: system, turns: Self.compacted(turns), tools: replyOnly),
           let call = last.calls.first(where: { $0.name == "reply" }) {
            host.showAnswer(call.arguments["text"]?.description ?? "")
            return
        }
        let text = ModelOutput.answer((try? await router.chat(system: system, turns: Self.compacted(turns), tools: []))?.text ?? "")
        host.showAnswer(text.isEmpty ? "I couldn't finish that one. Try asking again, or in smaller steps." : text)
    }

    // MARK: - Tools

    struct Outcome {
        let result: String
        /// The command is complete (an answer was shown or text was pasted).
        var finished = false
        /// The result was already shown to you.
        var shown = false
    }

    private func captureInputTarget() async -> InputTarget? {
        guard let app = ScreenControl.workingApp() else { return nil }
        var field: AXUIElement?
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier { field = element }
        }
        var tab: String?
        if let browser = BrowserControl.browser(for: app) { tab = await BrowserControl.currentTab(in: browser)?.url }
        return InputTarget(app: app, field: field, tab: tab)
    }

    /// Back to where you were typing: the tab (if the command moved to another one), the app, the field.
    private func backToInput() async {
        guard let target = inputTarget else { return }
        if let tab = target.tab, let url = URL(string: tab), let id = target.app.bundleIdentifier,
           let browser = BrowserControl.running(id), await BrowserControl.currentTab(in: browser)?.url != tab {
            _ = await BrowserControl.show(url, in: browser, reuse: false)
        }
        if !target.app.isActive {
            target.app.activate(options: [])
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if let field = target.field {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    /// No browser named and none in use yet: the one you told Murmur to use for links.
    private func preferredBrowser() {
        guard lastBrowser == nil, let name = prefs.browser else { return }
        useBrowser(.string(name))
    }

    /// "… on chrome": use that browser for this and the next web steps.
    private func useBrowser(_ value: JSONValue?) {
        guard let name = value?.description.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let app = AppCatalog.shared.resolve(name), MacActions.isBrowser(app) else { return }
        lastBrowser = app
    }

    /// Runs a tool, and remembers what it did for the next command.
    private func execute(_ tool: String, _ args: [String: JSONValue]) async -> Outcome {
        let outcome = await perform(tool, args)
        did.append(CommandMemory.Action(tool: tool, args: args.mapValues { String($0.description.prefix(200)) },
                                        result: String(outcome.result.prefix(300))))
        return outcome
    }

    private func perform(_ tool: String, _ args: [String: JSONValue]) async -> Outcome {
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
            guard await allow(.quitting, title, "It will ask about any unsaved work, as ⌘Q does.") else {
                return Outcome(result: "You cancelled quitting \(name).", finished: true)
            }
            return Outcome(result: MacActions.quitApp(name))
        case "hide_app": return Outcome(result: MacActions.hideApp(text("name")))
        case "find_apps": return Outcome(result: MacActions.findApps(text("query")))
        case "list_running_apps": return Outcome(result: MacActions.runningApps())
        case "open_folder": return Outcome(result: MacActions.openFolder(text("name")))
        case "open_file":
            // The file from an earlier command (memory lists it as in play) only when the user points back at it
            // ("open it again", "that PDF", its name). "Open the PDF" or "mujhe PDF kholkar do" is a new request: the
            // model used to hand back the remembered file, so every PDF request opened the same one.
            var query = text("query")
            var afresh = false
            let picked = offered.contains((query as NSString).expandingTildeInPath)
            if !picked, let earlier = Self.earlierFile(query, recent: CommandMemory.recentFiles()),
               !Self.pointsBack(utterance, to: earlier) {
                query = Self.fileWords(utterance)
                afresh = true
                host.log("command: \(earlier) is the file from before, but this asks for one afresh: finding “\(query)”")
            }
            // A file seen on the screen or selected in Finder, or one the model picked from the matches: open that one
            // (by its path, or its exact name). play: start a video or song.
            if !afresh {
                var path = (query as NSString).expandingTildeInPath
                if !path.hasPrefix("/"), let exact = await MacActions.findByName(query) { path = exact }
                if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                    if text("play") == "true", MacActions.isPlayable(path) {
                        return Outcome(result: await MacActions.play(file: path))
                    }
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    return Outcome(result: "Opened \(URL(fileURLWithPath: path).lastPathComponent).")
                }
            }
            // A description: the model sees the search's matches and picks, with everything it knows (what was
            // said, memory, the screen). A clear winner opens at once; so does the quick path's top match.
            host.progress("Finding “\(query)”…")
            let found = routing ? await host.findFiles(query) : []
            let clear = found.count == 1 || (found.count > 1 && found[0].score >= found[1].score * 1.4)
            guard found.count > 1, !clear else {
                return Outcome(result: await host.openFile(query), finished: true)
            }
            let matches = Array(found.prefix(5))
            offered = Set(matches.map(\.path))
            host.log("command: \(matches.count) close matches for “\(query)”; the model picks")
            return Outcome(result: Self.describe(matches, for: query))
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
            // The user's name isn't added: a document that mentions them a lot (a handover, a contract) then outranked
            // the Aadhaar or PAN card asked for.
            host.searchFiles(query)
            return Outcome(result: "Showing file search results for \"\(query)\".", finished: true, shown: true)
        case "open_url":
            useBrowser(args["browser"])
            preferredBrowser()
            guard let url = MacActions.webAddress(text("url")) else {
                return Outcome(result: "That doesn't look like a web address.")
            }
            return Outcome(result: await showPage(url, opened: "Opened \(url.host ?? url.absoluteString)"))
        case "web_search":
            useBrowser(args["browser"])
            preferredBrowser()
            guard let url = MacActions.webSearchAddress(text("query")) else { return Outcome(result: "Couldn't build the search.") }
            return Outcome(result: await showPage(url, opened: "Searching the web for \"\(text("query"))\""))
        case "set_volume": return Outcome(result: MacActions.setVolume(Int(args["percent"]?.number ?? 50)))
        case "change_volume": return Outcome(result: MacActions.changeVolume(by: text("direction") == "down" ? -15 : 15))
        case "mute":
            let on = text("on") != "false"
            return Outcome(result: MacActions.mute(on))
        case "brightness": return Outcome(result: MacActions.brightness(up: text("direction") != "down"))
        case "lock_screen": return Outcome(result: MacActions.lockScreen())
        case "media_control":
            let action = text("action")
            // Where you are first: Finder's selected video, the player in front, the page in front. Then a page this
            // command opened, or the browser you used last. Anything else: the media keys (they only toggle).
            if action == "pause" || action == "play", let done = await mediaWhereYouAre(action) {
                return Outcome(result: done)
            }
            return Outcome(result: MacActions.media(action))
        case "set_brightness":
            return Outcome(result: await MacActions.setBrightness(Int(args["percent"]?.number ?? 50)))
        case "set_bluetooth":
            host.progress("Switching Bluetooth…")
            return Outcome(result: await MacActions.setBluetooth(text("on") != "false"))
        case "set_wifi":
            host.progress("Switching Wi-Fi…")
            return Outcome(result: await MacActions.setWiFi(text("on") != "false"))
        case "screenshot": return Outcome(result: MacActions.screenshot())
        case "list_shortcuts": return Outcome(result: await MacActions.listShortcuts())
        case "run_shortcut":
            let name = text("name")
            guard await allow(.shortcuts, "Run the shortcut \"\(name)\"?", "Shortcuts can change things on your Mac.") else {
                return Outcome(result: "You cancelled the shortcut.", finished: true)
            }
            host.progress("Running \(name)…")
            return Outcome(result: await MacActions.runShortcut(name, input: args["input"]?.description))
        case "ask_claude", "ask_codex":
            let helper: AssistantCLI = tool == "ask_claude" ? .claude : .codex
            let task = text("task")
            guard helper.isAllowed else { return Outcome(result: "\(helper.display) isn't allowed in Murmur's menu.") }
            let approved = await allow(.coding, "Ask \(helper.display)?",
                                     "Murmur will send this to \(helper.display) (uses your subscription):\n\n\(task.prefix(600))")
            guard approved else { return Outcome(result: "You declined asking \(helper.display).", finished: true) }
            host.progress("Asking \(helper.display)…")
            let answer = await helper.run(task)
            return Outcome(result: "\(helper.display) answered:\n\(answer.prefix(6000))")
        case "coding_followup":
            guard let session = CodingSession.current else {
                return await build(text("message"), helper: "", folderName: "")
            }
            return await followUp(text("message"), in: session)
        case "build_with_agent":
            return await build(text("task"), helper: text("helper"), folderName: text("folder_name"))
        case "open_settings": return Outcome(result: MacActions.openSettings(text("pane")))
        case "site_search":
            useBrowser(args["browser"])
            preferredBrowser()
            guard let url = MacActions.siteSearchAddress(text("site"), text("query")) else {
                return Outcome(result: "Couldn't build the search.")
            }
            return Outcome(result: await showPage(url, opened: "Searching \(text("site")) for \"\(text("query"))\""))
        case "browser_read":
            guard let browser = browserHere() else {
                return Outcome(result: "No browser is in front (the user is in \(ScreenControl.workingApp()?.localizedName ?? "another app")): read_screen to see it, or open_url to open a page.")
            }
            host.progress("Reading the page…")
            if await canScript(browser), case .success(let page) = await BrowserControl.read(in: browser) {
                host.log("command: read the page in \(browser.name): \(page.count) characters")
                return Outcome(result: page)
            }
            return Outcome(result: await ScreenControl.read())
        case "browser_click":
            guard let browser = browserHere() else {
                return Outcome(result: "No browser is in front (the user is in \(ScreenControl.workingApp()?.localizedName ?? "another app")): use read_screen and click, or open_url first.")
            }
            let words = text("text")
            if words.range(of: Self.riskyWords, options: .regularExpression) != nil {
                guard await allow(.clicks, "Click “\(words)”?", "This may send, post or delete something.") else {
                    return Outcome(result: "You said no to clicking \(words).", finished: true)
                }
            }
            host.progress("Clicking \(words)…")
            if await canScript(browser) { return Outcome(result: await BrowserControl.click(words, in: browser)) }
            return Outcome(result: await ScreenControl.click(labeled: words))
        case "browser_type":
            guard let browser = browserHere() else {
                return Outcome(result: "No browser is in front (the user is in \(ScreenControl.workingApp()?.localizedName ?? "another app")): use read_screen and click, or open_url first.")
            }
            host.progress("Typing…")
            let submit = text("submit") == "true"
            if await canScript(browser) {
                return Outcome(result: await BrowserControl.type(text("text"), into: text("field"), submit: submit, in: browser))
            }
            // The page can't be scripted: click into the field and type, as a person would.
            guard await ScreenControl.focusField(named: text("field")) else {
                return Outcome(result: "There's no field to type into on this page.")
            }
            host.pasteHere(text("text"))
            try? await Task.sleep(nanoseconds: 350_000_000)
            if submit {
                _ = ScreenControl.press("return")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return Outcome(result: "Typed it\(submit ? " and pressed Return" : "").")
        case "browser_scroll":
            guard let browser = browserHere() else {
                return Outcome(result: "No browser is in front (the user is in \(ScreenControl.workingApp()?.localizedName ?? "another app")): use read_screen and click, or open_url first.")
            }
            if await canScript(browser) { return Outcome(result: await BrowserControl.scroll(text("direction"), in: browser)) }
            let keys = ["up": "pageup", "top": "cmd+up", "bottom": "cmd+down"][text("direction").lowercased()] ?? "pagedown"
            NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first?.activate()
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = ScreenControl.press(keys)
            try? await Task.sleep(nanoseconds: 500_000_000)
            return Outcome(result: "Scrolled \(text("direction")).")
        case "browser_tabs":
            guard let browser = browserHere() else {
                return Outcome(result: "No browser is in front (the user is in \(ScreenControl.workingApp()?.localizedName ?? "another app")): use read_screen and click, or open_url first.")
            }
            if await canScript(browser) { return Outcome(result: await BrowserControl.tabs(in: browser)) }
            return Outcome(result: "Can't list \(browser.name)'s tabs right now. press_keys cmd+1 … cmd+9 switches to a tab by position.")
        case "browser_switch_tab":
            guard let browser = browserHere() else {
                return Outcome(result: "No browser is in front (the user is in \(ScreenControl.workingApp()?.localizedName ?? "another app")): use read_screen and click, or open_url first.")
            }
            if await canScript(browser) { return Outcome(result: await BrowserControl.switchTab(text("tab"), in: browser)) }
            if let number = Int(text("tab")), (1...9).contains(number) {
                NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first?.activate()
                try? await Task.sleep(nanoseconds: 250_000_000)
                return Outcome(result: ScreenControl.press("cmd+\(number)"))
            }
            return Outcome(result: "Can't find tabs by name right now. press_keys cmd+1 … cmd+9 switches by position.")
        case "run_applescript":
            let script = args["script"]?.description ?? ""
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Outcome(result: "No script given.")
            }
            if MacActions.scriptIsRisky(script) {
                let purpose = text("purpose")
                let title = purpose.isEmpty ? "Run this script?" : purpose.capitalizedFirst + "?"
                guard await allow(.scripts, title, String(script.prefix(1200))) else {
                    return Outcome(result: "The user chose not to run it.", finished: true)
                }
            }
            host.progress(text("purpose").isEmpty ? "Working in the app…" : text("purpose") + "…")
            let result = await MacActions.appleScript(source: script)
            host.log("command: ran an AppleScript → \(result.hasPrefix("Script error") ? "error" : "ok")")
            return Outcome(result: result)
        case "read_screen":
            // In a browser, the page itself says more than its window does.
            if let browser = BrowserControl.inFront(), await canScript(browser),
               case .success(let page) = await BrowserControl.read(in: browser) {
                host.log("command: read the page in \(browser.name): \(page.count) characters")
                return Outcome(result: page)
            }
            host.progress("Looking at the screen…")
            let screen = await ScreenControl.read()
            let controls = screen.split(separator: "\n").filter { $0.hasPrefix("[") }.count
            host.log("command: read the screen: \(screen.contains("Text on screen:") ? "text and " : "no text, ")\(controls) things to press")
            return Outcome(result: screen)
        case "click":
            let id = Int(args["id"]?.number ?? 0)
            let what = ScreenControl.name(of: id) ?? "[\(id)]"
            if what.range(of: Self.riskyWords, options: .regularExpression) != nil {
                guard await allow(.clicks, "Click \(what)?", "This may send, post or delete something.") else {
                    return Outcome(result: "You said no to clicking \(what).", finished: true)
                }
            }
            host.progress("Clicking \(what)…")
            return Outcome(result: await ScreenControl.click(id))
        case "type_text":
            let words = text("text")
            // Already sent by send_message: typing it again would send it twice.
            if text("submit") == "true",
               sentMessages.contains(where: { $0.trimmingCharacters(in: .whitespaces) == words.trimmingCharacters(in: .whitespaces) }) {
                host.log("command: not sending the same message twice")
                return Outcome(result: "That message was already sent. Don't send it again; call done.")
            }
            if let id = args["into"]?.number, id > 0 {
                _ = await ScreenControl.focus(Int(id))
            }
            if text("submit") == "true", !(await mayPressReturn("return")) {
                return Outcome(result: "You chose not to send it.", finished: true)
            }
            host.pasteHere(words)
            try? await Task.sleep(nanoseconds: 350_000_000)
            if text("submit") == "true" {
                _ = ScreenControl.press("return")
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            return Outcome(result: "Typed \(words.count) characters\(text("submit") == "true" ? " and pressed Return" : "").")
        case "press_keys":
            guard await mayPressReturn(text("keys")) else {
                return Outcome(result: "You chose not to send it.", finished: true)
            }
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
            // Into the box you were typing in, even if the command went elsewhere to get the text.
            await backToInput()
            host.pasteHere(text("text"))
            return Outcome(result: "Pasted.", finished: true, shown: true)
        case "read_clipboard":
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            return Outcome(result: copied.isEmpty ? "The clipboard has no text."
                : "Clipboard (\(copied.count) characters):\n\(copied.prefix(8000))")
        case "copy_text":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text("text"), forType: .string)
            return Outcome(result: "Copied \(text("text").count) characters to the clipboard.")
        case "paste_clipboard":
            // What's on the clipboard (with its formatting), into the box you were typing in.
            guard NSPasteboard.general.pasteboardItems?.isEmpty == false else {
                return Outcome(result: "The clipboard is empty.")
            }
            await backToInput()
            _ = ScreenControl.press("cmd+v")
            try? await Task.sleep(nanoseconds: 300_000_000)
            return Outcome(result: "Pasted the clipboard into \(inputTarget?.app.localizedName ?? "the app").",
                           finished: true, shown: true)
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
        case "calendar_events":
            host.progress("Reading your calendar…")
            return Outcome(result: await AppData.events(start: text("start"), days: Int(args["days"]?.number ?? 1),
                                                         search: text("search")))
        case "reminders_list":
            host.progress("Reading your reminders…")
            return Outcome(result: await AppData.reminders(search: text("search"), completed: text("completed") == "true"))
        case "remember":
            let result = CommandMemory.remember(subject: text("subject"), fact: text("fact"))
            host.progress(result)
            return Outcome(result: result)
        case "forget_fact":
            return Outcome(result: CommandMemory.unremember(text("about")))
        case "recall":
            return Outcome(result: CommandMemory.recall(text("query"), kind: text("kind"), days: args["days"]?.number ?? 30))
        case "app_dictionary":
            return Outcome(result: await AppData.scriptingDictionary(text("app")))
        case "send_message":
            let said = text("to"), body = text("text")
            // "Mom" → Roma; no app named → where Roma is messaged (what you said, else what Murmur noticed).
            let to = prefs.person(said)
            let app = !text("app").isEmpty ? text("app")
                : prefs.chatApp(for: to) ?? ScreenControl.workingApp()?.localizedName ?? "Messages"
            guard !to.isEmpty, !body.isEmpty else { return Outcome(result: "Who should it go to, and what should it say?") }
            guard await allow(.messages, "Send this to \(to) on \(app)?", "“\(body)”") else {
                return Outcome(result: "You chose not to send it.", finished: true)
            }
            messageApproved = true
            host.progress("Sending to \(to)…")
            let result = await Messaging.send(body, to: to, in: app, paste: host.pasteHere)
            host.log("command: send_message → \(result.prefix(160))")
            if result.hasPrefix("Sent") { sentMessages.append(body) }
            return Outcome(result: result)
        case "reply":
            host.showAnswer(text("text"))
            return Outcome(result: "Shown.", finished: true, shown: true)
        case "plan":
            let steps = Self.parsePlan(text("steps"))
            guard !steps.isEmpty else { return Outcome(result: "Write one step per line, [x] for done and [ ] for to do.") }
            let before = plan.count
            plan = Array(steps.prefix(25))
            let open = plan.filter { !$0.done }.count
            host.log("command: plan \(before == 0 ? "made" : "updated"): \(plan.count) steps, \(open) open")
            if before == 0, plan.count >= 3 { await askForTask() }
            if let current = plan.firstIndex(where: { !$0.done }) {
                host.progress("Step \(current + 1) of \(plan.count): \(plan[current].text.prefix(60))…")
            }
            return Outcome(result: "Task list saved: \(plan.count) steps, \(open) to do. It's shown to you on every step.")
        case "note":
            let note = text("text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { return Outcome(result: "Nothing to note.") }
            notes.append(String(note.prefix(700)))
            if notes.count > 60 { notes.removeFirst(notes.count - 60) }
            return Outcome(result: "Noted (\(notes.count) notes).")
        case "browser_back":
            guard let browser = browserHere() else {
                return Outcome(result: "No browser is in front: use press_keys cmd+[ in the app, or open the page again.")
            }
            if await canScript(browser) {
                _ = await BrowserControl.evaluate("history.back(); 'ok'", in: browser)
            } else {
                NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first?.activate()
                try? await Task.sleep(nanoseconds: 250_000_000)
                _ = ScreenControl.press("cmd+[")
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            return Outcome(result: "Went back to the previous page.")
        default:
            return Outcome(result: "Unknown tool \(tool).")
        }
    }

    /// The browser the page tools act in: the one in front, or the one this command opened a page in. Not the
    /// browser you used last: with another app in front, its old page isn't what you mean.
    private func browserHere() -> BrowserControl.Browser? {
        if let front = BrowserControl.inFront() { return front }
        if openedPage || lastBrowser != nil { return BrowserControl.running(browserInUse) }
        return nil
    }

    /// Return in a chat app sends what's typed: the user says yes first, unless they already did for this message.
    private func mayPressReturn(_ keys: String) async -> Bool {
        guard ["return", "enter"].contains(keys.lowercased().trimmingCharacters(in: .whitespaces)), !messageApproved,
              let app = ScreenControl.workingApp(), let id = app.bundleIdentifier, Messaging.apps.contains(id) else {
            return true
        }
        let yes = await allow(.messages, "Send this message?", "Pressing Return in \(app.localizedName ?? "this app") sends what's typed.")
        if yes { messageApproved = true }
        return yes
    }

    /// Play or pause what the user means, where they are: Finder's selected video or song, the player in front, the
    /// page in front; then a page this command opened or the browser used last (for "pause the video" said from
    /// another app). Nil: nothing there, so the media keys.
    private func mediaWhereYouAre(_ action: String) async -> String? {
        let working = ScreenControl.workingApp()
        // Finder: the selected video or song. Nothing playable selected: the media keys.
        if working?.bundleIdentifier == "com.apple.finder" {
            if action == "play", let first = MacActions.finderSelection()?.split(separator: "\n").first.map({ String($0) }),
               MacActions.isPlayable(first) {
                return await MacActions.play(file: first)
            }
            return nil
        }
        // A player in front (QuickTime, IINA, VLC, Music, Spotify, or any app that plays video or audio): it, and
        // only it. Never a browser in the background.
        if let working, MacActions.isMediaPlayer(working) {
            if let done = await MacActions.controlPlayer(working, action) { return done }
            ScreenControl.raiseViewedWindow(of: working)
            working.activate()
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = ScreenControl.press("space")
            host.log("command: media → \(working.localizedName ?? "player") (space)")
            return "\(action == "play" ? "Played" : "Paused") it in \(working.localizedName ?? "the player")."
        }
        // A browser in front: the video on the page you're looking at; if the page can't be scripted, its own key
        // in that window (YouTube: k; most players: space). The media key would go to whatever played last.
        if let working, let browser = BrowserControl.browser(for: working) {
            if await canScript(browser), let done = await BrowserControl.media(action, in: browser) { return done }
            let address = await BrowserControl.currentTab(in: browser)?.url ?? ""
            ScreenControl.raiseViewedWindow(of: working)
            working.activate()
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = ScreenControl.press(address.contains("youtube.com") ? "k" : "space")
            return "\(action == "play" ? "Played" : "Paused") the video in \(browser.name)."
        }
        // Somewhere else (an editor, a chat app): "pause the video" means the one playing in a browser, if any.
        if let browser = BrowserControl.target(preferred: browserInUse), await canScript(browser),
           let done = await BrowserControl.media(action, in: browser) {
            return done
        }
        return nil
    }

    /// What "this" points at, for a request that points at the screen: Finder's selection, and the front app's screen
    /// (the page itself, in a browser), with its buttons and links to act on.
    private func lookAtScreen() async -> String {
        var parts: [String] = []
        if let browser = BrowserControl.inFront(), await canScript(browser),
           case .success(let page) = await BrowserControl.read(in: browser, limit: 3500) {
            parts.append("The page in front:\n" + page)
        } else {
            parts.append("The screen in front:\n" + (await ScreenControl.read()))
        }
        host.log("command: the request points at the screen; looked first")
        return "The request points at something on the screen (\"this\", \"that\", \"here\"). What's there now:\n"
            + parts.joined(separator: "\n\n")
    }

    /// Puts a page up for this command without piling up tabs: a tab that already has it comes to the front, and once
    /// this command has opened a page, the next ones load in that same tab. Otherwise a new tab, as before.
    private func showPage(_ url: URL, opened: String) async -> String {
        let bundleID = lastBrowser?.bundleID ?? openedIn ?? BrowserControl.defaultBrowserID
        if let browser = BrowserControl.running(bundleID),
           let done = await BrowserControl.show(url, in: browser, reuse: openedPage) {
            openedIn = browser.bundleID
            openedPage = true
            host.log("command: \(done)")
            return done
        }
        openedIn = bundleID
        openedPage = true
        MacActions.open(url, in: lastBrowser)
        return opened + (lastBrowser.map { " in \($0.name)" } ?? "") + "."
    }

    /// Whether Murmur can work inside `browser`'s pages, checked once per command. When the browser's "Allow
    /// JavaScript from Apple Events" is off, Murmur offers once to turn it on (Chrome-family browsers, through their
    /// menu); declined or not possible, the browser tools work through the screen instead, silently.
    private func canScript(_ browser: BrowserControl.Browser) async -> Bool {
        if let known = pageAccess[browser.bundleID] { return known }
        if BrowserControl.unavailable.contains(browser.bundleID) {
            pageAccess[browser.bundleID] = false
            return false
        }
        var access = await BrowserControl.probe(browser)
        if access == .switchOff, !browser.safari {
            let yes = await host.confirm("Let Murmur work inside \(browser.name) pages?",
                "Murmur will turn on \(browser.name)'s “Allow JavaScript from Apple Events” (View → Developer), so it can "
                + "read pages and click and type in them directly. You can turn it off there at any time.")
            if yes, await BrowserControl.enablePageAccess(in: browser) {
                access = .ok
                host.log("command: turned on page access in \(browser.name)")
            }
        }
        let usable = access == .ok
        if !usable {
            BrowserControl.unavailable.insert(browser.bundleID)
            BrowserControl.explainOnce(access, browser)
            host.log("command: \(browser.name) pages can't be scripted (\(access)); working through the screen")
        }
        pageAccess[browser.bundleID] = usable
        return usable
    }

    /// The screen after an action: a moment for it to settle (a web page takes longer), then what's on it.
    private func screenAfterChange(_ tool: String) async -> String {
        let web: Set<String> = ["open_url", "web_search", "site_search"]
        try? await Task.sleep(nanoseconds: web.contains(tool) ? 2_000_000_000 : 700_000_000)
        if let browser = BrowserControl.inFront(), await canScript(browser),
           case .success(let page) = await BrowserControl.read(in: browser, limit: 3500) {
            return "\n\nThe page now:\n\(page)"
        }
        let screen = await ScreenControl.read()
        return "\n\nThe screen now:\n\(screen)"
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
            guard await allow(.commands, "Run this command?", detail) else {
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
            "- Respond only with tool calls. Work in steps until the WHOLE request is done: each response does what "
                + "it can (several calls in order are fine), then you see the results and the screen, and go on. "
                + "When everything the user asked for is done, call done. If one response does it all (\"open "
                + "Slack\"), put done at the end of that same response.",
            "- Apps: open_app, quit_app, hide_app, find_apps, list_running_apps. Use the app name the user said.",
            "- Opening a file (\"open my resume pdf\"): open_file with the description in the user's words. A file "
                + "from memory (\"In play\") only when the user points back to it (\"open it again\", \"that PDF\"); "
                + "\"open the PDF\" is a new request, not the last file opened.",
            "- The user may speak Hinglish (Hindi in English letters) or Hindi. Understand it like English: kholo / "
                + "kholkar do / khol do = open; band karo = close or quit; chalao / bajao / play karo = play; bhejo = "
                + "send; dhundo / search karo = find; dikhao = show; batao = tell; badhao / kam karo = turn up / down; "
                + "mujhe = for me. \"Mujhe PDF kholkar do\" → open_file \"PDF\". Messages keep the user's own words "
                + "and language.",
            "- Files: \"search\", \"find\" or \"look for\" means the user's own files on this Mac: search_files. "
                + "open_folder for standard folders.",
            "- Web: web_search only when the user says web, online, internet or Google, or after opening a browser; "
                + "open_url for a site.",
            "- Mac settings and updates: open_settings (\"check for updates\" → software update); then read_screen "
                + "and click if the user asked for a specific switch.",
            "- System: set_volume, change_volume, mute, brightness, lock_screen, screenshot, media_control (pause or resume a playing video or song, next, previous), set_brightness, set_bluetooth, set_wifi "
                + "(switch these directly; don't open Settings for them).",
            "- Shortcuts: list_shortcuts, run_shortcut.",
            "- Building or changing software (an app, website, script, API, project; \"create a React app…\"): call "
                + "build_with_agent with the user's full request. It starts Claude Code or Codex in Terminal to build "
                + "it. Never web_search or open a browser for that.",
            "- You can see and use the front app like a person: read_screen shows the text in its window and lists "
                + "its buttons, links and fields as [n]. To answer what's on the screen (\"what's on my screen\", "
                + "\"summarise this page\", \"what does this error say\"), read_screen, then reply from its text. "
                + "click n; type_text (into field n, submit true to press Return); press_keys "
                + "(\"return\", \"cmd+l\", \"cmd+n\", \"down\", \"pagedown\"); wait. Use them for any task the other "
                + "tools don't cover. After an action that changes the screen you are shown the new screen with its "
                + "[n] numbers; use only numbers from the latest screen. Keep going until the whole request is done, "
                + "then call done.",
            "- In the browser (Chrome, Safari, Brave, Edge, Arc), use the browser tools: they work inside the page and "
                + "are faster and surer than read_screen. browser_read gives the page's address, full text, fields and "
                + "links/buttons; browser_click clicks a link or button by its words (\"the first video\": click its "
                + "title words); browser_type types into a field by its name (submit true to search or send the form); "
                + "browser_scroll (down, up, top, bottom) for more of the page; browser_tabs and browser_switch_tab; "
                + "media_control pauses or plays the page's video. To summarise or answer about a page: browser_read, "
                + "then reply from its text. If a browser tool says it can't work in pages, use read_screen and click.",
            "- Apps that can be scripted (Notes, Reminders, Calendar, Mail, Messages, Contacts, Finder, Music, "
                + "Safari, System Events…): run_applescript does it directly, without clicking: e.g. tell application "
                + "\"Reminders\" to make new reminder with properties {name:\"Call Mom\", remind me date:(current date) + "
                + "3600}; tell application \"Notes\" to make new note with properties {body:\"<h1>Title</h1>text\"}; "
                + "tell application \"Calendar\" to get summary of every event of calendar 1 whose start date > (current "
                + "date); tell application \"Mail\" to make new outgoing message with properties {subject:…, content:…, "
                + "visible:true}; tell application \"System Events\" to tell appearance preferences to set dark mode to "
                + "true; tell application \"Finder\" to … . Prefer it over clicking through an app. Scripts that send, "
                + "delete, quit or empty something are shown to the user first. If a script fails, read the error, fix "
                + "it and try again, or use the app's screen instead.",
            "- Websites: open the result page directly when you can: site_search (YouTube, Amazon, GitHub, Maps, "
                + "Wikipedia…) or open_url with a search URL; then browser_read and browser_click what the user wants "
                + "(\"the first video\": the first link that is a video title, not an ad or a channel). YouTube sorted "
                + "by views (\"the most viewed\"): open_url https://www.youtube.com/results?search_query=<words>&sp=CAM%253D "
                + "then click the first video title; if the page isn't sorted, use its Filters button, Sort by, View "
                + "count. To play a video, click its title.",
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
            "- Finish the WHOLE request, by the quickest route. A request to be told something (\"get me the updates "
                + "on my latest LinkedIn post\", \"how many…\", \"what's…\") is only done when you call reply with the "
                + "actual answer: the numbers, names or text. reply ends the command: use it once, for the final "
                + "answer, never to describe a step.",
            "- Memory first: before acting, check the memory below. Use the user's name for their own documents, "
                + "nicknames for people (\"Mom\" is who they said), their chosen browser and apps, and every preference "
                + "they told you, in every step and every search.",
            "- Work where the user is. The front app below (its window, Finder's selection, the browser tab when a "
                + "browser is in front, and the screen when the request points at it) is where \"this\", \"that\", "
                + "\"the first one\", \"play\" and \"open\" happen, unless the user names another app or a website. "
                + "Finder: videos, songs and documents are the user's own files: open_file with the file's path or "
                + "its exact name from the screen (play true to play a video or song); \"play this\" with a video "
                + "selected: media_control play. A player (QuickTime, Music, Spotify, IINA, VLC): media_control. A "
                + "browser: the page tools. Go to YouTube or the web only when the user names a site or asks to search "
                + "online; never web_search or search_files for something already on the screen.",
            "- Information inside apps: get the data, don't just open the app. Calendar: calendar_events (\"what's on "
                + "my calendar tomorrow\", \"my meetings this week\": start and days from today's date above). "
                + "Reminders: reminders_list. Other apps that can be scripted (Mail, Notes, Messages, Contacts, Music, "
                + "Safari, Finder, Photos, Things, OmniFocus…): run_applescript that reads it and returns text, e.g. "
                + "tell application \"Mail\" to get {subject, sender} of messages 1 thru 10 of inbox; call "
                + "app_dictionary first when unsure of the app's words. Apps that can't be scripted (WhatsApp, Slack, "
                + "Teams, most Electron apps): open_app, read_screen, then click and scroll to the right view and read "
                + "again. Then reply with the details asked for.",
            "- Personal facts and preferences: when the user tells you something lasting about themselves or how they "
                + "like things done (\"remember that Mom is Roma on WhatsApp\", \"from now on open links in Chrome\", "
                + "\"keep my messages short\", \"call me Shubham\"), call remember (the same subject again replaces it; "
                + "the user's own name goes under subject \"my name\" as \"My name is <full name>\"; "
                + "forget_fact drops one), then reply in a few words. \"Remind me to…\" is a reminder, not this. Follow "
                + "what the user told you over everything; use what was noticed from their commands when they don't say.",
            "- The user's own documents (\"my resume\", \"my Aadhaar card\", \"my PAN card\", \"my passport\"): open_file "
                + "with what the document is (\"Aadhaar card\", \"PAN card\"), not the user's name: a name matches every "
                + "file about them. When the matches come back, pick the user's own one (their name in it helps tell).",
            "- Memory: the latest commands and what's in play are below. For anything further back (\"what did I send "
                + "Roma yesterday\", \"open the file from this morning\", \"which video did I watch\"), call recall.",
            "- Follow-ups: a request that continues an earlier command (listed below) uses its person, app, file or "
                + "page. \"And also ask when she's coming back\" after messaging Roma on WhatsApp → send_message to Roma "
                + "on WhatsApp with that question; \"play it\" after opening a video → play that video; \"do it again\" → "
                + "repeat it.",
            "- Messages to people (\"send a message to Riya on WhatsApp saying…\", \"text Mom that I'm late\", \"tell "
                + "the team on Slack…\"): send_message with the app, who it's for and the message in the user's words "
                + "(fix only obvious transcription slips). It asks the user first. If its result says to finish on the "
                + "screen, do that. Never just type the request into the box the user is in.",
            "- Copy and paste: \"paste what I copied\" → paste_clipboard. \"Copy the text from the other page/app and paste "
                + "it here\" → get the text (browser_switch_tab or open_app, then browser_read or read_screen; or select it "
                + "and press_keys cmd+c, then read_clipboard), then insert_text with exactly that text: it goes back to "
                + "the box the user was in. Never type the request itself into the box.",
            "- Documents: open_file with the user's own distinctive words (\"Q3 sales report\", \"lease 2025\"), never "
                + "a generic word like \"document\". If it says it's showing matches, the user picks; don't open "
                + "something else instead.",
            "- Big requests, done the way a person would (\"summarise my emails\", \"go through my unread messages\", "
                + "\"compare these three laptops\", \"check every tab\"): call plan first with the steps you can see, "
                + "then work through them one at a time. Open the list, read it, scroll for more; open each item that "
                + "matters (important, unread, from a person, about money or dates), read it, note what matters with "
                + "note, go back (browser_back), then the next. Rewrite the plan as you learn: add the items you "
                + "found, drop what isn't needed, add a step when something blocks you (a sign-in, a pop-up). Mark "
                + "steps [x] as you finish them. When every step is done, reply with the answer built from your "
                + "notes: grouped, most important first. Never answer from the first screen alone.",
            "- Long pages: browser_read gives the text from where the page is scrolled to. To understand a whole page "
                + "(a long post, its comments, a feed, an article), browser_scroll down and read on until the page says "
                + "it's the end or you have what's needed; click \"see more\", \"load more comments\" and similar to "
                + "open hidden text. Don't answer from the first screen alone when the answer is further down.",
            "- Tabs: the browser's current tab is given below when there is one. If it already shows what's needed, "
                + "work there (browser_read) rather than opening it again. open_url, web_search and site_search come to "
                + "a tab that already has the page, and after your first page they load in that same tab, so never "
                + "open the same site twice. Inside a site, follow its links and buttons (browser_click: \"Me\", "
                + "\"Posts\", \"Activity\", the post itself) rather than guessing deep addresses.",
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
            tool("open_file", "Open the user's own file: by its full path or exact name when you know it (Finder's "
                 + "selection, a name on the screen, a match listed earlier), else a description with the user's own "
                 + "words, e.g. \"lease 2025 pdf\": a clear best match opens, otherwise you get the matches to pick from",
                 ["query": ("string", "the file's full path, its exact name, or the user's description"),
                  "play": ("string", "true to start playing a video or song")], required: ["query"]),
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
            tool("media_control", "Play or pause what's where the user is (the video selected in Finder, the player in "
                 + "front, the page's video), or skip what's playing",
                 ["action": ("string", "pause, play, next or previous")]),
            tool("set_brightness", "Set the screen brightness to a percentage", ["percent": ("number", "0 to 100")]),
            tool("set_bluetooth", "Turn Bluetooth on or off", ["on": ("boolean", "true for on, false for off")]),
            tool("set_wifi", "Turn Wi-Fi on or off", ["on": ("boolean", "true for on, false for off")]),
            tool("screenshot", "Open the screenshot toolbar"),
            tool("list_shortcuts", "List the user's Shortcuts"),
            tool("run_shortcut", "Run one of the user's Shortcuts (asks first)",
                 ["name": ("string", "shortcut name"), "input": ("string", "optional text input")], required: ["name"]),
            tool("coding_followup", "Send a request to the Claude Code / Codex session already building the user's "
                 + "project (add or change a feature, fix a bug, run it, test it, commit)",
                 ["message": ("string", "the user's request, in their words, complete")]),
            tool("build_with_agent", "Start a Claude Code (or Codex) session in Terminal that builds software in a new "
                 + "project folder", ["task": ("string", "the user's full request"),
                                      "helper": ("string", "claude or codex; empty for the default"),
                                      "folder_name": ("string", "short folder name, optional")], required: ["task"]),
            tool("open_settings", "Open a System Settings pane (software update, wifi, bluetooth, battery, display, "
                 + "sound, privacy, keyboard…) or \"app store updates\"", ["pane": ("string", "the pane")]),
            tool("site_search", "Search a website in the browser (youtube, google, amazon, github, maps, wikipedia, "
                 + "reddit, linkedin, spotify…)", ["site": ("string", "the site"), "query": ("string", "what to search")]),
            tool("browser_read", "Read the page in the browser: address, title, its text, fields, links and buttons"),
            tool("browser_click", "Click a link or button on the browser page by its words",
                 ["text": ("string", "the link's or button's words, as shown")]),
            tool("browser_type", "Type into a field on the browser page (by its label or placeholder; empty: the "
                 + "focused or search field), optionally submitting",
                 ["field": ("string", "the field's label or placeholder, or empty"), "text": ("string", "what to type"),
                  "submit": ("boolean", "true to submit (search, send the form)")]),
            tool("browser_scroll", "Scroll the browser page", ["direction": ("string", "down, up, top or bottom")]),
            tool("browser_tabs", "List the tabs in the browser's front window"),
            tool("browser_switch_tab", "Switch to a browser tab by number or by words in its title or address",
                 ["tab": ("string", "tab number or words")]),
            tool("run_applescript", "Run an AppleScript to do something in a scriptable app (Notes, Reminders, "
                 + "Calendar, Mail, Messages, Finder, Music, System Events…) and get its result",
                 ["script": ("string", "the AppleScript"), "purpose": ("string", "what it does, in a few words")]),
            tool("read_screen", "See the front app's window: the text on it, and its buttons, links and fields, numbered"),
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
            tool("insert_text", "Paste finished text into the box the user was typing in when they spoke (Murmur goes "
                 + "back there first, even after visiting another page or app)", ["text": ("string", "the text")]),
            tool("read_clipboard", "Read the text on the clipboard (what the user copied)"),
            tool("copy_text", "Put text on the clipboard", ["text": ("string", "the text")]),
            tool("paste_clipboard", "Paste what's on the clipboard, formatting and all, into the box the user was typing in"),
            tool("replace_selection", "Put finished text in place of the user's selected text (a translation, a "
                 + "rewrite, a fix)", ["text": ("string", "the finished text")]),
            tool("run_command", "Run a shell command on the Mac (zsh, in the home folder) and return its output",
                 ["command": ("string", "the command"),
                  "purpose": ("string", "one short line on what it does, shown when the user is asked")],
                 required: ["command"]),
            tool("reply", "Show a short answer to the user", ["text": ("string", "the answer")]),
            tool("calendar_events", "Read the user's calendar events, from every calendar account",
                 ["start": ("string", "today, tomorrow, a weekday, or YYYY-MM-DD"),
                  "days": ("number", "how many days: 1 for a day, 7 for a week"),
                  "search": ("string", "only events mentioning this; empty for all")], required: ["start"]),
            tool("reminders_list", "Read the user's reminders",
                 ["search": ("string", "only reminders mentioning this; empty for all"),
                  "completed": ("string", "true to include done ones")], required: []),
            tool("remember", "Keep a lasting fact or preference the user told you, for every later command (it shows on "
                 + "Murmur's Memory page)",
                 ["subject": ("string", "what it's about, in a word or two: a person's name, \"browser\", \"message style\""),
                  "fact": ("string", "the fact in plain words, e.g. \"Mom is Roma, on WhatsApp\"")]),
            tool("forget_fact", "Forget a fact or preference the user told you before",
                 ["about": ("string", "its subject or words from it")]),
            tool("recall", "Look back through earlier commands and what they did (who was messaged and what, files and "
                 + "pages opened, answers given)",
                 ["query": ("string", "words to find: a person, file, site or topic; empty for everything recent"),
                  "kind": ("string", "message, file, web, media, calendar, write, code, app, setting, answer, or any"),
                  "days": ("number", "how far back, in days (default 30)")], required: ["query"]),
            tool("app_dictionary", "An app's AppleScript terms (what it holds and its commands), to write a "
                 + "run_applescript that reads or changes it", ["app": ("string", "app name")]),
            tool("send_message", "Send a message to a person or channel in WhatsApp, Messages, Slack and other chat apps "
                 + "(the user is asked first)",
                 ["app": ("string", "WhatsApp, Messages, Slack… (empty: the chat app in front)"),
                  "to": ("string", "the person, group or channel, as the user said it"),
                  "text": ("string", "the message, in the user's words")], required: ["to", "text"]),
            tool("plan", "Write or rewrite your task list for a request with several parts (going through emails, "
                 + "comparing things, a chain of steps): one step per line, [x] for done, [ ] for to do. Call it first, "
                 + "then again whenever you learn something (more items to go through, a step not needed, something "
                 + "in the way) so it always shows what's left. It's shown to you on every step.",
                 ["steps": ("string", "the steps, one per line, each starting with [x] or [ ]")]),
            tool("note", "Keep a finding for the final answer: it stays with you even when older page text is cut "
                 + "(\"HDFC: card bill ₹12,340 due 20 Oct\")", ["text": ("string", "the finding, short")]),
            tool("browser_back", "Go back to the previous page in the browser (from an opened email back to the inbox)"),
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

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
