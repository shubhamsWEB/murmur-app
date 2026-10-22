//! Commands & AI on Windows, as the Mac app's AgentKit: one key both types and gives commands. What you said is
//! decided to be a command or dictation (intent.rs); a command is carried out (agent.rs, with Windows' tools in
//! actions.rs); dictation can be tidied by the model first (ai/cleanup.rs). The model is the one chosen in Settings →
//! Commands & AI: Ollama on this PC, or Claude or OpenAI with your key.
//!
//! Still to come on Windows: reading the screen and clicking, browser automation, and sending messages; the model is
//! told so and says it when asked.

pub mod actions;
pub mod agent;
pub mod answer;
pub mod intent;
pub mod memory;
pub mod places;
pub mod quick;
pub mod tools;
pub mod wake;

use crate::ai::{self, cleanup, Call, Turn};
use crate::dictation::cursor::Spot;
use agent::{FileHit, Outcome};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::AppHandle;

/// What's chosen in Settings → Commands & AI.
#[derive(Clone, Debug, Default)]
pub struct Choices {
    pub ai: ai::Config,
    /// AI clean-up of dictation (off by default, as on the Mac), and the style for each kind of app.
    pub cleanup: bool,
    pub styles: BTreeMap<String, String>,
    /// Commands told apart from dictation without Shift (on by default).
    pub detect: bool,
}

/// What a command needs from the rest of Murmur.
pub struct Hooks {
    /// The best files for a description (the search service).
    pub find: Box<dyn Fn(&str) -> Vec<FileHit> + Send + Sync>,
    /// Murmur's window, searching for this.
    pub search: Box<dyn Fn(&str) + Send + Sync>,
    /// Settings → Commands & AI.
    pub settings: Box<dyn Fn() + Send + Sync>,
}

pub struct Assistant {
    app: AppHandle,
    pub memory: memory::Memory,
    choices: Mutex<Choices>,
    hooks: Hooks,
    /// One command at a time.
    running: Mutex<()>,
    /// When the local model was last woken (it unloads after a while idle, and loading it takes seconds).
    warmed: Mutex<Option<Instant>>,
    /// Said once per launch: the cloud key was rejected.
    warned_about_key: Mutex<bool>,
}

/// The search service's answer as files: one per path, the strong matches (or the first few).
pub fn hits(answer: &Value) -> Vec<FileHit> {
    let strong = answer["strong"].as_u64().unwrap_or(0) as usize;
    let all = answer["hits"].as_array().cloned().unwrap_or_default();
    let take = if strong > 0 { strong } else { 5 };
    let mut out: Vec<FileHit> = Vec::new();
    for hit in all.iter().take(take.max(1)) {
        let Some(path) = hit["path"].as_str() else { continue };
        if out.iter().any(|h| h.path == path) {
            continue;
        }
        out.push(FileHit {
            path: path.to_string(),
            kind: hit["kind"].as_str().unwrap_or("file").to_string(),
            modified: hit["modified"].as_f64().unwrap_or(0.0),
            score: hit["score"].as_f64().unwrap_or(0.0),
            excerpt: hit["excerpt"].as_str().map(String::from),
        });
    }
    out.truncate(8);
    out
}

impl Assistant {
    pub fn new(app: &AppHandle, memory_file: Option<PathBuf>, choices: Choices, hooks: Hooks) -> Assistant {
        answer::make(app);
        #[cfg(windows)]
        actions::warm();
        let assistant = Assistant {
            app: app.clone(),
            memory: memory::Memory::open(memory_file),
            choices: Mutex::new(choices),
            hooks,
            running: Mutex::new(()),
            warmed: Mutex::new(None),
            warned_about_key: Mutex::new(false),
        };
        assistant.warm_up();
        assistant
    }

    pub fn choices(&self) -> Choices {
        self.choices.lock().unwrap().clone()
    }

    pub fn set_choices(&self, choices: Choices) {
        *self.choices.lock().unwrap() = choices;
        *self.warmed.lock().unwrap() = None;
        self.warm_up();
    }

