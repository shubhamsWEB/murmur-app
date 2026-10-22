//! Decides whether something you said is a command for Murmur or text to type, so one key does both (the Mac's
//! IntentClassifier, with Windows' words).
//!
//! Typing is the default; a command needs a clear signal:
//! 1. Shift held with the dictation key → command.
//! 2. A known command pattern ("open Slack", "open chrome and search facebook", "volume 30") → command.
//! 3. Starts with "Murmur" ("Murmur, summarise this") → command.
//! 4. Doesn't open like an instruction → typed.
//! 5. Opens like an instruction to the computer ("open…", "summarise…", "translate…"); messages and questions ("send…",
//!    "what's…") don't count, so they're typed unless you say "Murmur" first or hold Shift:
//!    - the focus is somewhere you can't type (the desktop, a folder) → command;
//!    - otherwise the model decides, with a short time limit; no answer → typed.
//! Whether a text field has the focus is often unknown (Chrome and Electron apps don't always say), so "unknown" never
//! counts as "no text field".

use super::quick::{self, Apps};
use super::{memory, wake};
use crate::ai::Router;
use fancy_regex::Regex;
use std::sync::OnceLock;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Intent {
    Command,
    Dictation,
}

/// What has the keyboard focus, as far as UI Automation can tell.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Focus {
    TextField,
    NotText,
    Unknown,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Decision {
    pub intent: Intent,
    pub reason: String,
    /// A clear signal (Shift, a known command, "Murmur…", nowhere to type), not the model's guess. A guessed command
    /// that ends up only answering is typed instead.
    pub explicit: bool,
}

impl Decision {
    fn command(reason: &str) -> Decision {
        Decision { intent: Intent::Command, reason: reason.into(), explicit: true }
    }
    fn dictation(reason: &str) -> Decision {
        Decision { intent: Intent::Dictation, reason: reason.into(), explicit: true }
    }
}

/// Everything known when the words came in.
pub struct Situation<'a> {
    pub forced_command: bool,
    pub focus: Focus,
    pub front_app: Option<&'a str>,
    pub has_selection: bool,
    /// Seconds since the last command.
    pub since_last: Option<f64>,
}

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("a valid pattern"))
}

fn matches(cell: &'static OnceLock<Regex>, pattern: &str, text: &str) -> bool {
    re(cell, pattern).is_match(text).unwrap_or(false)
}

/// Words that start an instruction to the computer. Dictated prose rarely opens with these bare.
const COMMAND_OPENERS: &[&str] = &[
    "open", "launch", "start", "quit", "close", "exit", "hide", "switch", "find", "search", "google", "play", "pause",
    "set", "turn", "mute", "unmute", "lock", "run", "summarize", "summarise", "translate", "rewrite", "rephrase",
    "shorten", "schedule", "remind", "check", "update", "upgrade", "install", "uninstall", "enable", "disable",
    "connect", "disconnect", "empty", "restart", "reboot", "shut", "sleep", "show", "go", "navigate", "take",
    "download", "clear", "change", "increase", "decrease", "reduce", "raise", "lower", "toggle", "create", "make",
    "build", "add", "delete", "remove", "move", "rename", "copy", "watch", "explain", "ask", "tell", "dim", "brighten",
    "stop", "resume", "unpause", "skip", "next", "previous", "send", "message", "whatsapp", "text", "email", "ping",
    "remember", "forget", "minimise", "minimize", "maximise", "maximize", "paste", "write", "type", "look",
];
const QUESTION_OPENERS: &[&str] = &["what", "what's", "what’s", "whats", "how", "which", "why", "where", "when", "is",
                                      "are", "can", "could", "do", "does", "did", "read"];

/// "from now on open links in Chrome", "remember that Mom is Roma", "call me Shubham": teaching Murmur.
pub fn something_to_remember(cleaned: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    matches(&R, r"^(from now on|going forward|keep in mind|remember that|remember my|remember i|please remember|call me|my name is)\b", cleaned)
}

