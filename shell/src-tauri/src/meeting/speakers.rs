//! Who said a line, as people see it, as the Mac's MeetingSpeakers.swift. voices.rs keeps raw voice numbers (1, 2… in
//! the order a voice was first heard, a stray cough's included); this decides which of them are shown, under which
//! number, and by what name.
//!
//! Adapted from Cicada's `SpeakerLabels` and `SpeakerNameGuess` (github.com/wquguru/cicada, Apache-2.0, © wquguru):
//! the five-line rule, the known-voice exception and the evidence check for names.

use super::text::{Line, Speaker};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// A voice gets a number once it has said this many substantive lines.
pub const SHOWN_AFTER: usize = 5;

/// A line long enough to say whose voice it is: three words, or four characters of a script written without spaces
/// between words. "Yeah." or a stray "." can make a voice of their own; they don't count towards a number.
pub fn substantive(text: &str) -> bool {
    if text.split_whitespace().filter(|word| word.chars().any(char::is_alphabetic)).count() >= 3 {
        return true;
    }
    text.chars().filter(|c| matches!(*c as u32, 0x3040..=0x30FF | 0x4E00..=0x9FFF | 0xAC00..=0xD7A3 | 0x0900..=0x097F)).count() >= 4
}

/// Voice → speaker number (1, 2…) for the voices on show. A voice is shown from its `SHOWN_AFTER`th substantive line,
/// and only once two voices are, so a one-to-one call stays "Them". `known` voices (remembered, or named by you) are
/// shown from their first line, and one known voice is enough. Numbers follow the order voices came on show, so a
/// number never moves once seen.
pub fn numbers(lines: &[Line], known: &HashSet<u32>) -> HashMap<u32, u32> {
    let mut count: HashMap<u32, usize> = HashMap::new();
    let mut reached: Vec<u32> = Vec::new();
    for line in lines.iter().filter(|l| l.speaker == Speaker::Them) {
        let Some(voice) = line.voice else { continue };
        if reached.contains(&voice) {
            continue;
        }
        if known.contains(&voice) {
            reached.push(voice);
            continue;
        }
        if !substantive(&line.text) {
            continue;
        }
        let said = count.entry(voice).or_default();
        *said += 1;
        if *said == SHOWN_AFTER {
            reached.push(voice);
        }
    }
    if reached.len() < 2 && !reached.iter().any(|voice| known.contains(voice)) {
        return HashMap::new();
    }
    reached.into_iter().enumerate().map(|(index, voice)| (voice, index as u32 + 1)).collect()
}

/// The other side's only voice in a one-to-one call (numbers hide it, but you still need to be able to name it). A
/// breath or click can make a second one-line voice: the one voice with substantive speech still counts.
pub fn single_voice(lines: &[Line]) -> Option<u32> {
    let them = || lines.iter().filter(|l| l.speaker == Speaker::Them);
    let voices: HashSet<u32> = them().filter_map(|l| l.voice).collect();
    if voices.len() == 1 {
        return voices.into_iter().next();
    }
    let talking: HashSet<u32> = them().filter(|l| substantive(&l.text)).filter_map(|l| l.voice).collect();
    if talking.len() == 1 { talking.into_iter().next() } else { None }
}

/// Where a voice's name came from. Higher sources win: you, then the voices you saved, then the conversation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    Conversation,
    Library,
    User,
}

/// A name given to a voice. Empty from `User`: you said it isn't the guessed person; the voice shows as Speaker N.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct VoiceName {
    pub name: String,
    pub source: Source,
    /// Why: the line a conversation name came from ("03:21 “Hi, I'm Priya…”").
    pub evidence: Option<String>,
}

impl VoiceName {
    /// `new` takes `old`'s place unless `old` came from a higher source.
    pub fn merge(old: Option<&VoiceName>, new: VoiceName) -> VoiceName {
        match old {
            Some(old) if new.source < old.source => old.clone(),
            _ => new,
        }
    }
}

/// The voices shown from their first line: those with a name that came from you or from your saved voices. A
/// conversation's guess isn't enough by itself (it's only shown once the voice has a number).
pub fn known(names: &HashMap<u32, VoiceName>, lines: &[Line]) -> HashSet<u32> {
    let mut known: HashSet<u32> = names.iter()
        .filter(|(_, name)| name.source == Source::Library || (name.source == Source::User && !name.name.is_empty()))
        .map(|(voice, _)| *voice).collect();
    // A one-to-one caller you named is shown under that name, though it never gets a number.
    if let Some(only) = single_voice(lines) {
        if names.get(&only).is_some_and(|name| !name.name.is_empty()) {
            known.insert(only);
        }
    }
    known
}

