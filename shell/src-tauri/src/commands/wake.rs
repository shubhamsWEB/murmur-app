//! "Murmur, …" at the start of what you said, however the speech model spelled it (the Mac's WakeName). Parakeet has
//! never heard the name, so it writes "Murmer", "Mermer", "Mur mur", "Marmar"…: anything close enough counts.

const NAME: &str = "murmur";
/// Spellings heard in testing that are too far from "murmur" for the distance rule.
const HEARD: &[&str] = &["murma", "merma", "mirmir", "mamur", "murmurs", "mermurs", "murmers", "mermers", "merman"];
/// Real words close to the name that start ordinary sentences.
const NOT_IT: &[&str] = &["murder", "murders", "murdered", "murmured", "murmuring", "mormon", "mirror"];

/// What you said after the name, when you started with it ("Murmer, summarise this" → "summarise this"); None when
/// you didn't address Murmur.
pub fn strip(text: &str) -> Option<String> {
    let lower = text.to_lowercase();
    let mut rest = lower.trim_start();
    // "Hey Murmur", "OK Murmur".
    for greeting in ["hey", "hi", "ok", "okay", "yo"] {
        if let Some(after) = rest.strip_prefix(greeting) {
            if after.starts_with(|c: char| c.is_whitespace() || ",.!".contains(c)) {
                rest = after.trim_start_matches(|c: char| c.is_whitespace() || ",.!".contains(c));
                break;
            }
        }
    }
    let first: String = rest.chars().take_while(|c| c.is_ascii_alphabetic()).collect();
    if first.is_empty() {
        return None;
    }
    let mut after = &rest[first.len()..];
    if !is_name(&first) {
        // "Mur mur", "Mer-mer": the name heard as two words.
        let gap = after.len() - after.trim_start_matches(|c: char| c.is_whitespace() || c == '-').len();
        let second: String = after[gap..].chars().take_while(|c| c.is_ascii_alphabetic()).collect();
        if gap == 0 || second.is_empty() || first.len() > 4 || !is_name(&format!("{first}{second}")) {
            return None;
        }
        after = &after[gap + second.len()..];
    }
    // Back to the original's letters (its capitals), from the same place, when lowercasing kept the lengths.
    let cut = text.len() - after.len();
    let rest = if lower.len() == text.len() && text.is_char_boundary(cut) { &text[cut..] } else { after };
    Some(rest.trim_matches(|c: char| c.is_whitespace() || ",.!?:;-".contains(c)).to_string())
}

fn is_name(word: &str) -> bool {
    if NOT_IT.contains(&word) {
        return false;
    }
    if word == NAME || HEARD.contains(&word) {
        return true;
    }
    word.starts_with('m') && (5..=8).contains(&word.len()) && distance(word, NAME) <= 2
}

/// Edit distance (insertions, deletions, substitutions).
fn distance(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut previous = row[0];
        row[0] = i;
        for j in 1..=b.len() {
            let saved = row[j];
            row[j] = (row[j] + 1).min(row[j - 1] + 1).min(previous + usize::from(a[i - 1] != b[j - 1]));
            previous = saved;
        }
    }
    row[b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addressed_to_murmur() {
        assert_eq!(strip("Murmur, summarise this").as_deref(), Some("summarise this"));
        assert_eq!(strip("Murmer open Spotify.").as_deref(), Some("open Spotify"));
        assert_eq!(strip("Hey Mermer, what's the time?").as_deref(), Some("what's the time"));
        assert_eq!(strip("Mur mur play music").as_deref(), Some("play music"));
        assert_eq!(strip("murmurs open notepad").as_deref(), Some("open notepad"));
        assert_eq!(strip("murder mystery night is on friday"), None);
        assert_eq!(strip("mirror the display"), None);
        assert_eq!(strip("open spotify"), None);
        assert_eq!(strip(""), None);
    }
}
