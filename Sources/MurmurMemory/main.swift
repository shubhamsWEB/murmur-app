import AgentKit
import AppKit

// Screen memory's helper: started by Murmur when screen memory is on (Contents/Helpers/murmur-memory), and gone when
// Murmur quits or it's turned off. A process of its own so reading windows and the model's work never touch the
// app's main thread, at background priority: macOS gives it spare time on the efficiency cores and throttles its disk.
// macOS counts it as Murmur's, so it uses Murmur's Accessibility (and Screen Recording) permission.
// `murmur-memory mcp`: Murmur's memory for Claude Code, Claude Desktop and Cursor (stdio MCP, read-only).
if CommandLine.arguments.dropFirst().first == "mcp" {
    MemoryServer().serve()
}
// `murmur-memory report`, `murmur-memory ask "when is my flight?"`: what screen memory made of your work, from Terminal.
if let command = CommandLine.arguments.dropFirst().first, ["report", "ask"].contains(command) {
    MemoryReport.run(Array(CommandLine.arguments.dropFirst()))
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
MainActor.assumeIsolated { ScreenWatcher().run() }
