//! Cuts a running stream of sound (the call, or your microphone) into pieces to transcribe, one per stretch of
//! speech, as the Mac's MeetingSegmenter: a piece ends at a pause of `pause` seconds after speech, or at the last
//! short pause once it reaches `longest` seconds (a long speech isn't held back). Stretches with almost no speech (a
//! cough, a click) are dropped.
//!
//! Speech is told from quiet by loudness over 30 ms frames against a noise floor that follows the room (it falls at
//! once to a quieter frame and rises slowly), so a fan or a call's hiss isn't taken for a voice.

pub struct Segmenter {
    pub rate: f64,
    /// Silence after speech that ends a piece.
    pub pause: f64,
    /// A piece is cut at its last short pause (or here) once it's this long.
    pub longest: f64,
    /// Speech a piece needs to be kept.
    pub least_speech: f64,
    frame: usize,
    partial: Vec<f32>,
    piece: Vec<f32>,
    noise: f32,
    voiced: usize,
    silent_run: usize,
    heard: bool,
    /// Where (in `piece`) the latest short pause ended: the place to cut a long piece.
    last_pause: usize,
    /// The loudness of the last frame, 0…1 on a scale from −60 dBFS (silence) to −10 dBFS (loud), for a meter.
    pub level: f32,
}

impl Segmenter {
    pub fn new(rate: f64) -> Segmenter {
        Segmenter {
            rate, pause: 0.6, longest: 20.0, least_speech: 0.35,
            frame: ((rate * 0.03) as usize).max(1),
            partial: Vec::new(), piece: Vec::new(), noise: 0.002, voiced: 0, silent_run: 0, heard: false, last_pause: 0,
            level: 0.0,
        }
    }

    fn frame_seconds(&self) -> f64 {
        self.frame as f64 / self.rate
    }

    /// Adds sound; returns the pieces it finished, in order.
    pub fn add(&mut self, samples: &[f32]) -> Vec<Vec<f32>> {
        let mut done = Vec::new();
        self.partial.extend_from_slice(samples);
        let mut start = 0;
        while self.partial.len() - start >= self.frame {
            let chunk: Vec<f32> = self.partial[start..start + self.frame].to_vec();
            start += self.frame;
            if let Some(finished) = self.take(&chunk) {
                done.push(finished);
            }
        }
        self.partial.drain(..start);
        done
    }

    /// What's left at the end, if it holds speech.
    pub fn flush(&mut self) -> Option<Vec<f32>> {
        let enough = self.voiced as f64 * self.frame_seconds() >= self.least_speech;
        let piece = std::mem::take(&mut self.piece);
        self.reset();
        enough.then_some(piece)
    }

    /// Someone is speaking now (speech within the last 0.3 s), so a question may not be over yet.
    pub fn is_speaking(&self) -> bool {
        self.heard && (self.silent_run as f64) * self.frame_seconds() < 0.3
    }

    /// The loudness above which a frame is speech: well above the room's noise, and above −48 dBFS.
    fn threshold(&self) -> f32 {
        (self.noise * 3.2).max(0.004)
    }

    fn take(&mut self, chunk: &[f32]) -> Option<Vec<f32>> {
        let rms = (chunk.iter().map(|v| v * v).sum::<f32>() / chunk.len() as f32).sqrt();
        self.level = ((20.0 * rms.max(1e-6).log10() + 60.0) / 50.0).clamp(0.0, 1.0);
        let speech = rms > self.threshold();
        if !speech {
            self.noise = if rms < self.noise { rms.max(1e-5) } else { self.noise * 0.95 + rms * 0.05 };
        }
        self.piece.extend_from_slice(chunk);
        if speech {
            self.voiced += 1;
            self.silent_run = 0;
            self.heard = true;
        } else {
            self.silent_run += 1;
            // A short pause (a quarter second): somewhere a long piece can be cut without splitting a word.
            if self.heard && self.silent_run as f64 * self.frame_seconds() >= 0.25 {
                self.last_pause = self.piece.len();
            }
        }
        if !self.heard {
            // Before anyone speaks, only a moment of lead-in is kept.
            let lead = (self.rate * 0.3) as usize;
            if self.piece.len() > lead * 2 {
                let extra = self.piece.len() - lead;
                self.piece.drain(..extra);
            }
            return None;
        }
        let seconds = self.piece.len() as f64 / self.rate;
        let enough = self.voiced as f64 * self.frame_seconds() >= self.least_speech;
        if self.silent_run as f64 * self.frame_seconds() >= self.pause {
            // The end of a stretch of speech; a little of the silence after it stays.
            let trailing = (self.silent_run * self.frame).saturating_sub((self.rate * 0.3) as usize);
            let keep = self.piece.len() - trailing.min(self.piece.len());
            let finished = self.piece[..keep].to_vec();
            self.piece.clear();
            self.reset();
            return enough.then_some(finished);
        }
        if seconds >= self.longest {
            let cut = if self.last_pause > (self.rate * 5.0) as usize { self.last_pause } else { self.piece.len() };
            let finished = self.piece[..cut].to_vec();
            let rest = self.piece[cut..].to_vec();
            self.reset();
            self.heard = !rest.is_empty();
            self.piece = rest;
            // The rest was cut out of speech: counted as speech, so its end isn't dropped as a cough.
            if self.heard {
                self.voiced = (self.least_speech / self.frame_seconds()) as usize + 1;
            }
            return enough.then_some(finished);
        }
        None
    }

    fn reset(&mut self) {
        self.piece.clear();
        self.voiced = 0;
        self.silent_run = 0;
        self.heard = false;
        self.last_pause = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(seconds: f64, rate: f64, amplitude: f32) -> Vec<f32> {
        (0..(seconds * rate) as usize).map(|i| amplitude * ((i as f32) * 0.05).sin()).collect()
    }

    #[test]
    fn a_stretch_of_speech_ends_at_a_pause() {
        let rate = 16_000.0;
        let mut segmenter = Segmenter::new(rate);
        let mut sound = vec![0.0001f32; 8_000];
        sound.extend(tone(1.5, rate, 0.2));
        sound.extend(vec![0.0001f32; 16_000]);
        let pieces = segmenter.add(&sound);
        assert_eq!(pieces.len(), 1);
        let seconds = pieces[0].len() as f64 / rate;
        assert!((1.5..2.4).contains(&seconds), "{seconds}");
        assert!(!segmenter.is_speaking());
    }

    #[test]
    fn a_click_is_dropped_and_long_speech_is_cut() {
        let rate = 16_000.0;
        let mut segmenter = Segmenter::new(rate);
        let mut click = vec![0.0001f32; 8_000];
        click.extend(tone(0.1, rate, 0.3));
        click.extend(vec![0.0001f32; 16_000]);
        assert!(segmenter.add(&click).is_empty());
        let long = tone(25.0, rate, 0.2);
        let pieces = segmenter.add(&long);
        assert_eq!(pieces.len(), 1);
        assert!(segmenter.is_speaking());
        assert!(segmenter.flush().is_some());
    }
}
