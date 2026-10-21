//! Your recent dictations, kept on this PC only (history.json beside the settings), newest first: the Mac's
//! DictationHistory. Home's "This week" is worked out from it (words dictated, minutes saved against typing). Turned off
//! in Settings, which also clears it. Home gets only when each one was and how many words it had, never the text.
//!
//! "Keep recordings" saves each recording and what was heard to Documents\Murmur Recordings, to compare speech models,
//! as on the Mac.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// As many as the Mac keeps.
const LIMIT: usize = 200;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Item {
    /// Milliseconds since 1970.
    pub at: u64,
    pub text: String,
    /// The app it went into (its program's name), when known.
    #[serde(default)]
    pub app: Option<String>,
    /// "dictation" or "command".
    pub kind: String,
}

pub struct History {
    file: PathBuf,
    items: Mutex<Vec<Item>>,
}

impl History {
    pub fn open(folder: &Path) -> History {
        let file = folder.join("history.json");
        let items = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        History { file, items: Mutex::new(items) }
    }

    pub fn add(&self, text: &str, app: Option<String>, kind: &str) {
        if text.trim().is_empty() {
            return;
        }
        let at = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
        let mut items = self.items.lock().unwrap();
        items.insert(0, Item { at, text: text.to_string(), app, kind: kind.to_string() });
        items.truncate(LIMIT);
        save(&self.file, &items);
    }

    pub fn clear(&self) {
        self.items.lock().unwrap().clear();
        let _ = std::fs::remove_file(&self.file);
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.items.lock().unwrap().is_empty()
    }

    /// What Home needs for "This week": when each one was, its kind and how many words it had.
    pub fn counts(&self) -> Vec<Value> {
        self.items.lock().unwrap().iter()
            .map(|item| json!({"at": item.at, "kind": item.kind, "words": item.text.split_whitespace().count()}))
            .collect()
    }
}

fn save(file: &Path, items: &[Item]) {
    let Ok(data) = serde_json::to_vec(items) else { return };
    let partial = file.with_extension("json.partial");
    if std::fs::write(&partial, data).is_ok() {
        let _ = std::fs::rename(&partial, file);
    }
}

/// Documents\Murmur Recordings (or the home folder's, where there's no Documents).
pub fn recordings_folder() -> Option<PathBuf> {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from)?;
    let documents = home.join("Documents");
    Some(if documents.is_dir() { documents } else { home }.join("Murmur Recordings"))
}

/// Saves a recording (16-bit mono WAV) and what was heard beside it, named by the time.
pub fn keep_recording(samples: &[f32], rate: u32, heard: &str, model: &str) -> Result<PathBuf, String> {
    let folder = recordings_folder().ok_or("no home folder")?;
    std::fs::create_dir_all(&folder).map_err(|error| error.to_string())?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    let wav = folder.join(format!("{stamp}-{model}.wav"));
    std::fs::write(&wav, wav_bytes(samples, rate)).map_err(|error| error.to_string())?;
    std::fs::write(wav.with_extension("txt"), heard).map_err(|error| error.to_string())?;
    Ok(wav)
}

fn wav_bytes(samples: &[f32], rate: u32) -> Vec<u8> {
    let data = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + data as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data.to_le_bytes());
    for sample in samples {
        out.extend_from_slice(&((sample.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_newest_two_hundred_and_survives_a_restart() {
        let folder = std::env::temp_dir().join(format!("murmur-history-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let history = History::open(&folder);
        history.clear();
        for i in 0..205 {
            history.add(&format!("word {i}"), None, "dictation");
        }
        history.add("   ", None, "dictation"); // nothing heard: not kept
        let again = History::open(&folder);
        let counts = again.counts();
        assert_eq!(counts.len(), LIMIT);
        assert_eq!(counts[0]["words"], 2);
        assert_eq!(again.items.lock().unwrap()[0].text, "word 204");
        again.clear();
        assert!(History::open(&folder).is_empty());
        let _ = std::fs::remove_dir_all(&folder);
    }

    #[test]
    fn a_wav_header_that_players_read() {
        let bytes = wav_bytes(&[0.0, 0.5, -1.0], 16_000);
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(bytes[24..28].try_into().unwrap()), 16_000);
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 6);
        assert_eq!(bytes.len(), 50);
    }
}
