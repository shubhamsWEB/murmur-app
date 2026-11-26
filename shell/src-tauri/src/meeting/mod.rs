//! Meeting notes, as the Mac's MeetingMode: while a call runs, Murmur listens to both sides (the call's sound and your
//! microphone), writes down what's said, keeps notes as it goes, and when someone on the call asks a question, drafts
//! an answer you can say. All of it shows in a panel beside the call (ui/meeting.html), which is kept out of screen
//! sharing; at the end the notes and the transcript are saved to Documents › Murmur Meetings.
//!
//! Answering waits for the question to be over: the other side's lines since the last answer make one turn. Once they
//! pause, a line that plainly asks something is answered at once; otherwise a cloud AI decides from the conversation
//! whether they asked the user something ("answer"), are still asking ("wait") or said nothing to answer ("no"). With
//! a model on this PC, a pause decides. If they carry on within three seconds of an answer, it's written again for the
//! whole turn. Ctrl+Alt+Enter (or Answer now) answers at once.
//!
//! What the meeting is about, your instructions and your documents go with every answer and the notes. Speech is
//! transcribed with its own setting: dictation's model (on this PC, or Sarvam if that's dictation's), or Sarvam or
//! OpenAI in the cloud. The notes and answers come from the AI chosen for meetings (or for commands).

pub mod audio;
pub mod detect;
pub mod documents;
pub mod screen;
pub mod segmenter;
pub mod speakers;
pub mod text;
pub mod voices;

use crate::ai::{self, output, stream::Picture, Provider};
use crate::commands::Assistant;
use crate::dictation::{cloud, level, Dictation};
use crate::settings::Settings;
use segmenter::Segmenter;
use serde::Serialize;
use serde_json::{json, Value};
use speakers::{Source, VoiceName};
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use text::{Line, Speaker, Spoken};

/// The panel's window, and the small one that offers notes when a call starts.
pub const PANEL: &str = "meeting";
pub const OFFER: &str = "meeting-offer";
/// Answer what was just said, now (registered only while notes run).
pub const HOTKEY: &str = "CommandOrControl+Alt+Enter";
pub const HOTKEY_TEXT: &str = "Ctrl+Alt+Enter";

/// Reading and changing the settings file (main.rs owns it).
pub struct Store {
    pub read: Box<dyn Fn() -> Settings + Send + Sync>,
    pub edit: Box<dyn Fn(&mut dyn FnMut(&mut Settings)) + Send + Sync>,
}

/// What was asked for: an answer to the other side, or one of the panel's quick actions.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Answer,
    SayNext,
    FollowUps,
    Recap,
    Asked,
}

impl Kind {
    fn system(self) -> &'static str {
        match self {
            Kind::FollowUps => FOLLOW_UP_SYSTEM,
            Kind::Recap => RECAP_SYSTEM,
            _ => ANSWER_SYSTEM,
        }
    }

    /// The heading over the extra points.
    fn also_title(self) -> &'static str {
        match self {
            Kind::FollowUps => "Questions you could ask",
            Kind::Recap => "Decisions and open questions",
            _ => "You could also say",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Answer {
    id: u64,
    question: String,
    text: String,
    spoken: Spoken,
    writing: bool,
    kind: Kind,
    also_title: &'static str,
    used_screen: bool,
    looking: bool,
}

#[derive(Clone, Debug, Serialize)]
struct Document {
    name: String,
    path: String,
    #[serde(skip)]
    text: String,
}

/// The meeting, as the panel shows it, and what decides when to answer.
struct State {
    running: bool,
    finishing: bool,
    app_name: Option<String>,
    app_program: Option<String>,
    started: f64,
    lines: Vec<Line>,
    answers: Vec<Answer>,
    shown: usize,
    notes: String,
    writing_notes: bool,
    problem: Option<String>,
    saved: Option<PathBuf>,
    auto_answer: bool,
    mic_muted: bool,
    about: String,
    documents: Vec<Document>,
    email: Option<(String, String)>,
    drafting_email: bool,
    collapsed: bool,
    unread: bool,
    // Turn-taking.
    turn: Vec<Line>,
    turn_changed: Instant,
    turn_revision: u64,
    checked_revision: Option<u64>,
    checking: bool,
    last_verdict: Option<String>,
    answered_turn: Vec<Line>,
    answered_at: Option<Instant>,
    answering: bool,
    replace_next: bool,
    // Notes.
    lines_at_notes: usize,
    last_notes: Instant,
    notes_running: bool,
    // Offered when a meeting app turned on the microphone: it ends when that app lets go of it.
    automatic: bool,
    mic_free_since: Option<Instant>,
    next_id: u64,
    next_answer_id: u64,
    heard_call: bool,
    speech: String,
    // Who's speaking (voices.rs, speakers.rs).
    /// Every turn's voiceprint, grouped into the call's voices.
    clusters: voices::Clusters,
    /// The voices on show and their numbers ("Speaker 2").
    numbers: HashMap<u32, u32>,
    names: HashMap<u32, VoiceName>,
    /// The voices found among the ones you saved, and which saved voice each is.
    matched: HashMap<u32, u64>,
    /// The names heard in the meeting, offered when you name a voice.
    people: Vec<String>,
    /// What your microphone heard for each of your lines, before the call's words were taken out of it.
    mic_heard: HashMap<u64, String>,
    lines_at_names: usize,
    naming: bool,
    /// When anything was last said (a meeting nobody's speaking in ends itself).
    last_words: Instant,
}

impl State {
    fn new() -> State {
        State {
            running: false, finishing: false, app_name: None, app_program: None, started: now(), lines: vec![],
            answers: vec![], shown: 0, notes: String::new(), writing_notes: false, problem: None, saved: None,
            auto_answer: true, mic_muted: false, about: String::new(), documents: vec![], email: None,
            drafting_email: false, collapsed: false, unread: false, turn: vec![],
            turn_changed: Instant::now(), turn_revision: 0, checked_revision: None, checking: false, last_verdict: None,
            answered_turn: vec![], answered_at: None, answering: false, replace_next: false, lines_at_notes: 0,
            last_notes: Instant::now(), notes_running: false, automatic: false, mic_free_since: None, next_id: 0,
            next_answer_id: 0, heard_call: false, speech: String::new(), clusters: voices::Clusters::new(),
            numbers: HashMap::new(), names: HashMap::new(), matched: HashMap::new(), people: vec![],
            mic_heard: HashMap::new(), lines_at_names: 0, naming: false, last_words: Instant::now(),
        }
    }

    fn begin_answer(&mut self, question: &str, kind: Kind) -> usize {
        self.next_answer_id += 1;
        self.answers.push(Answer {
            id: self.next_answer_id, question: question.into(), text: String::new(), spoken: Spoken::default(),
            writing: true, kind, also_title: kind.also_title(), used_screen: false, looking: false,
        });
        self.shown = self.answers.len() - 1;
        self.shown
    }

    fn restart_last(&mut self, question: &str) -> usize {
        let Some(index) = self.answers.len().checked_sub(1) else { return self.begin_answer(question, Kind::Answer) };
        let answer = &mut self.answers[index];
        answer.question = question.into();
        answer.text.clear();
        answer.spoken = Spoken::default();
        answer.used_screen = false;
        answer.writing = true;
        self.shown = index;
        index
    }

    fn consume_replace(&mut self) -> bool {
        let replace = self.replace_next && !self.answers.is_empty();
        self.replace_next = false;
        replace
    }
}

/// One side's sound on its way to the transcript: cut into stretches of speech, each sent on to be transcribed.
struct Feed {
    speaker: Speaker,
    rate: u32,
    inner: Mutex<FeedInner>,
    send: mpsc::Sender<Piece>,
}

struct FeedInner {
    segmenter: Segmenter,
    muted: bool,
    finished: bool,
    sound: bool,
}

impl Feed {
    fn new(speaker: Speaker, rate: u32, send: mpsc::Sender<Piece>) -> Feed {
        Feed { speaker, rate, send, inner: Mutex::new(FeedInner {
            segmenter: Segmenter::new(rate as f64), muted: false, finished: false, sound: false,
        }) }
    }

    /// On the sound's thread: only the cutting happens here.
    fn add(&self, samples: &[f32]) {
        let done = {
            let mut inner = self.inner.lock().unwrap();
            if inner.finished || inner.muted {
                return;
            }
            if !inner.sound && samples.iter().any(|s| s.abs() > 1e-5) {
                inner.sound = true;
            }
            inner.segmenter.add_timed(samples)
        };
        for (piece, after) in done {
            self.deliver(piece, after);
        }
    }

    fn finish(&self) {
        let last = {
            let mut inner = self.inner.lock().unwrap();
            if inner.finished {
                return;
            }
            inner.finished = true;
            if inner.muted { None } else { inner.segmenter.flush() }
        };
        if let Some(last) = last {
            self.deliver(last, 0);
        }
    }

    fn set_muted(&self, muted: bool) {
        let mut inner = self.inner.lock().unwrap();
        inner.muted = muted;
        if muted {
            let _ = inner.segmenter.flush();
        }
    }

    fn level(&self) -> f32 {
        let inner = self.inner.lock().unwrap();
        if inner.muted { 0.0 } else { inner.segmenter.level }
    }

    fn speaking(&self) -> bool {
        let inner = self.inner.lock().unwrap();
        !inner.muted && inner.segmenter.is_speaking()
    }

    fn heard_sound(&self) -> bool {
        self.inner.lock().unwrap().sound
    }

    /// `after`: the samples heard since the piece ended (the pause that ended it), so `at` is when it began.
    fn deliver(&self, samples: Vec<f32>, after: usize) {
        let at = now() - (samples.len() + after) as f64 / self.rate as f64;
        let _ = self.send.send(Piece { speaker: self.speaker, samples, rate: self.rate, at });
    }
}

/// One stretch of speech, ready to transcribe.
struct Piece {
    speaker: Speaker,
    samples: Vec<f32>,
    rate: u32,
    at: f64,
}

struct Sound {
    _mic: Option<audio::Live>,
    _call: Option<audio::Live>,
    mic: Option<Arc<Feed>>,
    call: Option<Arc<Feed>>,
}

pub struct Meeting {
    app: AppHandle,
    store: Store,
    state: Mutex<State>,
    sound: Mutex<Option<Sound>>,
    /// Bumped by every new answer (and the meeting's end): an answer being written stops when it's no longer its turn.
    generation: AtomicU64,
    /// The transcriber's thread, while a meeting runs (it ends when the sound's done).
    worker: Mutex<Option<std::thread::JoinHandle<()>>>,
    /// Looking for a meeting app with the microphone on.
    watching: AtomicBool,
    /// The app already offered (not offered again until it lets go of the microphone), and since when one's been seen.
    offered: Mutex<(Option<String>, Option<(String, Instant)>)>,
    log: Mutex<Option<std::fs::File>>,
    /// When the panel was last sent the whole state, and whether more changed since (sent a moment later).
    sent: Mutex<(Instant, bool)>,
    /// The ticker running now (a meeting started again soon after one stopped has a new one; the old one ends).
    ticks: AtomicU64,
    /// The models that tell the call's voices apart, once they're downloaded and loaded (None: everyone's "Them").
    voices: Mutex<Option<Arc<voices::Models>>>,
    voices_loading: AtomicBool,
    /// The voices you asked Murmur to remember.
    library: Mutex<voices::Library>,
}

/// The call's voices as the panel lists them: each voice with a line, what it's shown as, its name and its source.
fn voices_shown(state: &State) -> Vec<Value> {
    let mut seen: Vec<u32> = Vec::new();
    let mut out = Vec::new();
    for line in state.lines.iter().filter(|l| l.speaker == Speaker::Them) {
        let Some(voice) = line.voice else { continue };
        if seen.contains(&voice) {
            continue;
        }
        seen.push(voice);
        let name = state.names.get(&voice);
        let (seconds, turns) = state.clusters.heard(voice);
        out.push(json!({
            "voice": voice, "label": line.who, "name": name.map(|n| n.name.clone()).unwrap_or_default(),
            "source": name.map(|n| n.source), "evidence": name.and_then(|n| n.evidence.clone()),
            "canRemember": seconds >= voices::FEWEST_SECONDS && turns >= voices::FEWEST_TURNS,
            "saved": state.matched.contains_key(&voice),
        }));
    }
    out
}

/// Names to offer when you name a voice: the people heard in the meeting, then the voices you saved; none that's
/// already on a voice.
fn people_offered(state: &State, library: &voices::Library) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let taken: Vec<String> = state.names.values().map(|n| n.name.to_lowercase()).collect();
    for name in state.people.iter().chain(library.profiles.iter().map(|p| &p.name)) {
        let lower = name.to_lowercase();
        if !taken.contains(&lower) && !out.iter().any(|have| have.to_lowercase() == lower) {
            out.push(name.clone());
        }
    }
    out
}

