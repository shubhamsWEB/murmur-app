import AppKit

/// The apps installed on this Mac, found by what you call them ("chrome", "vs code", "i term", "settings").
public final class AppCatalog: @unchecked Sendable {
    public struct App: Sendable {
        public let name: String
        public let url: URL
        public let bundleID: String?
        let key: String
    }

    public static let shared = AppCatalog()

    private let lock = NSLock()
    private var apps: [App] = []
    private var loadedAt = Date.distantPast

    /// Spoken names that don't match an app's name.
    private let aliases: [String: String] = [
        "chrome": "googlechrome", "vscode": "visualstudiocode", "code": "visualstudiocode",
        "settings": "systemsettings", "systempreferences": "systemsettings", "preferences": "systemsettings",
        "appstore": "appstore", "mail": "mail", "messages": "messages", "imessage": "messages",
        "facetime": "facetime", "word": "microsoftword", "excel": "microsoftexcel",
        "powerpoint": "microsoftpowerpoint", "outlook": "microsoftoutlook", "teams": "microsoftteams",
        "whatsapp": "whatsapp", "music": "music", "itunes": "music", "activitymonitor": "activitymonitor",
        "taskmanager": "activitymonitor", "intellij": "intellijidea", "idea": "intellijidea",
    ]

    public init() {}

    public var all: [App] {
        refreshIfStale()
        lock.lock(); defer { lock.unlock() }
        return apps
    }

    /// The best match for a spoken name, or nil when nothing is close enough.
    public func resolve(_ spoken: String) -> App? {
        matches(spoken, limit: 1).first
    }

    /// Apps whose names match `spoken`, best first.
    public func matches(_ spoken: String, limit: Int = 5) -> [App] {
        var query = Self.key(spoken)
        for suffix in ["app", "application"] where query.hasSuffix(suffix) && query.count > suffix.count + 2 {
            query.removeLast(suffix.count)
        }
        guard !query.isEmpty else { return [] }
        let target = aliases[query] ?? query
        let scored: [(App, Int)] = all.compactMap { app in
            let score = Self.score(target, app.key)
            return score > 0 ? (app, score) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.count < $1.0.name.count }
            .prefix(limit).map(\.0)
    }

    static func score(_ query: String, _ name: String) -> Int {
        if name == query { return 100 }
        if name.hasPrefix(query) { return 85 }
        if name.contains(query) { return 70 }
        if query.count >= 5, name.count >= 4, distance(query, name) <= 2 { return 55 }
        // "slackapp": the name plus a little; not "terminalandrunls", which is more than an app name.
        if query.hasPrefix(name), name.count >= 4, query.count <= name.count + 4 { return 50 }
        return 0
    }

    static func key(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    private func refreshIfStale() {
        lock.lock()
        let stale = Date().timeIntervalSince(loadedAt) > 300
        lock.unlock()
        guard stale else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", "/System/Library/CoreServices/Applications",
                       home.appendingPathComponent("Applications").path]
        var found: [String: App] = [:]
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                let display = String(name.dropLast(4))
                let key = Self.key(display)
                if found[key] == nil {
                    found[key] = App(name: display, url: url, bundleID: Bundle(url: url)?.bundleIdentifier, key: key)
                }
            }
        }
        lock.lock()
        apps = Array(found.values)
        loadedAt = Date()
        lock.unlock()
    }

    /// Levenshtein distance (short strings only).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
