//! The pill: a small window near the bottom of the screen showing what dictation is doing (the Mac's DictationHUD;
//! its page is ui/pill.html, which draws and animates it). It never takes the focus, so the words still go where the
//! person was typing, and clicks go through it. The page is told what to show; the window is hidden once the page's
//! closing animation is through. With the Murmur button on (logo.rs), the pill opens out of it, where it is, and the
//! button hides while the pill is out.

use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "pill";
const WIDTH: f64 = 520.0;
const HEIGHT: f64 = 72.0;
/// Above the taskbar, as the Mac's sits above the Dock.
const ABOVE_BOTTOM: f64 = 64.0;
/// The page's closing animation.
const CLOSING: Duration = Duration::from_millis(260);

/// Bumped by every show and hide, so a hide scheduled for one never hides the next.
static GENERATION: AtomicU64 = AtomicU64::new(0);

pub fn make(app: &AppHandle) -> tauri::Result<()> {
    let window = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("pill.html".into()))
        .title("Murmur")
        .inner_size(WIDTH, HEIGHT)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build()?;
    let _ = window.set_ignore_cursor_events(true);
    #[cfg(windows)]
    if let Ok(hwnd) = window.hwnd() {
        windows::never_activate(hwnd.0 as _);
    }
    Ok(())
}

/// Shows the pill (opening it if it's closed) with `mode` (listening, starting, working, message) and its words.
pub fn show(app: &AppHandle, mode: &str, text: &str) {
    send(app, json!({"mode": mode, "text": text}));
}

/// A message for `seconds`, then the pill closes. `tone`: info, done or problem.
pub fn flash(app: &AppHandle, text: &str, tone: &str, seconds: f64) {
    let generation = send(app, json!({"mode": "message", "text": text, "tone": tone}));
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs_f64(seconds));
        if GENERATION.load(Ordering::SeqCst) == generation {
            hide(&app);
        }
    });
}

/// The microphone's level, 0…1, for the listening bird.
pub fn level(app: &AppHandle, level: f32) {
    let _ = app.emit_to(LABEL, "pill-level", level);
}

/// Closes the pill: the page animates it shut, then the window goes.
pub fn hide(app: &AppHandle) {
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    let _ = app.emit_to(LABEL, "pill", json!({"mode": "hidden"}));
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(CLOSING);
        if GENERATION.load(Ordering::SeqCst) == generation {
            if let Some(window) = app.get_webview_window(LABEL) {
                hide_quietly(&window);
            }
            super::logo::pill_out(&app, false);
        }
    });
}

fn send(app: &AppHandle, state: serde_json::Value) -> u64 {
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    if let Some(window) = app.get_webview_window(LABEL) {
        if !is_shown(&window) {
            place(app, &window);
            show_quietly(&window);
        }
    }
    let _ = app.emit_to(LABEL, "pill", state);
    super::logo::pill_out(app, true);
    generation
}

