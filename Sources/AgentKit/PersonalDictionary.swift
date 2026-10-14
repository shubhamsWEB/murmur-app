import Combine
import Foundation

/// Words and names Murmur should always spell your way ("Copico", "Kubernetes", "Riya"), and what the speech model
/// tends to hear instead ("kopiko", "cuber nettis"). You add entries in Settings; Murmur also learns them when you
/// correct a word it typed (`CorrectionLearner`). Kept in UserDefaults, on this Mac.
public struct DictionaryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { written.lowercased() }
    /// How it should be written.
    public var written: String
    /// What the speech model wrote instead (matched as whole words, ignoring case).
    public var heard: [String]
    /// Learned from a correction you made, rather than added by hand.
    public var learned: Bool

    public init(written: String, heard: [String] = [], learned: Bool = false) {
        self.written = written
        self.heard = heard
        self.learned = learned
    }
}

@MainActor
public final class PersonalDictionary: ObservableObject {
    public static let shared = PersonalDictionary()
    private static let key = "personalDictionary"

    @Published public private(set) var entries: [DictionaryEntry] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            entries = saved
        }
    }

    /// The words and names to spell your way, for the AI pass.
    public var terms: [String] { entries.map(\.written) }

    /// Adds a word (and optionally what it's heard as); an entry for the same word gains the new spellings.
    public func add(_ written: String, heard: [String] = [], learned: Bool = false) {
        let word = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let variants = heard.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != word.lowercased() }   // a case-only difference: `apply` fixes it
        if let index = entries.firstIndex(where: { $0.written.lowercased() == word.lowercased() }) {
            var entry = entries[index]
            entry.written = word
            for variant in variants where !entry.heard.contains(where: { $0.lowercased() == variant.lowercased() }) {
                entry.heard.append(variant)
            }
            entry.learned = entry.learned && learned
            entries[index] = entry
        } else {
            entries.append(DictionaryEntry(written: word, heard: variants, learned: learned))
        }
        entries.sort { $0.written.localizedCaseInsensitiveCompare($1.written) == .orderedAscending }
        save()
    }

    public func remove(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// A correction you made to text Murmur typed: `heard` was typed, you changed it to `written`.
    public func learn(heard: String, written: String) {
        guard heard != written else { return }
        add(written, heard: [heard], learned: true)   // a capitals-only fix adds just the word: `apply` keeps its case
    }

    /// Your spellings applied to a transcript: what's heard becomes what's written, and the word itself gets your
    /// capitals ("copico" → "Copico"). Whole words only, ignoring case.
    public func apply(_ text: String) -> String {
        var out = text
        for entry in entries {
            for variant in entry.heard + [entry.written] {
                let pattern = #"(?i)(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: variant)
                    + #"(?![\p{L}\p{N}])"#
                out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: entry.written),
                                               options: .regularExpression)
            }
        }
        return out
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
