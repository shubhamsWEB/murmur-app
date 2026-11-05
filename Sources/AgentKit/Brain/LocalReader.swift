import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Murmur's built-in reading model, from the memory's side: asks `murmur-engine reader-service` (Qwen3 on llama.cpp,
/// shared by the app and its screen-memory helper over a Unix socket), starting it when it isn't running. No Ollama
/// needed. The model files and the socket are where `ReaderModelFiles` (MurmurIndex) puts them.
public enum LocalReader {
    /// The model choice that means "the built-in one" (`BrainDistiller.model()`).
    public static let name = "murmur-reader"

    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Murmur")
    }
    /// The same names as `ReaderModelFiles`: the 4B model, and the 1.7B one for Macs with 8 GB or less.
    static let files = ["Qwen3-4B-Q4_K_M.gguf", "Qwen3-1.7B-Q8_0.gguf"]
    public static var socket: URL { support.appendingPathComponent("reader.sock") }

    /// Whether a reading model is downloaded (only verified files get their final name).
    public static var installed: Bool {
        files.contains { FileManager.default.fileExists(atPath: support.appendingPathComponent("Models/\($0)").path) }
    }

    /// Whether file search's model (EmbeddingGemma 2, text part) is there: the one memory searches by meaning with.
    public static var embedderInstalled: Bool {
        FileManager.default.fileExists(atPath: support.appendingPathComponent("Models/embeddinggemma-2-Q8_0.gguf").path)
    }

    /// Vectors for these texts (a query, or things to remember), from EmbeddingGemma 2 in the memory service: each
    /// 768 numbers, normalised. Nil when they couldn't be made.
    public static func embed(_ texts: [String], query: Bool, socket: URL = LocalReader.socket,
                             start: Bool = true) async -> [[Float]]? {
        guard !texts.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: embedNow(texts, query: query, socket: socket, start: start))
            }
        }
    }

    /// The same, on this thread (the MCP server answers one request at a time).
    public static func embedNow(_ texts: [String], query: Bool, socket: URL = LocalReader.socket, start: Bool = true) -> [[Float]]? {
        guard let reply = request(["op": "embed", "texts": texts, "query": query], socket: socket, start: start,
                                  timeout: 60),
              let encoded = reply["vectors"] as? [String] else { return nil }
        let vectors = encoded.compactMap { Data(base64Encoded: $0) }.map { data in
            data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return vectors.count == texts.count ? vectors : nil
    }

    /// Murmur's engine: next to this program in Helpers/ (the screen-memory helper), or in the app's Helpers/.
    static var engine: URL? {
        let here = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [here?.appendingPathComponent("murmur-engine"),
                          here?.deletingLastPathComponent().appendingPathComponent("Helpers/murmur-engine"),
                          Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/murmur-engine")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The model's answer, or nil when it couldn't be asked (not downloaded, the engine missing, it failed).
    /// `fast`: the user is away and the Mac plugged in, so the service may run at normal priority for it.
    public static func ask(system: String, user: String, json: Bool, maxTokens: Int = 900, fast: Bool = false,
                           socket: URL = LocalReader.socket, start: Bool = true) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: askNow(system: system, user: user, json: json, maxTokens: maxTokens,
                                                      fast: fast, socket: socket, start: start))
            }
        }
    }

    static func askNow(system: String, user: String, json: Bool, maxTokens: Int, fast: Bool = false, socket: URL,
                       start: Bool) -> String? {
        request(["op": "generate", "system": system, "user": user, "json": json, "max": maxTokens, "fast": fast],
                socket: socket, start: start, timeout: 600)?["text"] as? String
    }

    /// One request to the memory service, starting it when it isn't running.
    static func request(_ body: [String: Any], socket: URL, start: Bool, timeout: Double) -> [String: Any]? {
        var fd = connect(socket.path)
        if fd == nil, start, launch() {
            // The service starts listening at once; the model loads on the first request.
            let deadline = Date().addingTimeInterval(20)
            while fd == nil, Date() < deadline {
                usleep(200_000)
                fd = connect(socket.path)
            }
        }
        guard let fd else { return nil }
        defer { close(fd) }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        send(fd, data + Data("\n".utf8))
        guard let line = readLine(fd, timeout: timeout),
              let reply = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        if let error = reply["error"] as? String { MemoryLog.write("memory service: \(error)") }
        return reply
    }

    /// Starts the memory service in the background if it isn't running, without waiting for it: the next command finds
    /// it ready (a command never waits for a model to load).
    public static func warm() {
        DispatchQueue.global(qos: .utility).async {
            if let fd = connect(socket.path) { close(fd) } else { _ = launch() }
        }
    }

    /// Starts the reader service (it exits by itself after five minutes with nothing to read).
    static func launch() -> Bool {
        guard installed || embedderInstalled, let engine else { return false }
        let process = Process()
        process.executableURL = engine
        process.arguments = ["memory-service"]
        process.qualityOfService = .background
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }

    // MARK: The socket

    private static func connect(_ path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        #if canImport(Glibc)
        let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Glibc)
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    private static func send(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    private static func readLine(_ fd: Int32, timeout: Double) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, Int32(min(1000, max(0, deadline.timeIntervalSinceNow * 1000)))) >= 0 else { break }
            guard waiting.revents != 0 else { continue }
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
            if let end = data.firstIndex(of: 10) { return String(decoding: data[..<end], as: UTF8.self) }
        }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
}
