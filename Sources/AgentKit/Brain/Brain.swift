import AppKit
import CoreGraphics
import Observation

/// Murmur's living memory: a second brain that keeps itself current.
///
/// Every half hour (and at launch) each source that's switched on is listed; only what changed is read. Contacts,
/// Calendar, Reminders and what you told Murmur become memories at once. Notes and Mail wait until the Mac has been
/// idle for a couple of minutes, then the local model reads them a few at a time. Memories a source says again get
/// surer; a newer value replaces the old one; what's deleted at the source is forgotten; what nobody says again fades
/// and is archived. Nothing leaves the Mac.
///
/// Each command gets the memories it needs (`context(for:)`), and "what do you know about…" questions are answered
/// with sources (`ask(_:)`).
@MainActor
@Observable
public final class Brain {
    public static let shared = Brain()

    public nonisolated let store: BrainStore

    /// Bumped when what's known changes, so the Memory page reloads.
    public private(set) var revision = 0
    /// What it's doing now, for the Memory page ("Reading Notes, 3 of 12"); nil when resting.
    public private(set) var activity: String?
    /// The model reading Notes and Mail, or nil when Ollama has no general model.
    public private(set) var reader: String?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var lastTidy = Date.distantPast

    init(store: BrainStore = BrainStore()) {
        self.store = store
    }

    // MARK: Running

    /// Starts keeping memory current: now, then every 30 minutes.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)   // let launch settle first
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func state(_ source: BrainSource) -> BrainStore.SourceState {
        store.source(source.rawValue, enabledByDefault: source.onByDefault)
    }

    /// Turns a source on (asking macOS for access, then reading it) or off (forgetting what it taught).
    public func set(_ source: BrainSource, enabled: Bool) async {
        store.setSource(source.rawValue, enabled: enabled)
        if enabled {
            await sync(only: source)
        } else {
            store.forget(origin: source.origin)
            store.synced(source.rawValue, status: "Off", items: 0, enabled: false)
            revision += 1
        }
    }

    /// Reads every source that's on (or just one), now. Notes and Mail are read straight away too.
    public func sync(only: BrainSource? = nil, now: Bool = false) async {
        guard !running else { return }
        running = true
        defer { running = false; activity = nil; revision += 1 }
        reader = await BrainDistiller.model()
        for source in only.map({ [$0] }) ?? BrainSource.allCases where state(source).enabled {
            await sync(source, readNow: now || only != nil)
        }
        if Date().timeIntervalSince(lastTidy) > 6 * 3600 {
            store.tidy()
            lastTidy = Date()
        }
    }

