import AppKit
import SwiftUI

/// Murmur's design system (the "Murmur — App Redesign" canvas): warm paper, charcoal ink, and coral only for what's
/// live or yours to notice. Primary buttons are charcoal; status uses calm green and amber pills. Every colour has a
/// dark-mode twin with the same role.
enum Theme {
    nonisolated static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: dynamicNS(light, dark))
    }

    nonisolated static func dynamicNS(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    // Surfaces
    static let page = dynamic(0xFBF8F4, 0x1E1B1A)
    static let pageNS = dynamicNS(0xFBF8F4, 0x1E1B1A)
    static let sidebar = dynamic(0xF4EFE9, 0x252120)
    static let card = dynamic(0xFFFFFF, 0x2A2624)
    static let cardAlt = dynamic(0xFDFBF8, 0x262220)
    static let fill = dynamic(0xF4EFE9, 0x353029)
    // Lines
    static let line = dynamic(0xE8E0D7, 0x3A3431)
    static let hairline = dynamic(0xF1EBE4, 0x332E2B)
    static let control = dynamic(0xE2D9CF, 0x4A423D)
    // Text
    static let ink = dynamic(0x221E1C, 0xF5EDE6)
    static let ink2 = dynamic(0x6B5F58, 0xBFB2A9)
    static let ink3 = dynamic(0x8A7D75, 0x978A82)
    // Accent: the voice
    static let accent = Color(red: 1.0, green: 0.435, blue: 0.380)          // #FF6F61
    static let accentText = dynamic(0xC4473C, 0xFF8A7E)
    static let accentTint = dynamic(0xFFEDE9, 0x3D2622)
    static let accentRing = dynamic(0xFFE3DD, 0x4A2A25)
    // Status
    static let good = dynamic(0x2F7A57, 0x6FCB9C)
    static let goodTint = dynamic(0xE5F1EA, 0x1F3329)
    static let goodDot = Color(red: 0.184, green: 0.604, blue: 0.416)
    static let warn = dynamic(0xA8611B, 0xE9A866)
    static let warnTint = dynamic(0xFBEFDF, 0x3A2C1C)
    static let danger = dynamic(0xB83A30, 0xFF8A7E)
    // Primary buttons
    static let primary = ink
    static let onPrimary = dynamic(0xFFFFFF, 0x1E1B1A)

    static let sidebarWidth: CGFloat = 232
    static let radius: CGFloat = 12
}

// MARK: - Buttons

/// Charcoal, the one main action on a page.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, compact: compact)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                .foregroundStyle(enabled ? Theme.onPrimary : Theme.ink2)
                .padding(.horizontal, compact ? 12 : 14)
                .frame(height: compact ? 28 : 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled ? Theme.primary.opacity(configuration.isPressed ? 0.82 : 1) : Theme.control))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// White with a quiet border: everything else you can press.
struct SecondaryButtonStyle: ButtonStyle {
    var compact = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, compact: compact, destructive: destructive)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        let destructive: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                .foregroundStyle(!enabled ? Theme.ink3 : destructive ? Theme.danger : Theme.ink)
                .padding(.horizontal, compact ? 10 : 12)
                .frame(height: compact ? 26 : 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Theme.fill : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.control))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var murmurPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var murmurPrimaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var murmurSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var murmurSecondaryCompact: SecondaryButtonStyle { SecondaryButtonStyle(compact: true) }
    static var murmurDestructive: SecondaryButtonStyle { SecondaryButtonStyle(destructive: true) }
}

// MARK: - Building blocks

/// A page's title and one line about it, with an optional action on the right.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.4).foregroundStyle(Theme.ink)
                Text(subtitle).font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// SMALL CAPS label over a group.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 4)
    }
}

/// A labelled group of rows on a white card.
struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionLabel(title) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
        }
    }
}

/// One setting: what it is and what it does on the left, its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// The line between rows in a section.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 18)
    }
}

/// A switch in Murmur's charcoal.
struct MurmurSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(Theme.primary)
            .controlSize(.small)
    }
}

/// A short status: green when fine, amber while busy, coral when it needs you.
struct Pill: View {
    enum Tone { case good, busy, attention, neutral }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .good: Theme.good
        case .busy: Theme.warn
        case .attention: Theme.accentText
        case .neutral: Theme.ink2
        }
    }

    private var background: Color {
        switch tone {
        case .good: Theme.goodTint
        case .busy: Theme.warnTint
        case .attention: Theme.accentTint
        case .neutral: Theme.fill
        }
    }
}

/// A keyboard key, as in the How-to rows.
struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.control))
    }
}

/// A thin coral progress bar.
struct ThinProgress: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                if let fraction {
                    Capsule().fill(Theme.accent).frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
                } else {
                    Capsule().fill(Theme.accent.opacity(0.5)).frame(width: geometry.size.width * 0.3)
                }
            }
        }
        .frame(height: 4)
    }
}
