import AppKit

/// Opened from the disk image (or from Downloads), Murmur offers to move itself to Applications, opens the copy there,
/// and ejects the disk image: no dragging onto the Applications shortcut. Run from the disk image it can't update
/// itself (the disk is read-only) and starts afresh from wherever it's opened next; from Downloads, macOS runs it from
/// a hidden read-only copy, and updates fail the same way.
///
/// Dev builds, run from build.noindex, never ask; any other copy does (a disk image made locally too, for trying
/// it). "Don't ask again" is kept.
enum MoveToApplications {
    private static let declinedKey = "moveToApplicationsDeclined"

    /// Asks, and moves when you say yes. True when Murmur is quitting for the copy in Applications to open.
    @MainActor static func offerIfNeeded() -> Bool {
        guard UserDefaults.standard.string(forKey: "defaultsSuite") == nil,
              !UserDefaults.standard.bool(forKey: declinedKey) else { return false }
        let running = Bundle.main.bundleURL
        let source = originalURL(of: running)
        guard !isInApplications(source), !source.path.contains("/build.noindex/"),
              !source.path.contains("/.build/") else { return false }
        let fromDiskImage = source.path.hasPrefix("/Volumes/")
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        log("move: running from \(source.path)\(source == running ? "" : " (macOS runs a hidden copy)")")

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Murmur to your Applications folder?"
        alert.informativeText = fromDiskImage
            ? "Murmur is running from its disk image. In Applications it can update itself and start when you log in. "
                + "Murmur will open again from there and eject the disk image."
            : "Murmur works best from Applications, where it can update itself and start when you log in. Murmur will "
                + "open again from there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on, answer != .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: declinedKey)
        }
        guard answer == .alertFirstButtonReturn else {
            log("move: not now")
            return false
        }

        switch move(source, to: destination) {
        case .success:
            log("move: copied to \(destination.path)")
            // From Downloads: the original goes to the Trash. A disk image is read-only; it's ejected instead.
            if !fromDiskImage { try? FileManager.default.trashItem(at: source, resultingItemURL: nil) }
            let volume = fromDiskImage ? volumeRoot(of: source) : nil
            relaunch(destination, eject: volume)
            return true
        case .failure(let problem):
            log("move: failed: \(problem)")
            let failed = NSAlert()
            failed.messageText = "Murmur couldn't be moved to Applications"
            failed.informativeText = "\(problem)\n\nYou can drag Murmur onto the Applications folder yourself."
            failed.runModal()
            return false
        }
    }

    // MARK: Moving

    private struct Problem: Error, CustomStringConvertible { let description: String }

    /// Replaces any Murmur already in Applications with this one: as you, else with an administrator's password
    /// (macOS asks). The copy's quarantine flag is removed: you opened this Murmur already, and a quarantined app
    /// that Finder didn't move is run from a hidden read-only copy, where it can't update itself.
    private static func move(_ source: URL, to destination: URL) -> Result<Void, Problem> {
        let fileManager = FileManager.default
        var asYou = true
        if fileManager.fileExists(atPath: destination.path) {
            asYou = (try? fileManager.trashItem(at: destination, resultingItemURL: nil)) != nil
        }
        if asYou, run("/usr/bin/ditto", [source.path, destination.path]) {
            _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
            return .success(())
        }
        // Not allowed as you (Applications belongs to an administrator): ask macOS for one.
        let command = "/bin/rm -rf \(quoted(destination.path)) && /usr/bin/ditto \(quoted(source.path)) "
            + "\(quoted(destination.path)) && /usr/bin/xattr -dr com.apple.quarantine \(quoted(destination.path))"
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let cancelled = (error[NSAppleScript.errorNumber] as? Int) == -128
            return .failure(Problem(description: cancelled ? "You cancelled the password prompt."
                                    : (error[NSAppleScript.errorMessage] as? String ?? "macOS didn't allow it.")))
        }
        return fileManager.fileExists(atPath: destination.path) ? .success(())
            : .failure(Problem(description: "The copy didn't arrive in Applications."))
    }

    /// Opens the copy in Applications once this Murmur has quit, then ejects the disk image it came from.
    private static func relaunch(_ app: URL, eject volume: URL?) {
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"; "
            + "if [ -n \"$3\" ]; then /bin/sleep 1; /usr/sbin/diskutil eject \"$3\" >/dev/null 2>&1; fi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "murmur-move", String(getpid()), app.path, volume?.path ?? ""]
        try? process.run()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// A path for the shell, in single quotes.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Where it runs from

    static func isInApplications(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// "/Volumes/Murmur 1.4.2/Murmur.app" → "/Volumes/Murmur 1.4.2".
    static func volumeRoot(of url: URL) -> URL? {
        let parts = url.standardizedFileURL.pathComponents   // ["/", "Volumes", "Murmur 1.4.2", "Murmur.app"]
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes").appendingPathComponent(parts[2])
    }

    /// Where the app really is. A quarantined app opened where Finder didn't move it runs from a hidden read-only
    /// copy (App Translocation); Security has the original's path, through functions it exports but doesn't declare
    /// (Sparkle and other apps look it up the same way). The running path when it isn't translocated.
    private static func originalURL(of url: URL) -> URL {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutableRawPointer?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutableRawPointer?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        var translocated = false
        guard unsafeBitCast(isSymbol, to: IsTranslocated.self)(url as CFURL, &translocated, nil), translocated,
              let original = unsafeBitCast(originalSymbol, to: OriginalPath.self)(url as CFURL, nil) else { return url }
        return original.takeRetainedValue() as URL
    }
}
