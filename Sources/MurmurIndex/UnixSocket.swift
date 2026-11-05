#if !os(Windows)
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A local (Unix domain) socket, for the reader service and its clients: same machine, same user, nothing on the
/// network. Blocking calls with timeouts.
public enum UnixSocket {
    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        return address
    }

    private static func socket() -> Int32 {
        #if canImport(Glibc)
        return Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        return Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
    }

    /// Listens at `path` (only this user may connect). Nil when another process already listens there.
    public static func listen(at path: String) -> Int32? {
        if let existing = connect(to: path) { close(existing); return nil }
        unlink(path)   // a socket file left behind by a reader that crashed
        guard var address = address(path) else { return nil }
        let fd = socket()
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, startListening(fd) == 0 else { close(fd); return nil }
        return fd
    }

    private static func startListening(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        return Glibc.listen(fd, 8)
        #else
        return Darwin.listen(fd, 8)
        #endif
    }

    public static func connect(to path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket()
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Glibc)
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    /// The next connection, or nil after `timeout` seconds without one.
    public static func accept(_ server: Int32, timeout: Double) -> Int32? {
        guard ready(server, timeout: timeout) else { return nil }
        #if canImport(Glibc)
        let fd = Glibc.accept(server, nil, nil)
        #else
        let fd = Darwin.accept(server, nil, nil)
        #endif
        return fd >= 0 ? fd : nil
    }

    private static func ready(_ fd: Int32, timeout: Double) -> Bool {
        var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&waiting, 1, Int32(max(0, timeout) * 1000)) > 0
    }

    /// One line (without its newline), or nil when none came within `timeout` seconds.
    public static func readLine(_ fd: Int32, timeout: Double) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard ready(fd, timeout: deadline.timeIntervalSinceNow) else { break }
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
            if let end = data.firstIndex(of: 10) { return String(decoding: data[..<end], as: UTF8.self) }
        }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }

    public static func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                #if canImport(Glibc)
                let written = Glibc.write(fd, raw.baseAddress! + offset, raw.count - offset)
                #else
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                #endif
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
#endif
