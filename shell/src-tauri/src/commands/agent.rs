//! A spoken command, carried out: the Mac's CommandAgent loop, for the tools Windows has (tools.rs). The quick
//! patterns first (quick.rs: "open Spotify", "volume 30"), then the model in steps: it calls tools, sees what they did,
//! and goes on until the request is done, it answers, or it runs out of steps. What it does on the PC is the host's
//! (actions.rs on Windows); what's decided here is the same everywhere, so it's tested with a scripted model.

use super::memory::{self, Memory, Preferences};
use super::{intent, quick, tools, wake};
use crate::ai::{self, output, AiError, Call, Reply, ToolSpec, Turn};
use serde_json::{Map, Value};
use std::time::{Duration, Instant};

/// Steps a command may take, and how long it may run.
const MAX_STEPS: usize = 16;
const TIME_CAP: Duration = Duration::from_secs(240);

/// A model that can call tools, asked one step at a time from this (plain) thread.
pub trait Model {
    fn name(&self) -> &'static str;
    fn is_local(&self) -> bool;
    fn chat(&self, system: &str, turns: &[Turn], tools: &[ToolSpec]) -> Result<Reply, AiError>;
}

impl Model for ai::Router {
    fn name(&self) -> &'static str {
        ai::Router::name(self)
    }

    fn is_local(&self) -> bool {
        ai::Router::is_local(self)
    }

    fn chat(&self, system: &str, turns: &[Turn], tools: &[ToolSpec]) -> Result<Reply, AiError> {
        // A local model on an ordinary PC reads a long prompt slowly the first time.
        let timeout = Duration::from_secs(if self.is_local() { 90 } else { 45 });
        ai::blocking(ai::Router::chat(self, system, turns, tools, timeout))
    }
}

/// A file the search found.
#[derive(Clone, Debug, PartialEq)]
pub struct FileHit {
    pub path: String,
    pub kind: String,
    /// Seconds since 1970.
    pub modified: f64,
    pub score: f64,
    pub excerpt: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outcome {
    pub result: String,
    /// The command is complete (an answer was shown, text was typed, a file opened from the quick path).
    pub finished: bool,
}

impl Outcome {
    pub fn said(result: impl Into<String>) -> Outcome {
        Outcome { result: result.into(), finished: false }
    }

    pub fn ended(result: impl Into<String>) -> Outcome {
        Outcome { result: result.into(), finished: true }
    }
}

/// What a command does on the PC, and how it talks to you.
pub trait Host {
    fn log(&mut self, line: &str);
    /// The pill, while it works.
    fn progress(&mut self, text: &str);
    /// An answer to read (the answer window).
    fn show_answer(&mut self, text: &str);
    /// Text typed where you were typing when you spoke (back to that window first). False when it couldn't be.
    fn insert(&mut self, text: &str) -> bool;
    /// Text put in place of the selection; false when the selection can't be edited there.
    fn replace_selection(&mut self, text: &str) -> bool;
    /// The best matches for a description of a file, best first.
    fn find_files(&mut self, query: &str) -> Vec<FileHit>;
    fn open_path(&mut self, path: &str) -> Result<(), String>;
    /// Murmur's window, searching for this.
    fn show_search(&mut self, query: &str);
    /// Yes or no from you (a dialog).
    fn confirm(&mut self, title: &str, detail: &str) -> bool;
    /// Settings → Commands & AI, when no model can answer.
    fn open_model_settings(&mut self);
    /// Whether an installed app goes by this name (for the quick path's "open …").
    fn resolves_app(&self, name: &str) -> bool;
    fn is_browser(&self, app: &str) -> bool;
    /// The PC's own tools (apps, places, the web, sound, the screen, keys, the clipboard). `browser`: the one to use
    /// for web pages, if one was named or chosen.
    fn act(&mut self, tool: &str, call: &Call, browser: Option<&str>) -> Outcome;
}

struct HostApps<'a>(&'a dyn Host);

impl quick::Apps for HostApps<'_> {
    fn resolves(&self, name: &str) -> bool {
        self.0.resolves_app(name)
    }
}

/// Where the command was spoken.
#[derive(Clone, Debug, Default)]
pub struct Context {
    /// "Tuesday, 22 October 2026, 14:05".
    pub now: String,
    pub front_app: Option<String>,
    pub window_title: Option<String>,
    /// The text selected where you are, if any.
    pub selection: Option<String>,
    /// The selection is in a box you can type in, so an edit of it can replace it.
    pub editable: bool,
    /// You clearly gave a command (Shift held, a command word); false when it was the model's guess.
    pub explicit: bool,
}

pub struct Agent<'a> {
    host: &'a mut dyn Host,
    memory: &'a Memory,
    /// The model chosen, and the local one to fall back on (the same when the local one was chosen).
    model: &'a dyn Model,
    local: &'a dyn Model,
    utterance: String,
    prefs: Preferences,
    did: Vec<memory::Action>,
    answer: Option<String>,
    /// Files offered for the model to pick from (open_file's matches).
    offered: Vec<String>,
    awaiting_pick: bool,
    browser: Option<String>,
}

