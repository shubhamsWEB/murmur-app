import Foundation

/// Watches a command as it runs, for the signs of a task going nowhere: steps that keep failing, the same step again
/// with nothing changed, a task list with nothing ticked for a long while. Each sign gets one nudge (said once, with
/// what went wrong) so the model changes course early, rather than spending the rest of its steps the same way.
/// Plain code, no model: it reads the tool results Murmur already has.
public struct TaskHealth: Sendable {
    /// Failed steps in a row (each step's calls all failed).
    public private(set) var failuresInARow = 0
    private var lastFailures: [String] = []
    private var nudgedFailures = 0
    private var stepsWithoutProgress = 0
    private var lastOpenSteps: Int?
    private var lastDoneSteps: Int?

    public init() {}

    /// A tool result that says the action didn't work.
    public static func isFailure(_ result: String) -> Bool {
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return false }
        let start = #"^(couldn[’']?t|could not|can[’']?t|cannot|no |nothing on|not_found|script error|there[’']?s no|that doesn[’']?t|unknown tool|i don[’']?t know|murmur has no|murmur needs|failed|error)"#
        let anywhere = #"\b(couldn[’']?t (click|find|open|do|reach|type|read|send|write)|didn[’']?t (switch|work|open|load)|isn[’']?t running|not found|exit status [1-9]|nothing changed)"#
        return text.range(of: start, options: .regularExpression) != nil
            || text.range(of: anywhere, options: .regularExpression) != nil
    }

    /// One step's results (the tools called and what each said) and the task list after it (nil when there's none).
    /// Returns a nudge to add to the step's last result, or nil when all looks well.
    public mutating func record(_ results: [(tool: String, result: String)], openSteps: Int?, doneSteps: Int?) -> String? {
        // Only actions count: a step that clicked (and failed) then read the page hasn't worked because the read did.
        let acting = results.filter { !Self.looking.contains($0.tool) }
        if !acting.isEmpty, acting.allSatisfy({ Self.isFailure($0.result) }) {
            failuresInARow += 1
            lastFailures = acting.map { "\($0.tool): \($0.result.prefix(140))" }
        } else if !acting.isEmpty {
            failuresInARow = 0
            nudgedFailures = 0
        }
        // Progress on the task list: a step ticked (or the list rewritten shorter).
        if let open = openSteps, let done = doneSteps {
            if let lastDone = lastDoneSteps, let lastOpen = lastOpenSteps, done <= lastDone, open >= lastOpen {
                stepsWithoutProgress += 1
            } else {
                stepsWithoutProgress = 0
            }
            lastOpenSteps = open
            lastDoneSteps = done
        }
        if failuresInARow >= 2, nudgedFailures < failuresInARow / 2 {
            nudgedFailures = failuresInARow / 2
            let what = lastFailures.joined(separator: "; ")
            if failuresInARow >= 4 {
                return "Four steps in a row haven't worked (last: \(what)). Stop repeating this approach. If there's "
                    + "another way (the app's own buttons from read_screen, a direct address with open_url, "
                    + "run_command, a script), take it; if this part truly can't be done, note why, tick it off in "
                    + "your plan as skipped, and go on with the rest."
            }
            return "The last two steps didn't work (\(what)). Don't try the same thing again, and don't ask the user "
                + "to do it: look at where things are (read_screen, or browser_read in a browser) and take another "
                + "route. In a website that's usually the exact address of what you want with open_url (e.g. Gmail's "
                + "Sent: https://mail.google.com/mail/u/0/#sent), the site's own search, or its keyboard shortcuts."
        }
        if stepsWithoutProgress >= 8 {
            stepsWithoutProgress = 0
            return "No step of your task list has been ticked for 8 steps. Check where you are against the list: "
                + "tick what's done with plan, rewrite or drop a step that's stuck (say why in a note), and move on to "
                + "the next."
        }
        return nil
    }

    /// Tools that only look or keep notes: they neither make a step work nor fail.
    static let looking: Set<String> = [
        "plan", "note", "wait", "use_skill", "read_skill_file", "browser_read", "read_screen", "read_whole_page",
        "browser_tabs", "app_dictionary", "recall", "list_running_apps", "read_clipboard",
    ]

    /// The nudge for the same step twice with nothing to show for it.
    public static let repeatNudge = "That's exactly what you just did, and it didn't move things on. Don't do it a "
        + "third time: look at the screen (read_screen or browser_read) and take a different step."
}
