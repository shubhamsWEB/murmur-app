import AppKit
import SwiftUI
import VoiceKit

/// Meetings: the notes from your calls, newest first, from Documents › Murmur Meetings. Search them, read one in
/// place, copy its notes, or show its file. Start notes from here too.
struct MeetingsPage: View {
    let app: AppController
    let state: HomeState
    @State private var meetings: [SavedMeeting] = []
    @State private var query = ""
    @State private var open: URL?
    @State private var copied: URL?

    var body: some View {
        let _ = state.revision
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Meetings",
                       subtitle: "Notes from your calls, newest first. Murmur offers to take them when a call starts.") {
                HStack(spacing: 8) {
                    Button("Open folder") { showFolder() }.buttonStyle(.murmurSecondary)
                    Button(app.dictation.meetingNotesRunning ? "Show notes" : "Take notes now") {
                        app.dictation.startMeetingNotes()
                    }
                    .buttonStyle(.murmurPrimary)
                }
            }
            SettingsSection {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.ink3)
                    TextField("Search your meetings: a name, a decision, a number", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.ink3)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            let shown = filtered
            if meetings.isEmpty {
                SettingsSection {
                    Text("No meetings yet. Start notes from here or the menu bar, or say yes when Murmur offers as a call "
                         + "starts. Each meeting's notes and transcript are saved in Documents › Murmur Meetings.")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(18)
                }
            } else if shown.isEmpty {
                Text("No meeting mentions “\(query)”.").font(.system(size: 13)).foregroundStyle(Theme.ink2)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(shown) { meeting in card(meeting) }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: app.dictation.meetingNotesRunning) { load() }
    }

    private var filtered: [SavedMeeting] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return meetings }
        return meetings.filter { meeting in
            let haystack = (meeting.title + " " + meeting.text).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private func card(_ meeting: SavedMeeting) -> some View {
        let expanded = open == meeting.url
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                open = expanded ? nil : meeting.url
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                        Text(meeting.subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        if !expanded, let gist = meeting.gist {
                            Text(gist).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(meeting.title), \(meeting.subtitle)")
            .accessibilityHint(expanded ? "Hides the notes" : "Shows the notes")
            if expanded {
                RowDivider()
                VStack(alignment: .leading, spacing: 14) {
                    MeetingNotesText(markdown: meeting.notes)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button(copied == meeting.url ? "Copied" : "Copy notes") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(meeting.notes, forType: .string)
                            copied = meeting.url
                        }
                        .buttonStyle(.murmurSecondaryCompact)
                        Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([meeting.url]) }
                            .buttonStyle(.murmurSecondaryCompact)
                        Button("Open") { NSWorkspace.shared.open(meeting.url) }
                            .buttonStyle(.murmurSecondaryCompact)
                    }
                }
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }

    private func load() {
        guard let folder = MeetingMode.folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { meetings = []; return }
        meetings = files.filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { SavedMeeting(url: $0) }
            .sorted { $0.date > $1.date }
    }

    private func showFolder() {
        guard let folder = MeetingMode.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// One saved meeting: its file, title, when, which app, and its notes (the part before the transcript).
struct SavedMeeting: Identifiable {
    var id: URL { url }
    let url: URL
    let title: String
    let date: Date
    let app: String?
    let text: String
    let notes: String
    let lines: Int

    init?(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.url = url
        self.text = text
        // "2026-11-18 01.30 Zoom.md": the date and the app from the name; the file's date otherwise.
        let name = url.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = String(name.prefix(16))
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        date = formatter.date(from: stamp) ?? modified ?? .distantPast
        let rest = name.dropFirst(min(17, name.count)).trimmingCharacters(in: .whitespaces)
        app = rest.isEmpty || rest == "Meeting" ? nil : rest
        let parts = text.components(separatedBy: "\n## Transcript")
        notes = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        lines = parts.count > 1 ? parts[1].components(separatedBy: "\n\n").filter { $0.hasPrefix("**") }.count : 0
        let heading = notes.components(separatedBy: .newlines).first { $0.hasPrefix("# ") }
        title = heading.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? (app.map { "\($0) meeting" } ?? "Meeting")
    }

    var subtitle: String {
        var parts = [date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())]
        if let app { parts.append(app) }
        if lines > 0 { parts.append("\(lines) lines") }
        return parts.joined(separator: ", ")
    }

    /// The first bullet of the notes, as a preview.
    var gist: String? {
        notes.components(separatedBy: .newlines)
            .first { $0.hasPrefix("- ") && !$0.hasPrefix("- [") }
            .map { String($0.dropFirst(2)) }
    }
}