/// A meeting with nothing said for this long ends itself (unless that's turned off).
const QUIET_END: Duration = Duration::from_secs(600);

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

impl Meeting {
    pub fn new(app: &AppHandle, logs: &std::path::Path, data: &std::path::Path, store: Store) -> Arc<Meeting> {
        let log = std::fs::OpenOptions::new().create(true).append(true).open(logs.join("meeting.log")).ok();
        let meeting = Arc::new(Meeting {
            app: app.clone(), store, state: Mutex::new(State::new()), sound: Mutex::new(None),
            generation: AtomicU64::new(0), worker: Mutex::new(None), watching: AtomicBool::new(false),
            offered: Mutex::new((None, None)), log: Mutex::new(log), sent: Mutex::new((Instant::now(), false)),
            ticks: AtomicU64::new(0), voices: Mutex::new(None), voices_loading: AtomicBool::new(false),
            library: Mutex::new(voices::Library::load(data.join("voices.json"))),
        });
        meeting.state.lock().unwrap().auto_answer = !(meeting.store.read)().meeting_auto_answer_off;
        meeting.watch();
        meeting
    }

    fn note(&self, line: &str) {
        let seconds = now() as u64;
        if let Some(file) = self.log.lock().unwrap().as_mut() {
            let _ = writeln!(file, "{seconds} {line}");
        }
        if cfg!(debug_assertions) {
            println!("meeting: {line}");
        }
    }

    pub fn is_running(&self) -> bool {
        self.state.lock().unwrap().running
    }

    fn settings(&self) -> Settings {
        (self.store.read)()
    }

    fn edit(&self, mut change: impl FnMut(&mut Settings)) {
        (self.store.edit)(&mut |settings| change(settings));
    }

    // MARK: The AI and speech

    /// The AI for answers and notes: the meeting's own choice, else the commands'.
    fn router(&self) -> ai::Router {
        let assistant = self.app.state::<Arc<Assistant>>();
        let chosen = self.settings().meeting_ai;
        if chosen.trim().is_empty() {
            assistant.router()
        } else {
            ai::for_provider(Provider::from_name(&chosen), &assistant.choices().ai)
        }
    }

    /// What the panel says answers come from.
    fn ai_name(&self) -> String {
        self.router().display(true)
    }

    // MARK: Offering notes when a meeting starts

    /// Every three seconds: a meeting app that's had the microphone on for five seconds is offered notes (while
    /// offering is on); notes started that way finish once the app has let go of the microphone for 30 seconds.
    fn watch(self: &Arc<Self>) {
        if self.watching.swap(true, Ordering::SeqCst) {
            return;
        }
        let meeting = self.clone();
        std::thread::Builder::new()
            .name("murmur-meeting-watch".into())
            .spawn(move || loop {
                std::thread::sleep(Duration::from_secs(3));
                meeting.check();
            })
            .ok();
    }

    fn check(self: &Arc<Self>) {
        let offers = !self.settings().meeting_offer_off;
        let (running, automatic) = {
            let state = self.state.lock().unwrap();
            (state.running, state.automatic)
        };
        if !offers && !(running && automatic) {
            return;
        }
        let found = detect::meeting();
        if running {
            if !automatic {
                return;
            }
            let mut state = self.state.lock().unwrap();
            if found.is_some() {
                state.mic_free_since = None;
            } else if let Some(since) = state.mic_free_since {
                if since.elapsed() >= Duration::from_secs(30) {
                    let app = state.app_name.clone().unwrap_or("The meeting app".into());
                    drop(state);
                    self.note(&format!("{app} turned the microphone off; finishing the notes"));
                    self.stop();
                }
            } else {
                state.mic_free_since = Some(Instant::now());
            }
            return;
        }
        let mut offered = self.offered.lock().unwrap();
        let Some((name, program)) = found else {
            if offered.0.is_some() {
                hide_offer(&self.app);
            }
            *offered = (None, None);
            return;
        };
        if offered.0.as_deref() == Some(name.as_str()) {
            return;
        }
        match &offered.1 {
            // On for a few seconds, not a moment's voice search.
            Some((seen, since)) if *seen == name => {
                if since.elapsed() < Duration::from_secs(5) {
                    return;
                }
                offered.0 = Some(name.clone());
                drop(offered);
                self.note(&format!("{name} has the microphone on; offering notes"));
                show_offer(&self.app, &name, &program);
            }
            _ => offered.1 = Some((name, Instant::now())),
        }
    }

    // MARK: A meeting

