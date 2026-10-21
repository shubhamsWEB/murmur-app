//! The Murmur button on screen, as the Mac's FloatingLogo: a small charcoal capsule with the cream Starling, always on
//! top, that never takes the focus. Drag it anywhere (it stays where it's left); click it to open Murmur; right-click
//! for its menu (ui/logo.html). When you dictate, the listening pill opens out of it, right where it is (pill.rs centres
//! itself on it), and the button hides while the pill is out: there's only ever one.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder, WindowEvent};

pub const LABEL: &str = "logo";
const WIDTH: f64 = 56.0;
const HEIGHT: f64 = 34.0;
/// Above the taskbar, as the Mac's sits just above the Dock.
const ABOVE_BOTTOM: f64 = 12.0;

static ENABLED: AtomicBool = AtomicBool::new(false);
/// The listening pill is out (grown out of the button, in its place).
static PILL_OUT: AtomicBool = AtomicBool::new(false);
/// Bumped by every move, so only the last one of a drag is saved.
static MOVES: AtomicU64 = AtomicU64::new(0);
/// Where it was left: saved in the settings by the shell.
type Save = Box<dyn Fn(i32, i32) + Send + Sync>;
static SAVE: Mutex<Option<Save>> = Mutex::new(None);

/// Makes the button's window (hidden), at `position` (where it was left) when that's still on a screen. `save` keeps
/// where it's dragged to.
pub fn make(app: &AppHandle, position: Option<(i32, i32)>, save: impl Fn(i32, i32) + Send + Sync + 'static) -> tauri::Result<()> {
    *SAVE.lock().unwrap() = Some(Box::new(save));
    let window = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("logo.html".into()))
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
    #[cfg(windows)]
    if let Ok(hwnd) = window.hwnd() {
        super::pill::windows::never_activate(hwnd.0 as _);
    }
    place(&window, position);
    window.on_window_event(|event| {
        if let WindowEvent::Moved(position) = event {
            let (x, y) = (position.x, position.y);
            let generation = MOVES.fetch_add(1, Ordering::SeqCst) + 1;
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(600));
                if MOVES.load(Ordering::SeqCst) == generation {
                    if let Some(save) = SAVE.lock().unwrap().as_ref() {
                        save(x, y);
                    }
                }
            });
        }
    });
    Ok(())
}

/// Turned on or off (Settings → Murmur button on screen, or its menu's Hide).
pub fn set_enabled(app: &AppHandle, on: bool) {
    ENABLED.store(on, Ordering::SeqCst);
    update(app);
}

/// Where the listening pill should open: the button's centre, while it's on.
pub fn anchor(app: &AppHandle) -> Option<PhysicalPosition<i32>> {
    if !ENABLED.load(Ordering::SeqCst) {
        return None;
    }
    let window = app.get_webview_window(LABEL)?;
    let (position, size) = (window.outer_position().ok()?, window.outer_size().ok()?);
    Some(PhysicalPosition::new(position.x + size.width as i32 / 2, position.y + size.height as i32 / 2))
}

/// The listening pill came out (true) or went back (false): the button hides while it's out.
pub fn pill_out(app: &AppHandle, out: bool) {
    PILL_OUT.store(out, Ordering::SeqCst);
    update(app);
}

fn update(app: &AppHandle) {
    let Some(window) = app.get_webview_window(LABEL) else { return };
    if ENABLED.load(Ordering::SeqCst) && !PILL_OUT.load(Ordering::SeqCst) {
        if !window.is_visible().unwrap_or(false) {
            #[cfg(windows)]
            if let Ok(hwnd) = window.hwnd() {
                super::pill::windows::show_without_activating(hwnd.0 as _);
            }
            #[cfg(not(windows))]
            let _ = window.show();
        }
    } else {
        let _ = window.hide();
    }
}

/// Where it was left, if half of it is still on a screen; otherwise bottom centre of the main screen, above the taskbar.
fn place(window: &tauri::WebviewWindow, saved: Option<(i32, i32)>) {
    if let Some((x, y)) = saved {
        let on_screen = window.available_monitors().unwrap_or_default().iter().any(|monitor| {
            let (area, scale) = (monitor.work_area(), monitor.scale_factor());
            let (w, h) = ((WIDTH * scale) as i32, (HEIGHT * scale) as i32);
            x + w / 2 >= area.position.x && x + w / 2 <= area.position.x + area.size.width as i32
                && y >= area.position.y && y + h / 2 <= area.position.y + area.size.height as i32
        });
        if on_screen {
            let _ = window.set_position(PhysicalPosition::new(x, y));
            return;
        }
    }
    let Some(monitor) = window.primary_monitor().ok().flatten() else { return };
    let (area, scale) = (monitor.work_area(), monitor.scale_factor());
    let (w, h) = ((WIDTH * scale) as i32, (HEIGHT * scale) as i32);
    let x = area.position.x + (area.size.width as i32 - w) / 2;
    let y = area.position.y + area.size.height as i32 - h - (ABOVE_BOTTOM * scale) as i32;
    let _ = window.set_position(PhysicalPosition::new(x, y));
}
