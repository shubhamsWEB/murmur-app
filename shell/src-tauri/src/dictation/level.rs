//! Brings a recording to a steady speaking level before transcription, so soft speech and whispers are heard as well
//! as normal speech: the Mac app's AudioLevel (Sources/VoiceKit/AudioLevel.swift), step for step, so a recording comes
//! out the same on both.
//!
//! Steps: remove DC offset → high-pass at 80 Hz (rumble and fan hum, which would otherwise be boosted too) → measure
//! the speech level (the loudest 5 % of 20 ms frames) and the noise floor (the quietest 10 %) → one gain that brings
//! speech to about −20 dBFS, capped at `max_gain_db` (30 dB, or 40 dB with Quiet Voice) and never more than keeps speech
//! clearly above the noise → lift words said more quietly than the rest toward the same level, a few dB at a time and
//! never in the pauses → soft-limit peaks so nothing clips.

pub struct Leveled {
    pub samples: Vec<f32>,
    pub speech_db: f32,
    pub noise_db: f32,
    pub gain_db: f32,
}

/// The recording at a steady speaking level. `lift_words`: whether soft words get their own lift (Parakeet hears soft
/// words better for it; Whisper, which evens out loudness itself, can drop a soft last word when it's lifted).
pub fn normalize_with(input: &[f32], sample_rate: f32, max_gain_db: f32, lift_words: bool) -> Leveled {
    if input.len() <= 320 {
        return Leveled { samples: input.to_vec(), speech_db: -120.0, noise_db: -120.0, gain_db: 0.0 };
    }
    let mut samples = input.to_vec();

    // DC offset.
    let mean = samples.iter().sum::<f32>() / samples.len() as f32;

    // One-pole high-pass at 80 Hz.
    let rc = 1.0 / (2.0 * std::f32::consts::PI * 80.0);
    let dt = 1.0 / sample_rate;
    let alpha = rc / (rc + dt);
    let mut previous_in = samples[0] - mean;
    let mut previous_out = 0.0f32;
    for sample in samples.iter_mut() {
        let x = *sample - mean;
        let y = alpha * (previous_out + x - previous_in);
        *sample = y;
        previous_in = x;
        previous_out = y;
    }

    // Frame loudness (20 ms frames).
    let frame = (sample_rate / 50.0) as usize;
    let levels: Vec<f32> = samples
        .chunks_exact(frame)
        .map(|chunk| (chunk.iter().map(|v| v * v).sum::<f32>() / frame as f32).sqrt())
        .collect();
    if levels.is_empty() {
        return Leveled { samples, speech_db: -120.0, noise_db: -120.0, gain_db: 0.0 };
    }
    let mut sorted = levels.clone();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let speech = sorted[((sorted.len() as f32 * 0.95) as usize).min(sorted.len() - 1)].max(1e-6);
    let noise = sorted[(sorted.len() as f32 * 0.10) as usize].max(1e-6);
    let speech_db = 20.0 * speech.log10();
    let noise_db = 20.0 * noise.log10();

    // Gain toward −20 dBFS speech, capped, and only boosting when there is speech above the noise.
    let target_db = -20.0f32;
    let mut gain_db = max_gain_db.min((target_db - speech_db).max(0.0));
    if speech_db - noise_db < 6.0 {
        gain_db = gain_db.min(6.0); // nothing but noise: don't turn it into a roar
    }
    let gain = 10f32.powf(gain_db / 20.0);

    // Word by word: a 20 ms frame of speech (well above the noise) that's quieter than the target gets up to 12 dB
    // more, rising over ~60 ms and falling back at once for loud frames and gently in pauses.
    let word_target = 0.06f32; // about −24 dBFS
    let max_lift = if lift_words { 4.0f32 } else { 1.0 }; // +12 dB
    let speech_floor = (noise * 2.0).max(0.0005) * gain;
    let mut lifts = vec![1.0f32; levels.len()];
    let mut current = 1.0f32;
    for (k, level) in levels.iter().enumerate() {
        let level = level * gain;
        let want = if level > speech_floor { max_lift.min((word_target / level.max(1e-6)).max(1.0)) } else { 1.0 };
        if want < current {
            current = want;
        } else {
            current += (want - current) * if level > speech_floor { 0.35 } else { 0.08 };
        }
        lifts[k] = current;
    }

    // Apply the gain (the frame lifts blended sample by sample) with a soft limiter above 0.8, so peaks round off
    // instead of clipping.
    let last = lifts.len() - 1;
    for (i, sample) in samples.iter_mut().enumerate() {
        let position = i as f32 / frame as f32 - 0.5;
        let k = (position.max(0.0) as usize).min(last);
        let next = (k + 1).min(last);
        let t = (position - k as f32).clamp(0.0, 1.0);
        let v = *sample * gain * (lifts[k] + (lifts[next] - lifts[k]) * t);
        let a = v.abs();
        *sample = if a > 0.8 { v.signum() * (0.8 + 0.2 * ((a - 0.8) / 0.2).tanh()) } else { v };
    }
    Leveled { samples, speech_db, noise_db, gain_db }
}

#[cfg(test)]
mod tests {
    use super::normalize_with;

    fn normalize(input: &[f32], rate: f32, max_gain_db: f32) -> super::Leveled {
        normalize_with(input, rate, max_gain_db, true)
    }

    fn tone(amplitude: f32, seconds: f32, rate: f32) -> Vec<f32> {
        (0..(seconds * rate) as usize)
            .map(|i| {
                // Speech-like: on for 300 ms, off for 200 ms.
                let on = (i as f32 / rate * 1000.0) as u32 % 500 < 300;
                if on { amplitude * (i as f32 * 2.0 * std::f32::consts::PI * 220.0 / rate).sin() } else { 0.0 }
            })
            .collect()
    }

    #[test]
    fn whisper_is_lifted_and_capped() {
        let quiet = tone(0.003, 2.0, 16_000.0); // about −50 dBFS
        let normal = normalize(&quiet, 16_000.0, 30.0);
        let whisper = normalize(&quiet, 16_000.0, 40.0);
        assert!((normal.gain_db - 30.0).abs() < 0.01, "capped at 30: {}", normal.gain_db);
        assert!(whisper.gain_db > normal.gain_db, "Quiet Voice boosts more");
    }

    #[test]
    fn normal_speech_is_left_alone_and_never_clips() {
        let loud = tone(0.5, 2.0, 16_000.0);
        let out = normalize(&loud, 16_000.0, 40.0);
        assert_eq!(out.gain_db, 0.0);
        assert!(out.samples.iter().all(|v| v.abs() <= 1.0));
    }

    #[test]
    fn silence_is_not_boosted_into_a_roar() {
        let hiss: Vec<f32> = (0..32_000).map(|i| ((i * 7919 % 1000) as f32 / 1000.0 - 0.5) * 0.002).collect();
        assert!(normalize(&hiss, 16_000.0, 40.0).gain_db <= 6.0);
    }
}
