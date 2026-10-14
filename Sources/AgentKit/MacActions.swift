import AppKit
import Carbon.HIToolbox

/// The things Murmur can do on this Mac. Each returns a short result the router (or you) can read.
@MainActor
public enum MacActions {
    // MARK: Apps

    public static func openApp(_ spoken: String) async -> String {
        await openAppReturningApp(spoken).0
    }

    /// Opens an app and returns it too (so a following web search can use it when it's a browser).
    static func openAppReturningApp(_ spoken: String) async -> (String, AppCatalog.App?) {
        guard let app = AppCatalog.shared.resolve(spoken) else {
            return ("No app called \"\(spoken)\" is installed.", nil)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
            return ("Opened \(app.name).", app)
        } catch {
            return ("Couldn't open \(app.name): \(error.localizedDescription)", nil)
        }
    }

    /// Opens the app, waits until it's in front, and starts a new document (⌘N) when asked, so what's pasted next
    /// lands in it. Returns what happened and whether it's ready for typing.
    static func prepareToWrite(in spoken: String, newDocument: Bool) async -> (String, Bool) {
        let (result, app) = await openAppReturningApp(spoken)
        guard let app else { return (result, false) }
        for _ in 0..<50 {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier == app.bundleID || front?.localizedName == app.name { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)   // its window comes up
        if newDocument {
            postKey(CGKeyCode(kVK_ANSI_N), flags: .maskCommand)
            try? await Task.sleep(nanoseconds: 700_000_000)   // the new note or document takes the cursor
        }
        return (result, true)
    }

    static let browserIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "ai.perplexity.comet", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    static func isBrowser(_ app: AppCatalog.App?) -> Bool {
        guard let id = app?.bundleID else { return false }
        return browserIDs.contains(id)
    }

    /// The running app matching a spoken name (running apps first, then installed ones by bundle id).
    static func running(_ spoken: String) -> NSRunningApplication? {
        let key = AppCatalog.key(spoken)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let hit = apps.max(by: { score(key, $0) < score(key, $1) }), score(key, hit) > 0 { return hit }
        if let installed = AppCatalog.shared.resolve(spoken), let id = installed.bundleID {
            return apps.first { $0.bundleIdentifier == id }
        }
        return nil
    }

    private static func score(_ key: String, _ app: NSRunningApplication) -> Int {
        AppCatalog.score(key, AppCatalog.key(app.localizedName ?? ""))
    }

    public static func quitApp(_ spoken: String) -> String {
        guard let app = running(spoken) else { return "\"\(spoken)\" isn't running." }
        let name = app.localizedName ?? spoken
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return "Murmur won't quit itself from a command." }
        // A normal quit: the app asks about unsaved work, as with ⌘Q.
        return app.terminate() ? "Asked \(name) to quit." : "\(name) didn't accept the quit request."
    }

    public static func hideApp(_ spoken: String) -> String {
        guard let app = running(spoken) else { return "\"\(spoken)\" isn't running." }
        app.hide()
        return "Hid \(app.localizedName ?? spoken)."
    }

    public static func findApps(_ spoken: String) -> String {
        let hits = AppCatalog.shared.matches(spoken, limit: 6)
        return hits.isEmpty ? "No installed app matches \"\(spoken)\"."
            : "Installed apps matching \"\(spoken)\": " + hits.map(\.name).joined(separator: ", ")
    }

    public static func runningApps() -> String {
        let names = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        return "Running: " + names.joined(separator: ", ")
    }

    // MARK: Files and folders

    public static func openFolder(_ spoken: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders: [String: URL] = [
            "downloads": home.appendingPathComponent("Downloads"),
            "documents": home.appendingPathComponent("Documents"),
            "desktop": home.appendingPathComponent("Desktop"),
            "pictures": home.appendingPathComponent("Pictures"),
            "music": home.appendingPathComponent("Music"),
            "movies": home.appendingPathComponent("Movies"),
            "home": home,
            "applications": URL(fileURLWithPath: "/Applications"),
        ]
        let key = AppCatalog.key(spoken).replacingOccurrences(of: "folder", with: "")
        guard let url = folders.first(where: { key.contains($0.key) })?.value else {
            return "I only know the standard folders (Downloads, Documents, Desktop, Pictures, Music, Movies, home)."
        }
        NSWorkspace.shared.open(url)
        return "Opened \(url.lastPathComponent)."
    }

