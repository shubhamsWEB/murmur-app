import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to one connected app's MCP server over Streamable HTTP (MCP 2025-06-18): JSON-RPC posted to one URL, answered
/// as JSON or as a short event stream. Lists the app's tools and calls them. Signs every request with the app's token,
/// and when the server says it ran out (401) asks for a fresh one once.
public actor MCPClient {
    public struct Tool: Sendable, Equatable, Codable {
        public let name: String
        public let description: String
        /// Its input JSON Schema, as JSON text.
        public let schema: String
        public let readOnly: Bool

        /// The schema's properties, as "name (type, required): description" lines, for the command model.
        public var arguments: String {
            guard let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any],
                  let properties = object["properties"] as? [String: Any] else { return "" }
            let required = Set(object["required"] as? [String] ?? [])
            return properties.keys.sorted().map { key in
                let property = properties[key] as? [String: Any] ?? [:]
                let type = property["type"] as? String ?? "any"
                let about = (property["description"] as? String).map { ": \($0.prefix(100))" } ?? ""
                return "\(key) (\(type)\(required.contains(key) ? ", required" : ""))\(about)"
            }.joined(separator: "; ")
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// Signed out (the token was refused, and a fresh one didn't help): sign in again.
        case signedOut
        case server(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .signedOut: return "Murmur was signed out of this app. Connect it again."
            case .server(let message): return message
            case .unreadable(let what): return "The app answered in a way Murmur can't read (\(what))."
            }
        }
    }

    public static let protocolVersion = "2025-06-18"

    public let url: URL
    /// The token to send; `true` asks for a fresh one (after a 401). Nil: no sign-in.
    private let token: @Sendable (_ fresh: Bool) async throws -> String?
    private let session: URLSession
    private var sessionID: String?
    private var negotiated: String?
    private var ready = false
    private var nextID = 1

    public init(url: URL, session: URLSession = .shared, token: @escaping @Sendable (_ fresh: Bool) async throws -> String?) {
        self.url = url
        self.session = session
        self.token = token
    }

    // MARK: Using the app

    /// Everything the app can do.
    public func tools() async throws -> [Tool] {
        var tools: [Tool] = []
        var cursor: String?
        repeat {
            let result = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            for tool in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = tool["name"] as? String else { continue }
                let schema = (tool["inputSchema"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                let hints = tool["annotations"] as? [String: Any]
                tools.append(Tool(name: name, description: (tool["description"] as? String ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                                  schema: schema, readOnly: hints?["readOnlyHint"] as? Bool ?? false))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 500
        return tools
    }

    /// Calls a tool with its arguments (a JSON object, as text). Returns what it said, and whether it was an error.
    public func call(_ name: String, arguments: String = "{}") async throws -> (text: String, isError: Bool) {
        let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let result = try await request("tools/call", ["name": name, "arguments": parsed])
        return (Self.text(of: result), result["isError"] as? Bool ?? false)
    }

    /// A tool result's content as text: its text parts, embedded resources' text, and a note for anything else.
    static func text(of result: [String: Any]) -> String {
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text": parts.append(item["text"] as? String ?? "")
            case "resource":
                let resource = item["resource"] as? [String: Any]
                parts.append(resource?["text"] as? String ?? "[\(resource?["uri"] as? String ?? "resource")]")
            case "resource_link": parts.append("[\(item["name"] as? String ?? "link"): \(item["uri"] as? String ?? "")]")
            case let other?: parts.append("[\(other)]")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: JSON-RPC

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if !ready { try await start() }
        do {
            return try await send(method, params)
        } catch Failure.server(let message) where message.contains("session") && sessionID != nil {
            // The server forgot the session (restarted): start a new one, once.
            ready = false
            sessionID = nil
            try await start()
            return try await send(method, params)
        }
    }

    private func start() async throws {
        let result = try await send("initialize", [
            "protocolVersion": Self.protocolVersion, "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Murmur", "version": "1"],
        ])
        negotiated = result["protocolVersion"] as? String
        _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], id: nil)
        ready = true
    }

    private func send(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        guard let reply = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params], id: id) else {
            throw Failure.unreadable("no answer to \(method)")
        }
        if let error = reply["error"] as? [String: Any] {
            throw Failure.server(error["message"] as? String ?? "The app couldn't do that.")
        }
        return reply["result"] as? [String: Any] ?? [:]
    }

    /// Posts one message; for a request, returns the reply with its id.
    private func post(_ message: [String: Any], id: Int?, fresh: Bool = false) async throws -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let negotiated { request.setValue(negotiated, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let bearer = try await token(fresh) { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable("not HTTP") }
        if http.statusCode == 401 || http.statusCode == 403 {
            guard !fresh else { throw Failure.signedOut }
            return try await post(message, id: id, fresh: true)
        }
        if http.statusCode == 404, sessionID != nil { throw Failure.server("session expired") }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        guard let id else { return nil }   // a notification: 202, nothing back
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.server("The app answered HTTP \(http.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let messages = type.contains("text/event-stream") ? Self.events(data) : [data]
        for body in messages {
            let value = try? JSONSerialization.jsonObject(with: body)
            for reply in (value as? [[String: Any]]) ?? (value as? [String: Any]).map({ [$0] }) ?? [] {
                if (reply["id"] as? NSNumber)?.intValue == id || (reply["id"] as? String) == String(id) { return reply }
            }
        }
        throw Failure.unreadable("no reply to request \(id)")
    }

    /// The `data:` of each server-sent event.
    static func events(_ data: Data) -> [Data] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return text.components(separatedBy: "\n\n").compactMap { event in
            let lines = event.split(separator: "\n").filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).drop { $0 == " " } }
            return lines.isEmpty ? nil : Data(lines.joined(separator: "\n").utf8)
        }
    }
}
