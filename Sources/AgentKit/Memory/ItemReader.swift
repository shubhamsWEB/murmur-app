import Foundation

/// One thing a window held, read by rules from its address, title and text, never by a model: a flight booked, a
/// release published, an issue, an email, a message the user sent, a document or file worked on, a page. Each has a
/// key that stays the same however often it's seen ("flight|6E537|2026-11-08", "release|murmur-app|1.6.0"), its exact
/// fields as the window showed them, and the window it came from. What the model writes later is checked against
/// these, so a time or a version is never the model's guess.
public struct MemoryItem: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case flight, booking, release, issue, email, message, document, code, page
    }

    public var kind: Kind
    public var key: String
    public var title: String
    /// The fields as one line each ("Departs: Sat 8 Nov 2026 10:15"), for the model and for answers.
    public var body: String
    /// Who wrote or sent it (a message, an email, a release), "" when no one in particular.
    public var actor: String
    /// The project it belongs to, by its plain name ("murmur-app", "Murmur"), "" when none.
    public var project: String
    public var people: [String]
    /// When it happens or happened: a flight's departure, a release's day, an email's date. Nil when the window
    /// doesn't say.
    public var when: Date?
    public var fields: [String: String]
    /// The user's own (their booking, their release, what they sent).
    public var mine: Bool

    public init(kind: Kind, key: String, title: String, body: String = "", actor: String = "", project: String = "",
                people: [String] = [], when: Date? = nil, fields: [String: String] = [:], mine: Bool = false) {
        self.kind = kind
        self.key = key
        self.title = title
        self.body = body
        self.actor = actor
        self.project = project
        self.people = people
        self.when = when
        self.fields = fields
        self.mine = mine
    }
}

public enum ItemReader {
    /// What a window holds, best first. `me`: the user's names (their contact card, what they told Murmur).
    public static func read(_ raw: Journal.Snapshot, me: [String], calendar: Calendar = .current) -> [MemoryItem] {
        let window = Triage.with(raw, text: ScreenText.clean(raw.text))
        var items: [MemoryItem] = []
        let mine = Engagement.mentions(window.title + "\n" + window.text, any: me)
        items += flights(in: window, mine: mine, calendar: calendar)
        items += releases(in: window, me: me, calendar: calendar)
        if let issue = issue(in: window) { items.append(issue) }
        items += emails(in: window, me: me, calendar: calendar)
        items += messages(in: window)
        if let work = work(in: window) { items.append(work) }
        if items.isEmpty, let page = page(in: window) { items.append(page) }
        return items
    }

    // MARK: Projects

    /// Folders that hold projects ("~/IdeaProjects/murmur/…": the project is "murmur").
    static let projectRoots: Set<String> = ["ideaprojects", "projects", "project", "code", "dev", "developer", "src",
                                            "github", "repos", "repositories", "workspace", "workspaces", "work", "git",
                                            "sites", "apps", "documents", "desktop", "xcodeprojects", "androidstudioprojects"]