    private func sync(_ source: BrainSource, readNow: Bool) async {
        activity = "Looking at \(source.title)"
        guard let listing = await BrainSources.list(source) else {
            store.synced(source.rawValue, status: source.needsModel ? "Murmur can't open \(source.title) yet. Allow it in "
                         + "System Settings › Privacy & Security › Automation." : "Murmur needs access to "
                         + "\(source.title). Allow it in System Settings › Privacy & Security.", items: nil, enabled: true)
            return
        }
        var items: [String: (hash: String, title: String)] = [:]
        for entry in listing.entries where items[entry.key] == nil { items[entry.key] = (entry.hash, entry.title) }
        let fresh = store.changed(source: source.rawValue, items: items, complete: listing.complete)
        var learned = BrainStore.Applied()

        if !source.needsModel {
            for entry in listing.entries where fresh.contains(entry.key) {
                let item = "\(source.rawValue):\(entry.key)"
                store.clear(item: item)   // what it says now replaces what it said
                learned.add(store.apply(entry.candidates, item: item))
                store.read(source: source.rawValue, key: entry.key, hash: entry.hash)
                if source == .contacts, entry.key == "me", let me = store.entity(named: "me", kind: .me) {
                    store.addAlias(entry.title, to: me)
                    if let first = entry.title.split(separator: " ").first, first.count > 2 { store.addAlias(String(first), to: me) }
                }
            }
            store.synced(source.rawValue, status: summary(learned, items: listing.entries.count, source: source),
                         items: listing.entries.count, enabled: true)
            revision += 1
            return
        }

        // Read by the model: newest first, a few each time, only while you're away from the Mac.
        let waiting = listing.entries.filter { fresh.contains($0.key) && $0.hash != "old" }
            .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
        for entry in listing.entries where fresh.contains(entry.key) && entry.hash == "old" {
            store.read(source: source.rawValue, key: entry.key, hash: entry.hash)   // too old to be worth reading
        }
        guard let reader else {
            store.synced(source.rawValue, status: waiting.isEmpty ? "Up to date" : "\(waiting.count) waiting. "
                         + "Install a general model in Ollama to read them (ollama pull qwen3:4b).",
                         items: listing.entries.count, enabled: true)
            return
        }
        let batch = Array(waiting.prefix(source == .notes ? 25 : 40))
        var texts: [String: String] = [:]
        if source == .notes { texts = await BrainSources.noteTexts(batch.map(\.key)) }
        var done = 0
        for (index, entry) in batch.enumerated() {
            guard readNow || Self.idleSeconds() > 120 else { break }   // you're back: stop, carry on later
            activity = "Reading \(source.title), \(index + 1) of \(batch.count)"
            let text = BrainModel.redact(entry.text ?? texts[entry.key] ?? "")
            let item = "\(source.rawValue):\(entry.key)"
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
                let candidates = await BrainDistiller.distill(text, title: entry.title, origin: source.origin, model: reader)
                store.clear(item: item)
                learned.add(store.apply(candidates, item: item))
                revision += 1
            }
            store.read(source: source.rawValue, key: entry.key, hash: entry.hash)
            done += 1
        }
        let left = waiting.count - done
        store.synced(source.rawValue, status: left > 0 ? "\(summary(learned, items: nil, source: source)) \(left) still to "
                     + "read, while you're away." : summary(learned, items: listing.entries.count, source: source),
                     items: listing.entries.count, enabled: true)
    }

    private func summary(_ applied: BrainStore.Applied, items: Int?, source: BrainSource) -> String {
        var parts: [String] = []
        if applied.added > 0 { parts.append("learned \(applied.added)") }
        if applied.replaced > 0 { parts.append("updated \(applied.replaced)") }
        if parts.isEmpty { return items.map { "Up to date, \($0) \(source == .commands ? "facts" : "items")." } ?? "" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + String(text.dropFirst()) + "."
    }

    /// Seconds since the last key press, click or mouse move.
    nonisolated static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Using it

    /// What a command should know: who and what it names, what matches its words, and what's coming up when it's
    /// about time. At most ~1,200 characters. Nil when nothing applies. Used memories fade more slowly.
    public nonisolated func context(for utterance: String, limit: Int = 1200) -> String? {
        var hits = store.search(utterance, limit: 14).filter { $0.memory.origin != .told }   // told: already given
        let lower = utterance.lowercased()
        if ["today", "tomorrow", "this week", "next week", "meeting", "schedule", "free", "busy", "remind", "to do",
            "todo", "agenda", "calendar"].contains(where: lower.contains) {
            let known = Set(hits.map(\.id))
            hits += store.upcoming(limit: 8).filter { !known.contains($0.id) }
        }
        guard !hits.isEmpty else { return nil }
        var lines: [String] = []
        var used: [Int64] = []
        var length = 0
        for hit in hits {
            let line = "- \(hit.memory.text)"
            guard length + line.count <= limit else { break }
            lines.append(line)
            used.append(hit.id)
            length += line.count + 1
        }
        store.used(used)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// An answer to "what do you know about…": the memories that match, each with where it came from and how sure
    /// Murmur is, for the model to answer from.
    public nonisolated func ask(_ query: String) -> String {
        let hits = store.search(query, limit: 20)
        guard !hits.isEmpty else { return "Nothing in Murmur's memory about \"\(query)\"." }
        store.used(hits.map(\.id))
        return hits.map { hit in
            let sure = hit.memory.pinned ? "told by the user" : hit.memory.confidence >= 0.9 ? "certain" : "likely"
            let when = hit.memory.confirmed.formatted(.dateTime.day().month(.abbreviated).year())
            return "- \(hit.memory.text) [about \(hit.about); from \(hit.memory.origin.display), \(when); \(sure)]"
        }.joined(separator: "\n")
    }

    /// Forgets one memory, everything about one entity, or everything.
    public func forget(memory id: Int64) { store.forget(memory: id); revision += 1 }
    public func forget(entity id: Int64) { store.forget(entity: id); revision += 1 }
    public func forgetAll() { store.forgetAll(); revision += 1 }
}

extension BrainStore.Applied {
    mutating func add(_ other: BrainStore.Applied) {
        added += other.added
        confirmed += other.confirmed
        replaced += other.replaced
    }
}
