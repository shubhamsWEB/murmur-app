//! The text side of meeting notes, as the Mac's MeetingText.swift: telling a question from a statement, finding your
//! microphone's echo of the call, the transcript and the meeting's context as the AI reads them, and an answer split
//! into what to say (its headline, points, example, code and extras) as it streams in.

use serde::Serialize;
use std::collections::HashSet;

/// Who said a line: the other side (the call's sound) or you (your microphone).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum Speaker {
    You,
    Them,
}

impl Speaker {
    pub fn name(self) -> &'static str {
        match self {
            Speaker::You => "You",
            Speaker::Them => "Them",
        }
    }
}

/// One line of a meeting's transcript: what one side said in one stretch of speech (or one person's turn in it).
/// `at` and `end`: seconds since 1970.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Line {
    pub id: u64,
    pub speaker: Speaker,
    pub text: String,
    pub at: f64,
    pub end: f64,
    /// Who it's shown as: "You", a name, "Speaker 2", or "Them" (speakers.rs).
    pub who: String,
    /// Which of the call's voices said it (1, 2… as the meeting's voices are grouped now); None: not told apart.
    pub voice: Option<u32>,
    /// Its voiceprint's place in the meeting's grouping (voices.rs), which `voice` is read from as the grouping changes.
    #[serde(skip)]
    pub stretch: Option<usize>,
}

impl Line {
    pub fn new(id: u64, speaker: Speaker, text: impl Into<String>, at: f64, end: f64) -> Line {
        Line { id, speaker, text: text.into(), at, end: end.max(at), who: speaker.name().into(), voice: None, stretch: None }
    }
}

/// Whether a line asks something, so Murmur drafts an answer: a question mark (the speech models write them), or a
/// sentence that opens the way a question does ("what…", "can you…", "tell me about…"), or a request ("write…").
pub fn is_question(text: &str) -> bool {
    let words: Vec<&str> = text.split_whitespace().collect();
    if words.len() < 3 {
        return false;
    }
    if text.contains('?') {
        return true;
    }
    // The last sentence decides: "We shipped it. How did that go" asks; "How it went is fine." doesn't.
    let last_sentence = text.split(['.', '!']).rfind(|s| !s.trim().is_empty()).unwrap_or(text);
    let mut last: Vec<String> = last_sentence.trim().to_lowercase().split_whitespace().map(String::from).collect();
    const LEAD_INS: [&str; 24] = ["so", "and", "okay", "ok", "alright", "right", "well", "now", "then", "um", "uh", "hmm",
                                  "also", "but", "great", "cool", "nice", "yeah", "yes", "sure", "anyway", "actually",
                                  "please", "just"];
    while last.len() > 3 && LEAD_INS.contains(&bare(&last[0]).as_str()) {
        last.remove(0);
    }
    if last.len() < 3 {
        return false;
    }
    let joined = last.join(" ");
    if PHRASES.iter().any(|phrase| joined.contains(phrase)) {
        return true;
    }
    // A request: "Write factorial in Python", "Please explain the cache", "Show me the query".
    let opener = last.iter().map(|w| bare(w))
        .find(|w| !["please", "so", "okay", "ok", "now", "and", "then", "just"].contains(&w.as_str()))
        .unwrap_or_default();
    if REQUESTS.contains(&opener.as_str()) {
        return true;
    }
    let first = bare(&last[0]);
    let second = bare(&last[1]);
    if WH.contains(&first.as_str()) {
        // "What we did was…" is a statement: a question word followed by a subject and no auxiliary.
        return AUXILIARIES.contains(&second.as_str())
            || ["much", "many", "long", "often", "far", "about", "if"].contains(&second.as_str());
    }
    if AUXILIARIES.contains(&first.as_str()) {
        // "Can you…", "Is there…", "Do you…": an auxiliary first and a subject after it.
        return SUBJECTS.contains(&second.as_str());
    }
    false
}

/// A word without the punctuation around it.
fn bare(word: &str) -> String {
    word.trim_matches(|c: char| c.is_ascii_punctuation() && c != '\'').to_string()
}