/// What a line's speaker is shown as: "You", a name, "Speaker 2", or "Them". A name shows on a voice that's on show,
/// or on `single`, a one-to-one call's only voice.
pub fn label(line: &Line, numbers: &HashMap<u32, u32>, names: &HashMap<u32, VoiceName>, single: Option<u32>) -> String {
    if line.speaker != Speaker::Them {
        return "You".into();
    }
    let Some(voice) = line.voice else { return "Them".into() };
    if let Some(name) = names.get(&voice).filter(|name| !name.name.is_empty()) {
        if numbers.contains_key(&voice) || single == Some(voice) {
            return name.name.clone();
        }
    }
    numbers.get(&voice).map_or_else(|| "Them".into(), |number| format!("Speaker {number}"))
}

/// Every line's `who`, from its voice as the meeting is grouped now. Returns the numbers on show.
pub fn relabel(lines: &mut [Line], names: &HashMap<u32, VoiceName>) -> HashMap<u32, u32> {
    let numbers = numbers(lines, &known(names, lines));
    let single = single_voice(lines);
    for index in 0..lines.len() {
        let who = label(&lines[index], &numbers, names, single);
        if lines[index].who != who {
            lines[index].who = who;
        }
    }
    numbers
}

// MARK: Names from the conversation

/// The newest lines the AI reads.
pub const WINDOW: usize = 400;

/// The meeting's AI reads the labelled transcript and reports two things: people who say their own name ("Hi, I'm
/// Priya"), and the names of the people taking part. Only the first is ever put on a voice, and only when the line
/// really is that voice's and really says it (`introduces`). The rest are offered when you name someone, and nothing
/// more: in a meeting, a name that's spoken is nearly always someone else's ("Ryan, what do you think?").
pub const INSTRUCTION: &str = "Two things about the people in this meeting transcript. \
    \"speakers\": people labelled \"Speaker N\" who say their own name on a line with their own label (\"Hi, I'm \
    Priya\", \"My name is Raj\", \"This is Emma from Acme\"). Only that: someone being addressed, mentioned, thanked \
    or introduced by another person is not it, however clear it seems who they are. \
    \"people\": the names of the people who are taking part in the meeting, as far as what's said shows it \
    (addressed, introduced as present, or introducing themselves); not people only talked about. Speech \
    recognition writes names by ear and often misspells them: for a public figure recognisable from the name and \
    what is said, write the name as the news spells it; otherwise as written. Leave out anyone you are unsure of. \
    Reply with only this JSON: \
    {\"speakers\": [{\"speaker\": 2, \"name\": \"Priya\", \"evidence\": \"L12\"}], \"people\": [\"Priya\", \"Raj Mehta\"]}, \
    the evidence being the line where they say their name; empty lists if none.";

/// "03:21" for `at` in a meeting that started at `start`.
pub fn clock(at: f64, start: f64) -> String {
    let seconds = (at - start).max(0.0) as u64;
    format!("{:02}:{:02}", seconds / 60, seconds % 60)
}

/// The transcript as the AI reads it: the newest `WINDOW` lines, "[L12 03:41 Speaker 2] text". None when no voice is
/// on show (nothing to name), or every voice on show already has a name you gave it or saved.
pub fn content(lines: &[Line], numbers: &HashMap<u32, u32>, names: &HashMap<u32, VoiceName>, start: f64) -> Option<String> {
    if numbers.is_empty() || numbers.keys().all(|voice| names.get(voice).is_some_and(|name| name.source >= Source::Library)) {
        return None;
    }
    let mut out = String::from("Meeting transcript. Speakers: You = the user; Speaker N = one person on the other side, told \
                                apart by voice; Them = someone on the other side, not identified.\n");
    for (index, line) in window(lines).iter().enumerate() {
        let who = match line.speaker {
            Speaker::You => "You".to_string(),
            Speaker::Them => line.voice.and_then(|v| numbers.get(&v)).map_or_else(|| "Them".into(), |n| format!("Speaker {n}")),
        };
        out += &format!("[L{} {} {who}] {}\n", index + 1, clock(line.at, start), line.text);
    }
    Some(out)
}

