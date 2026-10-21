//! Fits dictated text to where it lands, the way you'd type it there: a space before it when it follows a word, no
//! capital or full stop when it goes into the middle of a sentence, a capital when it starts one. The words themselves
//! are never changed, only spacing, the first letter's case and the final full stop. The Mac's TextFit
//! (Sources/AgentKit/TextFit.swift), rule for rule, with its tests; the text around the cursor comes from cursor.rs.

/// `text`: what was heard. `before`: the few characters just before the cursor (or the selection being replaced),
/// empty at the start. `after`: the few just after it, empty at the end. `is_word`: whether a lowercase word is an
/// ordinary dictionary word ("meeting" yes, "monday" or "shubham" no), so names keep their capital.
pub fn fit(text: &str, before: &str, after: &str, is_word: impl Fn(&str) -> bool) -> String {
    let mut out = text.trim().to_string();
    let Some(first) = out.chars().next() else { return text.to_string() };

    // Where the text starts: a new sentence (start of the field, a new line, after . ! ? …) or mid-sentence.
    let before_trimmed = before.trim_end_matches([' ', '\t']);
    let previous = before_trimmed.chars().last();
    let starts_sentence = match previous {
        None => true,
        Some(c) => c == '\n' || c == '\r' || ".!?…".contains(c),
    };
    let after_first = after.chars().next();
    let after_word = after.chars().find(|c| *c != ' ' && *c != '\t');

    if starts_sentence {
        if first.is_lowercase() && first.is_alphabetic() {
            out = first.to_uppercase().collect::<String>() + &out[first.len_utf8()..];
        }
    } else if let Some(previous) = previous {
        if previous.is_alphabetic() || previous.is_numeric() || ",;:-–—".contains(previous) {
            out = lowercasing_first_word(&out, &is_word);
        }
    }

    // A full stop at the end only belongs at the end of a sentence: not when more of it follows (a lowercase word, a
    // number, punctuation). A capital after it starts a new sentence, so the stop stays.
    if let Some(word) = after_word {
        if (word.is_lowercase() || word.is_numeric() || ",;:.!?".contains(word)) && out.ends_with('.') && !out.ends_with("..") {
            out.pop();
        }
    }

    // Spacing: a space after a word before the text, and between the text and a word right after it.
    if let (Some(last), Some(start)) = (before.chars().last(), out.chars().next()) {
        if !last.is_whitespace() && !"([{\"'“‘/@#$\n".contains(last) && !",.;:!?)]}”’%".contains(start) {
            out.insert(0, ' ');
        }
    }
    if let Some(c) = after_first {
        if c.is_alphabetic() || c.is_numeric() || "([{\"“".contains(c) {
            out.push(' ');
        }
    }
    out
}

/// "Tomorrow works" → "tomorrow works"; "I think", "Monday", "API", "iPhone" stay as they are.
fn lowercasing_first_word(text: &str, is_word: &impl Fn(&str) -> bool) -> String {
    let word: String = text.chars().take_while(|c| c.is_alphabetic() || *c == '\'' || *c == '’').collect();
    if word == "A" {
        return format!("a{}", &text[1..]);
    }
    let mut chars = word.chars();
    let Some(head) = chars.next() else { return text.to_string() };
    if word.chars().count() < 2 || !head.is_uppercase() || chars.any(|c| c.is_uppercase()) {
        return text.to_string();
    }
    let bare = word.split(['\'', '’']).next().unwrap_or(&word);
    if bare == "I" || !is_word(&bare.to_lowercase()) {
        return text.to_string();
    }
    head.to_lowercase().collect::<String>() + &text[head.len_utf8()..]
}

#[cfg(test)]
mod tests {
    // The Mac's TextFitTests, case for case.
    fn fit(text: &str, before: &str, after: &str) -> String {
        let words = ["tomorrow", "meeting", "works", "the", "we", "a", "and", "sounds", "good", "thanks"];
        super::fit(text, before, after, |w| words.contains(&w))
    }

    #[test]
    fn as_on_the_mac() {
        let cases = [
            ("Tomorrow works.", "", "", "Tomorrow works."),
            ("tomorrow works.", "ok. ", "", "Tomorrow works."),
            ("Tomorrow works.", "ok.", "", " Tomorrow works."),
            ("Tomorrow works.", "I think ", "", "tomorrow works."),
            ("Tomorrow works.", "I think", "", " tomorrow works."),
            ("Monday works.", "how about ", "", "Monday works."),
            ("I think so.", "and ", "", "I think so."),
            ("I'm in.", "and ", "", "I'm in."),
            ("API calls.", "the ", "", "API calls."),
            ("A meeting.", "we need ", "", "a meeting."),
            ("The meeting.", "", "and more", "The meeting "),
            ("The meeting.", "", " and more", "The meeting"),
            ("Sounds good.", "", " Thanks", "Sounds good."),
            ("Sounds good.", "Well ", ", thanks", "sounds good"),
            ("Sounds good.", "Well,", "", " sounds good."),
            ("tomorrow.", "Hi\n", "", "Tomorrow."),
            ("Sounds good.", "(", ")", "Sounds good."),
            ("And then...", "well ", "so", "and then... "),
            ("main kal aaunga.", "", "", "Main kal aaunga."),
            ("  ", "x", "", "  "),
        ];
        for (text, before, after, expected) in cases {
            assert_eq!(fit(text, before, after), expected, "{text:?} after {before:?}, before {after:?}");
        }
    }

    #[test]
    fn windows_line_ends_start_a_sentence() {
        assert_eq!(fit("tomorrow.", "Hi\r\n", ""), "Tomorrow.");
    }
}
