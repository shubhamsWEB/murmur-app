//! Speech to text in the cloud, with the person's own key, as the Mac's SarvamTranscriber and OpenAITranscriber:
//!
//! - Sarvam's Saaras (dictation's "Indian languages" model, and meeting notes when chosen): Hindi, Hinglish, English
//!   and 20 more Indian languages, mixed as spoken. Its REST endpoint takes up to 30 seconds a request, so a longer
//!   recording goes in pieces cut at its pauses, sent together and put back in order.
//! - OpenAI's gpt-4o-mini-transcribe (meeting notes, when chosen): a stretch of speech at a time.
//!
//! Each piece goes as a 16 kHz 16-bit mono WAV in a multipart form. Only the recording goes; nothing else does.

use crate::ai::{self, AiError};
use std::time::Duration;

pub const SARVAM_ENDPOINT: &str = "https://api.sarvam.ai/speech-to-text";
pub const OPENAI_ENDPOINT: &str = "https://api.openai.com/v1/audio/transcriptions";
pub const OPENAI_MODEL: &str = "gpt-4o-mini-transcribe";

/// The longest piece sent to Sarvam, in seconds (under its 30, with room to spare), and the earliest point in a
/// piece's last stretch where a cut may go (the quietest moment between the two).
const MAX_SECONDS: f64 = 28.0;
const EARLIEST_CUT: f64 = 20.0;

/// How Sarvam writes what you say. In English letters unless chosen otherwise: people type Hindi and Hinglish in
/// English letters (as the Hinglish model writes it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Output {
    /// Everything in English letters ("namaste, how are you"): transliteration.
    #[default]
    Latin,
    /// Each language in its own script ("नमस्ते, how are you").
    Spoken,
    /// Translated to English.
    English,
}

impl Output {
    pub const ALL: [Output; 3] = [Output::Latin, Output::Spoken, Output::English];

    pub fn from_name(name: &str) -> Output {
        match name {
            "spoken" => Output::Spoken,
            "english" => Output::English,
            _ => Output::Latin,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Output::Latin => "latin",
            Output::Spoken => "spoken",
            Output::English => "english",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Output::Latin => "In English letters (Hinglish)",
            Output::Spoken => "As spoken (each language in its own script)",
            Output::English => "Translated to English",
        }
    }

    /// The request's model and mode.
    fn fields(self) -> Vec<(&'static str, String)> {
        match self {
            Output::Spoken => vec![("model", "saaras:v4".into())],
            Output::Latin => vec![("model", "saaras:v4".into()), ("mode", "translit".into())],
            Output::English => vec![("model", "saaras:v4".into()), ("mode", "translate".into())],
        }
    }
}

/// The languages Sarvam can be told to expect ("unknown": it tells itself), as (code, name).
pub const LANGUAGES: [(&str, &str); 15] = [
    ("unknown", "Detect automatically"), ("hi-IN", "Hindi"), ("en-IN", "English (India)"), ("bn-IN", "Bengali"),
    ("ta-IN", "Tamil"), ("te-IN", "Telugu"), ("mr-IN", "Marathi"), ("gu-IN", "Gujarati"), ("kn-IN", "Kannada"),
    ("ml-IN", "Malayalam"), ("pa-IN", "Punjabi"), ("od-IN", "Odia"), ("ur-IN", "Urdu"), ("as-IN", "Assamese"),
    ("ne-IN", "Nepali"),
];

/// How Sarvam should listen: the writing and the language.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Sarvam {
    pub output: Output,
    /// A code from `LANGUAGES`; empty: "unknown".
    pub language: String,
}

pub fn has_key(account: &str) -> bool {
    ai::keys::get(account).is_some_and(|key| !key.trim().is_empty())
}

/// What's said in `samples` (mono, at `rate`), by Sarvam.
pub async fn sarvam(samples: &[f32], rate: u32, choice: &Sarvam) -> Result<String, AiError> {
    let key = ai::keys::get("sarvam").filter(|k| !k.trim().is_empty()).ok_or(AiError::NoKey("Sarvam"))?;
    let audio = to_16k(samples, rate);
    let ranges = pieces(&audio, 16_000.0);
    if ranges.is_empty() {
        return Ok(String::new());
    }
    let language = if choice.language.trim().is_empty() { "unknown".to_string() } else { choice.language.clone() };
    let mut fields = choice.output.fields();
    fields.push(("language_code", language));
    // The pieces go together, and are put back in order.
    let handles: Vec<_> = ranges.into_iter().map(|range| {
        let wav = wav(&audio[range], 16_000);
        let fields = fields.clone();
        let key = key.clone();
        tauri::async_runtime::spawn(async move {
            send(SARVAM_ENDPOINT, &[("api-subscription-key".into(), key)], &fields, wav, "Sarvam").await
                .map(|json| json["transcript"].as_str().unwrap_or_default().trim().to_string())
        })
    }).collect();
    let mut texts = Vec::new();
    for handle in handles {
        let text = handle.await.map_err(|_| AiError::Unreachable("Sarvam"))??;
        if !text.is_empty() {
            texts.push(text);
        }
    }
    Ok(texts.join(" "))
}

