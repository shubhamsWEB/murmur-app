//! Numbers said as words, written as people write them: "version one point three" → "version 1.3", "twenty five
//! people" → "25 people", "ten percent" → "10%", "two thousand twenty six" → "2026", "fifty dollars" → "$50". AI
//! cleanup runs it before the model sees the text, so a version or an amount is never typed out in words, whatever
//! the model does. The Mac's SpokenNumbers, rule for rule.
//!
//! Left alone on purpose: one to nine on their own in an ordinary sentence ("I have two kids", "one of them", "no
//! one"), unless something says they're a number ("version two", "page three", "five percent", "at five pm"); words
//! that only sound like numbers ("someone", "the point is"); anything not in English ("do", "ek").

/// The text with its spoken numbers in digits, where that's how they're written.
pub fn digits(text: &str) -> String {
    convert(text, false)
}

/// Every spoken number in digits, even "two" in "two kids": for comparing a model's reply with what was said (a model
/// that wrote "2" didn't make up a word).
pub fn all_digits(text: &str) -> String {
    convert(text, true)
}

// MARK: The words

fn unit(word: &str) -> Option<i64> {
    Some(match word {
        "zero" => 0, "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5, "six" => 6, "seven" => 7,
        "eight" => 8, "nine" => 9, "ten" => 10, "eleven" => 11, "twelve" => 12, "thirteen" => 13, "fourteen" => 14,
        "fifteen" => 15, "sixteen" => 16, "seventeen" => 17, "eighteen" => 18, "nineteen" => 19,
        _ => return None,
    })
}

fn ten(word: &str) -> Option<i64> {
    Some(match word {
        "twenty" => 20, "thirty" => 30, "forty" => 40, "fifty" => 50, "sixty" => 60, "seventy" => 70, "eighty" => 80,
        "ninety" => 90,
        _ => return None,
    })
}

fn scale(word: &str) -> Option<i64> {
    Some(match word {
        "hundred" => 100, "thousand" => 1_000, "lakh" | "lakhs" => 100_000, "million" => 1_000_000,
        "crore" | "crores" => 10_000_000, "billion" => 1_000_000_000,
        _ => return None,
    })
}

/// Words before a number that say it's a number, not a word in a sentence ("version two", "page three").
const BEFORE: &[&str] = &["version", "v", "number", "page", "pages", "chapter", "step", "level", "room", "gate",
                          "platform", "flight", "round", "season", "episode", "figure", "table", "item", "option",
                          "slide", "ios", "macos", "android", "python", "swift", "node", "java", "iphone", "pixel",
                          "galaxy", "rank", "grade", "phase", "sprint", "build", "release", "score"];

/// Words before a time: "at eleven thirty" → "at 11:30".
const BEFORE_TIME: &[&str] = &["at", "by", "till", "until", "around", "from", "before", "after", "since"];

/// Words after a number that make it one, and how they're written after it ("ten percent" → "10%").
fn after(word: &str) -> Option<&'static str> {
    Some(match word {
        "percent" => "%", "am" | "a.m" => " am", "pm" | "p.m" => " pm", "gb" => " GB", "mb" => " MB", "tb" => " TB",
        "kb" => " KB", "ghz" => " GHz", "mhz" => " MHz", "kg" => " kg", "km" => " km", "cm" => " cm", "mm" => " mm",
        "ml" => " ml", "fps" => " fps", "hz" => " Hz", "mp" => " MP",
        _ => return None,
    })
}

/// Currencies after a number, written before it ("fifty dollars" → "$50").
fn currency(word: &str) -> Option<&'static str> {
    Some(match word {
        "dollar" | "dollars" => "$", "rupee" | "rupees" => "₹", "euro" | "euros" => "€", "pound" | "pounds" => "£",
        _ => return None,
    })
}

// MARK: Reading a number

fn all_digit_chars(word: &str) -> bool {
    word.chars().all(|c| c.is_numeric())
}

/// The value of a word in a number ("twenty" → 20, "seven" → 7, "7" → 7, "twenty-five" → 25), or None.
fn value(word: &str) -> Option<i64> {
    if let Some(u) = unit(word) {
        return Some(u);
    }
    if let Some(t) = ten(word) {
        return Some(t);
    }
    let parts: Vec<&str> = word.split('-').filter(|p| !p.is_empty()).collect();
    if parts.len() == 2 {
        if let (Some(t), Some(u)) = (ten(parts[0]), unit(parts[1])) {
            if u > 0 && u < 10 {
                return Some(t + u);
            }
        }
    }
    if !word.is_empty() && word.len() <= 9 && word.chars().all(|c| c.is_ascii_digit()) {
        return word.parse().ok();
    }
    None
}

