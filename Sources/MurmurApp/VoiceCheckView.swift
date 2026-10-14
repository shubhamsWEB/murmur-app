import AgentKit
import SwiftUI
import VoiceKit

/// The voice check: type the names you say often, read three short sentences in one go (about ten seconds), and see
/// what Murmur misheard. Misheard names go into your dictionary with how they were heard, so dictation listens for
/// them and spells them your way from then on.
struct VoiceCheckView: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject private var dictionary = PersonalDictionary.shared
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case start, recording, working, results }

    @State private var stage = Stage.start
    @State private var namesText = ""
    @State private var said = ""
    @State private var recording: [Float] = []
    @State private var heard = ""
    /// Parakeet alone, and with your dictionary listened for and applied.
    @State private var alone: VoiceCheck.Result?
    @State private var withDictionary: VoiceCheck.Result?
    /// The same recording again, after adding the words you picked.
    @State private var after: VoiceCheck.Result?
    @State private var suggestions: [DictionaryEntry] = []
    @State private var picked: Set<String> = []
    @State private var keep = false
    @State private var problem: String?

    private var names: [String] {
        namesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var sentences: [String] { VoiceCheck.sentences(names: Array(names.prefix(3))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice check").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch stage {
            case .start: startView
            case .recording, .working: readingView
            case .results: resultsView
            }
            if let problem {
                Text(problem).font(.system(size: 12.5)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Theme.page)
        .onDisappear { dictation.cancelCheckRecording() }
    }

    private var subtitle: String {
        switch stage {
        case .start: "Read three short sentences, about ten seconds. Murmur finds the names it mishears and learns them."
        case .recording: "Read all three, at your normal pace. Then click Done."
        case .working: "Checking what Murmur heard… The first check also downloads a small listening model."
        case .results: "What Murmur heard, word by word."
        }
    }

    // MARK: Start

    private var startView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Names you say often (optional)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                TextField("e.g. Samay Raina, Koramangala, Zomato", text: $namesText)
                    .textFieldStyle(.roundedBorder)
                Text("People, places, apps. Separate them with commas; the last sentence uses them.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            sentenceCard(dim: true)
            HStack {
                if !dictation.speechModelState.isReady {
                    Text("The speech model is still getting ready.").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.murmurSecondary)
                Button("Start reading", action: start)
                    .buttonStyle(.murmurPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dictation.speechModelState.isReady)
            }
        }
    }

    private func sentenceCard(dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                Text(sentence)
                    .font(.system(size: dim ? 15 : 19, weight: .medium))
                    .foregroundStyle(dim ? Theme.ink2 : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }

    // MARK: Reading

    private var readingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            sentenceCard(dim: false)
            HStack(spacing: 10) {
                if stage == .recording {
                    Circle().fill(Theme.accent).frame(width: 9, height: 9)
                    Text("Listening").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink2)
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") {
                    dictation.cancelCheckRecording()
                    dismiss()
                }
                .buttonStyle(.murmurSecondary)
                Button("Done", action: finish)
                    .buttonStyle(.murmurPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(stage != .recording)
            }
        }
    }

    private func start() {
        problem = nil
        // Your names go in first, so the check hears them the way dictation will.
        for name in names { dictionary.add(name) }
        said = sentences.joined(separator: " ")
        do {
            try dictation.startCheckRecording()
            stage = .recording
        } catch {
            problem = error.localizedDescription
        }
    }

    private func finish() {
        let samples = dictation.stopCheckRecording()
        guard samples.count >= 16_000 * 2 else {
            stage = .start
            problem = "That was too short. Click Start reading, read all three sentences, then click Done."
            return
        }
        stage = .working
        Task { await check(samples) }
    }

    private func check(_ samples: [Float]) async {
        do {
            let (transcript, leveled) = try await dictation.transcribeForCheck(samples)
            guard !transcript.heard.trimmingCharacters(in: .whitespaces).isEmpty else {
                stage = .start
                problem = "Murmur didn't hear anything. Check the microphone in System Settings → Sound, and try again."
                return
            }
            recording = leveled
            heard = transcript.heard
            alone = VoiceCheck.compare(said: said, heard: transcript.heard, names: names)
            let result = VoiceCheck.compare(said: said, heard: dictionary.apply(DictationController.written(transcript)), names: names)
            withDictionary = result
            suggestions = VoiceCheck.suggestions(result.mistakes, isRealWord: { DictationController.isRealWord($0) })
            // Your own names are ticked; names from the sample sentences are offered, unticked, so your dictionary
            // only gets words you actually say.
            let own = Set(names.map { $0.lowercased() })
            picked = Set(suggestions.filter { own.contains($0.written.lowercased()) }.map(\.id))
            after = nil
            stage = .results
        } catch {
            stage = .start
            problem = error.localizedDescription
        }
    }

    // MARK: Results

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let alone, let withDictionary {
                HStack(spacing: 12) {
                    score("Speech model alone", alone.accuracy, emphasised: false)
                    score("With your dictionary", withDictionary.accuracy, emphasised: after == nil)
                    if let after { score("After adding words", after.accuracy, emphasised: true) }
                }
                if withDictionary.mistakes.isEmpty {
                    Text("Murmur heard every word.").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.good)
                } else {
                    mistakesList(withDictionary.mistakes)
                }
            }
            Toggle(isOn: $keep) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep this recording on this Mac").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                    Text("So Murmur can tune itself to your voice later. Saved in Application Support/Murmur/Voice, never uploaded.")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            HStack {
                Button("Check again") {
                    stage = .start
                    problem = nil
                }
                .buttonStyle(.murmurSecondary)
                Spacer()
                if !suggestions.isEmpty && after == nil {
                    Button(picked.isEmpty ? "Add words" : "Add \(picked.count) to dictionary", action: addPicked)
                        .buttonStyle(.murmurSecondary)
                        .disabled(picked.isEmpty)
                }
                Button("Done") {
                    if keep { DictationController.keepRecording(recording, said: said, heard: heard) }
                    dismiss()
                }
                .buttonStyle(.murmurPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func score(_ title: String, _ accuracy: Double, emphasised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Int((accuracy * 100).rounded()))%")
                .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                .foregroundStyle(emphasised ? Theme.ink : Theme.ink2)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(emphasised ? Theme.card : Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(emphasised ? Theme.line : .clear))
    }

    private func mistakesList(_ mistakes: [VoiceCheck.Mistake]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Misheard").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
            ForEach(Array(mistakes.enumerated()), id: \.offset) { _, mistake in
                let suggestion = suggestions.first { $0.written.lowercased()
                    == mistake.expected.trimmingCharacters(in: .punctuationCharacters).lowercased() }
                HStack(spacing: 8) {
                    if let suggestion, after == nil {
                        Toggle("", isOn: Binding(
                            get: { picked.contains(suggestion.id) },
                            set: { on in if on { picked.insert(suggestion.id) } else { picked.remove(suggestion.id) } }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    }
                    Text(mistake.expected).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(mistake.heard.isEmpty ? "not heard" : "heard as “\(mistake.heard)”")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    Spacer(minLength: 0)
                    if suggestion == nil {
                        Text("not a name, left as is").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }

    /// Adds the picked words, then checks the same recording again so you can see the difference.
    private func addPicked() {
        for entry in suggestions where picked.contains(entry.id) {
            dictionary.add(entry.written, heard: entry.heard)
        }
        let samples = recording
        Task {
            guard let output = try? await dictation.transcribeForCheck(samples) else { return }
            after = VoiceCheck.compare(said: said, heard: dictionary.apply(DictationController.written(output.transcript)), names: names)
        }
    }
}
