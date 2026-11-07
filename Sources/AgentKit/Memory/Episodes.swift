import Foundation

/// The timeline cut into episodes: stretches of one piece of work ("Releasing Murmur 1.6.0", "Talking to Priya about
/// the Acme deal"), by rules, never by a model. A sighting is one stay in one window. Consecutive sightings belong to
/// one episode while they share what they're about (a project, a conversation, a site), with room for a quick look
/// elsewhere (a glance at Slack while coding) and for looking things up (docs, a search, an AI chat) for the work in
/// hand. Ten minutes away, or a sustained switch to something else, ends it.
public enum Episodes {
    public struct Sighting: Sendable, Equatable {
        public var id: Int64
        public var snapshot: Int64
        public var start: Date
        public var end: Date
        public var app: String
        public var title: String
        public var domain: String
        public var kind: WindowKind
        /// What it's about: "project:murmur", "person:priya sharma", "site:goindigo.in", "app:finder".
        public var context: String
        /// The project it's part of (its plain core: "murmur"), "" when none.
        public var project: String

        public init(id: Int64, snapshot: Int64, start: Date, end: Date, app: String, title: String, domain: String,
                    kind: WindowKind, context: String, project: String) {
            self.id = id
            self.snapshot = snapshot
            self.start = start
            self.end = end
            self.app = app
            self.title = title
            self.domain = domain
            self.kind = kind
            self.context = context
            self.project = project
        }

        public var seconds: Double { max(0, end.timeIntervalSince(start)) }
    }

    public struct Episode: Sendable, Equatable {
        public var key: String
        public var start: Date
        public var end: Date
        /// Time actually spent in it (its sightings), not end minus start.
        public var seconds: Double
        /// What it's about most (by time), and the project when it has one.
        public var context: String
        public var project: String
        public var apps: [String]
        /// The windows' titles, most time first (at most 8).
        public var titles: [String]
        public var sightings: [Int64]
        public var snapshots: [Int64]
        /// Ended: a later episode began, or nothing was seen for ten minutes.
        public var final: Bool
    }

    /// Away this long ends an episode.
    public static let gap: TimeInterval = 10 * 60
    /// A look elsewhere this short doesn't.
    public static let glance: TimeInterval = 120
    /// Looking things up for the work in hand, at most this long at a time.
    public static let lookup: TimeInterval = 15 * 60

    /// What a window is about, from what was read in it: its project, who a conversation is with, its site, its app.
    public static func context(project: String, person: String, domain: String, app: String) -> String {
        if !project.isEmpty { return "project:" + BrainModel.projectCore(project) }
        if !person.isEmpty { return "person:" + BrainModel.nameKey(person) }
        if !domain.isEmpty { return "site:" + domain.lowercased() }
        return "app:" + app.lowercased()
    }

    /// The sightings (in time order) as episodes, oldest first. The last is final only once `now` is ten minutes past
    /// its end.
    public static func segment(_ sightings: [Sighting], now: Date = Date()) -> [Episode] {
        let sorted = sightings.sorted { $0.start < $1.start }
        var groups: [[Sighting]] = []
        var current: [Sighting] = []
        var pendingAside: [Sighting] = []

        func contexts(_ group: [Sighting]) -> [String: Double] {
            var time: [String: Double] = [:]
            for sighting in group { time[sighting.context, default: 0] += max(sighting.seconds, 1) }
            return time
        }
        func project(_ group: [Sighting]) -> String {
            var time: [String: Double] = [:]
            for sighting in group where !sighting.project.isEmpty { time[sighting.project, default: 0] += max(sighting.seconds, 1) }
            return time.max { $0.value < $1.value }?.key ?? ""
        }
        func close() {
            if !current.isEmpty { groups.append(current) }
            current = []
        }

        for sighting in sorted {
            guard let last = (pendingAside.last ?? current.last) else { current = [sighting]; continue }
            if sighting.start.timeIntervalSince(last.end) > gap {
                current += pendingAside
                pendingAside = []
                close()
                current = [sighting]
                continue
            }
            // What the episode is about: what it began with, and what it stayed in (not a glance it took).
            let known = contexts(current).filter { $0.value >= glance || $0.key == current.first?.context }
            let mainProject = project(current)
            let belongs = known[sighting.context] != nil
                || (!sighting.project.isEmpty && sighting.project == mainProject)
                // Looking things up for a project's work: docs, a search, an AI chat, a page, briefly.
                || (!mainProject.isEmpty && sighting.project.isEmpty
                    && [.docs, .search, .assistant].contains(sighting.kind) && sighting.seconds <= lookup)
            if belongs {
                // What was looked at in between was an aside of this episode.
                current += pendingAside + [sighting]
                pendingAside = []
                continue
            }
            // Something else: a glance stays an aside for now; a longer stay (or asides adding up) starts the next.
            pendingAside.append(sighting)
            let aside = pendingAside.reduce(0) { $0 + $1.seconds }
            if aside > glance {
                close()
                current = pendingAside
                pendingAside = []
            }
        }
        // Asides at the end: their own episode when they're about one thing, else part of the last one.
        if !pendingAside.isEmpty {
            if Set(pendingAside.map(\.context)).count == 1, pendingAside.reduce(0, { $0 + $1.seconds }) >= 60 {
                close()
                current = pendingAside
            } else {
                current += pendingAside
            }
        }
        close()

        return groups.enumerated().map { index, group in
            let time = contexts(group)
            let main = time.max { $0.value < $1.value }?.key ?? group[0].context
            let start = group.map(\.start).min() ?? group[0].start
            let end = group.map(\.end).max() ?? group[0].end
            var byTitle: [String: Double] = [:]
            for sighting in group where !sighting.title.isEmpty { byTitle[sighting.title, default: 0] += max(sighting.seconds, 1) }
            var apps: [String] = []
            for sighting in group.sorted(by: { $0.seconds > $1.seconds }) where !apps.contains(sighting.app) { apps.append(sighting.app) }
            var snapshots: [Int64] = []
            for sighting in group where !snapshots.contains(sighting.snapshot) { snapshots.append(sighting.snapshot) }
            let isLast = index == groups.count - 1
            return Episode(key: "ep|\(Int(start.timeIntervalSince1970))|\(group[0].context)", start: start, end: end,
                           seconds: group.reduce(0) { $0 + $1.seconds }, context: main, project: project(group), apps: apps,
                           titles: byTitle.sorted { $0.value > $1.value }.prefix(8).map(\.key),
                           sightings: group.map(\.id), snapshots: snapshots,
                           final: !isLast || now.timeIntervalSince(end) >= gap)
        }
    }
}
