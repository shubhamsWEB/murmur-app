import Foundation
import Testing
@testable import AgentKit

/// The knowledge pipeline's rules: wiki pages checked against their evidence, the week in the chronicle, the walk over
/// connections, the digest checked against its inputs, Murmur's entry in AI apps' settings, and the local API's requests.
struct WikiRulesTests {
    let evidence = [
        WikiRules.Evidence(label: "the user told Murmur", when: nil, text: "Priya Shah works at Acme as head of design.", source: "memory:1"),
        WikiRules.Evidence(label: "what you did, 40 min", when: nil,
                           text: "Reviewing the Acme launch deck with Priya. Agreed to ship version 2.1 on 4 Dec.", source: "episode:7"),
        WikiRules.Evidence(label: "seen in mail.google.com", when: nil,
                           text: "Priya: can you send the pricing sheet by Friday? · Shubham: Sure, I'll send it Friday.", source: "snapshot:44"),
    ]

    func check(_ json: String, existing: [String] = [], known: [String] = ["Acme", "Rahul"]) -> WikiRules.Written? {
        WikiRules.check(json, title: "Priya Shah", aliases: ["Priya"], existing: existing, evidence: evidence, known: known)
    }

    @Test func keepsCitedClaims() throws {
        let written = try #require(check("""
            {"summary": "Head of design at [[Acme]]; reviewing the launch with you", "claims": [
              {"text": "Priya Shah is head of design at [[Acme]]", "whose": "thing", "basis": "said", "worth": "core", "sources": [1]},
              {"text": "You and Priya agreed to ship version 2.1 on 4 Dec", "whose": "user", "basis": "did", "worth": "core", "sources": [2]}
            ]}
            """))
        #expect(written.claims.count == 2)
        #expect(written.claims[0].sources == ["memory:1"])
        #expect(written.claims[1].basis == "did")
        #expect(written.links == ["Acme"])
        #expect(!written.summary.isEmpty)
    }

    @Test func dropsUncitedUnsupportedAndNoise() throws {
        let written = try #require(check("""
            {"summary": "x", "claims": [
              {"text": "Priya is the user's closest collaborator", "whose": "other", "basis": "guess", "worth": "core", "sources": []},
              {"text": "Priya leads the Berlin office and manages twelve engineers", "whose": "thing", "basis": "seen", "worth": "core", "sources": [1]},
              {"text": "Acme's site lists pricing plans and integrations", "whose": "thing", "basis": "seen", "worth": "noise", "sources": [3]},
              {"text": "Priya asked you to send the pricing sheet by Friday", "whose": "user", "basis": "seen", "worth": "core", "sources": [9]}
            ]}
            """))
        #expect(written.claims.isEmpty)
        #expect(written.unsupported == 3)
    }

    @Test func numbersMustBeInTheEvidence() throws {
        let written = try #require(check("""
            {"summary": "", "claims": [
              {"text": "You and Priya agreed to ship version 2.2 on 4 Dec", "whose": "user", "basis": "did", "worth": "core", "sources": [2]}
            ]}
            """))
        #expect(written.claims.isEmpty)
    }

    @Test func keptClaimsMustBeOnThePage() throws {
        let page = ["Priya Shah is head of design at Acme"]
        let kept = try #require(check("""
            {"summary": "", "claims": [{"text": "Priya Shah is head of design at Acme", "worth": "core", "sources": [0]},
              {"text": "Priya runs marketing", "worth": "core", "sources": [0]}]}
            """, existing: page))
        #expect(kept.claims.map(\.text) == ["Priya Shah is head of design at [[Acme]]"])   // linked: Acme is a known name
        #expect(kept.claims.first?.sources == ["page"])
        #expect(kept.unsupported == 1)
    }

    @Test func unknownLinksBecomePlainWords() throws {
        let written = try #require(check("""
            {"summary": "", "claims": [{"text": "Priya Shah works at [[Acme]] with [[Globex]]", "worth": "core", "sources": [1]}]}
            """, known: ["Acme"]))
        #expect(written.claims.first?.text == "Priya Shah works at [[Acme]] with Globex")
    }

    @Test func notJSONIsNil() {
        #expect(check("I could not write the page.") == nil)
    }

    @Test func promptNumbersEvidenceFromOne() {
        let prompt = WikiRules.prompt(title: "Priya Shah", kind: "person", aliases: ["Priya"], existing: [], evidence: evidence,
                                      known: ["Acme"], today: Date(timeIntervalSince1970: 1_795_000_000))
        #expect(prompt.contains("[1] (the user told Murmur)"))
        #expect(prompt.contains("[3] (seen in mail.google.com)"))
        #expect(prompt.contains("(new page)"))
        #expect(prompt.contains("KNOWN NAMES: Acme"))
    }
}

struct ChronicleWeekTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    @Test func weekPeriods() {
        // Thu 19 Nov 2026 is in ISO week 47.
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 10))!
        #expect(Journal.Level.week.period(of: day, calendar: calendar) == "2026-W47")
        #expect(Journal.Level.of("2026-W47") == .week)
        #expect(Journal.Level.of("2026-11-19T10") == .hour)
        #expect(Journal.Level.of("2026-11") == .month)
        #expect(Journal.Level.of("2026") == .year)
        #expect(Journal.Level.week.below == .day)
    }

    @Test func weekParts() throws {
        let parts = try #require(Journal.Level.parts(of: "2026-W47", calendar: calendar))
        #expect(parts.level == .day)
        #expect(parts.keys == ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"])
        // A year's first week can start in the year before.
        let first = try #require(Journal.Level.parts(of: "2027-W01", calendar: calendar))
        #expect(first.keys.first == "2027-01-04")
        let monthStart = try #require(Journal.Level.start(of: "2026-11", calendar: calendar))
        #expect(calendar.component(.day, from: monthStart) == 1)
    }
}

struct GraphWalkTests {
    @Test func reachesWhatTheSeedIsConnectedTo() {
        // launch(1) — priya(2) — acme(3); launch — rahul(4); an unrelated island 5 — 6.
        let links: [Int64: [(Int64, Double)]] = [
            1: [(2, 3), (4, 1)], 2: [(1, 3), (3, 2)], 3: [(2, 2)], 4: [(1, 1)], 5: [(6, 1)], 6: [(5, 1)],
        ]
        let ranked = MemoryGraph.personalizedPageRank(links: links, seeds: [1], limit: 5)
        let ids = ranked.map(\.id)
        #expect(ids.first == 2)          // the heaviest neighbour first
        #expect(ids.contains(3))         // two steps away
        #expect(!ids.contains(1))        // the seed itself isn't an answer
        #expect(!ids.contains(5) && !ids.contains(6))
    }

    @Test func noSeedsNoWalk() {
        #expect(MemoryGraph.personalizedPageRank(links: [1: [(2, 1)]], seeds: [9], limit: 3).isEmpty)
    }
}

struct DigestTests {
    @Test func dropsLinesWithInventedNumbers() {
        let inputs = "2026-11-18: You released Murmur 1.8.0 and talked to Priya about pricing."
        let digest = ProfileRules.checkDigest("""
            ### Projects
            - [18 Nov] Released Murmur 1.8.0
            - Murmur has 5000 users
            ### People
            - Priya: pricing
            """, inputs: inputs)
        #expect(digest.contains("Released Murmur 1.8.0"))
        #expect(!digest.contains("5000"))
        #expect(digest.contains("### People"))
    }

    @Test func emptyHeadingsGo() {
        let digest = ProfileRules.checkDigest("### Now\n- Building 99 things\n### Projects\n- Murmur", inputs: "Murmur")
        #expect(!digest.contains("### Now"))
        #expect(digest.contains("### Projects"))
    }

    @Test func fillerAndNonPreferencesGo() {
        let digest = ProfileRules.checkDigest("""
            ### Now
            Sun 22 Nov 2026
            ### Projects
            - Murmur 1.8.1 released
            ### Preferences
            - LinkedIn post completed
            - None specified.
            - Prefers short replies
            """, inputs: "Sun 22 Nov 2026 Murmur 1.8.1")
        #expect(!digest.contains("### Now"))
        #expect(!digest.contains("LinkedIn"))
        #expect(!digest.contains("None specified"))
        #expect(digest.contains("Prefers short replies"))
    }
}

struct RegistrationTests {
    let helper = "/Applications/Murmur.app/Contents/Helpers/murmur-memory"

    @Test func addsToJSONKeepingTheRest() throws {
        let before = #"{"theme": "dark", "mcpServers": {"github": {"command": "gh-mcp"}}}"#
        let after = try #require(MCPRegistration.addingJSON(to: before, key: "mcpServers", typed: false, command: helper))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: Any])
        #expect(object["theme"] as? String == "dark")
        #expect(servers["github"] != nil)
        #expect((servers["murmur"] as? [String: Any])?["command"] as? String == helper)
        // Again: nothing to change.
        #expect(MCPRegistration.addingJSON(to: after, key: "mcpServers", typed: false, command: helper) == nil)
        // A newer copy of Murmur moves it.
        #expect(MCPRegistration.addingJSON(to: after, key: "mcpServers", typed: false, command: "/Applications/Other/Murmur.app/Contents/Helpers/murmur-memory") != nil)
    }

    @Test func leavesOthersAlone() {
        let theirs = #"{"mcpServers": {"murmur": {"command": "/usr/local/bin/some-other-murmur"}}}"#
        #expect(MCPRegistration.addingJSON(to: theirs, key: "mcpServers", typed: false, command: helper) == nil)
        #expect(MCPRegistration.removingJSON(from: theirs, key: "mcpServers") == nil)
        // A file with comments isn't JSON: left alone.
        #expect(MCPRegistration.addingJSON(to: "// settings\n{}", key: "mcpServers", typed: false, command: helper) == nil)
    }

    @Test func newFileAndTypedEntry() throws {
        let made = try #require(MCPRegistration.addingJSON(to: nil, key: "servers", typed: true, command: helper))
        #expect(made.contains("\"type\" : \"stdio\""))
        let removed = try #require(MCPRegistration.removingJSON(from: made, key: "servers"))
        #expect(!removed.contains("murmur-memory"))
    }

    @Test func codexTOML() throws {
        let before = "model = \"gpt-5\"\n\n[mcp_servers.github]\ncommand = \"gh\"\n"
        let added = try #require(MCPRegistration.addingTOML(to: before, command: helper))
        #expect(added.hasPrefix(before))
        #expect(added.contains("[mcp_servers.murmur]\ncommand = \"\(helper)\"\nargs = [\"mcp\"]"))
        #expect(MCPRegistration.addingTOML(to: added, command: helper) == nil)
        let moved = try #require(MCPRegistration.addingTOML(to: added + "\n[profiles.fast]\nmodel = \"x\"\n", command: "/Applications/New/Murmur.app/Contents/Helpers/murmur-memory"))
        #expect(moved.contains("[profiles.fast]"))
        #expect(moved.components(separatedBy: "[mcp_servers.murmur]").count == 2)
        let removed = try #require(MCPRegistration.removingTOML(from: moved))
        #expect(!removed.contains("murmur"))
        #expect(removed.contains("[mcp_servers.github]") && removed.contains("[profiles.fast]"))
        // Someone else's block by that name stays.
        #expect(MCPRegistration.addingTOML(to: "[mcp_servers.murmur]\ncommand = \"theirs\"\n", command: helper) == nil)
    }
}

struct MemoryAPITests {
    @Test func parsesRequests() throws {
        let raw = "GET /search_memory?query=quarterly%20report&limit=5 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\n\r\n"
        let request = try #require(MemoryAPI.parse(Data(raw.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/search_memory")
        #expect(request.query["query"] == "quarterly report")
        #expect(MemoryAPI.authorized(request, token: "abc"))
        #expect(!MemoryAPI.authorized(request, token: "abd"))
    }

    @Test func waitsForTheWholeBody() throws {
        let head = "POST /call HTTP/1.1\r\nContent-Length: 20\r\n\r\n"
        #expect(MemoryAPI.parse(Data((head + "{\"name\":").utf8)) == nil)
        let request = try #require(MemoryAPI.parse(Data((head + "{\"name\":\"get_profile\"}").utf8)))
        #expect(String(decoding: request.body, as: UTF8.self).hasPrefix("{\"name\":"))
        #expect(!MemoryAPI.authorized(request, token: "abc"))
    }
}

struct KnowledgeOnRealDataTests {
    /// Seen on a real Mac: the user listed among their own people, and a broken line left under the bullets.
    @Test func digestLeavesOutTheUserAndFragments() {
        let digest = ProfileRules.checkDigest("""
            ### People
            - Shubham Agrawal: Software engineer at Ford
            - Roma: chat ongoing
            ### Decisions and promises
            - Fix typography on Sudoku Clan
            (US) DUNS request.
            """, inputs: "Shubham Agrawal Ford Roma Sudoku Clan typography DUNS", me: ["Shubham Agrawal", "You"])
        #expect(!digest.contains("Shubham"))
        #expect(digest.contains("Roma"))
        #expect(!digest.contains("DUNS"))
    }

    /// The second run: names in bold, and "Follow-up on…" for every open thread.
    @Test func boldNamesAndFollowUps() {
        let digest = ProfileRules.checkDigest("""
            ### People
            - **Shubham Agrawal**: Software engineer at Ford.
            - **Roma**: Chat ongoing. Last message on 15 Nov.
            ### Decisions and promises
            - **Roma**: Follow-up on WhatsApp message.
            """, inputs: "Shubham Agrawal Ford Roma 15 Nov WhatsApp", me: ["Shubham Agrawal"])
        #expect(!digest.contains("Shubham"))
        #expect(digest.contains("Last message on 15 Nov"))
        #expect(!digest.contains("Follow-up") && !digest.contains("Decisions"))
    }

    /// Sarvam's digest: "Today is…", the same Murmur work three times, and a dozen lines under one heading.
    @Test func digestSaysEachThingOnce() {
        let digest = ProfileRules.checkDigest("""
            ### Now
            - Today is Mon 23 Nov 2026.
            - You deployed the wedding invitation website to Vercel.
            ### Projects
            - You reviewed and deployed the redesigned home page and meeting notes for Murmur 1.8.0, leaving release open.
            - You reviewed and deployed the redesigned home page and meeting notes for Murmur 1.8.0, deployed GitHub Pages.
            - One
            - Two
            - Three
            - Four
            - Five
            - Six
            """, inputs: "Mon 23 Nov 2026 Murmur 1.8.0 wedding Vercel", perSection: 4)
        #expect(!digest.contains("Today is"))
        #expect(digest.contains("Vercel"))
        #expect(digest.components(separatedBy: "redesigned home page").count == 2)
        #expect(!digest.contains("Four"))
    }

    /// "Not at weekends" means Saturday too, in a calendar (India's) whose weekend is Sunday only.
    @Test func saturdayIsAWeekendEverywhere() {
        var settings = ScreenMemorySettings()
        (settings.enabled, settings.always, settings.from, settings.to, settings.weekends) = (true, false, 9, 19, false)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_IN")
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 10))!
        let friday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 10))!
        #expect(!settings.readsNow(saturday, calendar: calendar))
        #expect(settings.readsNow(friday, calendar: calendar))
    }

    /// Murmur's own day summaries ("You reviewed…") were taken for how the user writes, and "2-3 hours" was made up.
    @Test func profileKeepsOnlyWhatTheInputsShow() {
        let content = """
            ### Habits
            You work in the afternoon. Focused sessions last around 2-3 hours.
            ### How you write
            Concise. One example is: `You reviewed the deployment`.
            """
        let none = ProfileRules.checkProfile(content, inputs: "2026-11-23: You reviewed the deployment in the afternoon", written: [])
        #expect(none.contains("afternoon"))
        #expect(!none.contains("2-3"))
        #expect(!none.contains("How you write"))
        let some = ProfileRules.checkProfile(content, inputs: "afternoon", written: ["ok will send by eod"])
        #expect(some.contains("How you write") && some.contains("Concise"))
        #expect(!some.contains("You reviewed"))
    }

    @Test func noLinkInsideAWord() {
        var linked: [String] = []
        let text = WikiRules.relink("Working on [[Sudoku]]-V2 with [[Roma]]", known: ["sudoku": "Sudoku", "roma": "Roma"], linked: &linked)
        #expect(text == "Working on Sudoku-V2 with [[Roma]]")
        var more: [String] = []
        #expect(WikiRules.autolink("Sudoku-V2 ships", known: ["Sudoku"], linked: &more) == "Sudoku-V2 ships")
    }
}

/// Claude ran out of tokens on the "You" page and the digest (Mon 23 Nov): what it finished is kept.
struct CutOffTests {
    @Test func aCutOffPageKeepsItsFinishedClaims() throws {
        let answer = #"{"summary": "Your page", "claims": [{"text": "You released [[murmur]] between 6 Nov and 10 Nov 2026.", "whose": "user", "basis": "did", "worth": "core", "sources": [1]}, {"text": "You worked on [[murmur]] from 5 Nov to 21 No"#
        let object = try #require(WikiRules.jsonObject(in: answer))
        #expect(object["summary"] as? String == "Your page")
        #expect((object["claims"] as? [[String: Any]])?.count == 1)
        // A string with braces and quotes in it doesn't confuse it.
        let tricky = #"{"summary": "a } and \" here", "claims": [{"text": "x {y}", "sources": [1]}, {"text": "cut"#
        #expect((WikiRules.jsonObject(in: tricky)?["claims"] as? [[String: Any]])?.first?["text"] as? String == "x {y}")
    }

    @Test func aCutOffDigestEndsAtItsLastWholeSentence() {
        let digest = ProfileRules.checkDigest("""
            ### Projects
            - Murmur: Deployed the redesigned home page. Committing the Swift fixes is still to do. The
            """ + CloudReader.cutOff, inputs: "Murmur")
        #expect(digest.hasSuffix("Committing the Swift fixes is still to do."))
    }
}


/// Sarvam's pages (Mon 23 Nov): "Modernizing Sudoku v2 game" beside Sudoku V2, "Sudoku Clan: Multiplayer" beside Sudoku
/// Clan, and "with Shubham" in what Shubham did.
struct OneSubjectTests {
    @Test func projectsAreKnownByWhatTheyAre() {
        #expect(BrainModel.projectIdentity("Modernizing Sudoku v2 game") == BrainModel.projectIdentity("Sudoku V2"))
        #expect(BrainModel.projectIdentity("sudoku-v2") == "sudoku v2")
        #expect(BrainModel.projectIdentity("Sudoku Clan: Multiplayer") == BrainModel.projectIdentity("Sudoku Clan"))
        #expect(BrainModel.projectIdentity("Sudoku Clan multiplayer web app") == "sudoku clan")
        #expect(BrainModel.projectIdentity("Working on Murmur 1.8.0") == "murmur")
        #expect(BrainModel.projectIdentity("Murmur – voice assistant") == "murmur")
        // Still apart: another project, and a name that is only what it is.
        #expect(BrainModel.projectIdentity("Sudoku V2") != BrainModel.projectIdentity("Sudoku Clan"))
        #expect(BrainModel.projectIdentity("Game") == "game")
        #expect(BrainModel.projectIdentity("Wedding invitation website") == "wedding invitation")
    }

    @Test func theUserIsNeverSomeoneTheyWorkedWith() {
        let me = ["Shubham Agrawal", "Shubham"]
        #expect(WikiRules.withoutSelf("You set up Oracle Cloud, discussing it with Claude and Shubham.", me: me)
                == "You set up Oracle Cloud, discussing it with Claude.")
        #expect(WikiRules.withoutSelf("You reviewed the deployment of Sudoku-V2 with Shubham Agrawal, and left it open.", me: me)
                == "You reviewed the deployment of Sudoku-V2, and left it open.")
        #expect(WikiRules.withoutSelf("You planned the release with Shubham and Roma.", me: me) == "You planned the release with Roma.")
        #expect(WikiRules.withoutSelf("Shubham's app passed review.", me: me) == "your app passed review.")
        // Someone else's name, and the user's name on its own, stay.
        #expect(WikiRules.withoutSelf("You talked with Roma.", me: me) == "You talked with Roma.")
        #expect(WikiRules.withoutSelf("My name is Shubham Agrawal", me: me) == "My name is Shubham Agrawal")
    }
}