    pub fn router(&self) -> ai::Router {
        ai::current(&self.choices().ai)
    }

    /// The style for a kind of app: the one chosen, else its default.
    pub fn style(&self, category: cleanup::Category) -> cleanup::Style {
        self.choices().styles.get(category.name()).and_then(|name| cleanup::Style::from_name(name))
            .filter(|style| category.styles().contains(style))
            .unwrap_or_else(|| category.default_style())
    }

    /// Wakes the local model ahead of use (it unloads after a while idle): at most every five minutes, when it's the
    /// one that will answer and clean-up or commands may need it.
    pub fn warm_up(&self) {
        let router = self.router();
        let ai::Router::Ollama { model } = router else { return };
        let mut warmed = self.warmed.lock().unwrap();
        if warmed.is_some_and(|at| at.elapsed() < Duration::from_secs(300)) {
            return;
        }
        *warmed = Some(Instant::now());
        drop(warmed);
        if !ai::ollama_installed() {
            return;
        }
        std::thread::spawn(move || ai::blocking(ai::ollama_warm_up(&model)));
    }

    // MARK: Dictation, tidied

    /// AI clean-up of what was heard. None (typed as heard) when it's off, too short to bother, slow (over four
    /// seconds), failed, or the reply is anything but a tidied version of it.
    pub fn clean_up(&self, text: &str, program: Option<&str>, title: Option<&str>, log: &dyn Fn(&str)) -> Option<String> {
        let choices = self.choices();
        if !choices.cleanup || !cleanup::worth_cleaning(text) {
            return None;
        }
        let category = cleanup::category(program, title);
        let style = self.style(category);
        let router = self.router();
        let what = format!("{}, {}, {}", router.name(), category.name(), style.name());
        crate::dictation::pill_show(&self.app, "working", "Tidying up");
        let started = Instant::now();
        let reply = ai::blocking(router.chat(&cleanup::system(style, category), &[Turn::User(cleanup::user(text))], &[],
                                             Duration::from_secs(4)));
        let took = started.elapsed().as_secs_f64();
        match reply {
            Err(error) => {
                log(&format!("AI clean-up ({what}) gave nothing in {took:.1} s ({error}): typed as heard"));
                None
            }
            Ok(reply) => match cleanup::accept(text, &reply.text) {
                None => {
                    log(&format!("AI clean-up ({what}) changed more than tidying in {took:.1} s: typed as heard"));
                    None
                }
                Some(cleaned) => {
                    log(&format!("AI clean-up ({what}) in {took:.1} s{}", if cleaned == text { ", nothing to change" } else { "" }));
                    Some(cleaned)
                }
            },
        }
    }

    // MARK: Command or dictation

    pub fn decide(&self, text: &str, spot: &Spot, front_app: Option<&str>, forced: bool) -> intent::Decision {
        let choices = self.choices();
        if !choices.detect {
            return if forced {
                intent::Decision { intent: intent::Intent::Command, reason: "Shift held".into(), explicit: true }
            } else {
                intent::Decision { intent: intent::Intent::Dictation, reason: "detection off".into(), explicit: true }
            };
        }
        let focus = match spot.text_field {
            Some(true) => intent::Focus::TextField,
            Some(false) => intent::Focus::NotText,
            None => intent::Focus::Unknown,
        };
        let situation = intent::Situation {
            forced_command: forced,
            focus,
            front_app,
            has_selection: spot.selection.is_some(),
            since_last: self.memory.since_last(),
        };
        let router = self.router();
        // The model is asked only when it can answer: Ollama there, or a cloud key.
        let usable = !router.is_local() || ai::ollama_installed();
        let decision = ai::blocking(intent::decide(text, &situation, &PcApps, usable.then_some(&router)));
        if ai::is_key_problem(ai::last_error().as_deref()) {
            let mut warned = self.warned_about_key.lock().unwrap();
            if !*warned {
                *warned = true;
                let provider = self.choices().ai.provider.company();
                crate::dictation::pill_flash(&self.app, &format!("{provider} rejected the API key · change it in Settings → Commands & AI"), "problem", 4.0);
                std::thread::sleep(Duration::from_millis(1200));
            }
        }
        decision
    }

