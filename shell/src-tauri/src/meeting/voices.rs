//! Who's speaking on a call, worked out on this PC, as the Mac's MeetingVoices, VoiceClusters and SpeakerTurns do it.
//!
//! Two small models through sherpa-onnx (downloaded once, 32 MB together): pyannote's segmentation 3.0, which finds
//! where one voice stops and another starts inside a stretch of speech, and WeSpeaker's ResNet34, which turns a
//! voice into a print (256 numbers that are close for the same person and far apart for different people).
//!
//! `Models::turns` cuts a stretch where the voice changes; each turn's print goes into `Clusters`, which keeps every
//! print heard and groups the whole meeting again as each arrives (pair by pair, closest first), so an early mistake
//! isn't kept. Each group keeps the number (1, 2…) most of its turns had before, so a voice's number doesn't change
//! as the grouping does. Nothing here is tuned to a person: the same settings for every voice and every meeting.

use sha2::{Digest, Sha256};
use sherpa_onnx::{OfflineSpeakerDiarization, OfflineSpeakerDiarizationConfig, SpeakerEmbeddingExtractor,
                  SpeakerEmbeddingExtractorConfig};
use std::path::{Path, PathBuf};

// MARK: The models' files

/// A model file: its name in Murmur's folder, where it's downloaded from, its size and SHA-256.
struct File {
    name: &'static str,
    url: &'static str,
    bytes: u64,
    sha256: &'static str,
}

