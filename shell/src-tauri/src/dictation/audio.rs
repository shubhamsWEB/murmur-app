//! The microphone, while the dictation key is held: one input stream on a thread of its own (cpal's streams aren't
//! sent between threads on every system), its samples mixed to mono and kept, and a level for the pill as they come.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, Stream};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// A recording in progress. `finish` stops it and gives back what was heard.
pub struct Recording {
    stop: mpsc::Sender<()>,
    thread: Option<JoinHandle<()>>,
    samples: Arc<Mutex<Vec<f32>>>,
    pub sample_rate: u32,
    pub device: String,
    pub started: Instant,
    /// How long the microphone took to deliver its first samples (a Bluetooth headset waking takes a while).
    pub opened_in: Duration,
}

/// The input devices' names, for Settings' microphone list (the default one first).
pub fn microphones() -> Vec<String> {
    let host = cpal::default_host();
    let default = host.default_input_device().map(|device| device.to_string());
    let mut names: Vec<String> = host
        .input_devices()
        .map(|devices| devices.map(|device| device.to_string()).collect())
        .unwrap_or_default();
    names.sort();
    names.dedup();
    if let Some(default) = default {
        names.retain(|name| *name != default);
        names.insert(0, default);
    }
    names
}

impl Recording {
    /// Starts the microphone named `wanted` (or the system's default when that's empty or gone). `level` gets the
    /// loudness of each moment, 0…1, for the pill.
    pub fn start(wanted: &str, level: impl Fn(f32) + Send + 'static) -> Result<Recording, String> {
        let samples = Arc::new(Mutex::new(Vec::with_capacity(16_000 * 30)));
        let (stop, stopped) = mpsc::channel::<()>();
        let (ready, opened) = mpsc::channel::<Result<(u32, String), String>>();
        let kept = samples.clone();
        let started = Instant::now();
        let wanted = wanted.to_string();
        let thread = std::thread::Builder::new()
            .name("murmur-microphone".into())
            .spawn(move || {
                let stream = match open(&wanted, kept, level) {
                    Ok((stream, rate, name)) => {
                        let _ = ready.send(Ok((rate, name)));
                        stream
                    }
                    Err(error) => {
                        let _ = ready.send(Err(error));
                        return;
                    }
                };
                let _ = stopped.recv(); // until finish (or the Recording is dropped)
                drop(stream);
            })
            .map_err(|error| format!("can't start the microphone's thread: {error}"))?;
        let (sample_rate, device) = opened
            .recv_timeout(Duration::from_secs(5))
            .map_err(|_| "the microphone didn't answer".to_string())??;
        // The first samples, so the pill's "listening" is true (a waking headset can take a second).
        let waited = Instant::now();
        while samples.lock().unwrap().is_empty() && waited.elapsed() < Duration::from_millis(1500) {
            std::thread::sleep(Duration::from_millis(10));
        }
        Ok(Recording {
            stop,
            thread: Some(thread),
            samples,
            sample_rate,
            device,
            opened_in: started.elapsed(),
            started,
        })
    }

    /// Stops the microphone; what it heard, mono, at `sample_rate`. Waits at most two seconds for the microphone to
    /// close: a driver that hangs on closing (a Bluetooth headset gone, the PC just woken) must not hold up the next
    /// dictation, which would look as if the key had stopped working. A stream that won't close is left to its thread.
    pub fn finish(mut self) -> Vec<f32> {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() {
            let (closed, waited) = mpsc::channel();
            std::thread::spawn(move || {
                let _ = thread.join();
                let _ = closed.send(());
            });
            if waited.recv_timeout(Duration::from_secs(2)).is_err() {
                eprintln!("murmur-shell: the microphone didn't close within 2 s; going on without waiting");
            }
        }
        std::mem::take(&mut *self.samples.lock().unwrap())
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        let _ = self.stop.send(());
    }
}

