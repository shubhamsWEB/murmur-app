import Foundation

/// `murmur-memory report` and `murmur-memory ask "…"`, from Terminal: what screen memory has made of what you did, and
/// what it answers to a question, to check it against what really happened. Brings items and episodes up to date
/// first (by rules, the same as the helper does every few minutes); never runs the model, never sends anything.
public enum MemoryReport {
    public static func run(_ arguments: [String], brain: BrainStore = BrainStore(), journal: Journal = Journal(),
                           now: Date = Date()) -> Never {
        let graph = MemoryGraph(url: journal.url)
        let command = arguments.first ?? "report"
        graph.readItems(from: journal, me: brain.meNames(), now: now)
        graph.segment(now: now)
        switch command {
        case "ask":
            let question = arguments.dropFirst().joined(separator: " ")
            guard !question.isEmpty else { print("Usage: murmur-memory ask \"when is my flight?\""); exit(1) }
            print(MemoryServer(brain: brain, journal: journal).call("search_memory", ["query": question]))
        case "knowledge":
            // One round of the knowledge pipeline now: the due wiki pages, then the digest and the profile when they're
            // due. `murmur-memory knowledge 5`: up to five pages. Words after the number:
            // - `again`: the digest and profile written now even when they aren't due;
            // - `rewrite`: the pages written already, the first of them, rewritten (to compare models on the same ones);
            // - `cloud=anthropic` (or openai, sarvam): with that provider instead of the local model, its key on standard
            //   input as the app hands it over (MURMUR_KEYS_ON_STDIN=1), with what goes to it as when screen memory
            //   reads with it (secrets and private episodes out, no windows, nothing the user wrote).
            let limit = Int(arguments.dropFirst().first ?? "") ?? 3
            let again = arguments.contains("again"), rewrite = arguments.contains("rewrite")
            let cloud = arguments.first { $0.hasPrefix("cloud=") }.map { String($0.dropFirst(6)) }
            if cloud != nil { CloudReader.takeKeysFromStandardInput() }
            MemoryLog.echo = true
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await knowledge(brain: brain, journal: journal, graph: graph, limit: limit, again: again, rewrite: rewrite,
                                cloud: cloud)
                done.signal()
            }
            done.wait()
        default:
            print(report(brain: brain, journal: journal, graph: graph, now: now))
        }
        exit(0)
    }

    /// Writes what's due of the wiki, the digest and the profile, and prints what was written.
    static func knowledge(brain: BrainStore, journal: Journal, graph: MemoryGraph, limit: Int, again: Bool = false,
                          rewrite: Bool = false, cloud: CloudReader.Provider? = nil) async {
        let pageAsk: EpisodeReader.Ask, proseAsk: EpisodeReader.Ask, model: String
        if let cloud {
            guard let json = CloudReader.ask(cloud), let prose = CloudReader.ask(cloud, json: false) else {
                print("No key for \(cloud) was handed over (MURMUR_KEYS_ON_STDIN=1 and one line of JSON on standard input)."); return
            }
            pageAsk = json
            proseAsk = prose
            model = CloudReader.name(cloud) + " " + CloudReader.model(cloud)
        } else {
            guard let local = await BrainDistiller.model() else { print("No model to read with (Murmur's reader isn't downloaded)."); return }
            pageAsk = ScreenWatcher.ask(local, fast: true, schema: WikiRules.schema, maxTokens: 900)
            proseAsk = ScreenWatcher.ask(local, fast: false, schema: nil, maxTokens: 800)
            model = local
        }
        let remote = cloud != nil
        let wiki = Wiki(url: journal.url), profile = Profile(url: journal.url)
        // One subject, one page: what was kept under two names put together first (as the helper does when it starts).
        let projects = brain.mergeProjects(), yours = brain.mergeMe()
        if projects + yours > 0 {
            print("Put together \(projects) projects kept under other names and \(yours) people who are you.")
        }
        let subjects = rewrite ? wiki.written(limit: limit) : wiki.due(limit: limit)
        print(rewrite ? "Rewriting the first \(subjects.count) pages with \(model)…"
                      : "Writing \(subjects.count) of \(wiki.dueCount()) due pages with \(model)…")
        var started = Date()
        let pages = await WikiWriter.pass(wiki: wiki, brain: brain, graph: graph, journal: journal, ask: pageAsk, model: model,
                                          remote: remote, limit: limit, subjects: rewrite ? subjects : nil)
        print(String(format: "%d pages written in %.0f s", pages, Date().timeIntervalSince(started)))
        for subject in subjects { if let page = wiki.page(entity: subject.entity, history: rewrite) { print("\n" + MemoryServer.pageText(page)) } }
        started = Date()
        let written = await ProfileWriter.pass(profile: profile, journal: journal, wiki: wiki, brain: brain, graph: graph,
                                               ask: proseAsk, model: model, remote: remote, again: again)
        if !written.isEmpty { print(String(format: "\n%@ written in %.0f s", written.joined(separator: " and "), Date().timeIntervalSince(started))) }
        for key in ["digest", "profile"] {
            guard let text = profile.text(key) else { print("\nNo \(key) yet."); continue }
            print("\n\(key.uppercased()) (\(written.contains(key) ? "just written, " : "")\(ProfileRules.day(text.generated))):\n\(text.text)")
        }
    }

    public static func report(brain: BrainStore, journal: Journal, graph: MemoryGraph, now: Date = Date(),
                              calendar: Calendar = .current) -> String {
        var out: [String] = []
        let counts = graph.counts()
        let me = brain.meNames()
        out.append("Screen memory, \(ScreenDates.spoken(now, calendar: calendar))")
        out.append("You are: " + (me.isEmpty ? "(not known yet: add your own card in Contacts, or tell Murmur your name)" : me.joined(separator: ", ")))
        out.append("\(journal.counts().snapshots) windows kept, \(counts.sightings) stays in them, \(counts.items) things read from "
                   + "them, \(counts.episodes) episodes (\(counts.unread) still to read), \(counts.edges) connections")
        let wiki = Wiki(url: journal.url), pages = wiki.counts(), profile = Profile(url: journal.url)
        out.append("Knowledge: \(pages.pages) wiki pages (\(pages.claims) claims true now, \(pages.retired) no longer true), "
                   + "\(wiki.dueCount()) due; profile " + (profile.text("profile").map { "written " + ProfileRules.day($0.generated) } ?? "not yet")
                   + "; digest " + (profile.text("digest").map { "written " + ProfileRules.day($0.generated) } ?? "not yet"))
        func section(_ title: String, _ lines: [String]) {
            out.append("")
            out.append(title)
            out += lines.isEmpty ? ["  (none)"] : lines.map { "  " + $0 }
        }
        section("Coming up (exact, from the windows):", graph.upcoming(now: now).map { $0.item.body.replacingOccurrences(of: "\n", with: "; ") })
        let releases = graph.items([.release], limit: 10)
        section("Releases:", releases.map { ($0.item.mine ? "yours: " : "") + $0.item.body.components(separatedBy: "\nNotes:").first!
            .replacingOccurrences(of: "\n", with: "; ") })
        section("Open promises and plans:", journal.loops(limit: 15).map { "\($0.label): \(Nudges.describe($0, now: now))" })
        section("Latest episodes (what you did):", graph.recentEpisodes(limit: 20).map {
            MemoryRecall.line($0, calendar: calendar).dropFirst(2) + ($0.read ? "" : " (not read yet)")
        })
        var projects: [String] = []
        for entity in brain.entities(kind: .project, limit: 12) {
            projects += MemoryRecall.connections(of: entity.id, name: entity.name, graph: graph, calendar: calendar).prefix(1)
        }
        section("Projects and how they connect:", projects.map { String($0.dropFirst(2)) })
        section("Memories from the screen (newest):", brain.fromScreen(limit: 15).map { "\($0.about): \($0.memory.text)" })
        return out.joined(separator: "\n")
    }
}
