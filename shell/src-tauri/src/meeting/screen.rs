//! A picture of the meeting, as the Mac's MeetingScreen: the meeting app's biggest window (where a shared slide or
//! chart shows), or the window in front when no meeting app is known. Taken from the screen as it's shown, so
//! Murmur's own windows (left out of captures) are never in it. At most 1600 pixels on its long side, as a PNG.
//!
//! For a model that doesn't look at pictures (the local one, Sarvam), its text, read on this PC by Windows' OCR.

use crate::ai::stream::Picture;

pub struct Shot {
    pub picture: Picture,
    /// "Zoom — Weekly sync": the app and the window's title.
    pub title: String,
}

/// The meeting app's window (by its program, "zoom.exe"), else the front window.
pub fn capture(program: Option<&str>) -> Option<Shot> {
    #[cfg(windows)]
    return windows::capture(program);
    #[cfg(not(windows))]
    {
        let _ = program;
        None
    }
}

/// The text in a picture, by Windows' OCR (written to a file for it, then deleted).
pub fn text(picture: &Picture) -> Option<String> {
    let path = std::env::temp_dir().join(format!("murmur-meeting-{}.png", std::process::id()));
    std::fs::write(&path, &picture.bytes).ok()?;
    let text = crate::ocr::read(&path.display().to_string()).ok();
    let _ = std::fs::remove_file(&path);
    text.map(|t| t.trim().to_string()).filter(|t| !t.is_empty())
}

#[cfg_attr(not(windows), allow(dead_code))]
/// RGBA pixels, `width` × `height`, scaled down to fit `largest` on the long side (averaging the pixels each one covers).
pub fn shrink(rgba: &[u8], width: usize, height: usize, largest: usize) -> (Vec<u8>, usize, usize) {
    let long = width.max(height);
    if long <= largest || width == 0 || height == 0 {
        return (rgba.to_vec(), width, height);
    }
    let scale = long as f64 / largest as f64;
    let (w, h) = (((width as f64 / scale) as usize).max(1), ((height as f64 / scale) as usize).max(1));
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let (y0, y1) = ((y as f64 * scale) as usize, (((y + 1) as f64 * scale) as usize).min(height).max((y as f64 * scale) as usize + 1));
        for x in 0..w {
            let (x0, x1) = ((x as f64 * scale) as usize, (((x + 1) as f64 * scale) as usize).min(width).max((x as f64 * scale) as usize + 1));
            let mut sum = [0u32; 4];
            let mut count = 0u32;
            for yy in y0..y1 {
                for xx in x0..x1 {
                    let i = (yy * width + xx) * 4;
                    for c in 0..4 {
                        sum[c] += rgba[i + c] as u32;
                    }
                    count += 1;
                }
            }
            let o = (y * w + x) * 4;
            for c in 0..4 {
                out[o + c] = (sum[c] / count.max(1)) as u8;
            }
        }
    }
    (out, w, h)
}

/// RGBA pixels as a PNG file.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn png(rgba: &[u8], width: usize, height: usize) -> Option<Vec<u8>> {
    let mut bytes = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut bytes, width as u32, height as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().ok()?;
        writer.write_image_data(rgba).ok()?;
    }
    Some(bytes)
}

#[cfg(windows)]
mod windows {
    use super::{png, shrink, Shot};
    use crate::ai::stream::Picture;
    use crate::commands::actions;
    use windows_sys::Win32::Foundation::{HWND, RECT};
    use windows_sys::Win32::Graphics::Gdi::{
        BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits, ReleaseDC,
        SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CAPTUREBLT, DIB_RGB_COLORS, SRCCOPY,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetWindowRect, IsIconic};

    pub fn capture(program: Option<&str>) -> Option<Shot> {
        let windows = actions::windows();
        let area = |w: &actions::Window| -> i64 {
            let mut rect = RECT { left: 0, top: 0, right: 0, bottom: 0 };
            unsafe { GetWindowRect(w.hwnd as HWND, &mut rect) };
            (rect.right - rect.left) as i64 * (rect.bottom - rect.top) as i64
        };
        let usable = |w: &&actions::Window| unsafe { IsIconic(w.hwnd as HWND) == 0 };
        let chosen = program.and_then(|program| {
            let program = program.to_lowercase();
            windows.iter().filter(usable)
                .filter(|w| w.program.to_lowercase().starts_with(program.trim_end_matches(".exe")))
                .max_by_key(|w| area(w))
                .cloned()
        }).or_else(|| windows.iter().find(usable).cloned())?;
        let mut rect = RECT { left: 0, top: 0, right: 0, bottom: 0 };
        unsafe { GetWindowRect(chosen.hwnd as HWND, &mut rect) };
        let (width, height) = ((rect.right - rect.left).max(0) as usize, (rect.bottom - rect.top).max(0) as usize);
        if width < 200 || height < 150 {
            return None;
        }
        let rgba = grab(rect.left, rect.top, width, height)?;
        let (rgba, w, h) = shrink(&rgba, width, height, 1600);
        let bytes = png(&rgba, w, h)?;
        Some(Shot { picture: Picture { bytes, media: "image/png" }, title: format!("{} — {}", actions::app_name(&chosen), chosen.title) })
    }

    /// The screen's pixels in a rectangle, as RGBA (what's shown there; windows left out of captures aren't).
    fn grab(x: i32, y: i32, width: usize, height: usize) -> Option<Vec<u8>> {
        unsafe {
            let screen = GetDC(std::ptr::null_mut());
            if screen.is_null() {
                return None;
            }
            let memory = CreateCompatibleDC(screen);
            let bitmap = CreateCompatibleBitmap(screen, width as i32, height as i32);
            let old = SelectObject(memory, bitmap as _);
            let copied = BitBlt(memory, 0, 0, width as i32, height as i32, screen, x, y, SRCCOPY | CAPTUREBLT) != 0;
            let mut info: BITMAPINFO = std::mem::zeroed();
            info.bmiHeader = BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width as i32,
                biHeight: -(height as i32), // top-down
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB,
                ..std::mem::zeroed()
            };
            let mut pixels = vec![0u8; width * height * 4];
            let lines = if copied {
                GetDIBits(memory, bitmap, 0, height as u32, pixels.as_mut_ptr() as _, &mut info, DIB_RGB_COLORS)
            } else {
                0
            };
            SelectObject(memory, old);
            DeleteObject(bitmap as _);
            DeleteDC(memory);
            ReleaseDC(std::ptr::null_mut(), screen);
            if lines == 0 {
                return None;
            }
            // BGRA → RGBA, opaque.
            for pixel in pixels.chunks_mut(4) {
                pixel.swap(0, 2);
                pixel[3] = 255;
            }
            Some(pixels)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shrinks_and_encodes() {
        let rgba = vec![200u8; 3200 * 100 * 4];
        let (out, w, h) = shrink(&rgba, 3200, 100, 1600);
        assert_eq!((w, h), (1600, 50));
        assert!(out.iter().all(|v| *v == 200));
        let file = png(&out, w, h).unwrap();
        assert_eq!(&file[1..4], b"PNG");
    }
}
