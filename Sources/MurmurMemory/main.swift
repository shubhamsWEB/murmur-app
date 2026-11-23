import AgentKit
import AppKit

// Screen memory's helper: started by Murmur when screen memory is on (Contents/Helpers/murmur-memory), and gone when
// Murmur quits or it's turned off. A process of its own so reading windows and the model's work never touch the
// app's main thread, at background priority: macOS gives it spare time on the efficiency cores and throttles its disk.
// macOS counts it as Murmur's, so it uses Murmur's Accessibility (and Screen Recording) permission.
// `murmur-memory mcp`: Murmur's memory for Claude Code, Claude Desktop, Cursor, Codex and the rest (stdio MCP,
// read-only); Murmur adds it to them itself (MCPRegistration).
if CommandLine.arguments.dropFirst().first == "mcp" {
    MemoryServer().serve()
}
// `murmur-memory report`, `murmur-memory ask "when is my flight?"`: what screen memory made of your work, from Terminal.
// `murmur-memory knowledge`: one round of the wiki, digest and profile now, printed.
if let command = CommandLine.arguments.dropFirst().first, ["report", "ask", "knowledge"].contains(command) {
    MemoryReport.run(Array(CommandLine.arguments.dropFirst()))
}
// `murmur-memory eval evals/memory.local.json`: memory scored on your own questions (MemoryEval).
if CommandLine.arguments.dropFirst().first == "eval" {
    MemoryEval.run(Array(CommandLine.arguments.dropFirst()))
}

// The key for reading with Claude or OpenAI, when the user chose that: one line from Murmur, on standard input.
CloudReader.takeKeysFromStandardInput()
setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("murmur-memory: Murmur has no Accessibility permission\n".utf8))
    exit(2)
}
// The same tools as `murmur-memory mcp`, over HTTP on 127.0.0.1 with a token, for assistants that run commands.
let memoryAPI = MemoryAPI()
memoryAPI.start()
MainActor.assumeIsolated { ScreenWatcher().run() }
