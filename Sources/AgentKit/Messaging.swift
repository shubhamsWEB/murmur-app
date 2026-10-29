import AppKit

/// Sending a message for you in WhatsApp, Messages or Slack, always after you've said yes to the exact words.
/// WhatsApp and Messages go to the person's number from Contacts; Slack through its quick switcher. Anything it
/// can't do directly, it hands back to the model to finish on the screen.
@MainActor
enum Messaging {
    /// Chat apps, where Return sends what's typed.
    static let apps: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop", "com.hnc.Discord",
        "com.microsoft.teams2", "com.microsoft.teams",
    ]

    /// Sends `text` to `to` in `app`. The caller has asked the user already.
    static func send(_ text: String, to: String, in app: String, paste: (String) -> Void) async -> String {
        let service = app.lowercased()
        if service.contains("whatsapp") {
            if let person = await contact(to), let phone = person.phone, let number = internationalNumber(phone) {
                var parts = URLComponents()
                parts.scheme = "whatsapp"
                parts.host = "send"
                parts.queryItems = [URLQueryItem(name: "phone", value: number), URLQueryItem(name: "text", value: text)]
                if let url = parts.url, NSWorkspace.shared.open(url) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)   // the chat opens with the message typed
                    bringForward(["net.whatsapp.WhatsApp", "desktop.WhatsApp"])
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    _ = ScreenControl.press("return")
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    // Still in the box: the Return didn't take (the chat wasn't focused yet). Once more.
                    if stillTyped(text) {
                        _ = ScreenControl.press("return")
                        try? await Task.sleep(nanoseconds: 800_000_000)
                    }
                    if stillTyped(text) {
                        return "The message is typed in the WhatsApp chat with \(person.name) but didn't send. press_keys "
                            + "return once to send it (the user already said yes). Don't type it again."
                    }
                    return "Sent it on WhatsApp to \(person.name). Don't type or send it again."
                }
            }
            _ = await MacActions.openAppReturningApp("WhatsApp")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = ScreenControl.press("cmd+f")
            try? await Task.sleep(nanoseconds: 500_000_000)
            paste(to)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return "\(to) has no phone number in Contacts, so WhatsApp's chat search now has \"\(to)\" in it. Finish on the "
                + "screen: read_screen, click the right chat, type_text the message, then press_keys return (the user "
                + "already said yes to sending it)."
        }
        if service.contains("slack") {
            _ = await MacActions.openAppReturningApp("Slack")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            _ = ScreenControl.press("cmd+k")
            try? await Task.sleep(nanoseconds: 500_000_000)
            paste(to)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            _ = ScreenControl.press("return")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            paste(text)
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = ScreenControl.press("return")
            return "Sent it in Slack to \(to) through the quick switcher. read_screen to check it went to the right place."
        }
        if service.isEmpty || ["messages", "imessage", "sms", "text", "message"].contains(service) {
            if let person = await contact(to), let handle = person.phone.flatMap(internationalNumber).map({ "+" + $0 }) ?? person.email {
                await Permissions.automation("com.apple.MobileSMS")
                let script = """
                tell application "Messages"
                    set targetService to 1st account whose service type = iMessage
                    send "\(quoted(text))" to participant "\(quoted(handle))" of targetService
                end tell
                """
                let output = await MacActions.run("/usr/bin/osascript", ["-e", script], timeout: 20)
                if !output.contains("error") { return "Sent it with Messages to \(person.name)." }
                return "Messages couldn't send it to \(person.name) (\(output.prefix(160))). Finish on the screen: open_app "
                    + "Messages, press_keys cmd+n, type_text the name, then the message, then press_keys return."
            }
            return "\(to) isn't in Contacts with a number or email. Finish on the screen: open_app Messages, press_keys cmd+n, "
                + "type_text the name, pick them, type_text the message, then press_keys return (already approved)."
        }
        return "Murmur has no direct way to send in \(app): open_app \(app), find the chat (its search box, read_screen, "
            + "click), type_text the message, then press_keys return (the user already said yes to sending it)."
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
