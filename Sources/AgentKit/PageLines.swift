import Foundation

/// How a control on a web page is written in a page read through Accessibility. Reading only the text inside things
/// dropped what a control is called and its state: a grid read as "3 9 8 6 4…" with no rows or columns (its cells
/// are named "Row 1, column 3, empty"), and a switch read the same on and off, so turning it off looked like
/// nothing changed. A named control is written as its name with its state; one without a name reads as before.
public enum PageLines {
    /// The line for a control, or nil to read it as before (its text). `role`: the Accessibility role; `name`: its
    /// description or title (what a screen reader says); `inner`: the text inside it; `state`: on/off for a switch
    /// or checkbox, the text in a field, the value of a slider.
    public static func control(role: String, name: String?, inner: String, state: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let kind = kinds[role] else { return nil }
        let inside = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        // A long block inside (a card that's a button) is read as text, as before.
        guard inside.count <= 80 else { return nil }
        var line = name
        if !inside.isEmpty, !fold(name).contains(fold(inside)) { line += ": \(inside)" }
        switch kind {
        case "checkbox", "switch", "radio", "toggle":
            return "\(line) (\(kind)\(state.map { ", \($0)" } ?? ""))"
        case "text field", "combo box":
            let value = state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "\(line) (\(kind)\(value.isEmpty ? ", empty" : ": \"\(value.prefix(120))\""))"
        case "slider":
            return "\(line) (slider\(state.map { ": \($0)" } ?? ""))"
        default:
            return "\(line) (\(kind))"
        }
    }

    /// An Accessibility value as a switch's state: 1 on, 0 off, 2 mixed.
    public static func toggleState(_ number: Int?) -> String? {
        switch number {
        case 1: return "on"
        case 0: return "off"
        case 2: return "mixed"
        default: return nil
        }
    }

    /// The roles written as controls, and what they're called.
    static let kinds: [String: String] = [
        "AXCell": "cell", "AXButton": "button", "AXCheckBox": "checkbox", "AXSwitch": "switch",
        "AXToggle": "toggle", "AXRadioButton": "radio", "AXTextField": "text field", "AXComboBox": "combo box",
        "AXPopUpButton": "pop-up", "AXMenuButton": "menu button", "AXSlider": "slider", "AXTab": "tab",
    ]

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
