//! Murmur's windows kept out of screen sharing and screen recordings (on unless turned off), as the Mac's
//! PrivateWindows: the dictation pill, answers, the Murmur button, the window, every window Murmur opens. What you
//! dictate, and what Murmur answers, stays on your screen and not on the call.
//!
//! It's Windows' own setting for a window (`SetWindowDisplayAffinity` with `WDA_EXCLUDEFROMCAPTURE`, Windows 10 2004
//! and later; what Electron's content protection sets): Teams, Zoom, Meet in a browser, OBS and the Snipping Tool
//! all capture the screen without it. Older Windows has only `WDA_MONITOR`, which shows the window as black instead.
//!
//! Set on each window from the window thread (where Windows wants it), and checked again every second for every
//! window Murmur has: a window made later, or one WebView2 made again, is covered too. Meeting notes' windows are
//! left out whatever the setting: what's on them is about the people on the call.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::{AppHandle, Manager};

static ON: AtomicBool = AtomicBool::new(true);

/// Windows that stay out of sharing whatever the setting.
pub const ALWAYS: [&str; 2] = [crate::meeting::PANEL, crate::meeting::OFFER];

pub fn is_on() -> bool {
    ON.load(Ordering::SeqCst)
}

/// Turns it on or off, for every window now.
pub fn set(app: &AppHandle, on: bool) {
    ON.store(on, Ordering::SeqCst);
    let main = app.clone();
    let _ = app.run_on_main_thread(move || apply_all(&main));
}

/// Every window as chosen (on the window thread).
pub fn apply_all(app: &AppHandle) {
    for (label, window) in app.webview_windows() {
        apply(&window, is_on() || ALWAYS.contains(&label.as_str()));
    }
}

/// Keeps every window as chosen, now and once a second.
pub fn watch(app: &AppHandle) {
    let app = app.clone();
    std::thread::Builder::new()
        .name("murmur-privacy".into())
        .spawn(move || loop {
            let main = app.clone();
            let _ = app.run_on_main_thread(move || apply_all(&main));
            std::thread::sleep(Duration::from_secs(1));
        })
        .ok();
}

#[cfg(windows)]
fn apply(window: &tauri::WebviewWindow, private: bool) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetWindowDisplayAffinity, SetWindowDisplayAffinity, WDA_EXCLUDEFROMCAPTURE, WDA_MONITOR, WDA_NONE,
    };
    let Ok(hwnd) = window.hwnd() else { return };
    let hwnd = hwnd.0 as windows_sys::Win32::Foundation::HWND;
    let wanted = if private { WDA_EXCLUDEFROMCAPTURE } else { WDA_NONE };
    let mut now = 0u32;
    unsafe {
        if GetWindowDisplayAffinity(hwnd, &mut now) != 0 && now == wanted {
            return;
        }
        // Before Windows 10 2004 there's no leaving it out, only showing it black.
        if SetWindowDisplayAffinity(hwnd, wanted) == 0 && private {
            SetWindowDisplayAffinity(hwnd, WDA_MONITOR);
        }
    }
}

#[cfg(not(windows))]
fn apply(_window: &tauri::WebviewWindow, _private: bool) {}
