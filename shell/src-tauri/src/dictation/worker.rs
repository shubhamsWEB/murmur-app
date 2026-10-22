//! A speech model in a process of its own: Murmur.exe started again as `--speech-worker <model> <folder>`, which loads
//! the model and turns the recordings it's sent into words. The Hinglish model (Whisper, a gigabyte, on the processor)
//! runs this way. On a Surface with 8 GB, loading it closed Murmur without a word: ONNX Runtime and sherpa-onnx end
//! the process on errors they can't handle, and a windowed program can't show what they printed. Apart, whatever
//! happens there leaves Murmur running, and what the worker printed and how it ended go to speech-worker.log and
//! dictation.log.
//!
//! The protocol, on the worker's standard input and output: Murmur sends a recording as its sample rate and sample
//! count (two little-endian u32s) and the samples (little-endian f32s); the worker answers with one line, the words as
//! a JSON string. Before the first, it says "ready <seconds it took to load>" once the model is in.

use super::speech::{Model, Recognizer};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;
use std::time::Instant;

pub const ARGUMENT: &str = "--speech-worker";

/// The model where it runs: in Murmur (Parakeet, quick and small) or in a worker (Hinglish).
pub enum Engine {
    Here(Recognizer),
    Apart(Worker),
}

impl Engine {
    /// Loads `model`: the Hinglish one in a worker, whose output goes to `log`.
    pub fn load(model: Model, folder: &Path, log: &Path) -> Result<Engine, String> {
        if model == Model::Hinglish {
            Worker::start(model, folder, log).map(Engine::Apart)
        } else {
            Recognizer::load(model, folder).map(Engine::Here)
        }
    }

    pub fn warm_up(&self) -> f64 {
        match self {
            Engine::Here(recognizer) => recognizer.warm_up(),
            Engine::Apart(_) => 0.0, // Whisper isn't warmed up (speech.rs says why)
        }
    }

    /// The words in a recording; an error when the worker has stopped (with how it ended).
    pub fn words(&self, samples: &[f32], rate: u32) -> Result<String, String> {
        match self {
            Engine::Here(recognizer) => Ok(recognizer.words(samples, rate)),
            Engine::Apart(worker) => worker.words(samples, rate),
        }
    }
}

struct Pipes {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
}

pub struct Worker {
    pipes: Mutex<Option<Pipes>>,
}

impl Worker {
    /// Starts the worker and waits for the model to load (or for the worker to stop, with what it said).
    fn start(model: Model, folder: &Path, log: &Path) -> Result<Worker, String> {
        let exe = std::env::current_exe().map_err(|error| format!("can't find Murmur.exe: {error}"))?;
        let stderr = std::fs::OpenOptions::new().create(true).append(true).open(log)
            .map(Stdio::from).unwrap_or_else(|_| Stdio::null());
        let mut command = Command::new(exe);
        command.arg(ARGUMENT).arg(model.name()).arg(folder)
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(stderr);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = command.spawn().map_err(|error| format!("can't start the speech worker: {error}"))?;
        crate::helper::adopt(&child); // it ends with Murmur
        let input = child.stdin.take().ok_or("no input to the speech worker")?;
        let mut output = BufReader::new(child.stdout.take().ok_or("no output from the speech worker")?);
        let mut line = String::new();
        let _ = output.read_line(&mut line);
        if !line.starts_with("ready") {
            let status = child.wait().map(|s| ended(s.code())).unwrap_or_else(|_| "ended".into());
            return Err(format!("the speech model stopped while loading ({status}{})",
                               last_line(log).map(|l| format!(": {l}")).unwrap_or_default()));
        }
        Ok(Worker { pipes: Mutex::new(Some(Pipes { child, input, output })) })
    }

    fn words(&self, samples: &[f32], rate: u32) -> Result<String, String> {
        let mut guard = self.pipes.lock().unwrap();
        let Some(pipes) = guard.as_mut() else { return Err("the speech model stopped earlier".into()) };
        if let Some(text) = ask(&mut pipes.input, &mut pipes.output, samples, rate) {
            return Ok(text);
        }
        // It stopped: say how, and start afresh next time.
        let mut pipes = guard.take().unwrap();
        let _ = pipes.child.kill();
        let status = pipes.child.wait().map(|s| ended(s.code())).unwrap_or_else(|_| "ended".into());
        Err(format!("the speech model stopped ({status})"))
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(mut pipes) = self.pipes.lock().unwrap().take() {
            let _ = pipes.child.kill();
            let _ = pipes.child.wait();
        }
    }
}

/// One recording to the worker and its words back; None when the worker has gone.
fn ask(input: &mut impl Write, output: &mut impl BufRead, samples: &[f32], rate: u32) -> Option<String> {
    let mut message = Vec::with_capacity(8 + samples.len() * 4);
    message.extend_from_slice(&rate.to_le_bytes());
    message.extend_from_slice(&(samples.len() as u32).to_le_bytes());
    for sample in samples {
        message.extend_from_slice(&sample.to_le_bytes());
    }
    input.write_all(&message).and_then(|_| input.flush()).ok()?;
    let mut line = String::new();
    if output.read_line(&mut line).ok()? == 0 {
        return None;
    }
    serde_json::from_str::<String>(line.trim()).ok()
}

