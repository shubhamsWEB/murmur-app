import AppKit
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppController?
    /// A notification clicked before Murmur had finished starting (the click launched it): opened once it has.
    private var openedNotification: String?

    static func main() {
        signal(SIGPIPE, SIG_IGN)   // a helper that just exited must surface as a write error, not kill the app
        // MURMUR_WORKER_DIR runs another worker (the Python reference, for evals) in place of the bundled model. Only
        // dev runs take it: anywhere else it would have Murmur, and its helpers, start whatever that folder holds.
        if UserDefaults.standard.string(forKey: "defaultsSuite") == nil { unsetenv("MURMUR_WORKER_DIR") }
        // An exception AppKit catches and carries on from leaves Swift's concurrency state broken, and Murmur crashes
        // later somewhere unrelated. Crash at the exception instead, so the report shows what threw.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Before launch finishes, so a click on a notification that launched Murmur still reaches it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var replaced: String?
        if let other = otherRunningCopy() {
            // Started by a click on a notification while another copy runs (two copies share Murmur's ID, and macOS
            // opens the installed one for the click): the running copy has the click already. Bring it forward and
            // step aside, rather than closing the window it just opened. On 11 Nov the installed copy replaced the
            // running one this way, which looked like a crash.
            if notification.userInfo?[NSApplication.launchUserNotificationUserInfoKey] != nil {
                other.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }
            // Another Murmur is running (an older install, or the dev build): the one you just opened takes over, so
            // you always get the copy you chose, and only one listens to the fn key.
            replaced = other.bundleURL.map { tildePath($0.path) } ?? "?"
            other.terminate()
            let deadline = Date().addingTimeInterval(4)
            while !other.isTerminated, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if !other.isTerminated { other.forceTerminate() }
        }
        // For testing both themes: `-forceAppearance dark` (or light).
        switch UserDefaults.standard.string(forKey: "forceAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }

        let settings = AppSettings.load()
        AppLog.shared.open(in: settings.indexDirectory)
        log("launch pid \(getpid()) from \(tildePath(Bundle.main.bundlePath)): roots \(settings.roots.map { tildePath($0.path) }) · "
            + "index \(tildePath(settings.indexDirectory.path)) · models \(tildePath(settings.modelsDirectory.path))")
        // Only now is the log open: said here, so it's in it.
        if let replaced { log("launch: replaced the Murmur that was running (\(replaced))") }
        let (atLogin, why) = Launch.atLogin()   // while the open-application event is still the current one
        let showWindow = !atLogin && !DebugHooks.drivesUI
        log("launch: \(atLogin ? "at login" : "opened by hand") (\(why))\(showWindow ? ", showing the window" : "")")
        // Opened from the disk image or Downloads: offer to move to Applications, then open from there. After the log
        // is open, so what it decided is in it.
        if MoveToApplications.offerIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        let app = AppController(settings: settings)
        self.app = app
        NSApp.mainMenu = Self.makeMainMenu(app)
        app.start(showWindow: showWindow)
        DebugHooks.run(app)
        if let key = openedNotification {
            openedNotification = nil
            opened(notification: key)
        }
    }

    /// A notification clicked: the brief, the wrap-up and reminders open "Your day", the whole of what they sum up.
    fileprivate func opened(notification key: String) {
        guard let app else { openedNotification = key; return }
        let day = ["brief:", "wrap:", "due:", "eve:"].contains { key.hasPrefix($0) }
        log("notification: opened \(key.split(separator: ":").first.map(String.init) ?? "?")\(day ? ", showing your day" : "")")
        app.showHome(day ? .day : nil)
    }

    /// Opening the app again (from Finder or Spotlight) while it runs: show its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app?.showHome() }
        return true
    }

    /// Another copy is running (a second copy of the app, launched from elsewhere). Dev and test runs, which keep their
    /// own settings, index and models (`-defaultsSuite`), run alongside an installed Murmur that's in use.
    private func otherRunningCopy() -> NSRunningApplication? {
        guard UserDefaults.standard.string(forKey: "defaultsSuite") == nil,
              let id = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0 != NSRunningApplication.current }
    }

    /// The menu bar while a window is open (the Dock icon shows then). It also gives text fields ⌘C/⌘V/⌘A/⌘Z.
    private static func makeMainMenu(_ app: AppController) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Murmur", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        if Updates.hasFeed {
            appMenu.addItem(ActionMenuItem("Check for Updates…") { [weak app] in app?.updates.checkNow() })
        }
        appMenu.addItem(.separator())
        appMenu.addItem(ActionMenuItem("Settings…", key: ",") { [weak app] in app?.showHome(.dictation) })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Murmur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(ActionMenuItem("New Search", key: "n") { [weak app] in app?.showSearchWindow(query: "") })
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        for submenu in [appMenu, fileMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}

/// How Murmur was launched. At login (its login item) it stays in the menu bar; opened by hand (Finder, Spotlight,
/// Launchpad, after an update) it shows its window, so opening it never looks like nothing happened.
enum Launch {
    /// Whether this is the launch at login, and what says so. Call it while the app finishes launching: the
    /// open-application event is still the current one then.
    static func atLogin() -> (Bool, String) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == AEEventID(kAEOpenApplication),
           event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem) {
            return (true, "the login item")
        }
        // In case macOS doesn't mark the login item's launch: within two minutes of logging in counts as at login.
        guard let login = consoleLogin() else { return (false, "no login time") }
        let since = Date().timeIntervalSince(login)
        return (since < 120, "logged in \(Int(since)) s ago")
    }

    /// When this user logged in at the Mac (what `who` shows for the console).
    private static func consoleLogin() -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let entry = getutxent()?.pointee {
            guard Int32(entry.ut_type) == USER_PROCESS, text(entry.ut_line) == "console",
                  text(entry.ut_user) == NSUserName() else { continue }
            let time = Date(timeIntervalSince1970: TimeInterval(entry.ut_tv.tv_sec))
            if latest.map({ time > $0 }) ?? true { latest = time }
        }
        return latest
    }

    /// A fixed-size C string field of a utmpx entry.
    private static func text<Field>(_ field: Field) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Brings Murmur to the front. Plain `NSApp.activate()` is only a request that macOS may decline while another
/// app is in use; the panel needs real activation so App Nap doesn't slow search down.
func bringAppToFront() {
    (NSApp as any ForcedActivation).activate(ignoringOtherApps: true)
}

/// Calls the older activation API without a deprecation warning.
private protocol ForcedActivation {
    func activate(ignoringOtherApps: Bool)
}

extension NSApplication: ForcedActivation {}


extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.identifier
        await MainActor.run { self.opened(notification: key) }
    }

    /// Shown even while Murmur's window is in front (it would be held back otherwise).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