/// pyannote/segmentation-3.0 (MIT) as sherpa-onnx exported it, and WeSpeaker's VoxCeleb ResNet34-LM (CC BY 4.0).
const FILES: [File; 2] = [
    File { name: "segmentation.onnx",
           url: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx",
           bytes: 5_992_913, sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079" },
    File { name: "voiceprint.onnx",
           url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx",
           bytes: 26_530_550, sha256: "e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012" },
];

/// Where the models are kept: beside the speech models (…\Murmur\Speech Models\meeting-voices).
pub fn folder() -> Option<PathBuf> {
    crate::dictation::speech::default_folder(crate::dictation::speech::Model::English)
        .and_then(|english| english.parent().map(|models| models.join("meeting-voices")))
}

pub fn installed(folder: &Path) -> bool {
    FILES.iter().all(|file| std::fs::metadata(folder.join(file.name)).is_ok_and(|m| m.len() == file.bytes))
}

/// Downloads what's missing (each file checked against its SHA-256 before it's kept).
pub async fn download(folder: &Path) -> Result<(), String> {
    std::fs::create_dir_all(folder).map_err(|error| error.to_string())?;
    for file in &FILES {
        let path = folder.join(file.name);
        if std::fs::metadata(&path).is_ok_and(|m| m.len() == file.bytes) {
            continue;
        }
        let reply = crate::ai::client().get(file.url).send().await.map_err(|error| format!("{}: {error}", file.name))?;
        if !reply.status().is_success() {
            return Err(format!("{}: the download answered {}", file.name, reply.status()));
        }
        let bytes = reply.bytes().await.map_err(|error| format!("{}: {error}", file.name))?;
        let sum: String = Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect();
        if sum != file.sha256 {
            return Err(format!("{}: what was downloaded isn't the model (its checksum is wrong)", file.name));
        }
        let partial = folder.join(format!("{}.part", file.name));
        std::fs::write(&partial, &bytes).and_then(|_| std::fs::rename(&partial, &path)).map_err(|error| error.to_string())?;
    }
    Ok(())
}

// MARK: The models

/// A turn inside a stretch of speech: one voice from `start` to `end` (seconds into the stretch).
#[derive(Clone, Debug, PartialEq)]
pub struct Turn {
    pub start: f64,
    pub end: f64,
    /// Which of the stretch's voices (0, 1…): only within this stretch.
    pub local: i32,
}

pub struct Models {
    diarizer: OfflineSpeakerDiarization,
    extractor: SpeakerEmbeddingExtractor,
}

/// Inside one stretch the segmentation's own word on who's who is kept (its voices are only joined when their prints,
/// as the model gives them, are this close): the meeting's grouping decides the rest.
const WITHIN_STRETCH: f32 = 0.3;
/// A turn shorter than this isn't one: "Yeah." under someone else's sentence, or a breath. It goes to the turn beside it.
pub const SHORTEST_TURN: f64 = 0.6;
/// The models hear 16 kHz.
pub const RATE: u32 = 16_000;

impl Models {
    pub fn load(folder: &Path) -> Result<Models, String> {
        if !installed(folder) {
            return Err("the voice models aren't downloaded yet".into());
        }
        let path = |name: &str| Some(folder.join(name).to_string_lossy().into_owned());
        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(1, 4) as i32;
        let embedding = SpeakerEmbeddingExtractorConfig { model: path(FILES[1].name), num_threads: threads, ..Default::default() };
        let mut config = OfflineSpeakerDiarizationConfig::default();
        config.segmentation.pyannote.model = path(FILES[0].name);
        config.segmentation.num_threads = threads;
        config.embedding = embedding.clone();
        // Inside one stretch: as many voices as it hears, told apart at the same distance as across the meeting.
        config.clustering.num_clusters = -1;
        config.clustering.threshold = WITHIN_STRETCH;
        config.min_duration_on = 0.3;
        config.min_duration_off = 0.3;
        let diarizer = OfflineSpeakerDiarization::create(&config).ok_or("sherpa-onnx couldn't load the voice models")?;
        let extractor = SpeakerEmbeddingExtractor::create(&embedding).ok_or("sherpa-onnx couldn't load the voiceprint model")?;
        Ok(Models { diarizer, extractor })
    }

    /// The turns in a stretch of speech (mono, 16 kHz), in order, covering all of it: one turn when it's one voice (or
    /// too short to tell). Short turns are folded into their neighbours and same-voice neighbours joined.
    pub fn turns(&self, samples: &[f32]) -> Vec<Turn> {
        let length = samples.len() as f64 / RATE as f64;
        let whole = vec![Turn { start: 0.0, end: length, local: 0 }];
        // Under two turns' worth there's nothing to cut.
        if length < SHORTEST_TURN * 3.0 {
            return whole;
        }
        let Some(result) = self.diarizer.process(samples) else { return whole };
        let heard: Vec<Turn> = result.sort_by_start_time().into_iter()
            .map(|s| Turn { start: s.start as f64, end: s.end as f64, local: s.speaker })
            .collect();
        let turns = tidy_turns(heard, length);
        if turns.is_empty() { whole } else { turns }
    }

    /// A voice's print from `samples` (mono, 16 kHz), unit length, with the part every voice shares taken out; None
    /// when there's too little to make one.
    pub fn print(&self, samples: &[f32]) -> Option<Vec<f32>> {
        without_background(&self.raw_print(samples)?)
    }

    /// The print as the model gives it, unit length.
    fn raw_print(&self, samples: &[f32]) -> Option<Vec<f32>> {
        if samples.len() < (RATE as f64 * 0.4) as usize {
            return None;
        }
        let stream = self.extractor.create_stream()?;
        stream.accept_waveform(RATE as i32, samples);
        stream.input_finished();
        if !self.extractor.is_ready(&stream) {
            return None;
        }
        normalized(&self.extractor.compute(&stream)?)
    }
}

/// What the segmentation heard, as turns that cover the stretch end to end: overlaps cut at their middle, gaps given
/// to the turn before, turns under `SHORTEST_TURN` folded into the longer neighbour, same-voice neighbours joined.
pub fn tidy_turns(mut heard: Vec<Turn>, length: f64) -> Vec<Turn> {
    heard.retain(|turn| turn.end > turn.start);
    heard.sort_by(|a, b| a.start.total_cmp(&b.start));
    if heard.is_empty() {
        return heard;
    }
    // End to end: each turn runs to where the next begins (an overlap is cut at its middle).
    let mut turns: Vec<Turn> = Vec::new();
    for turn in heard {
        match turns.last_mut() {
            Some(last) if last.local == turn.local => last.end = last.end.max(turn.end),
            Some(last) => {
                if turn.end <= last.end {
                    continue; // said under the other voice: theirs
                }
                let cut = if turn.start < last.end { (turn.start + last.end) / 2.0 } else { turn.start };
                last.end = cut;
                turns.push(Turn { start: cut, ..turn });
            }
            None => turns.push(turn),
        }
    }
    turns.first_mut().unwrap().start = 0.0;
    turns.last_mut().unwrap().end = length;
    // Short ones go to the longer neighbour, until none is left.
    loop {
        join_same(&mut turns);
        let Some(short) = (0..turns.len()).filter(|&i| turns[i].end - turns[i].start < SHORTEST_TURN && turns.len() > 1)
            .min_by(|&a, &b| (turns[a].end - turns[a].start).total_cmp(&(turns[b].end - turns[b].start))) else { break };
        let before = short.checked_sub(1).map(|i| turns[i].end - turns[i].start);
        let after = turns.get(short + 1).map(|t| t.end - t.start);
        if before.unwrap_or(-1.0) >= after.unwrap_or(-1.0) {
            turns[short - 1].end = turns[short].end;
        } else {
            turns[short + 1].start = turns[short].start;
        }
        turns.remove(short);
    }
    turns
}

fn join_same(turns: &mut Vec<Turn>) {
    let mut i = 1;
    while i < turns.len() {
        if turns[i].local == turns[i - 1].local {
            turns[i - 1].end = turns[i].end;
            turns.remove(i);
        } else {
            i += 1;
        }
    }
}

// MARK: Words

/// How far (seconds) a cut in the words moves to reach the end of a sentence.
pub const SENTENCE_REACH: f64 = 1.2;

/// A word and when it was said, in seconds from the start of what was transcribed.
#[derive(Clone, Debug, PartialEq)]
pub struct TimedWord {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

/// A stretch's words given to its turns by when each was said (its middle against the cuts, in seconds), so the
/// stretch is transcribed once, whole, and no word is lost or garbled where it's cut. None when the words and their
/// times don't add up to `whole`. As the Mac's `SpeakerTurns.texts`.
pub fn texts(words: &[TimedWord], cuts: &[f64], whole: &str) -> Option<Vec<String>> {
    if words.is_empty() || cuts.is_empty() {
        return None;
    }
    let letters = |text: &str| -> String { text.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect() };
    if letters(&words.iter().map(|w| w.text.as_str()).collect::<String>()) != letters(whole) {
        return None;
    }
    // People mostly take over at the end of a sentence, and the cut is only known to within a few words: it moves to
    // the nearest sentence end within `SENTENCE_REACH` seconds, when there is one.
    let ends: Vec<f64> = words.windows(2)
        .filter(|pair| pair[0].text.chars().last().is_some_and(|c| ".?!।。".contains(c)))
        .map(|pair| (pair[0].end + pair[1].start) / 2.0)
        .collect();
    let moved: Vec<f64> = cuts.iter().map(|&cut| {
        ends.iter().copied().min_by(|a, b| (a - cut).abs().total_cmp(&(b - cut).abs()))
            .filter(|nearest| (nearest - cut).abs() <= SENTENCE_REACH).unwrap_or(cut)
    }).collect();
    let mut parts: Vec<Vec<&str>> = vec![Vec::new(); cuts.len() + 1];
    for word in words {
        let middle = (word.start + word.end) / 2.0;
        parts[moved.iter().filter(|&&cut| cut <= middle).count()].push(&word.text);
    }
    Some(parts.into_iter().map(|part| part.join(" ")).collect())
}

/// The same without the words' times (a cloud speech model, or Whisper): each turn gets its share of the words by how
/// long it was, the cut moved to a sentence's end when one is within three words.
pub fn texts_by_share(whole: &str, turns: &[Turn]) -> Vec<String> {
    let words: Vec<&str> = whole.split_whitespace().collect();
    let length: f64 = turns.last().map_or(0.0, |turn| turn.end);
    if turns.len() < 2 || length <= 0.0 || words.len() < turns.len() {
        return vec![whole.to_string()];
    }
    let ends_sentence = |index: usize| words[index].chars().last().is_some_and(|c| ".?!।。".contains(c));
    let mut parts = Vec::new();
    let mut from = 0;
    for turn in &turns[..turns.len() - 1] {
        let wanted = ((turn.end / length) * words.len() as f64).round() as usize;
        let mut cut = wanted.clamp(from, words.len());
        // A sentence's end nearby: the nearest within three words.
        let near = (cut.saturating_sub(3).max(from + 1)..=(cut + 3).min(words.len() - 1))
            .filter(|&at| at >= 1 && ends_sentence(at - 1))
            .min_by_key(|&at| at.abs_diff(cut));
        if let Some(at) = near {
            cut = at;
        }
        parts.push(words[from..cut].join(" "));
        from = cut;
    }
    parts.push(words[from..].join(" "));
    parts
}

// MARK: Prints

pub fn normalized(print: &[f32]) -> Option<Vec<f32>> {
    let length = print.iter().map(|x| x * x).sum::<f32>().sqrt();
    (length > 1e-6 && length.is_finite()).then(|| print.iter().map(|x| x / length).collect())
}

/// A unit-length print with the part every voice shares taken out (`BACKGROUND`), unit length again.
pub fn without_background(print: &[f32]) -> Option<Vec<f32>> {
    if print.len() != BACKGROUND.len() {
        return normalized(print);
    }
    normalized(&print.iter().zip(BACKGROUND.iter()).map(|(x, shared)| x - shared).collect::<Vec<f32>>())
}

/// The part of a print that every voice shares (the model's own lean, and what speech in general sounds like to it):
/// about half of each print. Taking it out before comparing spreads different people apart, so one "same voice"
/// distance works. A fixed average rather than each meeting's own: a meeting's own average is the speaker in a
/// one-to-one call. The average of 320 recordings of 40 people (LibriSpeech's dev-clean readers) through this model.
const BACKGROUND: [f32; 256] = [
    -0.06131, -0.00037, -0.02834, 0.01343, 0.05375, 0.05608, 0.07796, -0.05207, 0.08386, -0.06210,
    0.00990, -0.03395, -0.00564, -0.02035, -0.05126, 0.00081, 0.03831, 0.04220, 0.05640, -0.03016,
    0.00532, -0.03493, -0.00684, -0.06552, 0.00974, -0.04378, 0.04142, -0.05849, 0.06513, 0.00008,
    -0.01466, 0.01430, 0.02750, -0.07658, -0.11681, 0.03135, -0.01696, -0.03454, 0.07338, -0.09060,
    -0.00922, 0.05120, -0.02473, 0.02048, -0.06111, 0.04774, 0.05082, -0.03161, -0.05931, 0.01807,
    0.02089, -0.04986, 0.03543, -0.04750, -0.00230, 0.01959, -0.06982, 0.04863, 0.04645, -0.07211,
    -0.00121, -0.10287, 0.03227, -0.00267, -0.02511, -0.06795, -0.05690, 0.00380, -0.00266, -0.12800,
    0.03090, 0.07201, -0.04774, -0.00321, 0.03479, -0.04021, 0.01402, 0.01371, 0.00019, 0.05574,
    -0.00807, 0.05222, 0.01851, -0.03895, 0.08213, 0.08936, -0.03107, 0.01817, -0.00848, -0.01337,
    0.01902, -0.04815, 0.06723, 0.08032, 0.01968, -0.02895, 0.07722, 0.05956, -0.04313, 0.05516,
    0.01718, -0.02901, -0.07076, -0.03985, -0.00072, -0.06781, 0.00872, -0.00802, 0.02897, 0.01490,
    0.01666, -0.04926, -0.07320, -0.00576, 0.02477, -0.02756, -0.00966, -0.03580, -0.03309, 0.07052,
    -0.00395, -0.11807, 0.06635, -0.01800, 0.00635, -0.00156, 0.00191, -0.04107, -0.01431, 0.11239,
    0.00568, -0.01986, -0.02717, 0.01770, -0.01397, -0.03215, 0.03471, -0.04636, -0.01136, 0.00927,
    -0.01271, 0.02140, 0.01325, 0.06235, -0.06739, 0.02717, -0.05647, -0.01605, 0.02352, 0.06065,
    0.02631, -0.01293, -0.03621, -0.02357, -0.02990, 0.01136, -0.03667, 0.01642, 0.01151, -0.02956,
    -0.05632, 0.04171, 0.02281, 0.04731, -0.02603, 0.01650, 0.06249, 0.02232, 0.00855, 0.01303,
    -0.02481, 0.00956, 0.00229, -0.00549, -0.07528, 0.01979, -0.01610, -0.02990, -0.03413, 0.02987,
    0.00288, -0.01770, -0.07507, -0.03445, -0.03394, -0.05710, -0.02543, -0.01638, -0.00702, -0.04409,
    0.03639, 0.02148, -0.06394, -0.03705, 0.00256, 0.04943, 0.06586, -0.03467, -0.07107, -0.03132,
    -0.06792, 0.04196, 0.06242, -0.00971, 0.01754, -0.09176, 0.00068, -0.12824, -0.01223, -0.02072,
    -0.06944, -0.01582, 0.00117, -0.07273, 0.02732, 0.05197, -0.03778, -0.00341, 0.00205, -0.07020,
    0.08235, -0.08293, 0.00180, 0.04126, -0.07445, -0.03576, 0.13255, 0.05458, 0.05872, 0.00843,
    -0.03090, 0.04111, -0.03362, -0.04702, -0.05848, 0.00186, -0.08080, 0.03810, -0.06452, 0.00361,
    0.00334, 0.00033, 0.01567, 0.00071, 0.05170, -0.01354, -0.02005, 0.01540, 0.02449, 0.02996,
    0.03706, -0.02671, -0.03252, 0.06135, 0.05424, -0.00239,
];

/// How alike two unit-length prints are: 1 the same, 0 unrelated.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

// MARK: Telling a meeting's voices apart

/// Two groups closer than this on average (cosine distance, the shared part taken out) are one voice.
///
/// Measured on eight made-up meetings of 3 to 7 real voices (LibriSpeech readers through different "microphones", a
/// third of the turns under two seconds, some handing over without a pause), with the settings below: 94 % of the
/// talking given to the right person, 2 % to the wrong one, 4 % left as "Them"; 40 people heard as 44 voices (a
/// stray extra voice rarely says the five lines it takes to be shown). At 0.55 people start to be taken for each
/// other (5 % wrong); at 0.45 one person is more often heard as two.
pub const SAME_BELOW: f32 = 0.5;
/// A turn by itself is a voice only when it's this long (seconds): a short one unlike everyone ("Yeah.", a cough) is
/// left without a voice rather than made a speaker.
pub const NEW_VOICE_SECONDS: f64 = 4.0;
/// Only turns this long are grouped into voices: a shorter one's print is too rough to found a voice on or to pull two
/// voices together, so it's given to the voice it's most like (or to none).
pub const CORE_SECONDS: f64 = 2.5;
/// A turn left out of every group is still given to the voice it's most like when that voice is within `LOOSE_BELOW`
/// of it and the next voice is at least `LOOSE_LEAD` farther: "which of the people here is this?" is an easier
/// question than "is this the same person?".
pub const LOOSE_BELOW: f32 = 0.72;
pub const LOOSE_LEAD: f32 = 0.1;
/// Past this many turns the meeting is grouped again only every few turns (it takes longer as it grows).
const EVERY_TIME: usize = 160;

#[derive(Clone)]
struct Stretch {
    print: Vec<f32>,
    seconds: f64,
    voice: Option<u32>,
    /// Turns you said are one person share a tie, and are kept together however the grouping goes.
    tie: Option<u32>,
    /// Not grouped with anyone, but plainly more like one voice than any other: shown as theirs, and not part of what
    /// that voice is known by.
    loose: bool,
}

#[derive(Clone, Default)]
pub struct Clusters {
    stretches: Vec<Stretch>,
    next_voice: u32,
    next_tie: u32,
    same_below: f32,
    core_seconds: f64,
    new_voice_seconds: f64,
}

impl Clusters {
    pub fn new() -> Clusters {
        Clusters { stretches: Vec::new(), next_voice: 1, next_tie: 1, same_below: SAME_BELOW, core_seconds: CORE_SECONDS, new_voice_seconds: NEW_VOICE_SECONDS }
    }

    /// How many voices there are.
    #[cfg(test)]
    pub fn count(&self) -> usize {
        self.numbers().len()
    }

    fn numbers(&self) -> Vec<u32> {
        let mut voices: Vec<u32> = self.stretches.iter().filter_map(|s| s.voice).collect();
        voices.sort_unstable();
        voices.dedup();
        voices
    }

    /// Takes a turn in (its unit-length print) and groups the meeting again. Returns the turn's index.
    pub fn add(&mut self, print: Vec<f32>, seconds: f64) -> usize {
        self.stretches.push(Stretch { print, seconds, voice: None, tie: None, loose: false });
        let index = self.stretches.len() - 1;
        if self.stretches.len() <= EVERY_TIME || self.stretches.len() % 5 == 0 {
            self.regroup();
        } else {
            // Between groupings: with the voice it's nearest to, if it's near enough.
            let mut best: Option<(u32, f32)> = None;
            for voice in self.numbers() {
                let Some(centre) = self.centroid(voice) else { continue };
                let distance = 1.0 - cosine(&centre, &self.stretches[index].print);
                if distance < best.map_or(self.same_below, |b| b.1) {
                    best = Some((voice, distance));
                }
            }
            self.stretches[index].voice = best.map(|b| b.0);
            self.adopt();
        }
        index
    }

    /// The voice of a turn, by its index, as the meeting is grouped now.
    pub fn voice(&self, index: usize) -> Option<u32> {
        self.stretches.get(index).and_then(|s| s.voice)
    }

    /// The voice a print is most like, when it's plainly one of them (`LOOSE_BELOW`, `LOOSE_LEAD`); with one voice
    /// only, near enough is enough.
    pub fn likeliest(&self, print: &[f32]) -> Option<u32> {
        let mut scored: Vec<(u32, f32)> = Vec::new();
        let mut voices: Vec<u32> = self.stretches.iter().filter(|s| !s.loose).filter_map(|s| s.voice).collect();
        voices.sort_unstable();
        voices.dedup();
        for voice in voices {
            if let Some(centre) = self.centroid(voice) {
                scored.push((voice, 1.0 - cosine(&centre, print)));
            }
        }
        scored.sort_by(|a, b| a.1.total_cmp(&b.1));
        let best = *scored.first()?;
        if best.1 >= LOOSE_BELOW || scored.get(1).is_some_and(|next| next.1 - best.1 < LOOSE_LEAD) {
            return None;
        }
        Some(best.0)
    }

    /// Groups every turn again and gives the groups their numbers.
    fn regroup(&mut self) {
        let n = self.stretches.len();
        if n == 0 {
            return;
        }
        // Average-linkage clustering: distances between groups kept in a table, the two closest joined each round.
        // Only turns long enough to know a voice by are grouped; the short ones go to the voice they're most like.
        let core_seconds = self.core_seconds;
        let mut members: Vec<Vec<usize>> = (0..n).map(|i| vec![i]).collect();
        let mut alive: Vec<bool> = self.stretches.iter().map(|s| s.seconds >= core_seconds || s.tie.is_some()).collect();
        let mut table = vec![0f32; n * n];
        for i in (0..n).filter(|&i| alive[i]) {
            for j in (i + 1..n).filter(|&j| alive[j]) {
                let d = 1.0 - cosine(&self.stretches[i].print, &self.stretches[j].print);
                table[i * n + j] = d;
                table[j * n + i] = d;
            }
        }
        loop {
            let mut best: Option<(usize, usize, f32)> = None;
            for a in (0..n).filter(|&a| alive[a]) {
                for b in (a + 1..n).filter(|&b| alive[b]) {
                    let d = table[a * n + b];
                    if d < best.map_or(self.same_below, |best| best.2) {
                        best = Some((a, b, d));
                    }
                }
            }
            let Some((a, b, _)) = best else { break };
            let (na, nb) = (members[a].len() as f32, members[b].len() as f32);
            for k in (0..n).filter(|&k| alive[k] && k != a && k != b) {
                let d = (na * table[a * n + k] + nb * table[b * n + k]) / (na + nb);
                table[a * n + k] = d;
                table[k * n + a] = d;
            }
            let moved = std::mem::take(&mut members[b]);
            members[a].extend(moved);
            alive[b] = false;
        }
        // Groups holding turns you said are one person are one group.
        let mut all: Vec<Vec<usize>> = (0..n).filter(|&i| alive[i]).map(|i| std::mem::take(&mut members[i])).collect();
        let mut holder: std::collections::HashMap<u32, usize> = std::collections::HashMap::new();
        let mut g = 0;
        while g < all.len() {
            let ties: Vec<u32> = all[g].iter().filter_map(|&i| self.stretches[i].tie).collect();
            if let Some(into) = ties.iter().find_map(|tie| holder.get(tie).copied()) {
                let moved = all.remove(g);
                all[into].extend(moved);
                for tie in ties {
                    holder.insert(tie, into);
                }
            } else {
                for tie in ties {
                    holder.insert(tie, g);
                }
                g += 1;
            }
        }
        // Groups worth a voice: more than one turn, or one long enough to be someone.
        let groups: Vec<Vec<usize>> = all.into_iter()
            .filter(|group| group.len() > 1 || self.stretches[group[0]].seconds >= self.new_voice_seconds)
            .collect();
        // Each keeps the number most of its turns had; the biggest overlaps choose first.
        let mut claims: Vec<(usize, u32, usize)> = Vec::new();
        for (g, group) in groups.iter().enumerate() {
            let mut had: std::collections::BTreeMap<u32, usize> = std::collections::BTreeMap::new();
            for &index in group {
                if let Some(voice) = self.stretches[index].voice {
                    *had.entry(voice).or_default() += 1;
                }
            }
            claims.extend(had.into_iter().map(|(voice, shared)| (g, voice, shared)));
        }
        claims.sort_by(|a, b| b.2.cmp(&a.2).then(a.1.cmp(&b.1)));
        let mut number: Vec<Option<u32>> = vec![None; groups.len()];
        let mut taken: Vec<u32> = Vec::new();
        for (g, voice, _) in claims {
            if number[g].is_none() && !taken.contains(&voice) {
                number[g] = Some(voice);
                taken.push(voice);
            }
        }
        for stretch in &mut self.stretches {
            stretch.voice = None;
            stretch.loose = false;
        }
        // New groups are numbered in the order first heard.
        let mut order: Vec<usize> = (0..groups.len()).collect();
        order.sort_by_key(|&g| groups[g].iter().min().copied().unwrap_or(0));
        for g in order {
            let voice = number[g].unwrap_or_else(|| {
                self.next_voice += 1;
                self.next_voice - 1
            });
            for &index in &groups[g] {
                self.stretches[index].voice = Some(voice);
            }
        }
        self.adopt();
    }

    /// Turns left without a voice go to the one they're plainly most like (`likeliest`).
    fn adopt(&mut self) {
        let found: Vec<(usize, u32)> = (0..self.stretches.len())
            .filter(|&i| self.stretches[i].voice.is_none())
            .filter_map(|i| self.likeliest(&self.stretches[i].print).map(|voice| (i, voice)))
            .collect();
        for (index, voice) in found {
            self.stretches[index].voice = Some(voice);
            self.stretches[index].loose = true;
        }
    }

    /// You said two voices are one person: `from`'s turns are `into`'s, now and as the grouping changes.
    pub fn merge(&mut self, from: u32, into: u32) {
        if from == into || !self.stretches.iter().any(|s| s.voice == Some(from)) {
            return;
        }
        let both = |s: &Stretch| s.voice == Some(from) || s.voice == Some(into);
        let ties: Vec<u32> = self.stretches.iter().filter(|s| both(s)).filter_map(|s| s.tie).collect();
        let tie = ties.iter().min().copied().unwrap_or_else(|| {
            self.next_tie += 1;
            self.next_tie - 1
        });
        for stretch in &mut self.stretches {
            if both(stretch) || stretch.tie.is_some_and(|t| ties.contains(&t)) {
                stretch.tie = Some(tie);
                if both(stretch) {
                    stretch.voice = Some(into);
                }
            }
        }
    }

    /// A voice's average print, unit length.
    pub fn centroid(&self, voice: u32) -> Option<Vec<f32>> {
        let mut sum: Vec<f32> = Vec::new();
        for stretch in self.stretches.iter().filter(|s| s.voice == Some(voice) && !s.loose) {
            if sum.is_empty() {
                sum = vec![0.0; stretch.print.len()];
            }
            if stretch.print.len() == sum.len() {
                for (total, x) in sum.iter_mut().zip(&stretch.print) {
                    *total += x;
                }
            }
        }
        normalized(&sum)
    }

    /// Seconds of speech heard from a voice, and in how many turns.
    pub fn heard(&self, voice: u32) -> (f64, usize) {
        let own = self.stretches.iter().filter(|s| s.voice == Some(voice) && !s.loose);
        own.fold((0.0, 0), |(seconds, turns), s| (seconds + s.seconds, turns + 1))
    }
}

// MARK: Voices you asked Murmur to remember

/// A voice you asked Murmur to remember: the name you gave it and the print it's known by. Kept only on this PC, in
/// Murmur's data folder (voices.json), never in a meeting's notes or transcript.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Profile {
    pub id: u64,
    pub name: String,
    /// Unit length, the shared part taken out.
    pub print: Vec<f32>,
    /// How many turns it was learned from (it weighs a new meeting's against them).
    pub samples: usize,
    /// Seconds since 1970.
    pub last_seen: f64,
    /// How the print was made: prints made another way can't be compared and are left alone.
    pub kind: u32,
}

/// How prints are made now (this model, `BACKGROUND` taken out).
pub const KIND: u32 = 1;
/// A saved voice is named in a new meeting without asking at this likeness or above, with this lead over the next
/// saved voice. The bar is higher than for telling voices apart in one meeting: a wrong name in someone's notes is
/// worse than "Speaker 2".
pub const KNOWN_ABOVE: f32 = 0.6;
pub const KNOWN_LEAD: f32 = 0.1;
/// (Each of 40 readers saved from four recordings and heard again in four others, two thirds of them through a
/// different "microphone": 23 named, none wrongly, 17 left for you to name.)
/// Remembering a voice, and knowing one again, needs this much of it from the meeting.
pub const FEWEST_TURNS: usize = 2;
pub const FEWEST_SECONDS: f64 = 8.0;
/// A profile's old print weighs at most this many turns against a new meeting's.
const HEAVIEST: usize = 20;

#[derive(Default)]
pub struct Library {
    pub profiles: Vec<Profile>,
    path: Option<PathBuf>,
}

impl Library {
    pub fn load(path: PathBuf) -> Library {
        let profiles = std::fs::read_to_string(&path).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default();
        Library { profiles, path: Some(path) }
    }

    fn save(&self) {
        let Some(path) = &self.path else { return };
        if let Some(folder) = path.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        if let Ok(text) = serde_json::to_string(&self.profiles) {
            let _ = std::fs::write(path, text);
        }
    }

    /// The saved voice a meeting's voice (its average print) plainly is, with how alike they are.
    pub fn who(&self, print: &[f32]) -> Option<(&Profile, f32)> {
        let mut scored: Vec<(&Profile, f32)> = self.profiles.iter().filter(|p| p.kind == KIND && p.print.len() == print.len())
            .map(|profile| (profile, cosine(&profile.print, print))).collect();
        scored.sort_by(|a, b| b.1.total_cmp(&a.1));
        let best = *scored.first()?;
        if best.1 < KNOWN_ABOVE || scored.get(1).is_some_and(|next| best.1 - next.1 < KNOWN_LEAD) {
            return None;
        }
        Some(best)
    }

    /// Remembers a voice under `name` (a meeting's average print, learned from `turns` turns): a saved voice of that
    /// name learns from it too; otherwise it's a new one.
    pub fn remember(&mut self, name: &str, print: &[f32], turns: usize, now: f64) {
        let name = name.trim();
        if name.is_empty() || print.is_empty() {
            return;
        }
        if let Some(profile) = self.profiles.iter_mut().find(|p| p.kind == KIND && p.name.to_lowercase() == name.to_lowercase()) {
            let old = profile.samples.min(HEAVIEST) as f32;
            let mixed: Vec<f32> = profile.print.iter().zip(print).map(|(a, b)| a * old + b * turns as f32).collect();
            if let Some(mixed) = normalized(&mixed) {
                profile.print = mixed;
            }
            profile.samples += turns;
            profile.last_seen = now;
        } else {
            let id = self.profiles.iter().map(|p| p.id).max().unwrap_or(0) + 1;
            self.profiles.push(Profile { id, name: name.into(), print: print.to_vec(), samples: turns, last_seen: now, kind: KIND });
        }
        self.save();
    }

    pub fn seen(&mut self, id: u64, now: f64) {
        if let Some(profile) = self.profiles.iter_mut().find(|p| p.id == id) {
            profile.last_seen = now;
            self.save();
        }
    }

    pub fn forget(&mut self, id: u64) {
        self.profiles.retain(|p| p.id != id);
        self.save();
    }

    pub fn rename(&mut self, id: u64, name: &str) {
        if let Some(profile) = self.profiles.iter_mut().find(|p| p.id == id) {
            if !name.trim().is_empty() {
                profile.name = name.trim().into();
            }
        }
        self.save();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(text: &str, start: f64, end: f64) -> TimedWord {
        TimedWord { text: text.into(), start, end }
    }

    /// The Mac's testWordsGoToThePartTheyWereSaidIn.
    #[test]
    fn words_go_to_the_turn_they_were_said_in() {
        let words = vec![word("What", 0.1, 0.3), word("do", 0.3, 0.4), word("you", 0.4, 0.5), word("think?", 0.5, 0.9),
                         word("Yeah,", 1.0, 1.2), word("so", 1.2, 1.4), word("I", 1.4, 1.5), word("agree.", 1.5, 2.0)];
        let whole = "What do you think? Yeah, so I agree.";
        let both = Some(vec!["What do you think?".to_string(), "Yeah, so I agree.".to_string()]);
        assert_eq!(texts(&words, &[0.95], whole), both);
        // A cut that lands inside a word: the word goes whole to the side most of it is on.
        assert_eq!(texts(&words, &[0.85], whole), both);
        // The cut came three words late: it moves back to the end of the sentence.
        assert_eq!(texts(&words, &[1.45], whole), both);
        // No sentence ends anywhere near: the cut stays where it was.
        let run: Vec<TimedWord> = (0..8).map(|i| word(&format!("word{i}"), i as f64, i as f64 + 0.8)).collect();
        let joined = run.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ");
        assert_eq!(texts(&run, &[3.9], &joined).unwrap()[0], "word0 word1 word2 word3");
        // No times, or times that aren't this text's.
        assert_eq!(texts(&[], &[0.95], whole), None);
        assert_eq!(texts(&words, &[0.95], "Something else entirely."), None);
        assert_eq!(texts(&words, &[], whole), None);
    }

    #[test]
    fn without_times_each_turn_gets_its_share_cut_at_a_sentence() {
        let whole = "What do you think about the plan? Yeah, so I agree with most of it.";
        let turns = vec![turn(0.0, 3.0, 0), turn(3.0, 7.0, 1)];
        assert_eq!(texts_by_share(whole, &turns), vec!["What do you think about the plan?", "Yeah, so I agree with most of it."]);
        assert_eq!(texts_by_share("Hello.", &turns), vec!["Hello."]);
    }

    #[test]
    fn a_saved_voice_is_known_again_only_when_its_plain() {
        let mut library = Library::default();
        library.remember("Priya", &print(0, 0.1, 0), 4, 1.0);
        library.remember("Raj", &print(1, 0.1, 1), 4, 1.0);
        assert_eq!(library.who(&print(0, 0.3, 2)).map(|(p, _)| p.name.as_str()), Some("Priya"));
        assert!(library.who(&print(3, 0.1, 3)).is_none(), "someone new");
        let between = normalized(&print(0, 0.0, 0).iter().zip(print(1, 0.0, 0)).map(|(a, b)| a + b).collect::<Vec<_>>()).unwrap();
        assert!(library.who(&between).is_none(), "as like one as the other");
        // The same name again: it learns, it isn't saved twice.
        library.remember("priya", &print(0, 0.2, 4), 3, 2.0);
        assert_eq!((library.profiles.len(), library.profiles[0].samples), (2, 7));
        library.forget(1);
        assert_eq!(library.profiles.len(), 1);
    }

    fn turn(start: f64, end: f64, local: i32) -> Turn {
        Turn { start, end, local }
    }

    #[test]
    fn turns_cover_the_stretch_and_short_ones_are_folded_in() {
        // A gap and an overlap: end to end, cut at the overlap's middle.
        let turns = tidy_turns(vec![turn(0.2, 4.0, 0), turn(3.6, 8.0, 1), turn(8.5, 12.0, 0)], 12.5);
        assert_eq!(turns, vec![turn(0.0, 3.8, 0), turn(3.8, 8.5, 1), turn(8.5, 12.5, 0)]);
        // "Yeah." in the middle of someone's sentence isn't a turn.
        let turns = tidy_turns(vec![turn(0.0, 5.0, 0), turn(5.0, 5.3, 1), turn(5.3, 9.0, 0)], 9.0);
        assert_eq!(turns, vec![turn(0.0, 9.0, 0)]);
        assert_eq!(tidy_turns(vec![], 3.0), vec![]);
        assert_eq!(tidy_turns(vec![turn(0.5, 2.0, 3)], 2.4), vec![turn(0.0, 2.4, 3)]);
    }

    /// A print near one of a few directions: `who` picks the direction, `wobble` how far off it is.
    fn print(who: usize, wobble: f32, seed: usize) -> Vec<f32> {
        let mut v = vec![0.0f32; 16];
        v[who] = 1.0;
        v[8 + (seed % 8)] = wobble;
        normalized(&v).unwrap()
    }

    #[test]
    fn the_same_voice_keeps_its_number_and_new_voices_get_the_next() {
        let mut clusters = Clusters::new();
        let a = clusters.add(print(0, 0.2, 0), 5.0);
        let b = clusters.add(print(1, 0.2, 1), 5.0);
        let a2 = clusters.add(print(0, 0.3, 2), 4.0);
        let c = clusters.add(print(2, 0.2, 3), 6.0);
        assert_eq!((clusters.voice(a), clusters.voice(b), clusters.voice(a2), clusters.voice(c)),
                   (Some(1), Some(2), Some(1), Some(3)));
        assert_eq!(clusters.count(), 3);
        assert_eq!(clusters.heard(1), (9.0, 2));
    }

    #[test]
    fn a_short_turn_unlike_everyone_isnt_a_new_speaker() {
        let mut clusters = Clusters::new();
        clusters.add(print(0, 0.1, 0), 5.0);
        let cough = clusters.add(print(5, 0.1, 1), 0.7);
        assert_eq!(clusters.voice(cough), None);
        assert_eq!(clusters.count(), 1);
    }

    #[test]
    fn voices_you_say_are_one_person_stay_one() {
        let mut clusters = Clusters::new();
        let a = clusters.add(print(0, 0.1, 0), 5.0);
        let b = clusters.add(print(1, 0.1, 1), 5.0);
        clusters.merge(2, 1);
        let later = clusters.add(print(1, 0.2, 2), 5.0);
        assert_eq!((clusters.voice(a), clusters.voice(b), clusters.voice(later)), (Some(1), Some(1), Some(1)));
    }

    /// Simulated meetings through the real models (not run by default: it needs the models and recordings):
    /// MURMUR_VOICE_MODELS=<folder> MURMUR_VOICE_SIM=<folder of mN.wav + mN.json> cargo test voices::tests::sim -- --ignored --nocapture
    #[test]
    #[ignore]
    fn sim() {
        let (Ok(models), Ok(sim)) = (std::env::var("MURMUR_VOICE_MODELS"), std::env::var("MURMUR_VOICE_SIM")) else { return };
        let models = Models::load(Path::new(&models)).expect("models");
        let (mut right, mut wrong, mut none, mut cast_total, mut voices_total) = (0.0, 0.0, 0.0, 0, 0);
        let mut same: Vec<(f32, f64)> = Vec::new();
        let mut different: Vec<(f32, f64)> = Vec::new();
        for entry in std::fs::read_dir(&sim).unwrap().flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("wav") {
                continue;
            }
            let wave = sherpa_onnx::Wave::read(path.to_str().unwrap()).expect("wav");
            let truth: Vec<serde_json::Value> = serde_json::from_str(&std::fs::read_to_string(path.with_extension("json")).unwrap()).unwrap();
            let who_at = |t: f64| truth.iter().find(|x| t >= x["start"].as_f64().unwrap() && t < x["end"].as_f64().unwrap())
                .map(|x| x["who"].as_str().unwrap().to_string());
            // As the meeting hears it: the segmenter's pieces, each cut into turns, each turn's print grouped.
            let mut segmenter = crate::meeting::segmenter::Segmenter::new(RATE as f64);
            let mut clusters = Clusters::new();
            if let Some(same) = std::env::var("MURMUR_SAME").ok().and_then(|v| v.parse().ok()) { clusters.same_below = same; }
            if let Some(core) = std::env::var("MURMUR_CORE").ok().and_then(|v| v.parse().ok()) { clusters.core_seconds = core; }
            if let Some(new) = std::env::var("MURMUR_NEW").ok().and_then(|v| v.parse().ok()) { clusters.new_voice_seconds = new; }
            let mut heard: Vec<(f64, f64, Option<usize>, Vec<f32>)> = Vec::new();
            let mut fed = 0usize;
            let started = std::time::Instant::now();
            let mut pieces: Vec<(Vec<f32>, f64)> = Vec::new();
            for chunk in wave.samples().chunks(1600) {
                fed += chunk.len();
                for (piece, after) in segmenter.add_timed(chunk) {
                    let start = (fed - after - piece.len()) as f64 / RATE as f64;
                    pieces.push((piece, start));
                }
            }
            if let Some(piece) = segmenter.flush() {
                let start = (fed - piece.len()) as f64 / RATE as f64;
                pieces.push((piece, start));
            }
            for (piece, start) in &pieces {
                for turn in models.turns(piece) {
                    let (a, b) = ((turn.start * RATE as f64) as usize, ((turn.end * RATE as f64) as usize).min(piece.len()));
                    let index = models.print(&piece[a..b]).map(|print| {
                        (clusters.add(print.clone(), turn.end - turn.start), print)
                    });
                    heard.push((start + turn.start, start + turn.end, index.as_ref().map(|i| i.0), index.map(|i| i.1).unwrap_or_default()));
                }
            }
            let took = started.elapsed().as_secs_f64();
            // Each voice is whoever it mostly was; then every 100 ms of speech is right, wrong or without a voice.
            let mut votes: std::collections::HashMap<(u32, String), f64> = std::collections::HashMap::new();
            let step = 0.1;
            let mut slices: Vec<(String, Option<u32>)> = Vec::new();
            for (start, end, index, _) in &heard {
                let voice = index.and_then(|i| clusters.voice(i));
                let mut t = *start;
                while t < *end {
                    if let Some(who) = who_at(t) {
                        if let Some(voice) = voice {
                            *votes.entry((voice, who.clone())).or_default() += step;
                        }
                        slices.push((who, voice));
                    }
                    t += step;
                }
            }
            let mut owner: std::collections::HashMap<u32, String> = std::collections::HashMap::new();
            for voice in clusters.numbers() {
                if let Some(((_, who), _)) = votes.iter().filter(|((v, _), _)| *v == voice).max_by(|a, b| a.1.total_cmp(b.1)) {
                    owner.insert(voice, who.clone());
                }
            }
            let (mut r, mut w, mut n) = (0.0, 0.0, 0.0);
            for (who, voice) in &slices {
                match voice.and_then(|v| owner.get(&v)) {
                    Some(name) if name == who => r += step,
                    Some(_) => w += step,
                    None => n += step,
                }
            }
            let cast: std::collections::HashSet<&str> = truth.iter().map(|x| x["who"].as_str().unwrap()).collect();
            println!("{}: {} people, {} voices; right {:.0} s, wrong {:.0} s, no voice {:.0} s; {} pieces, {} turns, {:.1} s for {:.0} s of sound",
                     path.file_name().unwrap().to_string_lossy(), cast.len(), clusters.count(), r, w, n, pieces.len(), heard.len(),
                     took, wave.samples().len() as f64 / RATE as f64);
            right += r; wrong += w; none += n; cast_total += cast.len(); voices_total += clusters.count();
            // How far apart prints are: the same person's, and different people's (by the shorter turn's length).
            let people: Vec<Option<String>> = heard.iter().map(|(a, b, _, _)| who_at((a + b) / 2.0)).collect();
            for i in 0..heard.len() {
                for j in i + 1..heard.len() {
                    if heard[i].3.is_empty() || heard[j].3.is_empty() { continue }
                    let (Some(a), Some(b)) = (&people[i], &people[j]) else { continue };
                    let d = 1.0 - cosine(&heard[i].3, &heard[j].3);
                    let shorter = (heard[i].1 - heard[i].0).min(heard[j].1 - heard[j].0);
                    if a == b { same.push((d, shorter)) } else { different.push((d, shorter)) }
                }
            }
        }
        println!("all: right {:.1} %, wrong {:.1} %, no voice {:.1} %; {} people heard as {} voices",
                 100.0 * right / (right + wrong + none), 100.0 * wrong / (right + wrong + none),
                 100.0 * none / (right + wrong + none), cast_total, voices_total);
        for (label, floor) in [("turns of 4 s or more", 4.0), ("turns of 2 s or more", 2.0), ("all turns", 0.0)] {
            let pick = |v: &Vec<(f32, f64)>| { let mut d: Vec<f32> = v.iter().filter(|x| x.1 >= floor).map(|x| x.0).collect(); d.sort_by(|a, b| a.total_cmp(b)); d };
            let (s, d) = (pick(&same), pick(&different));
            let q = |v: &Vec<f32>, p: f64| v.get(((v.len() as f64 - 1.0) * p) as usize).copied().unwrap_or(f32::NAN);
            println!("{label}: same person 50 % {:.2}, 90 % {:.2}, 99 % {:.2}; different people 1 % {:.2}, 10 % {:.2}, 50 % {:.2}",
                     q(&s, 0.5), q(&s, 0.9), q(&s, 0.99), q(&d, 0.01), q(&d, 0.1), q(&d, 0.5));
        }
    }

    /// The average print of many voices (a folder of 16 kHz recordings), as the constant `BACKGROUND` is written:
    /// MURMUR_VOICE_MODELS=<folder> MURMUR_VOICE_UTTERANCES=<folder> cargo test voices::tests::background -- --ignored --nocapture
    #[test]
    #[ignore]
    fn background() {
        let (Ok(models), Ok(folder)) = (std::env::var("MURMUR_VOICE_MODELS"), std::env::var("MURMUR_VOICE_UTTERANCES")) else { return };
        let models = Models::load(Path::new(&models)).expect("models");
        let mut sum = vec![0f32; 256];
        let mut count = 0;
        for entry in std::fs::read_dir(&folder).unwrap().flatten() {
            let Some(wave) = sherpa_onnx::Wave::read(entry.path().to_str().unwrap()) else { continue };
            let Some(print) = models.raw_print(wave.samples()) else { continue };
            for (total, x) in sum.iter_mut().zip(&print) { *total += x; }
            count += 1;
        }
        let mean: Vec<f32> = sum.iter().map(|x| x / count as f32).collect();
        println!("// {count} recordings; length {:.3}", mean.iter().map(|x| x * x).sum::<f32>().sqrt());
        for row in mean.chunks(10) {
            println!("    {},", row.iter().map(|x| format!("{x:.5}")).collect::<Vec<_>>().join(", "));
        }
    }

    /// What the segmentation says about each piece that holds two people (MURMUR_VOICE_WAV=<one meeting's wav>).
    #[test]
    #[ignore]
    fn diag() {
        let (Ok(models), Ok(wav)) = (std::env::var("MURMUR_VOICE_MODELS"), std::env::var("MURMUR_VOICE_WAV")) else { return };
        let models = Models::load(Path::new(&models)).expect("models");
        let wave = sherpa_onnx::Wave::read(&wav).expect("wav");
        let truth: Vec<serde_json::Value> = serde_json::from_str(&std::fs::read_to_string(Path::new(&wav).with_extension("json")).unwrap()).unwrap();
        let mut segmenter = crate::meeting::segmenter::Segmenter::new(RATE as f64);
        let mut fed = 0usize;
        for chunk in wave.samples().chunks(1600) {
            fed += chunk.len();
            for (piece, after) in segmenter.add_timed(chunk) {
                let start = (fed - after - piece.len()) as f64 / RATE as f64;
                let end = start + piece.len() as f64 / RATE as f64;
                let inside: Vec<String> = truth.iter().filter(|x| x["end"].as_f64().unwrap() > start + 0.3 && x["start"].as_f64().unwrap() < end - 0.3)
                    .map(|x| format!("{}@{:.1}-{:.1}", x["who"].as_str().unwrap(), x["start"].as_f64().unwrap() - start, x["end"].as_f64().unwrap() - start)).collect();
                if inside.len() < 2 { continue }
                let raw: Vec<String> = models.diarizer.process(&piece).map(|r| r.sort_by_start_time()).unwrap_or_default().iter()
                    .map(|s| format!("{}:{:.1}-{:.1}", s.speaker, s.start, s.end)).collect();
                let turns: Vec<String> = models.turns(&piece).iter().map(|t| format!("{}:{:.1}-{:.1}", t.local, t.start, t.end)).collect();
                println!("piece {:.1}-{:.1}: truth [{}] heard [{}] turns [{}]", start, end, inside.join(", "), raw.join(", "), turns.join(", "));
            }
        }
    }

    /// Saved voices: each person's average print from half their recordings against everyone's from the other half
    /// (files named <who>_a<n>.wav and <who>_b<n>.wav in MURMUR_VOICE_UTTERANCES).
    #[test]
    #[ignore]
    fn known() {
        let (Ok(models), Ok(folder)) = (std::env::var("MURMUR_VOICE_MODELS"), std::env::var("MURMUR_VOICE_UTTERANCES")) else { return };
        let models = Models::load(Path::new(&models)).expect("models");
        let mut halves: std::collections::BTreeMap<(String, bool), Vec<Vec<f32>>> = std::collections::BTreeMap::new();
        for entry in std::fs::read_dir(&folder).unwrap().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some((who, rest)) = name.split_once('_') else { continue };
            let Some(wave) = sherpa_onnx::Wave::read(entry.path().to_str().unwrap()) else { continue };
            let Some(print) = models.print(wave.samples()) else { continue };
            halves.entry((who.to_string(), rest.starts_with('a'))).or_default().push(print);
        }
        let centre = |prints: &Vec<Vec<f32>>| {
            let mut sum = vec![0f32; prints[0].len()];
            for print in prints { for (t, x) in sum.iter_mut().zip(print) { *t += x; } }
            normalized(&sum).unwrap()
        };
        let saved: Vec<(String, Vec<f32>)> = halves.iter().filter(|(k, _)| k.1).map(|(k, v)| (k.0.clone(), centre(v))).collect();
        let (mut same, mut other, mut leads): (Vec<f32>, Vec<f32>, Vec<f32>) = (vec![], vec![], vec![]);
        let (mut named, mut wrongly, mut unnamed) = (0, 0, 0);
        let mut library = Library::default();
        for (who, print) in &saved { library.remember(who, print, 4, 0.0); }
        for ((who, first), prints) in &halves {
            if *first { continue }
            let heard = centre(prints);
            let mut scores: Vec<(f32, bool)> = saved.iter().map(|(name, print)| (cosine(print, &heard), name == who)).collect();
            scores.sort_by(|a, b| b.0.total_cmp(&a.0));
            for (score, own) in &scores { if *own { same.push(*score) } else { other.push(*score) } }
            leads.push(scores[0].0 - scores[1].0);
            match library.who(&heard) {
                Some((profile, _)) if profile.name == *who => named += 1,
                Some(_) => wrongly += 1,
                None => unnamed += 1,
            }
        }
        same.sort_by(|a, b| a.total_cmp(b));
        other.sort_by(|a, b| a.total_cmp(b));
        leads.sort_by(|a, b| a.total_cmp(b));
        let q = |v: &Vec<f32>, p: f64| v[((v.len() as f64 - 1.0) * p) as usize];
        println!("the same person: least {:.2}, 10 % {:.2}, half {:.2}; someone else: half {:.2}, 99 % {:.2}, most {:.2}; lead: least {:.2}, 10 % {:.2}",
                 same[0], q(&same, 0.1), q(&same, 0.5), q(&other, 0.5), q(&other, 0.99), other[other.len() - 1], leads[0], q(&leads, 0.1));
        println!("named {named}, wrongly {wrongly}, not named {unnamed} of {}", named + wrongly + unnamed);
    }
}