/// What's said in `samples` (mono, at `rate`, at most a few minutes), by OpenAI.
pub async fn openai(samples: &[f32], rate: u32) -> Result<String, AiError> {
    let key = ai::keys::get("openai").filter(|k| !k.trim().is_empty()).ok_or(AiError::NoKey("OpenAI"))?;
    let wav = wav(&to_16k(samples, rate), 16_000);
    let model = std::env::var("MURMUR_OPENAI_TRANSCRIBE_MODEL").ok().filter(|m| !m.trim().is_empty())
        .unwrap_or_else(|| OPENAI_MODEL.to_string());
    let fields = vec![("model", model), ("response_format", "json".to_string())];
    let json = send(OPENAI_ENDPOINT, &[("Authorization".into(), format!("Bearer {key}"))], &fields, wav, "OpenAI").await?;
    Ok(json["text"].as_str().unwrap_or_default().trim().to_string())
}

async fn send(url: &str, headers: &[(String, String)], fields: &[(&'static str, String)], wav: Vec<u8>,
              provider: &'static str) -> Result<serde_json::Value, AiError> {
    let boundary = format!("murmur-{:x}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos()).unwrap_or(0));
    let body = form(&boundary, fields, &wav);
    let mut request = ai::client().post(url).timeout(Duration::from_secs(45))
        .header("Content-Type", format!("multipart/form-data; boundary={boundary}"))
        .body(body);
    for (name, value) in headers {
        request = request.header(name.as_str(), value.as_str());
    }
    let response = request.send().await.map_err(|_| AiError::Unreachable(provider))?;
    let code = response.status().as_u16();
    let text = response.text().await.unwrap_or_default();
    let json: serde_json::Value = serde_json::from_str(&text).unwrap_or(serde_json::Value::Null);
    if code != 200 {
        let detail = json["error"]["message"].as_str().or_else(|| json["error"].as_str()).map(String::from)
            .unwrap_or_else(|| ai::cut(&text, 300));
        return Err(AiError::Http { provider, code, detail });
    }
    Ok(json)
}

/// Mono samples at `rate` as 16 kHz: each output sample is the average of the input it covers (a low-pass on the way
/// down, enough for speech), or a straight line between two neighbours on the way up.
pub fn to_16k(samples: &[f32], rate: u32) -> Vec<f32> {
    if rate == 16_000 || rate == 0 || samples.is_empty() {
        return samples.to_vec();
    }
    let ratio = rate as f64 / 16_000.0;
    let count = (samples.len() as f64 / ratio).floor() as usize;
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        if ratio > 1.0 {
            let start = (i as f64 * ratio) as usize;
            let end = (((i + 1) as f64 * ratio) as usize).min(samples.len()).max(start + 1);
            let sum: f32 = samples[start..end].iter().sum();
            out.push(sum / (end - start) as f32);
        } else {
            let at = i as f64 * ratio;
            let low = at.floor() as usize;
            let high = (low + 1).min(samples.len() - 1);
            let part = (at - low as f64) as f32;
            out.push(samples[low] * (1.0 - part) + samples[high] * part);
        }
    }
    out
}

/// The pieces of `samples` (at `rate`) for Sarvam, in order, covering all of it: each at most 28 seconds, cut at the
/// quietest 100 ms between 20 and 28 seconds in.
pub fn pieces(samples: &[f32], rate: f64) -> Vec<std::ops::Range<usize>> {
    let longest = (MAX_SECONDS * rate) as usize;
    let earliest = (EARLIEST_CUT * rate) as usize;
    if samples.len() <= longest {
        return if samples.is_empty() { vec![] } else { vec![0..samples.len()] };
    }
    let window = ((0.1 * rate) as usize).max(1);
    let mut out = Vec::new();
    let mut start = 0;
    while samples.len() - start > longest {
        let mut best = start + longest;
        let mut quietest = f32::MAX;
        let mut position = start + earliest;
        while position + window <= start + longest {
            let energy: f32 = samples[position..position + window].iter().map(|s| s * s).sum();
            if energy < quietest {
                quietest = energy;
                best = position + window / 2;
            }
            position += window / 2;
        }
        out.push(start..best);
        start = best;
    }
    out.push(start..samples.len());
    out
}

/// Samples (−1…1) as a 16-bit PCM mono WAV file.
pub fn wav(samples: &[f32], rate: u32) -> Vec<u8> {
    let bytes = samples.len() as u32 * 2;
    let mut data = Vec::with_capacity(44 + bytes as usize);
    data.extend_from_slice(b"RIFF");
    data.extend_from_slice(&(36 + bytes).to_le_bytes());
    data.extend_from_slice(b"WAVEfmt ");
    data.extend_from_slice(&16u32.to_le_bytes());
    data.extend_from_slice(&1u16.to_le_bytes());
    data.extend_from_slice(&1u16.to_le_bytes());
    data.extend_from_slice(&rate.to_le_bytes());
    data.extend_from_slice(&(rate * 2).to_le_bytes());
    data.extend_from_slice(&2u16.to_le_bytes());
    data.extend_from_slice(&16u16.to_le_bytes());
    data.extend_from_slice(b"data");
    data.extend_from_slice(&bytes.to_le_bytes());
    for sample in samples {
        data.extend_from_slice(&((sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16).to_le_bytes());
    }
    data
}

/// A multipart/form-data body: the text fields, then the file.
pub fn form(boundary: &str, fields: &[(&str, String)], file: &[u8]) -> Vec<u8> {
    let mut body = Vec::with_capacity(file.len() + 512);
    for (name, value) in fields {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    }
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n\
                                    Content-Type: audio/wav\r\n\r\n").as_bytes());
    body.extend_from_slice(file);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_recordings_go_whole_and_long_ones_in_pieces_at_their_pauses() {
        assert!(pieces(&[], 16_000.0).is_empty());
        assert_eq!(pieces(&vec![0.1; 16_000 * 10], 16_000.0), vec![0..160_000]);
        // 60 s of sound with a quiet stretch at 24 s and at 50 s.
        let mut samples = vec![0.3f32; 16_000 * 60];
        for s in &mut samples[16_000 * 24..16_000 * 24 + 4_000] { *s = 0.0; }
        for s in &mut samples[16_000 * 50..16_000 * 50 + 4_000] { *s = 0.0; }
        let cut = pieces(&samples, 16_000.0);
        assert_eq!(cut.first().unwrap().start, 0);
        assert_eq!(cut.last().unwrap().end, samples.len());
        for pair in cut.windows(2) { assert_eq!(pair[0].end, pair[1].start); }
        let first = cut[0].end as f64 / 16_000.0;
        assert!((24.0..24.3).contains(&first), "cut in the pause: {first}");
        assert!(cut.iter().all(|r| r.len() <= 16_000 * 28));
    }

    #[test]
    fn wav_and_form() {
        let file = wav(&[0.0, 1.0, -1.0], 16_000);
        assert_eq!(&file[..4], b"RIFF");
        assert_eq!(file.len(), 44 + 6);
        assert_eq!(i16::from_le_bytes([file[46], file[47]]), i16::MAX);
        let body = String::from_utf8_lossy(&form("b", &[("model", "saaras:v4".into())], b"WAV")).to_string();
        assert!(body.starts_with("--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nsaaras:v4\r\n"));
        assert!(body.ends_with("WAV\r\n--b--\r\n"));
    }

    #[test]
    fn resampled_to_16k() {
        assert_eq!(to_16k(&vec![0.5; 48_000], 48_000).len(), 16_000);
        assert!(to_16k(&vec![0.5; 48_000], 48_000).iter().all(|s| (s - 0.5).abs() < 1e-6));
        assert_eq!(to_16k(&vec![0.5; 8_000], 8_000).len(), 16_000);
        assert_eq!(to_16k(&[0.1, 0.2], 16_000), vec![0.1, 0.2]);
    }

    #[test]
    fn outputs_round_trip() {
        for output in Output::ALL {
            assert_eq!(Output::from_name(output.name()), output);
        }
        assert_eq!(Output::from_name(""), Output::Latin);
        assert!(Output::Latin.fields().contains(&("mode", "translit".to_string())));
    }
}
