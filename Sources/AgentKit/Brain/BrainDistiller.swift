import Foundation

/// Reads one thing from a source that has no structure of its own (a note, an email) and writes down what's worth
/// remembering about the user's world, with the local model in Ollama: nothing leaves the Mac. Run in the background
/// while the Mac is idle; a slow model is fine.
public enum BrainDistiller {
    /// A model that's good at reading: a general one, not Murmur Agent (trained only to pick tools). The first of these
    /// Ollama has, unless one was chosen (`defaults write com.copico.Murmur brainModel <name>`).
    static let readers = ["qwen3:4b", "qwen3:8b", "llama3.2:3b", "qwen3:1.7b", "gemma3:4b", "qwen2.5:7b"]

    public static func model() async -> String? {
        if let chosen = UserDefaults.standard.string(forKey: "brainModel"), !chosen.isEmpty { return chosen }
        let installed = await installedModels()
        for name in readers where installed.contains(name) { return name }
        // Any general model at all, else nothing: Notes and Mail wait until there's one.
        return installed.first { !$0.hasPrefix(LocalModels.agent) && !$0.hasPrefix("murmur-") && !$0.contains("embed") }
    }

    static func installedModels() async -> [String] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            .map { $0.hasSuffix(":latest") ? String($0.dropLast(7)) : $0 }
    }

    static func system(today: Date = Date()) -> String {
        let day = today.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return """
            You read one item from the user's own Mac (a note or an email) and write down what's worth remembering \
            about the user's world, so their assistant knows it later. Today is \(day).

            Write only durable, useful things: who people are and how they relate to the user (role, company, team, \
            family), what projects and deals are about and where they stand, decisions made, dates that matter, the \
            user's preferences, and tasks the user has to do. Skip greetings, newsletters, adverts, receipts, \
            one-off logistics, and anything you'd have to guess. Each memory is one short plain sentence that names \
            who or what it's about ("Priya Shah is the user's manager at Acme"), never "he", "she" or "this".

            For each memory give: "about" (the person, organization, project, place or topic it's about, by its full \
            name; "me" for the user themselves), "about_kind" (person, organization, project, place, topic or me), \
            "text", "kind" (fact, relationship, preference, event, task or status), "slot" (for an attribute a \
            person or thing has one of: employer, role, phone, email, city, birthday, manager, status; else empty), \
            and "expires" (YYYY-MM-DD when it stops being true, for an event or a task with a date; else empty).

            At most 6 memories. If nothing is worth remembering, return an empty list. JSON only.
            """
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "memories": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "about": ["type": "string"], "about_kind": ["type": "string"], "text": ["type": "string"],
                        "kind": ["type": "string"], "slot": ["type": "string"], "expires": ["type": "string"],
                    ],
                    "required": ["about", "about_kind", "text", "kind"],
                ],
            ],
        ],
        "required": ["memories"],
    ]

    /// What one item is worth remembering. Empty when nothing is (or the model couldn't be asked).
    public static func distill(_ text: String, title: String, origin: BrainModel.Origin, model: String) async
        -> [BrainModel.Candidate] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180   // in the background, on a slow Mac: no hurry
        let item = "\(origin == .mail ? "Email" : "Note"): \(title)\n\n\(text.prefix(6000))"
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system()], ["role": "user", "content": item]],
            "format": schema, "stream": false, "think": false, "keep_alive": "10m",
            "options": OllamaClient.options(["temperature": 0, "num_predict": 700]),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = data
        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else { return [] }
        return parse(content, origin: origin)
    }

    /// The memories in the model's answer: its JSON, read leniently (text around it, a list on its own, kinds and
    /// dates written loosely). Memories that don't say who or what they're about, or are too long to be one fact,
    /// are dropped.
    public static func parse(_ content: String, origin: BrainModel.Origin, now: Date = Date()) -> [BrainModel.Candidate] {
        let answer = ModelOutput.answer(content)
        var list: [[String: Any]] = []
        if let start = answer.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let end = answer.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end,
           let value = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) {
            if let object = value as? [String: Any] { list = object["memories"] as? [[String: Any]] ?? [] }
            else if let array = value as? [[String: Any]] { list = array }
        }
        let dates = DateFormatter()
        dates.dateFormat = "yyyy-MM-dd"
        dates.locale = Locale(identifier: "en_US_POSIX")
        return list.prefix(8).compactMap { entry -> BrainModel.Candidate? in
            let about = (entry["about"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (entry["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !about.isEmpty, text.count >= 8, text.count <= 280 else { return nil }
            var kind = BrainModel.EntityKind.read(entry["about_kind"] as? String ?? "")
            if ["me", "user", "the user", "myself"].contains(about.lowercased()) { kind = .me }
            let slot = (entry["slot"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            var expires = (entry["expires"] as? String).flatMap { dates.date(from: String($0.prefix(10))) }
            // A date already past isn't worth keeping as what's coming up.
            if let date = expires, date < now.addingTimeInterval(-86400) { expires = nil; if slot == nil { return nil } }
            if let date = expires { expires = date.addingTimeInterval(86400) }   // true through that day
            return BrainModel.Candidate(about: about, aboutKind: kind, text: text,
                                        kind: BrainModel.Kind.read(entry["kind"] as? String ?? ""), slot: slot,
                                        expires: expires, confidence: 0.6, origin: origin)
        }
    }
}