/// "send a message to Riya on WhatsApp saying…", "text Mom that I'm late", "Rahul ko message bhejo": an errand, not
/// words for the box you're in.
pub fn message_request(cleaned: &str) -> bool {
    static TO_SEND: OnceLock<Regex> = OnceLock::new();
    static REQUEST: OnceLock<Regex> = OnceLock::new();
    matches(&TO_SEND, r"^(send|write|drop|shoot) (a |an )?(quick |short )?(message|msg|text|whatsapp|dm|reply|note|email|mail)\b.*\bto\b|^(message|text|whatsapp|ping|dm|email|mail) (?!(me|us|you|him|her|them)\b)[a-z]+.*\b(on|in|via|over|through) (whatsapp|slack|telegram|signal|messages|teams|discord)\b|^(message|text|whatsapp|ping|dm) (?!(me|us|you|him|her|them)\b)[a-z]+( [a-z]+)? (saying|that|to say|and say|asking|telling|to tell)\b|^(send|tell) .+\b(on|in|via|over|through) (whatsapp|slack|telegram|signal|teams|discord)\b", cleaned)
        || matches(&REQUEST, r"^(send|text|message|msg|whatsapp|ping|dm) (?!(me|us|you|him|her|them|it|this|that)\b)[a-z]+( [a-z]+)? (a |an )?(quick |short )?(message|msg|text|whatsapp|note)\b|^(send|text|message|msg|whatsapp|ping|dm) .+\b(on|via|over|in|through) (whatsapp|slack|telegram|signal|messages|teams|discord)\b|\b[a-z]+ (ko|se) .*\b(message|msg|whatsapp|text|sms|mail|email)\b.*\b(karo|kar do|kar de|kardo|kar dijiye|bhejo|bhej do|bhej de|bhejdo|bhej dijiye|bolo|bol do|keh do|kaho|likh do|likho)\b|\b(whatsapp|message|msg|slack|telegram) (pe|par|me|mein) .*\b[a-z]+ ko\b.*\b(bhejo|bhej do|bhej de|bolo|bol do|keh do|kaho|likh do|likho|karo|kar do)\b|\b[a-z]+ ko .*\b(bhejo|bhej do|bhej de|bhejdo|bhej dijiye)\b.*\b(whatsapp|message|msg)\b", cleaned)
}

/// A question or instruction about what's on the screen: "what's on my screen", "summarise this page".
pub fn about_the_screen(cleaned: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    matches(&R, r"^(what(['’]s| is| are| does| do)?|whats|which|read|describe|summari[sz]e|explain|tell me|look at|check)\b.*\b(screen|on screen|this (page|tab|window|error|message|email|mail|article|document|doc|site|website|video|chart|table|code|dialog|popup|notification)|the (page|tab|window|error|dialog|popup))\b|^what (am i|i'm|im) (looking at|seeing)\b", cleaned)
}

/// A question about your own chats, mail or calendar: "what did I send Roma on WhatsApp today?".
pub fn about_my_messages(cleaned: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    static YOU: OnceLock<Regex> = OnceLock::new();
    matches(&R, r"^(what|which|who|when|did|do i|have i|has|any|show|tell me|check|summari[sz]e|sum up|go through|find)\b.*\b(i|me|my|mine|mera|meri|mere|maine|mujhe)\b.*\b(whatsapp|messages?|chats?|texts?|emails?|e-mails?|mails?|inbox|gmail|slack|telegram|calendar|meetings?|reminders?)\b|^(what|which|who|when|did|any|show|tell me|check|summari[sz]e|sum up|go through|find)\b.*\b(whatsapp|messages?|chats?|emails?|mails?|inbox|gmail|slack|calendar|meetings?|reminders?)\b.*\b(i|me|my|mine)\b", cleaned)
        && !matches(&YOU, r"\b(you|your|u|tum|tumne|aap|aapne)\b", cleaned)
}

