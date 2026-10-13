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

    /// Downloads a model with the `ollama` command. Returns nil when it worked, else what went wrong.
    public static func pull(_ model: String) async -> String? {
        let output = await MacActions.run("/bin/zsh", ["-lc", "ollama pull \(model) 2>&1 | tail -3"], timeout: 3600)
        if case .ready = await check(model: model) { return nil }
        return output.isEmpty ? "The download didn't finish." : output
    }
}