fn window(lines: &[Line]) -> &[Line] {
    &lines[lines.len().saturating_sub(WINDOW)..]
}

fn json_object(reply: &str) -> Option<serde_json::Value> {
    let (from, to) = (reply.find('{')?, reply.rfind('}')?);
    serde_json::from_str(reply.get(from..=to)?).ok().filter(serde_json::Value::is_object)
}

/// The names in the AI's reply that hold, by voice, and the voices whose name doesn't (`refuted`: to be dropped, an
/// earlier copy too): a name holds when its evidence line is that voice's own and says it (`introduces`). A name given
/// to two voices goes to the one with more lines.
pub fn read(reply: &str, all: &[Line], numbers: &HashMap<u32, u32>, start: f64) -> (HashMap<u32, VoiceName>, Vec<u32>) {
    let (mut found, mut refuted): (HashMap<u32, VoiceName>, Vec<u32>) = (HashMap::new(), Vec::new());
    let Some(object) = json_object(reply) else { return (found, refuted) };
    let Some(list) = object["speakers"].as_array() else { return (found, refuted) };
    let voice_of: HashMap<u32, u32> = numbers.iter().map(|(voice, number)| (*number, *voice)).collect();
    let lines = window(all);
    let spoken = |voice: u32| all.iter().filter(|l| l.voice == Some(voice)).count();
    let digits = |value: &serde_json::Value| -> Option<usize> {
        let text = value.as_str().map(String::from).unwrap_or_else(|| value.to_string());
        text.chars().skip_while(|c| !c.is_ascii_digit()).take_while(char::is_ascii_digit).collect::<String>().parse().ok()
    };
    for item in list {
        let Some(voice) = digits(&item["speaker"]).and_then(|number| voice_of.get(&(number as u32)).copied()) else { continue };
        let Some(name) = item["name"].as_str().map(str::trim).filter(|n| !n.is_empty() && n.chars().count() <= 40) else { continue };
        // "L52" or "L52, L53": the first line named.
        let line = digits(&item["evidence"]).and_then(|number| number.checked_sub(1)).and_then(|index| lines.get(index))
            .filter(|line| line.speaker == Speaker::Them && line.voice == Some(voice) && introduces(&line.text, name));
        let Some(line) = line else {
            refuted.push(voice);
            continue;
        };
        if let Some(other) = found.iter().find(|(_, n)| n.name.to_lowercase() == name.to_lowercase()).map(|(v, _)| *v) {
            if spoken(other) >= spoken(voice) {
                continue;
            }
            found.remove(&other);
        }
        let quote: String = if line.text.chars().count() > 60 { line.text.chars().take(60).collect::<String>() + "…" } else { line.text.clone() };
        found.insert(voice, VoiceName { name: name.into(), source: Source::Conversation,
                                        evidence: Some(format!("{} “{quote}”", clock(line.at, start))) });
    }
    refuted.retain(|voice| !found.contains_key(voice));
    (found, refuted)
}

/// The people the AI says are taking part ("people"), for offering when you name a voice: trimmed, no repeats.
pub fn people(reply: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let Some(object) = json_object(reply) else { return out };
    for item in object["people"].as_array().into_iter().flatten() {
        let Some(name) = item.as_str().map(str::trim).filter(|n| !n.is_empty() && n.chars().count() <= 40) else { continue };
        if !out.iter().any(|have| have.to_lowercase() == name.to_lowercase()) {
            out.push(name.to_string());
        }
    }
    out.truncate(12);
    out
}

/// Words that come before your own name when you say who you are.
const OPENERS: &[&[&str]] = &[&["i'm"], &["i", "am"], &["my", "name", "is"], &["my", "name's"], &["myself"], &["this", "is"],
                              &["mera", "naam"], &["मेरा", "नाम"], &["मैं"], &["main"], &["je", "m'appelle"], &["me", "llamo"],
                              &["ich", "bin"], &["ich", "heiße"], &["mi", "chiamo"]];
/// "This is Priya" can be someone else being introduced: it counts only as "This is Priya from…/here/speaking".
const AFTER_THIS_IS: &[&str] = &["from", "here", "speaking", "calling", "with", "at"];