/// Hinglish instructions put the verb last: "mujhe PDF kholkar do", "Spotify pe gaana chalao", "Chrome band karo".
fn hinglish_instruction(cleaned: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    matches(&R, r"\b(khol|chala|baja|bhej|dhund|dhoond|dhundh|dhoondh|dikha|bata|suna|hata|mita|badha|ghata|laga|bula|rok)(o|iye|ie|na|kar|ke|\s?(do|de|dijiye|dena|kar(o|iye|na| do| dijiye| dena| de)?|ke( do| dijiye| dena| de)?))\b|\b(open|start|launch|play|pause|search|mute|unmute|on|off|save|copy|paste|delete|translate|summari[sz]e|call|set|chalu|kam|zyada|jyada|tez|dheema|dheere|full|clear|install|update|close|share|send|check|show|band|bandh|record|scroll|refresh|reload|minimi[sz]e|maximi[sz]e|type|likh)\s+(kar(o|iye|na|ke do|kar do| do| dijiye| dena| de)?|kijiye|kijie|do)\b", cleaned)
}

/// Things on the PC a Hinglish instruction can be about.
fn pc_things(cleaned: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    matches(&R, r"\b(pdf|file|files|folder|document|doc|docs|photo|photos|tasveer|video|videos|song|gaana|gana|gaane|music|app|chrome|edge|youtube|spotify|whatsapp|slack|volume|awaaz|awaz|aawaz|brightness|wifi|wi-fi|bluetooth|screen|screenshot|calendar|mail|email|notes|notepad|downloads|desktop|browser|tab|settings?|pc|laptop|computer|system|resume|cv|card|aadhaar|aadhar|passport|statement|invoice|bill|receipt|ticket|certificate)\b", cleaned)
}

/// "…on my PC", "…on this laptop": talking about the computer, so most likely an instruction for it.
fn about_the_pc(cleaned: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    matches(&R, r"\b(on|for|of|in) (my|this|the) (pc|laptop|computer|system|screen|desktop|windows)\b", cleaned)
}

/// A chain of steps for the computer: "open Notepad and write…", "search YouTube for lofi and play the first one".
fn chain_of_steps(cleaned: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    matches(&R, r"^(open|launch|start|go to|visit|switch to|search|find|look up|play|google) .+ (and|then) (then )?(write|type|draft|jot|note|add|put|create|make|compose|list|play|watch|open|search|press|select|save|download|summari[sz]e|sum up|explain|describe|read|translate|tell|check|compare|reply|answer|copy|send|email|share|find|look)\b", cleaned)
}

// MARK: Selected text

/// "summarise this", "make it more formal", "translate this to Hindi", "explain this": one thing to do with the
/// selected text. Some(true) when the result is to read (a summary, an explanation), Some(false) for an edit that goes
/// in place of the selection. A request that goes on to do more with the result isn't one.
pub fn selection_task(utterance: &str) -> Option<bool> {
    let task = selection_instruction(utterance)?;
    (!goes_further(&quick::clean(utterance))).then_some(task)
}

/// Whether the words are an instruction about the selected text at all.
pub fn is_about_selection(utterance: &str) -> bool {
    selection_instruction(utterance).is_some()
}

fn goes_further(text: &str) -> bool {
    static NEXT: OnceLock<Regex> = OnceLock::new();
    static PLACE: OnceLock<Regex> = OnceLock::new();
    matches(&NEXT, r"\b(and|then|and then)\b.*\b(add|put|save|send|paste|write|create|make|open|email|mail|share|post|copy|insert|append|store|note|attach|tweet|message|text|search|google|look up|read)\b", text)
        || matches(&PLACE, r"\b(in|into|to|on|onto|as)\s+(a\s+|an\s+|my\s+|the\s+)?(new\s+)?(notes?|onenote|notepad|word|docs?|google docs|document|file|mail|email|gmail|outlook|slack|whatsapp|telegram|teams|discord|reminders?|calendar|notion|obsidian|todo|to-do|clipboard|desktop|downloads)\b", text)
}

fn selection_instruction(utterance: &str) -> Option<bool> {
    static READING: OnceLock<Regex> = OnceLock::new();
    static EDITING: OnceLock<Regex> = OnceLock::new();
    static NEEDS_THIS: OnceLock<Regex> = OnceLock::new();
    static MENTIONS: OnceLock<Regex> = OnceLock::new();
    let text = quick::clean(utterance);
    if matches(&READING, r"^(summari[sz]e|sum up|tl ?dr|explain|what does (this|it) (mean|say)|what is this|what's this|reply to|respond to|answer|draft a reply|write a reply)\b", &text) {
        return Some(true);
    }
    if matches(&EDITING, r"^(translate|rewrite|rephrase|reword|shorten|condense|simplify|expand|lengthen|proofread|paraphrase)\b", &text) {
        return Some(false);
    }
    if matches(&NEEDS_THIS, r"^(make|turn|convert|fix|correct|improve|polish|edit|format|clean up|change)\b", &text)
        && matches(&MENTIONS, r"\b(this|it|that|selection|selected|text|paragraph|sentence|email|message)\b", &text) {
        return Some(false);
    }
    None
}

