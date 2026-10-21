//! The dictation key: held to talk, as the Mac app's Fn key is. Windows has no Fn key it tells apps about, so the
//! default is Ctrl + Windows (the keys Wispr Flow uses there), or Right Ctrl, or Right Alt, chosen in Settings.
//!
//! A low-level keyboard hook (on a thread of its own, with the message loop it needs) sees every key going down and
//! up. The combination held means Down; letting go of it means Up. Another key pressed while it's held means the
//! person was using a shortcut (Ctrl + Windows + D, Ctrl + Windows + →), so that's Cancel. Keys Murmur sends itself
//! (the paste) are passed over. Nothing is swallowed: other apps see every key as before.

// The hook is Windows' only, for now: elsewhere the tracking is there (and tested) but nothing calls it.
#![cfg_attr(not(windows), allow(dead_code))]

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Press {
    Down,
    Up,
    Cancel,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Combo {
    CtrlWin,
    RightCtrl,
    RightAlt,
}

// Virtual-key codes (WinUser.h), as the hook reports them: the left and right keys apart.
const LCONTROL: u32 = 0xA2;
const RCONTROL: u32 = 0xA3;
const CONTROL: u32 = 0x11;
const LWIN: u32 = 0x5B;
const RWIN: u32 = 0x5C;
const RMENU: u32 = 0xA5;

impl Combo {
    pub const ALL: [Combo; 3] = [Combo::CtrlWin, Combo::RightCtrl, Combo::RightAlt];

    pub fn from_name(name: &str) -> Combo {
        match name {
            "right-ctrl" => Combo::RightCtrl,
            "right-alt" => Combo::RightAlt,
            _ => Combo::CtrlWin,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Combo::CtrlWin => "ctrl+win",
            Combo::RightCtrl => "right-ctrl",
            Combo::RightAlt => "right-alt",
        }
    }

    /// As Settings and the pill say it.
    pub fn title(self) -> &'static str {
        match self {
            Combo::CtrlWin => "Ctrl + Windows",
            Combo::RightCtrl => "Right Ctrl",
            Combo::RightAlt => "Right Alt",
        }
    }

    /// The keys that make it: one of each group held.
    fn groups(self) -> &'static [&'static [u32]] {
        match self {
            Combo::CtrlWin => &[&[LCONTROL, RCONTROL, CONTROL], &[LWIN, RWIN]],
            Combo::RightCtrl => &[&[RCONTROL]],
            Combo::RightAlt => &[&[RMENU]],
        }
    }

    fn contains(self, key: u32) -> bool {
        self.groups().iter().any(|group| group.contains(&key))
    }

    /// Keys that may be down alongside without making it a shortcut: Right Alt is AltGr on many layouts, which
    /// Windows sends as Left Ctrl + Right Alt.
    fn tolerates(self, key: u32) -> bool {
        self == Combo::RightAlt && key == LCONTROL
    }
}

/// What the keys add up to, event by event: kept apart from the hook so it can be tested.
pub struct Tracker {
    down: HashSet<u32>,
    active: bool,
}

impl Tracker {
    pub fn new() -> Tracker {
        Tracker { down: HashSet::new(), active: false }
    }

    /// A key went down (`pressed`) or up. Returns what that means for dictation, if anything.
    pub fn key(&mut self, combo: Combo, key: u32, pressed: bool) -> Option<Press> {
        let repeat = pressed && self.down.contains(&key);
        if pressed { self.down.insert(key); } else { self.down.remove(&key); }
        if repeat {
            return None;
        }
        let held = combo.groups().iter().all(|group| group.iter().any(|k| self.down.contains(k)));
        if self.active {
            if pressed && !combo.contains(key) && !combo.tolerates(key) {
                self.active = false;
                return Some(Press::Cancel);
            }
            if !held {
                self.active = false;
                return Some(Press::Up);
            }
            return None;
        }
        // Starts only when the combination is all that's down (Ctrl + Windows with Shift held is something else).
        let extra = self.down.iter().any(|k| !combo.contains(*k) && !combo.tolerates(*k));
        if pressed && held && !extra {
            self.active = true;
            return Some(Press::Down);
        }
        None
    }
}

/// Starts watching the keyboard for `combo` (changeable while it runs), calling `on` for each Down, Up and Cancel.
#[cfg(windows)]
pub fn listen(combo: Arc<Mutex<Combo>>, on: impl Fn(Press) + Send + Sync + 'static) -> Result<(), String> {
    hook::start(combo, Box::new(on))
}