    // MARK: System Settings

    /// System Settings panes by what you'd call them (macOS 13+ pane IDs).
    static let settingsPanes: [String: String] = [
        "software update": "com.apple.Software-Update-Settings.extension",
        "update": "com.apple.Software-Update-Settings.extension",
        "updates": "com.apple.Software-Update-Settings.extension",
        "wifi": "com.apple.wifi-settings-extension", "wi-fi": "com.apple.wifi-settings-extension",
        "bluetooth": "com.apple.BluetoothSettings", "network": "com.apple.Network-Settings.extension",
        "display": "com.apple.Displays-Settings.extension", "displays": "com.apple.Displays-Settings.extension",
        "sound": "com.apple.Sound-Settings.extension", "battery": "com.apple.Battery-Settings.extension",
        "notifications": "com.apple.Notifications-Settings.extension", "focus": "com.apple.Focus-Settings.extension",
        "privacy": "com.apple.settings.PrivacySecurity.extension",
        "privacy and security": "com.apple.settings.PrivacySecurity.extension",
        "security": "com.apple.settings.PrivacySecurity.extension",
        "accessibility": "com.apple.Accessibility-Settings.extension",
        "keyboard": "com.apple.Keyboard-Settings.extension", "trackpad": "com.apple.Trackpad-Settings.extension",
        "mouse": "com.apple.Mouse-Settings.extension", "general": "com.apple.systempreferences.GeneralSettings",
        "storage": "com.apple.settings.Storage", "appearance": "com.apple.Appearance-Settings.extension",
        "dark mode": "com.apple.Appearance-Settings.extension",
        "desktop": "com.apple.Desktop-Settings.extension", "dock": "com.apple.Desktop-Settings.extension",
        "desktop and dock": "com.apple.Desktop-Settings.extension",
        "wallpaper": "com.apple.Wallpaper-Settings.extension",
        "users": "com.apple.Users-Groups-Settings.extension", "passwords": "com.apple.Passwords-Settings.extension",
        "time machine": "com.apple.Time-Machine-Settings.extension", "backup": "com.apple.Time-Machine-Settings.extension",
        "date and time": "com.apple.Date-Time-Settings.extension", "time": "com.apple.Date-Time-Settings.extension",
        "login items": "com.apple.LoginItems-Settings.extension", "screen time": "com.apple.Screen-Time-Settings.extension",
        "lock screen": "com.apple.Lock-Screen-Settings.extension", "touch id": "com.apple.Touch-ID-Settings.extension",
        "control center": "com.apple.ControlCenter-Settings.extension", "siri": "com.apple.Siri-Settings.extension",
        "night shift": "com.apple.Displays-Settings.extension", "microphone": "com.apple.settings.PrivacySecurity.extension",
    ]

