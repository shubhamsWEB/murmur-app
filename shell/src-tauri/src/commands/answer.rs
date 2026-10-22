//! The answer to a command (a question answered, a summary of the selected text, something that couldn't be done): a
//! small card near the bottom of the screen, as the Mac's answer panel, with Copy and Close. Its page is
//! ui/answer.html; it asks for the answer when it loads (`answer_text`) and is told new ones ("answer" events).
//! Unlike the pill it takes the focus, so Esc closes it and the text can be selected.

use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "answer";
const WIDTH: f64 = 520.0;
const HEIGHT: f64 = 220.0;
const ABOVE_BOTTOM: f64 = 64.0;

static LATEST: Mutex<String> = Mutex::new(String::new());

/// Makes the (hidden) window at launch, so showing an answer is quick.
pub fn make(app: &AppHandle) {
    let built = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("answer.html".into()))
        .title("Murmur")
        .inner_size(WIDTH, HEIGHT)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .build();
    if let Err(error) = built {
        eprintln!("murmur-shell: no answer window: {error}");
    }
}

/// Shows an answer.
pub fn show(app: &AppHandle, text: &str) {
    *LATEST.lock().unwrap() = text.trim().to_string();
    let Some(window) = app.get_webview_window(LABEL) else { return };
    let _ = app.emit_to(LABEL, "answer", text.trim());
    place(&window, HEIGHT);
    let _ = window.show();
    let _ = window.set_focus();
}

pub fn latest() -> String {
    LATEST.lock().unwrap().clone()
}

/// The page measured its text: the window fits it (up to a limit; past that, the page scrolls).
pub fn fit(app: &AppHandle, height: f64) {
    if let Some(window) = app.get_webview_window(LABEL) {
        let height = height.clamp(96.0, 520.0);
        let _ = window.set_size(tauri::LogicalSize::new(WIDTH, height));
        place(&window, height);
    }
}

pub fn close(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(LABEL) {
        let _ = window.hide();
    }
}

/// Bottom centre of the screen the pointer is on, above the taskbar (where the pill was).
fn place(window: &tauri::WebviewWindow, height: f64) {
    let monitor = window.cursor_position().ok()
        .and_then(|point| window.monitor_from_point(point.x, point.y).ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let (width, height) = ((WIDTH * scale) as i32, (height * scale) as i32);
    let x = area.position.x + (area.size.width as i32 - width) / 2;
    let y = area.position.y + area.size.height as i32 - height - (ABOVE_BOTTOM * scale) as i32;
    let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
}