/// Centred on the Murmur button when it's on (the pill's closed capsule is the button's size, so it grows out of it);
/// otherwise bottom centre of the screen the pointer is on, above the taskbar.
fn place(app: &AppHandle, window: &tauri::WebviewWindow) {
    if let Some(centre) = super::logo::anchor(app) {
        let scale = window.monitor_from_point(centre.x as f64, centre.y as f64).ok().flatten()
            .map_or(1.0, |monitor| monitor.scale_factor());
        let (width, height) = ((WIDTH * scale) as i32, (HEIGHT * scale) as i32);
        let _ = window.set_position(tauri::PhysicalPosition::new(centre.x - width / 2, centre.y - height / 2));
        return;
    }
    let monitor = window
        .cursor_position()
        .ok()
        .and_then(|point| window.monitor_from_point(point.x, point.y).ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let width = (WIDTH * scale) as i32;
    let height = (HEIGHT * scale) as i32;
    let x = area.position.x + (area.size.width as i32 - width) / 2;
    let y = area.position.y + area.size.height as i32 - height - (ABOVE_BOTTOM * scale) as i32;
    let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
}

/// The pill's and the Murmur button's windows on Windows: bare popups (no title bar, frame or rounded outline) that
/// are never activated and aren't in Alt+Tab, shown and hidden here rather than through Tauri, which puts its own window
/// style back when it shows or hides a window (with a title bar: the Murmur button came out as a tiny "Murmur" title bar
/// with a close button).
#[cfg(windows)]
pub(super) mod windows {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_BORDER_COLOR, DWMWA_WINDOW_CORNER_PREFERENCE};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, IsWindowVisible, SetWindowLongPtrW, SetWindowPos, ShowWindow, GWL_EXSTYLE, GWL_STYLE,
        HWND_TOPMOST, SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, SW_HIDE,
        SW_SHOWNOACTIVATE, WS_BORDER, WS_CAPTION, WS_DLGFRAME, WS_EX_APPWINDOW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
        WS_EX_WINDOWEDGE, WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU, WS_THICKFRAME,
    };

    /// A bare popup, never activated, not in Alt+Tab; no rounded corners or outline on Windows 11.
    pub fn never_activate(hwnd: HWND) {
        unsafe {
            let frame = (WS_CAPTION | WS_BORDER | WS_DLGFRAME | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX
                | WS_MAXIMIZEBOX) as isize;
            let style = GetWindowLongPtrW(hwnd, GWL_STYLE);
            SetWindowLongPtrW(hwnd, GWL_STYLE, (style & !frame) | WS_POPUP as isize);
            let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE,
                              (ex & !((WS_EX_APPWINDOW | WS_EX_WINDOWEDGE) as isize))
                                  | (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) as isize);
            let square: u32 = 1; // DWMWCP_DONOTROUND
            let no_border: u32 = 0xFFFF_FFFE; // DWMWA_COLOR_NONE
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE as u32, &square as *const u32 as _, 4);
            DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR as u32, &no_border as *const u32 as _, 4);
            SetWindowPos(hwnd, std::ptr::null_mut(), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
    }

    /// Shown on top without taking the focus from the app the person is typing in.
    pub fn show_without_activating(hwnd: HWND) {
        never_activate(hwnd);
        unsafe {
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
    }

    pub fn hide(hwnd: HWND) {
        unsafe {
            ShowWindow(hwnd, SW_HIDE);
        }
    }

    pub fn visible(hwnd: HWND) -> bool {
        unsafe { IsWindowVisible(hwnd) != 0 }
    }
}

/// Shown without taking the focus (on Windows, as a bare popup: `windows`). On Windows the window's own thread does it,
/// later: restyling or showing a window from another thread waits on that thread's answer, and dictation's thread,
/// waiting so as it opened the pill, stopped hearing the key altogether.
pub(super) fn show_quietly(window: &tauri::WebviewWindow) {
    #[cfg(windows)]
    {
        let target = window.clone();
        let _ = window.run_on_main_thread(move || {
            if let Ok(hwnd) = target.hwnd() {
                windows::show_without_activating(hwnd.0 as _);
            }
        });
    }
    #[cfg(not(windows))]
    let _ = window.show();
}

pub(super) fn hide_quietly(window: &tauri::WebviewWindow) {
    #[cfg(windows)]
    {
        let target = window.clone();
        let _ = window.run_on_main_thread(move || {
            if let Ok(hwnd) = target.hwnd() {
                windows::hide(hwnd.0 as _);
            }
        });
    }
    #[cfg(not(windows))]
    let _ = window.hide();
}

pub(super) fn is_shown(window: &tauri::WebviewWindow) -> bool {
    #[cfg(windows)]
    if let Ok(hwnd) = window.hwnd() {
        return windows::visible(hwnd.0 as _);
    }
    window.is_visible().unwrap_or(false)
}