    /// Opens a System Settings pane ("software update", "wifi", "battery"…), or the App Store's updates.
    public static func openSettings(_ spoken: String) -> String {
        let key = spoken.lowercased()
            .replacingOccurrences(of: #"\b(settings?|preferences|pane|page|the|my)\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: "and")
            .split(separator: " ").joined(separator: " ")
        if key.contains("app store") || key == "app updates" || key == "apps" {
            NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
            return "Opened the App Store's updates."
        }
        let pane = settingsPanes[key] ?? settingsPanes.first { key.contains($0.key) }?.value
        let url = URL(string: pane.map { "x-apple.systempreferences:\($0)" } ?? "x-apple.systempreferences:")!
        NSWorkspace.shared.open(url)
        if pane == "com.apple.Software-Update-Settings.extension" {
            return "Opened Software Update. It checks for updates as it opens."
        }
        return pane == nil ? "Opened System Settings." : "Opened \(spoken.capitalized) settings."
    }

    // MARK: Web

    public static func openURL(_ text: String) -> String {
        openURL(text, in: nil)
    }

    static func openURL(_ text: String, in browser: AppCatalog.App?) -> String {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw.replacingOccurrences(of: " dot ", with: ".") }
        guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            return "That doesn't look like a web address."
        }
        open(url, in: browser)
        return "Opened \(url.host ?? raw)."
    }

    /// Search pages that take the query in their address, so a search on a site is one step, not typing into it.
    static let siteSearches: [String: String] = [
        "youtube": "https://www.youtube.com/results?search_query=",
        "google": "https://www.google.com/search?q=",
        "google images": "https://www.google.com/search?tbm=isch&q=", "images": "https://www.google.com/search?tbm=isch&q=",
        "google maps": "https://www.google.com/maps/search/", "maps": "https://www.google.com/maps/search/",
        "amazon": "https://www.amazon.in/s?k=", "flipkart": "https://www.flipkart.com/search?q=",
        "github": "https://github.com/search?q=", "wikipedia": "https://en.wikipedia.org/w/index.php?search=",
        "reddit": "https://www.reddit.com/search/?q=", "twitter": "https://x.com/search?q=", "x": "https://x.com/search?q=",
        "linkedin": "https://www.linkedin.com/search/results/all/?keywords=",
        "stack overflow": "https://stackoverflow.com/search?q=", "stackoverflow": "https://stackoverflow.com/search?q=",
        "spotify": "https://open.spotify.com/search/", "netflix": "https://www.netflix.com/search?q=",
        "chatgpt": "https://chatgpt.com/?q=", "perplexity": "https://www.perplexity.ai/search?q=",
    ]

    static func siteSearch(_ site: String, _ query: String, in browser: AppCatalog.App?) -> String {
        let key = site.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\.(com|in|org)$"#, with: "", options: .regularExpression)
        guard let base = siteSearches[key] else { return webSearch("\(query) site:\(site)", in: browser) }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "+", "=", "?", "/"])) ?? query
        guard let url = URL(string: base + encoded) else { return "Couldn't build the search." }
        open(url, in: browser)
        return "Searching \(site) for \"\(query)\"\(browser.map { " in \($0.name)" } ?? "")."
    }

    public static func webSearch(_ query: String) -> String {
        webSearch(query, in: nil)
    }

    static func webSearch(_ query: String, in browser: AppCatalog.App?) -> String {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return "Couldn't build the search." }
        open(url, in: browser)
        return "Searching the web for \"\(query)\"\(browser.map { " in \($0.name)" } ?? "")."
    }

    /// Opens a web address in the given browser, or the default one.
    private static func open(_ url: URL, in browser: AppCatalog.App?) {
        if let browser, isBrowser(browser) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: browser.url, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: System

    public static func setVolume(_ percent: Int) -> String {
        let value = max(0, min(100, percent))
        _ = appleScript("set volume output volume \(value) without output muted")
        return "Volume \(value)%."
    }

    public static func changeVolume(by delta: Int) -> String {
        let current = Int(appleScript("output volume of (get volume settings)") ?? "") ?? 50
        return setVolume(current + delta)
    }

    public static func mute(_ on: Bool) -> String {
        _ = appleScript("set volume output muted \(on)")
        return on ? "Muted." : "Unmuted."
    }

    public static func brightness(up: Bool, steps: Int = 2) -> String {
        for _ in 0..<max(1, steps) { postMediaKey(up ? 2 : 3) }   // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        return up ? "Brighter." : "Dimmer."
    }

    public static func lockScreen() -> String {
        postKey(CGKeyCode(kVK_ANSI_Q), flags: [.maskCommand, .maskControl])
        return "Locked the screen."
    }

    public static func screenshot() -> String {
        postKey(CGKeyCode(kVK_ANSI_5), flags: [.maskCommand, .maskShift])
        return "Opened the screenshot toolbar."
    }

    // MARK: Shortcuts

    public static func listShortcuts() async -> String {
        let output = await run("/usr/bin/shortcuts", ["list"], timeout: 15)
        let names = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return names.isEmpty ? "No Shortcuts found." : "Your Shortcuts: " + names.joined(separator: ", ")
    }

    public static func runShortcut(_ name: String, input: String?) async -> String {
        var arguments = ["run", name]
        var inputFile: URL?
        if let input, !input.isEmpty {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-shortcut-input.txt")
            try? input.write(to: file, atomically: true, encoding: .utf8)
            arguments += ["--input-path", file.path]
            inputFile = file
        }
        let output = await run("/usr/bin/shortcuts", arguments, timeout: 120)
        if let inputFile { try? FileManager.default.removeItem(at: inputFile) }
        return output.isEmpty ? "Ran the shortcut \"\(name)\"." : "Shortcut \"\(name)\" said: \(output.prefix(500))"
    }

    // MARK: Bluetooth and Wi-Fi

    /// Bluetooth on or off, the way System Settings and `blueutil` do it (IOBluetooth's power preference). macOS
    /// asks once for Bluetooth permission.
    public static func setBluetooth(_ on: Bool) async -> String {
        typealias GetPower = @convention(c) () -> Int32
        typealias SetPower = @convention(c) (Int32) -> Void
        guard let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
              let getSymbol = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
              let setSymbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else {
            return "Couldn't reach Bluetooth from here. Use open_settings bluetooth, then read_screen and click."
        }
        let power = unsafeBitCast(getSymbol, to: GetPower.self)
        let setPower = unsafeBitCast(setSymbol, to: SetPower.self)
        let word = on ? "on" : "off"
        if (power() != 0) == on { return "Bluetooth is already \(word)." }
        setPower(on ? 1 : 0)
        for _ in 0..<20 {            // it takes a moment to switch
            try? await Task.sleep(nanoseconds: 150_000_000)
            if (power() != 0) == on { return "Turned Bluetooth \(word)." }
        }
        return "Bluetooth didn't switch \(word). Murmur may need Bluetooth permission (System Settings → Privacy & "
            + "Security → Bluetooth)."
    }

    /// Wi-Fi on or off (`networksetup`, no password needed).
    public static func setWiFi(_ on: Bool) async -> String {
        let ports = await run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 10)
        // "Hardware Port: Wi-Fi\nDevice: en0"
        var device: String?
        let lines = ports.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            if index + 1 < lines.count, lines[index + 1].hasPrefix("Device: ") {
                device = String(lines[index + 1].dropFirst("Device: ".count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let device else { return "This Mac has no Wi-Fi." }
        let output = await run("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"], timeout: 15)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Turned Wi-Fi \(on ? "on" : "off")." : "Wi-Fi: \(trimmed.prefix(200))"
    }

    // MARK: Helpers

    @discardableResult
    static func appleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Brightness, volume and media keys are "system-defined" events, not key codes.
    static func postMediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Runs a program and returns what it printed (stdout, else stderr), trimmed.
    nonisolated static func run(_ path: String, _ arguments: [String], timeout: TimeInterval,
                                environment: [String: String]? = nil,
                                directory: URL? = nil) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                if let environment { process.environment = environment }
                if let directory { process.currentDirectoryURL = directory }
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: "Couldn't start \(path): \(error.localizedDescription)")
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // Drain both pipes at once (Codex writes a lot to stderr): a full pipe would block the process.
                var stderr = Data()
                let drained = DispatchGroup()
                drained.enter()
                DispatchQueue.global().async {
                    stderr = err.fileHandleForReading.readDataToEndOfFile()
                    drained.leave()
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                drained.wait()
                process.waitUntilExit()
                timer.cancel()
                let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? fallback : text)
            }
        }
    }
}
