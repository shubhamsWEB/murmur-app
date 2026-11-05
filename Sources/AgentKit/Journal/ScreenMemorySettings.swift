import Foundation

/// What screen memory never reads beyond the built-in list (`ScreenReader.neverRead`), and whether it may read a
/// picture of a window whose text shows little.
public struct ScreenRules: Sendable, Equatable, Codable {
    /// Apps (bundle ids) and sites (domains) you excluded.
    public var excluded: [String] = []
    public var pictures = true
    /// Keep what the user writes and sends (a message, an edit), as theirs: the surest sign of what they said.
    public var authored = true

    public init() {}

    enum CodingKeys: String, CodingKey { case excluded, pictures, authored }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        excluded = try values.decodeIfPresent([String].self, forKey: .excluded) ?? []
        pictures = try values.decodeIfPresent(Bool.self, forKey: .pictures) ?? true
        authored = try values.decodeIfPresent(Bool.self, forKey: .authored) ?? true
    }
}

/// Screen memory's settings, in a file both the app and its helper read
/// (~/Library/Application Support/Murmur/screen-memory.json).
public struct ScreenMemorySettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var rules = ScreenRules()
    /// Only read between these hours (24-hour clock); `always` ignores them.
    public var always = true
    public var from = 9
    public var to = 19
    public var weekends = true
    /// A morning brief and an evening wrap-up, at these times ("09:00", "18:30"); empty for none.
    public var brief = "09:00"
    public var wrap = "18:30"

    public init() {}

    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Murmur/screen-memory.json")

    public static func load() -> ScreenMemorySettings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ScreenMemorySettings.self, from: $0) }
            ?? ScreenMemorySettings()
    }

    public func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }

    /// Whether now is within the reading hours.
    public func readsNow(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        if always { return true }
        if !weekends, calendar.isDateInWeekend(date) { return false }
        let hour = calendar.component(.hour, from: date)
        return from <= to ? (hour >= from && hour < to) : (hour >= from || hour < to)
    }
}

