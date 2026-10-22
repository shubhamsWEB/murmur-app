//! Dictation, as the Mac app has it: hold the dictation key, speak, let go, and the words are typed where you are.
//! Everything happens on this computer: the microphone (audio.rs), the level (level.rs, the Mac's AudioLevel), Parakeet
//! or Whisper through sherpa-onnx (speech.rs), the paste (paste.rs). The key (keys.rs) and the paste work on Windows
//! for now.
//!
//! What's said can also be a command (Alt with the key, or told apart by what it says; Shift with the key types it
//! whatever it says, as ⌃ and ⇧ with Fn on the Mac) or be tidied by the
//! model before it's typed (AI clean-up): both are commands/mod.rs's, with the model chosen in Commands & AI.
//!
//! The speech model (about 650 MB) is downloaded by the helper (`murmur-engine download-speech-model`, checked file by
//! file) the first time dictation is on, then loaded once and kept warm. The pill (pill.rs, ui/pill.html) shows each
//! step, opening out of the Murmur button (logo.rs) when it's on.

pub mod audio;
pub mod cursor;
pub mod fit;
pub mod history;
pub mod keys;
pub mod level;
pub mod logo;
pub mod paste;
mod pill;
pub mod speech;
pub mod worker;

/// The pill, for commands: what they're doing, a word for a moment, or closed.
pub fn pill_show(app: &AppHandle, mode: &str, text: &str) {
    pill::show(app, mode, text);
}

pub fn pill_flash(app: &AppHandle, text: &str, tone: &str, seconds: f64) {
    pill::flash(app, text, tone, seconds);
}

pub fn pill_hide(app: &AppHandle) {
    pill::hide(app);
}

use crate::commands::Assistant;
use crate::helper::{Launch, ModelDownload};
use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

/// What the person chose (Settings → Dictation).
#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub enabled: bool,
    pub key: keys::Combo,
    pub model: speech::Model,
    /// The microphone's name; empty: the system's default.
    pub microphone: String,
    /// A stronger boost for soft speech and whispers (on by default, as on the Mac).
    pub quiet_voice: bool,
    /// The Murmur button on screen (on by default, as on the Mac).
    pub floating_button: bool,
    /// A history of dictations on this PC, for Home's "This week" (on by default, as on the Mac).
    pub keep_history: bool,
    /// Every recording and what was heard, saved to Documents\Murmur Recordings (off by default).
    pub keep_recordings: bool,
}

/// Hold the key to talk; a press shorter than this is a tap, not a dictation (as on the Mac).
const TAP: Duration = Duration::from_millis(300);
/// Two taps this close together start hands-free dictation; the next tap finishes it, Esc cancels it.
const DOUBLE_TAP: Duration = Duration::from_millis(400);
/// Recordings shorter than this are dropped as accidental.
const SHORTEST: Duration = Duration::from_millis(250);

pub struct Dictation {
    inner: Arc<Inner>,
}

struct Inner {
    app: AppHandle,
    config: Mutex<Config>,
    combo: Arc<Mutex<keys::Combo>>,
    recognizer: Mutex<Option<Arc<worker::Engine>>>,
    /// The log folder (the speech worker's output goes there).
    logs: PathBuf,
    loading: AtomicBool,
    /// The speech model: {"state": "missing|downloading|checking|waiting|loading|ready|failed", …}.
    model: Mutex<Value>,
    download: ModelDownload,
    rerun: AtomicBool,
    /// A helper launch for these arguments (the shell's: its program, environment and log folder).
    launch: Box<dyn Fn(Vec<String>, &str) -> Launch + Send + Sync>,
    recording: Mutex<Option<audio::Recording>>,
    /// Hands-free: started by a double tap, finished by the next tap.
    hands_free: AtomicBool,
    /// When the key last went down, and when a tap last ended (for the double tap): the key watcher's times, not
    /// when this thread got to them (opening the microphone takes it a moment).
    pressed_at: Mutex<Option<Instant>>,
    last_tap: Mutex<Option<Instant>>,
    /// Why the key can't be watched, if it can't.
    key_problem: Mutex<Option<String>>,
    /// What a dictation is doing: "idle", "listening" or "working" (Home's key lights up while you talk).
    phase: Mutex<&'static str>,
    log: Mutex<Option<std::fs::File>>,
    history: history::History,
    /// The last dictation, as typed (the tray's Paste Last Dictation). Kept in memory only.
    last: Mutex<Option<String>>,
    /// What the dictation thread is doing and since when (for the watchdog).
    busy: Mutex<Option<(Instant, keys::Press)>>,
    /// Alt was held with the key during this dictation: what's said is a command. Shift: it's typed, whatever it says.
    command: AtomicBool,
    typing: AtomicBool,
    /// Where the words would go, looked at as the key went down (a moment's work, on a thread of its own): the focus
    /// and selection, and the window in front (its handle, program and title). Taken when the words are in.
    spot: Arc<Mutex<Option<Place>>>,
    /// The last dictation as heard, before AI clean-up (the tray's Paste Exactly What I Said).
    heard: Mutex<Option<String>>,
}

