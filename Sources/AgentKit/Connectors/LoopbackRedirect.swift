import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Where the browser comes back after you sign in to a connected app: a one-request web server on 127.0.0.1, on this
/// Mac only (RFC 8252's loopback redirect, what native apps use). It answers with a page saying you can close the tab,
/// and hands Murmur the address the browser came back to.
public final class LoopbackRedirect: @unchecked Sendable {
    public let port: UInt16
    private let socket: Int32

    /// A listener on this port, or any free one (0). Nil when the port is taken.
    public init?(port: UInt16 = 0) {
        #if canImport(Glibc)
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        socket = fd
        self.port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { close(socket) }

    public var redirect: String { "http://127.0.0.1:\(port)/callback" }

    /// The address the browser came back to, or nil when nobody came within `timeout` (you closed the page).
    public func wait(timeout: TimeInterval = 300) async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: accept(until: Date().addingTimeInterval(timeout)))
            }
        }
    }

    private func accept(until deadline: Date) -> URL? {
        while Date() < deadline {
            var waiting = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, min(1000, deadline.timeIntervalSinceNow * 1000)))
            guard poll(&waiting, 1, left) > 0 else { continue }
            #if canImport(Glibc)
            let client = Glibc.accept(socket, nil, nil)
            #else
            let client = Darwin.accept(socket, nil, nil)
            #endif
            guard client >= 0 else { continue }
            defer { close(client) }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { continue }
            let request = String(decoding: buffer.prefix(count), as: UTF8.self)
            // "GET /callback?code=…&state=… HTTP/1.1"
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard target.hasPrefix("/callback") else {
                respond(client, status: "404 Not Found", body: "")
                continue
            }
            respond(client, status: "200 OK", body: Self.page)
            return URL(string: "http://127.0.0.1:\(port)\(target)")
        }
        return nil
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let reply = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n\(body)"
        _ = reply.withCString { write(client, $0, strlen($0)) }
    }

    static let page = """
        <!doctype html><html><head><meta charset="utf-8"><title>Murmur</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;background:#fbf7f1;color:#2b2622;display:grid;\
        place-items:center;height:100vh;margin:0}p{max-width:24em;text-align:center;line-height:1.5}</style></head>
        <body><p><b>Connected to Murmur.</b><br>You can close this tab and go back to Murmur.</p></body></html>
        """
}
