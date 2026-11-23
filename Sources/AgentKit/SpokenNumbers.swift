import Foundation

/// Numbers said as words, written as people write them: "version one point three" → "version 1.3", "twenty five
/// people" → "25 people", "ten percent" → "10%", "two thousand twenty six" → "2026", "fifty dollars" → "$50".
/// AI cleanup runs it before the model sees the text, so a version or an amount is never typed out in words, whatever
/// the model does.
///
/// Left alone on purpose: one to nine on their own in an ordinary sentence ("I have two kids", "one of them", "no
/// one"), unless something says they're a number ("version two", "page three", "five percent", "at five pm"); words
/// that only sound like numbers ("someone", "the point is"); anything not in English ("do", "ek").
public enum SpokenNumbers {
    /// The text with its spoken numbers in digits, where that's how they're written.
    public static func digits(_ text: String) -> String {
        convert(text, everything: false)
    }

    /// Every spoken number in digits, even "two" in "two kids": for comparing a model's reply with what was said (a
    /// model that wrote "2" didn't make up a word).
    public static func allDigits(_ text: String) -> String {
        convert(text, everything: true)
    }

    // MARK: The words

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "lakh": 100_000, "lakhs": 100_000, "million": 1_000_000,
        "crore": 10_000_000, "crores": 10_000_000, "billion": 1_000_000_000,
    ]

    /// Words before a number that say it's a number, not a word in a sentence ("version two", "page three").
    static let before: Set<String> = [
        "version", "v", "number", "page", "pages", "chapter", "step", "level", "room", "gate", "platform", "flight",
        "round", "season", "episode", "figure", "table", "item", "option", "slide", "ios", "macos", "android",
        "python", "swift", "node", "java", "iphone", "pixel", "galaxy", "rank", "grade", "phase", "sprint", "build",
        "release", "score",
    ]

    /// Words before a time: "at eleven thirty" → "at 11:30".
    static let beforeTime: Set<String> = ["at", "by", "till", "until", "around", "from", "before", "after", "since"]

    /// Words after a number that make it one, and how they're written after it ("ten percent" → "10%").
    static let after: [String: String] = [
        "percent": "%", "am": " am", "pm": " pm", "a.m": " am", "p.m": " pm", "gb": " GB", "mb": " MB", "tb": " TB",
        "kb": " KB", "ghz": " GHz", "mhz": " MHz", "kg": " kg", "km": " km", "cm": " cm", "mm": " mm", "ml": " ml",
        "fps": " fps", "hz": " Hz", "mp": " MP",
    ]

    /// Currencies after a number, written before it ("fifty dollars" → "$50").
    static let currency: [String: String] = [
        "dollar": "$", "dollars": "$", "rupee": "₹", "rupees": "₹", "euro": "€", "euros": "€", "pound": "£",
        "pounds": "£",
    ]

    // MARK: Reading a number

    /// The value of a word in a number ("twenty" → 20, "seven" → 7, "7" → 7, "twenty-five" → 25), or nil.
    static func value(_ word: String) -> Int? {
        if let u = units[word] { return u }
        if let t = tens[word] { return t }
        let parts = word.split(separator: "-").map(String.init)
        if parts.count == 2, let t = tens[parts[0]], let u = units[parts[1]], u > 0, u < 10 { return t + u }
        if !word.isEmpty, word.count <= 9, word.allSatisfy(\.isASCII), word.allSatisfy(\.isNumber) { return Int(word) }
        return nil
    }

    static func isNumberWord(_ word: String) -> Bool { value(word) != nil || scales[word] != nil }

    /// Number words as one whole number ("two thousand and twenty six" → 2026, "nineteen ninety nine" → 1999), or nil
    /// when they don't make one ("five six", "thousand").
    static func whole(_ words: [String]) -> Int? {
        let words = words.filter { $0 != "and" }
        guard let first = words.first, scales[first] == nil else { return nil }
        if let year = year(words) { return year }
        enum Kind { case none, unit, ten, scale }
        var total = 0, current = 0
        var last = Kind.none
        for word in words {
            if let scale = scales[word] {
                guard last != .none, last != .scale || scale > 100 else { return nil }
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
                last = .scale
                continue
            }
            guard let v = value(word) else { return nil }
            switch last {
            case .unit: return nil   // "five six": two numbers
            case .ten: guard v > 0, v < 10 else { return nil }
            case .none, .scale: break
            }
            current += v
            last = v >= 20 && v < 100 && v % 10 == 0 ? .ten : .unit
        }
        return total + current
    }

    /// A year said in two halves: "nineteen ninety nine" → 1999, "twenty twenty six" → 2026.
    private static func year(_ words: [String]) -> Int? {
        func half(_ w: ArraySlice<String>) -> Int? {
            if w.count == 1, let v = value(w.first!), v >= 10, v < 100 { return v }
            if w.count == 2, let t = tens[w.first!], let u = units[w.last!], u > 0, u < 10 { return t + u }
            return nil
        }
        guard (2...3).contains(words.count) else { return nil }
        for split in 1..<words.count {
            if let hi = half(words[..<split]), (19...20).contains(hi), let lo = half(words[split...]) {
                return hi * 100 + lo
            }
        }
        return nil
    }

    /// "eleven thirty" → "11:30", "nine oh five" isn't handled; nil when it isn't an hour and its minutes.
    static func time(_ words: [String]) -> String? {
        guard words.count >= 2, let hour = value(words[0]), (1...12).contains(hour), !words[0].allSatisfy(\.isNumber)
        else { return nil }
        let rest = Array(words.dropFirst())
        guard !rest.contains("point"), !rest.contains("and"), let minutes = whole(rest), (10...59).contains(minutes)
        else { return nil }
        return "\(hour):\(minutes)"
    }

    /// Number words, maybe with "point"s, as digits: "1.3", "1.3.2", "25"; nil when they don't make a number.
    static func written(_ words: [String]) -> String? {
        let parts = words.split(separator: "point", omittingEmptySubsequences: false).map(Array.init)
        guard let head = parts.first, !head.isEmpty, let whole = whole(head) else { return nil }
        var out = [String(whole)]
        for part in parts.dropFirst() {
            let digits = part.compactMap(value)
            guard !part.isEmpty, digits.count == part.count, digits.allSatisfy({ $0 < 10 }) else { return nil }
            out.append(digits.map(String.init).joined())
        }
        return out.joined(separator: ".")
    }

    // MARK: Converting

    /// A word of the text with the space before it, and the word as compared (lowercased, without punctuation round it).
    private struct Word {
        var space: String
        var text: String
        var bare: String { Self.bare(text) }
        static func bare(_ text: String) -> String {
            text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)
                .subtracting(CharacterSet(charactersIn: "-")))
        }
        /// Punctuation that ends a number: a comma, a full stop, a question mark.
        var stops: Bool { text.last.map { ",.;:!?)".contains($0) } ?? false }
    }

    private static func split(_ text: String) -> (words: [Word], tail: String) {
        var words: [Word] = []
        var space = "", word = ""
        for ch in text {
            if ch.isWhitespace {
                if !word.isEmpty { words.append(Word(space: space, text: word)); space = ""; word = "" }
                space.append(ch)
            } else {
                word.append(ch)
            }
        }
        if !word.isEmpty { words.append(Word(space: space, text: word)); space = "" }
        return (words, space)
    }

    private static func convert(_ text: String, everything: Bool) -> String {
        var (words, tail) = split(text)
        var i = 0
        while i < words.count {
            guard isNumberWord(words[i].bare), !words[i].bare.allSatisfy(\.isNumber) || i + 1 < words.count else {
                i += 1
                continue
            }
            // The longest stretch that could be one number: number words, "and" between them, "point" before a digit.
            var j = i
            while j < words.count {
                let bare = words[j].bare
                let nextIsDigit = j + 1 < words.count && value(words[j + 1].bare).map { $0 < 10 } == true
                let nextIsNumber = j + 1 < words.count && isNumberWord(words[j + 1].bare)
                guard isNumberWord(bare) || (bare == "point" && nextIsDigit && j > i)
                        || (bare == "and" && nextIsNumber && j > i) else { break }
                j += 1
                if words[j - 1].stops { break }
            }
            let previous = i > 0 ? words[i - 1].bare : nil
            // A time: "at eleven thirty" → "at 11:30", "eleven fifteen pm" → "11:15 pm".
            let afterRun = j < words.count ? words[j].bare : nil
            if let time = time(words[i..<j].map(\.bare)),
               previous.map(beforeTime.contains) == true || afterRun == "am" || afterRun == "pm" {
                let trail = String(words[j - 1].text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                words[i].text = String(words[i].text.prefix { !$0.isLetter && !$0.isNumber }) + time + trail
                for k in (i + 1)..<j { words[k].text = ""; words[k].space = "" }
                i = j
                continue
            }
            // The longest start of it that makes a number ("fifty and sixty": "fifty").
            var end = j
            var digits: String?
            while end > i {
                let run = words[i..<end].map(\.bare)
                if run.last != "and", run.last != "point", let made = written(run) { digits = made; break }
                end -= 1
            }
            // Two numbers said one after the other with nothing between ("eleven thirty", "nine eight four five"):
            // not one number, and not clear what they are, so left as said.
            if let _ = digits, end < j, isNumberWord(words[end].bare) {
                i = j
                continue
            }
            guard let digits else { i += 1; continue }
            let next = end < words.count ? words[end].bare : nil
            let unit = next.flatMap { after[$0] }, sign = next.flatMap { currency[$0] }
            // One to nine alone in a sentence stay words, unless something marks them as a number.
            let single = end - i == 1 && Int(digits).map { $0 < 10 } == true
            // A letter and a number are a name: "P two" → "P2", "v two" → "v2".
            if single, i > 0, let letter = words[i - 1].text.first, words[i - 1].text.count == 1,
               letter.isUppercase || letter == "v", !words[i].bare.allSatisfy(\.isNumber), end - i == 1 {
                let trail = String(words[i].text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                words[i - 1].text += digits + trail
                words[i].text = ""
                words[i].space = ""
                i = end
                continue
            }
            let marked = previous.map(before.contains) == true || unit != nil || sign != nil
            if single, !marked, !everything, !words[i].bare.allSatisfy(\.isNumber) {
                i = end
                continue
            }
            // What was round the words: an opening bracket or quote before, a comma or full stop after.
            let lead = String(words[i].text.prefix { !$0.isLetter && !$0.isNumber })
            let lastText = words[end - 1].text
            var trail = String(lastText.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            var made = lead + digits
            var used = end
            if trail.isEmpty, let marker = unit ?? sign {
                let unitText = words[end].text
                trail = String(unitText.reversed().prefix { !$0.isLetter && !$0.isNumber && $0 != "." }.reversed())
                if unitText.lowercased().hasSuffix("m.") { trail = String(trail.drop { $0 == "." }) }
                made = unit != nil ? lead + digits + marker : lead + marker + digits
                used = end + 1
            }
            words[i].text = made + trail
            for k in (i + 1)..<used { words[k].text = ""; words[k].space = "" }
            i = used
        }
        return words.filter { !$0.text.isEmpty || !$0.space.isEmpty }.map { $0.space + $0.text }.joined() + tail
    }
}