const REQUESTS: [&str; 26] = ["write", "implement", "code", "explain", "describe", "show", "give", "list", "design", "build",
                              "create", "solve", "find", "calculate", "compare", "define", "walk", "outline", "summarize",
                              "summarise", "optimize", "debug", "fix", "reverse", "sort", "convert"];
const WH: [&str; 12] = ["what", "what's", "how", "how's", "why", "when", "where", "who", "who's", "which", "whom", "whose"];
const AUXILIARIES: [&str; 26] = ["is", "are", "was", "were", "do", "does", "did", "can", "could", "would", "will", "should",
                                 "shall", "have", "has", "had", "may", "might", "am", "isn't", "aren't", "don't", "doesn't",
                                 "didn't", "can't", "won't"];
const SUBJECTS: [&str; 15] = ["you", "we", "they", "he", "she", "it", "i", "there", "this", "that", "your", "the", "anyone",
                              "someone", "everyone"];
const PHRASES: [&str; 13] = ["tell me about", "tell me how", "walk me through", "can you explain", "explain how",
                             "explain why", "what do you think", "your thoughts on", "how would you", "talk me through",
                             "take me through", "describe how", "describe a time"];

/// Whether `mine` (from your microphone) is the call's sound picked up again, on speakers rather than headphones: the
/// same words in the same order, heard at the same moment (`apart`: seconds between the two). A reply that takes up
/// their words ("Can you share the pricing sheet?" / "Yes, I'll share the pricing sheet") is you speaking.
pub fn is_echo(mine: &str, theirs: &str, apart: f64) -> bool {
    if apart.abs() > ECHO_SLACK {
        return false;
    }
    let (a, b) = (sequence(mine), sequence(theirs));
    if a.len() < 3 || b.len() < 3 {
        return false;
    }
    in_order(&a, &b) as f64 / a.len().max(b.len()) as f64 >= 0.75
}

/// How much of `mine` is found in `theirs`, 0…1, in word pairs: the microphone hears the speakers worse than the call
/// is heard, and cuts it elsewhere, so a whole-line comparison misses some echoes. From Cicada's `EchoMatch`
/// (github.com/wquguru/cicada, Apache-2.0, © wquguru); a single word counts as itself.
pub fn contained(mine: &str, theirs: &[&str]) -> f64 {
    let a = pairs(&sequence(mine));
    if a.len() < 2 {
        return 0.0;
    }
    let b: HashSet<String> = theirs.iter().flat_map(|line| pairs(&sequence(line))).collect();
    a.iter().filter(|pair| b.contains(*pair)).count() as f64 / a.len() as f64
}

/// Echo by containment: at least this share of your line is in what they said around then.
pub const CONTAINED_ECHO: f64 = 0.6;
/// The echo comes back within this long of the call playing it.
pub const ECHO_SLACK: f64 = 6.0;
/// In a line that's partly yours, one sentence is the call's only when it's this long (words) and this much of it is
/// theirs.
const ECHO_SENTENCE_WORDS: usize = 6;
const ECHO_SENTENCE: f64 = 0.8;
/// In a line that's mostly the call, a sentence is yours when it's this long and no more than this much of it is
/// theirs (a sentence of the call the microphone misheard still shares more than that)…
const YOURS_WORDS: usize = 3;
const YOURS_SHARE: f64 = 0.2;
/// …and fewer than this share of its words are in what they said at all.
const YOURS_WORDS_SHARE: f64 = 0.6;

/// The other side's lines being said while `line` was: their time overlaps its, give or take `ECHO_SLACK`. A
/// microphone that hears the speakers doesn't cut where the call does (in a room it rarely hears a pause, so its
/// stretches run long), so one of your lines can cover several of theirs.
pub fn during<'a>(line: &Line, lines: &'a [Line]) -> Vec<&'a Line> {
    let (from, to) = (line.at - ECHO_SLACK, line.end + ECHO_SLACK);
    lines.iter().filter(|l| l.speaker == Speaker::Them && l.end >= from && l.at <= to).collect()
}