    // MARK: A command

    /// Carries out a command (on dictation's thread; one at a time). `target`: the window you were in when you spoke,
    /// for typing back into it.
    pub fn run(&self, text: &str, spot: &Spot, front: Option<(isize, String, String)>, explicit: bool, log: &(dyn Fn(&str) + Sync)) {
        let _one = self.running.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let (target, program, title) = match &front {
            Some((hwnd, program, title)) => (Some(*hwnd), Some(program.clone()), Some(title.clone())),
            None => (None, None, None),
        };
        let front_app = program.as_deref().map(|p| p.trim_end_matches(".exe").trim_end_matches(".EXE").to_string());
        let context = agent::Context {
            now: now_text(),
            front_app: front_app.clone(),
            window_title: title,
            selection: spot.selection.clone(),
            editable: spot.text_field == Some(true),
            explicit,
        };
        crate::dictation::pill_show(&self.app, "working", &format!("“{}”", ai::cut(text, 60)));
        let choices = self.choices();
        let model = ai::current(&choices.ai);
        let local = ai::local(&choices.ai);
        let mut host = Pc { app: &self.app, hooks: &self.hooks, log, target, editable: context.editable, answered: false };
        agent::Agent::new(&mut host, &self.memory, &model, &local).run(text, &context);
        if !host.answered {
            // The pill's last word (what was done) for a moment, then it closes.
            std::thread::sleep(Duration::from_millis(1200));
            crate::dictation::pill_hide(&self.app);
        }
    }

    // MARK: Settings → Commands & AI

    /// What the page shows.
    pub fn info(&self) -> Value {
        let choices = self.choices();
        let key = |provider: ai::Provider| provider.key_account().and_then(ai::keys::get).map(|k| ai::keys::masked(&k));
        let categories: Vec<Value> = cleanup::Category::ALL.iter().map(|category| json!({
            "id": category.name(), "title": category.display(), "examples": category.examples(),
            "style": self.style(*category).name(),
            "styles": category.styles().iter().map(|s| json!({"id": s.name(), "title": s.display()})).collect::<Vec<_>>(),
        })).collect();
        let facts: Vec<Value> = self.memory.facts().iter().enumerate()
            .map(|(i, f)| json!({"id": format!("fact:{i}"), "text": f.text})).collect();
        json!({
            "provider": choices.ai.provider.name(),
            "localModel": choices.ai.local_model,
            "anthropicModel": choices.ai.anthropic_model,
            "openaiModel": choices.ai.openai_model,
            "workspace": choices.ai.anthropic_workspace,
            "defaults": {"local": ai::DEFAULT_LOCAL_MODEL, "anthropic": ai::DEFAULT_ANTHROPIC_MODEL, "openai": ai::DEFAULT_OPENAI_MODEL},
            "keys": {"anthropic": key(ai::Provider::Anthropic), "openai": key(ai::Provider::OpenAI)},
            "cleanup": choices.cleanup,
            "categories": categories,
            "detect": choices.detect,
            "ollamaInstalled": ai::ollama_installed(),
            "using": self.router().name(),
            "lastError": ai::last_error(),
            "facts": facts,
            "commands": self.memory.recent(400).len(),
        })
    }

    /// The models Ollama has (None: it isn't running).
    pub fn ollama_models(&self) -> Option<Vec<String>> {
        ai::blocking(ai::ollama_models())
    }

    /// Checks a provider's saved key (or that Ollama answers): None when it works, else what's wrong.
    pub fn check(&self, provider: ai::Provider) -> Option<String> {
        let config = self.choices().ai;
        if provider == ai::Provider::Local {
            let router = ai::local(&config);
            return match ai::blocking(router.chat("Reply with OK.", &[Turn::User("OK?".into())], &[], Duration::from_secs(60))) {
                Ok(_) => None,
                Err(error) => Some(error.to_string()),
            };
        }
        ai::blocking(ai::verify(provider, &config))
    }
}