    /// Starts listening to the call and your microphone (or shows the notes, when they're already running).
    pub fn start(self: &Arc<Self>, app: Option<(String, String)>, automatic: bool) {
        hide_offer(&self.app);
        {
            let state = self.state.lock().unwrap();
            if state.running || state.finishing {
                drop(state);
                self.show_panel();
                return;
            }
        }
        let settings = self.settings();
        let found = app.or_else(detect::meeting);
        let speech_choice = settings.meeting_speech.clone();
        let speech = match speech_choice.as_str() {
            "sarvam" if cloud::has_key("sarvam") => "sarvam",
            "openai" if cloud::has_key("openai") => "openai",
            _ => "",
        };
        {
            let mut state = self.state.lock().unwrap();
            let documents = std::mem::take(&mut state.documents);
            let about = std::mem::take(&mut state.about);
            *state = State::new();
            // What you set up before starting stays.
            state.documents = documents;
            state.about = about;
            state.running = true;
            state.auto_answer = !settings.meeting_auto_answer_off;
            state.app_name = found.as_ref().map(|(name, _)| name.clone());
            state.app_program = found.as_ref().map(|(_, program)| program.clone());
            state.automatic = automatic;
            state.speech = speech.to_string();
            if speech != speech_choice {
                state.problem = Some(format!("{} needs its API key: this meeting is transcribed by dictation's speech model.",
                                             if speech_choice == "sarvam" { "Sarvam" } else { "OpenAI" }));
            }
        }
        self.generation.fetch_add(1, Ordering::SeqCst);
        // The speech model, if it'll be needed and isn't loaded (dictation may be off).
        if speech.is_empty() {
            self.app.state::<Dictation>().ensure_loaded();
        }
        let (send, pieces) = mpsc::channel::<Piece>();
        let worker = {
            let meeting = self.clone();
            std::thread::Builder::new()
                .name("murmur-meeting-words".into())
                .spawn(move || {
                    for piece in pieces {
                        meeting.transcribe(piece);
                    }
                })
                .ok()
        };
        *self.worker.lock().unwrap() = worker;
        let microphone = self.app.state::<Dictation>().microphone();
        let mut sound = Sound { _mic: None, _call: None, mic: None, call: None };
        let (mic_feed, call_feed) = (Arc::new(Mutex::new(None::<Arc<Feed>>)), Arc::new(Mutex::new(None::<Arc<Feed>>)));
        for (side, slot) in [(audio::Side::Microphone, mic_feed.clone()), (audio::Side::Call, call_feed.clone())] {
            let send = send.clone();
            let speaker = if side == audio::Side::Call { Speaker::Them } else { Speaker::You };
            let started = audio::start(side, &microphone, move |rate| {
                let feed = Arc::new(Feed::new(speaker, rate, send));
                *slot.lock().unwrap() = Some(feed.clone());
                move |samples: &[f32]| feed.add(samples)
            });
            match started {
                Ok(live) => {
                    self.note(&format!("{} from {} at {} Hz", if side == audio::Side::Call { "the call" } else { "your microphone" },
                                       live.device, live.rate));
                    if side == audio::Side::Call { sound._call = Some(live) } else { sound._mic = Some(live) }
                }
                Err(error) => {
                    self.note(&format!("{}: {error}", if side == audio::Side::Call { "call sound" } else { "microphone" }));
                    self.state.lock().unwrap().problem = Some(if side == audio::Side::Call {
                        format!("Can't hear the call: {error}")
                    } else {
                        format!("Can't hear your microphone: {error}")
                    });
                }
            }
        }
        drop(send);
        sound.mic = mic_feed.lock().unwrap().take();
        sound.call = call_feed.lock().unwrap().take();
        *self.sound.lock().unwrap() = Some(sound);
        register_hotkey(&self.app, true);
        self.prepare_voices();
        self.ticker();
        self.show_panel();
        let (app_name, router) = (self.state.lock().unwrap().app_name.clone(), self.ai_name());
        self.note(&format!("notes started{}{}, answers with {router}, speech {}",
                           app_name.map(|a| format!(" ({a})")).unwrap_or_default(), if automatic { ", offered" } else { "" },
                           if speech.is_empty() { "by dictation's model" } else { speech }));
        // Windows gives silence, not an error, when nothing plays: said once a minute has passed with none.
        let meeting = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(60));
            let silent = meeting.sound.lock().unwrap().as_ref().and_then(|s| s.call.as_ref()).is_some_and(|f| !f.heard_sound());
            let mut state = meeting.state.lock().unwrap();
            if state.running && silent && state.problem.is_none() {
                state.problem = Some("No sound from the call yet. If others are talking, check that the call plays on \
                                      Windows' default speakers or headphones.".into());
                drop(state);
                meeting.changed();
            }
        });
        self.changed();
        let _ = self.app.emit("meeting-running", true);
    }

    /// Stops listening, writes the final notes and saves them.
    pub fn stop(self: &Arc<Self>) {
        {
            let mut state = self.state.lock().unwrap();
            if !state.running {
                return;
            }
            state.running = false;
            state.finishing = true;
        }
        register_hotkey(&self.app, false);
        let sound = self.sound.lock().unwrap().take();
        let worker = self.worker.lock().unwrap().take();
        self.changed();
        let _ = self.app.emit("meeting-running", false);
        let meeting = self.clone();
        std::thread::spawn(move || {
            // What was still being said goes in, then the last notes.
            if let Some(sound) = sound {
                let Sound { _mic, _call, mic, call } = sound;
                drop(_mic);
                drop(_call);
                std::thread::sleep(Duration::from_millis(300));
                for feed in [mic, call].into_iter().flatten() {
                    feed.finish();
                }
            }
            if let Some(worker) = worker {
                let (done, joined) = mpsc::channel();
                std::thread::spawn(move || {
                    let _ = worker.join();
                    let _ = done.send(());
                });
                let _ = joined.recv_timeout(Duration::from_secs(60));
            }
            // The answer being written, and notes being updated, finish first.
            let waited = Instant::now();
            while waited.elapsed() < Duration::from_secs(60) {
                let state = meeting.state.lock().unwrap();
                if !state.answering && !state.notes_running {
                    break;
                }
                drop(state);
                std::thread::sleep(Duration::from_millis(200));
            }
            let has_lines = !meeting.state.lock().unwrap().lines.is_empty();
            if has_lines {
                // The last look for people who said their own name, so the notes and the saved transcript have it.
                meeting.guess_names(true);
                meeting.write_notes(true);
                meeting.save();
            }
            let count = {
                let mut state = meeting.state.lock().unwrap();
                state.finishing = false;
                state.lines.len()
            };
            meeting.note(&format!("notes finished, {count} lines"));
            meeting.changed();
            let _ = meeting.app.emit("meetings-changed", ());
        });
    }

    /// Four times a second while it runs: the meters, and whether a turn is ready to answer.
    fn ticker(self: &Arc<Self>) {
        let meeting = self.clone();
        let mine = self.ticks.fetch_add(1, Ordering::SeqCst) + 1;
        std::thread::Builder::new()
            .name("murmur-meeting-tick".into())
            .spawn(move || {
                while meeting.is_running() && meeting.ticks.load(Ordering::SeqCst) == mine {
                    std::thread::sleep(Duration::from_millis(250));
                    meeting.tick();
                }
            })
            .ok();
    }

    fn tick(self: &Arc<Self>) {
        let (call_level, mic_level, speaking) = {
            let sound = self.sound.lock().unwrap();
            let call = sound.as_ref().and_then(|s| s.call.clone());
            let mic = sound.as_ref().and_then(|s| s.mic.clone());
            (call.as_ref().map_or(0.0, |f| f.level()), mic.as_ref().map_or(0.0, |f| f.level()),
             call.as_ref().is_some_and(|f| f.speaking()))
        };
        let _ = self.app.emit_to(PANEL, "meeting-level", json!({"call": call_level, "mic": mic_level}));
        // A change waiting to go to the panel (it's sent at most a few times a second).
        if self.sent.lock().unwrap().1 {
            self.changed();
        }
        // Nobody has said anything for ten minutes: the call is over, or was never one.
        if self.state.lock().unwrap().last_words.elapsed() >= QUIET_END && !self.settings().meeting_stay_when_quiet {
            self.note("nothing said for ten minutes: ending");
            self.stop();
            return;
        }
        let mut state = self.state.lock().unwrap();
        if !state.auto_answer || state.turn.is_empty() || state.answering || state.checking {
            return;
        }
        let quiet = state.turn_changed.elapsed().as_secs_f64();
        // Wait for them to stop (a call that never goes quiet doesn't hold it up for long).
        if speaking && quiet < 4.0 {
            return;
        }
        // Their line arrives once they've paused (0.6 s) and it's been transcribed: a further 0.6 s of quiet.
        if quiet < 0.6 {
            return;
        }
        let said = state.turn.iter().map(|l| l.text.as_str()).collect::<Vec<_>>().join(" ");
        let asks = state.turn.iter().any(|l| text::is_question(&l.text)) || text::is_question(&said);
        if state.turn.last().is_some_and(|l| text::is_question(&l.text)) {
            let replace = state.consume_replace();
            drop(state);
            self.fire(replace, false);
            return;
        }
        let router = self.router();
        if router.is_local() {
            if asks && quiet >= 1.5 {
                let replace = state.consume_replace();
                drop(state);
                self.fire(replace, false);
            } else if quiet >= 8.0 {
                state.turn.clear();
                drop(state);
                self.note(&format!("not answering (no question heard): \"{}\"", ai::cut(&said, 80)));
            }
            return;
        }
        if state.checked_revision == Some(state.turn_revision) {
            match state.last_verdict.as_deref() {
                Some("wait") if quiet >= 3.0 => {
                    let replace = state.consume_replace();
                    drop(state);
                    self.fire(replace, false);
                }
                Some("no") if quiet >= 8.0 => state.turn.clear(),
                _ => {}
            }
            return;
        }
        // Too little to be a question ("Okay.", "Right, yes."): wait for more, then let it go.
        if !asks && text::substantive_words(state.turn.iter()) < 4 {
            if quiet >= 8.0 {
                state.turn.clear();
            }
            return;
        }
        state.checking = true;
        state.checked_revision = Some(state.turn_revision);
        state.last_verdict = None;
        let revision = state.turn_revision;
        let user = format!("Conversation so far (newest last):\n{}\n\nWhat the other side said since the last answer: \"{said}\"",
                           text::transcript(state.lines.iter(), 4_000));
        drop(state);
        let meeting = self.clone();
        std::thread::spawn(move || {
            let verdict = ai::blocking(router.choose(DECIDE_SYSTEM, &user, "decision", &["answer", "wait", "no"],
                                                     Duration::from_secs(3)));
            let mut state = meeting.state.lock().unwrap();
            state.checking = false;
            if revision != state.turn_revision || state.turn.is_empty() || state.answering {
                return;
            }
            state.last_verdict = verdict.clone();
            match verdict.as_deref() {
                Some("answer") => {
                    let replace = state.consume_replace();
                    drop(state);
                    meeting.fire(replace, false);
                }
                Some("wait") => {
                    drop(state);
                    meeting.note("they're still asking");
                }
                Some("no") => {
                    drop(state);
                    meeting.note(&format!("nothing to answer: \"{}\"", ai::cut(&said, 80)));
                }
                // No verdict (the check failed or timed out): answer what looks like a question.
                _ if asks => {
                    let replace = state.consume_replace();
                    drop(state);
                    meeting.fire(replace, false);
                }
                _ => {}
            }
        });
    }

    // MARK: Words

    fn transcribe(self: &Arc<Self>, piece: Piece) {
        let speech = self.state.lock().unwrap().speech.clone();
        // The call's side: where one voice stops and another starts inside this stretch (one turn when it's one voice).
        let models = if piece.speaker == Speaker::Them { self.voices.lock().unwrap().clone() } else { None };
        let heard = models.as_ref().map(|_| cloud::to_16k(&piece.samples, piece.rate));
        let turns = match (&models, &heard) {
            (Some(models), Some(heard)) => models.turns(heard),
            _ => Vec::new(),
        };
        let mut timed: Option<Vec<voices::TimedWord>> = None;
        let mut local = || -> Result<String, String> {
            let dictation = self.app.state::<Dictation>();
            let Some(engine) = dictation.engine() else {
                dictation.ensure_loaded();
                return Err("The speech model isn't ready yet. Set it up under Settings › Dictation.".into());
            };
            let leveled = level::normalize_with(&piece.samples, piece.rate as f32, 30.0, true);
            // Two people in it: the words with their times, so each goes to the one who said it.
            if turns.len() > 1 {
                if let Some((words, times)) = engine.timed(&leveled.samples, piece.rate) {
                    timed = Some(times.into_iter().map(|(text, start, end)| voices::TimedWord { text, start, end }).collect());
                    return Ok(words);
                }
            }
            engine.words(&leveled.samples, piece.rate)
        };
        let result = match speech.as_str() {
            "sarvam" | "openai" => {
                let cloud = if speech == "sarvam" {
                    let choice = self.app.state::<Dictation>().config().sarvam;
                    ai::blocking(cloud::sarvam(&piece.samples, piece.rate, &choice))
                } else {
                    ai::blocking(cloud::openai(&piece.samples, piece.rate))
                };
                cloud.or_else(|error| {
                    // The cloud couldn't be reached: this PC's model for this piece, rather than losing it.
                    self.note(&format!("cloud speech failed ({error}); this piece on this PC"));
                    local()
                })
            }
            _ => local(),
        };
        let words = match result {
            Ok(words) => words,
            Err(error) => {
                self.note(&format!("couldn't transcribe: {error}"));
                let mut state = self.state.lock().unwrap();
                if state.problem.is_none() {
                    state.problem = Some(error);
                    drop(state);
                    self.changed();
                }
                return;
            }
        };
        let words = crate::dictation::speech::tidy(&words);
        if !text::is_worth_keeping(&words) {
            return;
        }
        let length = piece.samples.len() as f64 / piece.rate as f64;
        let print = |from: f64, to: f64| -> Option<Vec<f32>> {
            let (models, heard) = (models.as_ref()?, heard.as_ref()?);
            let rate = voices::RATE as f64;
            let (a, b) = (((from * rate) as usize).min(heard.len()), ((to * rate) as usize).min(heard.len()));
            models.print(&heard[a..b])
        };
        if turns.len() > 1 {
            // Transcribed once, whole; each turn gets the words said in it.
            let cuts: Vec<f64> = turns[..turns.len() - 1].iter().map(|turn| turn.end).collect();
            let parts = timed.as_ref().and_then(|timed| voices::texts(timed, &cuts, &words))
                .unwrap_or_else(|| voices::texts_by_share(&words, &turns));
            if parts.len() == turns.len() {
                self.note(&format!("{} people in one stretch of {length:.0} s: cut where the voice changes", turns.len()));
                for (turn, part) in turns.iter().zip(parts) {
                    if text::is_worth_keeping(&part) {
                        self.add(piece.speaker, part, piece.at + turn.start, piece.at + turn.end, print(turn.start, turn.end));
                    }
                }
                return;
            }
        }
        let whole = print(0.0, length);
        self.add(piece.speaker, words, piece.at, piece.at + length, whole);
    }

    /// `print`: the voiceprint of who said it (the call's side, when the voice models are in).
    fn add(self: &Arc<Self>, speaker: Speaker, words: String, at: f64, end: f64, print: Option<Vec<f32>>) {
        let mut guess = false;
        {
            let mut state = self.state.lock().unwrap();
            let id = state.next_id;
            state.next_id += 1;
            let mut line = Line::new(id, speaker, words, at, end);
            match speaker {
                // On speakers, your microphone hears the call too: that isn't you speaking. It's compared with all they
                // said while it was being heard, not one of their lines: the microphone cuts elsewhere than the call.
                Speaker::You => {
                    let theirs: Vec<String> = text::during(&line, &state.lines).iter().map(|l| l.text.clone()).collect();
                    let theirs: Vec<&str> = theirs.iter().map(String::as_str).collect();
                    let Some(yours) = text::without_echo(&line.text, &theirs) else {
                        drop(state);
                        self.note("your microphone picked up the call (speakers?): left out");
                        return;
                    };
                    state.mic_heard.insert(id, line.text.clone());
                    if yours != line.text {
                        self.note("your microphone picked up the call under your words: their part left out");
                        line.text = yours;
                    }
                }
                Speaker::Them => {
                    state.heard_call = true;
                    if let Some(print) = print {
                        line.stretch = Some(state.clusters.add(print, end - at));
                    }
                }
            }
            // Lines stay in the order they were said: a long stretch finishes after shorter ones that began later.
            let index = state.lines.iter().rposition(|l| l.at <= line.at).map_or(0, |i| i + 1);
            state.lines.insert(index, line.clone());
            state.lines_at_notes = state.lines_at_notes.min(index);
            if speaker == Speaker::Them {
                // What your microphone heard of this, written down before their line was, goes now.
                let yours: Vec<Line> = state.lines.iter()
                    .filter(|l| l.speaker == Speaker::You && l.end >= line.at - text::ECHO_SLACK && l.at <= line.end + text::ECHO_SLACK)
                    .cloned().collect();
                for mine in yours {
                    let heard = state.mic_heard.get(&mine.id).cloned().unwrap_or_else(|| mine.text.clone());
                    let theirs: Vec<String> = text::during(&mine, &state.lines).iter().map(|l| l.text.clone()).collect();
                    let theirs: Vec<&str> = theirs.iter().map(String::as_str).collect();
                    let rest = text::without_echo(&heard, &theirs);
                    if rest.as_deref() == Some(mine.text.as_str()) {
                        continue;
                    }
                    let Some(at) = state.lines.iter().position(|l| l.id == mine.id) else { continue };
                    match rest {
                        Some(rest) => state.lines[at].text = rest,
                        None => {
                            state.lines.remove(at);
                            if at < state.lines_at_notes {
                                state.lines_at_notes -= 1;
                            }
                            if at < state.lines_at_names {
                                state.lines_at_names -= 1;
                            }
                        }
                    }
                }
            }
            state.last_words = Instant::now();
            self.refresh_speakers(&mut state);
            if speaker == Speaker::Them {
                let line = state.lines.iter().find(|l| l.id == id).cloned().unwrap_or(line);
                self.join_turn(&mut state, line);
            }
            if state.lines.len().saturating_sub(state.lines_at_names) >= 20 && !state.answering {
                guess = true;
            }
        }
        let _ = self.app.emit_to(PANEL, "meeting-lines", ());
        self.changed();
        if guess {
            self.guess_names(false);
        }
        self.write_notes_if_due();
    }

    // MARK: Who's speaking

    /// The voice models, loaded in the background when a meeting starts (downloaded the first time: 32 MB). Until
    /// they're in, the other side is "Them".
    fn prepare_voices(self: &Arc<Self>) {
        if self.voices.lock().unwrap().is_some() || self.voices_loading.swap(true, Ordering::SeqCst) {
            return;
        }
        let meeting = self.clone();
        std::thread::Builder::new().name("murmur-meeting-voices".into()).spawn(move || {
            let loaded = (|| -> Result<voices::Models, String> {
                let folder = voices::folder().ok_or("no folder for the voice models")?;
                if !voices::installed(&folder) {
                    meeting.note("voices: downloading the models that tell speakers apart (32 MB, once)");
                    ai::blocking(voices::download(&folder))?;
                }
                voices::Models::load(&folder)
            })();
            match loaded {
                Ok(models) => {
                    *meeting.voices.lock().unwrap() = Some(Arc::new(models));
                    meeting.note("voices: ready (speakers are told apart on this PC)");
                }
                Err(error) => meeting.note(&format!("voices: not available ({error}); the other side stays \"Them\"")),
            }
            meeting.voices_loading.store(false, Ordering::SeqCst);
        }).ok();
    }

    /// Every line's voice as the meeting is grouped now, saved voices recognised, and what each line is shown as.
    fn refresh_speakers(&self, state: &mut State) {
        for index in 0..state.lines.len() {
            if let Some(stretch) = state.lines[index].stretch {
                state.lines[index].voice = state.clusters.voice(stretch);
            }
        }
        // A voice heard enough that's plainly one you saved carries that name (yours for it, if you gave one, stays).
        let voices: HashSet<u32> = state.lines.iter().filter_map(|l| l.voice).collect();
        let mut library = self.library.lock().unwrap();
        for voice in voices {
            if state.names.get(&voice).is_some_and(|name| name.source >= Source::Library) {
                continue;
            }
            let (seconds, turns) = state.clusters.heard(voice);
            if seconds < voices::FEWEST_SECONDS || turns < voices::FEWEST_TURNS {
                continue;
            }
            let Some(print) = state.clusters.centroid(voice) else { continue };
            let Some((profile, score)) = library.who(&print).map(|(profile, score)| (profile.clone(), score)) else { continue };
            // One saved voice is one person here: the voice that's most like it keeps the name.
            if state.matched.values().any(|id| *id == profile.id) {
                continue;
            }
            self.note(&format!("voices: voice {voice} is a saved voice ({:.2} alike)", score));
            state.names.insert(voice, VoiceName { name: profile.name.clone(), source: Source::Library, evidence: None });
            state.matched.insert(voice, profile.id);
            library.seen(profile.id, now());
        }
        drop(library);
        state.numbers = speakers::relabel(&mut state.lines, &state.names);
    }

    /// Asks the meeting's AI for the names in what's said, when some voice on show has no name of yours or saved. A
    /// voice is named only when it says its own name on its own line (`speakers::read`); the other names heard are
    /// offered when you name someone. `wait`: at the end of the meeting, before the notes are written.
    fn guess_names(self: &Arc<Self>, wait: bool) {
        let (content, router) = {
            let mut state = self.state.lock().unwrap();
            if state.naming {
                return;
            }
            let Some(content) = speakers::content(&state.lines, &state.numbers, &state.names, state.started) else { return };
            state.naming = true;
            state.lines_at_names = state.lines.len();
            (content, self.router())
        };
        if router.is_local() && !ai::ollama_installed() {
            self.state.lock().unwrap().naming = false;
            return;
        }
        let meeting = self.clone();
        let ask = move || {
            let reply = ai::blocking(router.write(speakers::INSTRUCTION, &content, None, 600, true, &mut |_| {}, &|| false));
            let mut state = meeting.state.lock().unwrap();
            state.naming = false;
            let Ok(reply) = reply else { return };
            let reply = output::answer(&reply);
            let (found, refuted) = speakers::read(&reply, &state.lines, &state.numbers, state.started);
            for voice in refuted {
                if state.names.get(&voice).is_some_and(|name| name.source == Source::Conversation) {
                    state.names.remove(&voice);
                }
            }
            for (voice, name) in found {
                meeting.note(&format!("voices: voice {voice} said their own name ({})", name.evidence.clone().unwrap_or_default()));
                let merged = VoiceName::merge(state.names.get(&voice), name);
                state.names.insert(voice, merged);
            }
            for person in speakers::people(&reply) {
                if !state.people.iter().any(|have| have.to_lowercase() == person.to_lowercase()) {
                    state.people.push(person);
                }
            }
            meeting.refresh_speakers(&mut state);
            drop(state);
            meeting.changed();
        };
        if wait {
            ask();
        } else {
            std::thread::spawn(ask);
        }
    }

    /// You named a voice (or, with an empty name, said the name on it is wrong). `remember`: saved, so Murmur knows
    /// the voice in later meetings.
    fn name_voice(self: &Arc<Self>, voice: u32, name: &str, remember: bool) -> Result<(), String> {
        let name = name.trim();
        let mut state = self.state.lock().unwrap();
        state.names.insert(voice, VoiceName { name: name.to_string(), source: Source::User, evidence: None });
        if name.is_empty() {
            state.matched.remove(&voice);
        }
        let mut result = Ok(());
        if remember && !name.is_empty() {
            let (seconds, turns) = state.clusters.heard(voice);
            match state.clusters.centroid(voice) {
                Some(print) if seconds >= voices::FEWEST_SECONDS && turns >= voices::FEWEST_TURNS => {
                    self.library.lock().unwrap().remember(name, &print, turns, now());
                    self.note(&format!("voices: voice {voice} saved ({turns} turns, {seconds:.0} s)"));
                }
                _ => result = Err("Murmur hasn't heard enough of this voice to remember it yet. Try again later in the call.".to_string()),
            }
        }
        self.refresh_speakers(&mut state);
        drop(state);
        self.changed();
        let _ = self.app.emit("meeting-people", ());
        result
    }

    /// You said two voices are one person: `from`'s lines are `into`'s, now and as the meeting goes on.
    fn merge_voices(self: &Arc<Self>, from: u32, into: u32) {
        let mut state = self.state.lock().unwrap();
        state.clusters.merge(from, into);
        if let Some(name) = state.names.remove(&from) {
            if !state.names.contains_key(&into) {
                state.names.insert(into, name);
            }
        }
        state.matched.remove(&from);
        self.refresh_speakers(&mut state);
        drop(state);
        self.note(&format!("voices: voice {from} is voice {into} (you said so)"));
        self.changed();
    }

    /// The voices you saved, for Meetings › People: newest seen first.
    pub fn people(&self) -> Value {
        let library = self.library.lock().unwrap();
        let mut profiles: Vec<&voices::Profile> = library.profiles.iter().collect();
        profiles.sort_by(|a, b| b.last_seen.total_cmp(&a.last_seen));
        json!(profiles.iter().map(|p| json!({"id": p.id, "name": p.name, "samples": p.samples, "lastSeen": p.last_seen})).collect::<Vec<_>>())
    }

    fn join_turn(&self, state: &mut State, line: Line) {
        // Still talking during the answer, or carrying on within three seconds of it: the answer was early, so it's
        // written again for the whole turn.
        let continuing = !state.answered_turn.is_empty() && state.auto_answer
            && (state.answering || state.answered_at.is_some_and(|at| at.elapsed() < Duration::from_secs(3)));
        if continuing && state.turn.is_empty() {
            self.generation.fetch_add(1, Ordering::SeqCst);
            state.answering = false;
            state.turn = state.answered_turn.clone();
            state.replace_next = true;
            self.note("they carried on; answering again");
        }
        state.turn.push(line);
        // With auto answer off, the turn is only what Answer now would answer: their last few lines.
        if !state.auto_answer && state.turn.len() > 4 {
            let extra = state.turn.len() - 4;
            state.turn.drain(..extra);
        }
        state.turn_changed = Instant::now();
        state.turn_revision += 1;
    }

    // MARK: Answers

    /// Writes an answer for the turn into the panel (a new one, or over the last when they carried on). `screen`:
    /// look at the meeting's screen too (also when the question is about it: "this chart", "the slide").
    fn fire(self: &Arc<Self>, replace: bool, screen: bool) {
        let (lines, waited) = {
            let mut state = self.state.lock().unwrap();
            let lines = std::mem::take(&mut state.turn);
            state.answered_turn = lines.clone();
            state.answered_at = None;
            (lines, state.turn_changed.elapsed().as_secs_f64())
        };
        let asked = lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>().join(" ");
        if !lines.is_empty() {
            self.note(&format!("answering {waited:.1} s after their last line came in"));
        }
        let (question, request) = if asked.is_empty() {
            ("What's on the screen?".to_string(),
             "Nobody has asked anything yet: say what's being shown on the meeting's screen and what the user could say \
              about it.".to_string())
        } else {
            (asked.clone(), format!("What the other side just asked: \"{asked}\""))
        };
        let screen = screen || text::refers_to_screen(&asked);
        self.respond(Kind::Answer, &question, &request, screen, replace, 12_000);
    }

    /// Their latest lines: the turn so far, else what they said in the last half minute (up to three lines).
    fn latest_theirs(&self, within: f64) -> Vec<Line> {
        let mut state = self.state.lock().unwrap();
        if !state.turn.is_empty() {
            return state.turn.clone();
        }
        let theirs: Vec<Line> = state.lines.iter().filter(|l| l.speaker == Speaker::Them).cloned().collect();
        let Some(last) = theirs.last() else { return vec![] };
        if now() - last.at > within {
            return vec![];
        }
        let recent: Vec<Line> = theirs.iter().filter(|l| last.at - l.at < 30.0).cloned().collect();
        let kept = recent[recent.len().saturating_sub(3)..].to_vec();
        state.turn = kept.clone();
        kept
    }

    /// Answers what the other side said last, now.
    pub fn answer_now(self: &Arc<Self>) {
        {
            let state = self.state.lock().unwrap();
            if !state.running && state.lines.is_empty() {
                return;
            }
        }
        if self.latest_theirs(f64::MAX).is_empty() {
            self.state.lock().unwrap().problem = Some("Nothing from the other side to answer yet.".into());
            self.changed();
            return;
        }
        self.note("answer now");
        self.fire(false, false);
    }

    /// Answers about what's on the meeting's screen.
    fn answer_from_screen(self: &Arc<Self>) {
        self.latest_theirs(90.0);
        self.note("answer about the screen");
        self.fire(false, true);
    }

    /// Writes a reply of `kind` into the panel: the meeting's context and conversation, the request, and (with
    /// `screen`) a picture or the text of the meeting's screen.
    fn respond(self: &Arc<Self>, kind: Kind, question: &str, request: &str, screen: bool, replace: bool, limit: usize) {
        let router = self.router();
        let mine = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let (index, prompt, program) = {
            let mut state = self.state.lock().unwrap();
            let index = if replace { state.restart_last(question) } else { state.begin_answer(question, kind) };
            state.answering = true;
            state.problem = None;
            if state.collapsed {
                state.unread = true;
            }
            let context = self.context(&state);
            let mut prompt = if context.is_empty() { String::new() } else { format!("{context}\n\n") };
            prompt += &format!("Conversation so far (newest last):\n{}\n\n{request}", text::transcript(state.lines.iter(), limit));
            (index, prompt, state.app_program.clone())
        };
        self.changed();
        let meeting = self.clone();
        std::thread::spawn(move || {
            let mut prompt = prompt;
            let mut picture: Option<Picture> = None;
            if screen {
                meeting.mark_screen(index, true);
                match screen::capture(program.as_deref()) {
                    Some(shot) if router.looks_at_images() => {
                        prompt += &format!("\n\nA picture of the meeting's screen is attached ({}): what's being shown or \
                                            shared now. Use it when the question is about what's on it.", shot.title);
                        meeting.note(&format!("looked at the screen (a picture, to {})", router.name()));
                        picture = Some(shot.picture);
                    }
                    Some(shot) => match screen::text(&shot.picture) {
                        Some(read) => {
                            prompt += &format!("\n\nText read from the meeting's screen ({}), top to bottom; charts and \
                                                pictures aren't described, only their words and numbers:\n{}", shot.title,
                                               ai::cut(&read, 6_000));
                            meeting.note("looked at the screen (its text, read on this PC)");
                        }
                        None => meeting.note("the screen had no text to read"),
                    },
                    None => {
                        meeting.state.lock().unwrap().problem = Some("Couldn't see the meeting's screen.".into());
                        meeting.note("couldn't capture the screen");
                    }
                }
                meeting.mark_screen(index, false);
            }
            if meeting.generation.load(Ordering::SeqCst) != mine {
                return;
            }
            let started = Instant::now();
            let mut first: Option<f64> = None;
            let mut written = String::new();
            let mut last_sent = Instant::now() - Duration::from_secs(1);
            let stop = || meeting.generation.load(Ordering::SeqCst) != mine;
            let result = ai::blocking(router.write(kind.system(), &prompt, picture.as_ref(), 3_000, true, &mut |piece: &str| {
                if first.is_none() {
                    first = Some(started.elapsed().as_secs_f64());
                }
                written.push_str(piece);
                if last_sent.elapsed() >= Duration::from_millis(70) {
                    last_sent = Instant::now();
                    meeting.update_answer(index, &written, false, mine);
                }
            }, &stop));
            if stop() {
                return;
            }
            match result {
                Ok(text) => {
                    meeting.update_answer(index, &output::answer(&text), true, mine);
                    meeting.note(&format!("answered ({}): first words in {:.1} s, done in {:.1} s, {} characters of prompt",
                                          router.display(true), first.unwrap_or(0.0), started.elapsed().as_secs_f64(),
                                          prompt.chars().count()));
                }
                Err(error) => {
                    meeting.update_answer(index, &written, true, mine);
                    meeting.state.lock().unwrap().problem = Some(format!("Couldn't draft an answer: {error}"));
                    meeting.note(&format!("answer failed: {error}"));
                }
            }
            {
                let mut state = meeting.state.lock().unwrap();
                state.answering = false;
                if kind == Kind::Answer {
                    state.answered_at = Some(Instant::now());
                }
            }
            meeting.changed();
            meeting.write_notes_if_due();
        });
    }

    fn mark_screen(&self, index: usize, looking: bool) {
        if let Some(answer) = self.state.lock().unwrap().answers.get_mut(index) {
            answer.used_screen = true;
            answer.looking = looking;
        }
        self.changed();
    }

    /// The answer as it's written so far: to the panel at once (the rest of the state follows a moment later).
    fn update_answer(&self, index: usize, written: &str, done: bool, generation: u64) {
        if self.generation.load(Ordering::SeqCst) != generation {
            return;
        }
        let answer = {
            let mut state = self.state.lock().unwrap();
            let Some(answer) = state.answers.get_mut(index) else { return };
            answer.text = written.to_string();
            answer.spoken = text::spoken(written);
            if done {
                answer.writing = false;
            }
            answer.clone()
        };
        let _ = self.app.emit_to(PANEL, "meeting-answer", json!({"index": index, "answer": answer}));
        if done {
            self.changed();
        }
    }

    fn context(&self, state: &State) -> String {
        let documents: Vec<(String, String)> = state.documents.iter().map(|d| (d.name.clone(), d.text.clone())).collect();
        text::context(&state.about, &self.settings().meeting_instructions, &documents, 24_000)
    }

    // MARK: Quick actions (the panel's buttons and the Ask box)

    fn say_next(self: &Arc<Self>) {
        self.note("what should I say");
        self.respond(Kind::SayNext, "What should I say?", "Nobody asked the user anything directly. From where the \
            conversation is now, suggest what the user could say next to move it forward or add something useful.", false, false, 12_000);
    }

    fn follow_ups(self: &Arc<Self>) {
        self.note("follow-up questions");
        self.respond(Kind::FollowUps, "Follow-up questions", "Suggest questions the user could ask now.", false, false, 12_000);
    }

    fn recap(self: &Arc<Self>) {
        self.note("recap");
        self.respond(Kind::Recap, "Recap so far", "Recap the meeting so far.", false, false, 20_000);
    }

    fn ask(self: &Arc<Self>, question: &str) {
        let question = question.trim();
        if question.is_empty() {
            return;
        }
        self.note("asked");
        self.respond(Kind::Asked, question, &format!("The user asks you privately (they didn't say this in the meeting): \
            \"{question}\""), text::refers_to_screen(question), false, 12_000);
    }

    // MARK: Notes

    /// When enough of substance has been said since the last update: about a paragraph (80 words) after a minute and
    /// a half, or a lot (250 words) after 45 seconds, and no answer is being written.
    fn write_notes_if_due(self: &Arc<Self>) {
        {
            let mut state = self.state.lock().unwrap();
            if !state.running || state.notes_running || state.answering || state.lines_at_notes > state.lines.len() {
                return;
            }
            let words = text::substantive_words(state.lines[state.lines_at_notes..].iter());
            let since = state.last_notes.elapsed().as_secs_f64();
            if !((words >= 80 && since >= 90.0) || (words >= 250 && since >= 45.0)) {
                return;
            }
            state.notes_running = true;
        }
        let meeting = self.clone();
        std::thread::spawn(move || {
            meeting.write_notes(false);
            meeting.state.lock().unwrap().notes_running = false;
        });
    }

    /// Updates the notes from what's new since the last update (the final notes read the whole meeting again).
    /// Small talk and call logistics are left out of what the AI reads; it can answer NO CHANGE.
    fn write_notes(&self, last: bool) {
        let router = self.router();
        let prompt = {
            let mut state = self.state.lock().unwrap();
            let start = state.lines_at_notes.min(state.lines.len());
            state.lines_at_notes = state.lines.len();
            state.last_notes = Instant::now();
            let substantive: Vec<Line> = state.lines.iter().filter(|l| text::is_substantive(&l.text)).cloned().collect();
            let earlier: Vec<Line> = state.lines[..start].iter().filter(|l| text::is_substantive(&l.text)).cloned().collect();
            let fresh: Vec<Line> = state.lines[start..].iter().filter(|l| text::is_substantive(&l.text)).cloned().collect();
            if if last { substantive.is_empty() } else { fresh.is_empty() } {
                return;
            }
            state.writing_notes = true;
            let context = self.context(&state);
            let mut prompt = if context.is_empty() { String::new() } else { format!("{context}\n\n") };
            if last {
                if !state.notes.is_empty() {
                    prompt += &format!("Notes taken during the meeting:\n{}\n\n", state.notes);
                }
                prompt += &speakers::note(&state.lines);
                prompt += &format!("The whole meeting (newest last):\n{}\n\nThe meeting has ended. Write the final notes from \
                                    the whole meeting, with a title line (# …) naming what it was actually about.",
                                   text::transcript(substantive.iter(), 30_000));
            } else {
                prompt += &speakers::note(&state.lines);
                prompt += &if state.notes.is_empty() { "No notes yet.\n\n".to_string() } else { format!("Notes so far:\n{}\n\n", state.notes) };
                if !earlier.is_empty() {
                    let tail = &earlier[earlier.len().saturating_sub(6)..];
                    prompt += &format!("Just before, for context (already in the notes):\n{}\n\n", text::transcript(tail.iter(), 1_500));
                }
                prompt += &format!("New since the notes were last updated:\n{}\n\nUpdate the notes with what's new and worth \
                                    keeping, and reply with the whole notes. If nothing new is worth noting, reply exactly: \
                                    NO CHANGE", text::transcript(fresh.iter(), 10_000));
            }
            prompt
        };
        self.changed();
        // The final notes have room for a long meeting.
        let reply = ai::blocking(router.write(NOTES_SYSTEM, &prompt, None, if last { 8_000 } else { 3_000 }, true, &mut |_| {}, &|| false));
        let mut state = self.state.lock().unwrap();
        state.writing_notes = false;
        match reply {
            Ok(reply) => {
                let reply = output::answer(&reply);
                if !last && text::is_no_change(&reply) {
                    drop(state);
                    self.note("notes: nothing new worth noting");
                } else {
                    state.notes = reply;
                    drop(state);
                    self.note(&format!("notes {}", if last { "finished" } else { "updated" }));
                }
            }
            Err(error) => {
                state.problem = Some(format!("Couldn't write the notes: {error}"));
                drop(state);
                self.note(&format!("notes failed: {error}"));
            }
        }
        self.changed();
    }

    /// Where meeting notes are saved: Documents › Murmur Meetings.
    pub fn folder() -> Option<PathBuf> {
        let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from)?;
        let documents = home.join("Documents");
        Some(if documents.is_dir() { documents } else { home }.join("Murmur Meetings"))
    }

    fn save(&self) {
        let Some(folder) = Meeting::folder() else { return };
        let mut state = self.state.lock().unwrap();
        let (y, mo, d, h, mi) = civil(state.started + text::local_offset());
        let app = state.app_name.clone().unwrap_or("Meeting".into());
        let name = format!("{y:04}-{mo:02}-{d:02} {h:02}.{mi:02} {app}.md").replace(['/', '\\', ':'], "-");
        let mut body = if state.notes.is_empty() { "# Meeting notes\n".to_string() } else { state.notes.clone() };
        body += "\n\n## Transcript\n\n";
        body += &state.lines.iter().map(|l| format!("**{} {}:** {}", text::clock_seconds(l.at), l.who, l.text))
            .collect::<Vec<_>>().join("\n\n");
        body += "\n";
        let path = folder.join(name);
        let written = std::fs::create_dir_all(&folder).and_then(|_| std::fs::write(&path, body));
        match written {
            Ok(()) => {
                state.saved = Some(path.clone());
                drop(state);
                self.note(&format!("notes saved to {}", path.display()));
            }
            Err(error) => state.problem = Some(format!("Couldn't save the notes: {error}")),
        }
    }

    /// Drafts a follow-up email from the notes: thanks, what was decided, who does what, the next step.
    fn draft_email(self: &Arc<Self>) {
        let prompt = {
            let mut state = self.state.lock().unwrap();
            if state.drafting_email || (state.notes.is_empty() && state.lines.is_empty()) {
                return;
            }
            state.drafting_email = true;
            let context = self.context(&state);
            let mut prompt = if context.is_empty() { String::new() } else { format!("{context}\n\n") };
            prompt += &if state.notes.is_empty() {
                let lines: Vec<Line> = state.lines.iter().filter(|l| text::is_substantive(&l.text)).cloned().collect();
                format!("The meeting (newest last):\n{}", text::transcript(lines.iter(), 20_000))
            } else {
                format!("The meeting's notes:\n{}", state.notes)
            };
            prompt
        };
        self.note("drafting a follow-up email");
        self.changed();
        let router = self.router();
        let meeting = self.clone();
        std::thread::spawn(move || {
            let reply = ai::blocking(router.write(EMAIL_SYSTEM, &prompt, None, 1_500, true, &mut |_| {}, &|| false));
            let mut state = meeting.state.lock().unwrap();
            state.drafting_email = false;
            match reply {
                Ok(reply) => {
                    let (subject, body) = text::email(&output::answer(&reply));
                    if let Some(saved) = &state.saved {
                        if let Ok(mut file) = std::fs::OpenOptions::new().append(true).open(saved) {
                            let _ = write!(file, "\n## Follow-up email\n\n**Subject:** {subject}\n\n{body}\n");
                        }
                    }
                    state.email = Some((subject, body));
                }
                Err(error) => state.problem = Some(format!("Couldn't draft the email: {error}")),
            }
            drop(state);
            meeting.changed();
        });
    }

    // MARK: The panel

    /// Tells the panel what changed: at once, unless it was told less than 150 ms ago (then the ticker sends it).
    fn changed(&self) {
        {
            let mut sent = self.sent.lock().unwrap();
            if sent.0.elapsed() < Duration::from_millis(150) {
                sent.1 = true;
                return;
            }
            *sent = (Instant::now(), false);
        }
        let _ = self.app.emit_to(PANEL, "meeting", self.snapshot());
    }

    /// What the panel shows.
    pub fn snapshot(&self) -> Value {
        let settings = self.settings();
        let ai_name = self.ai_name();
        let commands_ai = self.app.state::<Arc<Assistant>>().router().display(true);
        let state = self.state.lock().unwrap();
        json!({
            "running": state.running,
            "finishing": state.finishing,
            "app": state.app_name,
            "started": state.started,
            // The latest 400 (the saved file has them all).
            "lines": state.lines[state.lines.len().saturating_sub(400)..].iter().map(|l| json!({"id": l.id,
                "speaker": l.who, "side": l.speaker.name(), "voice": l.voice, "text": l.text, "time": text::clock(l.at)})).collect::<Vec<_>>(),
            // The call's voices, for naming them: what each is shown as, its name and where that came from.
            "voices": voices_shown(&state),
            "people": people_offered(&state, &self.library.lock().unwrap()),
            "stayWhenQuiet": settings.meeting_stay_when_quiet,
            "lineCount": state.lines.len(),
            "answers": state.answers,
            "shown": state.shown,
            "notes": state.notes,
            "writingNotes": state.writing_notes,
            "problem": state.problem,
            "saved": state.saved.as_ref().map(|p| p.display().to_string()),
            "autoAnswer": state.auto_answer,
            "micMuted": state.mic_muted,
            "about": state.about,
            "instructions": settings.meeting_instructions,
            "documents": state.documents,
            "email": state.email.as_ref().map(|(subject, body)| json!({"subject": subject, "body": body})),
            "draftingEmail": state.drafting_email,
            "ai": settings.meeting_ai,
            "aiName": ai_name,
            "commandsAi": commands_ai,
            "speech": settings.meeting_speech,
            "speechNow": state.speech,
            "keys": {"anthropic": Provider::Anthropic.has_key(), "openai": Provider::OpenAI.has_key(), "sarvam": Provider::Sarvam.has_key()},
            "layout": if settings.meeting_layout == "strip" { "strip" } else { "card" },
            "opacity": settings.meeting_opacity.filter(|o| (0.35..=1.0).contains(o)).unwrap_or(1.0),
            "solidOnHover": !settings.meeting_solid_on_hover_off,
            "textSize": settings.meeting_text_size.filter(|s| (15.0..=30.0).contains(s)).unwrap_or(19.0),
            "collapsed": state.collapsed,
            "unread": state.unread,
            "hotkey": HOTKEY_TEXT,
            "offers": !settings.meeting_offer_off,
        })
    }

    /// One of the panel's controls.
    pub fn action(self: &Arc<Self>, action: &str, value: &Value) -> Result<(), String> {
        let text = value.as_str().unwrap_or_default().to_string();
        let flag = value.as_bool().unwrap_or(false);
        match action {
            "start" => self.start(None, false),
            "stop" => self.stop(),
            "answerNow" => self.answer_now(),
            "screen" => self.answer_from_screen(),
            "sayNext" => self.say_next(),
            "followUps" => self.follow_ups(),
            "recap" => self.recap(),
            "ask" => self.ask(&text),
            "email" => self.draft_email(),
            "show" => {
                let mut state = self.state.lock().unwrap();
                let count = state.answers.len();
                state.shown = (value.as_u64().unwrap_or(0) as usize).min(count.saturating_sub(1));
            }
            "auto" => {
                self.state.lock().unwrap().auto_answer = flag;
                self.edit(|s| s.meeting_auto_answer_off = !flag);
                self.note(&format!("auto answer {}", if flag { "on" } else { "off" }));
            }
            "mute" => {
                self.state.lock().unwrap().mic_muted = flag;
                if let Some(feed) = self.sound.lock().unwrap().as_ref().and_then(|s| s.mic.clone()) {
                    feed.set_muted(flag);
                }
                self.note(&format!("microphone {} in the notes", if flag { "muted" } else { "on" }));
            }
            "ai" => {
                let provider = Provider::from_name(&text);
                if !text.is_empty() && provider != Provider::Local && !provider.has_key() {
                    return Err(format!("{} needs its API key first: add it in Murmur's Settings → Commands & AI.", provider.company()));
                }
                self.edit(|s| s.meeting_ai = text.clone());
                self.note(&format!("answers and notes with {}", self.ai_name()));
            }
            "speech" => {
                if (text == "sarvam" || text == "openai") && !cloud::has_key(&text) {
                    return Err(format!("{} needs its API key first: add it in Murmur's Settings → Commands & AI.",
                                       if text == "sarvam" { "Sarvam" } else { "OpenAI" }));
                }
                self.edit(|s| s.meeting_speech = text.clone());
            }
            "instructions" => self.edit(|s| s.meeting_instructions = text.clone()),
            "about" => self.state.lock().unwrap().about = text,
            "offers" => self.edit(|s| s.meeting_offer_off = !flag),
            "stayWhenQuiet" => self.edit(|s| s.meeting_stay_when_quiet = flag),
            // {voice, name, remember}: a voice named by you (an empty name: "not them").
            "nameVoice" => {
                let voice = value["voice"].as_u64().ok_or("which voice?")? as u32;
                return self.name_voice(voice, value["name"].as_str().unwrap_or_default(), value["remember"].as_bool().unwrap_or(false));
            }
            // {from, into}: two voices that are one person.
            "mergeVoices" => {
                let (Some(from), Some(into)) = (value["from"].as_u64(), value["into"].as_u64()) else { return Err("which voices?".into()) };
                self.merge_voices(from as u32, into as u32);
            }
            // A saved voice forgotten, or renamed ({id, name}), from Meetings › People.
            "forgetPerson" => {
                self.library.lock().unwrap().forget(value.as_u64().ok_or("which person?")?);
                let _ = self.app.emit("meeting-people", ());
            }
            "renamePerson" => {
                self.library.lock().unwrap().rename(value["id"].as_u64().ok_or("which person?")?, value["name"].as_str().unwrap_or_default());
                let _ = self.app.emit("meeting-people", ());
            }
            "opacity" => {
                let opacity = value.as_f64().unwrap_or(1.0).clamp(0.35, 1.0);
                self.edit(|s| s.meeting_opacity = Some(opacity));
            }
            "solidOnHover" => self.edit(|s| s.meeting_solid_on_hover_off = !flag),
            "textSize" => {
                let size = value.as_f64().unwrap_or(19.0).clamp(15.0, 30.0);
                self.edit(|s| s.meeting_text_size = Some(size));
            }
            "layout" => {
                let layout = if text == "strip" { "strip" } else { "card" }.to_string();
                self.edit(|s| s.meeting_layout = layout.clone());
                self.state.lock().unwrap().collapsed = false;
                place_panel(&self.app, &layout, false);
            }
            "collapse" | "expand" => {
                let collapsed = action == "collapse";
                {
                    let mut state = self.state.lock().unwrap();
                    state.collapsed = collapsed;
                    if !collapsed {
                        state.unread = false;
                    }
                }
                place_panel(&self.app, &self.settings().meeting_layout, collapsed);
            }
            "close" => {
                hide_panel(&self.app);
                let mut state = self.state.lock().unwrap();
                if !state.running && !state.finishing {
                    let documents = std::mem::take(&mut state.documents);
                    *state = State::new();
                    state.documents = documents;
                }
            }
            "dismissProblem" => self.state.lock().unwrap().problem = None,
            "addDocuments" => {
                let meeting = self.clone();
                use tauri_plugin_dialog::DialogExt;
                self.app.dialog().file().set_title("Documents for this meeting: an agenda, a spec, notes")
                    .add_filter("Documents", &["txt", "md", "markdown", "docx", "html", "htm", "rtf", "csv", "json"])
                    .pick_files(move |files| {
                        for file in files.unwrap_or_default() {
                            let Ok(path) = file.into_path() else { continue };
                            meeting.add_document(path);
                        }
                        meeting.changed();
                    });
                return Ok(());
            }
            "removeDocument" => {
                let index = value.as_u64().unwrap_or(u64::MAX) as usize;
                let mut state = self.state.lock().unwrap();
                if index < state.documents.len() {
                    state.documents.remove(index);
                }
            }
            "offerAccept" => {
                let offered = self.offered.lock().unwrap().0.clone();
                let found = detect::meeting().filter(|(name, _)| Some(name) == offered.as_ref());
                self.start(found.or_else(|| offered.map(|name| (name, String::new()))), true);
            }
            "offerDismiss" => {
                hide_offer(&self.app);
                let name = self.offered.lock().unwrap().0.clone().unwrap_or_default();
                self.note(&format!("notes not taken for {name}"));
            }
            "openFolder" => {
                use tauri_plugin_opener::OpenerExt;
                let folder = Meeting::folder().ok_or("no Documents folder")?;
                std::fs::create_dir_all(&folder).map_err(|error| error.to_string())?;
                self.app.opener().open_path(folder.display().to_string(), None::<&str>).map_err(|error| error.to_string())?;
                return Ok(());
            }
            "openSaved" => {
                if let Some(saved) = self.state.lock().unwrap().saved.clone() {
                    use tauri_plugin_opener::OpenerExt;
                    let _ = self.app.opener().reveal_item_in_dir(saved);
                }
            }
            "mail" => {
                use tauri_plugin_opener::OpenerExt;
                let encode = |text: &str| text.bytes().map(|b| match b {
                    b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
                    _ => format!("%{b:02X}"),
                }).collect::<String>();
                let subject = value["subject"].as_str().unwrap_or_default();
                let body = value["body"].as_str().unwrap_or_default();
                let url = format!("mailto:?subject={}&body={}", encode(subject), encode(body));
                self.app.opener().open_url(url, None::<&str>).map_err(|error| error.to_string())?;
                return Ok(());
            }
            other => return Err(format!("no meeting action called {other}")),
        }
        self.changed();
        Ok(())
    }

    fn add_document(&self, path: PathBuf) {
        let mut state = self.state.lock().unwrap();
        if state.documents.len() >= 5 || state.documents.iter().any(|d| d.path == path.display().to_string()) {
            return;
        }
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        match documents::text(&path) {
            Ok(text) => state.documents.push(Document { name, path: path.display().to_string(), text }),
            Err(error) => state.problem = Some(format!("Couldn't read {name}: {error}.")),
        }
    }

    pub fn show_panel(&self) {
        let collapsed = {
            let mut state = self.state.lock().unwrap();
            state.unread = false;
            state.collapsed
        };
        show_panel(&self.app, &self.settings().meeting_layout, collapsed);
    }
}

