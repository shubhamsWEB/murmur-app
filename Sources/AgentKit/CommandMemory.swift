import Foundation

/// The last few commands and what they did, so the next one can follow on: "send Roma a message saying hi", then
/// "and also ask when she's coming back" (she: Roma; the app: WhatsApp). In memory only, for a quarter of an hour.
public enum CommandMemory {
    struct Entry {
        let said: String
        let app: String?
        let did: [String]
        let at: Date
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []
    private static let keep: TimeInterval = 15 * 60

    static func add(_ said: String, app: String?, did: [String]) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(said: said, app: app, did: did, at: Date()))
        entries = Array(entries.filter { Date().timeIntervalSince($0.at) < keep }.suffix(5))
    }

    /// Seconds since the last command finished.
    public static var sinceLast: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return entries.last.map { Date().timeIntervalSince($0.at) }
    }

    /// For the model: the recent commands, oldest first, with what each did.
    static func summary() -> String? {
        lock.lock()
        let recent = entries.filter { Date().timeIntervalSince($0.at) < keep }
        lock.unlock()
        guard !recent.isEmpty else { return nil }
        return recent.map { entry in
            let minutes = Int(Date().timeIntervalSince(entry.at) / 60)
            let when = minutes < 1 ? "just now" : "\(minutes) min ago"
            let did = entry.did.suffix(6).map { "\n    did: \($0)" }.joined()
            return "- \(when), in \(entry.app ?? "?"): \"\(entry.said)\"\(did)"
        }.joined(separator: "\n")
    }

    /// "and also ask when she's coming back", "tell him too", "do that again", "send it", said within a few minutes
    /// of a command: it follows on from it, so it's a command too (it was typed into the box as dictation).
    public static func isFollowUp(_ utterance: String) -> Bool {
        guard let since = sinceLast, since < 300 else { return false }
        let text = QuickCommands.clean(utterance)
        return text.range(of: #"^(and|also|and also|then|and then|plus|oh and|one more thing|after that)\b|^(tell|ask|send|message|text|reply to|remind|let|call|ping|email|show|give) (her|him|them|it|that|those)\b|^(do it|do that|same|same thing|again|do it again|try again|undo that|send it|send that|open it|play it|reply)\b|\b(her|him|them)\b.*\b(too|also|as well)\b"#,
                          options: .regularExpression) != nil
    }
}
