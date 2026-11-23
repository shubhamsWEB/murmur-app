import Foundation
import Network
import Security

/// Murmur's memory over HTTP on this Mac only (127.0.0.1), for an assistant that runs commands rather than MCP tools:
/// the same tools as the MCP server (`MemoryServer`), answered by the screen-memory helper while it runs.
///
/// - `GET /tools`: the tools and what they take (JSON).
/// - `GET /<tool>?name=value…` (`/search_memory?query=quarterly+report`): the tool's answer, as text.
/// - `POST /call` with `{"name": "...", "arguments": {...}}`: the same.
///
/// Every request needs `Authorization: Bearer <token>`, the token in `memory-api-token` beside the memory (readable by
/// this user only), so another user or a web page can't read it. The port is in `memory-api-port` (7356 unless
/// that's taken). Read-only, like the MCP server.
public final class MemoryAPI: @unchecked Sendable {
    public static let preferredPort: UInt16 = 7356
    static let folder = BrainStore.defaultURL.deletingLastPathComponent()
    public static let tokenFile = folder.appendingPathComponent("memory-api-token")
    public static let portFile = folder.appendingPathComponent("memory-api-port")

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "murmur.memory-api", qos: .utility)
    private let server: MemoryServer
    private let token: String

    public init(server: MemoryServer = MemoryServer()) {
        self.server = server
        token = Self.loadToken()
    }

    /// The token, made once (32 random bytes, hex) and kept readable by this user only.
    static func loadToken() -> String {
        if let saved = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 32 {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    /// Listens on 127.0.0.1, on 7356 or, when that's taken, any free port; the port goes in `memory-api-port`.
    public func start() { listen(on: Self.preferredPort) }

    /// A port that's taken fails after `start`, in the state handler: then any free port.
    private func listen(on port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        guard let listener = try? NWListener(using: parameters) else {
            if port != 0 { listen(on: 0) }
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let bound = listener.port?.rawValue else { return }
                try? String(bound).write(to: Self.portFile, atomically: true, encoding: .utf8)
                MemoryLog.write("memory API listening on 127.0.0.1:\(bound) (for assistants without MCP)")
            case .failed(let error):
                listener.cancel()
                MemoryLog.write("memory API couldn't listen on \(port == 0 ? "any port" : String(port)): \(error)")
                if port != 0 { self?.listen(on: 0) }
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(at: Self.portFile)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let (status, type, body) = self.answer(request)
                self.reply(connection, status: status, type: type, body: body)
            } else if done || error != nil || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// An HTTP request, once all of it has arrived.
    public struct Request: Equatable {
        public var method: String
        public var path: String
        public var query: [String: String]
        public var headers: [String: String]
        public var body: Data
    }

    /// The request in `data`, or nil while it isn't all there.
    public static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = head.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let target = String(parts[1])
        let components = URLComponents(string: "http://localhost" + (target.hasPrefix("/") ? target : "/" + target))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]).uppercased(), path: components?.path ?? target, query: query,
                       headers: headers, body: Data(body.prefix(length)))
    }

    /// Whether the request carries the token.
    public static func authorized(_ request: Request, token: String) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        return constantTimeEqual(String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces), token)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func answer(_ request: Request) -> (Int, String, Data) {
        // A browser page could reach 127.0.0.1 too: no token, no answer, and never one for a request a page made.
        guard request.headers["origin"] == nil, Self.authorized(request, token: token) else {
            return (401, "text/plain", Data("A token is needed: Authorization: Bearer <the contents of \(Self.tokenFile.path)>\n".utf8))
        }
        let name = String(request.path.dropFirst())
        switch (request.method, name) {
        case ("GET", "tools"), ("GET", ""):
            let data = (try? JSONSerialization.data(withJSONObject: ["tools": MemoryServer.tools], options: [.prettyPrinted])) ?? Data()
            return (200, "application/json", data)
        case ("POST", "call"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let tool = object["name"] as? String else {
                return (400, "text/plain", Data("Send {\"name\": \"search_memory\", \"arguments\": {\"query\": \"...\"}}\n".utf8))
            }
            return run(tool, object["arguments"] as? [String: Any] ?? [:])
        case ("GET", _):
            return run(name, request.query)
        default:
            return (405, "text/plain", Data("GET /tools, GET /<tool>?…, or POST /call\n".utf8))
        }
    }

    private func run(_ tool: String, _ arguments: [String: Any]) -> (Int, String, Data) {
        guard MemoryServer.toolNames.contains(tool) else {
            return (404, "text/plain", Data("No tool \(tool). The tools: \(MemoryServer.toolNames.joined(separator: ", "))\n".utf8))
        }
        return (200, "text/plain; charset=utf-8", Data((server.call(tool, arguments) + "\n").utf8))
    }

    private func reply(_ connection: NWConnection, status: Int, type: String, body: Data) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