/// Where the words would go.
#[derive(Clone, Debug, Default)]
struct Place {
    spot: cursor::Spot,
    front: Option<(isize, String, String)>,
}

enum Work {
    Key(keys::Press, Instant),
}

impl Dictation {
    /// Starts dictation: the pill's window, the key watcher, and the model (downloaded if it's missing and dictation
    /// is on, else loaded). `launch` makes a helper launch for some arguments and a log file's name.
    /// `data`: the folder the history is kept in (the settings').
    pub fn start(app: &AppHandle, config: Config, logs: PathBuf, data: &std::path::Path,
                 launch: impl Fn(Vec<String>, &str) -> Launch + Send + Sync + 'static) -> Dictation {
        let events = app.clone();
        let download = ModelDownload::new(move |event| {
            if let Some(dictation) = events.try_state::<Dictation>() {
                dictation.inner.model_event(event);
            }
        });
        let log = std::fs::OpenOptions::new().create(true).append(true).open(logs.join("dictation.log")).ok();
        let inner = Arc::new(Inner {
            app: app.clone(),
            combo: Arc::new(Mutex::new(config.key)),
            config: Mutex::new(config),
            recognizer: Mutex::new(None),
            logs: logs.clone(),
            loading: AtomicBool::new(false),
            model: Mutex::new(json!({"state": "missing"})),
            download,
            rerun: AtomicBool::new(false),
            launch: Box::new(launch),
            recording: Mutex::new(None),
            hands_free: AtomicBool::new(false),
            pressed_at: Mutex::new(None),
            last_tap: Mutex::new(None),
            key_problem: Mutex::new(None),
            phase: Mutex::new("idle"),
            log: Mutex::new(log),
            history: history::History::open(data),
            last: Mutex::new(None),
            busy: Mutex::new(None),
            command: AtomicBool::new(false),
            typing: AtomicBool::new(false),
            spot: Arc::new(Mutex::new(None)),
            heard: Mutex::new(None),
        });
        if let Err(error) = pill::make(app) {
            inner.note(&format!("no pill: {error}"));
        }
        logo::set_enabled(app, inner.config().floating_button);
        // Key presses arrive on the hook's thread, which must answer Windows at once: the work happens here.
        let (work, jobs) = mpsc::channel::<Work>();
        let worker = inner.clone();
        std::thread::Builder::new()
            .name("murmur-dictation".into())
            .spawn(move || {
                for job in jobs {
                    let Work::Key(press, at) = job;
                    *worker.busy.lock().unwrap() = Some((Instant::now(), press));
                    match press {
                        keys::Press::Down => worker.key_down(at),
                        keys::Press::Up => worker.key_up(at),
                        keys::Press::Cancel => worker.shortcut(),
                        keys::Press::Escape => worker.escape(),
                        keys::Press::Revived => worker.note("key watcher: Windows had dropped it, so it was put back (this press still counts)"),
                        keys::Press::Command => worker.mode_key(true),
                        keys::Press::Typing => worker.mode_key(false),
                    }
                    *worker.busy.lock().unwrap() = None;
                }
            })
            .expect("the dictation thread");
        // Says in the log when the dictation thread is stuck (a microphone that won't open or close, say): every key
        // press waits behind it, so it would look as if the key had stopped working.
        let watched = inner.clone();
        std::thread::Builder::new()
            .name("murmur-dictation-watchdog".into())
            .spawn(move || {
                let mut said: Option<Instant> = None;
                loop {
                    std::thread::sleep(Duration::from_secs(2));
                    let busy = *watched.busy.lock().unwrap();
                    match busy {
                        Some((since, press)) if since.elapsed() > Duration::from_secs(8) && said != Some(since) => {
                            watched.note(&format!("the dictation thread has been busy for {:.0} s with {press:?}: key presses wait behind it",
                                                  since.elapsed().as_secs_f64()));
                            said = Some(since);
                        }
                        None if said.is_some() => {
                            watched.note("the dictation thread is free again");
                            said = None;
                        }
                        _ => {}
                    }
                }
            })
            .expect("the dictation watchdog");
        if let Err(problem) = keys::listen(inner.combo.clone(), move |press| {
            let _ = work.send(Work::Key(press, Instant::now()));
        }) {
            inner.note(&format!("key: {problem}"));
            *inner.key_problem.lock().unwrap() = Some(problem);
        }
        inner.prepare();
        Dictation { inner }
    }