fn is_number_word(word: &str) -> bool {
    value(word).is_some() || scale(word).is_some()
}

/// Number words as one whole number ("two thousand and twenty six" → 2026, "nineteen ninety nine" → 1999), or None
/// when they don't make one ("five six", "thousand").
fn whole(words: &[&str]) -> Option<i64> {
    #[derive(PartialEq, Clone, Copy)]
    enum Kind { None, Unit, Ten, Scale }
    let words: Vec<&str> = words.iter().copied().filter(|w| *w != "and").collect();
    let first = words.first()?;
    if scale(first).is_some() {
        return None;
    }
    if let Some(year) = year(&words) {
        return Some(year);
    }
    let (mut total, mut current, mut last) = (0i64, 0i64, Kind::None);
    for word in &words {
        if let Some(scale) = scale(word) {
            if last == Kind::None || (last == Kind::Scale && scale <= 100) {
                return None;
            }
            if scale == 100 {
                current = current.max(1) * 100;
            } else {
                total += current.max(1) * scale;
                current = 0;
            }
            last = Kind::Scale;
            continue;
        }
        let v = value(word)?;
        match last {
            Kind::Unit => return None, // "five six": two numbers
            Kind::Ten if !(v > 0 && v < 10) => return None,
            _ => {}
        }
        current += v;
        last = if (20..100).contains(&v) && v % 10 == 0 { Kind::Ten } else { Kind::Unit };
    }
    Some(total + current)
}

/// A year said in two halves: "nineteen ninety nine" → 1999, "twenty twenty six" → 2026.
fn year(words: &[&str]) -> Option<i64> {
    fn half(w: &[&str]) -> Option<i64> {
        match w {
            [one] => value(one).filter(|v| (10..100).contains(v)),
            [t, u] => match (ten(t), unit(u)) {
                (Some(t), Some(u)) if u > 0 && u < 10 => Some(t + u),
                _ => None,
            },
            _ => None,
        }
    }
    if !(2..=3).contains(&words.len()) {
        return None;
    }
    for split in 1..words.len() {
        if let Some(hi) = half(&words[..split]).filter(|hi| (19..=20).contains(hi)) {
            if let Some(lo) = half(&words[split..]) {
                return Some(hi * 100 + lo);
            }
        }
    }
    None
}

/// "eleven thirty" → "11:30"; None when it isn't an hour and its minutes.
fn time(words: &[&str]) -> Option<String> {
    if words.len() < 2 {
        return None;
    }
    let hour = value(words[0]).filter(|h| (1..=12).contains(h))?;
    if all_digit_chars(words[0]) {
        return None;
    }
    let rest = &words[1..];
    if rest.contains(&"point") || rest.contains(&"and") {
        return None;
    }
    let minutes = whole(rest).filter(|m| (10..=59).contains(m))?;
    Some(format!("{hour}:{minutes}"))
}

/// Number words, maybe with "point"s, as digits: "1.3", "1.3.2", "25"; None when they don't make a number.
fn written(words: &[&str]) -> Option<String> {
    let mut parts = words.split(|w| *w == "point");
    let head = parts.next().filter(|head| !head.is_empty())?;
    let mut out = vec![whole(head)?.to_string()];
    for part in parts {
        let digits: Vec<i64> = part.iter().filter_map(|w| value(w)).collect();
        if part.is_empty() || digits.len() != part.len() || digits.iter().any(|d| *d >= 10) {
            return None;
        }
        out.push(digits.iter().map(i64::to_string).collect());
    }
    Some(out.join("."))
}

// MARK: Converting

/// A word of the text with the space before it.
struct Word {
    space: String,
    text: String,
}

impl Word {
    /// The word as compared: lowercased, without the punctuation round it (a hyphen stays: "twenty-five").
    fn bare(&self) -> String {
        self.text.to_lowercase().trim_matches(|c: char| !c.is_alphanumeric() && c != '-').to_string()
    }
    /// Punctuation that ends a number: a comma, a full stop, a question mark.
    fn stops(&self) -> bool {
        self.text.chars().last().is_some_and(|c| ",.;:!?)".contains(c))
    }
    fn clear(&mut self) {
        self.text.clear();
        self.space.clear();
    }
}

/// What's before the first letter or digit of `text` (an opening bracket or quote).
fn lead(text: &str) -> String {
    text.chars().take_while(|c| !c.is_alphanumeric()).collect()
}

