import Foundation

/// Runs a shell command for the command agent ("how much disk space is left", "convert this image to PNG", "what
/// changed in my repo"). Commands that only read run straight away; anything else is shown to you first, and sudo
/// is never run.
public enum ShellCommand {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let timedOut: Bool
    }

    /// Programs that only read and report. Anything else (or these with an option that writes) asks first.
    static let readOnly: Set<String> = [
        "ls", "pwd", "whoami", "id", "date", "cal", "uptime", "df", "du", "sw_vers", "uname", "hostname", "which",
        "echo", "cat", "head", "tail", "wc", "grep", "find", "egrep", "fgrep", "sort", "uniq", "cut", "tr", "file", "stat",
        "mdfind", "mdls", "system_profiler", "vm_stat", "top", "ps", "lsof", "sysctl", "printenv", "env", "basename",
        "dirname", "realpath", "shasum", "md5", "otool", "plutil", "sips", "networkQuality", "ping", "dig", "nslookup",
    ]
    /// Options that turn a reading program into one that changes things.
    static let writingOptions = #"(^|\s)(-delete|-exec|-execdir|-ok|-okdir|-fprint\w*)(\s|$)"#

    /// True when the command can run without asking: every program in it only reads, with nothing written to files
    /// and no command substitution or chaining.
    public static func isReadOnly(_ command: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.range(of: #"[;&<>`]|\$\(|\|\|"#, options: .regularExpression) != nil { return false }
        if text.range(of: writingOptions, options: .regularExpression) != nil { return false }
        for segment in text.split(separator: "|") {
            let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let program = words.first else { return false }
            switch program {
            case "git":
                let read: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "describe", "blame"]
                guard words.count > 1, read.contains(words[1]) else { return false }
            case "defaults":
                guard words.count > 1, words[1] == "read" else { return false }
            case "pmset":
                guard words.count > 1, words[1] == "-g" else { return false }
            case "diskutil":
                guard words.count > 1, ["list", "info", "apfs"].contains(words[1]),
                      words.count < 3 || words[1] != "apfs" || words[2] == "list" else { return false }
            case "sort":
                guard !words.contains(where: { $0 == "-o" || $0.hasPrefix("--output") }) else { return false }
            case "top":
                guard words.contains("-l") else { return false }   // without -l it never ends
            case "sips":
                guard words.count > 1, words[1] == "-g" || words[1] == "--getProperty" else { return false }
            default:
                guard readOnly.contains(program) else { return false }
            }
        }
        return true
    }

    /// Whether the command tries to run as root.
    public static func usesSudo(_ command: String) -> Bool {
        command.range(of: #"(^|[\s;&|(])(sudo|su|doas)\s"#, options: .regularExpression) != nil
    }

    /// Runs `command` with your login shell's settings (so Homebrew tools are found), in your home folder, and
    /// returns what it printed (both streams, cut to `limit` characters).
    public static func run(_ command: String, timeout: TimeInterval = 60, limit: Int = 8000) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                let buffer = OutputBuffer(limit: limit * 4)
                pipe.fileHandleForReading.readabilityHandler = { handle in buffer.append(handle.availableData) }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: Result(status: -1, output: "Couldn't start the shell: \(error.localizedDescription)",
                                                          timedOut: false))
                    return
                }
                var timedOut = false
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning {
                    if Date() > deadline {
                        timedOut = true
                        process.terminate()
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                var output = String(decoding: buffer.data, as: UTF8.self)
                if output.count > limit { output = String(output.prefix(limit)) + "\n… (cut)" }
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                      output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      timedOut: timedOut))
            }
        }
    }
}

/// What a command prints, gathered from the pipe's handler thread.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if stored.count < limit { stored.append(chunk) }
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