impl<'a> Agent<'a> {
    pub fn new(host: &'a mut dyn Host, memory: &'a Memory, model: &'a dyn Model, local: &'a dyn Model) -> Agent<'a> {
        Agent { host, memory, model, local, utterance: String::new(), prefs: Preferences::default(), did: Vec::new(),
                answer: None, offered: Vec::new(), awaiting_pick: false, browser: None }
    }

    /// Runs one spoken command.
    pub fn run(&mut self, utterance: &str, context: &Context) {
        let started = Instant::now();
        let utterance = wake::strip(utterance).unwrap_or_else(|| utterance.trim().to_string());
        self.utterance = utterance.clone();
        let app = context.front_app.clone().unwrap_or_default();
        self.host.log(&format!("command: \"{}\" in {}, window \"{}\"", ai::cut(&utterance, 120), if app.is_empty() { "?" } else { &app },
                               ai::cut(context.window_title.as_deref().unwrap_or_default(), 80)));
        // "forget that", "clear your memory".
        if let Some(all) = memory::forget_request(&utterance) {
            if all && !self.host.confirm("Clear Murmur's memory?",
                                         "Every command it remembers, and everything you told it, is deleted from this PC.") {
                return;
            }
            self.memory.forget(all);
            self.host.show_answer(if all { "Done. My memory is empty now." } else { "Forgotten." });
            return;
        }
        self.prefs = self.memory.preferences();
        self.browser = self.prefs.browser.clone();
        let selection = context.selection.clone().filter(|s| !s.trim().is_empty());
        if let Some(selection) = &selection {
            if let Some(shows) = intent::selection_task(&utterance) {
                self.transform(selection, &utterance, shows || !context.editable);
                self.host.log(&format!("command: selection task done in {:.2} s", started.elapsed().as_secs_f64()));
                self.finish(&app);
                return;
            }
        }
        // A request about someone or something in memory ("open Mom's photos") goes to the model, which sees it all.
        let quick = if self.prefs.touches(&utterance) {
            self.host.log("command: mentions something in memory; the model handles it");
            None
        } else {
            quick::parse_all(&utterance, &HostApps(&*self.host))
        };
        if let Some(actions) = quick {
            let mut results = Vec::new();
            let several = actions.len() > 1;
            for action in actions {
                // "open chrome and search facebook": after opening a browser, "search" means the web, in it.
                let mut tool = action.tool.clone();
                if tool == "search_files" && self.browser_opened() {
                    tool = "web_search".into();
                }
                let arguments: Map<String, Value> = action.arguments.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect();
                self.host.log(&format!("command: quick path → {tool} {:?}", action.arguments));
                let call = Call { id: format!("quick-{}", results.len()), name: tool.clone(), arguments };
                let outcome = self.execute(&call, false);
                results.push(outcome.result.clone());
                if outcome.finished {
                    break;
                }
                if several && tool == "open_app" {
                    std::thread::sleep(Duration::from_millis(400)); // let the app come up before the next step
                }
            }
            let summary = results.join(" ");
            self.host.log(&format!("command: done in {:.2} s: {summary}", started.elapsed().as_secs_f64()));
            self.host.progress(&summary);
            self.finish(&app);
            return;
        }
        self.route(&utterance, context, selection.as_deref());
        self.host.log(&format!("command: finished in {:.2} s", started.elapsed().as_secs_f64()));
        self.finish(&app);
    }

    fn finish(&mut self, app: &str) {
        let did = std::mem::take(&mut self.did);
        self.memory.record(&self.utterance, app, &did, self.answer.as_deref());
    }

    fn browser_opened(&self) -> bool {
        self.did.iter().any(|a| a.tool == "open_app" && a.arguments.get("name").and_then(Value::as_str).is_some_and(|n| self.host.is_browser(n)))
    }

    fn show(&mut self, text: &str) {
        self.answer = Some(text.to_string());
        self.host.show_answer(text);
    }

    // MARK: Selected text

    /// Does what you asked with the selected text: one plain answer from the model, no tools. A summary or an
    /// explanation is shown; an edit replaces the selection when it's in a text field (else it's shown to paste).
    fn transform(&mut self, selection: &str, instruction: &str, show: bool) {
        self.host.progress(if show { "Reading the selected text…" } else { "Working on the selected text…" });
        let words = selection.split_whitespace().count();
        let mut system = format!(
            "You help with text the user selected on their Windows PC. Follow their spoken instruction on the selected text \
             and reply with only the result: no preamble, no quotation marks, no notes about what you did. Keep the text's \
             language unless asked to translate. A summary is at most {} words: a few short sentences or bullet points, \
             never longer than the text. An explanation is short and plain.", (words / 4).max(30));
        if !self.prefs.notes.is_empty() {
            system += "\nWhat the user told you about themselves and how they like things (follow it where it applies):\n";
            system += &self.prefs.notes.iter().take(20).map(|n| format!("- {n}")).collect::<Vec<_>>().join("\n");
        }
        let turns = [Turn::User(format!("Instruction: {instruction}\n\nSelected text:\n\"\"\"\n{}\n\"\"\"", ai::cut(selection, 12_000)))];
        let mut model = self.model;
        let mut reply = model.chat(&system, &turns, &[]);
        if let Err(error) = &reply {
            self.host.log(&format!("command: {} failed on the selection: {error}", model.name()));
            ai::set_last_error(Some(error.to_string()));
            if !model.is_local() {
                model = self.local;
                self.host.progress("Using the local model…");
                reply = model.chat(&system, &turns, &[]);
            }
        }
        let error = reply.as_ref().err().map(|e| e.to_string());
        let text = reply.map(|r| output::answer(&r.text)).unwrap_or_default();
        if text.is_empty() {
            self.show(&format!("Couldn't do that with the selected text. {}", error.unwrap_or_else(|| "The model didn't answer.".into())));
            return;
        }
        self.host.log(&format!("command: {} worked on {} selected characters → {}", model.name(), selection.chars().count(), text.chars().count()));
        if show {
            self.show(&text);
        } else if self.host.replace_selection(&text) {
            self.did.push(memory::Action { tool: "replace_selection".into(), arguments: Map::new(), result: "Replaced the selected text.".into() });
        } else {
            self.host.log("command: the selection can't be edited there; showing the result instead");
            self.show(&text);
        }
    }

    // MARK: The model, step by step

    fn route(&mut self, utterance: &str, context: &Context, selection: Option<&str>) {
        let mut situation = format!("Now: {}.", context.now);
        situation += &format!("\nFront app (where the user is): {}.", context.front_app.as_deref().unwrap_or("unknown"));
        if let Some(title) = context.window_title.as_deref().filter(|t| !t.is_empty()) {
            situation += &format!(" Its window: \"{}\".", ai::cut(title, 150));
        }
        if let Some(memory) = self.memory.working_set() {
            situation += &format!("\nMemory (what \"she\", \"him\", \"it\", \"also\", \"again\" and \"that\" refer to):\n{memory}");
        }
        if let Some(selection) = selection {
            situation += &format!("\nSelected text (what \"this\", \"it\" and \"the selection\" mean):\n\"\"\"\n{}\n\"\"\"", ai::cut(selection, 8000));
        }
        let system = format!("{}\n\n{situation}", tools::system_prompt());
        let tools = tools::all();
        let mut model = self.model;
        let mut turns = vec![Turn::User(utterance.to_string())];
        self.host.progress("Thinking…");
        let mut last_signature = String::new();
        let mut repeats = 0;
        let mut did_more_than_open = false;
        let mut checks_before_done = 0;
        let mut nudged = false;
        let more_steps = has_more_than_one_step(utterance);
        let began = Instant::now();
        for step in 0..MAX_STEPS {
            if began.elapsed() > TIME_CAP {
                self.host.log(&format!("command: stopped at step {} ({} s)", step + 1, began.elapsed().as_secs()));
                self.wrap_up(model, &system, &turns, &tools);
                return;
            }
            let asked = Instant::now();
            let sent = compacted(&turns);
            let reply = match model.chat(&system, &sent, &tools) {
                Ok(reply) => {
                    self.host.log(&format!("command: {} step {} took {:.2} s", model.name(), step + 1, asked.elapsed().as_secs_f64()));
                    if !model.is_local() {
                        ai::set_last_error(None);
                    }
                    reply
                }
                Err(error) => {
                    self.host.log(&format!("command: {} failed at step {}: {error}", model.name(), step + 1));
                    ai::set_last_error(Some(error.to_string())); // a rejected key isn't asked again
                    let mut answer = None;
                    // Too slow, or the connection dropped: once more before giving up on it.
                    if matches!(error, AiError::Unreachable(_)) {
                        self.host.progress(&format!("Still working… (step {})", step + 1));
                        answer = model.chat(&system, &sent, &tools).ok();
                    }
                    // A cloud model that still fails (offline, a bad key) hands over to the local model.
                    let mut last = error.clone();
                    if answer.is_none() && !model.is_local() {
                        model = self.local;
                        self.host.progress(&format!("{error} Using the local model…"));
                        match model.chat(&system, &sent, &tools) {
                            Ok(reply) => answer = Some(reply),
                            Err(local) => last = local,
                        }
                    }
                    match answer {
                        Some(reply) => reply,
                        None => {
                            if step == 0 && self.search_instead(utterance) {
                                return;
                            }
                            if matches!(last, AiError::OllamaNotRunning) && !ai::ollama_installed() {
                                self.host.log("command: no model for this (Ollama isn't installed, no cloud key worked)");
                                self.show(ai::NEEDS_MODEL);
                                self.host.open_model_settings();
                                return;
                            }
                            let said = if step == 0 { last.to_string() } else { format!("I stopped partway: {last} Try asking again.") };
                            self.show(&said);
                            return;
                        }
                    }
                }
            };
            let only_answers = reply.calls.iter().all(|c| c.name == "reply" || c.name == "done");
            if !context.explicit && step == 0 && only_answers {
                // A guessed command that only answers: it was dictation. Type the words.
                self.host.log("command: guessed command only answered; typing the words instead");
                self.host.insert(utterance);
                return;
            }
            if reply.calls.is_empty() {
                // A model sometimes answers in plain text: that's the reply.
                let text = output::answer(&reply.text);
                if !text.is_empty() {
                    self.show(&text);
                    return;
                }
                // Nothing at all: ask once more rather than stop silently half-way.
                if nudged {
                    self.wrap_up(model, &system, &turns, &tools);
                    return;
                }
                nudged = true;
                turns.push(Turn::User("Continue the request with tool calls: the next step, reply with the answer, or done.".into()));
                continue;
            }
            turns.push(Turn::Assistant { text: reply.text.clone(), calls: reply.calls.clone() });
            let mut finished_now = false;
            let mut results = Vec::new();
            for (index, call) in reply.calls.iter().enumerate() {
                self.host.log(&format!("command: step {} → {} {}", step + 1, call.name, ai::cut(&Value::Object(call.arguments.clone()).to_string(), 300)));
                if call.name == "done" && self.awaiting_pick {
                    // open_file and done in one response: the matches came back, nothing has opened yet.
                    self.host.log("command: done before picking from the matches; asking for the pick");
                    turns.push(result(call, "Not done: nothing has opened yet. Pick the user's file from the matches above and call \
                                             open_file with its exact path, or reply that none of them is it."));
                    continue;
                }
                if call.name == "done" {
                    if checks_before_done < 1 && more_steps && !did_more_than_open {
                        checks_before_done += 1;
                        self.host.log(&format!("command: done at step {} after only opening something; going on", step + 1));
                        turns.push(result(call, &format!("Not done yet. The user asked: \"{utterance}\". So far you only opened \
                            something. Do the rest now (write it, search it, answer it), then call done.")));
                        continue;
                    }
                    turns.push(result(call, "ok"));
                    finished_now = true;
                    continue;
                }
                // reply ends the command, so a reply with more steps after it is a progress note, not the answer.
                if call.name == "reply" && reply.calls[index + 1..].iter().any(|c| c.name != "done" && c.name != "reply") {
                    self.host.progress(&ai::cut(&call.text("text"), 140));
                    turns.push(result(call, "Noted as progress, not shown as the answer: reply finishes the command, so keep \
                                             it for the final answer."));
                    continue;
                }
                if !tools::OPENING_TOOLS.contains(&call.name.as_str()) {
                    did_more_than_open = true;
                }
                let outcome = self.execute(call, true);
                if outcome.finished {
                    // "my PAN card and my resume": one opened, another part may still wait.
                    let more = reply.calls[index + 1..].iter().any(|c| c.name != "done" && c.name != "reply");
                    if !more && !self.awaiting_pick {
                        return;
                    }
                    self.host.log("command: one part finished; going on with the rest");
                    results.push(outcome.result.clone());
                    turns.push(result(call, &format!("{} (That part is done. Finish the rest of the request.)", outcome.result)));
                    continue;
                }
                if call.name == "open_file" {
                    self.awaiting_pick = outcome.result.starts_with("Files matching");
                } else if call.name == "search_files" {
                    self.awaiting_pick = false;
                }
                results.push(outcome.result.clone());
                turns.push(result(call, &outcome.result));
            }
            if let Some(last) = results.last() {
                self.host.progress(&ai::cut(last, 140));
            }
            if finished_now {
                return;
            }
            // Going round in circles: stop rather than loop to the limit.
            let signature = reply.calls.iter().map(|c| format!("{}{}", c.name, Value::Object(c.arguments.clone()))).collect::<Vec<_>>().join("|");
            let browsing = reply.calls.iter().all(|c| c.name == "wait");
            repeats = if signature == last_signature && !browsing { repeats + 1 } else { 0 };
            last_signature = signature;
            if repeats >= 2 {
                self.host.log("command: the same step three times; stopping");
                self.wrap_up(model, &system, &turns, &tools);
                return;
            }
            if repeats == 1 {
                turns.push(Turn::User("That's the same step as before and it didn't get anywhere. Try another way, or reply \
                                       saying what's stopping you.".into()));
            }
            self.host.progress(&format!("Working… (step {})", step + 2));
        }
        self.host.log(&format!("command: stopped after {MAX_STEPS} steps"));
        self.wrap_up(model, &system, &turns, &tools);
    }

    /// Out of steps, or going round in circles: the model says what it found and what's left, rather than nothing.
    fn wrap_up(&mut self, model: &dyn Model, system: &str, turns: &[Turn], tools: &[ToolSpec]) {
        let mut turns = turns.to_vec();
        turns.push(Turn::User("Stop here. Call reply now: in two or three sentences, what you found or did for the request, \
                               with any answer you have, and what's still left to do.".into()));
        let reply_only: Vec<ToolSpec> = tools.iter().filter(|t| t.name == "reply").cloned().collect();
        if let Ok(last) = model.chat(system, &compacted(&turns), &reply_only) {
            if let Some(call) = last.calls.iter().find(|c| c.name == "reply") {
                self.show(&call.text("text"));
                return;
            }
            let text = output::answer(&last.text);
            if !text.is_empty() {
                self.show(&text);
                return;
            }
        }
        self.show("I couldn't finish that one. Try asking again, or in smaller steps.");
    }

    /// No model answered, but it sounds like a search ("search my resume", "find the lease"): your files, rather than
    /// an error.
    fn search_instead(&mut self, utterance: &str) -> bool {
        let text = quick::clean(utterance);
        static START: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
        let start = START.get_or_init(|| regex::Regex::new(r"^(search|find|look for|look up|open|show me|show|get)( for)? ").unwrap());
        let Some(found) = start.find(&text) else { return false };
        let query = text[found.end()..].trim().to_string();
        if query.is_empty() {
            return false;
        }
        self.host.log(&format!("command: no model answered; searching files for \"{query}\""));
        self.host.show_search(&query);
        true
    }

    // MARK: Tools

    /// Runs a tool, and keeps what it did for the next command.
    fn execute(&mut self, call: &Call, routing: bool) -> Outcome {
        let (outcome, opened) = self.perform(call, routing);
        let said = ai::cut(&outcome.result, 200).replace('\n', " ⏎ ");
        self.host.log(&format!("command:   ↳ {said}{}", if outcome.result.chars().count() > 200 { "…" } else { "" }));
        let mut arguments: Map<String, Value> = call.arguments.iter()
            .map(|(k, v)| (k.clone(), Value::String(ai::cut(v.as_str().map(String::from).unwrap_or_else(|| v.to_string()).as_str(), 200))))
            .collect();
        if let Some(path) = opened {
            arguments.insert("opened".into(), Value::String(path));
        }
        self.did.push(memory::Action { tool: call.name.clone(), arguments, result: ai::cut(&outcome.result, 300) });
        outcome
    }

    /// What a tool did, and the file it opened (if it opened one).
    fn perform(&mut self, call: &Call, routing: bool) -> (Outcome, Option<String>) {
        let text = |key: &str| call.text(key);
        let outcome = match call.name.as_str() {
            "open_file" => return self.open_file(&text("query"), routing),
            "search_files" => {
                let query = search_words(&text("query"));
                self.host.show_search(&query);
                Outcome::ended(format!("Showing file search results for \"{query}\"."))
            }
            "reply" => {
                let answer = text("text");
                self.show(&answer);
                Outcome::ended("Shown.")
            }
            "insert_text" => {
                let words = text("text");
                if self.host.insert(&words) {
                    Outcome::ended("Typed it where you were.")
                } else {
                    self.show(&words);
                    Outcome::ended("Couldn't type it there; showed it instead.")
                }
            }
            "replace_selection" => {
                let words = text("text");
                if self.host.replace_selection(&words) {
                    Outcome::ended("Replaced the selected text.")
                } else {
                    self.show(&words);
                    Outcome::ended("The selected text can't be edited there; showed the result instead.")
                }
            }
            "remember" => {
                let result = self.memory.remember(&text("subject"), &text("fact"));
                self.prefs = self.memory.preferences();
                self.host.progress(&result);
                Outcome::said(result)
            }
            "forget_fact" => Outcome::said(self.memory.unremember(&text("about"))),
            "recall" => Outcome::said(self.memory.recall(&text("query"), call.number("days").unwrap_or(30.0))),
            "quit_app" => {
                let name = text("name");
                if !self.host.confirm(&format!("Close {name}?"), "It will ask about any unsaved work, as closing its window does.") {
                    return (Outcome::ended(format!("You cancelled closing {name}.")), None);
                }
                self.host.act("quit_app", call, None)
            }
            "write_in_app" => {
                let body = text("text");
                if body.trim().is_empty() {
                    return (Outcome::said("There was nothing to write."), None);
                }
                self.host.progress(&format!("Writing in {}…", text("app")));
                let outcome = self.host.act("write_in_app", call, None);
                if !outcome.finished {
                    // The app didn't open or take the text: the words aren't lost.
                    self.show(&format!("{}\n\nHere's what I wrote:\n\n{body}", outcome.result));
                    return (Outcome::ended(outcome.result), None);
                }
                outcome
            }
            "open_url" | "web_search" | "site_search" => {
                let named = text("browser");
                if !named.is_empty() && self.host.is_browser(&named) {
                    self.browser = Some(named);
                }
                let browser = self.browser.clone();
                self.host.act(&call.name, call, browser.as_deref())
            }
            "open_app" => {
                let outcome = self.host.act("open_app", call, None);
                let name = text("name");
                if self.host.is_browser(&name) {
                    self.browser = Some(name);
                }
                outcome
            }
            "done" => Outcome::ended("ok"),
            _ => {
                let browser = self.browser.clone();
                self.host.act(&call.name, call, browser.as_deref())
            }
        };
        (outcome, None)
    }

    /// A file by its path or exact name, or by a description: a clear best match opens; close ones go back to the
    /// model to pick from (it knows what was said, memory and the screen).
    fn open_file(&mut self, asked: &str, routing: bool) -> (Outcome, Option<String>) {
        let mut query = asked.trim().to_string();
        let picked = self.offered.iter().any(|p| same_path(p, &query));
        let mut afresh = false;
        // The file from an earlier command only when the user points back at it ("open it again", its name). "Open the
        // PDF" is a new request: handing back the remembered file opened the same one every time.
        if !picked && names_a_file(&query) {
            if let Some(earlier) = earlier_file(&query, &self.memory.recent_files()) {
                if !points_back(&self.utterance, &earlier) {
                    query = file_words(&self.utterance);
                    afresh = true;
                    self.host.log(&format!("command: {earlier} is the file from before, but this asks for one afresh: finding \"{query}\""));
                }
            }
        }
        if picked || (!afresh && is_path(&query) && std::path::Path::new(&query).exists()) {
            return self.open_exact(&query);
        }
        self.host.progress(&format!("Finding \"{query}\"…"));
        let found = self.host.find_files(&query);
        // An exact file name the model gave back.
        if !afresh {
            if let Some(hit) = found.iter().find(|hit| same_path(&hit.path, &query) || file_name(&hit.path).eq_ignore_ascii_case(&query)) {
                let path = hit.path.clone();
                return self.open_exact(&path);
            }
        }
        let clear = found.len() == 1 || (found.len() > 1 && found[0].score >= found[1].score * 1.4);
        if found.is_empty() {
            return (Outcome::said(format!("No file matching \"{query}\" was found. Try other words, or search_files to show \
                                           what there is.")), None);
        }
        if clear || !routing {
            let path = found[0].path.clone();
            let (mut outcome, opened) = self.open_exact(&path);
            outcome.finished = true;
            return (outcome, opened);
        }
        let matches: Vec<FileHit> = found.into_iter().take(5).collect();
        self.offered = matches.iter().map(|m| m.path.clone()).collect();
        self.host.log(&format!("command: {} close matches for \"{query}\"; the model picks", matches.len()));
        (Outcome::said(describe(&matches, &query)), None)
    }

    fn open_exact(&mut self, path: &str) -> (Outcome, Option<String>) {
        self.awaiting_pick = false;
        match self.host.open_path(path) {
            Ok(()) => (Outcome::said(format!("Opened {}.", file_name(path))), Some(path.to_string())),
            Err(error) => (Outcome::said(format!("Couldn't open {}: {error}", file_name(path))), None),
        }
    }
}

