import AgentKit
import AppKit
import SwiftUI

/// "Your day": the morning brief and the evening wrap-up in full. The notification is the short version; clicking it
/// opens this page. Read top to bottom: the brief, what needs you, today, where you left off, your work by session,
/// what's coming, and what's still open. Each row is one thing, one line of context, and a tag saying where it stands.
struct DayPage: View {
    let app: AppController
    let state: HomeState

    var body: some View {
        let _ = state.revision
        let _ = Brain.shared.revision
        let now = Date()
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Your day", subtitle: now.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                Button("Memory…") { state.section = .memory }.buttonStyle(.murmurSecondary)
            }
            if ScreenMemory.shared.settings.enabled {
                content(DayOverview.build(journal: ScreenMemory.shared.journal, brain: Brain.shared.store,
                                          graph: Brain.shared.graph, now: now))
            } else {
                SettingsSection {
                    SettingRow(title: "Screen memory is off",
                               detail: "Your day is built from what Murmur sees you work on. Turn on screen memory to see "
                                   + "what you did, where you left off and what’s still open.") {
                        Button("Open Memory") { state.section = .memory }.buttonStyle(.murmurSecondaryCompact)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ day: DayOverview) -> some View {
        if day.isEmpty {
            SettingsSection {
                paragraph("Nothing yet. As you work, what you do, what you promise and who’s waiting on you show up here.")
            }
        }
        ForEach(Array(day.notes.enumerated()), id: \.offset) { _, note in
            SettingsSection(note.title + " · " + note.created.formatted(date: .omitted, time: .shortened)) {
                paragraph(note.body)
            }
        }
        group("Needs you", day.needsYou)
        group("Today", day.today)
        group("Reminders", day.reminders)
        if let left = day.leftOff {
            SettingsSection("Where you left off") { row(left) }
        }
        ForEach(day.sessions) { session in sessionView(session) }
        group("Coming up this week", day.comingUp)
        group("Waiting on others", day.waitingOn)
        group("Your open promises", day.openPromises)
    }

    /// A session of work: its stretches in order, the short ones summed up, then what got finished.
    private func sessionView(_ session: DayOverview.Session) -> some View {
        SettingsSection("\(session.name) · \(session.hours) · \(DayDates.length(session.total))") {
            ForEach(Array(session.stretches.enumerated()), id: \.element.id) { index, line in
                if index > 0 { RowDivider() }
                row(line)
            }
            if session.shorter > 0 {
                if !session.stretches.isEmpty { RowDivider() }
                Text("\(session.shorter) shorter \(session.shorter == 1 ? "stretch" : "stretches") · "
                     + DayDates.length(session.shorterSeconds))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            if !session.finished.isEmpty {
                RowDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Finished").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
                    ForEach(session.finished) { line in
                        Label(line.title, systemImage: "checkmark")
                            .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                            .labelStyle(DoneLabel())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ lines: [DayOverview.Line]) -> some View {
        if !lines.isEmpty {
            SettingsSection(title) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if index > 0 { RowDivider() }
                    row(line)
                }
            }
        }
    }

    /// One thing: its title, one line of context, and where it stands on the right.
    private func row(_ line: DayOverview.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !line.context.isEmpty {
                    Text(line.context).font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                if !line.more.isEmpty {
                    Text(line.more).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 12)
            if !line.tag.isEmpty { tag(line.tag, line.tone) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func tag(_ text: String, _ tone: DayOverview.Tone) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
            .foregroundStyle(tone == .urgent ? Theme.accentText : tone == .done ? Theme.good : Theme.ink2)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tone == .urgent ? Theme.accent.opacity(0.12)
                                       : tone == .done ? Theme.goodTint : Theme.line.opacity(0.6)))
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
    }
}

/// A finished thing: a small green tick, then what it was.
private struct DoneLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.good)
            configuration.title
        }
    }
}