    pub fn config(&self) -> Config {
        self.inner.config.lock().unwrap().clone()
    }

    /// A new choice from Settings: the key changes at once; another model is loaded (or downloaded).
    pub fn configure(&self, config: Config) {
        let before = self.config();
        if before.keep_history && !config.keep_history {
            self.inner.history.clear();
        }
        logo::set_enabled(&self.inner.app, config.floating_button);
        *self.inner.combo.lock().unwrap() = config.key;
        *self.inner.config.lock().unwrap() = config.clone();
        if config.model != before.model {
            *self.inner.recognizer.lock().unwrap() = None;
            self.inner.download.stop();
        }
        if config.model != before.model || (config.enabled && !before.enabled) {
            self.inner.prepare();
        }
        self.inner.changed();
    }

    /// Settings' Download (or Try Again). After a model that was there didn't load, its files are fetched afresh.
    pub fn download(&self) {
        let failed = self.inner.model.lock().unwrap()["state"] == "failed";
        if let (true, Some(folder)) = (failed, self.inner.folder()) {
            let model = self.inner.config().model;
            if speech::installed(model, &folder) {
                self.inner.note("Try Again: the model's files are downloaded afresh");
                speech::remove(model, &folder);
            }
        }
        self.inner.start_download();
    }

    /// The tray's Paste Last Dictation: types the last dictation again where the cursor is now, once the menu has
    /// closed and the focus is back in that app.
    pub fn paste_last(&self) {
        let inner = self.inner.clone();
        std::thread::spawn(move || {
            let Some(text) = inner.last.lock().unwrap().clone() else {
                pill::flash(&inner.app, "Nothing dictated yet", "info", 2.0);
                return;
            };
            std::thread::sleep(Duration::from_millis(250));
            if let Err(error) = paste::insert(&text) {
                inner.note(&format!("paste last: {error}"));
                pill::flash(&inner.app, &format!("Couldn't type it: {error}"), "problem", 4.0);
            }
        });
    }

    /// The tray's Paste Exactly What I Said: the last dictation as the speech model heard it, before AI clean-up.
    pub fn paste_heard(&self) {
        let inner = self.inner.clone();
        std::thread::spawn(move || {
            let Some(text) = inner.heard.lock().unwrap().clone() else {
                pill::flash(&inner.app, "Nothing dictated yet", "info", 2.0);
                return;
            };
            std::thread::sleep(Duration::from_millis(250));
            if let Err(error) = paste::insert(&text) {
                inner.note(&format!("paste heard: {error}"));
                pill::flash(&inner.app, &format!("Couldn't type it: {error}"), "problem", 4.0);
            }
        });
    }

    /// Settings' Clear History.
    pub fn clear_history(&self) {
        self.inner.history.clear();
        self.inner.changed();
    }

    /// What Settings shows.
    pub fn snapshot(&self) -> Value {
        self.inner.state(true)
    }
}

impl Inner {
    fn config(&self) -> Config {
        self.config.lock().unwrap().clone()
    }

    fn folder(&self) -> Option<PathBuf> {
        speech::default_folder(self.config().model)
    }

    /// The model there and loaded, or on its way: loaded when it's there, downloaded (dictation on) when it isn't.
    fn prepare(self: &Arc<Self>) {
        let Some(folder) = self.folder() else { return };
        if speech::installed(self.config().model, &folder) {
            self.load();
        } else {
            self.set_model(json!({"state": "missing"}));
            if self.config().enabled {
                self.start_download();
            }
        }
    }