/// The window in front: its handle, its program's file name and its title.
pub fn front_window() -> Option<(isize, String, String)> {
    #[cfg(windows)]
    return actions::front().map(|w| (w.hwnd, w.program, w.title));
    #[cfg(not(windows))]
    None
}

/// "Thursday, 22 October 2026, 14:05", in the PC's time.
fn now_text() -> String {
    #[cfg(windows)]
    {
        let time = unsafe {
            let mut time = std::mem::zeroed::<windows_sys::Win32::Foundation::SYSTEMTIME>();
            windows_sys::Win32::System::SystemInformation::GetLocalTime(&mut time);
            time
        };
        const DAYS: [&str; 7] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
        const MONTHS: [&str; 12] = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                    "October", "November", "December"];
        return format!("{}, {} {} {}, {:02}:{:02}", DAYS[time.wDayOfWeek as usize % 7], time.wDay,
                       MONTHS[(time.wMonth as usize).saturating_sub(1) % 12], time.wYear, time.wHour, time.wMinute);
    }
    #[cfg(not(windows))]
    format!("{} seconds since 1970 (UTC)", memory::now() as u64)
}

/// Installed apps, for the quick path.
struct PcApps;

impl quick::Apps for PcApps {
    fn resolves(&self, name: &str) -> bool {
        #[cfg(windows)]
        return actions::resolves(name);
        #[cfg(not(windows))]
        {
            let _ = name;
            false
        }
    }
}

/// A command's host on this PC.
struct Pc<'a> {
    app: &'a AppHandle,
    hooks: &'a Hooks,
    log: &'a (dyn Fn(&str) + Sync),
    /// The window you were in when you spoke.
    #[cfg_attr(not(windows), allow(dead_code))]
    target: Option<isize>,
    editable: bool,
    answered: bool,
}

impl Pc<'_> {
    /// Back to the window you were typing in, if a command went elsewhere.
    fn back_to_target(&self) {
        #[cfg(windows)]
        if let Some(hwnd) = self.target {
            if actions::front().map(|w| w.hwnd) != Some(hwnd) {
                actions::bring_to_front(hwnd);
                std::thread::sleep(Duration::from_millis(250));
            }
        }
    }
}

impl agent::Host for Pc<'_> {
    fn log(&mut self, line: &str) {
        (self.log)(line);
    }

    fn progress(&mut self, text: &str) {
        if !text.trim().is_empty() {
            crate::dictation::pill_show(self.app, "working", &ai::cut(text.trim(), 90));
        }
    }

    fn show_answer(&mut self, text: &str) {
        self.answered = true;
        crate::dictation::pill_hide(self.app);
        answer::show(self.app, text);
    }

    fn insert(&mut self, text: &str) -> bool {
        self.back_to_target();
        crate::dictation::pill_hide(self.app);
        match crate::dictation::paste::insert(text) {
            Ok(()) => {
                self.answered = true;
                true
            }
            Err(error) => {
                (self.log)(&format!("command: couldn't type it: {error}"));
                false
            }
        }
    }

    fn replace_selection(&mut self, text: &str) -> bool {
        // Pasting over a selection replaces it, where the selection is in something you can type in.
        self.editable && self.insert(text)
    }

    fn find_files(&mut self, query: &str) -> Vec<FileHit> {
        (self.hooks.find)(query)
    }

    fn open_path(&mut self, path: &str) -> Result<(), String> {
        #[cfg(windows)]
        return actions::open_path(path);
        #[cfg(not(windows))]
        {
            let _ = path;
            Err("opening files from a command works on Windows for now".into())
        }
    }

    fn show_search(&mut self, query: &str) {
        crate::dictation::pill_hide(self.app);
        self.answered = true;
        (self.hooks.search)(query);
    }

    fn confirm(&mut self, title: &str, detail: &str) -> bool {
        use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
        self.app.dialog().message(detail).title(title).kind(MessageDialogKind::Warning)
            .buttons(MessageDialogButtons::OkCancelCustom("Yes".into(), "Cancel".into()))
            .blocking_show()
    }

    fn open_model_settings(&mut self) {
        (self.hooks.settings)();
    }

    fn resolves_app(&self, name: &str) -> bool {
        quick::Apps::resolves(&PcApps, name)
    }

    fn is_browser(&self, app: &str) -> bool {
        places::browser_program(app).is_some()
    }

    fn act(&mut self, tool: &str, call: &Call, browser: Option<&str>) -> Outcome {
        #[cfg(windows)]
        return act(self, tool, call, browser);
        #[cfg(not(windows))]
        {
            let _ = (tool, call, browser);
            Outcome::said("That works on Windows for now.")
        }
    }
}