/// What's left of `mine` (what your microphone heard) once the call's own words are taken out, given what they said
/// meanwhile: None when it's all the call; otherwise your words, without the sentences that are the call's.
///
/// Mostly the call (the same words in order as one of their lines, or most of its word pairs found in theirs): only
/// sentences with next to nothing of theirs in them are yours ("Sorry, can I jump in?" said over the speakers).
/// Mostly yours: only a long sentence that's nearly all theirs goes, because answering someone often repeats their
/// words ("Yes, I'll share the pricing sheet"). As the Mac's `MeetingText.withoutEcho`.
pub fn without_echo(mine: &str, theirs: &[&str]) -> Option<String> {
    if theirs.is_empty() {
        return Some(mine.to_string());
    }
    if theirs.iter().any(|line| is_echo(mine, line, 0.0)) {
        return None;
    }
    let share = contained(mine, theirs);
    if share <= 0.0 {
        return Some(mine.to_string());
    }
    let mostly = share >= CONTAINED_ECHO;
    let sentences = sentences(mine);
    if sentences.len() <= 1 {
        return (!mostly).then(|| mine.to_string());
    }
    let kept: Vec<&String> = sentences.iter().filter(|sentence| {
        let (words, found) = (sequence(sentence).len(), contained(sentence, theirs));
        if mostly {
            words >= YOURS_WORDS && found <= YOURS_SHARE && words_found(sentence, theirs) < YOURS_WORDS_SHARE
        } else {
            words < ECHO_SENTENCE_WORDS || found < ECHO_SENTENCE
        }
    }).collect();
    if kept.len() == sentences.len() {
        return Some(mine.to_string());
    }
    let rest = kept.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(" ");
    is_worth_keeping(&rest).then_some(rest)
}

/// The share of `mine`'s words found anywhere in `theirs`.
fn words_found(mine: &str, theirs: &[&str]) -> f64 {
    let words = sequence(mine);
    if words.is_empty() {
        return 0.0;
    }
    let said: HashSet<String> = theirs.iter().flat_map(|line| sequence(line)).collect();
    words.iter().filter(|word| said.contains(*word)).count() as f64 / words.len() as f64
}

fn pairs(words: &[String]) -> Vec<String> {
    if words.len() < 2 {
        return words.to_vec();
    }
    words.windows(2).map(|pair| format!("{} {}", pair[0], pair[1])).collect()
}

fn sequence(text: &str) -> Vec<String> {
    text.to_lowercase().split(|c: char| !c.is_alphanumeric() && c != '\'').filter(|w| !w.is_empty()).map(String::from).collect()
}

/// How many words the two have in the same order (the longest common subsequence).
fn in_order(a: &[String], b: &[String]) -> usize {
    let mut row = vec![0usize; b.len() + 1];
    for x in a {
        let mut diagonal = 0;
        for (j, y) in b.iter().enumerate() {
            let above = row[j + 1];
            row[j + 1] = if x == y { diagonal + 1 } else { row[j + 1].max(row[j]) };
            diagonal = above;
        }
    }
    row[b.len()]
}

/// "14:05" for seconds since 1970, in this PC's time.
pub fn clock(at: f64) -> String {
    let local = at + local_offset();
    let minutes = (local / 60.0).floor() as i64;
    format!("{:02}:{:02}", minutes.div_euclid(60).rem_euclid(24), minutes.rem_euclid(60))
}

/// "14:05:09".
pub fn clock_seconds(at: f64) -> String {
    let local = (at + local_offset()).floor() as i64;
    format!("{:02}:{:02}:{:02}", local.div_euclid(3600).rem_euclid(24), local.div_euclid(60).rem_euclid(60), local.rem_euclid(60))
}