/// (year, month, day, hour, minute) for seconds since 1970 (already in local time).
fn civil(seconds: f64) -> (i64, u32, u32, u32, u32) {
    let total = seconds.floor() as i64;
    let days = total.div_euclid(86_400);
    let rest = total.rem_euclid(86_400);
    // Howard Hinnant's days-to-civil.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    (year, month, day, (rest / 3_600) as u32, ((rest % 3_600) / 60) as u32)
}

// MARK: Windows (on the window thread)

/// The panel's size and place: a card on the right of the screen, beside the call; a wide strip at the top, near the
/// camera; or folded into a small pill at the top.
fn frame(layout: &str, collapsed: bool, area: (i32, i32, i32, i32), scale: f64) -> (f64, f64, i32, i32) {
    let (x, y, width, height) = area;
    let logical = |v: i32| v as f64 / scale;
    let (w, h) = if collapsed {
        (300.0, 52.0)
    } else if layout == "strip" {
        ((logical(width) - 120.0).clamp(640.0, 1100.0), 300.0)
    } else {
        (460.0, (logical(height) - 48.0).clamp(480.0, 860.0))
    };
    let (pw, ph) = ((w * scale) as i32, (h * scale) as i32);
    let (px, py) = if collapsed || layout == "strip" {
        (x + (width - pw) / 2, y + (12.0 * scale) as i32)
    } else {
        (x + width - pw - (16.0 * scale) as i32, y + (height - ph) / 2)
    };
    (w, h, px, py)
}

