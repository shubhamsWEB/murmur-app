//! What Murmur remembers between commands, as the Mac app's CommandMemory (kept simpler: a JSON file beside the
//! settings, memory.json): the facts and preferences you tell it ("remember that Mom is Roma", "from now on open links
//! in Chrome", "call me Shubham"), and the recent commands with what they did, so a follow-up ("open it again", "and
//! also search for…") and `recall` know what came before. Nothing leaves this PC.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Commands kept, and for how long.
const KEEP_COMMANDS: usize = 400;
const KEEP_DAYS: f64 = 90.0;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Fact {
    pub subject: String,
    pub text: String,
    pub at: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Episode {
    pub at: f64,
    /// The app in front ("WhatsApp", "chrome").
    #[serde(default)]
    pub app: String,
    pub said: String,
    /// What it did, in a few words ("opened Spotify; set the volume to 30%").
    pub summary: String,
    /// message, file, web, media, write, app, setting, answer, other.
    pub kind: String,
    /// The answer shown or the last result, cut short.
    #[serde(default)]
    pub result: String,
    /// The files opened (full paths), for "open it again".
    #[serde(default)]
    pub files: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct Store {
    facts: Vec<Fact>,
    episodes: Vec<Episode>,
}

/// One tool call a command made, for the record.
#[derive(Clone, Debug)]
pub struct Action {
    pub tool: String,
    pub arguments: serde_json::Map<String, serde_json::Value>,
    pub result: String,
}

pub struct Memory {
    file: Option<PathBuf>,
    store: Mutex<Store>,
}

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

impl Memory {
    /// The memory kept in `file` (none: in memory only, for tests).
    pub fn open(file: Option<PathBuf>) -> Memory {
        let store = file.as_ref().and_then(|path| std::fs::read(path).ok())
            .and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        Memory { file, store: Mutex::new(store) }
    }

    fn save(&self, store: &Store) {
        let Some(path) = &self.file else { return };
        if let Some(folder) = path.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        if let Ok(data) = serde_json::to_vec_pretty(store) {
            let partial = path.with_extension("json.partial");
            if std::fs::write(&partial, data).is_ok() {
                let _ = std::fs::rename(&partial, path);
            }
        }
    }

    // MARK: Facts you tell Murmur

    /// Keeps a fact under a short subject ("Roma", "browser", "message style"); the same subject again replaces it.
    pub fn remember(&self, subject: &str, fact: &str) -> String {
        let mut key = subject.trim().to_lowercase();
        if NAME_SUBJECTS.contains(&key.as_str()) || name_in(fact).is_some() {
            key = "my name".into(); // the user's own name always lives under one subject
        }
        let text = fact.trim();
        if key.is_empty() || text.is_empty() {
            return "Nothing to remember.".into();
        }
        let mut store = self.store.lock().unwrap();
        store.facts.retain(|f| f.subject != key);
        store.facts.push(Fact { subject: key, text: text.into(), at: now() });
        self.save(&store);
        format!("Remembered: {text}")
    }

    /// Drops the facts whose subject or text has these words.
    pub fn unremember(&self, words: &str) -> String {
        let wanted = words.trim().to_lowercase();
        if wanted.is_empty() {
            return "Which one?".into();
        }
        let mut store = self.store.lock().unwrap();
        let gone: Vec<String> = store.facts.iter()
            .filter(|f| f.subject == wanted || f.text.to_lowercase().contains(&wanted)).map(|f| f.text.clone()).collect();
        store.facts.retain(|f| !(f.subject == wanted || f.text.to_lowercase().contains(&wanted)));
        self.save(&store);
        if gone.is_empty() { format!("There was nothing about \"{words}\" to forget.") } else { format!("Forgot: {}", gone.join("; ")) }
    }

    /// What you told Murmur, newest first.
    pub fn facts(&self) -> Vec<Fact> {
        let mut facts = self.store.lock().unwrap().facts.clone();
        facts.sort_by(|a, b| b.at.total_cmp(&a.at));
        facts
    }

    /// "forget that" (the last command) or "clear your memory" (`all`: every command and fact).
    pub fn forget(&self, all: bool) {
        let mut store = self.store.lock().unwrap();
        if all {
            *store = Store::default();
        } else {
            store.episodes.pop();
        }
        self.save(&store);
    }

    /// One fact or command from Settings' Memory list: "fact:<n>" or "command:<n>" (its place, newest first).
    pub fn remove(&self, id: &str) {
        let mut store = self.store.lock().unwrap();
        let Some((kind, index)) = id.split_once(':') else { return };
        let Ok(index) = index.parse::<usize>() else { return };
        match kind {
            "fact" => {
                store.facts.sort_by(|a, b| b.at.total_cmp(&a.at));
                if index < store.facts.len() { store.facts.remove(index); }
            }
            "command" => {
                let count = store.episodes.len();
                if index < count { store.episodes.remove(count - 1 - index); }
            }
            _ => return,
        }
        self.save(&store);
    }

    // MARK: Preferences: memory as every command uses it

    pub fn preferences(&self) -> Preferences {
        let mut prefs = Preferences::default();
        for fact in self.facts() {
            let text = fact.text.clone();
            let lower = text.to_lowercase();
            prefs.notes.push(text.clone());
            if let Some(owner) = name_in(&text) {
                prefs.owner.get_or_insert(owner);
                continue;
            }
            if fact.subject == "my name" && text.split_whitespace().count() <= 4 {
                prefs.owner.get_or_insert(text.clone());
                continue;
            }
            // "Open links in Chrome", "browser: Edge".
            if prefs.browser.is_none() && (fact.subject.contains("browser") || has_word(&lower, &["link", "links", "browser", "web", "site", "sites", "page", "pages", "url", "search"])) {
                if let Some((_, name)) = BROWSERS.iter().find(|(word, _)| has_word(&lower, &[word])) {
                    prefs.browser = Some((*name).to_string());
                    continue;
                }
            }
            // "Mom is Roma", "my boss is Rahul Mehta", "Roma is my mom".
            if let Some((alias, person)) = alias_in(&text) {
                for word in person.to_lowercase().split_whitespace() {
                    prefs.cues.push(word.to_string());
                }
                prefs.aliases.push((alias, person));
            }
            for word in fact.subject.split_whitespace() {
                if word.len() > 2 && !PLAIN_WORDS.contains(&word) {
                    prefs.cues.push(word.to_string());
                }
            }
        }
        for (alias, _) in prefs.aliases.clone() {
            for word in alias.split_whitespace().filter(|w| !PLAIN_WORDS.contains(w)) {
                prefs.cues.push(word.to_string());
            }
        }
        prefs
    }

    // MARK: Commands

    /// Keeps a command and what it did.
    pub fn record(&self, said: &str, app: &str, actions: &[Action], answer: Option<&str>) {
        if actions.is_empty() && answer.is_none() {
            return;
        }
        let files = actions.iter().filter(|a| a.tool == "open_file" && a.result.starts_with("Opened "))
            .filter_map(|a| a.arguments.get("opened").and_then(|v| v.as_str()).map(String::from)).collect();
        let episode = Episode {
            at: now(),
            app: app.to_string(),
            said: said.to_string(),
            summary: summarise(actions, answer),
            kind: kind_of(actions).into(),
            result: crate::ai::cut(answer.unwrap_or_else(|| actions.last().map(|a| a.result.as_str()).unwrap_or_default()), 300),
            files,
        };
        let mut store = self.store.lock().unwrap();
        store.episodes.push(episode);
        let oldest = now() - KEEP_DAYS * 86400.0;
        store.episodes.retain(|e| e.at > oldest);
        let excess = store.episodes.len().saturating_sub(KEEP_COMMANDS);
        store.episodes.drain(..excess);
        self.save(&store);
    }

    /// The latest commands, newest first.
    pub fn recent(&self, limit: usize) -> Vec<Episode> {
        self.store.lock().unwrap().episodes.iter().rev().take(limit).cloned().collect()
    }

    /// Seconds since the last command.
    pub fn since_last(&self) -> Option<f64> {
        self.store.lock().unwrap().episodes.last().map(|e| now() - e.at)
    }

    /// The files opened in the last day, newest first.
    pub fn recent_files(&self) -> Vec<String> {
        let since = now() - 86400.0;
        self.store.lock().unwrap().episodes.iter().rev().filter(|e| e.at > since).flat_map(|e| e.files.clone()).collect()
    }

    /// What the model always gets: what you told Murmur, and the latest commands (last two hours).
    pub fn working_set(&self) -> Option<String> {
        let told = self.facts();
        let since = now() - 2.0 * 3600.0;
        let mut recent: Vec<Episode> = self.recent(5).into_iter().filter(|e| e.at > since).collect();
        recent.reverse();
        if told.is_empty() && recent.is_empty() {
            return None;
        }
        let mut lines = vec![];
        if !told.is_empty() {
            lines.push("The user told you (follow these over everything else):".to_string());
            lines.extend(told.iter().take(20).map(|f| format!("- {}", f.text)));
        }
        if !recent.is_empty() {
            lines.push("Latest commands (oldest first):".to_string());
            for e in &recent {
                lines.push(format!("{} in {}: \"{}\" → {}", ago(e.at), if e.app.is_empty() { "?" } else { &e.app }, e.said, e.summary));
            }
        }
        lines.push("Older history: call recall.".into());
        Some(lines.join("\n"))
    }

    /// The model's look further back: commands matching the words, within some days, newest first.
    pub fn recall(&self, query: &str, days: f64) -> String {
        let since = now() - days.max(0.01) * 86400.0;
        let words: Vec<String> = query.to_lowercase().split(|c: char| !c.is_alphanumeric())
            .filter(|w| w.len() > 1).map(String::from).collect();
        let found: Vec<Episode> = self.store.lock().unwrap().episodes.iter().rev()
            .filter(|e| e.at > since)
            .filter(|e| {
                let hay = format!("{} {} {} {}", e.said, e.summary, e.result, e.app).to_lowercase();
                words.is_empty() || words.iter().any(|w| hay.contains(w.as_str()))
            })
            .take(15).cloned().collect();
        if found.is_empty() {
            let about = if words.is_empty() { String::new() } else { format!(" about \"{query}\"") };
            return format!("Nothing in memory{about} from the last {} days.", days.max(1.0) as i64);
        }
        found.iter().map(|e| {
            let mut line = format!("{} in {}: \"{}\" → {}", ago(e.at), if e.app.is_empty() { "?" } else { &e.app }, e.said, e.summary);
            if !e.result.is_empty() && !e.summary.contains(&crate::ai::cut(&e.result, 40)) {
                line.push_str(&format!("\n    result: {}", crate::ai::cut(&e.result, 240)));
            }
            line
        }).collect::<Vec<_>>().join("\n")
    }
}

/// Memory, read once for a command.
#[derive(Clone, Debug, Default)]
pub struct Preferences {
    /// Your name ("Shubham Agrawal").
    pub owner: Option<String>,
    /// The browser for links and searches ("Chrome").
    pub browser: Option<String>,
    /// Nicknames to people: ("mom", "Roma").
    pub aliases: Vec<(String, String)>,
    /// Everything you told Murmur, as you said it.
    pub notes: Vec<String>,
    /// Words that point at something in memory.
    cues: Vec<String>,
}

impl Preferences {
    /// Whether the request mentions someone or something in memory (a nickname, a person, a subject): then the model,
    /// which sees all of memory, handles it rather than a quick pattern.
    pub fn touches(&self, utterance: &str) -> bool {
        let lower = utterance.to_lowercase();
        let words: Vec<&str> = lower.split(|c: char| !c.is_alphabetic()).filter(|w| !w.is_empty()).collect();
        self.cues.iter().any(|cue| words.contains(&cue.as_str()))
            || self.aliases.iter().any(|(alias, _)| alias.contains(' ') && lower.contains(alias.as_str()))
    }
}

const NAME_SUBJECTS: &[&str] = &["name", "my name", "user name", "user's name", "username", "full name", "own name",
                                   "user", "me", "owner", "the user's name"];
const BROWSERS: &[(&str, &str)] = &[("chrome", "Chrome"), ("edge", "Edge"), ("firefox", "Firefox"), ("brave", "Brave"),
                                     ("opera", "Opera"), ("vivaldi", "Vivaldi"), ("arc", "Arc")];
const PLAIN_WORDS: &[&str] = &["my", "the", "a", "an", "to", "of", "in", "on", "is", "and", "for", "with", "at", "it",
                                 "me", "i", "be", "always", "never", "use", "open", "opens", "link", "links", "message",
                                 "messages", "style", "short", "name", "browser", "keep", "make", "write", "reply",
                                 "replies", "please", "from", "now", "app", "apps", "his", "her", "their", "our", "your", "they"];

fn has_word(text: &str, words: &[&str]) -> bool {
    text.split(|c: char| !c.is_alphanumeric()).any(|w| words.contains(&w))
}

/// "My name is Shubham Agrawal", "call me Shubham", "I'm Shubham" → the name.
pub fn name_in(fact: &str) -> Option<String> {
    let text = fact.trim();
    let lower = text.to_lowercase();
    let starts = ["my full name is ", "my name is ", "my name's ", "call me ", "i am ", "i'm ", "the user's name is ",
                  "user's name is ", "name: "];
    let start = starts.iter().find(|s| lower.starts_with(*s))?;
    let name = text[start.len()..].trim_matches(|c: char| " .,!\"'".contains(c)).to_string();
    // A name, not "call me at five": a few words, the first capitalised.
    let first = name.chars().next()?;
    (first.is_uppercase() && name.split_whitespace().count() <= 5).then_some(name)
}

/// "Mom is Roma" → ("mom", "Roma"); "Roma is my mom" → ("mom", "Roma").
fn alias_in(text: &str) -> Option<(String, String)> {
    let words: Vec<&str> = text.trim_end_matches(['.', '!']).split_whitespace().collect();
    let is = words.iter().position(|w| *w == "is")?;
    let (left, right) = (&words[..is], &words[is + 1..]);
    let capitalised = |w: &&str| w.chars().next().is_some_and(char::is_uppercase);
    let strip_my = |part: &[&str]| -> Vec<String> {
        part.iter().filter(|w| !w.eq_ignore_ascii_case("my")).map(|w| w.trim_matches(',').to_string()).collect()
    };
    // "Roma is my mom": a name, then "my" + who.
    if !left.is_empty() && left.iter().all(capitalised) && right.first().is_some_and(|w| w.eq_ignore_ascii_case("my")) {
        let who = strip_my(right).join(" ").to_lowercase();
        return (!who.is_empty() && who.split_whitespace().count() <= 3).then(|| (who, left.join(" ")));
    }
    // "Mom is Roma", "my boss is Rahul Mehta, on WhatsApp".
    let who = strip_my(left).join(" ").to_lowercase();
    let person: Vec<String> = strip_my(right).into_iter().take_while(|w| w.chars().next().is_some_and(char::is_uppercase)).take(2).collect();
    (!who.is_empty() && who.split_whitespace().count() <= 3 && !person.is_empty()).then(|| (who, person.join(" ")))
}

/// "and also ask when she's coming back", "do it again", "open it", said within five minutes of a command.
pub fn is_follow_up(utterance: &str, since_last: Option<f64>) -> bool {
    if !since_last.is_some_and(|s| s < 300.0) {
        return false;
    }
    let text = super::quick::clean(utterance);
    if text.split_whitespace().count() > 20 {
        return false;
    }
    static FOLLOW: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    FOLLOW.get_or_init(|| regex::Regex::new(r"^(and|also|and also|then|and then|plus|oh and|one more thing|after that) (please )?(ask|tell|send|message|text|open|play|pause|stop|search|find|show|remind|reply|call|email|close|quit|turn|set|check|add|delete|share|save|copy|paste|summari[sz]e|translate|write|type|do)\b|^(tell|ask|send|message|text|reply to|remind|show|give) (her|him|them|it|that|those)\b|^(do it|do that|same thing|do it again|try again|send it|send that|open it|play it|paste it)\b").unwrap())
        .is_match(&text)
}

/// "forget that" → Some(false); "clear your memory", "forget everything" → Some(true).
pub fn forget_request(utterance: &str) -> Option<bool> {
    let text = super::quick::clean(utterance);
    static ALL: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static LAST: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    if ALL.get_or_init(|| regex::Regex::new(r"^(forget|clear|erase|wipe|delete) (everything|all|all of it|your memory|the memory|my history|the history|what you remember|all my commands)\b").unwrap()).is_match(&text) {
        return Some(true);
    }
    if LAST.get_or_init(|| regex::Regex::new(r"^(forget|delete|erase) (that|this|it|the last (command|one|thing)|what i (just )?(said|asked))$").unwrap()).is_match(&text) {
        return Some(false);
    }
    None
}

fn kind_of(actions: &[Action]) -> &'static str {
    for action in actions {
        return match action.tool.as_str() {
            "open_file" | "search_files" | "open_folder" => "file",
            "open_url" | "web_search" | "site_search" => "web",
            "media_control" => "media",
            "write_in_app" | "insert_text" | "replace_selection" | "type_text" => "write",
            "open_app" | "quit_app" | "hide_app" => "app",
            "set_volume" | "change_volume" | "mute" | "set_brightness" | "brightness" | "open_settings" | "lock_screen" => "setting",
            "reply" | "remember" | "recall" | "wait" | "done" | "read_clipboard" => continue,
            _ => "other",
        };
    }
    "answer"
}

fn summarise(actions: &[Action], answer: Option<&str>) -> String {
    let mut parts: Vec<String> = vec![];
    for action in actions {
        let a = |key: &str| action.arguments.get(key).map(|v| v.as_str().map(String::from).unwrap_or_else(|| v.to_string())).unwrap_or_default();
        let part = match action.tool.as_str() {
            "open_file" => format!("opened {}", if a("opened").is_empty() { a("query") } else { a("opened") }),
            "open_url" => format!("opened {}", a("url")),
            "web_search" => format!("searched the web for “{}”", a("query")),
            "site_search" => format!("searched {} for “{}”", a("site"), a("query")),
            "search_files" => format!("searched files for “{}”", a("query")),
            "open_app" => format!("opened {}", a("name")),
            "quit_app" => format!("quit {}", a("name")),
            "write_in_app" => format!("wrote in {}", a("app")),
            "media_control" => format!("{} media", a("action")),
            "set_volume" => format!("set the volume to {}%", a("percent")),
            "reply" | "done" | "wait" => continue,
            other => other.replace('_', " "),
        };
        if !parts.contains(&part) {
            parts.push(part);
        }
    }
    if let Some(answer) = answer {
        parts.push(format!("answered: “{}”", crate::ai::cut(answer, 100)));
    }
    if parts.is_empty() { "nothing".into() } else { parts.join("; ") }
}

fn ago(at: f64) -> String {
    let seconds = (now() - at).max(0.0);
    match seconds {
        s if s < 90.0 => "just now".into(),
        s if s < 3600.0 => format!("{} min ago", (s / 60.0).round() as i64),
        s if s < 86400.0 => format!("{} h ago", (s / 3600.0).round() as i64),
        s => format!("{} days ago", (s / 86400.0).round() as i64),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn action(tool: &str, args: serde_json::Value, result: &str) -> Action {
        Action { tool: tool.into(), arguments: args.as_object().unwrap().clone(), result: result.into() }
    }

    #[test]
    fn facts_and_preferences() {
        let memory = Memory::open(None);
        assert_eq!(memory.remember("name", "My name is Shubham Agrawal"), "Remembered: My name is Shubham Agrawal");
        memory.remember("browser", "From now on open links in Chrome");
        memory.remember("mom", "Mom is Roma, on WhatsApp");
        memory.remember("boss", "Rahul Mehta is my boss");
        let prefs = memory.preferences();
        assert_eq!(prefs.owner.as_deref(), Some("Shubham Agrawal"));
        assert_eq!(prefs.browser.as_deref(), Some("Chrome"));
        assert!(prefs.aliases.contains(&("mom".to_string(), "Roma".to_string())));
        assert!(prefs.aliases.contains(&("boss".to_string(), "Rahul Mehta".to_string())));
        assert!(prefs.touches("open mom's photos"));
        assert!(prefs.touches("message Roma"));
        assert!(!prefs.touches("open spotify"));
        // The same subject replaces; forgetting by words.
        memory.remember("browser", "Use Edge for links");
        assert_eq!(memory.preferences().browser.as_deref(), Some("Edge"));
        assert!(memory.unremember("roma").starts_with("Forgot: Mom is Roma"));
        assert_eq!(memory.facts().len(), 3);
    }

    #[test]
    fn names() {
        assert_eq!(name_in("call me Shubham").as_deref(), Some("Shubham"));
        assert_eq!(name_in("call me at five"), None);
        assert_eq!(name_in("I'm Riya Sharma.").as_deref(), Some("Riya Sharma"));
    }

    #[test]
    fn commands_are_kept_and_recalled() {
        let memory = Memory::open(None);
        memory.record("open my lease pdf", "explorer", &[action("open_file", json!({"query": "lease pdf", "opened": "C:\\Docs\\Lease 2025.pdf"}), "Opened Lease 2025.pdf.")], None);
        memory.record("what's the capital of peru", "chrome", &[action("reply", json!({"text": "Lima"}), "shown")], Some("Lima."));
        assert_eq!(memory.recent(5).len(), 2);
        assert_eq!(memory.recent_files(), vec!["C:\\Docs\\Lease 2025.pdf".to_string()]);
        assert!(memory.recall("lease", 30.0).contains("opened C:\\Docs\\Lease 2025.pdf"));
        assert!(memory.recall("peru", 30.0).contains("answered: “Lima.”"));
        assert!(memory.recall("bananas", 30.0).starts_with("Nothing in memory about \"bananas\""));
        let set = memory.working_set().unwrap();
        assert!(set.contains("Latest commands"));
        memory.forget(false);
        assert_eq!(memory.recent(5).len(), 1);
        memory.forget(true);
        assert!(memory.working_set().is_none());
    }

    #[test]
    fn follow_ups_and_forgetting() {
        assert!(is_follow_up("and also search for flights", Some(30.0)));
        assert!(is_follow_up("open it", Some(30.0)));
        assert!(!is_follow_up("open it", Some(900.0)));
        assert!(!is_follow_up("also I noticed a bug in the build", Some(30.0)));
        assert_eq!(forget_request("forget that"), Some(false));
        assert_eq!(forget_request("clear your memory"), Some(true));
        assert_eq!(forget_request("forget the milk"), None);
    }
}