/// This PC's offset from UTC, in seconds.
pub fn local_offset() -> f64 {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::Time::{GetTimeZoneInformation, TIME_ZONE_INFORMATION};
        let mut zone: TIME_ZONE_INFORMATION = std::mem::zeroed();
        let mode = GetTimeZoneInformation(&mut zone);
        // 2: daylight saving time is on.
        let bias = zone.Bias + if mode == 2 { zone.DaylightBias } else { zone.StandardBias };
        return -(bias as f64) * 60.0;
    }
    #[cfg(not(windows))]
    0.0
}

/// The transcript as the AI reads it, newest last, cut from the start to fit `limit` characters.
pub fn transcript<'a>(lines: impl DoubleEndedIterator<Item = &'a Line>, limit: usize) -> String {
    let mut kept: Vec<String> = Vec::new();
    let mut total = 0;
    for line in lines.rev() {
        let row = format!("[{}] {}: {}", clock(line.at), line.who, line.text);
        let size = row.chars().count() + 1;
        if total + size > limit {
            break;
        }
        total += size;
        kept.push(row);
    }
    kept.reverse();
    kept.join("\n")
}

/// What the AI knows about the meeting besides what's said: what it's about, your instructions, and your documents'
/// text, cut to `limit` characters (documents share what's left after the rest, in order).
pub fn context(about: &str, instructions: &str, documents: &[(String, String)], limit: usize) -> String {
    let mut parts: Vec<String> = Vec::new();
    if !about.trim().is_empty() {
        parts.push(format!("About this meeting: {}", about.trim()));
    }
    if !instructions.trim().is_empty() {
        parts.push(format!("The user's instructions: {}", instructions.trim()));
    }
    let mut room = limit as i64 - parts.iter().map(|p| p.chars().count() as i64 + 2).sum::<i64>();
    for (index, (name, text)) in documents.iter().enumerate() {
        if room <= 200 {
            break;
        }
        let share = room / (documents.len() - index) as i64;
        let text = text.trim();
        let budget = share - name.chars().count() as i64 - 40;
        let kept = if text.chars().count() as i64 > budget {
            format!("{} […]", text.chars().take((share - name.chars().count() as i64 - 60).max(0) as usize).collect::<String>())
        } else {
            text.to_string()
        };
        let part = format!("Document \"{name}\":\n{kept}");
        room -= part.chars().count() as i64 + 2;
        parts.push(part);
    }
    parts.join("\n\n")
}

/// A block of code in an answer: its language ("python") and the code.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Code {
    pub language: String,
    pub text: String,
}

/// An answer as it's read out loud: the headline, the points that complete it, an example, code, and extras.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Spoken {
    pub headline: Option<String>,
    pub points: Vec<String>,
    pub example: Option<String>,
    /// What to say, a sentence at a time (an answer in the older "SAY: …" shape, or plain text).
    pub say: Vec<String>,
    pub also: Vec<String>,
    pub code: Vec<Code>,
}

#[derive(Clone, Copy, PartialEq)]
enum Section {
    None,
    Say,
    Headline,
    Points,
    Example,
    Also,
}