fn show_panel(app: &AppHandle, layout: &str, collapsed: bool) {
    let main = app.clone();
    let layout = layout.to_string();
    let _ = app.run_on_main_thread(move || {
        let window = match main.get_webview_window(PANEL) {
            Some(window) => window,
            None => {
                let built = WebviewWindowBuilder::new(&main, PANEL, WebviewUrl::App("meeting.html".into()))
                    .title("Murmur · Meeting notes")
                    .inner_size(460.0, 720.0)
                    .min_inner_size(280.0, 48.0)
                    .decorations(false)
                    .transparent(true)
                    .shadow(true)
                    .resizable(true)
                    .always_on_top(true)
                    .skip_taskbar(true)
                    .visible(false)
                    .build();
                match built {
                    Ok(window) => window,
                    Err(error) => {
                        eprintln!("murmur-shell: no meeting panel: {error}");
                        return;
                    }
                }
            }
        };
        place(&window, &layout, collapsed);
        crate::privacy::apply_all(&main);
        let _ = window.show();
    });
}

fn place_panel(app: &AppHandle, layout: &str, collapsed: bool) {
    let main = app.clone();
    let layout = layout.to_string();
    let _ = app.run_on_main_thread(move || {
        if let Some(window) = main.get_webview_window(PANEL) {
            place(&window, &layout, collapsed);
        }
    });
}

