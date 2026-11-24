import Foundation

/// A meeting as kept on this Mac, beside the Markdown file in Documents › Murmur Meetings: what each line was, when,
/// from which side and voice, who the voices are, and the notes. Later releases build on it (playing a line back,
/// renaming speakers afterwards, notes that point at lines); the Windows app writes the same file.
///
/// `~/Library/Application Support/Murmur/Meetings/<id>/meeting.json`, the id being the start time
/// ("2026-11-24T14-30-05"), so folders sort by date.
public struct MeetingRecord: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public var id: Int
        /// Seconds from the start of the meeting.
        public var t: Double
        /// "you" or "them".
        public var side: String
        /// The voice on the call (MeetingVoices), when Murmur could tell.
        public var voice: Int?
        public var text: String
    }

    public struct Voice: Codable, Equatable, Sendable {
        public var voice: Int
        /// Speaker number as shown; nil for a voice that never came on show.
        public var number: Int?
        public var name: String?
        /// Where the name came from: user, library, window, conversation.
        public var source: String?
        public var evidence: String?
    }

    public var version = 1
    public var id: String
    public var started: Date
    public var ended: Date
    public var app: String?
    public var about: String?
    public var lines: [Line]
    public var voices: [Voice]
    public var notesMarkdown: String

    public init(started: Date, ended: Date, app: String?, about: String?, lines: [MeetingLine],
                numbers: [Int: Int], names: [Int: VoiceName], notes: String) {
        id = Self.id(for: started)
        self.started = started
        self.ended = ended
        self.app = app
        self.about = about?.isEmpty == true ? nil : about
        self.lines = lines.map {
            Line(id: $0.id, t: (max(0, $0.at.timeIntervalSince(started)) * 10).rounded() / 10,
                 side: $0.speaker == .you ? "you" : "them", voice: $0.voice, text: $0.text)
        }
        let heard = Set(lines.compactMap(\.voice)).union(names.keys)
        voices = heard.sorted().map { voice in
            let name = names[voice].flatMap { $0.name.isEmpty ? nil : $0 }
            return Voice(voice: voice, number: numbers[voice], name: name?.name, source: name?.source.rawValue,
                         evidence: name?.evidence)
        }
        notesMarkdown = notes
    }

    /// "2026-11-24T14-30-05" in the Mac's time zone.
    public static func id(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: date)
    }

    /// Where meetings are kept: Application Support › Murmur › Meetings.
    public static var folder: URL? {
        if let debug = UserDefaults.standard.string(forKey: "debugMeetingsFolder") {
            return URL(fileURLWithPath: (debug as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("Records", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Murmur/Meetings", isDirectory: true)
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes the record into its folder under `root` (Meetings), only this user able to read it.
    @discardableResult
    public func write(under root: URL) throws -> URL {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("meeting.json")
        try Self.encoder.encode(self).write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