fn result(call: &Call, content: &str) -> Turn {
    Turn::ToolResult { id: call.id.clone(), name: call.name.clone(), content: content.to_string() }
}

/// Long results (a clipboard, recalled history) slow every later step: keep the latest two in full, cut older ones.
pub fn compacted(turns: &[Turn]) -> Vec<Turn> {
    let mut keep = 2;
    let mut out = turns.to_vec();
    for turn in out.iter_mut().rev() {
        if let Turn::ToolResult { content, .. } = turn {
            if content.chars().count() > 1200 {
                if keep > 0 {
                    keep -= 1;
                    continue;
                }
                *content = format!("{}\n… (older text cut; ask again if you need it)", ai::cut(content, 500));
            }
        }
    }
    out
}

/// "open notepad and write a list", "go to YouTube, then play lofi": a second part after the first.
pub fn has_more_than_one_step(utterance: &str) -> bool {
    let text = quick::clean(utterance);
    static MORE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    MORE.get_or_init(|| regex::Regex::new(r"(\band\b|\bthen\b|,)\s*(then\s+)?(also\s+)?[a-z]+").unwrap()).is_match(&text)
        && text.split_whitespace().count() >= 4
}

/// "my resume" → "resume cv": the possessive only adds noise, and a CV is a résumé.
pub fn search_words(query: &str) -> String {
    static LEAD: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static CV: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let mut query = LEAD.get_or_init(|| regex::Regex::new(r"(?i)^(my|the|all|some) ").unwrap()).replace(query.trim(), "").to_string();
    if CV.get_or_init(|| regex::Regex::new(r"(?i)\b(cv|resume|résumé)\b").unwrap()).is_match(&query) && query.split_whitespace().count() <= 3 {
        let lower = query.to_lowercase();
        query = if lower.starts_with("cv") || lower.starts_with("resume") { "resume cv".into() } else { format!("resume cv {query}") };
    }
    query
}

