import AppKit
import SwiftUI

/// Murmur's colors for the voice overlays (the app's `Brand` holds the same values).
enum Palette {
    static let coral = Color(red: 1.000, green: 0.435, blue: 0.380)        // #FF6F61
    static let coralDeep = Color(red: 0.886, green: 0.333, blue: 0.290)    // #E2554A
    static let ink = Color(red: 0.169, green: 0.145, blue: 0.137)          // #2B2523
    static let cream = Color(red: 0.984, green: 0.969, blue: 0.949)        // #FBF7F2
    static let clay = Color(red: 0.541, green: 0.482, blue: 0.451)         // #8A7B73
    static let paper = Color(nsColor: NSColor(name: "MurmurPaper") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.118, green: 0.106, blue: 0.102, alpha: 1)
            : NSColor(srgbRed: 0.984, green: 0.969, blue: 0.949, alpha: 1)
    })
}
