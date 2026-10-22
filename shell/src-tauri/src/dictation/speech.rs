//! Speech to text on this computer, through sherpa-onnx (ONNX Runtime, on the processor), with the models the Mac app
//! has: NVIDIA's Parakeet TDT 0.6B for English (v2) and Multilingual (v3), and Oriserve's Whisper-Hindi2Hinglish-Apex
//! for Hinglish (Whisper large-v3-turbo fine-tuned on Indian Hindi, written in English letters; converted to sherpa-onnx's
//! Whisper format by scripts/hinglish/). `SpeechModelFiles` in the engine downloads them (`murmur-engine
//! download-speech-model`).

use sherpa_onnx::{OfflineRecognizer, OfflineRecognizerConfig, OfflineTransducerModelConfig, OfflineWhisperModelConfig};
use std::path::{Path, PathBuf};
use std::time::Instant;

/// The two models, as the engine and the settings name them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Model {
    English,
    Hinglish,
    Multilingual,
}

impl Model {
    pub const ALL: [Model; 3] = [Model::English, Model::Hinglish, Model::Multilingual];

    pub fn from_name(name: &str) -> Model {
        match name {
            "multilingual" => Model::Multilingual,
            "hinglish" => Model::Hinglish,
            _ => Model::English,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Model::English => "english",
            Model::Hinglish => "hinglish",
            Model::Multilingual => "multilingual",
        }
    }

    /// Its folder in Murmur's Speech Models (`SpeechModelFiles.folderName`).
    pub fn folder_name(self) -> &'static str {
        match self {
            Model::English => "parakeet-tdt-0.6b-v2-int8",
            Model::Hinglish => "whisper-hinglish-apex-int8",
            Model::Multilingual => "parakeet-tdt-0.6b-v3-int8",
        }
    }

    /// What it's called in Settings.
    pub fn title(self) -> &'static str {
        match self {
            Model::English => "English (most accurate)",
            Model::Hinglish => "Hinglish (Hindi in English letters)",
            Model::Multilingual => "Other languages (25 European)",
        }
    }

    /// Its files (the engine names a file only once it's checked).
    fn files(self) -> &'static [&'static str] {
        match self {
            Model::English | Model::Multilingual => &["tokens.txt", "decoder.int8.onnx", "joiner.int8.onnx", "encoder.int8.onnx"],
            Model::Hinglish => &["tokens.txt", "decoder.int8.onnx", "encoder.int8.onnx"],
        }
    }

    /// Whether soft words get their own lift before it hears them (level.rs): Parakeet's dictations come out better
    /// for it; Whisper evens loudness out itself, and a lifted soft last word can go missing.
    pub fn lifts_words(self) -> bool {
        self != Model::Hinglish
    }

    /// The longest stretch one pass takes: Whisper hears 30 seconds at a time; Parakeet takes a dictation whole.
    fn longest(self) -> Option<f32> {
        match self {
            Model::Hinglish => Some(28.0),
            Model::English | Model::Multilingual => None,
        }
    }
}

/// Whether all of the model's files are in `folder`.
pub fn installed(model: Model, folder: &Path) -> bool {
    model.files().iter().all(|name| folder.join(name).is_file())
}

/// Deletes the model's files from `folder`, so the next download fetches (and checks) them all again. The engine
/// trusts a file it once checked, so a file left from an earlier build of a model stays until it's taken away.
pub fn remove(model: Model, folder: &Path) {
    for name in model.files() {
        let _ = std::fs::remove_file(folder.join(name));
    }
}


pub struct Recognizer {
    inner: OfflineRecognizer,
    model: Model,
}

impl Recognizer {
    /// Loads the model from `folder` (a few seconds: the encoder is 650 MB), on as many threads as help.
    pub fn load(model: Model, folder: &Path) -> Result<Recognizer, String> {
        if !installed(model, folder) {
            return Err(format!("the speech model isn't in {}", folder.display()));
        }
        let path = |name: &str| -> Option<String> { Some(folder.join(name).to_string_lossy().into_owned()) };
        let mut config = OfflineRecognizerConfig::default();
        match model {
            Model::English | Model::Multilingual => {
                config.model_config.transducer = OfflineTransducerModelConfig {
                    encoder: path("encoder.int8.onnx"),
                    decoder: path("decoder.int8.onnx"),
                    joiner: path("joiner.int8.onnx"),
                };
                config.model_config.model_type = Some("nemo_transducer".into());
            }
            Model::Hinglish => {
                // As the Mac app runs Apex (WhisperKit, language "en"): Hindi and English, in English letters.
                config.model_config.whisper = OfflineWhisperModelConfig {
                    encoder: path("encoder.int8.onnx"),
                    decoder: path("decoder.int8.onnx"),
                    language: Some(HINGLISH_LANGUAGE.into()),
                    task: Some("transcribe".into()),
                    tail_paddings: -1,
                    ..Default::default()
                };
            }
        }
        config.model_config.tokens = path("tokens.txt");
        config.model_config.num_threads = threads(model);
        config.decoding_method = Some("greedy_search".into());
        let inner = OfflineRecognizer::create(&config).ok_or("sherpa-onnx couldn't load the speech model")?;
        Ok(Recognizer { inner, model })
    }