fn place(window: &tauri::WebviewWindow, layout: &str, collapsed: bool) {
    let monitor = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let area = monitor.work_area();
    let scale = monitor.scale_factor();
    let (w, h, x, y) = frame(layout, collapsed, (area.position.x, area.position.y, area.size.width as i32, area.size.height as i32), scale);
    let _ = window.set_size(tauri::LogicalSize::new(w, h));
    let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
}

fn hide_panel(app: &AppHandle) {
    let main = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(window) = main.get_webview_window(PANEL) {
            let _ = window.hide();
        }
    });
}

/// "Take notes of this meeting?" near the bottom right, without taking the focus from the call.
fn show_offer(app: &AppHandle, name: &str, _program: &str) {
    let main = app.clone();
    let url = format!("meeting.html?offer={}", name.replace(' ', "%20"));
    let _ = app.run_on_main_thread(move || {
        if let Some(window) = main.get_webview_window(OFFER) {
            let _ = window.close();
        }
        let built = WebviewWindowBuilder::new(&main, OFFER, WebviewUrl::App(url.into()))
            .title("Murmur")
            .inner_size(400.0, 132.0)
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .focused(false)
            .visible(false)
            .build();
        let Ok(window) = built else { return };
        if let Some(monitor) = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten()) {
            let area = monitor.work_area();
            let scale = monitor.scale_factor();
            let (w, h) = ((400.0 * scale) as i32, (132.0 * scale) as i32);
            let _ = window.set_position(tauri::PhysicalPosition::new(
                area.position.x + area.size.width as i32 - w - (16.0 * scale) as i32,
                area.position.y + area.size.height as i32 - h - (16.0 * scale) as i32));
        }
        crate::privacy::apply_all(&main);
        show_without_focus(&window);
        // Gone after a minute if it isn't answered.
        let later = main.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(60));
            hide_offer(&later);
        });
    });
}

