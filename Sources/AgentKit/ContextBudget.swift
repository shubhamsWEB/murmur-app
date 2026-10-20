import Foundation

/// Keeps a local model's prompt inside its context window. Ollama cuts a prompt that's too long without saying so,
/// and what it cuts first is the start, the instructions, so the model carried on half-blind. Here the oldest steps
/// go first, in whole steps, and the request, the instructions and the latest steps always stay.
public enum ContextBudget {
    /// A safe estimate of a text's tokens: about three characters each (English runs nearer four; JSON, code and
    /// Hindi in English letters run closer to three).
    public static func tokens(_ text: String) -> Int { (text.utf8.count + 2) / 3 }

    public static func tokens(_ turn: RouterTurn) -> Int {
        switch turn {
        case .user(let text): return tokens(text) + 8
        case .assistant(let text, let calls):
            return tokens(text) + calls.reduce(8) { $0 + tokens($1.name) + 12
                + $1.arguments.reduce(0) { $0 + tokens($1.key) + tokens($1.value.description) + 4 } }
        case .toolResult(_, let name, let content): return tokens(name) + tokens(content) + 8
        }
    }

    public static func tokens(_ turns: [RouterTurn]) -> Int { turns.reduce(0) { $0 + tokens($1) } }

    /// The tool definitions as the model reads them.
    public static func tokens(_ tools: [ToolSpec]) -> Int {
        tools.reduce(0) { total, tool in
            let schema = (try? JSONSerialization.data(withJSONObject: tool.parameters)).map(\.count) ?? 200
            return total + tokens(tool.name) + tokens(tool.description) + (schema + 2) / 3 + 16
        }
    }

    static let cutNote = "(Earlier steps were left out to fit; your task list and notes keep what matters.)"

    /// `turns` cut to fit `window` tokens together with `fixed` (instructions and tools), leaving `reserve` for the
    /// answer. Old page text is shortened first; then the oldest steps go, whole (a step's calls and their results
    /// together); the first turn (the request) and the latest step always stay. Unchanged when it already fits.
    public static func fit(_ turns: [RouterTurn], fixed: Int, window: Int, reserve: Int = 1500) -> [RouterTurn] {
        let room = window - fixed - reserve
        guard tokens(turns) > room, turns.count > 1 else { return turns }
        var out = turns

        // 1. Old tool results (all but the latest step's) down to their first lines.
        let latest = lastStepStart(out)
        for index in out.indices where index < latest {
            if case .toolResult(let id, let name, let content) = out[index], content.count > 400 {
                out[index] = .toolResult(callID: id, name: name,
                                         content: String(content.prefix(300)) + "\n… (cut to fit; read again if needed)")
            }
        }
        if tokens(out) <= room { return out }

        // 2. The oldest steps, whole, after the request.
        var steps = split(out)
        let first = steps.removeFirst()
        var dropped = false
        while steps.count > 1, tokens(first) + tokens(steps.flatMap { $0 }) > room {
            steps.removeFirst()
            dropped = true
        }
        var head = first
        if dropped, case .user(let text) = head[0], !text.hasSuffix(cutNote) {
            head[0] = .user(text + "\n\n" + cutNote)
        }
        out = head + steps.flatMap { $0 }
        if tokens(out) <= room { return out }

        // 3. Still too long (one huge page): the latest results share what room is left.
        let last = steps.last ?? []
        let start = out.count - last.count
        let isResult: (RouterTurn) -> Bool = { if case .toolResult = $0 { return true } else { return false } }
        let results = last.filter(isResult).count
        guard results > 0 else { return out }
        let left = room - tokens(Array(out[..<start])) - tokens(last.filter { !isResult($0) }) - results * 30
        let each = max(600, left * 3 / results)
        for index in start..<out.count {
            if case .toolResult(let id, let name, let content) = out[index], content.count > each {
                out[index] = .toolResult(callID: id, name: name,
                                         content: String(content.prefix(each)) + "\n… (cut to fit)")
            }
        }
        return out
    }

    /// The turns in steps: the request (and anything before the first answer) first, then each model answer with the
    /// results and notes that follow it.
    static func split(_ turns: [RouterTurn]) -> [[RouterTurn]] {
        var steps: [[RouterTurn]] = [[]]
        for turn in turns {
            if case .assistant = turn, !steps[steps.count - 1].isEmpty { steps.append([]) }
            steps[steps.count - 1].append(turn)
        }
        return steps
    }

    /// Where the latest step (the last model answer and what followed) starts.
    static func lastStepStart(_ turns: [RouterTurn]) -> Int {
        turns.lastIndex { if case .assistant = $0 { return true } else { return false } } ?? turns.count
    }

    /// The task list and notes go after the conversation, not in the instructions: they change every step, and
    /// anything that changes in the instructions makes a local model read the whole prompt again (its cache only
    /// holds an unchanged start). At the end, only the new step is read.
    public static func appendingState(_ state: String, to turns: [RouterTurn]) -> [RouterTurn] {
        let state = state.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isEmpty, let last = turns.last else { return turns }
        var out = turns
        let block = "\n\n---\n" + state
        switch last {
        case .toolResult(let id, let name, let content):
            out[out.count - 1] = .toolResult(callID: id, name: name, content: content + block)
        case .user(let text):
            out[out.count - 1] = .user(text + block)
        case .assistant:
            out.append(.user(state))
        }
        return out
    }
}