/// What's after the last letter or digit of `text` (a comma or full stop), without `also` stopping it.
fn trail(text: &str, also: Option<char>) -> String {
    let reversed: Vec<char> = text.chars().rev().take_while(|c| !c.is_alphanumeric() && Some(*c) != also).collect();
    reversed.into_iter().rev().collect()
}

fn split(text: &str) -> (Vec<Word>, String) {
    let mut words = Vec::new();
    let (mut space, mut word) = (String::new(), String::new());
    for ch in text.chars() {
        if ch.is_whitespace() {
            if !word.is_empty() {
                words.push(Word { space: std::mem::take(&mut space), text: std::mem::take(&mut word) });
            }
            space.push(ch);
        } else {
            word.push(ch);
        }
    }
    if !word.is_empty() {
        words.push(Word { space: std::mem::take(&mut space), text: word });
    }
    (words, space)
}

fn convert(text: &str, everything: bool) -> String {
    let (mut words, tail) = split(text);
    let mut i = 0;
    while i < words.len() {
        let bare_i = words[i].bare();
        if !is_number_word(&bare_i) || (all_digit_chars(&bare_i) && i + 1 >= words.len()) {
            i += 1;
            continue;
        }
        // The longest stretch that could be one number: number words, "and" between them, "point" before a digit.
        let mut j = i;
        while j < words.len() {
            let bare = words[j].bare();
            let next = words.get(j + 1).map(Word::bare);
            let next_is_digit = next.as_deref().and_then(value).is_some_and(|v| v < 10);
            let next_is_number = next.as_deref().is_some_and(is_number_word);
            if !(is_number_word(&bare) || (bare == "point" && next_is_digit && j > i)
                || (bare == "and" && next_is_number && j > i)) {
                break;
            }
            j += 1;
            if words[j - 1].stops() {
                break;
            }
        }
        let bares: Vec<String> = words[i..j].iter().map(Word::bare).collect();
        let run = |end: usize| -> Vec<&str> { bares[..end - i].iter().map(String::as_str).collect() };
        let previous = if i > 0 { Some(words[i - 1].bare()) } else { None };
        let marked_before = |list: &[&str]| previous.as_deref().is_some_and(|p| list.contains(&p));
        // A time: "at eleven thirty" → "at 11:30", "eleven fifteen pm" → "11:15 pm".
        let after_run = words.get(j).map(Word::bare);
        if let Some(time) = time(&run(j)) {
            if marked_before(BEFORE_TIME) || matches!(after_run.as_deref(), Some("am") | Some("pm")) {
                let made = lead(&words[i].text) + &time + &trail(&words[j - 1].text, None);
                words[i].text = made;
                for word in &mut words[i + 1..j] {
                    word.clear();
                }
                i = j;
                continue;
            }
        }
        // The longest start of it that makes a number ("fifty and sixty": "fifty").
        let mut end = j;
        let mut digits: Option<String> = None;
        while end > i {
            let run = run(end);
            if !matches!(run.last(), Some(&"and") | Some(&"point")) {
                if let Some(made) = written(&run) {
                    digits = Some(made);
                    break;
                }
            }
            end -= 1;
        }
        // Two numbers said one after the other with nothing between ("eleven thirty", "nine eight four five"): not
        // one number, and not clear what they are, so left as said.
        if digits.is_some() && end < j && is_number_word(&words[end].bare()) {
            i = j;
            continue;
        }
        let Some(digits) = digits else {
            i += 1;
            continue;
        };
        let next = words.get(end).map(Word::bare);
        let unit = next.as_deref().and_then(after);
        let sign = next.as_deref().and_then(currency);
        // One to nine alone in a sentence stay words, unless something marks them as a number.
        let said_in_words = !all_digit_chars(&bare_i);
        let single = end - i == 1 && digits.parse::<i64>().is_ok_and(|v| v < 10);
        // A letter and a number are a name: "P two" → "P2", "v two" → "v2".
        if single && i > 0 && said_in_words {
            let before: Vec<char> = words[i - 1].text.chars().collect();
            if before.len() == 1 && (before[0].is_uppercase() || before[0] == 'v') {
                let made = format!("{digits}{}", trail(&words[i].text, None));
                words[i - 1].text.push_str(&made);
                words[i].clear();
                i = end;
                continue;
            }
        }
        let marked = marked_before(BEFORE) || unit.is_some() || sign.is_some();
        if single && !marked && !everything && said_in_words {
            i = end;
            continue;
        }
        // What was round the words: an opening bracket or quote before, a comma or full stop after.
        let lead = lead(&words[i].text);
        let mut after_it = trail(&words[end - 1].text, None);
        let mut made = format!("{lead}{digits}");
        let mut used = end;
        if after_it.is_empty() {
            if let Some(marker) = unit.or(sign) {
                let unit_text = words[end].text.clone();
                after_it = trail(&unit_text, Some('.'));
                if unit_text.to_lowercase().ends_with("m.") {
                    after_it = after_it.trim_start_matches('.').to_string();
                }
                made = if unit.is_some() { format!("{lead}{digits}{marker}") } else { format!("{lead}{marker}{digits}") };
                used = end + 1;
            }
        }
        words[i].text = made + &after_it;
        for word in &mut words[i + 1..used] {
            word.clear();
        }
        i = used;
    }
    words.iter().filter(|w| !w.text.is_empty() || !w.space.is_empty()).map(|w| format!("{}{}", w.space, w.text))
        .collect::<String>() + &tail
}