/// An answer as it's read out. The model is asked for "ANSWER: … POINTS: - … EXAMPLE: … CODE: ``` … ALSO: - …";
/// Markdown (bold labels, "Answer:", "You could also say:") and plain text are read too, and a half-written answer
/// (still streaming) splits the same way.
pub fn spoken(text: &str) -> Spoken {
    // Code first: fenced blocks (a block still being written counts), taken out of what's said.
    let mut code: Vec<Code> = Vec::new();
    let mut prose: Vec<&str> = Vec::new();
    let mut block: Option<Code> = None;
    for raw in text.lines() {
        let trimmed = raw.trim();
        if let Some(language) = trimmed.strip_prefix("```") {
            match block.take() {
                Some(open) => code.push(open),
                None => block = Some(Code { language: language.trim().to_lowercase(), text: String::new() }),
            }
            continue;
        }
        if let Some(open) = block.as_mut() {
            if !open.text.is_empty() {
                open.text.push('\n');
            }
            open.text.push_str(raw);
        } else if !["code:", "code"].contains(&trimmed.to_lowercase().as_str()) {
            prose.push(raw);
        }
    }
    if let Some(open) = block {
        if !open.text.is_empty() {
            code.push(open);
        }
    }
    let labels: [(Section, &[&str]); 5] = [
        (Section::Headline, &["answer:", "answer"]),
        (Section::Say, &["say:", "say"]),
        (Section::Points, &["points:", "key points:", "points", "key points"]),
        (Section::Example, &["example:", "for example:", "example"]),
        (Section::Also, &["also:", "you could also say:", "you could also say", "also"]),
    ];
    let mut section = Section::None;
    let (mut say, mut also, mut points, mut headline, mut example) = (vec![], vec![], vec![], vec![], vec![]);
    for raw in prose {
        let line = raw.trim().trim_start_matches('#').trim().to_string();
        if line.is_empty() {
            continue;
        }
        // Labels are read without their bold ("**Answer:**"); the text keeps it, for key words.
        let plain = line.replace("**", "").replace("__", "");
        let lower = plain.to_lowercase();
        let found = labels.iter().find_map(|(kind, names)| label(&lower, &line, names).map(|rest| (*kind, rest)));
        if let Some((kind, rest)) = found {
            section = kind;
            if rest.is_empty() {
                continue;
            }
            let rest = bullet(&rest).unwrap_or(rest);
            match kind {
                Section::Headline => headline.push(rest),
                Section::Say => say.push(rest),
                Section::Points => points.push(rest),
                Section::Example => example.push(rest),
                Section::Also | Section::None => also.push(rest),
            }
            continue;
        }
        let item = bullet(&line);
        match section {
            Section::Also => also.push(item.unwrap_or(line)),
            Section::Points => points.push(item.unwrap_or(line)),
            Section::Example => example.push(item.unwrap_or(line)),
            // Bullets under the answer are its points.
            Section::Headline => match item {
                Some(item) => {
                    points.push(item);
                    section = Section::Points;
                }
                None => headline.push(line),
            },
            // Bullets after what to say are extra points (the older shape).
            Section::Say => match item {
                Some(item) => also.push(item),
                None => say.push(line),
            },
            Section::None => match item {
                Some(item) => points.push(item),
                None => say.push(line),
            },
        }
    }
    let head = headline.join(" ");
    let instance = example.join(" ");
    Spoken {
        say: sentences(&say.join(" ").replace("**", "")),
        also: also.into_iter().map(|a| a.replace("**", "")).collect(),
        code,
        headline: (!head.is_empty()).then_some(head),
        points,
        example: (!instance.is_empty()).then_some(instance),
    }
}

/// The text after a label that starts the line ("SAY: …", "**Answer:** …"), or None. `lower` is the line without
/// its bold, lowercased; what's returned is from `line` itself, so bold key words in it stay.
fn label(lower: &str, line: &str, labels: &[&str]) -> Option<String> {
    let bare = line.trim_start_matches(['*', '_']);
    for label in labels {
        if !lower.starts_with(label) || !bare.to_lowercase().starts_with(label) {
            continue;
        }
        let rest = &bare[label.len()..];
        let after = rest.trim_start_matches(['*', '_']);
        // "Answer" alone, or followed by ":" — not "Answering…" or "Also, we…".
        if label.ends_with(':') || after.trim().is_empty() || after.starts_with(':') {
            return Some(after.trim_start_matches(['*', '_', ':', ' ']).trim().to_string());
        }
    }
    None
}

fn bullet(line: &str) -> Option<String> {
    for marker in ["- ", "• ", "* ", "– "] {
        if let Some(rest) = line.strip_prefix(marker) {
            return Some(rest.trim().to_string());
        }
    }
    let digits: String = line.chars().take_while(|c| c.is_ascii_digit()).collect();
    if !digits.is_empty() && digits.len() <= 2 {
        let rest = &line[digits.len()..];
        if let Some(rest) = rest.strip_prefix('.').or_else(|| rest.strip_prefix(')')) {
            return Some(rest.trim().to_string());
        }
    }
    None
}

