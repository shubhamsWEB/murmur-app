//! A meeting's two sides of sound, as the Mac's LiveMicrophone and CallAudio: your microphone, and what the PC plays
//! (the call), heard through Windows' loopback capture of the speakers (WASAPI loopback: cpal opens an input stream on
//! the output device). Each runs on a thread of its own and hands its sound, mono, to a handler as it comes.
//!
//! The loopback hears everything the PC plays, from every app (notification sounds too): the call is most of it while
//! a call is on.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;
use std::sync::mpsc;
use std::time::Duration;

/// A live stream of sound; dropping it stops it.
pub struct Live {
    stop: Option<mpsc::Sender<()>>,
    pub rate: u32,
    pub device: String,
}

impl Drop for Live {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

/// Which side.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Side {
    /// The microphone named (or the default).
    Microphone,
    /// What the PC plays, from its default speakers or headphones.
    Call,
}

/// Starts one side. `make` is told the sample rate and gives the handler for the sound.
pub fn start<H>(side: Side, microphone: &str, make: impl FnOnce(u32) -> H + Send + 'static) -> Result<Live, String>
where
    H: FnMut(&[f32]) + Send + 'static,
{
    let (stop, stopped) = mpsc::channel::<()>();
    let (ready, opened) = mpsc::channel::<Result<(u32, String), String>>();
    let wanted = microphone.to_string();
    std::thread::Builder::new()
        .name(if side == Side::Call { "murmur-meeting-call" } else { "murmur-meeting-mic" }.into())
        .spawn(move || {
            let opened = open(side, &wanted, make);
            match opened {
                Ok((stream, rate, name)) => {
                    let _ = ready.send(Ok((rate, name)));
                    let _ = stopped.recv();
                    drop(stream);
                }
                Err(error) => {
                    let _ = ready.send(Err(error));
                }
            }
        })
        .map_err(|error| format!("can't start the sound's thread: {error}"))?;
    let (rate, device) = opened.recv_timeout(Duration::from_secs(5)).map_err(|_| "the sound didn't start".to_string())??;
    Ok(Live { stop: Some(stop), rate, device })
}

fn open<H>(side: Side, wanted: &str, make: impl FnOnce(u32) -> H) -> Result<(cpal::Stream, u32, String), String>
where
    H: FnMut(&[f32]) + Send + 'static,
{
    let host = cpal::default_host();
    let device = match side {
        Side::Microphone => (!wanted.is_empty())
            .then(|| host.input_devices().ok()?.find(|device| device.to_string() == wanted))
            .flatten()
            .or_else(|| host.default_input_device())
            .ok_or("there's no microphone")?,
        Side::Call => host.default_output_device().ok_or("there are no speakers to listen to")?,
    };
    let name = device.to_string();
    let config = match side {
        Side::Microphone => device.default_input_config(),
        Side::Call => device.default_output_config(),
    }
    .map_err(|error| format!("{name} can't be heard: {error}"))?;
    let channels = config.channels() as usize;
    let rate = config.sample_rate();
    let format = config.sample_format();
    let config: cpal::StreamConfig = config.into();
    let mut handler = make(rate);
    let mut take = move |floats: &[f32]| handler(&mono(floats, channels));
    let failed = |error: cpal::Error| eprintln!("murmur-shell: meeting sound: {error}");
    let stream = match format {
        SampleFormat::F32 => device.build_input_stream(config, move |data: &[f32], _: &_| take(data), failed, None),
        SampleFormat::I16 => device.build_input_stream(config, move |data: &[i16], _: &_| {
            take(&data.iter().map(|v| *v as f32 / 32768.0).collect::<Vec<_>>())
        }, failed, None),
        SampleFormat::U16 => device.build_input_stream(config, move |data: &[u16], _: &_| {
            take(&data.iter().map(|v| (*v as f32 - 32768.0) / 32768.0).collect::<Vec<_>>())
        }, failed, None),
        SampleFormat::I32 => device.build_input_stream(config, move |data: &[i32], _: &_| {
            take(&data.iter().map(|v| *v as f32 / 2_147_483_648.0).collect::<Vec<_>>())
        }, failed, None),
        other => return Err(format!("{name} plays in a format Murmur doesn't read ({other})")),
    }
    .map_err(|error| format!("can't listen to {name}: {error}"))?;
    stream.play().map_err(|error| format!("can't start {name}: {error}"))?;
    Ok((stream, rate, name))
}

/// The channels averaged into one.
fn mono(data: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return data.to_vec();
    }
    data.chunks(channels).map(|frame| frame.iter().sum::<f32>() / channels as f32).collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn channels_averaged() {
        assert_eq!(super::mono(&[0.2, 0.4, 0.0, 1.0], 2), vec![0.3, 0.5]);
    }
}