/// The PC's own tools.
#[cfg(windows)]
fn act(pc: &mut Pc, tool: &str, call: &Call, browser: Option<&str>) -> Outcome {
    let text = |key: &str| call.text(key);
    let said = |result: String| Outcome::said(result);
    match tool {
        "open_app" => said(actions::open_app(&text("name"))),
        "quit_app" => said(actions::quit_app(&text("name"))),
        "hide_app" => said(actions::hide_app(&text("name"))),
        "find_apps" => said(actions::find_apps(&text("query"))),
        "list_running_apps" => said(actions::running_apps()),
        "open_folder" => said(actions::open_folder(&text("name"))),
        "open_settings" => said(actions::open_settings(&text("page"))),
        "open_url" => said(actions::open_url(&text("url"), browser)),
        "web_search" => said(actions::web_search(&text("query"), browser)),
        "site_search" => said(actions::site_search(&text("site"), &text("query"), browser)),
        "set_volume" => said(actions::set_volume(call.number("percent").unwrap_or(50.0))),
        "change_volume" => said(actions::change_volume(text("direction") != "down")),
        "mute" => said(actions::mute(call.flag("on") != Some(false))),
        "media_control" => said(actions::media(&text("action"))),
        "set_brightness" => said(actions::set_brightness(Some(call.number("percent").unwrap_or(50.0)), 0)),
        "brightness" => said(actions::set_brightness(None, if text("direction") == "down" { -15 } else { 15 })),
        "lock_screen" => said(actions::lock_screen()),
        "screenshot" => said(actions::screenshot()),
        "write_in_app" => {
            let (result, written) = actions::write_in_app(&text("app"), call.text("text").trim(), call.flag("new_document") != Some(false));
            Outcome { result, finished: written }
        }
        "type_text" => {
            crate::dictation::pill_hide(pc.app);
            said(actions::type_text(&call.text("text"), call.flag("submit") == Some(true)))
        }
        "press_keys" => said(actions::press_keys(&text("keys"))),
        "read_clipboard" => said(match actions::clipboard_text() {
            Some(copied) if !copied.is_empty() => format!("Clipboard ({} characters):\n{}", copied.chars().count(), ai::cut(&copied, 8000)),
            _ => "The clipboard has no text.".into(),
        }),
        "copy_text" => said(if actions::copy_text(&call.text("text")) {
            format!("Copied {} characters to the clipboard.", call.text("text").chars().count())
        } else {
            "Couldn't use the clipboard (another app has it open).".into()
        }),
        "paste_clipboard" => {
            pc.back_to_target();
            crate::dictation::pill_hide(pc.app);
            actions::paste();
            pc.answered = true;
            Outcome::ended("Pasted the clipboard where you were.")
        }
        "wait" => {
            let seconds = call.number("seconds").unwrap_or(1.0).clamp(0.2, 6.0);
            std::thread::sleep(Duration::from_secs_f64(seconds));
            said(format!("Waited {seconds} s."))
        }
        // What the Mac can do and Windows can't yet: said plainly, so the model tells you rather than tries.
        "read_screen" | "click" | "browser_read" | "browser_click" | "browser_type" | "send_message" | "run_command" =>
            said("That isn't available on Windows yet. Reply saying so, and what the user can do instead.".into()),
        other => said(format!("Unknown tool {other}.")),
    }
}