fn hide_offer(app: &AppHandle) {
    let main = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(window) = main.get_webview_window(OFFER) {
            let _ = window.close();
        }
    });
}

#[cfg(windows)]
fn show_without_focus(window: &tauri::WebviewWindow) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{ShowWindow, SW_SHOWNOACTIVATE};
    match window.hwnd() {
        Ok(hwnd) => unsafe {
            ShowWindow(hwnd.0 as _, SW_SHOWNOACTIVATE);
        },
        Err(_) => {
            let _ = window.show();
        }
    }
}

#[cfg(not(windows))]
fn show_without_focus(window: &tauri::WebviewWindow) {
    let _ = window.show();
}

/// Ctrl+Alt+Enter while notes run (registered from the window thread, as Murmur's other shortcut is).
fn register_hotkey(app: &AppHandle, on: bool) {
    let main = app.clone();
    let _ = app.run_on_main_thread(move || {
        use tauri_plugin_global_shortcut::GlobalShortcutExt;
        let shortcuts = main.global_shortcut();
        let result = if on { shortcuts.register(HOTKEY) } else { shortcuts.unregister(HOTKEY) };
        if let Err(error) = result {
            if on {
                eprintln!("murmur-shell: {HOTKEY_TEXT} is taken by another app: {error}");
            }
        }
    });
}

