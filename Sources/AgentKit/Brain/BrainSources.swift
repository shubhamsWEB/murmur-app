import AppKit
import Contacts
import EventKit

/// Where the living memory learns from, on this Mac. Each source lists its items (a contact, an event, a note, an
/// email) with a hash of what they say, so only what changed is read again. Contacts, Calendar and Reminders say
/// what they say plainly: their memories are written here, with no model. Notes and Mail are read by the local model
/// (BrainDistiller). Each asks macOS for access only when its switch is turned on.
public enum BrainSource: String, CaseIterable, Sendable, Identifiable {
    case contacts, calendar, reminders, notes, mail, commands

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .contacts: return "Contacts"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .notes: return "Notes"
        case .mail: return "Mail"
        case .commands: return "What you tell Murmur"
        }
    }

    public var about: String {
        switch self {
        case .contacts: return "Who people are: their work, numbers, birthdays, family."
        case .calendar: return "Who you meet and what's coming up, 30 days back and 60 ahead."
        case .reminders: return "What you have to do. Done ones are forgotten."
        case .notes: return "People, projects and decisions in your notes, read by your local model."
        case .mail: return "Who you write to and about what, from your latest mail, read by your local model."
        case .commands: return "Facts you told Murmur (“remember that…”). They never fade."
        }
    }

    public var origin: BrainModel.Origin {
        switch self {
        case .contacts: return .contacts
        case .calendar: return .calendar
        case .reminders: return .reminders
        case .notes: return .notes
        case .mail: return .mail
        case .commands: return .told
        }
    }

    /// Read by the local model (slowly, in the background), rather than as it is.
    public var needsModel: Bool { self == .notes || self == .mail }

    /// On until turned off; the others ask for access first, so they start off.
    public var onByDefault: Bool { self == .commands }
}

/// One thing a source showed: its key, what it says (hashed), and either its memories (structured sources) or its
/// text for the model to read.
struct BrainEntry: Sendable {
    let key: String
    let hash: String
    let title: String
    var candidates: [BrainModel.Candidate] = []
    var text: String? = nil
    var at: Date? = nil
}

struct BrainListing: Sendable {
    var entries: [BrainEntry]
    /// Every item the source has (not just the latest): one missing from it was deleted there.
    var complete: Bool
}

public enum BrainSources {
    /// What a source has now. Nil when Murmur may not read it (access denied, the app missing).
    static func list(_ source: BrainSource) async -> BrainListing? {
        switch source {
        case .contacts: return await contacts()
        case .calendar: return await calendar()
        case .reminders: return await reminders()
        case .notes: return await notes()
        case .mail: return await mail()
        case .commands: return told()
        }
    }

    /// A short, stable fingerprint of what an item says.
    static func hash(_ parts: [String?]) -> String { BrainModel.fingerprint(parts) }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // MARK: Contacts

    nonisolated(unsafe) private static let contactKeys = [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
        CNContactJobTitleKey, CNContactDepartmentNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        CNContactBirthdayKey, CNContactRelationsKey, CNContactPostalAddressesKey, CNContactTypeKey,
    ] as [CNKeyDescriptor]

