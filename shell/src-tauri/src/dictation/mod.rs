//! Dictation, as the Mac app has it: hold the dictation key, speak, let go, and the words are typed where you are.
//! Everything happens on this computer: the microphone (audio.rs), the level (level.rs, the Mac's AudioLevel), Parakeet
//! through sherpa-onnx (speech.rs), the paste (paste.rs). The key (keys.rs) and the paste work on Windows for now.
//!
//! The speech model (650 MB) is downloaded by the helper (`murmur-engine download-speech-model`, checked file by file)
//! the first time dictation is on, then loaded once and kept warm. The pill (pill.rs, ui/pill.html) shows each step.

pub mod audio;
pub mod keys;
pub mod level;
pub mod paste;
mod pill;
pub mod speech;

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
}

/// Shorter than this is a tap, not a dictation.
const SHORTEST: Duration = Duration::from_millis(250);

pub struct Dictation {
    inner: Arc<Inner>,
}

struct Inner {
    app: AppHandle,
    config: Mutex<Config>,
    combo: Arc<Mutex<keys::Combo>>,
    recognizer: Mutex<Option<Arc<speech::Recognizer>>>,
    loading: AtomicBool,
    /// The speech model: {"state": "missing|downloading|checking|waiting|loading|ready|failed", …}.
    model: Mutex<Value>,
    download: ModelDownload,
    rerun: AtomicBool,
    /// A helper launch for these arguments (the shell's: its program, environment and log folder).
    launch: Box<dyn Fn(Vec<String>, &str) -> Launch + Send + Sync>,
    recording: Mutex<Option<audio::Recording>>,
    /// Why the key can't be watched, if it can't.
    key_problem: Mutex<Option<String>>,
    log: Mutex<Option<std::fs::File>>,
}

enum Work {
    Key(keys::Press),
}

impl Dictation {
    /// Starts dictation: the pill's window, the key watcher, and the model (downloaded if it's missing and dictation
    /// is on, else loaded). `launch` makes a helper launch for some arguments and a log file's name.
    pub fn start(app: &AppHandle, config: Config, logs: PathBuf,
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
            loading: AtomicBool::new(false),
            model: Mutex::new(json!({"state": "missing"})),
            download,
            rerun: AtomicBool::new(false),
            launch: Box::new(launch),
            recording: Mutex::new(None),
            key_problem: Mutex::new(None),
            log: Mutex::new(log),
        });
        if let Err(error) = pill::make(app) {
            inner.note(&format!("no pill: {error}"));
        }
        // Key presses arrive on the hook's thread, which must answer Windows at once: the work happens here.
        let (work, jobs) = mpsc::channel::<Work>();
        let worker = inner.clone();
        std::thread::Builder::new()
            .name("murmur-dictation".into())
            .spawn(move || {
                for job in jobs {
                    match job {
                        Work::Key(keys::Press::Down) => worker.begin(),
                        Work::Key(keys::Press::Up) => worker.end(),
                        Work::Key(keys::Press::Cancel) => worker.cancel(),
                    }
                }
            })
            .expect("the dictation thread");
        if let Err(problem) = keys::listen(inner.combo.clone(), move |press| {
            let _ = work.send(Work::Key(press));
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

    /// Settings' Download (or Try Again).
    pub fn download(&self) {
        self.inner.start_download();
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
        if speech::installed(&folder) {
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
                    let recognizer = speech::Recognizer::load(&folder)?;
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
        let models: Vec<Value> = [speech::Model::English, speech::Model::Multilingual]
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
        });
        if microphones {
            state["microphones"] = json!(audio::microphones());
        }
        state
    }

    // MARK: A dictation

    fn begin(self: &Arc<Self>) {
        let config = self.config();
        if !config.enabled {
            return;
        }
        if self.recognizer.lock().unwrap().is_none() {
            let state = self.model.lock().unwrap().clone();
            let text = match state["state"].as_str().unwrap_or_default() {
                "downloading" => match (state["bytes"].as_f64(), state["total"].as_f64()) {
                    (Some(bytes), Some(total)) if total > 0.0 =>
                        format!("Getting dictation ready · {:.0}%", bytes / total * 100.0),
                    _ => "Getting dictation ready…".to_string(),
                },
                "loading" | "checking" => "Getting dictation ready…".to_string(),
                "failed" => "The speech model didn't download · Settings → Dictation".to_string(),
                _ => {
                    self.start_download();
                    "Downloading the speech model…".to_string()
                }
            };
            pill::flash(&self.app, &text, "info", 3.0);
            return;
        }
        pill::show(&self.app, "starting", "Starting the microphone…");
        let app = self.app.clone();
        let started = Instant::now();
        match audio::Recording::start(&config.microphone, move |level| pill::level(&app, level)) {
            Ok(recording) => {
                self.note(&format!("listening with {} ({} Hz), on in {:.2} s (first sound after {:.2} s)",
                                   recording.device, recording.sample_rate, started.elapsed().as_secs_f64(),
                                   recording.opened_in.as_secs_f64()));
                pill::show(&self.app, "listening", "Listening");
                *self.recording.lock().unwrap() = Some(recording);
            }
            Err(error) => {
                self.note(&format!("microphone: {error}"));
                pill::flash(&self.app, &format!("Can't use the microphone: {error}"), "problem", 4.0);
            }
        }
    }

    fn cancel(&self) {
        if let Some(recording) = self.recording.lock().unwrap().take() {
            drop(recording.finish());
            pill::hide(&self.app);
        }
    }

    fn end(self: &Arc<Self>) {
        let Some(recording) = self.recording.lock().unwrap().take() else { return };
        let held = recording.started.elapsed();
        let (rate, device) = (recording.sample_rate, recording.device.clone());
        let samples = recording.finish();
        if held < SHORTEST {
            pill::hide(&self.app);
            return;
        }
        let Some(recognizer) = self.recognizer.lock().unwrap().clone() else { return };
        pill::show(&self.app, "working", "Writing it down");
        let inner = self.clone();
        let quiet = self.config().quiet_voice;
        std::thread::spawn(move || {
            let started = Instant::now();
            let seconds = samples.len() as f64 / rate as f64;
            let leveled = level::normalize(&samples, rate as f32, if quiet { 40.0 } else { 30.0 });
            if leveled.speech_db < -55.0 {
                inner.note(&format!("{seconds:.1} s, no sound (speech {:.0} dBFS) from {device}", leveled.speech_db));
                pill::flash(&inner.app, &format!("No sound from {device} · choose another in Settings"), "problem", 4.0);
                return;
            }
            let text = speech::tidy(&recognizer.transcribe(&leveled.samples, rate));
            inner.note(&format!("{seconds:.1} s of audio → {} characters in {:.2} s (speech {:.0} dBFS, noise {:.0}, gain {:+.0} dB{})",
                                text.chars().count(), started.elapsed().as_secs_f64(), leveled.speech_db,
                                leveled.noise_db, leveled.gain_db, if quiet { ", quiet voice" } else { "" }));
            if text.is_empty() {
                pill::flash(&inner.app, "Didn't catch that", "info", 2.0);
                return;
            }
            match paste::insert(&text) {
                Ok(()) => pill::hide(&inner.app),
                Err(error) => {
                    inner.note(&format!("paste: {error}"));
                    pill::flash(&inner.app, &format!("Couldn't type it: {error}"), "problem", 4.0);
                }
            }
        });
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