// MARK: Deciding

/// Command or dictation, with why. `router`: the model asked when the words alone don't settle it (none: typed).
pub async fn decide(utterance: &str, at: &Situation<'_>, apps: &dyn Apps, router: Option<&Router>) -> Decision {
    if at.forced_command {
        return Decision::command("command key held");
    }
    let cleaned = quick::clean(utterance);
    if cleaned.is_empty() {
        return Decision::dictation("empty");
    }
    // Text selected and "summarise this", "make it more formal", "translate this to Hindi".
    if at.has_selection && is_about_selection(utterance) {
        return Decision::command("an instruction about the selected text");
    }
    let quick_actions = quick::parse_all(utterance, apps);
    // "my photos from Goa are amazing" in a message is text; "find my photos…" is a search anywhere.
    static VERB_FIRST: OnceLock<Regex> = OnceLock::new();
    let verbless_file_search = quick_actions.as_ref().is_some_and(|a| a.iter().all(|a| a.tool == "search_files"))
        && !matches(&VERB_FIRST, r"^(find|search|show|get|look|open)\b", &cleaned);
    if verbless_file_search && at.focus == Focus::TextField {
        return Decision::dictation("file words, but you're in a text field");
    }
    if something_to_remember(&cleaned) {
        return Decision::command("something to remember");
    }
    if memory::is_follow_up(utterance, at.since_last) || memory::forget_request(utterance).is_some() {
        return Decision::command("follows on from the last command");
    }
    if message_request(&cleaned) {
        return Decision::command("a message to send");
    }
    if let Some(actions) = &quick_actions {
        if cleaned.split_whitespace().count() <= 14 {
            let tools: Vec<&str> = actions.iter().map(|a| a.tool.as_str()).collect();
            return Decision::command(&format!("known command ({})", tools.join(" + ")));
        }
    }
    if chain_of_steps(&cleaned) {
        return Decision::command("a chain of steps");
    }
    if wake::strip(utterance).is_some() {
        return Decision::command("addressed to Murmur");
    }
    if about_the_screen(&cleaned) {
        return Decision::command("about what's on the screen");
    }
    if about_my_messages(&cleaned) {
        return Decision::command("a question about your messages");
    }
    // Somewhere you can't type (the desktop, a folder, a player): whatever you said is for Murmur.
    if at.focus == Focus::NotText {
        return Decision::command("nowhere to type");
    }
    // Hinglish: about something on the PC and not in a text field, it's for Murmur; in a text field it could be a
    // message ("kal file bhej dena"), so the model decides.
    let hinglish = hinglish_instruction(&cleaned);
    if hinglish && at.focus != Focus::TextField && pc_things(&cleaned) {
        return Decision::command("Hinglish instruction about the PC");
    }
    let first = cleaned.split_whitespace().next().unwrap_or_default();
    let mentions_pc = about_the_pc(&cleaned);
    if mentions_pc && (COMMAND_OPENERS.contains(&first) || QUESTION_OPENERS.contains(&first)) {
        return Decision::command("about this PC");
    }
    if !(COMMAND_OPENERS.contains(&first) || mentions_pc || hinglish) {
        return Decision::dictation("reads as text");
    }
    let Some(router) = router else {
        return Decision::dictation("could be a command, but no model to ask; typed");
    };
    let system = "You classify one utterance spoken to Murmur, a Windows voice assistant. Either the user is giving \
        Murmur a COMMAND to carry out (open or quit apps, search, change settings, ask Murmur a question, rewrite or \
        summarise the selected text, write something for them, teach Murmur a preference), or they are DICTATING words \
        to be typed as-is into the text field they are in (a message, an email body, notes), even if those words \
        contain verbs or questions. The user may speak Hinglish (Hindi in English letters): \"mujhe PDF kholkar do\" \
        (open the PDF for me) and \"Spotify pe gaana chalao\" are commands; \"kal milte hain, file bhej dena\" in a \
        chat is dictation. Answer \"command\" or \"dictation\".";
    let user = format!(
        "App in front: {}. Text field focused: {}. Text selected: {}.\nUtterance: \"{utterance}\"",
        at.front_app.unwrap_or("unknown"),
        if at.focus == Focus::TextField { "yes" } else { "probably" },
        if at.has_selection { "yes" } else { "no" },
    );
    match router.choose(system, &user, "intent", &["command", "dictation"], Duration::from_millis(2500)).await.as_deref() {
        Some("command") => Decision { intent: Intent::Command, reason: format!("{}: command", router.name()), explicit: false },
        Some("dictation") => Decision::dictation(&format!("{}: dictation", router.name())),
        _ => {
            let why = crate::ai::last_error().map(|e| format!(": {e}")).unwrap_or_default();
            Decision::dictation(&format!("{} didn't answer{why}; typed", router.name()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct These(&'static [&'static str]);
    impl Apps for These {
        fn resolves(&self, name: &str) -> bool {
            self.0.iter().any(|app| app.eq_ignore_ascii_case(name))
        }
    }

    fn decide_now(text: &str, focus: Focus, selection: bool) -> Decision {
        let at = Situation { forced_command: false, focus, front_app: Some("notepad"), has_selection: selection, since_last: None };
        crate::ai::blocking(decide(text, &at, &These(&["slack", "spotify", "notepad"]), None))
    }

    fn intent(text: &str) -> Intent {
        decide_now(text, Focus::TextField, false).intent
    }

    #[test]
    fn commands() {
        assert_eq!(intent("open Slack"), Intent::Command);
        assert_eq!(intent("volume 30"), Intent::Command);
        assert_eq!(intent("Murmur, what's the weather like"), Intent::Command);
        assert_eq!(intent("remember that Mom is Roma"), Intent::Command);
        assert_eq!(intent("send a message to Riya on WhatsApp saying I'm late"), Intent::Command);
        assert_eq!(intent("Rahul ko WhatsApp pe message bhejo"), Intent::Command);
        assert_eq!(intent("open notepad and write a shopping list"), Intent::Command);
        assert_eq!(intent("what's on my screen"), Intent::Command);
        assert_eq!(decide_now("summarise this", Focus::TextField, true).intent, Intent::Command);
        let forced = Situation { forced_command: true, focus: Focus::TextField, front_app: None, has_selection: false, since_last: None };
        assert_eq!(crate::ai::blocking(decide("see you soon", &forced, &These(&[]), None)).reason, "command key held");
    }

    #[test]
    fn dictation() {
        assert_eq!(intent("see you at the meeting tomorrow"), Intent::Dictation);
        assert_eq!(intent("my photos from Goa are amazing"), Intent::Dictation);
        assert_eq!(intent("I think the launch went well"), Intent::Dictation);
        assert_eq!(intent("summarise this"), Intent::Dictation, "no selection: a sentence like any other");
        // Opens like an instruction, but no model to ask: typed (safe).
        let d = decide_now("check the numbers before Friday", Focus::TextField, false);
        assert_eq!(d.intent, Intent::Dictation);
        assert!(d.reason.contains("no model"));
    }

    #[test]
    fn nowhere_to_type() {
        assert_eq!(decide_now("check the downloads", Focus::NotText, false).intent, Intent::Command);
        assert_eq!(decide_now("mujhe PDF kholkar do", Focus::Unknown, false).intent, Intent::Command);
        assert_eq!(decide_now("how much space is left on my laptop", Focus::TextField, false).intent, Intent::Command);
    }

    #[test]
    fn selection_tasks() {
        assert_eq!(selection_task("summarise this"), Some(true));
        assert_eq!(selection_task("translate this to Hindi"), Some(false));
        assert_eq!(selection_task("make it more formal"), Some(false));
        assert_eq!(selection_task("make a list of groceries"), None);
        assert_eq!(selection_task("summarise this and email it to Riya"), None, "goes further: the model plans it");
    }
}