    /// The project a file belongs to, from its path: the folder under a projects folder, or the one holding the
    /// repository.
    public static func project(ofPath path: String) -> String {
        // A terminal's title runs on into its command ("~/IdeaProjects/murmur; git pull"): the path ends there.
        let cut = path.split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "&" || $0 == "|" }).first.map(String.init) ?? path
        let parts = cut.split(separator: "/").map(String.init)
        if let index = parts.lastIndex(where: { projectRoots.contains($0.lowercased()) }), index + 1 < parts.count,
           !(index + 1 == parts.count - 1 && isFileName(parts[index + 1])), isProjectName(parts[index + 1]) {
            return parts[index + 1]
        }
        if let users = parts.firstIndex(of: "Users"), users + 2 < parts.count - 1, isProjectName(parts[users + 2]) { return parts[users + 2] }
        return ""
    }

    static let editors: Set<String> = ["Code", "Visual Studio Code", "Cursor", "Windsurf", "Zed", "Xcode", "IntelliJ IDEA",
                                       "PyCharm", "WebStorm", "GoLand", "Android Studio", "Sublime Text", "Nova", "BBEdit",
                                       "Fleet", "RustRover", "CLion", "Rider", "PhpStorm", "DataGrip", "TextMate", "MacVim"]
    static let terminals: Set<String> = ["Terminal", "iTerm2", "iTerm", "Warp", "Ghostty", "kitty", "Alacritty", "WezTerm",
                                         "Hyper", "Tabby"]
    static let noteApps: Set<String> = ["Notes", "Obsidian", "Notion", "Bear", "Craft", "Logseq", "Pages", "Microsoft Word",
                                        "TextEdit", "Google Docs", "Typora", "Ulysses", "iA Writer"]

    /// A real project's name: not a folder that holds projects ("IdeaProjects", "Documents"), not the home folder
    /// ("shubhamagrawal"), not a path or an address.
    static func isProjectName(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard lower.count >= 2, lower.count <= 60, !lower.contains("@"), !lower.contains("/"), lower != "~" else { return false }
        if projectRoots.contains(lower) || ["users", "home", "library", "applications", "downloads", "tmp"].contains(lower) { return false }
        let user = NSUserName().lowercased()
        return user.isEmpty || !(user.hasPrefix(lower) || lower.hasPrefix(user))
    }

    /// A file name: has an extension of letters and digits ("ScreenWatcher.swift", "README.md").
    static func isFileName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ●", with: "")
        guard !trimmed.contains(" "), let dot = trimmed.lastIndex(of: "."), dot != trimmed.startIndex else { return false }
        let ext = trimmed[trimmed.index(after: dot)...]
        return (1...6).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber } && ext.contains(where: \.isLetter)
    }

    /// An editor's or terminal's title in parts: "ScreenWatcher.swift — murmur-app", "murmur – Journal.swift",
    /// "shubham@mac: ~/IdeaProjects/murmur — zsh — 120×40".
    static func titleParts(_ title: String) -> [String] {
        var parts = [title]
        for separator in [" — ", " – ", " - ", " | "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A document or file being worked on, with its project: from the file's path when the app says it, or from an
    /// editor's or terminal's title.
    static func work(in window: Journal.Snapshot) -> MemoryItem? {
        let app = window.app
        if let path = window.document, !path.isEmpty {
            let name = (path as NSString).lastPathComponent
            let project = project(ofPath: path)
            let code = editors.contains(app) || terminals.contains(app)
            return MemoryItem(kind: code ? .code : .document, key: "\(code ? "code" : "document")|\(path.lowercased())",
                              title: name, body: "File: \(path)" + (project.isEmpty ? "" : "\nProject: \(project)"),
                              project: project, fields: ["path": path], mine: true)
        }
        if editors.contains(app) {
            let parts = titleParts(window.title).filter { $0 != app && !$0.lowercased().contains("visual studio code") }
            let file = parts.first(where: isFileName) ?? ""
            let project = parts.first { !isFileName($0) && isProjectName($0) }
                ?? parts.first { $0.contains("/") }.map { ($0 as NSString).lastPathComponent }.flatMap { isProjectName($0) ? $0 : nil } ?? ""
            guard !file.isEmpty || !project.isEmpty else { return nil }
            return MemoryItem(kind: .code, key: "code|\(project.lowercased())|\(file.lowercased())", title: file.isEmpty ? project : file,
                              body: (file.isEmpty ? "" : "File: \(file)\n") + (project.isEmpty ? "" : "Project: \(project)"),
                              project: project, fields: ["file": file], mine: true)
        }
        if terminals.contains(app) {
            // "~/IdeaProjects/murmur", "murmur-app — -zsh — 120×40": the folder it's in.
            let parts = titleParts(window.title)
            let folder = parts.first { $0.contains("~/") || $0.hasPrefix("/") }
            var project = folder.map { path -> String in
                let cleaned = path.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? path
                let fromRoot = Self.project(ofPath: cleaned.replacingOccurrences(of: "~", with: "/Users/me"))
                let last = (cleaned.split(whereSeparator: { $0 == ";" || $0 == " " }).first.map(String.init) ?? cleaned) as NSString
                return fromRoot.isEmpty ? last.lastPathComponent : fromRoot
            } ?? ""
            if project.isEmpty, let first = parts.first, !first.hasPrefix("-"), !first.contains(" "), !first.contains("×"),
               !isFileName(first),
               first.count <= 40, first.lowercased() != app.lowercased() {
                project = first
            }
            guard !project.isEmpty, isProjectName(project), project.lowercased() != "me" else { return nil }
            return MemoryItem(kind: .code, key: "code|\(project.lowercased())|terminal", title: "\(project) (terminal)",
                              body: "Project: \(project)", project: project, mine: true)
        }
        if noteApps.contains(app), WindowKind.of(window) == .work || app != "Notion" {
            let parts = titleParts(window.title).filter { $0 != app }
            guard let name = parts.first, name.count >= 2 else { return nil }
            return MemoryItem(kind: .document, key: "document|\(app.lowercased())|\(name.lowercased())", title: name,
                              body: "Document: \(name) in \(app)", mine: true)
        }
        return nil
    }

    // MARK: Pages, issues, releases

    /// The address without what changes between visits (tracking, fragments), for one key per page.
    static func canonical(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.fragment = nil
        let keep: Set<String> = ["q", "id", "v", "p", "page", "query", "search", "list"]
        components.queryItems = components.queryItems?.filter { keep.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        var text = components.string ?? url
        if text.hasSuffix("/") { text.removeLast() }
        return text.replacingOccurrences(of: "https://www.", with: "https://").lowercased()
    }

    /// A page's title without the site's name after it ("Release Murmur 1.6.0 · shubhamsWEB/murmur-app · GitHub").
    static func pageTitle(_ title: String) -> String {
        let parts = title.components(separatedBy: " · ").flatMap { $0.components(separatedBy: " | ") }
        return parts.first?.trimmingCharacters(in: .whitespaces) ?? title
    }

    static func page(in window: Journal.Snapshot) -> MemoryItem? {
        guard let url = window.url, !url.isEmpty, !window.title.isEmpty else { return nil }
        let title = pageTitle(window.title)
        return MemoryItem(kind: .page, key: "page|" + canonical(url), title: title, body: "Page: \(title)\nAddress: \(url)",
                          fields: ["url": url, "site": window.domain])
    }

    /// An issue or pull request: GitHub, GitLab, Linear, Jira. Its state isn't kept (true for minutes); its key and
    /// project are, to tie the work on it together.
    static func issue(in window: Journal.Snapshot) -> MemoryItem? {
        guard let url = window.url, let parsed = URL(string: url), let host = parsed.host else { return nil }
        let path = parsed.pathComponents.filter { $0 != "/" }
        var key = "", project = "", kind = "issue"
        if host.hasSuffix("github.com") || host.hasSuffix("gitlab.com"), path.count >= 4,
           ["issues", "pull", "merge_requests"].contains(path[2]) || (path.count >= 5 && path[3] == "merge_requests"),
           let number = path.first(where: { Int($0) != nil }) {
            project = path[1]
            kind = path.contains("pull") || path.contains("merge_requests") ? "pull request" : "issue"
            key = "\(path[0])/\(path[1])#\(number)"
        } else if host == "linear.app", let index = path.firstIndex(of: "issue"), index + 1 < path.count {
            key = path[index + 1].uppercased()
            project = path.first ?? ""
        } else if host.hasSuffix("atlassian.net"), let index = path.firstIndex(of: "browse"), index + 1 < path.count {
            key = path[index + 1].uppercased()
            project = key.split(separator: "-").first.map(String.init) ?? ""
        } else {
            return nil
        }
        let title = pageTitle(window.title)
        return MemoryItem(kind: .issue, key: "issue|" + key.lowercased(), title: title,
                          body: "\(kind.capitalized) \(key): \(title)" + (project.isEmpty ? "" : "\nProject: \(project)"),
                          project: project, fields: ["number": key, "type": kind, "url": url])
    }

    static let versionPattern = #"(?<![\w.])v?(\d+\.\d+(?:\.\d+)?(?:[-.](?:beta|alpha|rc)\.?\d*)?)(?![\w.])"#

    /// GitHub's own lines on a release page, not the notes.
    static let releaseChrome = ["assets", "source code", "compare", "latest", "pre-release", "reactions", "released this",
                                "verified", "this commit was created", "gpg key", "loading", "contributors", "tag v",
                                "commit ", "edit:", "delete:", "draft a new release", "create release", "tagged this",
                                "github-actions", "@", "releases", "edit", "delete", "copy", "show all"]

    /// Published releases a page shows: GitHub's page of one release, or its list of them, each with its version, who
    /// published it, its day when the page says, and the start of its notes. The user's own when they published it
    /// (or the repository is theirs). A tag not yet released ("Create release from tag") is none.
    static func releases(in window: Journal.Snapshot, me: [String], calendar: Calendar) -> [MemoryItem] {
        guard let url = window.url, let parsed = URL(string: url), let host = parsed.host,
              host.hasSuffix("github.com") || host.hasSuffix("gitlab.com") else { return [] }
        let path = parsed.pathComponents.filter { $0 != "/" }
        guard path.count >= 3, path[2] == "releases" || (path.count >= 4 && path[3] == "releases") else { return [] }
        let owner = path[0], repo = path[1]
        let lines = window.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let lowerMe = me.flatMap { BrainModel.nameKey($0).split(separator: " ").map(String.init) }.filter { $0.count >= 4 }
        // Headings: "Murmur 1.6.0", "v1.6.0", each a release (not "Edit: Murmur 1.3.0", a button).
        let heading = #"^([A-Z][\w.-]*(?: [A-Z][\w.-]*)?)?\s?v?(\d+\.\d+(?:\.\d+)?(?:-[\w.]+)?)$"#
        var starts: [(index: Int, name: String, version: String)] = []
        for (index, line) in lines.enumerated() {
            guard let match = ranges(heading, in: line).first, !match.groups[1].isEmpty else { continue }
            // A release's heading is followed (within a few lines) by who released it or its tag.
            let next = lines[(index + 1)..<min(lines.count, index + 6)].map { $0.lowercased() }
            guard next.contains(where: { $0.hasPrefix("tag v") || $0 == "released this" || $0 == "latest" || $0.hasPrefix("@") }) else { continue }
            if let last = starts.last, last.version == match.groups[1] { continue }
            starts.append((index, match.groups[0], match.groups[1]))
        }
        // A page of one release that reads differently: its version from the address.
        if starts.isEmpty, path.count >= 5, path[3] == "tag", let version = first(versionPattern, in: path[4]) {
            if lines.contains(where: { $0.lowercased().hasPrefix("create release from tag") }) { return [] }   // not released
            starts = [(lines.firstIndex { $0.contains(version) } ?? 0, "", version)]
        }
        var out: [MemoryItem] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1].index : lines.count
            let block = Array(lines[min(start.index + 1, end)..<end])
            // A tag not released yet: none.
            if block.prefix(8).contains(where: { $0.lowercased().hasPrefix("create release from tag") || $0.lowercased().hasSuffix("tagged this") }) {
                continue
            }
            // "shubhamsWEB released this Nov 6", or "released this" on a line of its own after the name.
            let said = block.firstIndex { $0.lowercased().contains("released this") }
            var releaser = owner, dayText = ""
            if let said {
                let line = block[said]
                if line.lowercased() == "released this" {
                    if said > 0 { releaser = block[said - 1].trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) }
                    if said + 1 < block.count { dayText = block[said + 1] }
                } else if let range = line.range(of: " released this", options: .caseInsensitive) {
                    releaser = String(line[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
                    dayText = String(line[range.upperBound...])
                }
            }
            var notes: [String] = []
            for line in block {
                let lower = line.lowercased()
                if lower.hasPrefix("assets") { break }
                guard line.count >= 12, !releaseChrome.contains(where: { lower.hasPrefix($0) }), !lower.contains("released this"),
                      ranges(heading, in: line).isEmpty,
                      lower.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) == nil else { continue }
                notes.append(line)
                if notes.joined(separator: " ").count > 900 { break }
            }
            var name = start.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.lowercased() == "release" { name = repo }
            let mine = lowerMe.contains { releaser.lowercased().contains($0) || owner.lowercased().contains($0) }
            var when: Date?
            if !dayText.isEmpty {
                when = ScreenDates.find(in: dayText, reference: window.first, calendar: calendar).first?.date
                    ?? ScreenDates.relative(dayText, reference: window.first, calendar: calendar)
            }
            let product = "\(name) \(start.version)"
            var body = "Release: \(product)\nRepository: \(owner)/\(repo)\nPublished by: \(releaser)"
            if let when { body += "\nReleased: " + ScreenDates.day(when, calendar: calendar) }
            let text = notes.joined(separator: " ")
            if !text.isEmpty { body += "\nNotes: " + text.prefix(900) }
            out.append(MemoryItem(kind: .release, key: "release|\(repo.lowercased())|\(start.version.lowercased())", title: product,
                                  body: body, actor: releaser, project: name, when: when,
                                  fields: ["version": start.version, "repository": "\(owner)/\(repo)", "name": name,
                                           "notes": String(text.prefix(900))], mine: mine))
        }
        return out
    }

    /// Versions in order: "1.10.0" after "1.9.2".
    public static func newerVersion(_ a: String, than b: String) -> Bool {
        let x = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }, y = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for (p, q) in zip(x, y) where p != q { return p > q }
        return x.count > y.count
    }

    // MARK: Email and messages

    static let mailDomains: Set<String> = ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
                                           "mail.yahoo.com", "mail.proton.me", "app.fastmail.com", "mail.zoho.com", "mail.zoho.in"]

    static let mailApps: Set<String> = ["Mail", "Microsoft Outlook", "Outlook", "Spark", "Airmail", "Mimestream", "Superhuman"]

    static func isMail(_ window: Journal.Snapshot) -> Bool {
        mailApps.contains(window.app) || mailDomains.contains(window.domain)
    }

    /// Emails a window shows: the one open (its subject, who wrote it and to whom, the start of what it says), and each
    /// row of a Sent list ("To: Tanay , Murmur, an open-source voice computer I built , 3:09 AM , Hi Tanay, …"). The
    /// user's own when they sent it. The same email from the list and from its thread is one item.
    static func emails(in window: Journal.Snapshot, me: [String], calendar: Calendar) -> [MemoryItem] {
        guard isMail(window) else { return [] }
        var out: [MemoryItem] = []
        let lines = window.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Sent lists: one row per email the user sent.
        for line in lines where line.hasPrefix("To: ") {
            let parts = line.dropFirst(4).components(separatedBy: " , ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }
            let recipient = parts[0], subject = parts[1], when = parts[2]
            let body = parts.dropFirst(3).joined(separator: ", ")
            guard subject.count >= 3, !BrainModel.hasSecret(subject) else { continue }
            let name = greeted(in: body, matching: recipient) ?? recipient
            out.append(email(subject: subject, from: "me", to: [name], body: body, sentByMe: true,
                             when: sentTime(when, seen: window.first, calendar: calendar), calendar: calendar))
        }
        // The email open in the window.
        var subject = window.title.components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces) ?? window.title
        if ["inbox", "gmail", "mail", "sent", "drafts", "outlook", "compose", "untitled", "starred", "search results"]
            .contains(where: { subject.lowercased().hasPrefix($0) }) {
            subject = ""
        }
        guard subject.count >= 3 else { return out }
        // Who's on it: "Name <address>" lines, and the line after "to" ("to tanay", "to me").
        let senders = matches(#"([A-Z][\p{L}.'-]+(?: [A-Z][\p{L}.'-]+){0,3})\s*<[^>@\s]+@[^>\s]+>"#, in: window.text)
        let mineNames = Set(me.map { BrainModel.nameKey($0) })
        var recipients: [String] = []
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            if lower == "to", index + 1 < lines.count {
                let next = lines[index + 1]
                if next.count <= 60, !next.contains("@") || !next.contains(" ") { recipients.append(next) }
            } else if lower.hasPrefix("to "), line.count <= 40, !lower.contains(":"),
                      lines[max(0, index - 3)..<index].contains(where: { $0.contains("@") && $0.contains("<") }),
                      String(line.dropFirst(3)).range(of: #"^[\p{L}.'-]+(, [\p{L}.'-]+)*$"#, options: .regularExpression) != nil {
                recipients.append(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))   // "to me", "to Priya"
            }
        }
        let toMe = recipients.contains { $0.lowercased() == "me" }
        let account = window.title.components(separatedBy: " - ").first { $0.contains("@") }?.trimmingCharacters(in: .whitespaces) ?? ""
        let others = senders.filter { !mineNames.contains(BrainModel.nameKey($0)) }
        // Sent by the user: to someone (not "me"), and no one else's name as its sender.
        let sentByMe = !recipients.isEmpty && !toMe && (others.isEmpty || (!account.isEmpty && window.text.contains(account)))
        // What it says: the lines after its subject, up to the details.
        var body: [String] = []
        var sentAt: Date?
        if let start = lines.firstIndex(where: { $0 == subject }) {
            for line in lines[(start + 1)...] {
                let lower = line.lowercased()
                if lower == "to" || lower.hasPrefix("show details") || lower.hasPrefix("on ") && lower.hasSuffix("wrote:") { break }
                // "3:58 AM (20 minutes ago)": when it went.
                if lower.range(of: #"^\d{1,2}:\d{2}\s?[ap]m\b"#, options: .regularExpression) != nil, let clock = ScreenDates.times(in: line).first {
                    sentAt = ScreenDates.at(window.first, time: clock, calendar: calendar).map { $0 > window.last ? $0.addingTimeInterval(-86400) : $0 }
                    continue
                }
                if ["more message options", "reply", "forward"].contains(lower) { continue }
                body.append(line)
                if body.joined(separator: " ").count > 2500 { break }
            }
        }
        let text = body.joined(separator: " ")
        let to = recipients.filter { $0.lowercased() != "me" }.map { greeted(in: text, matching: $0) ?? $0 }
        let from = sentByMe ? "me" : others.first ?? ""
        let people = Array((sentByMe ? to : others).prefix(5))
        out.append(email(subject: subject, from: from, to: people, body: text, sentByMe: sentByMe, when: sentAt, calendar: calendar))
        return out
    }

    static func email(subject: String, from: String, to people: [String], body: String, sentByMe: Bool, when: Date?,
                      calendar: Calendar = .current) -> MemoryItem {
        let start = body.split(separator: " ").prefix(60).joined(separator: " ")
        var text = sentByMe ? "You emailed \(people.isEmpty ? "someone" : people.joined(separator: ", ")): \(subject)"
            : "Email: \(subject)" + (from.isEmpty ? "" : "\nFrom: \(from)")
        if let when { text += "\nSent: " + ScreenDates.spoken(when, calendar: calendar) }
        if !start.isEmpty { text += "\nIt says: " + start + (body.count > start.count ? "…" : "") }
        // What the user sent and what came back are two items: a reply keeps the thread's subject.
        let key = "email|\(BrainModel.nameKey(subject))" + (sentByMe ? "" : "|from:" + BrainModel.nameKey(from))
        return MemoryItem(kind: .email, key: key, title: subject, body: text,
                          actor: from, people: people, when: when,
                          fields: ["subject": subject, "to": people.joined(separator: ", "), "from": from,
                                   "start": String(start.prefix(400)), "body": String(body.prefix(2500))], mine: sentByMe)
    }

    /// The name an email greets ("Hi Tanay," for "tanay"), properly written.
    static func greeted(in body: String, matching name: String) -> String? {
        guard let greeting = first(#"^(?:Hi|Hello|Hey|Dear)\s+([A-Z][\p{L}'-]+)"#, in: body) else { return nil }
        let first = name.split(separator: " ").first.map { $0.lowercased() } ?? name.lowercased()
        // An address's name ("info", "hello", "care.finance", "contact") isn't a person's: the one greeted is.
        let addressLike = !name.contains(" ") && (name == name.lowercased() || name.contains("."))
        return greeting.lowercased() == first || name.isEmpty || addressLike ? greeting : nil
    }

    /// "3:09 AM" (today, as the list was seen), "Nov 2", "2 Nov 2026".
    static func sentTime(_ text: String, seen: Date, calendar: Calendar) -> Date? {
        if let clock = ScreenDates.times(in: text).first, text.count <= 10 {
            return ScreenDates.at(seen, time: clock, calendar: calendar)
        }
        // A list's day without a year is the last such day up to when it was seen.
        guard var date = ScreenDates.find(in: text, reference: seen, calendar: calendar).first?.date else { return nil }
        while date > seen.addingTimeInterval(86400) { date = calendar.date(byAdding: .year, value: -1, to: date) ?? date.addingTimeInterval(-365 * 86400) }
        return date
    }

    /// What the user sent in a conversation, with whom (the conversation's title, when it's a name).
    static func messages(in window: Journal.Snapshot) -> [MemoryItem] {
        guard !window.authored.isEmpty else { return [] }
        let with = conversationName(window)
        let lines: [String] = window.authored.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        let to = with.isEmpty ? "" : " to \(with)"
        let people: [String] = with.isEmpty ? [] : [with]
        return lines.suffix(6).map { (line: String) -> MemoryItem in
            let key = "message|\(window.app.lowercased())|" + BrainModel.fingerprint([with, line])
            let body = "You sent\(to) in \(window.app): \(line)"
            return MemoryItem(kind: .message, key: key, title: String(line.prefix(80)), body: body, actor: "me", people: people,
                              when: window.last, fields: ["text": line, "to": with, "app": window.app], mine: true)
        }
    }

    /// Who a conversation is with, from its title: "Priya Sharma", "WhatsApp: Mom", "#design - Acme - Slack".
    static func conversationName(_ window: Journal.Snapshot) -> String {
        let parts = titleParts(window.title.replacingOccurrences(of: ": ", with: " - "))
            .filter { ![window.app.lowercased(), "slack", "whatsapp", "messages", "telegram", "signal", "discord", "teams",
                       "microsoft teams", "messenger", "linkedin", "chat"].contains($0.lowercased()) }
        guard let name = parts.first, name.count <= 50, !name.lowercased().hasPrefix("inbox") else { return "" }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "()0123456789 "))
    }

    // MARK: Flights

    /// Airlines by their two-character code.
    static let airlines: [String: String] = [
        "6E": "IndiGo", "AI": "Air India", "IX": "Air India Express", "QP": "Akasa Air", "SG": "SpiceJet", "UK": "Vistara",
        "I5": "AIX Connect", "G8": "Go First", "S5": "Star Air", "9I": "Alliance Air", "EK": "Emirates", "QR": "Qatar Airways",
        "EY": "Etihad", "SQ": "Singapore Airlines", "TG": "Thai Airways", "MH": "Malaysia Airlines", "LH": "Lufthansa",
        "BA": "British Airways", "AF": "Air France", "KL": "KLM", "UA": "United", "AA": "American Airlines", "DL": "Delta",
        "CX": "Cathay Pacific", "JL": "Japan Airlines", "NH": "ANA", "TK": "Turkish Airlines", "WY": "Oman Air",
        "GF": "Gulf Air", "FZ": "flydubai", "G9": "Air Arabia", "J9": "Jazeera Airways", "SV": "Saudia", "UL": "SriLankan",
        "AK": "AirAsia", "FD": "Thai AirAsia", "QF": "Qantas", "AC": "Air Canada", "LX": "Swiss", "VS": "Virgin Atlantic",
        "TR": "Scoot", "VN": "Vietnam Airlines", "KE": "Korean Air", "BR": "EVA Air", "U2": "easyJet", "FR": "Ryanair",
        "B6": "JetBlue", "AS": "Alaska Airlines", "WN": "Southwest", "NZ": "Air New Zealand", "IB": "Iberia",
    ]

    /// Airports by their three-letter code: India's, and the large ones abroad.
    static let airports: [String: String] = [
        "BLR": "Bengaluru", "DEL": "Delhi", "BOM": "Mumbai", "MAA": "Chennai", "CCU": "Kolkata", "HYD": "Hyderabad",
        "RPR": "Raipur", "PNQ": "Pune", "GOI": "Goa", "GOX": "Goa (Mopa)", "AMD": "Ahmedabad", "COK": "Kochi",
        "TRV": "Thiruvananthapuram", "JAI": "Jaipur", "LKO": "Lucknow", "PAT": "Patna", "BBI": "Bhubaneswar",
        "NAG": "Nagpur", "IXC": "Chandigarh", "GAU": "Guwahati", "IDR": "Indore", "BHO": "Bhopal", "VNS": "Varanasi",
        "SXR": "Srinagar", "IXB": "Bagdogra", "VTZ": "Visakhapatnam", "CJB": "Coimbatore", "IXM": "Madurai",
        "IXE": "Mangaluru", "IXR": "Ranchi", "JDH": "Jodhpur", "UDR": "Udaipur", "ATQ": "Amritsar", "DED": "Dehradun",
        "STV": "Surat", "VGA": "Vijayawada", "TRZ": "Tiruchirappalli", "IXZ": "Port Blair", "JGB": "Jagdalpur",
        "BHU": "Bhavnagar", "RAJ": "Rajkot", "HBX": "Hubballi", "IXU": "Aurangabad", "GWL": "Gwalior", "JLR": "Jabalpur",
        "DXB": "Dubai", "AUH": "Abu Dhabi", "DOH": "Doha", "SIN": "Singapore", "BKK": "Bangkok", "KUL": "Kuala Lumpur",
        "LHR": "London Heathrow", "LGW": "London Gatwick", "CDG": "Paris", "FRA": "Frankfurt", "AMS": "Amsterdam",
        "JFK": "New York JFK", "EWR": "Newark", "SFO": "San Francisco", "LAX": "Los Angeles", "SEA": "Seattle",
        "ORD": "Chicago", "IST": "Istanbul", "HKG": "Hong Kong", "NRT": "Tokyo Narita", "HND": "Tokyo Haneda",
        "SYD": "Sydney", "MEL": "Melbourne", "YYZ": "Toronto", "ZRH": "Zurich", "MUC": "Munich", "CMB": "Colombo",
        "KTM": "Kathmandu", "DAC": "Dhaka", "MLE": "Malé", "DPS": "Bali", "MCT": "Muscat", "BAH": "Bahrain", "RUH": "Riyadh",
        "JED": "Jeddah", "KWI": "Kuwait",
    ]

    static let bookingWords = ["pnr", "booking", "itinerary", "e-ticket", "eticket", "boarding pass", "check-in", "check in",
                               "web check", "reservation", "confirmation", "passenger", "your trip", "manage booking"]

    /// Labels that say a time isn't the departure: the first time after one of them is that deadline.
    static let otherTimes = #"(?i)(check[- ]?in\s*/\s*bag drop closes:?|check[- ]?in closes|check[- ]?in opens|counters? close|gate closes|bag drop closes|date of booking|booked on|boarding(?: time| starts| begins)?|reporting time|report by|starts on|opens on|closes at|web check[- ]?in)"#

    /// The flights on a booking page: number, from and to, the departure (day and time exactly as the page has them),
    /// the arrival, the booking reference, and when check-in opens and closes when the page says so. A connection
    /// ("6E 537 | 6E 7575", one stop) is one journey, under its first flight.
    static func flights(in window: Journal.Snapshot, mine: Bool, calendar: Calendar) -> [MemoryItem] {
        let text = window.title + "\n" + window.text
        let lower = text.lowercased()
        guard bookingWords.contains(where: lower.contains) else { return [] }
        let kind = WindowKind.of(window)
        // Not a flight being talked about (an AI chat, docs, code, a terminal): the airline's own pages and the user's mail.
        guard ![.feed, .search, .video, .article, .assistant, .docs].contains(kind), !editors.contains(window.app),
              !terminals.contains(window.app) else { return [] }
        let codes = airlines.keys.sorted().joined(separator: "|")
        let numbers = ranges(#"\b(\#(codes))[\s-]?(\d{2,4})\b"#, in: text)
        guard !numbers.isEmpty else { return [] }
        let reference = first(#"(?i)(?:pnr|booking ref(?:erence)?|booking id|confirmation (?:no\.?|number|code))[\s\:#|-]{0,5}([A-Z0-9]{5,8})\b"#,
                              in: text)
        // Every time on the page, and those a label says are something else (check-in closes, boarding…).
        let clocks = ScreenDates.timeMatches(in: text)
        var deadlines: [Int: String] = [:]   // index in clocks -> its label
        for label in ranges(otherTimes, in: text) {
            if let index = clocks.firstIndex(where: { $0.range.lowerBound >= label.range.upperBound
                && text.distance(from: label.range.upperBound, to: $0.range.lowerBound) <= 30 }) {
                deadlines[index] = label.groups[0].lowercased()
            }
        }
        let departureLabels = ranges(#"(?i)\b(?:depart(?:ure|s|ing)? (?:time|at)|departs|dep\.|std|takes off)\b"#, in: text)
        let arrivalLabels = ranges(#"(?i)\b(?:arriv(?:al|es|ing)? (?:time|at)|arrives|arr\.|sta|lands)\b"#, in: text)
        func labelled(_ labels: [(range: Range<String.Index>, groups: [String])], near: Range<String.Index>) -> Int? {
            for label in labels where abs(text.distance(from: label.range.lowerBound, to: near.lowerBound)) <= 700 {
                if let index = clocks.firstIndex(where: { $0.range.lowerBound >= label.range.upperBound
                    && text.distance(from: label.range.upperBound, to: $0.range.lowerBound) <= 30 }) { return index }
            }
            return nil
        }
        func position(_ index: String.Index) -> Int { text.distance(from: text.startIndex, to: index) }
        var out: [MemoryItem] = []
        var seen = Set<String>()
        var previousEnd: String.Index?
        for (range, groups) in numbers {
            let airline = groups[0], digits = groups[1]
            let number = "\(airline) \(digits)"
            // The next leg of a connection, right after the first: kept with it.
            if let end = previousEnd, range.lowerBound >= end, text.distance(from: end, to: range.lowerBound) <= 12,
               var last = out.popLast() {
                last.fields["connecting"] = (last.fields["connecting"].map { $0 + ", " } ?? "") + number
                last.body += "\nConnecting flight: \(number)"
                out.append(last)
                seen.insert(number)
                previousEnd = range.upperBound
                continue
            }
            previousEnd = range.upperBound
            guard !seen.contains(number) else { continue }
            let at = position(range.lowerBound)
            // The day: the one nearest the number, on or after the day before the page was seen.
            let floor = calendar.startOfDay(for: window.first).addingTimeInterval(-86400)
            let allDays = ScreenDates.dateMatches(in: text, reference: window.first, calendar: calendar)
            let days = allDays.filter { $0.date >= floor }
            guard let day = days.min(by: { abs(position($0.range.lowerBound) - at) < abs(position($1.range.lowerBound) - at) })?.date
            else { continue }
            // The journey's times: those no label claims (check-in closes, boarding…), and not beside another day (when
            // it was booked, when the page was printed). It leaves at the earliest of them and arrives at the latest:
            // an itinerary lists each stop's time, a connection's too.
            let free = clocks.indices.filter { index in
                guard deadlines[index] == nil else { return false }
                let here = position(clocks[index].range.lowerBound)
                let near = allDays.filter { abs(position($0.range.lowerBound) - here) <= 30 }
                    .min { abs(position($0.range.lowerBound) - here) < abs(position($1.range.lowerBound) - here) }
                return near.map { calendar.isDate($0.date, inSameDayAs: day) } ?? true
            }
            func minutes(_ index: Int) -> Int { clocks[index].clock.hour * 60 + clocks[index].clock.minute }
            let departureIndex = labelled(departureLabels, near: range) ?? free.min { minutes($0) < minutes($1) }
            guard let departureIndex else { continue }
            let departure = clocks[departureIndex].clock
            let arrivalIndex = labelled(arrivalLabels, near: range)
                ?? free.filter { minutes($0) > minutes(departureIndex) }.max { minutes($0) < minutes($1) }
            let arrival = arrivalIndex.map { clocks[$0].clock }
            let lo = text.index(range.lowerBound, offsetBy: -min(260, at))
            let hi = text.index(range.upperBound, offsetBy: min(500, text.distance(from: range.upperBound, to: text.endIndex)))
            let around = String(text[lo..<hi])
            var route: [String] = []
            for code in ranges(#"\b([A-Z]{3})\b"#, in: around).map({ $0.groups[0] }) where airports[code] != nil && !route.contains(code) {
                route.append(code)
            }
            let named = ranges(#"\b(Bengaluru|Bangalore|New Delhi|Delhi|Mumbai|Chennai|Kolkata|Hyderabad|Raipur|Pune|Goa|Ahmedabad|Kochi|Jaipur|Lucknow|Patna|Bhubaneswar|Nagpur|Chandigarh|Guwahati|Indore|Bhopal|Varanasi|Srinagar|Dubai|Singapore|Bangkok|London|Doha)\b"#,
                               in: around).map { $0.groups[0] }
            var cities: [String] = []
            for city in named where !cities.contains(city) { cities.append(city) }
            // "BLR RPR", "BLR-RPR": the trip's own ends, when the page says them; else the first two places named.
            let ends = ranges(#"\b([A-Z]{3})\s?[-–→ ]\s?([A-Z]{3})\b"#, in: text).first { airports[$0.groups[0]] != nil && airports[$0.groups[1]] != nil }
            let from = ends.map { airports[$0.groups[0]]! } ?? route.first.map { airports[$0] ?? $0 } ?? cities.first ?? ""
            let to = ends.map { airports[$0.groups[1]]! } ?? route.dropFirst().first.map { airports[$0] ?? $0 } ?? cities.dropFirst().first ?? ""
            guard let departs = ScreenDates.at(day, time: departure, calendar: calendar) else { continue }
            var arrives = arrival.flatMap { ScreenDates.at(day, time: $0, calendar: calendar) }
            if let value = arrives, value < departs { arrives = value.addingTimeInterval(86400) }   // lands after midnight
            seen.insert(number)
            var fields = ["number": number, "airline": airlines[airline] ?? airline,
                          "departs": ScreenDates.stamp(departs, calendar: calendar), "departure time": departure.text]
            if let arrives, let arrival { fields["arrives"] = ScreenDates.stamp(arrives, calendar: calendar); fields["arrival time"] = arrival.text }
            if !from.isEmpty { fields["from"] = from }
            if !to.isEmpty { fields["to"] = to }
            if let reference { fields["reference"] = reference }
            // Deadlines: as the page labels them, on the flight's day (or the day the label gives); else from "48 hrs to
            // 60 mins before".
            for (index, label) in deadlines where !label.contains("booking") && !label.contains("booked") {
                let clock = clocks[index]
                let after = String(text[clock.range.upperBound...].prefix(24))
                let date = ScreenDates.find(in: after, reference: window.first, calendar: calendar).first?.date ?? day
                guard let when = ScreenDates.at(date, time: clock.clock, calendar: calendar), when <= departs,
                      departs.timeIntervalSince(when) <= 4 * 86400 else { continue }
                let name = label.contains("open") || label.contains("starts") || label.contains("web check") ? "check-in opens"
                    : label.contains("boarding") ? "boarding" : label.contains("report") ? "reporting" : "check-in closes"
                if fields[name] == nil { fields[name] = ScreenDates.stamp(when, calendar: calendar) }
            }
            if fields["check-in closes"] == nil, let closes = checkInCloses(text, departs: departs) {
                fields["check-in closes"] = ScreenDates.stamp(closes, calendar: calendar)
            }
            if fields["check-in opens"] == nil, let opens = checkInOpens(text, departs: departs) {
                fields["check-in opens"] = ScreenDates.stamp(opens, calendar: calendar)
            }
            let path = from.isEmpty ? "" : " \(from)" + (to.isEmpty ? "" : " to \(to)")
            let title = "Flight \(number)\(path)"
            var body = "\(title) (\(airlines[airline] ?? airline))\nDeparts: \(ScreenDates.spoken(departs, calendar: calendar))"
            if let arrives { body += "\nArrives: \(ScreenDates.spoken(arrives, calendar: calendar))" }
            if let reference { body += "\nBooking reference: \(reference)" }
            if let value = fields["check-in opens"] { body += "\nWeb check-in opens: \(value)" }
            if let value = fields["check-in closes"] { body += "\nCheck-in closes: \(value)" }
            if let value = fields["boarding"] { body += "\nBoarding: \(value)" }
            out.append(MemoryItem(kind: .flight, key: "flight|\(airline)\(digits)|\(ScreenDates.dayKey(departs, calendar: calendar))".lowercased(),
                                  title: title, body: body, when: departs, fields: fields, mine: mine))
        }
        return out
    }

    /// The value most of these say (the latest on a tie), nil for none.
    static func majority(_ values: [String]) -> String? {
        var votes: [String: Int] = [:], last: [String: Int] = [:]
        for (index, value) in values.enumerated() { votes[value, default: 0] += 1; last[value] = index }
        return votes.max { $0.value == $1.value ? (last[$0.key] ?? 0) < (last[$1.key] ?? 0) : $0.value < $1.value }?.key
    }

    /// A flight's title and lines from its fields.
    static func flightText(_ fields: [String: String], calendar: Calendar = .current) -> (title: String, body: String) {
        let number = fields["number"] ?? "", from = fields["from"] ?? "", to = fields["to"] ?? ""
        let path = from.isEmpty ? "" : " \(from)" + (to.isEmpty ? "" : " to \(to)")
        let title = "Flight \(number)\(path)"
        let stamp = ScreenDates.formatter("yyyy-MM-dd HH:mm", calendar)
        func spoken(_ key: String) -> String? { fields[key].flatMap { stamp.date(from: $0) }.map { ScreenDates.spoken($0, calendar: calendar) } }
        var body = "\(title) (\(fields["airline"] ?? ""))"
        if let departs = spoken("departs") { body += "\nDeparts: \(departs)" }
        if let arrives = spoken("arrives") { body += "\nArrives: \(arrives)" }
        if let reference = fields["reference"] { body += "\nBooking reference: \(reference)" }
        if let value = fields["check-in opens"] { body += "\nWeb check-in opens: \(value)" }
        if let value = fields["check-in closes"] { body += "\nCheck-in closes: \(value)" }
        if let value = fields["boarding"] { body += "\nBoarding: \(value)" }
        if let value = fields["connecting"] { body += "\nConnecting flight: \(value)" }
        return (title, body)
    }

    /// "Check-in closes 60 minutes before departure", "counters close 45 mins prior".
    static func checkInCloses(_ text: String, departs: Date) -> Date? {
        if let span = ranges(#"(?i)check[- ]?in[^.\n]{0,40}?(\d{1,3})\s*(?:hours?|hrs?)\s*to\s*(\d{1,3})\s*(?:minutes?|mins?)\s*before"#, in: text).first,
           let minutes = Double(span.groups[1]) {
            return departs.addingTimeInterval(-minutes * 60)
        }
        guard let match = ranges(#"(?i)(?:check[- ]?in|counters?|bag drop)[^.\n]{0,50}?clos\w*[^.\n]{0,30}?(\d{1,3})\s*(hours?|hrs?|minutes?|mins?)\s*(?:before|prior)"#,
                                 in: text).first, let amount = Double(match.groups[0]) else { return nil }
        return departs.addingTimeInterval(-amount * (match.groups[1].lowercased().hasPrefix("h") ? 3600 : 60))
    }

    /// "Web check-in opens 48 hours before departure".
    static func checkInOpens(_ text: String, departs: Date) -> Date? {
        if let span = ranges(#"(?i)check[- ]?in[^.\n]{0,40}?(\d{1,3})\s*(?:hours?|hrs?)\s*to\s*(\d{1,3})\s*(?:minutes?|mins?)\s*before"#, in: text).first,
           let hours = Double(span.groups[0]) {
            return departs.addingTimeInterval(-hours * 3600)
        }
        guard let match = ranges(#"(?i)check[- ]?in[^.\n]{0,40}?opens?[^.\n]{0,30}?(\d{1,3})\s*(hours?|hrs?|days?)\s*(?:before|prior)"#,
                                 in: text).first, let amount = Double(match.groups[0]) else { return nil }
        return departs.addingTimeInterval(-amount * (match.groups[1].lowercased().hasPrefix("d") ? 86400 : 3600))
    }

    // MARK: Matching

    static func ranges(_ pattern: String, in text: String) -> [(range: Range<String.Index>, groups: [String])] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let groups = (1..<max(1, match.numberOfRanges)).map { index -> String in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            return (range, groups)
        }
    }

    static func first(_ pattern: String, in text: String) -> String? {
        ranges(pattern, in: text).first.map { $0.groups.first ?? String(text[$0.range]) }
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        ranges(pattern, in: text).map { $0.groups.first ?? String(text[$0.range]) }
    }
}

/// Days and times as windows write them ("Sat, 08 Nov 2026", "8 Nov", "Nov 8, 2026", "2026-11-08", "08/11/2026",
/// "10:15", "10:15 AM", "22.40"), read exactly: nothing is guessed but a missing year (the next such day).
public enum ScreenDates {
    public struct Clock: Sendable, Equatable {
        public var hour: Int
        public var minute: Int
        /// As the page wrote it ("10:15", "6:05 pm").
        public var text: String
    }

    static let months: [String: Int] = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8,
                                        "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12]

    /// The days in a text, in the order they appear.
    public static func find(in text: String, reference: Date, calendar: Calendar = .current) -> [(date: Date, written: String)] {
        dateMatches(in: text, reference: reference, calendar: calendar).map { ($0.date, String(text[$0.range])) }
    }

    /// The days in a text with where each is, in order.
    static func dateMatches(in text: String, reference: Date, calendar: Calendar = .current) -> [(date: Date, range: Range<String.Index>)] {
        let month = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
        let patterns: [(String, (([String]) -> (y: Int?, m: Int, d: Int)?))] = [
            (#"\b(\d{4})-(\d{2})-(\d{2})\b"#, { g in (Int(g[0]), Int(g[1]) ?? 0, Int(g[2]) ?? 0) }),
            (#"(?i)\b(\d{1,2})(?:st|nd|rd|th)?[\s-]+"# + month + #"\.?,?(?:[\s-]+(\d{4}|'\d{2}))?\b"#, { g in
                guard let m = months[String(g[1].lowercased().prefix(g[1].lowercased().hasPrefix("sept") ? 4 : 3))] else { return nil }
                return (year(g[2]), m, Int(g[0]) ?? 0)
            }),
            (#"(?i)\b"# + month + #"\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#, { g in
                guard let m = months[String(g[0].lowercased().prefix(g[0].lowercased().hasPrefix("sept") ? 4 : 3))] else { return nil }
                return (year(g[2]), m, Int(g[1]) ?? 0)
            }),
            (#"\b(\d{1,2})[/.](\d{1,2})[/.](\d{4})\b"#, { g in (Int(g[2]), Int(g[1]) ?? 0, Int(g[0]) ?? 0) }),   // day first
        ]
        var found: [(date: Date, range: Range<String.Index>)] = []
        var taken: [Range<String.Index>] = []
        for (pattern, read) in patterns {
            for match in ItemReader.ranges(pattern, in: text) where !taken.contains(where: { $0.overlaps(match.range) }) {
                guard let parts = read(match.groups), (1...12).contains(parts.m), (1...31).contains(parts.d) else { continue }
                var components = DateComponents(year: parts.y, month: parts.m, day: parts.d)
                if parts.y == nil {
                    // No year: the next such day from when it was seen (or within the last two months).
                    let seen = calendar.dateComponents([.year], from: reference)
                    components.year = seen.year
                    if let date = calendar.date(from: components), date < reference.addingTimeInterval(-60 * 86400) {
                        components.year = (seen.year ?? 0) + 1
                    }
                }
                guard let date = calendar.date(from: components),
                      calendar.component(.day, from: date) == parts.d else { continue }   // "31 Feb"
                taken.append(match.range)
                found.append((date, match.range))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func year(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("'") { return Int(text.dropFirst()).map { 2000 + $0 } }
        return Int(text)
    }

    /// "2 days ago", "yesterday", "3 hours ago": the day it means.
    static func relative(_ text: String, reference: Date, calendar: Calendar) -> Date? {
        let lower = text.lowercased()
        if lower.contains("yesterday") { return reference.addingTimeInterval(-86400) }
        if lower.contains("today") || lower.contains("hours ago") || lower.contains("minutes ago") || lower.contains("hour ago") {
            return reference
        }
        if let days = ItemReader.first(#"(\d+) days? ago"#, in: lower).flatMap(Int.init) {
            return reference.addingTimeInterval(-Double(days) * 86400)
        }
        return nil
    }

    /// The times in a text, in order: "10:15", "10:15 AM", "6.05pm", "22:40 hrs". Not parts of a longer number.
    public static func times(in text: String) -> [Clock] { timeMatches(in: text).map(\.clock) }

    static func timeMatches(in text: String) -> [(clock: Clock, range: Range<String.Index>)] {
        ItemReader.ranges(#"(?<![\d\:.])([01]?\d|2[0-3])[\:.]([0-5]\d)(?![\d\:])(?:\s?(am|pm|AM|PM|a\.m\.|p\.m\.))?"#, in: text)
            .compactMap { match in
                guard var hour = Int(match.groups[0]), let minute = Int(match.groups[1]) else { return nil }
                let meridian = match.groups[2].lowercased()
                // "6.05" alone could be anything: a dot takes "am"/"pm" to be a time.
                if text[match.range].contains("."), meridian.isEmpty, !text[match.range].contains(":") { return nil }
                if meridian.hasPrefix("p"), hour < 12 { hour += 12 }
                if meridian.hasPrefix("a"), hour == 12 { hour = 0 }
                return (Clock(hour: hour, minute: minute, text: String(text[match.range])), match.range)
            }
    }

    /// The first time after a label ("Departure 10:15", "Dep: 10:15", "Departs at 10:15 AM").
    static func labelledTime(_ label: String, in text: String) -> Clock? {
        for match in ItemReader.ranges(label, in: text) {
            let rest = String(text[match.range.upperBound...].prefix(40))
            // The time right after the label, before anything else that's a word of its own ("Departure Terminal 1").
            if let clock = times(in: rest).first, let at = rest.range(of: clock.text),
               rest[..<at.lowerBound].split(whereSeparator: \.isWhitespace).filter({ $0.contains(where: \.isLetter) }).count <= 3 {
                return clock
            }
        }
        return nil
    }

    static func at(_ day: Date, time: Clock, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        return calendar.date(from: components)
    }

    static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// "2026-11-08 10:15".
    public static func stamp(_ date: Date, calendar: Calendar = .current) -> String { formatter("yyyy-MM-dd HH:mm", calendar).string(from: date) }
    /// "2026-11-08".
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String { formatter("yyyy-MM-dd", calendar).string(from: date) }
    /// "Sat 8 Nov 2026".
    public static func day(_ date: Date, calendar: Calendar = .current) -> String { formatter("EEE d MMM yyyy", calendar).string(from: date) }
    /// "Sat 8 Nov 2026, 10:15".
    public static func spoken(_ date: Date, calendar: Calendar = .current) -> String { formatter("EEE d MMM yyyy, HH:mm", calendar).string(from: date) }
}
