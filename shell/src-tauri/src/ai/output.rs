//! Takes a model's reasoning out of what it says, so you only ever see the answer (the Mac's ModelOutput).
//!
//! Ollama is asked not to think (`"think": false`), but an older Ollama, or a model that ignores the switch, still
//! writes its reasoning into the answer: `<think>…</think>` (Qwen3, DeepSeek-R1), a cut-off `<think>` with no end when
//! the answer hit its length cap mid-thought, or gpt-oss's analysis channel.

use regex::Regex;
use std::sync::OnceLock;

const TAGS: &str = "think|thinking|reasoning|thought|reflection";

fn regex(cell: &'static OnceLock<Regex>, pattern: impl FnOnce() -> String) -> &'static Regex {
    cell.get_or_init(|| Regex::new(&pattern()).expect("a valid pattern"))
}

/// The answer without the reasoning. Empty when there was only reasoning.
pub fn answer(raw: &str) -> String {
    static ANALYSIS: OnceLock<Regex> = OnceLock::new();
    static MARKS: OnceLock<Regex> = OnceLock::new();
    static END: OnceLock<Regex> = OnceLock::new();
    static START: OnceLock<Regex> = OnceLock::new();
    let mut text = raw.to_string();
    // gpt-oss (harmony format): keep the final channel when one is there.
    if let Some(at) = text.find("<|channel|>final<|message|>") {
        text = text[at + "<|channel|>final<|message|>".len()..].to_string();
    }
    // gpt-oss's analysis channel with no final one: reasoning only.
    text = regex(&ANALYSIS, || r"(?s)<\|channel\|>analysis<\|message\|>.*?(<\|end\|>|$)".into()).replace_all(&text, "").into();
    text = regex(&MARKS, || r"<\|[a-z_]+\|>".into()).replace_all(&text, "").into();
    // Whole reasoning blocks (the regex crate has no back-references: each tag pair in turn).
    for tag in TAGS.split('|') {
        let block = Regex::new(&format!(r"(?is)<{tag}>.*?</{tag}>")).expect("a valid pattern");
        text = block.replace_all(&text, "").into();
    }
    // An end tag with no start (the template opened the block): everything before it was reasoning.
    if let Some(last) = regex(&END, || format!(r"(?i)</({TAGS})>")).find_iter(&text).last() {
        text = text[last.end()..].to_string();
    }
    // A start tag with no end (cut off mid-thought): everything after it is reasoning.
    if let Some(start) = regex(&START, || format!(r"(?i)<({TAGS})>")).find(&text) {
        text = text[..start.start()].to_string();
    }
    text.trim().to_string()
}

/// Whether `raw` held reasoning at all (so an empty answer means "only reasoning", worth asking again).
pub fn had_reasoning(raw: &str) -> bool {
    static ANY: OnceLock<Regex> = OnceLock::new();
    regex(&ANY, || format!(r"(?i)</?({TAGS})>|<\|channel\|>")).is_match(raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reasoning_is_taken_out() {
        assert_eq!(answer("<think>let me see</think>\n\nOpen Slack."), "Open Slack.");
        assert_eq!(answer("<THINKING>a</THINKING>b<reasoning>c</reasoning>d"), "bd");
        assert_eq!(answer("reasoning first</think>The answer."), "The answer.");
        assert_eq!(answer("The answer.<think>cut off mid"), "The answer.");
        assert_eq!(answer("<think>only thinking"), "");
        assert_eq!(answer("<|channel|>analysis<|message|>hmm<|end|><|channel|>final<|message|>Hi there"), "Hi there");
        assert_eq!(answer("plain"), "plain");
        assert!(had_reasoning("<think>x</think>"));
        assert!(!had_reasoning("plain answer"));
    }
}