/// Text in sentences: a break after ".", "!" or "?" followed by a space and a capital (not inside "e.g." or "3.5").
pub fn sentences(text: &str) -> Vec<String> {
    let characters: Vec<char> = text.chars().collect();
    let mut out = Vec::new();
    let mut current = String::new();
    for (index, &character) in characters.iter().enumerate() {
        current.push(character);
        if !".!?".contains(character) || index + 1 >= characters.len() || characters[index + 1] != ' ' {
            continue;
        }
        let word = current.rsplit(' ').next().unwrap_or_default().to_lowercase();
        if ["e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "dr.", "approx."].contains(&word.as_str()) {
            continue;
        }
        let next = characters[index + 2..].iter().find(|c| **c != ' ');
        let Some(&next) = next else { continue };
        if !(next.is_uppercase() || next.is_ascii_digit() || "\"“'‘(".contains(next)) {
            continue;
        }
        out.push(current.trim().to_string());
        current.clear();
    }
    let rest = current.trim();
    if !rest.is_empty() {
        out.push(rest.to_string());
    }
    out
}

/// Whether a question is about what's on the screen (a shared slide, chart or page): "what does this chart show",
/// "on the slide", "can you see my screen". Then a picture of the meeting goes with it.
pub fn refers_to_screen(text: &str) -> bool {
    static PATTERNS: std::sync::OnceLock<Vec<regex::Regex>> = std::sync::OnceLock::new();
    let patterns = PATTERNS.get_or_init(|| {
        let things = "slide|slides|chart|graph|diagram|screen|table|figure|deck|dashboard|page|graphic|image|picture|\
                      spreadsheet|sheet|doc|document|code|numbers|data|plot|visual|mockup|design|presentation|whiteboard";
        [
            format!(r"\b(this|that|these|those|the|my|our|your)\s+(\w+\s+)?({things})\b"),
            r"\b(on|in)\s+(the|my|this|your)\s+screen\b".into(),
            r"\b(i'?m|we'?re|i am|we are)\s+sharing\b".into(),
            r"\bshared\s+(screen|slide|deck|doc)".into(),
            r"\b(can|do)\s+you\s+see\b".into(),
            r"\b(see|showing|shown|looking at)\s+(here|now|on)\b".into(),
            r"\bwhat (do|can) you see\b".into(),
        ].iter().filter_map(|p| regex::Regex::new(p).ok()).collect()
    });
    let lower = text.to_lowercase();
    patterns.iter().any(|p| p.is_match(&lower))
}

/// Whether a line carries something worth noting: a few words that aren't call logistics or small talk.
pub fn is_substantive(text: &str) -> bool {
    let count = text.split_whitespace().count();
    if count < 4 {
        return false;
    }
    const CHATTER: [&str; 36] = [
        "can you hear me", "can everyone hear", "you're on mute", "you are on mute", "you're muted", "am i audible",
        "is my screen visible", "let me share my screen", "can you see my screen", "one sec", "one second",
        "give me a second", "give me a minute", "good morning", "good afternoon", "good evening", "how are you",
        "how's it going", "nice to meet you", "thanks for joining", "thank you for joining", "bye everyone",
        "see you", "talk soon", "have a good", "sorry, go ahead", "no, go ahead", "you go first", "my internet",
        "my connection", "you're breaking up", "you froze", "let's wait for", "we'll wait for", "few more minutes",
        "can you see me",
    ];
    let lower = text.to_lowercase();
    // Chatter, unless there's more to the line than that ("Good morning, so the release moved to Friday").
    !CHATTER.iter().any(|c| lower.contains(c)) || count >= 12
}

/// The words of the substantive lines, for telling when enough has been said to update the notes.
pub fn substantive_words<'a>(lines: impl Iterator<Item = &'a Line>) -> usize {
    lines.filter(|l| is_substantive(&l.text)).map(|l| l.text.split_whitespace().count()).sum()
}

