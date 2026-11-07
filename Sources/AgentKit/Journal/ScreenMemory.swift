import AppKit
import ApplicationServices
import Observation
import UserNotifications

/// Screen memory, from the app's side: the switch and its settings, the helper that does the reading
/// (Contents/Helpers/murmur-memory, started and stopped here), and the briefs and reminders it writes, shown as
/// notifications.
@MainActor
@Observable
public final class ScreenMemory {
    public static let shared = ScreenMemory()

    public private(set) var settings = ScreenMemorySettings.load()
    public private(set) var running = false
    public private(set) var problem: String?
    public nonisolated let journal = Journal()

    @ObservationIgnored private var helper: Process?
    @ObservationIgnored private var restarts: [Date] = []
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var stopping = false

    init() {}

    /// Whether macOS lets Murmur show notifications (nil until it's known). Off, the brief still shows in Memory.
    public private(set) var notificationsAllowed: Bool?

    public func start() {
        if settings.enabled {
            launch()
            // Asked once; nothing happens if it was answered before.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showNudges() }
        }
    }

    /// Turns screen memory on (it needs Murmur's Accessibility permission, which dictation already asked for) or off.
    public func set(enabled: Bool) {
        if enabled, !AXIsProcessTrusted() {
            problem = "Murmur needs Accessibility permission to read your windows. Allow it in System Settings › Privacy & Security › Accessibility."
            return
        }
        problem = nil
        update { $0.enabled = enabled }
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            ReaderDownload.shared.ensure()   // what it sees is read by Murmur's own model
            launch()
        } else {
            stop()
        }
    }

    public func update(_ change: (inout ScreenMemorySettings) -> Void) {
        var next = settings
        change(&next)
        let newlyExcluded = Set(next.rules.excluded).subtracting(settings.rules.excluded)
        let readerChanged = next.cloudReader != settings.cloudReader
        settings = next
        settings.save()   // the helper reads it within a minute
        // Reading with Claude or OpenAI turned on or off: the helper starts again with (or without) the key.
        if readerChanged, settings.enabled, helper != nil { restart() }
        for app in newlyExcluded {
            journal.forget(app: app)
            Brain.shared.graph.forget(app: app)
        }
    }

    /// Forgets everything screen memory kept (snapshots, time, loops, chronicle) and what it taught the memory.
    public func forgetAll() {
        journal.forgetAll()
        Brain.shared.graph.forgetAll()
        Brain.shared.store.forget(origin: .screen)
    }

    // MARK: The helper

    private func launch() {
        guard helper?.isRunning != true else { return }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/murmur-memory")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            problem = "This copy of Murmur doesn't include screen memory's helper."
            return
        }
        let process = Process()
        process.executableURL = url
        process.qualityOfService = .background
        process.standardOutput = FileHandle.nullDevice
        // Reading with Claude or OpenAI: the helper gets the key on its standard input (it can't read Murmur's
        // Keychain items itself), never in its arguments or environment.
        var handoff: String?
        if let provider = settings.cloudReader, let choice = RouterChoice(rawValue: provider), let account = choice.keyAccount,
           let key = Keychain.get(account) {
            handoff = CloudReader.handoff(anthropic: choice == .anthropic ? key : nil, anthropicModel: AnthropicRouter.model,
                                          workspace: AnthropicWorkspace.id, openai: choice == .openai ? key : nil,
                                          openaiModel: OpenAIRouter.model)
        }
        let input = Pipe()
        if handoff != nil {
            var environment = ProcessInfo.processInfo.environment
            environment["MURMUR_KEYS_ON_STDIN"] = "1"
            process.environment = environment
            process.standardInput = input
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus, pid = ended.processIdentifier
            Task { @MainActor in self?.ended(status, pid: pid) }
        }
        do {
            try process.run()
            if let handoff {
                input.fileHandleForWriting.write(Data((handoff + "\n").utf8))
                try? input.fileHandleForWriting.close()
            }
            helper = process
            running = true
            stopping = false
        } catch {
            problem = "Screen memory couldn't start (\(error.localizedDescription))."
        }
    }

    private func stop() {
        stopping = true
        helper?.terminate()
        helper = nil
        running = false
    }

    /// The helper again, now (its settings changed in a way it reads only when it starts).
    private func restart() {
        let old = helper
        stopping = true
        helper = nil
        old?.terminate()
        stopping = false
        launch()
    }

    private func ended(_ status: Int32, pid: Int32) {
        // One that was replaced (restarted) ending: the new one carries on.
        if let helper, helper.processIdentifier != pid { return }
        running = false
        helper = nil
        guard !stopping, settings.enabled else { return }
        if status == 2 {
            problem = "Murmur needs Accessibility permission to read your windows."
            return
        }
        // Restarted after a crash, but not in a loop: at most three times an hour.
        restarts = restarts.filter { $0 > Date().addingTimeInterval(-3600) }
        guard restarts.count < 3 else { problem = "Screen memory stopped. Turn it off and on to try again."; return }
        restarts.append(Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
    }

    // MARK: Nudges

    /// Shows what the helper wrote as notifications, once macOS allows them. Until then they stay unseen (and the
    /// Memory page shows today's brief), so turning notifications on later still brings the next one.
    private func showNudges() {
        Brain.shared.journalChanged()
        let waiting = journal.unseenNudges()
        let journal = self.journal
        let memory = self
        UNUserNotificationCenter.current().getNotificationSettings { notifications in
            let allowed = notifications.authorizationStatus == .authorized || notifications.authorizationStatus == .provisional
            Task { @MainActor in memory.notificationsAllowed = allowed }
            guard allowed else { return }
            for nudge in waiting {
                let content = UNMutableNotificationContent()
                content.title = nudge.title
                content.body = nudge.body
                content.threadIdentifier = "murmur.\(nudge.kind)"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: nudge.key, content: content, trigger: nil))
                journal.seen(nudge: nudge.key)
            }
        }
    }
}
