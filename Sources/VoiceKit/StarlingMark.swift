import SwiftUI

/// Murmur's mark: a small coral starling whose wing is a sound wave (a murmuration is a flock of starlings).
/// Drawn from the same 100-unit geometry as the app icon (`Resources/AppIcon/appicon.svg`) so every size matches.
public struct StarlingMark: View {
    public enum Style: Sendable {
        /// Coral bird, charcoal beak and eye, cream wing: the app icon's colors.
        case color
        /// One color, the eye and wing cut out: for the menu bar, the voice bar and small sizes.
        case mono(Color)
    }

    var style: Style
    /// Listening: two little sound arcs from the beak.
    var listening: Bool
    /// Legs only at sizes where they read (the app icon and big marks).
    var legs: Bool

    public init(_ style: Style = .color, listening: Bool = false, legs: Bool = false) {
        self.style = style
        self.listening = listening
        self.legs = legs
    }

    // The bird's bounds in the 100-unit grid (x 12…89, y 29…85, plus room for the arcs), centred in the view.
    private static let center = CGPoint(x: 50.5, y: 56.75)

    public var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / (listening ? 96 : 82)
            context.translateBy(x: size.width / 2 - (Self.center.x + (listening ? 4 : 0)) * unit,
                                y: size.height / 2 - Self.center.y * unit)
            context.scaleBy(x: unit, y: unit)

            let coral = Color(red: 1.0, green: 0.435, blue: 0.380)
            let tailColor = Color(red: 0.886, green: 0.333, blue: 0.290)
            let ink = Color(red: 0.133, green: 0.118, blue: 0.110)
            let cream = Color(red: 1.0, green: 0.965, blue: 0.937)
            var monoColor: Color?
            if case .mono(let color) = style { monoColor = color }

            var tail = Path()
            tail.move(to: CGPoint(x: 30, y: 58))
            tail.addLine(to: CGPoint(x: 12, y: 47))
            tail.addLine(to: CGPoint(x: 16, y: 67))
            tail.closeSubpath()
            let body = Path(ellipseIn: CGRect(x: 24, y: 41, width: 48, height: 38))
            let head = Path(ellipseIn: CGRect(x: 53, y: 29, width: 26, height: 26))
            var beak = Path()
            beak.move(to: CGPoint(x: 78, y: 40.5))
            beak.addLine(to: CGPoint(x: 89, y: 44))
            beak.addLine(to: CGPoint(x: 78, y: 47.5))
            beak.closeSubpath()
            let eye = Path(ellipseIn: CGRect(x: 66.4, y: 36.4, width: 5.2, height: 5.2))
            var wing = Path()
            wing.move(to: CGPoint(x: 31, y: 60))
            wing.addQuadCurve(to: CGPoint(x: 40, y: 60), control: CGPoint(x: 35.5, y: 52))
            wing.addQuadCurve(to: CGPoint(x: 49, y: 60), control: CGPoint(x: 44.5, y: 68))
            wing.addQuadCurve(to: CGPoint(x: 58, y: 60), control: CGPoint(x: 53.5, y: 52))
            var legPath = Path()
            legPath.move(to: CGPoint(x: 44, y: 78.5)); legPath.addLine(to: CGPoint(x: 44, y: 84.5))
            legPath.move(to: CGPoint(x: 53, y: 78.5)); legPath.addLine(to: CGPoint(x: 53, y: 84.5))
            var arcs = Path()
            arcs.addArc(center: CGPoint(x: 88, y: 44), radius: 7, startAngle: .degrees(-40), endAngle: .degrees(40),
                        clockwise: false)
            arcs.move(to: CGPoint(x: 88 + 13 * cos(-0.70), y: 44 + 13 * sin(-0.70)))
            arcs.addArc(center: CGPoint(x: 88, y: 44), radius: 13, startAngle: .radians(-0.70), endAngle: .radians(0.70),
                        clockwise: false)

            if let monoColor {
                context.drawLayer { layer in
                    for shape in [tail, body, head, beak] { layer.fill(shape, with: .color(monoColor)) }
                    if legs { layer.stroke(legPath, with: .color(monoColor), style: StrokeStyle(lineWidth: 3, lineCap: .round)) }
                    layer.blendMode = .clear
                    layer.fill(eye, with: .color(.black))
                    layer.stroke(wing, with: .color(.black), style: StrokeStyle(lineWidth: 4.6, lineCap: .round))
                }
                if listening {
                    context.stroke(arcs, with: .color(monoColor), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
                }
            } else {
                context.fill(tail, with: .color(tailColor))
                context.fill(body, with: .color(coral))
                context.fill(head, with: .color(coral))
                context.fill(beak, with: .color(ink))
                context.fill(eye, with: .color(ink))
                context.stroke(wing, with: .color(cream), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
                if legs { context.stroke(legPath, with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round)) }
                if listening {
                    context.stroke(arcs, with: .color(coral), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
