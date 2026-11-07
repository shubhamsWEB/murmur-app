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
    /// What screen memory saw: open loops, the chronicle, the time ledger (same file, its own connection).
    public nonisolated let journal: Journal
    /// Vectors for search by meaning (EmbeddingGemma 2, in the memory service).
    public nonisolated let vectors: MemoryVectors
    public nonisolated var search: MemorySearch { MemorySearch(store: store, journal: journal, vectors: vectors) }
    /// The timeline under screen memory: items read from windows, episodes of work, how entities connect.
    public nonisolated let graph: MemoryGraph

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
        journal = Journal()
        vectors = MemoryVectors()
        graph = MemoryGraph()
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
        // Anything read by the model on: Murmur's own reading model comes down if it isn't here yet.
        if !LocalReader.installed, BrainSource.allCases.contains(where: { $0.needsModel && state($0).enabled })
            || ScreenMemory.shared.settings.enabled || !ConnectorTools.shared.names.isEmpty {
            ReaderDownload.shared.ensure()
        }
        reader = await BrainDistiller.model()
        for source in only.map({ [$0] }) ?? BrainSource.allCases where state(source).enabled {
            await sync(source, readNow: now || only != nil)
        }
        if only == nil { await syncApps(readNow: now) }
        // Everything new gets its vector, for search by meaning.
        if LocalReader.embedderInstalled {
            activity = "Indexing memories by meaning"
            let search = self.search
            await Task.detached(priority: .utility) {
                await search.catchUp(batches: 40) { await LocalReader.embed($0, query: false) }
            }.value
        }
        if Date().timeIntervalSince(lastTidy) > 6 * 3600 {
            await off { $0.tidy() }
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
        let name = source.rawValue, complete = listing.complete
        let fresh = await off { $0.changed(source: name, items: items, complete: complete) }
        var learned = BrainStore.Applied()

        if !source.needsModel {
            // Thousands of contacts or events: written on a background thread, never the main one.
            let entries = listing.entries.filter { fresh.contains($0.key) }
            learned = await off { store in
                var learned = BrainStore.Applied()
                for entry in entries {
                    let item = "\(name):\(entry.key)"
                    store.clear(item: item)   // what it says now replaces what it said
                    learned.add(store.apply(entry.candidates, item: item))
                    store.read(source: name, key: entry.key, hash: entry.hash)
                    if name == BrainSource.contacts.rawValue, entry.key == "me", let me = store.entity(named: "me", kind: .me) {
                        store.addAlias(entry.title, to: me)
                        if let first = entry.title.split(separator: " ").first, first.count > 2 { store.addAlias(String(first), to: me) }
                    }
                }
                return learned
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

    /// What connected apps (Linear, Notion, Jira…) show now: read by the model when it changed.
    private func syncApps(readNow: Bool) async {
        guard let reader else { return }
        let lessons = await Connectors.shared.lessons()
        for (connector, lesson, raw) in lessons {
            guard readNow || Self.idleSeconds() > 120 else { break }
            let source = "app.\(connector.id)", hash = BrainSources.hash([raw])
            let fresh = await off { $0.changed(source: source, items: [lesson.key: (hash, lesson.title)], complete: false) }
            guard fresh.contains(lesson.key) else { continue }
            activity = "Reading \(connector.name)"
            let candidates = await BrainDistiller.distill(BrainModel.redact(raw), title: lesson.title, origin: .apps,
                                                          model: reader)
            let item = "\(source):\(lesson.key)"
            _ = await off { store in
                store.clear(item: item)
                let applied = store.apply(candidates, item: item)
                store.read(source: source, key: lesson.key, hash: hash)
                return applied
            }
            revision += 1
        }
    }

    /// Runs store work on a background thread (SQLite writes for a whole source can take a moment).
    private func off<T: Sendable>(_ work: @escaping @Sendable (BrainStore) -> T) async -> T {
        let store = self.store
        return await Task.detached(priority: .utility) { work(store) }.value
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
    public nonisolated func context(for utterance: String, limit: Int = 1200) async -> String? {
        // The command's meaning, for search by meaning; words and names alone when the model isn't there.
        var vector: [Float]?
        if LocalReader.embedderInstalled {
            vector = await LocalReader.embed([utterance], query: true, start: false)?.first
            if vector == nil { LocalReader.warm() }   // ready for the next command
        }
        let search = self.search
        var hits = search.memories(utterance, vector: vector, limit: 14).filter { $0.memory.origin != .told }
        let lower = utterance.lowercased()
        if ["today", "tomorrow", "this week", "next week", "meeting", "schedule", "free", "busy", "remind", "to do",
            "todo", "agenda", "calendar"].contains(where: lower.contains) {
            let known = Set(hits.map(\.id))
            hits += store.upcoming(limit: 8).filter { !known.contains($0.id) }
        }
        // What screen memory adds: what's certain (a flight, a release) and what you did, then open loops, what you
        // did, what you saw (when the command is about them).
        var extra = MemoryRecall.isAboutTheUsersWork(utterance)
            ? MemoryRecall.lines(for: utterance, graph: graph, brain: store, vectors: vectors, vector: vector, limit: 6) : []
        extra += Recall.context(journal, for: utterance)
        let related = search.related(vector)
        extra += related.loops.prefix(3).map { "- Open loop (\($0.label.lowercased())): \(Nudges.describe($0, now: Date()))" }
        extra += related.chronicle.map { "- \($0)" }
        extra += related.seen.map(Recall.seen)
        var unique: [String] = []
        for line in extra where !unique.contains(line) { unique.append(line) }
        extra = unique
        guard !hits.isEmpty || !extra.isEmpty else { return nil }
        var lines: [String] = []
        var used: [Int64] = []
        var length = 0
        for line in extra where length + line.count <= limit / 2 {
            lines.append(line)
            length += line.count + 1
        }
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
    public nonisolated func ask(_ query: String) async -> String {
        let vector = LocalReader.embedderInstalled ? await LocalReader.embed([query], query: true)?.first : nil
        let search = self.search
        let hits = search.memories(query, vector: vector, limit: 20)
        // From the top down: what's certain from the windows, the episodes of work, how things connect; then promises,
        // summaries and windows.
        let structure = MemoryRecall.lines(for: query, graph: graph, brain: store, vectors: vectors, vector: vector)
        var extra = Recall.answer(journal, for: query)
        let related = search.related(vector)
        extra += related.loops.map { "- \($0.label): \(Nudges.describe($0, now: Date())) [open loop]" }
        extra += related.chronicle.map { "- \($0) [your summary]" }
        extra += related.seen.map(Recall.seen)
        var unique: [String] = []
        for line in extra where !unique.contains(line) { unique.append(line) }
        extra = unique
        guard !hits.isEmpty || !extra.isEmpty || !structure.isEmpty else { return "Nothing in Murmur's memory about \"\(query)\"." }
        store.used(hits.map(\.id))
        return (structure + hits.map { hit in
            let sure = hit.memory.pinned ? "told by the user" : hit.memory.confidence >= 0.9 ? "certain" : "likely"
            let when = hit.memory.confirmed.formatted(.dateTime.day().month(.abbreviated).year())
            return "- \(hit.memory.text) [about \(hit.about); from \(hit.memory.origin.display), \(when); \(sure)]"
        } + extra).joined(separator: "\n")
    }

    /// Screen memory's helper wrote something (a loop, a summary): the Memory page reloads.
    public func journalChanged() { revision += 1 }

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