/// Whether a global shortcut that was pressed is meeting notes' Answer now.
pub fn is_hotkey(shortcut: &tauri_plugin_global_shortcut::Shortcut) -> bool {
    static OURS: std::sync::OnceLock<Option<tauri_plugin_global_shortcut::Shortcut>> = std::sync::OnceLock::new();
    OURS.get_or_init(|| HOTKEY.parse().ok()).as_ref() == Some(shortcut)
}

// MARK: Saved meetings (the Meetings page)

/// The meetings saved in Documents › Murmur Meetings, newest first: their file, title, when, app, notes and lines.
pub fn saved() -> Vec<Value> {
    let Some(folder) = Meeting::folder() else { return vec![] };
    let Ok(entries) = std::fs::read_dir(&folder) else { return vec![] };
    let mut meetings: Vec<(f64, Value)> = entries.flatten().filter_map(|entry| {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()).map(|e| e.to_lowercase()) != Some("md".into()) {
            return None;
        }
        let text = std::fs::read_to_string(&path).ok()?;
        let modified = entry.metadata().ok()?.modified().ok()?.duration_since(UNIX_EPOCH).ok()?.as_secs_f64();
        let stem = path.file_stem()?.to_string_lossy().into_owned();
        // "2026-11-18 01.30 Zoom": the date and the app from the name.
        let mut parts = stem.splitn(3, ' ');
        let (date, time, app) = (parts.next().unwrap_or_default(), parts.next().unwrap_or_default(), parts.next());
        let notes = text.split("\n## Transcript").next().unwrap_or(&text).trim().to_string();
        let title = notes.lines().find(|l| l.starts_with("# ")).map(|l| l[2..].trim().to_string())
            .filter(|t| !t.is_empty() && t != "Meeting notes")
            .unwrap_or_else(|| app.map(|a| format!("{a} meeting")).unwrap_or("Meeting".into()));
        let gist = notes.lines().map(str::trim).find(|l| !l.is_empty() && !l.starts_with('#'))
            .map(|l| l.trim_start_matches(['-', '*', ' ']).to_string());
        let lines = text.split("\n## Transcript").nth(1).map_or(0, |t| t.lines().filter(|l| l.starts_with("**")).count());
        Some((modified, json!({
            "path": path.display().to_string(), "title": title, "date": date, "time": time.replace('.', ":"),
            "app": app, "notes": notes, "gist": gist, "lines": lines, "text": text,
        })))
    }).collect();
    meetings.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    meetings.into_iter().map(|(_, value)| value).collect()
}

// MARK: What the AI is told

pub const ANSWER_SYSTEM: &str = "You help the user during a live meeting or call. In the transcript, \"Them\" is the other \
people and \"You\" is the user (when the other side's voices are told apart, each is labelled by name or \"Speaker N\" \
instead of \"Them\"); it's speech-to-text, so expect misheard words. The user glances at your answer and says it \
out loud, live, so it must be quick to scan and natural to say, and complete, precise and correct. Reply in exactly this \
shape, plain text, no preamble; use **bold** only for the one or two key words in a line:
ANSWER: the direct answer in one short sentence the user can say first, in the first person.
POINTS:
- the rest of the answer, two to six bullets in the order you'd say them: the reasoning or how it works, the specifics \
(facts, numbers, names, steps), and the trade-offs or caveats that matter. Each bullet is one short spoken sentence (about \
8 to 20 words) that starts with its key idea. Cover every part of the question (if they asked two things, answer both, in \
the order asked), and get every fact, number, name, definition and technical detail exactly right. Nothing generic, no \
filler, no stock openers (\"Great question\", \"Certainly\"). A quick factual question may need only one or two points.
EXAMPLE: one short concrete example, only when it makes the answer clearer.
CODE: only when the question asks for code (write or fix a function, a query, a command) or a problem on the screen needs \
it: the complete code in one fenced block with its language (```python), working as written, with short comments only \
where they help. Then the POINTS walk through the approach out loud: the idea, why it works, and its time and space cost, \
not the code line by line.
ALSO:
- two or three short bullets: a point to add, a follow-up, or a question back (for code: an edge case, another approach, or \
how to test it).
Use the meeting's context and documents when they're given, what was said, and general knowledge. If the answer depends \
on facts you don't have (numbers, dates, the user's own experience), say in a point what to check or fill in rather than \
inventing it. When a picture or the text of the meeting's screen comes with the question, answer from what it shows (read \
charts' numbers and trends, slides' points) and say which part you mean. Follow the user's instructions when they're given.";

const FOLLOW_UP_SYSTEM: &str = "You help the user during a live meeting or call. In the transcript, \"Them\" is the other \
people and \"You\" is the user (when the other side's voices are told apart, each is labelled by name or \"Speaker N\" \
instead of \"Them\"); it's speech-to-text, so expect misheard words. Suggest questions the user could ask now: \
sharp, specific to what was actually said, the kind a thoughtful person would ask to clarify, go deeper or move things \
forward. Reply in exactly this shape, plain text, **bold** only for a key word:
ANSWER: one short sentence on what's worth digging into right now.
ALSO:
- three to five questions, each short and ready to ask out loud as written.
Use the meeting's context when given. No generic questions that would fit any meeting.";

const RECAP_SYSTEM: &str = "You help the user during a live meeting or call. In the transcript, \"Them\" is the other \
people and \"You\" is the user (when the other side's voices are told apart, each is labelled by name or \"Speaker N\" \
instead of \"Them\"); it's speech-to-text, so expect misheard words. Recap the meeting so far for someone who \
lost the thread for a few minutes. Reply in exactly this shape, plain text, **bold** only for key words:
ANSWER: what the meeting is about, in one short sentence.
POINTS:
- what's been covered, in order, one short bullet per topic, with the specifics (names, numbers, decisions), ending with \
where the conversation is right now.
ALSO:
- decisions, commitments and open questions so far, one short bullet each.
Skip small talk and logistics. No generic lines.";

const EMAIL_SYSTEM: &str = "Write the follow-up email the user sends after this meeting, from them to the people they met. \
Warm, short and specific, in their voice: thank them in one line, then what was agreed, who's doing what and by when (only \
what was actually said), and the next step. Plain text, short paragraphs or a few bullets, no placeholders except [Name] \
for a greeting you can't know. Reply in exactly this shape:
Subject: a specific subject line
(blank line)
the email";

const DECIDE_SYSTEM: &str = "You watch a live meeting transcript (speech-to-text, so expect misheard words and missing \
punctuation). \"Them\" is the other people and \"You\" is the user (when the other side's voices are told apart, each is labelled by name or \"Speaker N\" \
instead of \"Them\"). Decide one thing about what the other side said since \
the last answer:
\"answer\": they asked the user something, or asked them to explain, describe, show or do something (however it's phrased: \
\"tell me about…\", \"I'd love to hear how you…\", \"walk us through…\", \"what's your take\"), and they've finished asking.
\"wait\": they're plainly still in the middle of asking (the sentence breaks off, or they're listing parts).
\"no\": nothing for the user to answer: a statement, small talk, or talking to someone else.";

const NOTES_SYSTEM: &str = "You are an excellent note-taker sitting in on the user's meeting. In the transcript, \"Them\" is \
the other people and \"You\" is the user (when the other side's voices are told apart, each is labelled by name or \"Speaker N\" \
instead of \"Them\"); it's speech-to-text, so fix obvious mishearings from context and ignore fragments \
that make no sense.
Note only what someone would want to look back at: what was decided, who will do what and by when, the facts, numbers, \
names, dates and terms that came up, problems raised and how they were resolved, and questions left open. Leave out small \
talk, greetings, audio and screen-sharing logistics, filler, repeats, and anything said only in passing. Never write \
generic lines like \"The team discussed the project\" or \"They talked about next steps\": every bullet states the actual \
point, in a few plain words, with the specifics.
Shape the notes to what the meeting actually is:
- an interview: \"## Questions asked\", each question with the gist of how the user answered and anything the interviewer \
reacted to; then \"## About the role and team\" for what they told the user; then \"## Follow-ups\".
- a working meeting or stand-up: \"## Decisions\", \"## Action items\" (\"- [ ] Who: what, by when if said\"), then a \"##\" \
section per real topic, named after it, and \"## Open questions\".
- a call with a customer or partner: \"## Their needs\", \"## Concerns\", \"## What we offered\", \"## Next steps\".
Leave out any section with nothing in it. Use the meeting's context when it's given. Short, specific bullets. Reply with \
the notes only, in Markdown.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_for_file_names() {
        // 2026-11-18 01:30 UTC.
        assert_eq!(civil(1_794_965_400.0), (2026, 11, 18, 1, 30));
        assert_eq!(civil(0.0), (1970, 1, 1, 0, 0));
    }

    #[test]
    fn the_panel_fits_the_screen() {
        let area = (0, 0, 1920, 1040);
        let (w, h, x, y) = frame("card", false, area, 1.0);
        assert_eq!((w, h), (460.0, 860.0));
        assert!(x + w as i32 <= 1920 && y >= 0 && y + h as i32 <= 1040);
        let (w, _, x, _) = frame("strip", false, area, 1.0);
        assert_eq!(w, 1100.0);
        assert_eq!(x, (1920 - 1100) / 2);
        let (w, h, ..) = frame("card", true, area, 1.5);
        assert_eq!((w, h), (300.0, 52.0));
    }

    #[test]
    fn a_new_answer_and_one_written_again() {
        let mut state = State::new();
        assert_eq!(state.begin_answer("Q1", Kind::Answer), 0);
        assert_eq!(state.begin_answer("Q2", Kind::Recap), 1);
        state.answers[1].text = "old".into();
        assert_eq!(state.restart_last("Q2 and more"), 1);
        assert_eq!(state.answers[1].question, "Q2 and more");
        assert!(state.answers[1].text.is_empty());
        state.replace_next = true;
        assert!(state.consume_replace());
        assert!(!state.consume_replace());
    }
}