#[cfg(not(windows))]
pub fn listen(_combo: Arc<Mutex<Combo>>, _on: impl Fn(Press) + Send + Sync + 'static) -> Result<(), String> {
    Err("the dictation key works on Windows for now".into())
}

#[cfg(windows)]
mod hook {
    use super::{Combo, Press, Tracker};
    use std::sync::{Arc, Mutex, OnceLock};
    use windows_sys::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW, TranslateMessage, HC_ACTION,
        KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP,
    };

    struct Hooked {
        combo: Arc<Mutex<Combo>>,
        on: Box<dyn Fn(Press) + Send + Sync>,
        tracker: Mutex<Tracker>,
    }

    static HOOKED: OnceLock<Hooked> = OnceLock::new();

    pub fn start(combo: Arc<Mutex<Combo>>, on: Box<dyn Fn(Press) + Send + Sync>) -> Result<(), String> {
        if HOOKED.set(Hooked { combo, on, tracker: Mutex::new(Tracker::new()) }).is_err() {
            return Ok(()); // already listening
        }
        let (ready, started) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("murmur-dictation-key".into())
            .spawn(move || unsafe {
                let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(callback), GetModuleHandleW(std::ptr::null()), 0);
                let _ = ready.send(!hook.is_null());
                if hook.is_null() {
                    return;
                }
                // A low-level hook is called on the thread that set it, through its message loop.
                let mut message: MSG = std::mem::zeroed();
                while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
                    TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
            })
            .map_err(|error| format!("can't start the key watcher: {error}"))?;
        match started.recv() {
            Ok(true) => Ok(()),
            _ => Err("Windows didn't let Murmur watch the dictation key".into()),
        }
    }

    unsafe extern "system" fn callback(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code == HC_ACTION as i32 {
            if let Some(hooked) = HOOKED.get() {
                let info = &*(lparam as *const KBDLLHOOKSTRUCT);
                let message = wparam as u32;
                let pressed = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
                let released = message == WM_KEYUP || message == WM_SYSKEYUP;
                if (pressed || released) && info.flags & LLKHF_INJECTED == 0 {
                    let combo = *hooked.combo.lock().unwrap();
                    // Kept short: Windows drops a hook that takes too long. `on` only hands the press on.
                    let press = hooked.tracker.lock().unwrap().key(combo, info.vkCode, pressed);
                    if let Some(press) = press {
                        (hooked.on)(press);
                    }
                }
            }
        }
        CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hold_and_let_go() {
        let mut keys = Tracker::new();
        assert_eq!(keys.key(Combo::CtrlWin, LCONTROL, true), None);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, true), Some(Press::Down));
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, true), None); // auto-repeat
        assert_eq!(keys.key(Combo::CtrlWin, LCONTROL, true), None);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, false), Some(Press::Up));
        assert_eq!(keys.key(Combo::CtrlWin, LCONTROL, false), None);
    }

    #[test]
    fn a_shortcut_cancels() {
        let mut keys = Tracker::new();
        keys.key(Combo::CtrlWin, LCONTROL, true);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, true), Some(Press::Down));
        assert_eq!(keys.key(Combo::CtrlWin, 0x44, true), Some(Press::Cancel)); // D: show the desktop
        assert_eq!(keys.key(Combo::CtrlWin, 0x44, false), None);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, false), None);
    }

    #[test]
    fn not_with_other_keys_already_down() {
        let mut keys = Tracker::new();
        keys.key(Combo::CtrlWin, 0xA0, true); // Left Shift
        keys.key(Combo::CtrlWin, LCONTROL, true);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, true), None);
    }

    #[test]
    fn right_alt_is_altgr_too() {
        let mut keys = Tracker::new();
        // AltGr: Windows sends Left Ctrl, then Right Alt.
        assert_eq!(keys.key(Combo::RightAlt, LCONTROL, true), None);
        assert_eq!(keys.key(Combo::RightAlt, RMENU, true), Some(Press::Down));
        assert_eq!(keys.key(Combo::RightAlt, RMENU, false), Some(Press::Up));
        assert_eq!(keys.key(Combo::RightAlt, LCONTROL, false), None); // AltGr's Left Ctrl goes up with it
        // Right Ctrl alone.
        assert_eq!(keys.key(Combo::RightCtrl, RCONTROL, true), Some(Press::Down));
        assert_eq!(keys.key(Combo::RightCtrl, RCONTROL, false), Some(Press::Up));
    }

    #[test]
    fn names_round_trip() {
        for combo in Combo::ALL {
            assert_eq!(Combo::from_name(combo.name()), combo);
        }
        assert_eq!(Combo::from_name(""), Combo::CtrlWin);
    }
}