    /// The words in `samples` (mono, any sample rate: sherpa-onnx resamples to the model's 16 kHz). Longer than one
    /// pass takes, it's cut where it's quietest and the pieces' words are joined.
    pub fn transcribe(&self, samples: &[f32], sample_rate: u32) -> String {
        let pieces = match self.model.longest() {
            Some(seconds) => pieces(samples, sample_rate, seconds),
            None => vec![samples],
        };
        let texts: Vec<String> = pieces.into_iter().map(|piece| {
            let stream = self.inner.create_stream();
            stream.accept_waveform(sample_rate as i32, piece);
            self.inner.decode(&stream);
            stream.get_result().map(|result| result.text).unwrap_or_default()
        }).collect();
        texts.iter().map(|text| text.trim()).filter(|text| !text.is_empty()).collect::<Vec<_>>().join(" ")
    }

    /// What's typed for `samples`: the words, tidied, or nothing when the model only made something up. Whisper writes
    /// "nan" for silence or a breath (Apex does; other Whispers write "Thank you."), which isn't a dictation.
    pub fn words(&self, samples: &[f32], sample_rate: u32) -> String {
        let text = tidy(&self.transcribe(samples, sample_rate));
        let bare: String = text.chars().filter(|c| c.is_alphanumeric()).collect::<String>().to_lowercase();
        if self.model == Model::Hinglish && bare == "nan" {
            return String::new();
        }
        text
    }

    /// One second of silence through the model, so the first dictation doesn't pay for ONNX Runtime's first run.
    /// Whisper isn't warmed up: a second of silence costs it as long as a dictation (the encoder always hears its full
    /// window), all on the processor, for nothing.
    pub fn warm_up(&self) -> f64 {
        if self.model == Model::Hinglish {
            return 0.0;
        }
        let started = Instant::now();
        let _ = self.transcribe(&vec![0.0; 16_000], 16_000);
        started.elapsed().as_secs_f64()
    }
}

/// The language Whisper is told: English, which has Apex write Hindi in English letters as the Mac app's does.
const HINGLISH_LANGUAGE: &str = "en";

/// `samples` in pieces of at most `seconds`, each cut at the quietest quarter second of its last five seconds (a pause
/// between words, rather than through one).
fn pieces(samples: &[f32], rate: u32, seconds: f32) -> Vec<&[f32]> {
    let longest = (seconds * rate as f32) as usize;
    let window = (rate as usize / 4).max(1);
    let search = (5 * rate as usize).min(longest / 2);
    let mut out = Vec::new();
    let mut start = 0;
    while samples.len() - start > longest {
        let end = start + longest;
        let mut cut = end;
        let mut quietest = f32::MAX;
        let mut at = end - search;
        while at + window <= end {
            let energy: f32 = samples[at..at + window].iter().map(|s| s * s).sum();
            if energy < quietest {
                quietest = energy;
                cut = at + window / 2;
            }
            at += window / 2;
        }
        out.push(&samples[start..cut]);
        start = cut;
    }
    out.push(&samples[start..]);
    out
}

/// Threads for the model: the processor's cores, leaving one for everything else, at most 8 (past that it barely helps).
/// Threads for the model: all but one core for Parakeet (a dictation takes a moment); half of them for Whisper, which
/// works several seconds at a time and, given them all, left Windows too little to keep Murmur's windows answering
/// ("not responding" while Hinglish warmed up).
fn threads(model: Model) -> i32 {
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    match model {
        Model::Hinglish => (cores / 2).clamp(1, 8) as i32,
        Model::English | Model::Multilingual => cores.saturating_sub(1).clamp(1, 8) as i32,
    }
}

/// Murmur's Speech Models folder for `model` (`SpeechModelFiles.installed`): %LOCALAPPDATA%\Murmur\Speech Models on
/// Windows, $XDG_DATA_HOME/murmur/Speech Models (~/.local/share/murmur/…) on Linux.
pub fn default_folder(model: Model) -> Option<PathBuf> {
    let base = if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA").map(|local| PathBuf::from(local).join("Murmur"))
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
            .map(|data| data.join("murmur"))
    };
    base.map(|base| base.join("Speech Models").join(model.folder_name()))
}