/// The worker's side: each recording from `input` through `words`, its words to `output`, until `input` ends.
fn answer(input: &mut impl Read, output: &mut impl Write, words: impl Fn(&[f32], u32) -> String) {
    loop {
        let mut header = [0u8; 8];
        if input.read_exact(&mut header).is_err() {
            return; // Murmur closed it: done
        }
        let rate = u32::from_le_bytes(header[..4].try_into().unwrap());
        let count = u32::from_le_bytes(header[4..].try_into().unwrap()) as usize;
        let mut bytes = vec![0u8; count * 4];
        if input.read_exact(&mut bytes).is_err() {
            return;
        }
        let samples: Vec<f32> = bytes.chunks_exact(4).map(|b| f32::from_le_bytes(b.try_into().unwrap())).collect();
        let line = serde_json::to_string(&words(&samples, rate)).unwrap_or_else(|_| "\"\"".into());
        if writeln!(output, "{line}").and_then(|_| output.flush()).is_err() {
            return;
        }
    }
}

/// How a process ended, as Windows numbers it: "exit code 3", "exception 0xC0000005".
fn ended(code: Option<i32>) -> String {
    match code {
        Some(code) if code < 0 || code as u32 >= 0xC000_0000 => format!("exception 0x{:08X}", code as u32),
        Some(code) => format!("exit code {code}"),
        None => "ended".into(),
    }
}

/// The last thing the worker wrote to its log (what sherpa-onnx or ONNX Runtime said before it stopped).
fn last_line(log: &Path) -> Option<String> {
    let text = std::fs::read_to_string(log).ok()?;
    text.lines().rev().map(str::trim).find(|line| !line.is_empty()).map(|line| crate::ai::cut(line, 300))
}

/// The worker itself (`Murmur.exe --speech-worker <model> <folder>`): loads the model, says it's ready, then answers
/// each recording until Murmur closes its input. Returns the process's exit code.
pub fn serve(args: &[String]) -> i32 {
    let (Some(model), Some(folder)) = (args.first(), args.get(1)) else {
        eprintln!("speech worker: give the model and its folder");
        return 2;
    };
    let model = Model::from_name(model);
    eprintln!("speech worker: loading {} from {folder} ({})", model.name(), memory());
    let started = Instant::now();
    let recognizer = match Recognizer::load(model, Path::new(folder)) {
        Ok(recognizer) => recognizer,
        Err(error) => {
            eprintln!("speech worker: {error}");
            return 3;
        }
    };
    let seconds = started.elapsed().as_secs_f64();
    eprintln!("speech worker: loaded in {seconds:.1} s ({})", memory());
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    if writeln!(out, "ready {seconds:.1}").and_then(|_| out.flush()).is_err() {
        return 0;
    }
    answer(&mut std::io::stdin().lock(), &mut out, |samples, rate| recognizer.words(samples, rate));
    0
}

/// The PC's memory as the worker starts and once it's loaded, for the log: the usual reason a big model can't load.
fn memory() -> String {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
        let mut status: MEMORYSTATUSEX = std::mem::zeroed();
        status.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
        if GlobalMemoryStatusEx(&mut status) != 0 {
            let gb = |bytes: u64| bytes as f64 / 1e9;
            return format!("{:.1} GB of {:.1} GB free, {:.1} GB of commit free", gb(status.ullAvailPhys),
                           gb(status.ullTotalPhys), gb(status.ullAvailPageFile));
        }
    }
    "memory unknown".into()
}

#[cfg(test)]
mod tests {
    #[test]
    fn recordings_there_and_words_back() {
        // Two recordings through the worker's side, in memory: what Murmur sends, what it reads back.
        let mut sent = Vec::new();
        let recording: Vec<f32> = (0..48_000).map(|i| (i as f32 / 100.0).sin()).collect();
        sent.extend_from_slice(&48_000u32.to_le_bytes());
        sent.extend_from_slice(&(recording.len() as u32).to_le_bytes());
        recording.iter().for_each(|s| sent.extend_from_slice(&s.to_le_bytes()));
        sent.extend_from_slice(&16_000u32.to_le_bytes());
        sent.extend_from_slice(&0u32.to_le_bytes());
        let mut replies = Vec::new();
        super::answer(&mut sent.as_slice(), &mut replies, |samples, rate| {
            format!("{rate} Hz, {} samples, \"quoted\"\nline", samples.len())
        });
        let mut back = std::io::Cursor::new(replies);
        let mut first = String::new();
        std::io::BufRead::read_line(&mut back, &mut first).unwrap();
        assert_eq!(serde_json::from_str::<String>(first.trim()).unwrap(), "48000 Hz, 48000 samples, \"quoted\"\nline");
        // And Murmur's side against a worker that answers.
        let mut to_worker = Vec::new();
        let mut from_worker = std::io::Cursor::new(b"\"Aap pandrah log hain\"\n".to_vec());
        assert_eq!(super::ask(&mut to_worker, &mut from_worker, &[0.5, -0.5], 16_000).as_deref(), Some("Aap pandrah log hain"));
        assert_eq!(to_worker.len(), 8 + 2 * 4);
        // A worker that's gone: None.
        let mut gone = std::io::Cursor::new(Vec::new());
        assert_eq!(super::ask(&mut Vec::new(), &mut gone, &[0.0], 16_000), None);
    }

    #[test]
    fn how_it_ended() {
        assert_eq!(super::ended(Some(3)), "exit code 3");
        assert_eq!(super::ended(Some(-1073741819)), "exception 0xC0000005");
        assert_eq!(super::ended(Some(-1073740791)), "exception 0xC0000409");
        assert_eq!(super::ended(None), "ended");
    }
}