    static func contactsAllowed(ask: Bool) async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return true
        case .notDetermined where ask:
            return await Permissions.inFront { (try? await CNContactStore().requestAccess(for: .contacts)) ?? false }
        default: return false
        }
    }

    private static func contacts() async -> BrainListing? {
        guard await contactsAllowed(ask: true) else { return nil }
        return await Task.detached(priority: .utility) { () -> BrainListing in
            let store = CNContactStore()
            var entries: [BrainEntry] = []
            let request = CNContactFetchRequest(keysToFetch: contactKeys)
            try? store.enumerateContacts(with: request) { contact, _ in
                if let entry = entry(contact, about: nil) { entries.append(entry) }
            }
            // The "me" card: what Murmur knows about you.
            if let me = try? store.unifiedMeContactWithKeys(toFetch: contactKeys), var entry = entry(me, about: "me") {
                // Titled with your name: it becomes another name for "you", so a note about you by name is about you.
                entry = BrainEntry(key: "me", hash: entry.hash, title: entry.title, candidates: entry.candidates)
                entries.append(entry)
            }
            return BrainListing(entries: entries, complete: true)
        }.value
    }

    /// A contact's memories: each thing on the card, in a sentence. `about`: "me" for your own card.
    static func entry(_ contact: CNContact, about: String?) -> BrainEntry? {
        let person = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let company = contact.organizationName
        let isCompany = contact.contactType == .organization
        let name = person.isEmpty ? company : person
        guard !name.isEmpty else { return nil }
        let mine = about == "me"
        let subject = mine ? "You" : name
        let entityKind: BrainModel.EntityKind = mine ? .me : (isCompany || person.isEmpty ? .organization : .person)
        let entityName = mine ? "me" : name
        var memories: [BrainModel.Candidate] = []
        func add(_ text: String, _ kind: BrainModel.Kind = .fact, slot: String? = nil) {
            memories.append(BrainModel.Candidate(about: entityName, aboutKind: entityKind, text: text, kind: kind, slot: slot, confidence: 0.95, origin: .contacts))
        }
        if !mine, !contact.nickname.isEmpty { add("\(name) goes by \(contact.nickname)", slot: "nickname") }
        if mine, !person.isEmpty { add("Your name is \(person)", slot: "name") }
        if !company.isEmpty, !isCompany, !person.isEmpty {
            let role = [contact.jobTitle, contact.departmentName].filter { !$0.isEmpty }.joined(separator: ", ")
            add(role.isEmpty ? "\(subject) works at \(company)" : "\(subject) works at \(company) as \(role)", slot: "employer")
        } else if !contact.jobTitle.isEmpty {
            add("\(subject) is \(contact.jobTitle)", slot: "role")
        }
        let phones = contact.phoneNumbers.map { number in
            let label = number.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? ""
            return label.isEmpty ? number.value.stringValue : "\(label) \(number.value.stringValue)"
        }
        if !phones.isEmpty { add("\(subject)'s phone: \(phones.prefix(4).joined(separator: ", "))", slot: "phone") }
        let emails = contact.emailAddresses.map { $0.value as String }
        if !emails.isEmpty { add("\(subject)'s email: \(emails.prefix(4).joined(separator: ", "))", slot: "email") }
        if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
            var components = DateComponents()
            components.month = month
            components.day = day
            components.year = birthday.year ?? 2000
            if let date = Calendar.current.date(from: components) {
                let text = birthday.year != nil ? date.formatted(.dateTime.day().month(.wide).year())
                    : date.formatted(.dateTime.day().month(.wide))
                add("\(subject)'s birthday is \(text)", slot: "birthday")
            }
        }
        if let city = contact.postalAddresses.first?.value.city, !city.isEmpty {
            add("\(subject) \(mine ? "live" : "lives") in \(city)", slot: "city")
        }
        for relation in contact.contactRelations.prefix(6) {
            let label = relation.label.map { CNLabeledValue<CNContactRelation>.localizedString(forLabel: $0) } ?? "relation"
            let other = relation.value.name
            guard !other.isEmpty else { continue }
            add("\(mine ? "Your" : "\(name)'s") \(label.lowercased()) is \(other)", .relationship, slot: "relation_\(label.lowercased())")
        }
        guard !memories.isEmpty || !mine else { return nil }
        if memories.isEmpty { add("\(name) is in your contacts") }
        let key = mine ? "me" : contact.identifier
        return BrainEntry(key: key, hash: hash(memories.map(\.text)), title: name, candidates: memories)
    }

    // MARK: Calendar and Reminders

    nonisolated(unsafe) private static let events = EKEventStore()

    private static func calendar() async -> BrainListing? {
        guard await Permissions.events(.event, store: events) else { return nil }
        let now = Date()
        let from = now.addingTimeInterval(-30 * 86400), to = now.addingTimeInterval(60 * 86400)
        let found = events.events(matching: events.predicateForEvents(withStart: from, end: to, calendars: nil))
        var entries: [BrainEntry] = []
        var recurring: [String: (title: String, people: [String], rule: String)] = [:]
        for event in found.prefix(1500) {
            let people = (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { $0.name }
                .filter { !$0.isEmpty && !$0.contains("@") }
            let title = event.title ?? "Untitled"
            // A meeting that repeats says who you meet regularly; kept once, not per occurrence.
            if event.hasRecurrenceRules, !people.isEmpty, let rule = event.recurrenceRules?.first {
                let how: String
                switch rule.frequency {
                case .daily: how = "daily"
                case .weekly: how = rule.interval == 2 ? "every two weeks" : "weekly"
                case .monthly: how = "monthly"
                default: how = "regularly"
                }
                recurring[title.lowercased()] = (title, people, how)
                continue
            }
            // Only what's still to come is an event worth remembering; the past is who you met.
            guard event.endDate > now else {
                guard !people.isEmpty, people.count <= 6 else { continue }
                let memories = people.map { person in
                    BrainModel.Candidate(about: person, aboutKind: .person,
                                         text: "Met \(person) for \"\(title)\" on \(day(event.startDate))",
                                         kind: .fact, slot: "last_met", confidence: 0.8, origin: .calendar)
                }
                entries.append(BrainEntry(key: "\(event.calendarItemIdentifier)@\(Int(event.startDate.timeIntervalSince1970))",
                                          hash: hash([title, people.joined(separator: ","), String(event.startDate.timeIntervalSince1970)]),
                                          title: title, candidates: memories, at: event.startDate))
                continue
            }
            let when = event.isAllDay ? day(event.startDate)
                : "\(day(event.startDate)), \(event.startDate.formatted(date: .omitted, time: .shortened))"
            var text = "\"\(title)\" on \(when)"
            if !people.isEmpty { text += " with \(people.prefix(5).joined(separator: ", "))" }
            if let location = event.location, !location.isEmpty, location.count < 80 { text += " at \(location)" }
            let expires = event.endDate.addingTimeInterval(3600)
            var memories = [BrainModel.Candidate(about: "me", aboutKind: .me, text: "Coming up: \(text)", kind: .event,
                                                 expires: expires, confidence: 0.95, origin: .calendar)]
            for person in people.prefix(4) {
                memories.append(BrainModel.Candidate(about: person, aboutKind: .person, text: "Meeting the user: \(text)",
                                                     kind: .event, expires: expires, confidence: 0.95, origin: .calendar))
            }
            entries.append(BrainEntry(key: "\(event.calendarItemIdentifier)@\(Int(event.startDate.timeIntervalSince1970))",
                                      hash: hash([title, text]), title: title, candidates: memories, at: event.startDate))
        }
        for (key, meeting) in recurring {
            let memories = meeting.people.prefix(6).map { person in
                BrainModel.Candidate(about: person, aboutKind: .person,
                                     text: "Meets the user \(meeting.rule) in \"\(meeting.title)\"", kind: .relationship,
                                     slot: "meeting_\(key.prefix(40))", confidence: 0.9, origin: .calendar)
            }
            entries.append(BrainEntry(key: "recurring:\(key)", hash: hash([meeting.title, meeting.rule] + meeting.people),
                                      title: meeting.title, candidates: memories))
        }
        // A window of time, not all of it: what's outside it simply ages out.
        return BrainListing(entries: entries, complete: false)
    }

    private static func reminders() async -> BrainListing? {
        guard await Permissions.events(.reminder, store: events) else { return nil }
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let open: [EKReminder] = await withCheckedContinuation { continuation in
            _ = events.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        let entries = open.prefix(400).compactMap { reminder -> BrainEntry? in
            guard let title = reminder.title, !title.isEmpty else { return nil }
            let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let text = "To do: \(title)" + (due.map { " (due \(day($0)))" } ?? "")
            let memory = BrainModel.Candidate(about: "me", aboutKind: .me, text: text, kind: .task,
                                              expires: due?.addingTimeInterval(3 * 86400), confidence: 0.95,
                                              origin: .reminders)
            return BrainEntry(key: reminder.calendarItemIdentifier, hash: hash([text]), title: title, candidates: [memory])
        }
        // Every open reminder: one that's gone was done (or deleted), and is forgotten.
        return BrainListing(entries: entries, complete: true)
    }

    // MARK: Notes and Mail (read by the model)

    /// Runs a JavaScript for Automation script, starting its app hidden first if it isn't running (and quitting it
    /// after, if Murmur started it).
    private static func automation(_ bundleID: String, _ script: String, _ arguments: [String] = []) async -> String? {
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if !wasRunning {
            guard let url = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) })
            else { return nil }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        await Permissions.automation(bundleID)
        let output = await MacActions.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script] + arguments, timeout: 120)
        if !wasRunning {
            _ = await MacActions.run("/usr/bin/osascript", ["-e", "tell application id \"\(bundleID)\" to quit"], timeout: 10)
        }
        guard output.hasPrefix("[") || output.hasPrefix("{") else { return nil }
        return output
    }

    private static func json(_ text: String?) -> [[String: Any]] {
        guard let text, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return value
    }

    /// Notes changed in the last year, the 150 newest; their text is fetched only when they're read.
    private static func notes() async -> BrainListing? {
        let script = """
            const app = Application('Notes');
            const ids = app.notes.id(), names = app.notes.name(), dates = app.notes.modificationDate();
            JSON.stringify(ids.map((id, i) => ({id: id, name: names[i], at: dates[i] ? dates[i].getTime() / 1000 : 0})));
            """
        guard let output = await automation("com.apple.Notes", script) else { return nil }
        let cutoff = Date().addingTimeInterval(-365 * 86400).timeIntervalSince1970
        let all = json(output).compactMap { note -> BrainEntry? in
            guard let id = note["id"] as? String else { return nil }
            let at = note["at"] as? Double ?? 0
            return BrainEntry(key: id, hash: hash([String(Int(at))]), title: note["name"] as? String ?? "Note",
                              at: Date(timeIntervalSince1970: at))
        }
        let recent = all.filter { ($0.at?.timeIntervalSince1970 ?? 0) > cutoff }
            .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }.prefix(150)
        // The full list, so a deleted note is forgotten; only the recent ones get read.
        return BrainListing(entries: Array(recent) + all.filter { e in !recent.contains { $0.key == e.key } }
            .map { BrainEntry(key: $0.key, hash: "old", title: $0.title, at: $0.at) }, complete: true)
    }

    /// The text of these notes, by id.
    static func noteTexts(_ ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let script = """
            function run(ids) {
              const app = Application('Notes');
              return JSON.stringify(ids.map(id => { try { return {id: id, text: app.notes.byId(id).plaintext().slice(0, 8000)}; }
                                                    catch (e) { return {id: id, text: ''}; } }));
            }
            """
        let output = await automation("com.apple.Notes", script, ids)
        var texts: [String: String] = [:]
        for note in json(output) { if let id = note["id"] as? String { texts[id] = note["text"] as? String ?? "" } }
        return texts
    }

    /// The 30 newest emails you received and the 20 newest you sent, with their text.
    private static func mail() async -> BrainListing? {
        let script = """
            const Mail = Application('Mail');
            const out = [];
            for (const [box, label, n] of [[Mail.inbox, 'From', 30], [Mail.sentMailbox, 'To', 20]]) {
              let dates = [];
              try { dates = box.messages.dateReceived(); } catch (e) { continue; }
              const order = dates.map((d, i) => [d ? d.getTime() : 0, i]).sort((a, b) => b[0] - a[0]).slice(0, n);
              for (const [time, i] of order) {
                try {
                  const m = box.messages[i];
                  const who = label === 'From' ? m.sender() : m.toRecipients.name().concat(m.toRecipients.address()).join(', ');
                  out.push({id: String(m.messageId()), subject: m.subject() || '', who: label + ': ' + who,
                            at: time / 1000, text: (m.content() || '').slice(0, 5000)});
                } catch (e) {}
              }
            }
            JSON.stringify(out);
            """
        guard let output = await automation("com.apple.mail", script) else { return nil }
        let entries = json(output).compactMap { message -> BrainEntry? in
            guard let id = message["id"] as? String else { return nil }
            let subject = message["subject"] as? String ?? ""
            let who = message["who"] as? String ?? ""
            let text = "\(who)\nSubject: \(subject)\n\n\(message["text"] as? String ?? "")"
            return BrainEntry(key: id, hash: hash([id]), title: subject.isEmpty ? who : subject, text: text,
                              at: Date(timeIntervalSince1970: message["at"] as? Double ?? 0))
        }
        // The latest few, not the whole mailbox: older mail isn't "deleted".
        return BrainListing(entries: entries, complete: false)
    }

    // MARK: What you told Murmur

    private static func told() -> BrainListing {
        let entries = CommandMemory.toldFacts().map { fact in
            BrainEntry(key: fact.id, hash: hash([fact.text]), title: fact.text,
                       candidates: [BrainModel.Candidate(about: "me", aboutKind: .me, text: fact.text, kind: .preference,
                                                         confidence: 1, origin: .told)])
        }
        return BrainListing(entries: entries, complete: true)
    }

    // MARK: Google Drive

    /// Google Drive for desktop's folders on this Mac (~/Library/CloudStorage/GoogleDrive-…/My Drive, Shared drives).
    /// Adding one to Murmur's folders makes its files searchable, and what's in them part of what Murmur can find.
    public static func googleDriveFolders() -> [URL] {
        let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let accounts = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
        return accounts.filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }.flatMap { account -> [URL] in
            let inside = (try? FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? []
            return inside.filter { ["My Drive", "Shared drives"].contains($0.lastPathComponent) }
        }
    }
}