/// The matches, for the model to pick from: name, kind, folder, a line from inside, and the path to open.
pub fn describe(files: &[FileHit], query: &str) -> String {
    let mut lines = vec![format!("Files matching \"{query}\", best match first. Open the one the user asked for: open_file \
                                  with its exact path. If none of them is it, reply saying so (or search_files to show them all).")];
    for (index, file) in files.iter().enumerate() {
        let folder = std::path::Path::new(&file.path).parent().map(|p| p.display().to_string()).unwrap_or_default();
        let mut line = format!("{}. {} · {} · in {folder}", index + 1, file_name(&file.path), file.kind);
        if let Some(excerpt) = file.excerpt.as_deref().map(|e| e.replace(['«', '»'], "")).filter(|e| !e.trim().is_empty()) {
            line += &format!(" · \"{}\"", ai::cut(&excerpt, 140));
        }
        lines.push(format!("{line}\n   path: {}", file.path));
    }
    lines.join("\n")
}

fn file_name(path: &str) -> String {
    path.rsplit(['\\', '/']).next().unwrap_or(path).to_string()
}

fn is_path(query: &str) -> bool {
    let bytes = query.as_bytes();
    query.starts_with('/') || query.starts_with("\\\\") || (bytes.len() > 2 && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/'))
}

fn same_path(a: &str, b: &str) -> bool {
    a.replace('/', "\\").eq_ignore_ascii_case(&b.replace('/', "\\"))
}

/// A path or a file name ("C:\…\Aadhar.pdf", "Aadhar.pdf"), not a description ("Aadhaar card").
pub fn names_a_file(query: &str) -> bool {
    let query = query.trim();
    if is_path(query) {
        return true;
    }
    match query.rsplit_once('.') {
        Some((stem, ext)) => !stem.is_empty() && (1..=5).contains(&ext.len()) && ext.chars().all(char::is_alphanumeric),
        None => false,
    }
}

fn fold(text: &str) -> String {
    text.to_lowercase()
}

/// The earlier file a query names: its path or exact name, or every word of the query found in the name.
pub fn earlier_file(query: &str, recent: &[String]) -> Option<String> {
    let asked = fold(&file_name(query));
    let words: Vec<String> = asked.split(|c: char| !c.is_alphanumeric()).filter(|w| w.chars().count() > 2).map(String::from).collect();
    recent.iter().find(|path| {
        let name = fold(&file_name(path));
        name == asked || (!words.is_empty() && words.iter().all(|w| name.contains(w.as_str())))
    }).cloned()
}

/// The user means the file from before: "it", "that", "again", "wahi", "phir se", or words of its name ("my PAN card"
/// for PanCard.pdf).
pub fn points_back(utterance: &str, path: &str) -> bool {
    let text = quick::clean(utterance);
    static BACK: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    if BACK.get_or_init(|| regex::Regex::new(r"\b(it|that|this|same|again|previous|last|earlier|wahi|wohi|vahi|wo|woh|vo|voh|usko|use|usse|isko|ise|yahi|phir se|fir se|dobara|pichl[ia]|abhi wal[ia])\b").unwrap())
        .is_match(&text) {
        return true;
    }
    // Doubled letters folded: "aadhaar" said, "Aadhar.pdf" named; "PanCard" is "pan" and "card".
    let squeeze = |text: &str| -> String {
        let mut out = String::new();
        for ch in text.to_lowercase().chars() {
            if !out.ends_with(ch) {
                out.push(ch);
            }
        }
        out
    };
    let name = file_name(path);
    let stem = name.rsplit_once('.').map(|(s, _)| s.to_string()).unwrap_or(name);
    // CamelCase apart: "PanCard" → "Pan Card".
    let mut spaced = String::new();
    for (i, ch) in stem.chars().enumerate() {
        if i > 0 && ch.is_uppercase() {
            spaced.push(' ');
        }
        spaced.push(ch);
    }
    const GENERIC: &[&str] = &["pdf", "pdfs", "doc", "docx", "file", "document", "copy", "final", "new", "untitled"];
    let said: Vec<String> = squeeze(&text).split(|c: char| !c.is_alphanumeric()).map(String::from).collect();
    squeeze(&spaced).split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.chars().count() > 2 && !GENERIC.contains(w))
        .any(|w| said.iter().any(|s| s == w))
}

