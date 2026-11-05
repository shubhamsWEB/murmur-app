import Foundation

/// Which windows the reading model reads, in what order, and how much of each: decided before the model, in
/// milliseconds, so its time goes where memories come from.
///
/// - Conversations and the user's own work: always, first.
/// - AI chats: only what the user wrote in them.
/// - Feeds, videos, articles, product sites, search: only when they mention the user or someone they know, or the
///   user wrote something there. Otherwise they stay what they are, something seen (searchable for two weeks).
/// - Other pages and apps: when their meaning is close to what matters to the user (EmbeddingGemma: the window's
///   vector against the average of the user's most important memories), or they mention the user or people they know.
/// - A window read before: only what's new in it; nothing new, nothing read.
public enum Triage {
    public struct Plan: Sendable {
        /// What to read, best first, with the text to read (all of it, or only what's new).
        public var read: [Journal.Snapshot] = []
        /// What needn't be read, with why ("a feed, not about you").
        public var skip: [(id: Int64, why: String)] = []
    }

    /// Below this, a page's meaning is too far from what matters to the user to read (EmbeddingGemma 2 runs high:
    /// unrelated text scores 0.55 to 0.65 against a single memory, and lower against their average).
    public static let relevanceFloor: Float = 0.5

    public static func plan(_ pending: [Journal.Snapshot], me: [String], known: (String) -> [String],
                            relevance: (Journal.Snapshot) -> Float? = { _ in nil }) -> Plan {
        var plan = Plan()
        var first: [Journal.Snapshot] = [], later: [Journal.Snapshot] = []
        for var snapshot in pending {
            let kind = WindowKind.of(snapshot)
            // Only what's new since the model last read it.
            if !snapshot.readText.isEmpty {
                let before = Set(snapshot.readText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
                let fresh = snapshot.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !before.contains($0) }
                let words = fresh.joined(separator: " ").split(separator: " ").count
                if words < 8, snapshot.authored.isEmpty, snapshot.seenAs.isEmpty {
                    plan.skip.append((snapshot.id, "nothing new since it was read"))
                    continue
                }
                snapshot = with(snapshot, text: "New since it was last read:\n" + fresh.joined(separator: "\n"))
            }
            let text = snapshot.title + "\n" + snapshot.text
            let aboutUser = Engagement.mentions(text, any: me) || !known(String(text.prefix(6000))).isEmpty
                || !snapshot.authored.isEmpty
            switch kind {
            case .conversation, .work:
                first.append(snapshot)
            case .assistant:
                if snapshot.authored.isEmpty {
                    plan.skip.append((snapshot.id, "an AI chat with nothing you sent"))
                } else {
                    later.append(with(snapshot, text: "What the user asked the assistant:\n" + snapshot.authored))
                }
            case .feed, .video, .article, .product, .search:
                if aboutUser { later.append(snapshot) } else { plan.skip.append((snapshot.id, "\(kind.label), not about you")) }
            case .page, .app, .docs:
                if aboutUser {
                    later.append(snapshot)
                } else if let score = relevance(snapshot), score < relevanceFloor {
                    plan.skip.append((snapshot.id, "far from what matters to you"))
                } else {
                    later.append(snapshot)
                }
            }
        }
        plan.read = first.sorted { $0.seconds > $1.seconds } + later.sorted { $0.seconds > $1.seconds }
        return plan
    }

    static func with(_ snapshot: Journal.Snapshot, text: String) -> Journal.Snapshot {
        var copy = Journal.Snapshot(id: snapshot.id, app: snapshot.app, title: snapshot.title, url: snapshot.url,
                                    domain: snapshot.domain, text: text, first: snapshot.first, last: snapshot.last,
                                    seconds: snapshot.seconds, sightings: snapshot.sightings, kind: snapshot.kind,
                                    authored: snapshot.authored, seenAs: snapshot.seenAs)
        copy.readText = snapshot.readText
        return copy
    }
}