/// Whether `text` has its speaker saying their own name: an opener ("I'm", "my name is"…), then the name as the speech
/// model wrote it (which can be a letter or two off the real spelling).
pub fn introduces(text: &str, name: &str) -> bool {
    let lower = text.to_lowercase().replace('’', "'");
    // Marks that join a letter to the one before it (Devanagari's vowel signs) are part of the word.
    let part = |c: char| c.is_alphanumeric() || c == '\'' || matches!(c as u32, 0x0900..=0x097F);
    let words: Vec<&str> = lower.split(|c: char| !part(c)).filter(|w| !w.is_empty()).collect();
    let name = name.to_lowercase();
    let Some(wanted) = name.split(|c: char| !(c.is_alphabetic() || matches!(c as u32, 0x0900..=0x097F))).find(|w| !w.is_empty()) else { return false };
    if wanted.chars().count() < 2 {
        return false;
    }
    for start in 0..words.len() {
        for opener in OPENERS.iter().filter(|opener| words[start..].starts_with(opener)) {
            // Straight after it ("I'm, uh, Priya" too): "I'm with Priya on this" isn't an introduction.
            let mut at = start + opener.len();
            while at < words.len() && ["uh", "um", "er", "like"].contains(&words[at]) {
                at += 1;
            }
            if at >= words.len() || words[at].ends_with("'s") || !alike(words[at], wanted) {
                continue;
            }
            if *opener == ["this", "is"] {
                // The word after the name (first and last name skipped over).
                if !words[at + 1..].iter().take(2).any(|word| AFTER_THIS_IS.contains(word)) {
                    continue;
                }
            }
            return true;
        }
    }
    false
}

/// The same name allowing for how speech models spell ("Jamie" for Jaime, "Rhea" for Ria): the same first letter and
/// at most two letters different (one in a three-letter name).
fn alike(heard: &str, name: &str) -> bool {
    if heard == name {
        return true;
    }
    let (a, b): (Vec<char>, Vec<char>) = (heard.chars().collect(), name.chars().collect());
    let shorter = a.len().min(b.len());
    if a.first() != b.first() || shorter < 3 {
        return false;
    }
    distance(&a, &b) <= if shorter >= 4 { 2 } else { 1 }
}

fn distance(a: &[char], b: &[char]) -> usize {
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, x) in a.iter().enumerate() {
        let mut previous = row[0];
        row[0] = i + 1;
        for (j, y) in b.iter().enumerate() {
            let above = row[j + 1];
            row[j + 1] = if x == y { previous } else { 1 + previous.min(above).min(row[j]) };
            previous = above;
        }
    }
    row[b.len()]
}

/// A note for the AI that writes the notes: who the labels are, so it doesn't invent names or genders for them.
pub fn note(lines: &[Line]) -> String {
    let mut labels: Vec<&str> = Vec::new();
    for line in lines.iter().filter(|l| l.speaker == Speaker::Them) {
        if !labels.contains(&line.who.as_str()) {
            labels.push(&line.who);
        }
    }
    if labels.iter().all(|label| *label == "Them") {
        return String::new();
    }
    format!("Speakers in the transcript: You is the user; {} on the other side of the call, told apart by voice. Use \
             these labels exactly as written: don't invent a name, a role or a gender for a numbered speaker, and \
             \"Them\" is someone on the other side who wasn't told apart.\n\n", labels.join(", "))
}

#[cfg(test)]
mod tests {
    // The Mac's MeetingSpeakersTests, where they apply here.
    use super::*;

    fn them(id: u64, voice: u32, text: &str) -> Line {
        let mut line = Line::new(id, Speaker::Them, text, id as f64 * 10.0, id as f64 * 10.0 + 5.0);
        line.voice = Some(voice);
        line
    }

    fn talk(lines: &mut Vec<Line>, voice: u32, count: usize) {
        for _ in 0..count {
            lines.push(them(lines.len() as u64, voice, "this is a substantive line"));
        }
    }