fn open(wanted: &str, kept: Arc<Mutex<Vec<f32>>>, level: impl Fn(f32) + Send + 'static)
    -> Result<(Stream, u32, String), String> {
    let host = cpal::default_host();
    let device = (!wanted.is_empty())
        .then(|| host.input_devices().ok()?.find(|device| device.to_string() == wanted))
        .flatten()
        .or_else(|| host.default_input_device())
        .ok_or("there's no microphone")?;
    let name = device.to_string();
    let config = device.default_input_config().map_err(|error| format!("{name} can't record: {error}"))?;
    let channels = config.channels() as usize;
    let rate = config.sample_rate();
    let format = config.sample_format();
    let config: cpal::StreamConfig = config.into();
    // The pill's level: the loudest of the last ~50 ms, as 0…1 over −55…−15 dBFS.
    let loudest = Arc::new(AtomicU32::new(0));
    let since = Arc::new(Mutex::new(Instant::now()));
    let take = move |mono: &[f32]| {
        let peak = mono.iter().fold(0.0f32, |most, v| most.max(v.abs()));
        let _ = loudest.fetch_max(peak.to_bits(), Ordering::Relaxed);
        let mut last = since.lock().unwrap();
        if last.elapsed() >= Duration::from_millis(50) {
            *last = Instant::now();
            let peak = f32::from_bits(loudest.swap(0, Ordering::Relaxed));
            let db = 20.0 * peak.max(1e-6).log10();
            level(((db + 55.0) / 40.0).clamp(0.0, 1.0));
        }
        kept.lock().unwrap().extend_from_slice(mono);
    };
    let failed = |error: cpal::Error| eprintln!("murmur-shell: microphone: {error}");
    let stream = match format {
        SampleFormat::F32 => device.build_input_stream(config.clone(), move |data: &[f32], _: &_| take(&mix(data, channels)), failed, None),
        SampleFormat::I16 => device.build_input_stream(config.clone(), move |data: &[i16], _: &_| {
            let floats: Vec<f32> = data.iter().map(|v| *v as f32 / 32768.0).collect();
            take(&mix(&floats, channels))
        }, failed, None),
        SampleFormat::U16 => device.build_input_stream(config.clone(), move |data: &[u16], _: &_| {
            let floats: Vec<f32> = data.iter().map(|v| (*v as f32 - 32768.0) / 32768.0).collect();
            take(&mix(&floats, channels))
        }, failed, None),
        SampleFormat::I32 => device.build_input_stream(config.clone(), move |data: &[i32], _: &_| {
            let floats: Vec<f32> = data.iter().map(|v| *v as f32 / 2_147_483_648.0).collect();
            take(&mix(&floats, channels))
        }, failed, None),
        other => return Err(format!("{name} records in a format Murmur doesn't read ({other})")),
    }
    .map_err(|error| format!("can't open {name}: {error}"))?;
    stream.play().map_err(|error| format!("can't start {name}: {error}"))?;
    Ok((stream, rate, name))
}

/// Mono: with two or more channels, the loudest one over this buffer rather than the average (a headset mic on one
/// channel of two would otherwise come out at half the level, as the Mac's MicRecorder found).
fn mix(data: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return data.to_vec();
    }
    let energy = |channel: usize| data.iter().skip(channel).step_by(channels).map(|v| v * v).sum::<f32>();
    let energies: Vec<f32> = (0..channels).map(energy).collect();
    let (loudest, most) = energies.iter().enumerate().fold((0, 0.0f32), |best, (i, e)| if *e > best.1 { (i, *e) } else { best });
    let quietest = energies.iter().cloned().fold(f32::MAX, f32::min);
    if quietest * 4.0 < most {
        data.iter().skip(loudest).step_by(channels).copied().collect()
    } else {
        data.chunks(channels).map(|frame| frame.iter().sum::<f32>() / channels as f32).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::mix;

    #[test]
    fn mono_takes_the_live_channel() {
        // Left has the voice, right is silent: the voice, at full level.
        let stereo = [0.5, 0.0, -0.5, 0.0, 0.25, 0.0];
        assert_eq!(mix(&stereo, 2), vec![0.5, -0.5, 0.25]);
        // Both alike: averaged.
        assert_eq!(mix(&[0.2, 0.4, 0.2, 0.4], 2), vec![0.3, 0.3]);
        assert_eq!(mix(&[0.1, 0.2], 1), vec![0.1, 0.2]);
    }
}
