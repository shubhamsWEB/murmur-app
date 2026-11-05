import Foundation

/// Screen memory's log (Application Support/Murmur/memory.log): what it read, why it waited, what the model made of it,
/// and what went wrong. Never the text of a window. Kept under 2 MB (the older half goes).
public enum MemoryLog {
    nonisolated(unsafe) public static var url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Murmur/memory.log")
    private static let lock = NSLock()
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    // MARK: What the reader is doing (for the Memory page)

    static var statusURL: URL { url.deletingLastPathComponent().appendingPathComponent("reading-status.txt") }
    static var readNowURL: URL { url.deletingLastPathComponent().appendingPathComponent("read-now") }

    /// One line: what the reader is doing or waiting for ("Waiting: you're using the Mac").
    public static func setStatus(_ text: String) {
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: statusURL, options: .atomic)
    }

    public static func status() -> (text: String, at: Date)? {
        guard let data = FileManager.default.contents(atPath: statusURL.path),
              let at = (try? FileManager.default.attributesOfItem(atPath: statusURL.path)[.modificationDate]) as? Date
        else { return nil }
        return (String(decoding: data, as: UTF8.self), at)
    }

    /// "Read Now" on the Memory page: the helper reads at its next minute, without waiting for the user to step away.
    public static func requestReading() {
        setStatus("Reading starts within a minute")
        try? Data().write(to: readNowURL)
    }

    /// Whether reading was asked for (and the request taken).
    public static func takeReadingRequest() -> Bool {
        guard FileManager.default.fileExists(atPath: readNowURL.path) else { return false }
        try? FileManager.default.removeItem(at: readNowURL)
        return true
    }

    public static func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let text = "\(time.string(from: Date())) \(line)\n"
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           size > 2_000_000, let old = try? Data(contentsOf: url) {
            try? old.suffix(old.count / 2).write(to: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
    }
}