    #[test]
    fn a_voice_is_numbered_after_five_lines_once_two_are() {
        let mut lines = Vec::new();
        talk(&mut lines, 4, 6);
        assert!(numbers(&lines, &HashSet::new()).is_empty());
        talk(&mut lines, 2, 4);
        lines.push(them(99, 2, "Yeah."));
        assert!(numbers(&lines, &HashSet::new()).is_empty(), "only one voice has five lines");
        talk(&mut lines, 2, 1);
        assert_eq!(numbers(&lines, &HashSet::new()), HashMap::from([(4, 1), (2, 2)]));
        talk(&mut lines, 7, 5);
        assert_eq!(numbers(&lines, &HashSet::new()), HashMap::from([(4, 1), (2, 2), (7, 3)]));
        // A voice you named or saved is shown from its first line, and one is enough.
        let one = vec![them(0, 3, "Hello there everyone")];
        assert_eq!(numbers(&one, &HashSet::from([3])), HashMap::from([(3, 1)]));
    }

    #[test]
    fn labels() {
        let mut lines = Vec::new();
        talk(&mut lines, 1, 5);
        talk(&mut lines, 2, 5);
        lines.push(Line::new(50, Speaker::You, "Sounds good to me", 500.0, 502.0));
        let mut names = HashMap::new();
        names.insert(2, VoiceName { name: "Priya".into(), source: Source::Conversation, evidence: None });
        relabel(&mut lines, &names);
        assert_eq!((lines[0].who.as_str(), lines[5].who.as_str(), lines[10].who.as_str()), ("Speaker 1", "Priya", "You"));
        // One-to-one: "Them", until you name them.
        let mut call = Vec::new();
        talk(&mut call, 1, 8);
        relabel(&mut call, &HashMap::new());
        assert_eq!(call[0].who, "Them");
        let named = HashMap::from([(1, VoiceName { name: "Rahul".into(), source: Source::User, evidence: None })]);
        relabel(&mut call, &named);
        assert_eq!(call[0].who, "Rahul");
        assert!(note(&call).contains("Rahul") && note(&[Line::new(0, Speaker::Them, "Hi", 0.0, 1.0)]).is_empty());
    }

    #[test]
    fn only_someone_saying_their_own_name_is_named() {
        assert!(introduces("Hi, I'm Priya from finance.", "Priya Sharma"));
        assert!(introduces("Hello, my name is Raj and I lead the team", "Raj"));
        assert!(introduces("I am, uh, Jamie Sevia, I founded Epoch", "Jaime Sevilla"), "spelled by ear");
        assert!(introduces("Hi, this is Emma from Acme.", "Emma"));
        assert!(introduces("Myself Rahul, joining from Pune", "Rahul"));
        assert!(introduces("मेरा नाम अर्जुन है", "अर्जुन"));
        assert!(!introduces("This is Priya, our new designer.", "Priya"));
        assert!(!introduces("I'm with Priya on this one.", "Priya"));
        assert!(!introduces("I'm curious to hear from Ryan and Jaime.", "Ryan"));
        assert!(!introduces("Thanks, Priya, that was clear.", "Priya"));
        assert!(!introduces("So just to introduce all of the folks, there's Jaime Sevilla, who founded Epoch", "Jaime"));
        assert!(!introduces("I'm Priya's manager.", "Priya"));
        assert!(!introduces("I'm Daniel.", "David"));
    }

    #[test]
    fn the_ais_names_hold_only_with_evidence() {
        let mut lines = Vec::new();
        talk(&mut lines, 1, 5);
        talk(&mut lines, 2, 5);
        lines.push(them(10, 2, "Hi, I'm Priya from finance."));
        lines.push(them(11, 1, "Thanks, Priya. Ryan, what do you think?"));
        let numbers = numbers(&lines, &HashSet::new());
        let content = content(&lines, &numbers, &HashMap::new(), 0.0).unwrap();
        assert!(content.contains("[L11 01:40 Speaker 2] Hi, I'm Priya from finance."));
        let reply = r#"Here: {"speakers": [{"speaker": 2, "name": "Priya", "evidence": "L11"},
            {"speaker": 1, "name": "Ryan", "evidence": "L12"}], "people": ["Priya", "Ryan", "priya", " "]}"#;
        let (found, refuted) = read(reply, &lines, &numbers, 0.0);
        assert_eq!(found.get(&2).map(|n| n.name.as_str()), Some("Priya"));
        assert_eq!((found.len(), refuted), (1, vec![1]));
        assert_eq!(people(reply), vec!["Priya", "Ryan"]);
        assert_eq!(read("no json", &lines, &numbers, 0.0).0.len(), 0);
    }
}
