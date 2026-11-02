import AppKit

/// Sending a message or a file for you in any chat app (WhatsApp, Messages, Slack, Telegram, Signal, Discord, Teams),
/// always after you've said yes. Messages sends by AppleScript; every other app the same way: open the chat (directly
/// where Murmur can, else the one the model opened on the screen), then type or paste into its message box and press
/// Return, checking each step. What it can't do, it hands back to the model, saying what to do on the screen.
@MainActor
enum Messaging {
    /// Chat apps, where Return sends what's typed.
    static let apps: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop", "com.hnc.Discord",
        "com.microsoft.teams2", "com.microsoft.teams",
    ]

    /// Chat apps by the names people use for them, and their bundle ids.
    static let chatApps: [(names: [String], display: String, ids: [String])] = [
        (["whatsapp"], "WhatsApp", ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        (["slack"], "Slack", ["com.tinyspeck.slackmacgap"]),
        (["telegram"], "Telegram", ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        (["signal"], "Signal", ["org.whispersystems.signal-desktop"]),
        (["discord"], "Discord", ["com.hnc.Discord"]),
        (["teams"], "Microsoft Teams", ["com.microsoft.teams2", "com.microsoft.teams"]),
    ]

    /// The chat app the user named, else the chat app in front (for "reply to this").
    static func chatApp(_ service: String) -> (display: String, ids: [String])? {
        let named = service.lowercased()
        if let found = chatApps.first(where: { app in app.names.contains { named.contains($0) } }) {
            return (found.display, found.ids)
        }
        guard let front = ScreenControl.workingApp(), let id = front.bundleIdentifier, apps.contains(id),
              id != "com.apple.MobileSMS" else { return nil }
        return chatApps.first { $0.ids.contains(id) }.map { ($0.display, $0.ids) } ?? (front.localizedName ?? service, [id])
    }

    /// Sends `text` and/or `file` to `to` in `app`. The caller has asked the user already. `chatOpened`: this command
    /// opened the chat with `to` on the screen (clicked something with their name).
    ///
    /// Every chat app goes the same way: open the chat (directly where Murmur can: WhatsApp from a number in
    /// Contacts, Slack's quick switcher; else the chat the model opened on the screen), then deliver into it: the
    /// cursor in the message box, the file pasted in, the text typed, Return only from a text box, and a check that
    /// the text left the box. Messages is the exception: AppleScript sends there and says whether it worked.
    static func send(_ text: String, to: String, in app: String, file: URL? = nil, chatOpened: Bool = false,
                     paste: (String) -> Void) async -> String {
        let service = app.lowercased()
        if service.isEmpty || ["messages", "imessage", "sms", "text", "message"].contains(service) {
            return await sendWithMessages(text, file: file, to: to)
        }
        guard let chat = chatApp(service) else {
            return "Murmur has no way to send in \(app). open_app it, open the chat on the screen, then send_message "
                + "again with the app named: it's sent into the chat you opened."
        }
        // Text on WhatsApp to a number in Contacts: its link opens the chat with the words already typed.
        if file == nil, chat.display == "WhatsApp", let sent = await whatsAppLink(text, to: to) { return sent }
        if let problem = await openChat(with: to, in: chat, chatOpened: chatOpened, paste: paste) { return problem }
        return await deliver(text, file: file, to: to, in: chat, paste: paste)
    }

    /// Text by WhatsApp's link (whatsapp://send with the number and the words), Return, and a check that it left the
    /// box. Nil when they have no number in Contacts.
    private static func whatsAppLink(_ text: String, to: String) async -> String? {
        guard let person = await contact(to), let phone = person.phone, let number = internationalNumber(phone) else {
            return nil
        }
        var parts = URLComponents()
        parts.scheme = "whatsapp"
        parts.host = "send"
        parts.queryItems = [URLQueryItem(name: "phone", value: number), URLQueryItem(name: "text", value: text)]
        guard let url = parts.url, NSWorkspace.shared.open(url) else { return nil }
        try? await Task.sleep(nanoseconds: 3_000_000_000)   // the chat opens with the message typed
        bringForward(chatApps[0].ids)
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = ScreenControl.press("return")
        try? await Task.sleep(nanoseconds: 800_000_000)
        // Still in the box: the Return didn't take (the chat wasn't focused yet). Once more.
        if stillTyped(text) {
            _ = ScreenControl.press("return")
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        if stillTyped(text) {
            return "The message is typed in the WhatsApp chat with \(person.name) but didn't send. press_keys return once "
                + "to send it (the user already said yes). Don't type it again."
        }
        return "Sent it on WhatsApp to \(person.name). Don't type or send it again."
    }

    /// Opens the chat with `person`, or finds it already open. Nil when it's open; else what the model should do.
    private static func openChat(with person: String, in chat: (display: String, ids: [String]), chatOpened: Bool,
                                 paste: (String) -> Void) async -> String? {
        if await chatIsOpen(with: person, in: chat.ids, openedHere: chatOpened) {
            bringForward(chat.ids)
            return nil
        }
        switch chat.display {
        case "WhatsApp":
            if let found = await contact(person), let phone = found.phone, let number = internationalNumber(phone),
               let url = URL(string: "whatsapp://send?phone=\(number)"), NSWorkspace.shared.open(url) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
        case "Slack":
            _ = await MacActions.openAppReturningApp("Slack")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            _ = ScreenControl.press("cmd+k")
            try? await Task.sleep(nanoseconds: 500_000_000)
            paste(person)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            _ = ScreenControl.press("return")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            return nil
        default:
            break
        }
        if await openChatByName(person, in: chat, paste: paste) { return nil }
        // The app is in front now, so whatever the model presses and types goes to it, not to where the user was.
        return "Couldn't find a chat named \(person) in \(chat.display) (it's in front now). read_screen, open the chat "
            + "with \(person) (click it in the list, or the app's search: press_keys \(searchKey(chat.display)), "
            + "type_text the name, click the result), then send_message again: it's sent into the chat you opened."
    }

    /// The key that puts the cursor in a chat app's search.
    private static func searchKey(_ display: String) -> String {
        switch display {
        case "Discord": return "cmd+k"
        case "Microsoft Teams": return "cmd+e"
        default: return "cmd+f"
        }
    }

    /// Opens the chat with `person` the way you would: the app in front, their chat clicked in the list, else found
    /// with the app's search and clicked. Only a chat named after them counts (the name, or the name then more:
    /// "Roma, 2 unread messages"), never a message that mentions them; and it must show their name once open.
    private static func openChatByName(_ person: String, in chat: (display: String, ids: [String]),
                                       paste: (String) -> Void) async -> Bool {
        let name = person.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, await MacActions.openAppReturningApp(chat.display).1 != nil else { return false }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        bringForward(chat.ids)
        try? await Task.sleep(nanoseconds: 300_000_000)
        // Their chat is the open one already: its name heads it. Clicking the name there opens their contact
        // details over the message box, so nothing is clicked.
        if await ScreenControl.hasHeading(name) { return true }
        if let clicked = await ScreenControl.click(labeled: name, atLeast: 3), clicked.hasPrefix("Clicked"),
           await chatIsOpen(with: name, in: chat.ids, openedHere: true) {
            return true
        }
        _ = ScreenControl.press(searchKey(chat.display))
        try? await Task.sleep(nanoseconds: 500_000_000)
        paste(name)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let clicked = await ScreenControl.click(labeled: name, atLeast: 3), clicked.hasPrefix("Clicked") else {
            _ = ScreenControl.press("escape")
            return false
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        return await chatIsOpen(with: name, in: chat.ids, openedHere: true)
    }

    /// The chat app is in front (or was, behind Murmur) with the conversation with `person` open: its window is
    /// named after them, or this command opened their chat and their name is on the screen. Their name merely in the
    /// chat list isn't enough when the command didn't open it: another chat could be the open one.
    private static func chatIsOpen(with person: String, in bundleIDs: [String], openedHere: Bool) async -> Bool {
        guard let app = ScreenControl.workingApp(), let id = app.bundleIdentifier, bundleIDs.contains(id) else {
            return false
        }
        let name = person.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        if let title = ScreenControl.frontWindowTitle(), title.localizedCaseInsensitiveContains(name) { return true }
        guard openedHere else { return false }
        return await ScreenControl.read().localizedCaseInsensitiveContains(name)
    }

    /// Into the open chat: the cursor in the message box (after clicking a chat it's on the chat's name, where a
    /// paste does nothing and Return opens the contact), the file pasted (the app shows it ready to send, with a
    /// caption box), the text typed, Return only from a text box, then a check that the text left the box.
    private static func deliver(_ text: String, file: URL?, to person: String, in chat: (display: String, ids: [String]),
                                paste: (String) -> Void) async -> String {
        bringForward(chat.ids)
        try? await Task.sleep(nanoseconds: 800_000_000)
        var composer = await ScreenControl.focusComposer()
        if !composer {
            // A panel over the chat (contact details, a search, a menu): Escape closes it, then look again.
            _ = ScreenControl.press("escape")
            try? await Task.sleep(nanoseconds: 600_000_000)
            composer = await ScreenControl.focusComposer()
        }
        guard composer else {
            return "Couldn't find the message box in the \(chat.display) chat with \(person). read_screen, click the "
                + "message box, then send_message again."
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let file {
            let board = NSPasteboard.general
            board.clearContents()
            board.writeObjects([file as NSURL])
            _ = ScreenControl.press("cmd+v")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard ScreenControl.focusIsEditable() else {
                return "Pasted \(file.lastPathComponent) into the chat with \(person), but its send screen didn't take "
                    + "the keyboard, so nothing was sent. read_screen to see where it is; press_keys return only if it's "
                    + "ready to send to \(person)."
            }
        }
        if !text.isEmpty {
            paste(text)
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard ScreenControl.focusIsEditable() else {
                return "The message didn't go into a text box in \(chat.display), so nothing was sent. read_screen, "
                    + "click the message box in the chat with \(person), then send_message again."
            }
        }
        _ = ScreenControl.press("return")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if !text.isEmpty, stillTyped(text) {
            _ = ScreenControl.press("return")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if stillTyped(text) {
                return "The message is typed in the \(chat.display) chat with \(person) but didn't send. press_keys "
                    + "return once to send it (the user already said yes). Don't type it again."
            }
        }
        let what = [file?.lastPathComponent, text.isEmpty ? nil : "the message"].compactMap { $0 }
            .joined(separator: " and ")
        return "Sent \(what) to \(person) in \(chat.display). read_screen to check it's the last message there (the "
            + "user already said yes; don't send it again)."
    }

    /// Messages, by AppleScript: the file, then the text, to their number or email from Contacts.
    private static func sendWithMessages(_ text: String, file: URL?, to: String) async -> String {
        guard let person = await contact(to),
              let handle = person.phone.flatMap(internationalNumber).map({ "+" + $0 }) ?? person.email else {
            if file != nil {
                return "\(to) isn't in Contacts with a number or email, so Murmur can't send \(file!.lastPathComponent) "
                    + "with Messages."
            }
            return "\(to) isn't in Contacts with a number or email. Finish on the screen: open_app Messages, press_keys "
                + "cmd+n, type_text the name, pick them, type_text the message, then press_keys return (already approved)."
        }
        await Permissions.automation("com.apple.MobileSMS")
        var lines = ["tell application \"Messages\"",
                     "    set targetService to 1st account whose service type = iMessage",
                     "    set theBuddy to participant \"\(quoted(handle))\" of targetService"]
        if let file { lines.append("    send (POSIX file \"\(quoted(file.path))\") to theBuddy") }
        if !text.isEmpty { lines.append("    send \"\(quoted(text))\" to theBuddy") }
        lines.append("end tell")
        let output = await MacActions.run("/usr/bin/osascript", ["-e", lines.joined(separator: "\n")], timeout: 30)
        if output.contains("error") {
            return "Messages couldn't send it to \(person.name) (\(output.prefix(160))). Finish on the screen: open_app "
                + "Messages, press_keys cmd+n, type_text the name, then the message, then press_keys return."
        }
        let what = [file?.lastPathComponent, text.isEmpty ? nil : "the message"].compactMap { $0 }
            .joined(separator: " and ")
        return "Sent \(what) to \(person.name) with Messages."
    }

    /// The person's full name, phone and email from Contacts. A partial name is usable only when it identifies one
    /// contact; choosing the first of several “Alex” contacts could send a message to the wrong person.
    static func contact(_ name: String) async -> (name: String, phone: String?, email: String?)? {
        await Permissions.automation("com.apple.AddressBook")
        let script = """
        tell application "Contacts"
            set exactFound to (every person whose name is "\(quoted(name))")
            if (count of exactFound) = 1 then
                set p to item 1 of exactFound
            else
                set partialFound to (every person whose name contains "\(quoted(name))")
                if (count of partialFound) is not 1 then return ""
                set p to item 1 of partialFound
            end if
            set ph to ""
            set em to ""
            if (count of phones of p) > 0 then set ph to value of first phone of p
            if (count of emails of p) > 0 then set em to value of first email of p
            return (name of p) & "|" & ph & "|" & em
        end tell
        """
        let output = await MacActions.run("/usr/bin/osascript", ["-e", script], timeout: 20)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !output.contains("execution error") else { return nil }
        return (parts[0], parts[1].isEmpty ? nil : parts[1], parts[2].isEmpty ? nil : parts[2])
    }

    /// A phone number as WhatsApp wants it: country code and digits, no plus. A local ten-digit number gets this
    /// Mac's country code.
    static func internationalNumber(_ phone: String) -> String? {
        var digits = phone.filter(\.isNumber)
        if phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return digits.count >= 8 ? digits : nil }
        if digits.hasPrefix("00") { digits.removeFirst(2); return digits.count >= 8 ? digits : nil }
        if digits.hasPrefix("0") { digits.removeFirst() }
        let codes = ["IN": "91", "US": "1", "CA": "1", "GB": "44", "AU": "61", "AE": "971", "SG": "65", "DE": "49",
                     "FR": "33", "NL": "31", "IE": "353", "NZ": "64"]
        if digits.count == 10, let code = codes[Locale.current.region?.identifier ?? ""] { return code + digits }
        return digits.count >= 8 ? digits : nil
    }

    /// Whether the message is still in the focused text box (so it wasn't sent).
    static func stillTyped(_ text: String) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value) == .success,
              let typed = value as? String else { return false }
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !wanted.isEmpty && typed.trimmingCharacters(in: .whitespacesAndNewlines).contains(wanted)
    }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func bringForward(_ bundleIDs: [String]) {
        for id in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { app.activate(); return }
        }
    }
}
