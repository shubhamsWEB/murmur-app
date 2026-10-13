import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox

/// Murmur's dictation: hold the dictation key to talk and release to insert, or double-tap it for hands-free and tap
/// again to finish (Esc cancels). Speech is transcribed on this Mac and pasted into the focused app.
@MainActor
public final class DictationController {
    public enum Phase: Equatable {
        case idle
        case listening(handsFree: Bool)
        case transcribing
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastText: String?
    public private(set) var modelStatus = "Speech model not loaded"
    /// Where log lines go (the app passes its own logger).
    public var log: (String) -> Void = { print($0) }

    private let recorder = MicRecorder()
    private let transcriber = ParakeetTranscriber()
    private let hud = DictationHUD()
    private let monitor: DictationKeyMonitor
    private var pressedAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var retryTimer: Timer?
    private var openedAccessibilitySettings = false

    /// A press shorter than this is a tap, not a hold (taps start hands-free dictation).
    private let tapLength: TimeInterval = 0.3
    /// Two taps within this time make a double-tap.
    private let doubleTapWindow: TimeInterval = 0.4
    /// Shorter recordings are treated as accidental and dropped.
    private let minimumSamples = 16_000 / 4

    private static let keyDefault = "dictationKey"

    public init() {
        let saved = UserDefaults.standard.string(forKey: Self.keyDefault).flatMap(DictationKeyMonitor.Key.init)
        monitor = DictationKeyMonitor(key: saved ?? .fn)
        monitor.onDown = { [weak self] in self?.keyDown() }
        monitor.onUp = { [weak self] in self?.keyUp() }
        monitor.onOtherKey = { [weak self] code in self?.otherKey(code) }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.setLevel(level) }
        }
    }

    public var key: DictationKeyMonitor.Key { monitor.key }

    /// Asks for the microphone and Accessibility, starts watching the key, and loads the speech model.
    public func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async { self?.log("dictation: microphone \(granted ? "allowed" : "denied")") }
        }
        startMonitor(prompt: true)
        Task { await prepareModel() }
    }

    public func setKey(_ key: DictationKeyMonitor.Key) {
        UserDefaults.standard.set(key.rawValue, forKey: Self.keyDefault)
        monitor.stop()
        monitor.key = key
        startMonitor(prompt: false)
        log("dictation: key is now \(key.display)")
    }

    /// Pastes the last dictation again (when it couldn't be inserted the first time).
    public func pasteLast() {
        guard let lastText else { return }
        report(TextInserter.insert(lastText))
    }

    /// Items for the menu bar menu.
    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let header = NSMenuItem(title: "Dictation: hold \(monitor.key.display) to talk", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)
        let status = NSMenuItem(title: monitor.isRunning ? modelStatus : "Needs Accessibility permission",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        items.append(status)
        let canPaste = AXIsProcessTrusted()
        if monitor.isRunning, !canPaste {
            let note = NSMenuItem(title: "Can't paste yet: allow Murmur in Accessibility", action: nil, keyEquivalent: "")
            note.isEnabled = false
            items.append(note)
        }
        if !monitor.isRunning || !canPaste {
            items.append(ClosureMenuItem("Open Accessibility Settings…") {
                Self.openPrivacyPane("Privacy_Accessibility")
            })
        }
        let keyMenu = NSMenu()
        for key in DictationKeyMonitor.Key.allCases {
            keyMenu.addItem(ClosureMenuItem(key.display, checked: key == monitor.key) { [weak self] in
                self?.setKey(key)
            })
        }
        let keyItem = NSMenuItem(title: "Dictation Key", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        items.append(keyItem)
        if let lastText {
            items.append(ClosureMenuItem("Paste Last Dictation") { [weak self] in self?.pasteLast() })
            items.append(ClosureMenuItem("Copy Last Dictation") { TextInserter.copy(lastText) })
        }
        return items
    }

    // MARK: - Key handling

    private func keyDown() {
        switch phase {
        case .listening(handsFree: true):
            finish()                       // a tap ends hands-free dictation
        case .idle:
            let doubleTap = Date().timeIntervalSince(lastTapAt) < doubleTapWindow
            pressedAt = Date()
            begin(handsFree: doubleTap)
        default:
            break
        }
    }

    private func keyUp() {
        guard case .listening(handsFree: false) = phase else { return }
        if Date().timeIntervalSince(pressedAt) < tapLength {
            // A tap, not a hold: drop the audio and wait to see whether a second tap follows.
            recorder.cancel()
            phase = .idle
            hud.hide()
            lastTapAt = Date()
        } else {
            finish()
        }
    }

    private func otherKey(_ code: Int64) {
        switch phase {
        case .listening(handsFree: true) where code == Int64(kVK_Escape):
            cancel()
        case .listening(handsFree: false):
            cancel()                       // Fn was part of a shortcut (Fn+Delete, Fn+arrow…), not dictation
        default:
            break
        }
    }

    // MARK: - Dictation

    private func begin(handsFree: Bool) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.flash("Murmur needs microphone access")
            Self.openPrivacyPane("Privacy_Microphone")
            return
        }
        do {
            try recorder.start()
            phase = .listening(handsFree: handsFree)
            hud.show(.listening(handsFree: handsFree))
        } catch {
            log("dictation: can't start the microphone: \(error.localizedDescription)")
            hud.flash("Can't start the microphone")
        }
    }

    private func cancel() {
        recorder.cancel()
        phase = .idle
        hud.hide()
    }

    private func finish() {
        let samples = recorder.stop()
        guard samples.count >= minimumSamples else {
            phase = .idle
            hud.hide()
            return
        }
        phase = .transcribing
        Task { [weak self] in
            guard let self else { return }
            let ready = await transcriber.isReady
            hud.show(ready ? .transcribing : .preparing)
            let started = Date()
            do {
                let raw = try await transcriber.transcribe(samples)
                let text = TextCleanup.basic(raw)
                let seconds = Double(samples.count) / 16_000
                log(String(format: "dictation: %.1f s of audio → %ld characters in %.2f s",
                           seconds, text.count, Date().timeIntervalSince(started)))
                phase = .idle
                guard !text.isEmpty else {
                    hud.flash("Didn't catch that")
                    return
                }
                lastText = text
                hud.hide()
                report(TextInserter.insert(text))
            } catch {
                phase = .idle
                log("dictation: transcription failed: \(error.localizedDescription)")
                hud.flash("Transcription failed")
            }
        }
    }

    private func report(_ outcome: TextInserter.Outcome) {
        switch outcome {
        case .inserted:
            break
        case .secureInput:
            hud.flash("Can't type into a password field · use Paste Last Dictation")
        case .needsAccessibility:
            // Keep the words: they go on the clipboard, so ⌘V still works. Settings opens once per launch, not on
            // every dictation.
            if let lastText { TextInserter.copy(lastText) }
            hud.flash("Copied · press ⌘V. Allow Murmur in Accessibility to paste automatically", seconds: 4)
            if !openedAccessibilitySettings {
                openedAccessibilitySettings = true
                Self.openPrivacyPane("Privacy_Accessibility")
            }
        }
    }

    // MARK: - Setup

    private func prepareModel() async {
        modelStatus = "Speech model: downloading or loading…"
        log("dictation: preparing Parakeet")
        let started = Date()
        do {
            try await transcriber.prepare()
            modelStatus = "Speech model ready (Parakeet v3, on device)"
            log(String(format: "dictation: Parakeet ready in %.1f s", Date().timeIntervalSince(started)))
        } catch {
            modelStatus = "Speech model failed to load"
            log("dictation: Parakeet failed: \(error.localizedDescription)")
        }
    }

    /// Starts the key monitor. Without Accessibility permission macOS refuses it, so this retries every 2 s
    /// until you grant it in System Settings (once, with macOS's prompt, if `prompt`).
    private func startMonitor(prompt: Bool) {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if monitor.start() {
            log("dictation: watching \(monitor.key.display)")
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        log("dictation: waiting for Accessibility permission")
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.retryMonitor() }
        }
    }

    private func retryMonitor() {
        guard monitor.start() else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        log("dictation: Accessibility granted, watching \(monitor.key.display)")
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Tidying that needs no model: Parakeet already writes punctuation and capitals.
/// Milestone 2 replaces this with the local LLM pass.
enum TextCleanup {
    static func basic(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