/// What Parakeet writes, tidied for typing: single spaces, no leading or trailing space.
pub fn tidy(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tidies_spaces() {
        assert_eq!(tidy("  Hello   there.\n "), "Hello there.");
        assert_eq!(tidy(""), "");
    }

    #[test]
    fn names_match_the_engine() {
        assert_eq!(Model::from_name("multilingual").folder_name(), "parakeet-tdt-0.6b-v3-int8");
        assert_eq!(Model::from_name("hinglish").folder_name(), "whisper-hinglish-apex-int8");
        assert_eq!(Model::from_name("anything else"), Model::English);
        for model in Model::ALL {
            assert_eq!(Model::from_name(model.name()), model);
        }
    }

    #[test]
    fn only_hinglish_skips_the_word_lift() {
        assert!(Model::English.lifts_words() && Model::Multilingual.lifts_words());
        assert!(!Model::Hinglish.lifts_words());
    }

    #[test]
    fn long_recordings_are_cut_in_a_pause() {
        let rate = 16_000;
        // 40 s of "speech" with a silent half second at 25 s: cut there, not at 28 s.
        let mut samples = vec![0.3f32; 40 * rate];
        samples[25 * rate..25 * rate + rate / 2].fill(0.0);
        let parts = pieces(&samples, rate as u32, 28.0);
        assert_eq!(parts.len(), 2);
        let first = parts[0].len() as f32 / rate as f32;
        assert!((25.0..25.6).contains(&first), "{first}");
        assert_eq!(parts.iter().map(|p| p.len()).sum::<usize>(), samples.len());
        // Short ones stay whole.
        assert_eq!(pieces(&samples[..10 * rate], rate as u32, 28.0).len(), 1);
    }

    /// With MURMUR_TEST_SPEECH_MODEL (a folder with the English model) and MURMUR_TEST_WAV (16-bit mono speech): the
    /// whole path a dictation takes, level then Parakeet. Skipped without them.
    #[test]
    fn transcribes_a_recording() {
        let (Some(folder), Some(wav)) = (std::env::var_os("MURMUR_TEST_SPEECH_MODEL"), std::env::var_os("MURMUR_TEST_WAV"))
        else {
            return;
        };
        let (samples, rate) = read_wav(Path::new(&wav));
        let model = Model::from_name(&std::env::var("MURMUR_TEST_SPEECH_KIND").unwrap_or_default());
        println!("loading the {} model", model.name());
        let started = std::time::Instant::now();
        let recognizer = Recognizer::load(model, Path::new(&folder)).expect("load");
        println!("loaded in {:.1} s", started.elapsed().as_secs_f64());
        println!("warm-up {:.2} s", recognizer.warm_up());
        let leveled = crate::dictation::level::normalize_with(&samples, rate as f32, 40.0, model.lifts_words());
        let started = Instant::now();
        let text = recognizer.words(&leveled.samples, rate);
        println!("{:.1} s of audio in {:.2} s (gain {:.1} dB): {text}", samples.len() as f32 / rate as f32,
                 started.elapsed().as_secs_f64(), leveled.gain_db);
        let expected = std::env::var("MURMUR_TEST_EXPECT").unwrap_or_default().to_lowercase();
        if !expected.is_empty() {
            assert!(text.to_lowercase().contains(&expected), "{text}");
        }
    }

    /// 16-bit PCM WAV, any channel count (averaged to mono).
    fn read_wav(path: &Path) -> (Vec<f32>, u32) {
        let data = std::fs::read(path).expect("wav");
        let u16le = |at: usize| u16::from_le_bytes([data[at], data[at + 1]]);
        let u32le = |at: usize| u32::from_le_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]);
        let (mut at, mut channels, mut rate, mut samples) = (12, 1usize, 16_000u32, Vec::new());
        while at + 8 <= data.len() {
            let (id, size) = (&data[at..at + 4], u32le(at + 4) as usize);
            if id == b"fmt " {
                channels = u16le(at + 10) as usize;
                rate = u32le(at + 12);
            } else if id == b"data" {
                let body = &data[at + 8..(at + 8 + size).min(data.len())];
                let values: Vec<f32> =
                    body.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0).collect();
                samples = values.chunks(channels).map(|c| c.iter().sum::<f32>() / c.len() as f32).collect();
            }
            at += 8 + size + size % 2;
        }
        (samples, rate)
    }
}