/// The reply that means the notes need no change.
pub fn is_no_change(reply: &str) -> bool {
    let bare = reply.trim().trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace()).to_uppercase();
    bare == "NO CHANGE" || bare == "NOTHING NEW" || bare.is_empty()
}

/// An email the model wrote as "Subject: …" then the body: its subject and body.
pub fn email(text: &str) -> (String, String) {
    let mut lines: Vec<&str> = text.trim().lines().collect();
    let mut subject = "Follow-up".to_string();
    if let Some(first) = lines.first() {
        if first.to_lowercase().starts_with("subject:") {
            subject = first["subject:".len()..].trim().to_string();
            lines.remove(0);
        }
    }
    let body = lines.join("\n").trim().to_string();
    (if subject.is_empty() { "Follow-up".into() } else { subject }, body)
}

/// A line worth keeping: speech models write a lone "Thank you." or "." for noise.
pub fn is_worth_keeping(text: &str) -> bool {
    if text.chars().filter(|c| c.is_alphabetic()).count() < 2 {
        return false;
    }
    let bare = text.to_lowercase().trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace()).to_string();
    !["thank you", "thanks", "you", "bye", "uh", "um", "hmm", "mm"].contains(&bare.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn questions_and_statements() {
        assert!(is_question("How did you handle the outage?"));
        assert!(is_question("So tell me about your last project"));
        assert!(is_question("We shipped it last week. How did that go for the team"));
        assert!(is_question("Can you walk us through the design"));
        assert!(is_question("Write factorial in Python"));
        assert!(is_question("Okay please explain the cache layer"));
        assert!(!is_question("What we did was ship it on Friday"));
        assert!(!is_question("We shipped it on Friday."));
        assert!(!is_question("Yes."));
    }

    #[test]
    fn echoes() {
        assert!(is_echo("we should ship it on friday", "I think we should ship it on Friday.", 0.0));
        assert!(!is_echo("sounds good to me", "I think we should ship it on Friday.", 0.0));
        // Your reply takes up their words: that's you speaking, not the call heard again.
        assert!(!is_echo("Yes, I'll share the pricing sheet", "Can you share the pricing sheet?", 0.0));
        assert!(!is_echo("we should ship it on friday", "So we should ship it on Friday?", 12.0));
        assert!(is_echo("we should ship it on friday", "I think we should ship it on Friday.", 1.5));
    }

    /// The Mac's testTheMicrophonesEchoOfTheCallIsLeftOut: the microphone cuts elsewhere than the call does.
    #[test]
    fn the_calls_words_are_taken_out_of_what_the_microphone_heard() {
        let them = |id: u64, at: f64, seconds: f64, text: &str| Line::new(id, Speaker::Them, text, 1_000.0 + at, 1_000.0 + at + seconds);
        let lines = vec![
            them(1, 0.0, 7.0, "So I think the median future is actually not a very good thing to think about."),
            them(2, 8.0, 9.0, "I would much rather talk about individual scenarios and how much chance we put on each."),
            them(3, 18.0, 8.0, "For context, we did a similar discussion to this in November three years ago."),
            them(4, 60.0, 5.0, "Something said a minute later that has nothing to do with it."),
        ];
        // Twenty seconds of the room: the microphone heard the speakers, cut where it liked, a few words off.
        let heard = Line::new(9, Speaker::You, "future is actually not a very good thing to think about, I would much rather \
            talk about individual scenarios and how much chance we put on each. For context we did a similar discussion \
            to this in November", 1_002.0, 1_022.0);
        let meanwhile: Vec<&str> = during(&heard, &lines).iter().map(|l| l.text.as_str()).collect();
        assert_eq!(meanwhile.len(), 3);
        assert_eq!(without_echo(&heard.text, &meanwhile), None);
        // No single line of theirs holds enough of it: why it used to stay in as "You".
        assert!(lines.iter().all(|l| contained(&heard.text, &[l.text.as_str()]) < CONTAINED_ECHO));
        // What you really said stays, word for word.
        let reply = "I disagree, the median is still the most useful single number we have.";
        assert_eq!(without_echo(reply, &meanwhile).as_deref(), Some(reply));
        assert_eq!(without_echo("Yes. I'll share the pricing sheet tomorrow.", &["Can you share the pricing sheet?"]).as_deref(),
                   Some("Yes. I'll share the pricing sheet tomorrow."));
        assert_eq!(without_echo(reply, &[]).as_deref(), Some(reply));
        // You spoke while the speakers played: their sentence goes, yours stays.
        let mixed = "I would much rather talk about individual scenarios and how much chance we put on each. Sorry, can I jump in here?";
        assert_eq!(without_echo(mixed, &meanwhile).as_deref(), Some("Sorry, can I jump in here?"));
        // A scrap of the call the speech model wrote differently on the two sides is still the call.
        let scrap = "I would much rather talk about individual scenarios and how much chance we put on each. Rather individual chance.";
        assert_eq!(without_echo(scrap, &meanwhile), None);
    }

    #[test]
    fn answers_split_into_their_parts() {
        let text = "ANSWER: I'd use a **hash map**.\nPOINTS:\n- It gives O(1) lookups.\n- Memory grows with keys.\nEXAMPLE: A cache of user IDs.\nCODE:\n```python\ndef f(n):\n    return n\n```\nALSO:\n- Ask about the data size.";
        let answer = spoken(text);
        assert_eq!(answer.headline.as_deref(), Some("I'd use a **hash map**."));
        assert_eq!(answer.points, vec!["It gives O(1) lookups.", "Memory grows with keys."]);
        assert_eq!(answer.example.as_deref(), Some("A cache of user IDs."));
        assert_eq!(answer.code, vec![Code { language: "python".into(), text: "def f(n):\n    return n".into() }]);
        assert_eq!(answer.also, vec!["Ask about the data size."]);
        // Bold labels and a code block still being written.
        let streaming = spoken("**Answer:** Yes.\n```js\nlet a = 1;");
        assert_eq!(streaming.headline.as_deref(), Some("Yes."));
        assert_eq!(streaming.code[0].text, "let a = 1;");
        // Plain text: sentences to say.
        assert_eq!(spoken("It works. Then it ships.").say, vec!["It works.", "Then it ships."]);
        assert!(!spoken("Answering now").say.is_empty());
    }

    #[test]
    fn sentences_keep_abbreviations() {
        assert_eq!(sentences("Use e.g. Redis. It's 3.5 times faster. Done"), vec!["Use e.g. Redis.", "It's 3.5 times faster.", "Done"]);
    }

    #[test]
    fn screen_questions() {
        assert!(refers_to_screen("What does this chart show?"));
        assert!(refers_to_screen("Can you see my screen"));
        assert!(refers_to_screen("I'm sharing the deck now"));
        assert!(!refers_to_screen("How did the launch go?"));
    }

    #[test]
    fn notes_helpers() {
        assert!(!is_substantive("Can you hear me now?"));
        assert!(is_substantive("The release moved to Friday because QA found two blockers"));
        assert!(is_no_change("NO CHANGE."));
        assert!(!is_no_change("# Notes"));
        assert_eq!(email("Subject: Thanks\n\nHi all"), ("Thanks".to_string(), "Hi all".to_string()));
        assert!(!is_worth_keeping("Thank you."));
        assert!(is_worth_keeping("Let's ship it"));
    }

    #[test]
    fn transcript_and_context_fit() {
        let lines: Vec<Line> = (0..50).map(|i| Line::new(i, if i % 2 == 0 { Speaker::Them } else { Speaker::You },
                                                         format!("line number {i}"), 0.0, 0.0)).collect();
        let text = transcript(lines.iter(), 200);
        assert!(text.chars().count() <= 200);
        assert!(text.ends_with("line number 49"));
        let context = context("Hiring sync", "Be brief", &[("agenda.txt".into(), "x".repeat(50_000))], 2_000);
        assert!(context.starts_with("About this meeting: Hiring sync"));
        assert!(context.chars().count() <= 2_100);
    }
}
