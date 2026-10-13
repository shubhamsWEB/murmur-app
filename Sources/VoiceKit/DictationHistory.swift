import Foundation

/// Your recent dictations and commands, kept on this Mac only (Application Support/Murmur/history.json), newest first.
/// Turn it off in Murmur → Dictation; turning it off also clears it.
@MainActor
public final class DictationHistory: ObservableObject {
    public struct Item: Codable, Identifiable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case dictation
            case command
        }

        public let id: UUID
        public let date: Date
        public let text: String
        public let app: String?
        public let kind: Kind
    }

    public static let shared = DictationHistory()
    public static let limit = 200

    @Published public private(set) var items: [Item] = []

    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepHistory") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "keepHistory")
            if !newValue { clear() }
            objectWillChange.send()
        }
    }

    private let file: URL = {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Murmur")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    public func add(_ text: String, app: String?, kind: Item.Kind) {
        guard isEnabled, !text.isEmpty else { return }
        items.insert(Item(id: UUID(), date: Date(), text: text, app: app, kind: kind), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    public func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    public func clear() {
        items = []
        try? FileManager.default.removeItem(at: file)
    }

    /// Words dictated today (for the Home screen).
    public var wordsToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return items.filter { $0.kind == .dictation && $0.date >= start }
            .reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
