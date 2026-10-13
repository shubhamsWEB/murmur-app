import AppKit
import SwiftUI

/// Murmur's colors for the voice overlays (the app's `Brand` holds the same values).
enum Palette {
    static let coral = Color(red: 1.000, green: 0.435, blue: 0.380)        // #FF6F61
    static let coralDeep = Color(red: 0.886, green: 0.333, blue: 0.290)    // #E2554A
    static let ink = Color(red: 0.133, green: 0.118, blue: 0.110)          // #221E1C
    static let cream = Color(red: 0.984, green: 0.969, blue: 0.949)        // #FBF7F2
    static let clay = dynamic(0x6B5F58, 0xBFB2A9)
    static let text = dynamic(0x221E1C, 0xF5EDE6)
    static let card = dynamic(0xFFFFFF, 0x2A2624)
    static let line = dynamic(0xE8E0D7, 0x3A3431)
    static let control = dynamic(0xE2D9CF, 0x4A423D)
    static let onPrimary = dynamic(0xFFFFFF, 0x1E1B1A)

    nonisolated static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    static let paper = Color(nsColor: NSColor(name: "MurmurPaper") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.118, green: 0.106, blue: 0.102, alpha: 1)
            : NSColor(srgbRed: 0.984, green: 0.973, blue: 0.957, alpha: 1)   // #FBF8F4
    })
}
