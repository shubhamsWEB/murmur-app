import Foundation

/// Is Ollama there for the local command model: installed, running, and with the model pulled. Optional: dictation,
/// file search (its own embedding model, built in) and common commands never need it.
public enum OllamaProbe {
    public enum State: Equatable, Sendable {
        case notInstalled
        case notRunning
        case missingModel(String)
        case ready(String)
    }

    /// Ollama.app, or the `ollama` command from Homebrew or the install script.
    public static var isInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/Ollama.app", "\(home)/Applications/Ollama.app", "/opt/homebrew/bin/ollama",
                "/usr/local/bin/ollama"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    public static func check(model: String) async -> State {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return isInstalled ? .notRunning : .notInstalled
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let names = (json?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        // "qwen3:4b" matches "qwen3:4b"; "qwen3" matches "qwen3:latest".
        let wanted = model.contains(":") ? model : model + ":latest"
        return names.contains(wanted) ? .ready(model) : .missingModel(model)
    }

    /// Opens the Ollama app (it serves on 127.0.0.1:11434 while open).
    public static func start() async {
        _ = await MacActions.run("/usr/bin/open", ["-a", "Ollama"], timeout: 10)
    }

    /// Opens Ollama if it's closed and waits up to 10 s for it to answer.
    public static func startIfNeeded(model: String) async {
        guard case .notRunning = await check(model: model) else { return }
        await start()
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if case .notRunning = await check(model: model) { continue }
            return
        }
    }

    /// Downloads a model through Ollama's API, reporting how far it is (0 to 0.99) as it goes. Nil when the
    /// download ran to the end, else what went wrong.
    public static func download(_ model: String, progress: @escaping @MainActor (Double) -> Void) async -> String? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/pull")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        do {
            let (lines, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "Ollama couldn't start the download." }
            // Each layer reports its own bytes: the total is all of them.
            var layers: [String: (done: Double, total: Double)] = [:]
            for try await line in lines.lines {
                guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if let error = json["error"] as? String { return error }
                if let digest = json["digest"] as? String, let total = (json["total"] as? NSNumber)?.doubleValue, total > 0 {
                    layers[digest] = ((json["completed"] as? NSNumber)?.doubleValue ?? 0, total)
                    let done = layers.values.reduce(0) { $0 + $1.done }, all = layers.values.reduce(0) { $0 + $1.total }
                    await progress(min(done / max(all, 1), 0.99))
                }
                if json["status"] as? String == "success" { break }
            }
        } catch {
            return "The download stopped: \(error.localizedDescription)"
        }
        return nil
    }

    /// Gives a model a second name (`ollama cp`), so a model downloaded from the library is found under the name
    /// Murmur asks for. Nil when it worked, else what went wrong.
    public static func copy(_ source: String, to destination: String) async -> String? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/copy")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["source": source, "destination": destination])
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return "Ollama didn't answer." }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return status == 200 ? nil : "Ollama couldn't name the model (\(status))."
    }

    /// Downloads a model with the `ollama` command. Returns nil when it worked, else what went wrong. Murmur's own
    /// models come from Ollama's library under their published name and are given Murmur's name for them.
    public static func pull(_ model: String) async -> String? {
        let source = LocalModels.published[model] ?? model
        var command = "ollama pull \(source) 2>&1 | tail -3"
        if source != model { command += " && ollama cp \(source) \(model) 2>&1 | tail -1" }
        let output = await MacActions.run("/bin/zsh", ["-lc", command], timeout: 3600)
        if case .ready = await check(model: model) { return nil }
        return output.isEmpty ? "The download didn't finish." : output
    }
}

/// The local (Ollama) models offered for commands. `murmur-agent` is Murmur's own: Qwen3.5 4B trained on Murmur's
/// tools (murmur-models), about 14 times faster than qwen3:4b at a step and right more often.
public enum LocalModels {
    public static let agent = "murmur-agent"
    public static let choices = [agent, "qwen3:4b", "qwen3:8b", "qwen3:1.7b", "llama3.2:3b"]

    /// Murmur's models in Ollama's library, by the name Murmur uses for them.
    public static let published = [agent: "shubhama664/murmur-agent:v1",
                                   "murmur-cleanup": "shubhama664/murmur-cleanup:v1"]

    /// Murmur Agent from v2 on ("murmur-agent:v2", "shubhama664/murmur-agent:v3"): trained on Murmur's short prompt
    /// (`CommandAgent.compactPrompt`), so it's sent that, not the full rules. v1 ("murmur-agent", ":v1") learned
    /// with the full rules and keeps getting them.
    public static func usesShortPrompt(_ model: String) -> Bool {
        let parts = model.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == agent || parts[0].hasSuffix("/" + agent),
              parts[1].hasPrefix("v"), let version = Int(parts[1].dropFirst()) else { return false }
        return version >= 2
    }

    /// What a choice is called in menus.
    public static func display(_ model: String) -> String {
        model == agent || model.hasPrefix(agent + ":") ? "Murmur Agent" : model
    }

    /// The download's size, as said to you.
    public static func sizeText(_ model: String) -> String {
        switch model {
        case agent: return "2.8 GB"
        case "qwen3:1.7b": return "1.4 GB"
        case "qwen3:8b": return "5.2 GB"
        case "llama3.2:3b": return "2 GB"
        default: return "2.5 GB"
        }
    }
}
