import Foundation

/// The text side of screen vision, free of AppKit (so it's tested anywhere): where screenshots may go, how a
/// screenshot rides along in a tool result to a model that can see, and turning a vision model's positions into the
/// screenshot's pixels.
public enum VisionText {
    /// Where screenshots of your screen may go. `local` (the default): to a vision model on this Mac (Qwen3-VL through
    /// Ollama); the planning model, even a cloud one, gets only its description and positions. `cloud`: to the cloud
    /// model you chose in Settings (Claude or OpenAI), as images. `off`: no screenshots; text recognition on this Mac
    /// only. `defaults write com.copico.Murmur screenVision local|cloud|off`.
    public enum Mode: String, Sendable {
        case local, cloud, off
    }

    public static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: "screenVision") ?? "") ?? .local
    }

    /// The local vision model: Qwen3-VL, 8B with 16 GB of memory or more (about 94% on ScreenSpot, 6 GB), else 4B
    /// (about 90%, 3.3 GB). `defaults write com.copico.Murmur visionModel <ollama tag>` for another.
    public static var localModel: String {
        if let chosen = UserDefaults.standard.string(forKey: "visionModel"), !chosen.isEmpty { return chosen }
        return ProcessInfo.processInfo.physicalMemory >= 15 * 1_073_741_824 ? "qwen3-vl:8b" : "qwen3-vl:4b"
    }

    // MARK: Screenshots in tool results

    /// Where a screenshot sits in a tool result's text, for the model clients to put the image in its place.
    public static func marker(_ id: String) -> String { "[[screenshot:\(id)]]" }

    /// A tool result's text without its screenshot markers, and the screenshots' ids in order.
    public static func split(_ content: String) -> (text: String, ids: [String]) {
        let pattern = #"\[\[screenshot:([A-Za-z0-9-]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (content, []) }
        let whole = NSRange(content.startIndex..., in: content)
        let ids = regex.matches(in: content, range: whole).compactMap { match in
            Range(match.range(at: 1), in: content).map { String(content[$0]) }
        }
        let text = regex.stringByReplacingMatches(in: content, range: whole, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, ids)
    }

    /// Of all the screenshots in a conversation (in order), the ones still sent as images: the latest `keep`. Older
    /// ones are said to be left out; each is a few thousand tokens, and the screen has moved on since.
    public static func kept(_ all: [String], keep: Int = 2) -> Set<String> {
        Set(all.suffix(keep))
    }

    // MARK: Positions

    /// A position from a vision model that counts 0 to 1000 across and down the image (Qwen3-VL's way) in the
    /// screenshot's pixels.
    public static func pixels(relativeX x: Double, y: Double, width: Int, height: Int) -> (x: Int, y: Int) {
        let clampX = min(max(x, 0), 1000), clampY = min(max(y, 0), 1000)
        return (Int((clampX / 1000 * Double(width)).rounded()), Int((clampY / 1000 * Double(height)).rounded()))
    }

    /// A description that gives positions as "(x, y)" on the 0–1000 scale, with them in pixels instead, so the
    /// planning model clicks with the numbers it's given.
    public static func inPixels(_ description: String, width: Int, height: Int) -> String {
        let pattern = #"\(\s*(\d{1,4}(?:\.\d+)?)\s*,\s*(\d{1,4}(?:\.\d+)?)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return description }
        let out = NSMutableString(string: description)
        let source = description as NSString
        // Last first, so the earlier ranges still point at the same text.
        for match in regex.matches(in: description, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let x = Double(source.substring(with: match.range(at: 1))),
                  let y = Double(source.substring(with: match.range(at: 2))), x <= 1000, y <= 1000 else { continue }
            let point = pixels(relativeX: x, y: y, width: width, height: height)
            out.replaceCharacters(in: match.range, with: "(\(point.x), \(point.y))")
        }
        return out as String
    }

    /// A vision model's answer to "where is …": {"x": 512, "y": 300} (or "x=512, y=300", or "(512, 300)") on the
    /// 0–1000 scale; nil for {"none": true} or no position.
    public static func location(in answer: String) -> (x: Double, y: Double)? {
        if answer.range(of: #""none"\s*:\s*true"#, options: .regularExpression) != nil { return nil }
        let patterns = [#""x"\s*:\s*(\d+(?:\.\d+)?)\s*,\s*"y"\s*:\s*(\d+(?:\.\d+)?)"#,
                        #"\bx\s*[=:]\s*(\d+(?:\.\d+)?)\s*,?\s*y\s*[=:]\s*(\d+(?:\.\d+)?)"#,
                        #"\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\)"#,
                        #"\[\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*(?:,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*)?\]"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: answer, range: NSRange(answer.startIndex..., in: answer)) else { continue }
            func number(_ index: Int) -> Double? {
                guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: answer) else { return nil }
                return Double(answer[range])
            }
            guard let x = number(1), let y = number(2) else { continue }
            // A box [x1, y1, x2, y2]: its middle.
            if let x2 = number(3), let y2 = number(4) { return ((x + x2) / 2, (y + y2) / 2) }
            return (x, y)
        }
        return nil
    }

    // MARK: Prompts for the local vision model

    public static func describePrompt(app: String, window: String, question: String) -> String {
        "This is a screenshot of the \(app) window \"\(window)\" on a Mac. An assistant that can't see it will act on "
            + "your description, so be complete and exact.\n"
            + "1. TEXT: all the text you can read, top to bottom, left to right, as it appears (lists item by item).\n"
            + "2. CONTROLS: every button, link, field, tab, menu, checkbox, list row and icon that can be clicked, one "
            + "per line as `- <its words or what it shows> (<kind>) at (x, y)`, x and y from 0 to 1000 across and down "
            + "the image, at its centre.\n"
            + "3. MORE: say if the window's content is cut off (a scroll bar, text running past an edge, \"load "
            + "more\").\n"
            + (question.isEmpty ? "" : "4. ANSWER: \(question)\n")
            + "Only describe what is really there."
    }

    public static func locatePrompt(_ target: String) -> String {
        "Find this on the screenshot: \(target)\nReply with only JSON: {\"x\": <0-1000 across>, \"y\": <0-1000 down>} "
            + "at its centre, or {\"none\": true} if it isn't there."
    }
}