    fn start_download(&self) {
        let config = self.config();
        let Some(folder) = self.folder() else { return };
        let args = vec![
            "download-speech-model".to_string(),
            "--model".into(),
            config.model.name().into(),
            "--to".into(),
            folder.display().to_string(),
        ];
        let launch = (self.launch)(args, "speech-model.log");
        match self.download.run(&launch) {
            Ok(()) => self.set_model(json!({"state": "checking"})),
            Err(error) => self.set_model(json!({"state": "failed", "message": error})),
        }
    }

    /// The helper's download events (`murmur-engine download-speech-model`), as the search model's are handled.
    fn model_event(self: &Arc<Self>, event: Value) {
        let before = self.model.lock().unwrap().clone();
        let state = match event["event"].as_str().unwrap_or_default() {
            "progress" => json!({"state": "downloading", "bytes": event["all_bytes"], "total": event["all_total"]}),
            "file" => json!({"state": "downloading", "bytes": before["bytes"], "total": before["total"]}),
            "verifying" => json!({"state": "checking"}),
            "waiting" => json!({"state": "waiting"}),
            "retry" => json!({"state": "downloading", "bytes": before["bytes"], "total": before["total"],
                              "problem": event["message"]}),
            "done" => {
                self.rerun.store(false, Ordering::SeqCst);
                self.note("speech model downloaded");
                self.load();
                return;
            }
            "error" => json!({"state": "failed", "message": event["message"]}),
            // Ended without a word: once more, which checks what's there and finishes or goes on.
            "stopped" if !self.rerun.swap(true, Ordering::SeqCst) => {
                self.start_download();
                return;
            }
            "stopped" => json!({"state": "failed", "message": "the download stopped"}),
            _ => return,
        };
        self.set_model(state);
    }

    /// Loads the model on a thread of its own (a few seconds), then runs it once on silence so the first dictation is
    /// quick.
    fn load(self: &Arc<Self>) {
        if self.loading.swap(true, Ordering::SeqCst) {
            return;
        }
        self.set_model(json!({"state": "loading"}));
        let inner = self.clone();
        std::thread::spawn(move || {
            let model = inner.config().model;
            let result = inner.folder().ok_or("no folder for the speech model".to_string())
                .and_then(|folder| {
                    let started = Instant::now();
                    let recognizer = worker::Engine::load(model, &folder, &inner.logs.join("speech-worker.log"))?;
                    let warm = recognizer.warm_up();
                    inner.note(&format!("{} model loaded in {:.1} s (warm-up {:.2} s)", model.name(),
                                        started.elapsed().as_secs_f64(), warm));
                    Ok(recognizer)
                });
            inner.loading.store(false, Ordering::SeqCst);
            match result {
                // Still the model chosen (Settings may have changed it meanwhile).
                Ok(recognizer) if inner.config().model == model => {
                    *inner.recognizer.lock().unwrap() = Some(Arc::new(recognizer));
                    inner.set_model(json!({"state": "ready"}));
                }
                Ok(_) => inner.prepare(),
                Err(error) => {
                    inner.note(&format!("can't load the speech model: {error}"));
                    inner.set_model(json!({"state": "failed", "message": error}));
                    pill::flash(&inner.app, &format!("Dictation couldn't start: {error}"), "problem", 5.0);
                }
            }
        });
    }

    fn set_model(&self, state: Value) {
        *self.model.lock().unwrap() = state;
        self.changed();
    }

    fn changed(&self) {
        // Without the microphones: this goes out with every step of the model's download.
        let _ = self.app.emit("dictation", self.state(false));
    }

    /// What Settings shows; `microphones`: with the list of them (Windows takes a moment to name them).
    fn state(&self, microphones: bool) -> Value {
        let config = self.config();
        let keys: Vec<Value> = keys::Combo::ALL.iter().map(|combo| json!({"id": combo.name(), "title": combo.title()})).collect();
        let models: Vec<Value> = speech::Model::ALL
            .iter()
            .map(|model| json!({"id": model.name(), "title": model.title()}))
            .collect();
        let key_problem = self.key_problem.lock().unwrap().clone();
        let model_state = self.model.lock().unwrap().clone();
        let mut state = json!({
            "available": cfg!(windows),
            "enabled": config.enabled,
            "key": config.key.name(),
            "keys": keys,
            "keyProblem": key_problem,
            "model": config.model.name(),
            "models": models,
            "modelState": model_state,
            "folder": self.folder().map(|folder| folder.display().to_string()),
            "microphone": config.microphone,
            "quietVoice": config.quiet_voice,
            "floatingButton": config.floating_button,
            "keepHistory": config.keep_history,
            "keepRecordings": config.keep_recordings,
            "history": if config.keep_history { json!(self.history.counts()) } else { json!([]) },
            "recordingsFolder": history::recordings_folder().map(|folder| folder.display().to_string()),
            "phase": *self.phase.lock().unwrap(),
            "handsFree": self.hands_free.load(Ordering::SeqCst),
        });
        if microphones {
            state["microphones"] = json!(audio::microphones());
        }
        state
    }

