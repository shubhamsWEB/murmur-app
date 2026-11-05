import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Seeing a window, not only reading it: Qwen3-VL (the vision model "look at my screen" uses, in Ollama on this Mac)
/// looks at a small picture of a window you spent time in, with what its text and app say, and tells what kind of
/// screen it is, what's real content and what's decoration (a product's demo, an advert, an example), and what the
/// user was doing. The reading model then works from that.
///
/// Never at the cost of the Mac: only on Macs that can spare it (Apple silicon with 16 GB or more), only while plugged
/// in, away, cool and otherwise quiet, one picture at a time, a few a round (`WindowVision.Budget`).
public enum WindowVision {
    public struct Budget: Sendable {
        /// Pictures taken in an hour, at most.
        public var perHour = 30
        /// Pictures waiting, in all, at most.
        public var maxBytes = 150 * 1024 * 1024
        /// A window gets a picture once you've stayed this long.
        public var stayed: Double = 30
        /// Pictures looked at in one round.
        public var perRound = 10
        /// The long side of a picture, in pixels.
        public var side = 1024
        public init() {}
    }

    /// Whether this Mac can run the vision model in the background without being slowed: Apple silicon with 16 GB of
    /// memory or more. Others never take pictures; their windows are understood from structure and text.
    public static func capable(memory: UInt64 = ProcessInfo.processInfo.physicalMemory, appleSilicon: Bool = isAppleSilicon) -> Bool {
        appleSilicon && memory >= 15 << 30
    }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Which windows are worth a picture: those whose meaning their text leaves open (a page, a product's site, an
    /// app, a conversation whose bubbles say who wrote what). Not AI chats, terminals or code.
    public static func worthLooking(_ kind: WindowKind, app: String) -> Bool {
        switch kind {
        case .page, .product, .app, .conversation, .feed, .article: return !["terminal", "iterm2", "warp", "ghostty"].contains(app.lowercased())
        case .work, .assistant, .search, .docs, .video: return false
        }
    }

    // MARK: Asking the model

    static let system = """
        You see a picture of one window on the user's Mac, with the app it's in, its address and some of its text. Say \
        what it is, so their assistant remembers only what concerns the user. JSON only:
        "kind": one of conversation (people messaging, email), work (the user's own document, issue, code, notes), \
        assistant (an AI chat), feed, article, product (a company's or product's website: features, pricing, demos), \
        search, docs, video, page, app.
        "seen_as": one plain sentence on what this screen is and what the user is doing ("A Slack thread where Priya \
        asks the user for the Q3 deck", "A product's landing page showing a demo chat as an example").
        "user_content": true when what's shown is the user's own conversation or work; false for anything made for \
        everyone (a website, a demo, an advert, an example, someone else's post).
        "ignore": the parts that aren't real content (adverts, demo or sample messages, navigation), in a few words, or "".
        """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": ["kind": ["type": "string"], "seen_as": ["type": "string"], "user_content": ["type": "boolean"],
                       "ignore": ["type": "string"]],
        "required": ["kind", "seen_as", "user_content"],
    ]

    public struct Seen: Sendable, Equatable {
        public var kind: WindowKind?
        public var seenAs: String
        public var userContent: Bool
    }

    /// The model's answer, read leniently. The sentence carries what was ignored and whose content it was, for the
    /// reading model.
    public static func parse(_ content: String) -> Seen? {
        let answer = ModelOutput.answer(content)
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any] else {
            return nil
        }
        let sentence = (object["seen_as"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return nil }
        let user = object["user_content"] as? Bool ?? true
        let ignore = (object["ignore"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var seenAs = String(sentence.prefix(240))
        if !user { seenAs += " (not the user's own content)" }
        if !ignore.isEmpty, ignore.lowercased() != "none" { seenAs += " Not real content: \(ignore.prefix(120))." }
        let kind = WindowKind(rawValue: (object["kind"] as? String ?? "").lowercased())
        return Seen(kind: kind, seenAs: BrainModel.redact(seenAs), userContent: user)
    }

    /// What the vision model makes of one window. Nil when it couldn't be asked.
    public static func look(at jpeg: Data, snapshot: Journal.Snapshot, model: String) async -> Seen? {
        let place = snapshot.domain.isEmpty ? snapshot.app : "\(snapshot.app), \(snapshot.url ?? snapshot.domain)"
        let text = BrainModel.redact(String(snapshot.text.prefix(1500)))
        let user = "Window: \(place), titled \"\(snapshot.title)\". Murmur guessed: \(WindowKind.of(snapshot).label).\n"
            + "Some of its text:\n\(text)"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": "2m", "format": schema,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user, "images": [jpeg.base64EncodedString()]]],
            "options": ["temperature": 0, "num_predict": 200, "num_ctx": 4096],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let message = json["message"] as? [String: Any], let content = message["content"] as? String else {
            return nil
        }
        return parse(content)
    }

    /// The vision model Ollama has: the one chosen for "look at my screen" if it's there, else Qwen3-VL. Nil without.
    public static func model() async -> String? {
        let installed = await BrainDistiller.installedModels()
        for name in [VisionText.localModel, VisionText.defaultModel] + VisionText.earlierModels where installed.contains(name) {
            return name
        }
        return nil
    }
}