/// The words that describe the file in what was said: "mujhe PDF kholkar do" → "PDF".
pub fn file_words(utterance: &str) -> String {
    const DROP: &[&str] = &[
        "open", "opens", "launch", "show", "find", "get", "bring", "up", "pull", "me", "please", "pls", "for", "can",
        "you", "could", "would", "murmur", "hey", "the", "a", "an", "mujhe", "muje", "mujhko", "humein", "hume",
        "ko", "do", "de", "dena", "dijiye", "dijie", "karo", "kar", "kare", "karein", "karna", "kholo", "khol",
        "kholkar", "kholke", "kholiye", "kholna", "kholdo", "dikhao", "dikha", "dikhaiye", "dhundo", "dhoondo",
        "dhundho", "dhoondho", "zara", "jara", "ek", "toh", "to", "na", "mera", "meri", "mere", "apna", "apni",
        "apne", "wala", "wali", "wale", "ka", "ki", "ke", "se", "hai",
    ];
    let cleaned = quick::clean(utterance);
    let kept: Vec<&str> = cleaned.split_whitespace().filter(|w| !DROP.contains(&w.to_lowercase().as_str())).collect();
    if kept.is_empty() { utterance.to_string() } else { kept.join(" ") }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::RefCell;

    /// A model that answers from a script, one reply per step, and keeps what it was sent.
    struct Scripted {
        replies: RefCell<Vec<Result<Reply, AiError>>>,
        local: bool,
        seen: RefCell<Vec<Vec<Turn>>>,
    }

    impl Scripted {
        fn new(local: bool, replies: Vec<Result<Reply, AiError>>) -> Scripted {
            Scripted { replies: RefCell::new(replies), local, seen: RefCell::new(Vec::new()) }
        }
    }

    impl Model for Scripted {
        fn name(&self) -> &'static str {
            if self.local { "Local model" } else { "Claude" }
        }
        fn is_local(&self) -> bool {
            self.local
        }
        fn chat(&self, _system: &str, turns: &[Turn], _tools: &[ToolSpec]) -> Result<Reply, AiError> {
            self.seen.borrow_mut().push(turns.to_vec());
            let mut replies = self.replies.borrow_mut();
            if replies.is_empty() {
                return Ok(Reply::default());
            }
            replies.remove(0)
        }
    }

    fn calls(list: &[(&str, Value)]) -> Result<Reply, AiError> {
        Ok(Reply {
            text: String::new(),
            calls: list.iter().enumerate().map(|(i, (name, args))| Call {
                id: format!("c{i}"), name: name.to_string(), arguments: args.as_object().cloned().unwrap_or_default(),
            }).collect(),
        })
    }

    #[derive(Default)]
    struct Fake {
        did: Vec<String>,
        answers: Vec<String>,
        typed: Vec<String>,
        files: Vec<FileHit>,
        opened: Vec<String>,
        searched: Vec<String>,
        editable: bool,
        confirms: bool,
    }

    impl Host for Fake {
        fn log(&mut self, _line: &str) {}
        fn progress(&mut self, _text: &str) {}
        fn show_answer(&mut self, text: &str) {
            self.answers.push(text.into());
        }
        fn insert(&mut self, text: &str) -> bool {
            self.typed.push(text.into());
            true
        }
        fn replace_selection(&mut self, text: &str) -> bool {
            if self.editable {
                self.typed.push(text.into());
            }
            self.editable
        }
        fn find_files(&mut self, _query: &str) -> Vec<FileHit> {
            self.files.clone()
        }
        fn open_path(&mut self, path: &str) -> Result<(), String> {
            self.opened.push(path.into());
            Ok(())
        }
        fn show_search(&mut self, query: &str) {
            self.searched.push(query.into());
        }
        fn confirm(&mut self, _title: &str, _detail: &str) -> bool {
            self.confirms
        }
        fn open_model_settings(&mut self) {}
        fn resolves_app(&self, name: &str) -> bool {
            ["spotify", "notepad", "chrome", "slack"].contains(&name.to_lowercase().as_str())
        }
        fn is_browser(&self, app: &str) -> bool {
            ["chrome", "edge", "firefox"].contains(&app.to_lowercase().as_str())
        }
        fn act(&mut self, tool: &str, call: &Call, browser: Option<&str>) -> Outcome {
            let args = Value::Object(call.arguments.clone());
            self.did.push(format!("{tool} {args}{}", browser.map(|b| format!(" in {b}")).unwrap_or_default()));
            match tool {
                "write_in_app" => Outcome::ended(format!("Wrote it in {}.", call.text("app"))),
                _ => Outcome::said(format!("{tool}: ok")),
            }
        }
    }

    fn hit(path: &str, score: f64) -> FileHit {
        FileHit { path: path.into(), kind: "pdf".into(), modified: 0.0, score, excerpt: None }
    }

    fn explicit() -> Context {
        Context { now: "Thursday".into(), front_app: Some("Notepad".into()), explicit: true, ..Context::default() }
    }

    #[test]
    fn quick_commands_need_no_model() {
        let memory = Memory::open(None);
        let model = Scripted::new(true, vec![]);
        let mut host = Fake::default();
        Agent::new(&mut host, &memory, &model, &model).run("open spotify", &explicit());
        assert_eq!(host.did.len(), 1);
        assert!(host.did[0].starts_with("open_app"));
        assert!(model.seen.borrow().is_empty());
        assert_eq!(memory.recent(5)[0].said, "open spotify");
    }

    #[test]
    fn steps_until_done() {
        let memory = Memory::open(None);
        let model = Scripted::new(false, vec![
            calls(&[("open_url", json!({"url": "youtube.com"}))]),
            calls(&[("media_control", json!({"action": "play"})), ("done", json!({}))]),
        ]);
        let mut host = Fake::default();
        Agent::new(&mut host, &memory, &model, &model).run("go to youtube and play something calm for me please", &explicit());
        assert_eq!(host.did.len(), 2);
        assert!(host.did[1].starts_with("media_control"));
        assert_eq!(model.seen.borrow().len(), 2);
    }

    #[test]
    fn a_browser_named_is_used_for_pages() {
        let memory = Memory::open(None);
        memory.remember("browser", "Open links in Edge");
        let model = Scripted::new(false, vec![calls(&[("open_url", json!({"url": "github.com/x/y/pulls"})), ("done", json!({}))])]);
        let mut host = Fake::default();
        Agent::new(&mut host, &memory, &model, &model).run("show me the pull requests on my repo", &explicit());
        assert!(host.did[0].ends_with("in Edge"), "{:?}", host.did);
    }

    #[test]
    fn a_guess_that_only_answers_is_typed() {
        let memory = Memory::open(None);
        let model = Scripted::new(false, vec![calls(&[("reply", json!({"text": "Sure!"}))])]);
        let mut host = Fake::default();
        let context = Context { explicit: false, ..explicit() };
        Agent::new(&mut host, &memory, &model, &model).run("please send the report by friday", &context);
        assert_eq!(host.typed, vec!["please send the report by friday"]);
        assert!(host.answers.is_empty());
    }

    #[test]
    fn a_failing_cloud_model_hands_over_to_the_local_one() {
        let memory = Memory::open(None);
        let cloud = Scripted::new(false, vec![Err(AiError::Http { provider: "Anthropic", code: 401, detail: "bad key".into() })]);
        let local = Scripted::new(true, vec![calls(&[("reply", json!({"text": "It's 4 pm."}))])]);
        let mut host = Fake::default();
        Agent::new(&mut host, &memory, &cloud, &local).run("what time is it in tokyo", &explicit());
        assert_eq!(host.answers, vec!["It's 4 pm."]);
        assert_eq!(local.seen.borrow().len(), 1);
        crate::ai::set_last_error(None);
    }

    #[test]
    fn close_matches_go_back_to_the_model() {
        let memory = Memory::open(None);
        let model = Scripted::new(false, vec![
            calls(&[("open_file", json!({"query": "lease"})), ("done", json!({}))]),
            calls(&[("open_file", json!({"query": "C:\\Docs\\Lease 2025.pdf"}))]),
        ]);
        let mut host = Fake { files: vec![hit("C:\\Docs\\Lease 2024.pdf", 1.0), hit("C:\\Docs\\Lease 2025.pdf", 0.9)], ..Fake::default() };
        Agent::new(&mut host, &memory, &model, &model).run("open my lease for this year", &explicit());
        // The first done was turned back (nothing had opened); the path picked then opened.
        let seen = model.seen.borrow();
        assert!(matches!(seen[1].last(), Some(Turn::ToolResult { content, .. }) if content.starts_with("Not done")));
        assert_eq!(host.opened, vec!["C:\\Docs\\Lease 2025.pdf"]);
    }

    #[test]
    fn a_clear_match_opens_and_is_remembered() {
        let memory = Memory::open(None);
        let model = Scripted::new(false, vec![calls(&[("open_file", json!({"query": "pan card"}))]), calls(&[("done", json!({}))])]);
        let mut host = Fake { files: vec![hit("C:\\Docs\\PanCard.pdf", 2.0), hit("C:\\Docs\\Other.pdf", 0.5)], ..Fake::default() };
        Agent::new(&mut host, &memory, &model, &model).run("open my pan card", &explicit());
        assert_eq!(host.opened, vec!["C:\\Docs\\PanCard.pdf"]);
        assert_eq!(memory.recent_files(), vec!["C:\\Docs\\PanCard.pdf"]);
    }

    #[test]
    fn selection_edits_replace_or_show() {
        let memory = Memory::open(None);
        let model = Scripted::new(false, vec![Ok(Reply { text: "Bonjour".into(), calls: vec![] })]);
        let mut host = Fake { editable: true, ..Fake::default() };
        let context = Context { selection: Some("Hello".into()), editable: true, ..explicit() };
        Agent::new(&mut host, &memory, &model, &model).run("translate this to French", &context);
        assert_eq!(host.typed, vec!["Bonjour"]);

        let model = Scripted::new(false, vec![Ok(Reply { text: "A greeting.".into(), calls: vec![] })]);
        let mut host = Fake::default();
        Agent::new(&mut host, &memory, &model, &model).run("explain this", &context);
        assert_eq!(host.answers, vec!["A greeting."]);
    }

    #[test]
    fn going_round_in_circles_stops() {
        let memory = Memory::open(None);
        let same = || calls(&[("press_keys", json!({"keys": "ctrl+l"}))]);
        let model = Scripted::new(false, vec![same(), same(), same(), calls(&[("reply", json!({"text": "I couldn't get there."}))])]);
        let mut host = Fake::default();
        Agent::new(&mut host, &memory, &model, &model).run("press ctrl l in the browser over and over", &explicit());
        assert_eq!(host.did.len(), 3);
        assert_eq!(host.answers, vec!["I couldn't get there."]);
    }

    #[test]
    fn opening_alone_doesnt_finish_a_two_part_request() {
        let memory = Memory::open(None);
        let model = Scripted::new(false, vec![
            calls(&[("open_app", json!({"name": "Notepad"})), ("done", json!({}))]),
            calls(&[("type_text", json!({"text": "milk, eggs"})), ("done", json!({}))]),
        ]);
        let mut host = Fake::default();
        Agent::new(&mut host, &memory, &model, &model).run("open notepad and then write milk and eggs", &explicit());
        assert_eq!(host.did.len(), 2);
    }

    #[test]
    fn remembering_and_forgetting() {
        let memory = Memory::open(None);
        let model = Scripted::new(false, vec![calls(&[("remember", json!({"subject": "mom", "fact": "Mom is Roma"})),
                                                      ("reply", json!({"text": "Got it."}))])]);
        let mut host = Fake::default();
        Agent::new(&mut host, &memory, &model, &model).run("remember that mom is Roma", &explicit());
        assert_eq!(memory.facts()[0].text, "Mom is Roma");
        let mut host = Fake { confirms: true, ..Fake::default() };
        Agent::new(&mut host, &memory, &model, &model).run("clear your memory", &explicit());
        assert!(memory.facts().is_empty());
    }

    #[test]
    fn file_helpers() {
        assert!(names_a_file("C:\\Users\\me\\Aadhar.pdf"));
        assert!(names_a_file("Aadhar.pdf"));
        assert!(!names_a_file("Aadhaar card"));
        let recent = vec!["C:\\Docs\\PanCard.pdf".to_string()];
        assert_eq!(earlier_file("PanCard.pdf", &recent).as_deref(), Some("C:\\Docs\\PanCard.pdf"));
        assert!(points_back("open my pan card", "C:\\Docs\\PanCard.pdf"));
        assert!(points_back("open it again", "C:\\Docs\\PanCard.pdf"));
        assert!(!points_back("open the pdf", "C:\\Docs\\PanCard.pdf"));
        assert_eq!(file_words("mujhe PDF kholkar do"), "pdf");
        assert_eq!(search_words("my resume"), "resume cv");
        assert!(has_more_than_one_step("open notepad and write a list"));
        assert!(!has_more_than_one_step("open notepad"));
    }
}
