import Foundation

/// What became of the text Murmur wrote into a box ("tap to write"), kept on this Mac: what it wrote, and what you
/// actually sent (the same, your edited version, or nothing because you took it back). It's how Murmur learns to
/// write like you: the next time it writes in that app, the messages you really sent there go with the request as
/// examples of your voice, the ones you rewrote first.
///
/// One file only this user can read (Application Support › Murmur › written.json), the newest `limit` kept.
public final class WriteMemory: @unchecked Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Sent as written.
        case kept
        /// Sent after you changed it: `sent` is your version.
        case edited
        /// Taken back (⌘Z, deleted, or replaced with something else entirely).
        case reverted
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var app: String
        /// Who it was written to, when Murmur could tell.
        public var partner: String?
        public var wrote: String
        public var sent: String?
        public var outcome: Outcome
        public var at: Date

        public init(app: String, partner: String?, wrote: String, sent: String?, outcome: Outcome, at: Date = Date()) {
            self.app = app
            self.partner = partner
            self.wrote = wrote
            self.sent = sent
            self.outcome = outcome
            self.at = at
        }
    }

    public static let shared = WriteMemory()
    public static let limit = 300

    private let url: URL
    private let lock = NSLock()
    private var cache: [Entry]?

    public init(folder: URL? = nil) {
        let base = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Murmur", isDirectory: true)
        url = base.appendingPathComponent("written.json")
    }

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let read = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode([Entry].self, from: $0) } ?? []
        cache = read
        return read
    }

    public func add(_ entry: Entry) {
        var all = entries
        all.append(entry)
        if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
        lock.lock()
        defer { lock.unlock() }
        cache = all
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(all) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        cache = []
        try? FileManager.default.removeItem(at: url)
    }

    /// What happened to `wrote`, from what the box held when it was last seen with text in it (`last`), what it held
    /// before Murmur wrote (`before`), and whether it then emptied (a chat box empties when the message is sent).
    /// nil when it can't be told (you moved away with the text still there).
    public static func outcome(wrote: String, before: String, last: String, emptied: Bool) -> (Outcome, sent: String?)? {
        func plain(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let wrote = plain(wrote), before = plain(before), last = plain(last)
        // Back to what was there before, or cleared without ever being sent as text: taken back.
        if last == before || last.isEmpty { return emptied && last.isEmpty ? nil : (.reverted, nil) }
        guard emptied else { return nil }
        if last == wrote { return (.kept, wrote) }
        // Nothing of what Murmur wrote is left: you wrote your own instead.
        return overlap(last, wrote) < 0.3 ? (.reverted, nil) : (.edited, last)
    }

    /// The share of `b`'s words that are in `a`.
    public static func overlap(_ a: String, _ b: String) -> Double {
        let words = { (text: String) in text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let have = Set(words(a)), want = words(b)
        guard !want.isEmpty else { return 0 }
        return Double(want.filter(have.contains).count) / Double(want.count)
    }

    /// Messages you really sent in `app` (to `partner` first, then anyone), newest first, your own rewrites before
    /// ones sent as written: examples of how you write there. At most `count`, each at most 400 characters.
    public func examples(app: String, partner: String?, count: Int = 5) -> [String] {
        let sent = entries.filter { $0.app == app && $0.outcome != .reverted && ($0.sent ?? "").count >= 8 }.reversed()
        let rank = { (entry: Entry) -> Int in
            (entry.partner != nil && entry.partner == partner ? 0 : 2) + (entry.outcome == .edited ? 0 : 1)
        }
        var out: [String] = []
        for entry in sent.sorted(by: { rank($0) < rank($1) }) {
            guard let text = entry.sent.map({ String($0.prefix(400)) }), !out.contains(text) else { continue }
            out.append(text)
            if out.count == count { break }
        }
        return out
    }

    /// What you changed, lately, in what Murmur wrote for `app`: its text and yours, newest first.
    public func corrections(app: String, count: Int = 3) -> [(wrote: String, sent: String)] {
        entries.filter { $0.app == app && $0.outcome == .edited }.suffix(count).reversed().compactMap { entry in
            entry.sent.map { (String(entry.wrote.prefix(300)), String($0.prefix(300))) }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
