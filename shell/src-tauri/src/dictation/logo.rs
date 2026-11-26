//! The Murmur button on screen, as the Mac's FloatingLogo: a small charcoal capsule with the cream Starling, always on
//! top, that never takes the focus. Drag it anywhere (it stays where it's left). Rest the pointer on it and it opens
//! into three round buttons, icons only: the starling (open Murmur), a microphone (dictate) and a note (meeting notes;
//! a coral stop square while they're being taken), the one under the pointer named in a small label above it
//! (ui/logo.html). Right-click for its menu. When you dictate, the listening pill opens out of it, right where it is
//! (pill.rs centres itself on it), and the button hides while the pill is out: there's only ever one.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder, WindowEvent};

pub const LABEL: &str = "logo";
const WIDTH: f64 = 56.0;
const HEIGHT: f64 = 34.0;
/// Opened: the three buttons, with room above them for the label of the one under the pointer. The small button sits
/// at the bottom centre of this, so the capsule grows where it is.
const OPEN_WIDTH: f64 = 200.0;
const OPEN_HEIGHT: f64 = 72.0;
/// Above the taskbar, as the Mac's sits just above the Dock.
const ABOVE_BOTTOM: f64 = 12.0;

static ENABLED: AtomicBool = AtomicBool::new(false);
/// The listening pill is out (grown out of the button, in its place).
static PILL_OUT: AtomicBool = AtomicBool::new(false);
/// Opened (the window is the bigger one, around the small button's place).
static OPEN: AtomicBool = AtomicBool::new(false);
/// The small button's frame (x, y, width, height in physical pixels), kept while it's opened to go back to.
static SMALL: Mutex<Option<(i32, i32, i32, i32)>> = Mutex::new(None);
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
        super::pill::windows::remember(LABEL, hwnd.0 as _);
        super::pill::windows::never_activate(hwnd.0 as _);
    }
    place(&window, position);
    window.on_window_event(|event| {
        if let WindowEvent::Moved(position) = event {
            // Opening moves the window too: it's where the small button is left that's kept.
            if OPEN.load(Ordering::SeqCst) {
                return;
            }
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

/// Whether the button is on (Settings → Murmur button on screen).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn is_enabled() -> bool {
    ENABLED.load(Ordering::SeqCst)
}

/// Where the listening pill should open: the button's centre, while it's on. (Windows: `pill::windows::pill_spot`,
/// which doesn't wait on the window thread.)
#[cfg_attr(windows, allow(dead_code))]
pub fn anchor(app: &AppHandle) -> Option<PhysicalPosition<i32>> {
    if !ENABLED.load(Ordering::SeqCst) {
        return None;
    }
    if let Some((x, y, width, height)) = small_frame() {
        return Some(PhysicalPosition::new(x + width / 2, y + height / 2));
    }
    let window = app.get_webview_window(LABEL)?;
    let (position, size) = (window.outer_position().ok()?, window.outer_size().ok()?);
    Some(PhysicalPosition::new(position.x + size.width as i32 / 2, position.y + size.height as i32 / 2))
}

/// The small button's frame while it's opened (the listening pill opens out of that, not out of the opened one).
pub fn small_frame() -> Option<(i32, i32, i32, i32)> {
    *SMALL.lock().unwrap()
}

/// Opens the button into its three (the pointer came to rest on it) or makes it small again. Opening is asked for by
/// its page, on the window's thread; closing can come from anywhere. Says whether it's open now.
pub fn open(app: &AppHandle, on: bool) -> bool {
    let Some(window) = app.get_webview_window(LABEL) else { return false };
    if on {
        if OPEN.load(Ordering::SeqCst) {
            return true;
        }
        if !ENABLED.load(Ordering::SeqCst) || PILL_OUT.load(Ordering::SeqCst) {
            return false;
        }
        let (Ok(at), Ok(size)) = (window.outer_position(), window.outer_size()) else { return false };
        let scale = window.scale_factor().unwrap_or(1.0);
        let (width, height) = ((OPEN_WIDTH * scale).round() as i32, (OPEN_HEIGHT * scale).round() as i32);
        let mut x = at.x + (size.width as i32 - width) / 2;
        let mut y = at.y + size.height as i32 - height;
        if let Some(monitor) = window.current_monitor().ok().flatten() {
            let area = monitor.work_area();
            let right = area.position.x + area.size.width as i32 - width;
            x = x.min(right).max(area.position.x);
            y = y.max(area.position.y);
        }
        *SMALL.lock().unwrap() = Some((at.x, at.y, size.width as i32, size.height as i32));
        OPEN.store(true, Ordering::SeqCst);
        frame(&window, (x, y, width, height));
        #[cfg(windows)]
        watch_pointer(app);
        true
    } else {
        // Kept until the window is small again: the listening pill may be asking where to open meanwhile.
        let Some(small) = small_frame() else { return false };
        frame(&window, small);
        *SMALL.lock().unwrap() = None;
        OPEN.store(false, Ordering::SeqCst);
        let _ = app.emit_to(LABEL, "logo-open", false);
        false
    }
}

/// The window's place and size at once (Windows: straight from its handle, from any thread, in one step).
fn frame(window: &tauri::WebviewWindow, (x, y, width, height): (i32, i32, i32, i32)) {
    #[cfg(windows)]
    if let Some(hwnd) = super::pill::windows::handle(LABEL) {
        super::pill::windows::set_frame(hwnd, x, y, width, height);
        return;
    }
    let _ = window.set_size(tauri::PhysicalSize::new(width.max(1) as u32, height.max(1) as u32));
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

/// While it's opened: makes it small again once the pointer has been off it for about half a second. The page does
/// this itself when it's told the pointer left; this is for when a window that never takes the focus isn't told.
#[cfg(windows)]
fn watch_pointer(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let mut away = 0;
        while OPEN.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(120));
            let inside = super::pill::windows::handle(LABEL)
                .and_then(|hwnd| super::pill::windows::pointer_inside(hwnd, 6));
            away = if inside == Some(false) { away + 1 } else { 0 };
            if away >= 5 {
                open(&app, false);
                break;
            }
        }
    });
}

/// The listening pill came out (true) or went back (false): the button hides while it's out, small again.
pub fn pill_out(app: &AppHandle, out: bool) {
    PILL_OUT.store(out, Ordering::SeqCst);
    if out {
        open(app, false);
    }
    update(app);
}

fn update(app: &AppHandle) {
    let Some(window) = app.get_webview_window(LABEL) else { return };
    if ENABLED.load(Ordering::SeqCst) && !PILL_OUT.load(Ordering::SeqCst) {
        if !super::pill::is_shown(&window) {
            super::pill::show_quietly(&window);
        }
    } else {
        open(app, false);
        super::pill::hide_quietly(&window);
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