    // MARK: A dictation

    fn set_phase(&self, phase: &'static str) {
        let mut now = self.phase.lock().unwrap();
        if *now != phase {
            *now = phase;
            drop(now);
            self.changed();
        }
    }

    /// The key went down: a tap during hands-free dictation finishes it; otherwise dictation starts, hands-free when
    /// this follows a tap closely enough.
    fn key_down(self: &Arc<Self>, at: Instant) {
        let recording = self.recording.lock().unwrap().is_some();
        if recording {
            if self.hands_free.load(Ordering::SeqCst) {
                self.end();
            }
            return;
        }
        let double = self.last_tap.lock().unwrap().take().is_some_and(|tap| at.saturating_duration_since(tap) < DOUBLE_TAP);
        *self.pressed_at.lock().unwrap() = Some(at);
        self.begin(double);
    }

    /// The key went up: the end of a held dictation, or a tap (dropped, and remembered for a double tap).
    fn key_up(self: &Arc<Self>, at: Instant) {
        if self.hands_free.load(Ordering::SeqCst) || self.recording.lock().unwrap().is_none() {
            return;
        }
        let pressed = self.pressed_at.lock().unwrap().unwrap_or(at);
        if at.saturating_duration_since(pressed) < TAP {
            self.cancel();
            *self.last_tap.lock().unwrap() = Some(at);
        } else {
            self.end();
        }
    }

    /// Alt (`command`) or Shift with the key, held from the start or added while talking: a command, or typing only.
    fn mode_key(&self, command: bool) {
        if self.recording.lock().unwrap().is_none() {
            return;
        }
        let flag = if command { &self.command } else { &self.typing };
        if !flag.swap(true, Ordering::SeqCst) {
            self.note(if command { "Alt held: a command" } else { "Shift held: typed as said" });
            pill::show(&self.app, "listening", if command { "Listening for a command" } else { "Listening · typing only" });
        }
    }

    /// Another key pressed with the dictation key held: a shortcut, not dictation.
    fn shortcut(&self) {
        if !self.hands_free.load(Ordering::SeqCst) {
            self.cancel();
        }
    }

    fn escape(&self) {
        if self.hands_free.load(Ordering::SeqCst) {
            self.note("hands-free dictation cancelled");
            self.cancel();
        }
    }

    fn begin(self: &Arc<Self>, hands_free: bool) {
        let config = self.config();
        if !config.enabled {
            self.note("key pressed: dictation is off");
            return;
        }
        self.note(if hands_free { "key pressed: hands-free" } else { "key pressed" });
        if self.recognizer.lock().unwrap().is_none() {
            let state = self.model.lock().unwrap().clone();
            let text = match state["state"].as_str().unwrap_or_default() {
                "downloading" => match (state["bytes"].as_f64(), state["total"].as_f64()) {
                    (Some(bytes), Some(total)) if total > 0.0 =>
                        format!("Getting dictation ready · {:.0}%", bytes / total * 100.0),
                    _ => "Getting dictation ready…".to_string(),
                },
                "loading" | "checking" => "Getting dictation ready…".to_string(),
                // Downloaded but it didn't load, or stopped (the Hinglish worker): another try.
                "failed" if self.folder().is_some_and(|folder| speech::installed(self.config().model, &folder)) => {
                    self.load();
                    "Getting dictation ready…".to_string()
                }
                "failed" => "The speech model didn't download · see Murmur's Settings".to_string(),
                _ => {
                    self.start_download();
                    "Downloading the speech model…".to_string()
                }
            };
            pill::flash(&self.app, &text, "info", 3.0);
            return;
        }
        pill::show(&self.app, "starting", "Starting the microphone…");
        self.command.store(false, Ordering::SeqCst);
        self.typing.store(false, Ordering::SeqCst);
        self.look_around();
        let app = self.app.clone();
        let started = Instant::now();
        match audio::Recording::start(&config.microphone, move |level| pill::level(&app, level)) {
            Ok(recording) => {
                self.note(&format!("listening with {} ({} Hz), on in {:.2} s (first sound after {:.2} s)",
                                   recording.device, recording.sample_rate, started.elapsed().as_secs_f64(),
                                   recording.opened_in.as_secs_f64()));
                let words = if hands_free {
                    format!("Listening · tap {} to finish", config.key.title())
                } else {
                    "Listening".to_string()
                };
                pill::show(&self.app, "listening", &words);
                self.hands_free.store(hands_free, Ordering::SeqCst);
                *self.recording.lock().unwrap() = Some(recording);
                self.set_phase("listening");
            }
            Err(error) => {
                self.note(&format!("microphone: {error}"));
                pill::flash(&self.app, &format!("Can't use the microphone: {error}"), "problem", 4.0);
            }
        }
    }