#[cfg(test)]
mod tests {
    // The Mac's SpokenNumbersTests, case for case.
    use super::*;

    #[test]
    fn versions_and_decimals() {
        assert_eq!(digits("complete all the tasks in the version one point three"), "complete all the tasks in the version 1.3");
        assert_eq!(digits("Version one point three."), "Version 1.3.");
        assert_eq!(digits("upgrade to two point one point four today"), "upgrade to 2.1.4 today");
        assert_eq!(digits("it went up by zero point five"), "it went up by 0.5");
        assert_eq!(digits("ship version two next week"), "ship version 2 next week");
        assert_eq!(digits("Murmur one point nine point zero is out"), "Murmur 1.9.0 is out");
    }

    #[test]
    fn bigger_numbers_and_years() {
        assert_eq!(digits("we have twenty five people"), "we have 25 people");
        assert_eq!(digits("about three hundred and fifty users"), "about 350 users");
        assert_eq!(digits("in two thousand twenty six"), "in 2026");
        assert_eq!(digits("since nineteen ninety nine"), "since 1999");
        assert_eq!(digits("by twenty twenty seven"), "by 2027");
        assert_eq!(digits("it costs five lakh rupees"), "it costs ₹500000");
        assert_eq!(digits("ten people came"), "10 people came");
        assert_eq!(digits("twenty-five minutes"), "25 minutes");
    }

    #[test]
    fn units_currency_and_times() {
        assert_eq!(digits("a ten percent discount"), "a 10% discount");
        assert_eq!(digits("growth of five percent, not more"), "growth of 5%, not more");
        assert_eq!(digits("it's fifty dollars"), "it's $50");
        assert_eq!(digits("meet at five pm"), "meet at 5 pm");
        assert_eq!(digits("sixteen gb of memory"), "16 GB of memory");
        assert_eq!(digits("open page three"), "open page 3");
    }

    #[test]
    fn words_that_stay_words() {
        for text in ["I have two kids", "one of them said no", "no one came", "someone said it", "the point is we ship",
                     "that's a fine point", "one more thing", "do it once", "kal file bhej dena",
                     "Let's meet at 5, no, 6pm.", "a thousand thanks", "one or two of us", "between three and four", ""] {
            assert_eq!(digits(text), text);
        }
    }

    #[test]
    fn two_numbers_side_by_side_stay_separate() {
        assert_eq!(digits("fifty and sixty"), "50 and 60");
        assert_eq!(digits("five six seven"), "five six seven");
    }

    #[test]
    fn times_and_names() {
        assert_eq!(digits("call me at eleven thirty"), "call me at 11:30");
        assert_eq!(digits("let's start by nine fifteen pm"), "let's start by 9:15 pm");
        assert_eq!(digits("eleven thirty is fine"), "eleven thirty is fine");
        assert_eq!(digits("Start with P two P one and then the rest"), "Start with P2 P1 and then the rest");
        assert_eq!(digits("call me on nine eight four five"), "call me on nine eight four five");
        assert_eq!(digits("four by four"), "four by four");
    }

    #[test]
    fn everything_for_comparing() {
        assert_eq!(all_digits("I have two kids"), "I have 2 kids");
        assert_eq!(all_digits("version one point three"), "version 1.3");
    }

    #[test]
    fn spacing_and_punctuation_are_kept() {
        assert_eq!(digits("Total: twenty five, then thirty."), "Total: 25, then 30.");
        assert_eq!(digits("(version one point two)"), "(version 1.2)");
        assert_eq!(digits("line one\nversion two point zero\n"), "line one\nversion 2.0\n");
    }
}
