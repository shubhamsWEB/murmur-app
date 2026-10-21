//! Speech to text on this computer: NVIDIA's Parakeet TDT 0.6B through sherpa-onnx (ONNX Runtime, on the processor),
//! the model the Mac app runs on the Neural Engine. English is v2, Multilingual v3 (`SpeechModelFiles` in the
//! engine, which downloads them: `murmur-engine download-speech-model`).

use sherpa_onnx::{OfflineRecognizer, OfflineRecognizerConfig, OfflineTransducerModelConfig};
use std::path::{Path, PathBuf};
use std::time::Instant;

/// The two models, as the engine and the settings name them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Model {
    English,
    Multilingual,
}

impl Model {
    pub fn from_name(name: &str) -> Model {
        if name == "multilingual" { Model::Multilingual } else { Model::English }
    }

    pub fn name(self) -> &'static str {
        match self {
            Model::English => "english",
            Model::Multilingual => "multilingual",
        }
    }

    /// Its folder in Murmur's Speech Models (`SpeechModelFiles.folderName`).
    pub fn folder_name(self) -> &'static str {
        match self {
            Model::English => "parakeet-tdt-0.6b-v2-int8",
            Model::Multilingual => "parakeet-tdt-0.6b-v3-int8",
        }
    }

    /// What it's called in Settings.
    pub fn title(self) -> &'static str {
        match self {
            Model::English => "English",
            Model::Multilingual => "Multilingual (25 European languages)",
        }
    }
}

const FILES: [&str; 4] = ["tokens.txt", "decoder.int8.onnx", "joiner.int8.onnx", "encoder.int8.onnx"];

/// Whether all of the model's files are in `folder` (the engine names a file only once it's checked).
pub fn installed(folder: &Path) -> bool {
    FILES.iter().all(|name| folder.join(name).is_file())
}

pub struct Recognizer {
    inner: OfflineRecognizer,
}

impl Recognizer {
    /// Loads the model from `folder` (a few seconds: the encoder is 650 MB), on as many threads as help.
    pub fn load(folder: &Path) -> Result<Recognizer, String> {
        if !installed(folder) {
            return Err(format!("the speech model isn't in {}", folder.display()));
        }
        let path = |name: &str| -> Option<String> { Some(folder.join(name).to_string_lossy().into_owned()) };
        let mut config = OfflineRecognizerConfig::default();
        config.model_config.transducer = OfflineTransducerModelConfig {
            encoder: path("encoder.int8.onnx"),
            decoder: path("decoder.int8.onnx"),
            joiner: path("joiner.int8.onnx"),
        };
        config.model_config.tokens = path("tokens.txt");
        config.model_config.model_type = Some("nemo_transducer".into());
        config.model_config.num_threads = threads();
        config.decoding_method = Some("greedy_search".into());
        let inner = OfflineRecognizer::create(&config).ok_or("sherpa-onnx couldn't load the speech model")?;
        Ok(Recognizer { inner })
    }

    /// The words in `samples` (mono, any sample rate: sherpa-onnx resamples to the model's 16 kHz).
    pub fn transcribe(&self, samples: &[f32], sample_rate: u32) -> String {
        let stream = self.inner.create_stream();
        stream.accept_waveform(sample_rate as i32, samples);
        self.inner.decode(&stream);
        stream.get_result().map(|result| result.text).unwrap_or_default()
    }

    /// One second of silence through the model, so the first dictation doesn't pay for ONNX Runtime's first run.
    pub fn warm_up(&self) -> f64 {
        let started = Instant::now();
        let _ = self.transcribe(&vec![0.0; 16_000], 16_000);
        started.elapsed().as_secs_f64()
    }
}

/// Threads for the model: the processor's cores, leaving one for everything else, at most 8 (past that it barely helps).
fn threads() -> i32 {
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    cores.saturating_sub(1).clamp(1, 8) as i32
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
        assert_eq!(Model::from_name("anything else"), Model::English);
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
        let recognizer = Recognizer::load(Path::new(&folder)).expect("load");
        println!("warm-up {:.2} s", recognizer.warm_up());
        let leveled = crate::dictation::level::normalize(&samples, rate as f32, 40.0);
        let started = Instant::now();
        let text = tidy(&recognizer.transcribe(&leveled.samples, rate));
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