    /// Where the words would go, looked at now (before the pill or anything else changes it), on a thread of its own:
    /// UI Automation can take a moment in a busy app. The local model is woken meanwhile, if it'll be needed.
    fn look_around(&self) {
        *self.spot.lock().unwrap() = None;
        let spot = self.spot.clone();
        std::thread::spawn(move || {
            let front = crate::commands::front_window();
            let place = Place { spot: cursor::spot(), front };
            *spot.lock().unwrap() = Some(place);
        });
        if let Some(assistant) = self.app.try_state::<Arc<Assistant>>() {
            assistant.warm_up();
        }
    }

    /// What `look_around` found (waiting for it a moment, if it isn't in yet).
    fn place(&self) -> Place {
        let started = Instant::now();
        loop {
            if let Some(place) = self.spot.lock().unwrap().clone() {
                return place;
            }
            if started.elapsed() > Duration::from_millis(800) {
                self.note("couldn't tell where the words were going in time");
                return Place::default();
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn cancel(&self) {
        self.hands_free.store(false, Ordering::SeqCst);
        if let Some(recording) = self.recording.lock().unwrap().take() {
            drop(recording.finish());
            pill::hide(&self.app);
            self.set_phase("idle");
        }
    }

    fn end(self: &Arc<Self>) {
        self.hands_free.store(false, Ordering::SeqCst);
        let Some(recording) = self.recording.lock().unwrap().take() else { return };
        let held = recording.started.elapsed();
        let (rate, device) = (recording.sample_rate, recording.device.clone());
        let samples = recording.finish();
        if held < SHORTEST {
            pill::hide(&self.app);
            self.set_phase("idle");
            return;
        }
        let Some(recognizer) = self.recognizer.lock().unwrap().clone() else {
            self.set_phase("idle");
            return;
        };
        pill::show(&self.app, "working", "Writing it down");
        self.set_phase("working");
        let inner = self.clone();
        let quiet = self.config().quiet_voice;
        std::thread::spawn(move || {
            inner.transcribe_and_type(&recognizer, &samples, rate, &device, quiet);
            inner.set_phase("idle");
        });
    }

    /// The words in the recording, typed where the person is (or the pill says why not).
    fn transcribe_and_type(&self, recognizer: &worker::Engine, samples: &[f32], rate: u32, device: &str, quiet: bool) {
        let started = Instant::now();
        let seconds = samples.len() as f64 / rate as f64;
        let leveled = level::normalize_with(samples, rate as f32, if quiet { 40.0 } else { 30.0 },
                                            self.config().model.lifts_words());
        if leveled.speech_db < -55.0 {
            self.note(&format!("{seconds:.1} s, no sound (speech {:.0} dBFS) from {device}", leveled.speech_db));
            pill::flash(&self.app, &format!("No sound from {device} · choose another in Settings"), "problem", 4.0);
            return;
        }
        let text = match recognizer.words(&leveled.samples, rate) {
            Ok(text) => text,
            Err(error) => {
                // The worker stopped (Hinglish): Murmur carries on, and the model loads again on the next press.
                self.note(&format!("{error}: see speech-worker.log"));
                *self.recognizer.lock().unwrap() = None;
                self.set_model(json!({"state": "failed", "message": error}));
                pill::flash(&self.app, &format!("Dictation stopped: {error} · press the key to try again"), "problem", 5.0);
                return;
            }
        };
        let config = self.config();
        if config.keep_recordings {
            match history::keep_recording(samples, rate, &text, config.model.name()) {
                Ok(path) => self.note(&format!("recording kept: {}", path.display())),
                Err(error) => self.note(&format!("can't keep the recording: {error}")),
            }
        }
        self.note(&format!("{seconds:.1} s of audio → {} characters in {:.2} s (speech {:.0} dBFS, noise {:.0}, gain {:+.0} dB{})",
                           text.chars().count(), started.elapsed().as_secs_f64(), leveled.speech_db,
                           leveled.noise_db, leveled.gain_db, if quiet { ", quiet voice" } else { "" }));
        if text.is_empty() {
            pill::flash(&self.app, "Didn't catch that", "info", 2.0);
            return;
        }
        let place = self.place();
        let (program, title) = match &place.front {
            Some((_, program, title)) => (Some(program.as_str()), Some(title.as_str())),
            None => (None, None),
        };
        let mut words = text.clone();
        if let Some(assistant) = self.app.try_state::<Arc<Assistant>>() {
            let assistant = assistant.inner().clone();
            let forced = self.command.swap(false, Ordering::SeqCst);
            let typing = self.typing.swap(false, Ordering::SeqCst) && !forced;
            let mut spot = place.spot.clone();
            // "Summarise this" with text selected in an app that doesn't say what's selected: copy it.
            if !typing && spot.selection.is_none() && !spot.terminal && (forced || assistant.choices().detect)
                && crate::commands::intent::is_about_selection(&text) {
                spot.selection = paste::copy_selection();
                if let Some(selection) = &spot.selection {
                    self.note(&format!("selection: {} characters, copied with Ctrl+C", selection.chars().count()));
                }
            }
            let front_app = program.map(|p| p.trim_end_matches(".exe").trim_end_matches(".EXE").to_string());
            let decision = if typing {
                crate::commands::intent::Decision {
                    intent: crate::commands::intent::Intent::Dictation, reason: "Shift held".into(), explicit: true,
                }
            } else {
                assistant.decide(&text, &spot, front_app.as_deref(), forced)
            };
            self.note(&format!("intent: {} ({})", if decision.intent == crate::commands::intent::Intent::Command { "command" } else { "dictation" },
                               decision.reason));
            if decision.intent == crate::commands::intent::Intent::Command {
                if config.keep_history {
                    self.history.add(&text, None, "command");
                    self.changed();
                }
                let log = |line: &str| self.note(line);
                assistant.run(&text, &spot, place.front.clone(), decision.explicit, &log);
                return;
            }
            *self.heard.lock().unwrap() = Some(text.clone());
            if let Some(cleaned) = assistant.clean_up(&text, program, title, &|line: &str| self.note(line)) {
                words = cleaned;
            }
        }
        if place.spot.text_field == Some(false) {
            // Nowhere to type (the desktop, a folder's files): pasting there does nothing, or something unexpected.
            if paste::copy(&words) {
                self.note("dictation: nowhere to type, copied instead");
                pill::flash(&self.app, "Nowhere to type here · copied to the clipboard", "info", 3.0);
                *self.last.lock().unwrap() = Some(words.trim().to_string());
                return;
            }
        }
        // Spacing, the first letter and the last full stop fitted to the sentence it lands in; never the words.
        let text = cursor::fit(&words);
        *self.last.lock().unwrap() = Some(text.trim().to_string());
        match paste::insert(&text) {
            Ok(()) => {
                pill::hide(&self.app);
                if config.keep_history {
                    self.history.add(&text, None, "dictation");
                    self.changed();
                }
            }
            Err(error) => {
                self.note(&format!("paste: {error}"));
                pill::flash(&self.app, &format!("Couldn't type it: {error} · try Paste Last Dictation in the tray"), "problem", 4.0);
            }
        }
    }

    /// A line in dictation.log (in the shell's log folder), with the time.
    fn note(&self, line: &str) {
        let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        if let Some(file) = self.log.lock().unwrap().as_mut() {
            let _ = writeln!(file, "{seconds} {line}");
        }
        if cfg!(debug_assertions) {
            println!("dictation: {line}");
        }
    }
}
