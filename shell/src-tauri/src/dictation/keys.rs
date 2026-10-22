//! The dictation key: held to talk, as the Mac app's Fn key is. Windows has no Fn key it tells apps about, so the
//! default is Ctrl + Windows (the keys Wispr Flow uses there), or Right Ctrl, or Right Alt, chosen in Settings.
//!
//! A low-level keyboard hook (on a thread of its own, with the message loop it needs) sees every key going down and
//! up. The combination held means Down; letting go of it means Up. Another key pressed while it's held means the
//! person was using a shortcut (Ctrl + Windows + D, Ctrl + Windows + →), so that's Cancel. Keys Murmur sends itself
//! (the paste) are passed over. Nothing is swallowed: other apps see every key as before.
//!
//! Windows removes a low-level hook, silently, if it ever answers too slowly (LowLevelHooksTimeout): after Murmur has
//! sat idle for hours its memory is paged out, and the first key press can take that long. Nothing says so; the key
//! simply stops working until Murmur restarts. So a watchdog on the hook's thread (`Watch`) compares, five times a
//! second, what the hook has heard with the keyboard as it really is: the combination held but never heard means the
//! hook is gone, and it's put back at once and that press goes ahead; a release never heard ends the dictation rather
//! than leaving it listening. The hook is also renewed every few minutes while nothing is held.

// The hook is Windows' only, for now: elsewhere the tracking is there (and tested) but nothing calls it.
#![cfg_attr(not(windows), allow(dead_code))]

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Press {
    Down,
    Up,
    Cancel,
    /// Esc, whenever it's pressed: it cancels hands-free dictation.
    Escape,
    /// The hook had stopped hearing keys (Windows dropped it) and was put back: for the log. A Down follows.
    Revived,
    /// Shift pressed while the dictation key is held: what's said is a command (as ⌃ with Fn on the Mac).
    Command,
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
const SHIFTS: [u32; 3] = [0x10, 0xA0, 0xA1];
#[cfg_attr(not(windows), allow(dead_code))]
const ESCAPE: u32 = 0x1B;

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

    /// As a number, for a value read without a lock in the hook.
    pub fn index(self) -> u8 {
        Combo::ALL.iter().position(|c| *c == self).unwrap_or(0) as u8
    }

    pub fn from_index(index: u8) -> Combo {
        Combo::ALL.get(index as usize).copied().unwrap_or(Combo::CtrlWin)
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
    /// Shift was pressed during this dictation (Command given).
    commanded: bool,
}

impl Tracker {
    pub fn new() -> Tracker {
        Tracker { down: HashSet::new(), active: false, commanded: false }
    }

    /// A key went down (`pressed`) or up. Returns what that means for dictation, if anything.
    /// A key went down (`pressed`) or up. `still_down` says whether another key is really held now: a key let go
    /// while an administrator's window or a Windows prompt (UAC, the lock screen) had the keyboard is never seen going
    /// up, and remembered as held it blocked dictation, with any key, until Murmur restarted.
    pub fn key(&mut self, combo: Combo, key: u32, pressed: bool, still_down: impl Fn(u32) -> bool) -> Option<Press> {
        self.down.retain(|k| *k == key || still_down(*k));
        let repeat = pressed && self.down.contains(&key);
        if pressed { self.down.insert(key); } else { self.down.remove(&key); }
        if repeat {
            return None;
        }
        let held = combo.groups().iter().all(|group| group.iter().any(|k| self.down.contains(k)));
        if self.active {
            // Shift added to the held key: a command. Pressed again, nothing more.
            if pressed && SHIFTS.contains(&key) && !combo.contains(key) {
                if self.commanded {
                    return None;
                }
                self.commanded = true;
                return Some(Press::Command);
            }
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
            self.commanded = false;
            return Some(Press::Down);
        }
        None
    }

    /// Whether a dictation is held (Down given, no Up or Cancel yet).
    pub fn is_active(&self) -> bool {
        self.active
    }

    /// Whether any key is remembered as held.
    pub fn is_idle(&self) -> bool {
        !self.active && self.down.is_empty()
    }
}

/// What the watchdog found on one look at the keyboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fix {
    /// The hook and the keyboard agree.
    Fine,
    /// A dictation is held, but the combination was let go without the hook hearing it: end it.
    Up,
    /// The combination is held, on its own, but the hook never heard it go down: the hook is gone. Put it back and
    /// treat this as the press.
    Revive,
}

/// The watchdog's memory between looks: a mismatch must last two looks (about 300 ms) before it counts, since the
/// keyboard's state is only updated after the hook has been told about a key.
pub struct Watch {
    held: u32,
    free: u32,
}

const LOOKS: u32 = 2;

impl Watch {
    pub fn new() -> Watch {
        Watch { held: 0, free: 0 }
    }

    /// One look. `is_down`: whether a key is held right now (GetAsyncKeyState); `others`: whether any key outside the
    /// combination is held. Updates `tracker` to match what it decides.
    pub fn look(&mut self, tracker: &mut Tracker, combo: Combo, is_down: impl Fn(u32) -> bool, others: bool) -> Fix {
        tracker.down.retain(|k| is_down(*k));
        let held = combo.groups().iter().all(|group| group.iter().any(|k| is_down(*k)));
        if tracker.active {
            self.held = 0;
            if held {
                self.free = 0;
                return Fix::Fine;
            }
            self.free += 1;
            if self.free < LOOKS {
                return Fix::Fine;
            }
            self.free = 0;
            tracker.active = false;
            return Fix::Up;
        }
        self.free = 0;
        let heard = combo.groups().iter().all(|group| group.iter().any(|k| tracker.down.contains(k)));
        if !held || heard || others {
            self.held = 0;
            return Fix::Fine;
        }
        self.held += 1;
        if self.held < LOOKS {
            return Fix::Fine;
        }
        self.held = 0;
        for group in combo.groups() {
            for key in group.iter().filter(|k| is_down(**k)) {
                tracker.down.insert(*key);
            }
        }
        tracker.active = true;
        tracker.commanded = false;
        Fix::Revive
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
    use super::{Combo, Fix, Press, Tracker, Watch, ESCAPE};
    use std::ffi::c_void;
    use std::sync::atomic::{AtomicPtr, AtomicU8, Ordering};
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::System::Threading::{GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_HIGHEST};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetMessageW, SetTimer, SetWindowsHookExW, TranslateMessage,
        UnhookWindowsHookEx, HC_ACTION, KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP,
        WM_SYSKEYDOWN, WM_SYSKEYUP, WM_TIMER,
    };

    /// How often the watchdog looks at the keyboard.
    const LOOK_EVERY_MS: u32 = 150;
    /// The hook is renewed this often while nothing is held, before Windows has a chance to have dropped it.
    const RENEW_EVERY: Duration = Duration::from_secs(5 * 60);

    struct Hooked {
        combo: Arc<Mutex<Combo>>,
        /// The combination as last read, for when Settings holds the lock: the hook never waits on a lock.
        last_combo: AtomicU8,
        on: Box<dyn Fn(Press) + Send + Sync>,
        tracker: Mutex<Tracker>,
    }

    static HOOKED: OnceLock<Hooked> = OnceLock::new();
    static HOOK: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

    pub fn start(combo: Arc<Mutex<Combo>>, on: Box<dyn Fn(Press) + Send + Sync>) -> Result<(), String> {
        let last_combo = AtomicU8::new(combo.lock().map(|c| c.index()).unwrap_or(0));
        if HOOKED.set(Hooked { combo, last_combo, on, tracker: Mutex::new(Tracker::new()) }).is_err() {
            return Ok(()); // already listening
        }
        let (ready, started) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("murmur-dictation-key".into())
            .spawn(move || unsafe {
                // Answering Windows quickly is this thread's whole job.
                SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
                let _ = ready.send(install());
                if HOOK.load(Ordering::SeqCst).is_null() {
                    return;
                }
                SetTimer(std::ptr::null_mut(), 0, LOOK_EVERY_MS, None);
                let mut watch = Watch::new();
                let mut renewed = Instant::now();
                // A low-level hook is called on the thread that set it, through its message loop; the watchdog's
                // timer arrives through the same loop, so the two never run at once.
                let mut message: MSG = std::mem::zeroed();
                while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
                    if message.message == WM_TIMER && message.hwnd.is_null() {
                        look(&mut watch, &mut renewed);
                        continue;
                    }
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

    /// Sets the hook (again), dropping the old one if Windows hasn't already. On the hook's thread only.
    unsafe fn install() -> bool {
        let old = HOOK.swap(std::ptr::null_mut(), Ordering::SeqCst);
        if !old.is_null() {
            UnhookWindowsHookEx(old);
        }
        let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(callback), GetModuleHandleW(std::ptr::null()), 0);
        HOOK.store(hook, Ordering::SeqCst);
        !hook.is_null()
    }

    fn is_down(key: u32) -> bool {
        unsafe { (GetAsyncKeyState(key as i32) as u16) & 0x8000 != 0 }
    }

    /// Any key held besides the combination's (and the generic Shift, Ctrl and Alt, which mirror the left and right
    /// ones; the mouse buttons; and VK_PACKET, which on-screen keyboards send).
    fn others_down(combo: Combo) -> bool {
        (0x08u32..=0xFE)
            .filter(|k| !matches!(k, 0x10..=0x12 | 0xE7) && !combo.contains(*k) && !combo.tolerates(*k))
            .any(is_down)
    }

    fn current_combo(hooked: &Hooked) -> Combo {
        match hooked.combo.try_lock() {
            Ok(combo) => {
                hooked.last_combo.store(combo.index(), Ordering::Relaxed);
                *combo
            }
            Err(_) => Combo::from_index(hooked.last_combo.load(Ordering::Relaxed)),
        }
    }

    unsafe fn look(watch: &mut Watch, renewed: &mut Instant) {
        let Some(hooked) = HOOKED.get() else { return };
        let combo = current_combo(hooked);
        let mut tracker = hooked.tracker.lock().unwrap();
        let fix = watch.look(&mut tracker, combo, is_down, others_down(combo));
        let idle = tracker.is_idle();
        drop(tracker);
        match fix {
            Fix::Fine => {
                if idle && renewed.elapsed() >= RENEW_EVERY {
                    install();
                    *renewed = Instant::now();
                }
            }
            Fix::Up => (hooked.on)(Press::Up),
            Fix::Revive => {
                install();
                *renewed = Instant::now();
                (hooked.on)(Press::Revived);
                (hooked.on)(Press::Down);
            }
        }
    }

    unsafe extern "system" fn callback(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code == HC_ACTION as i32 {
            if let Some(hooked) = HOOKED.get() {
                let info = &*(lparam as *const KBDLLHOOKSTRUCT);
                let message = wparam as u32;
                let pressed = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
                let released = message == WM_KEYUP || message == WM_SYSKEYUP;
                if pressed && info.vkCode == ESCAPE && info.flags & LLKHF_INJECTED == 0 {
                    (hooked.on)(Press::Escape);
                }
                if (pressed || released) && info.flags & LLKHF_INJECTED == 0 {
                    // Kept short: Windows drops a hook that takes too long. `on` only hands the press on.
                    let combo = current_combo(hooked);
                    let press = hooked.tracker.lock().unwrap().key(combo, info.vkCode, pressed, is_down);
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
        assert_eq!(keys.key(Combo::CtrlWin, LCONTROL, true, |_| true), None);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, true, |_| true), Some(Press::Down));
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, true, |_| true), None); // auto-repeat
        assert_eq!(keys.key(Combo::CtrlWin, LCONTROL, true, |_| true), None);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, false, |_| true), Some(Press::Up));
        assert_eq!(keys.key(Combo::CtrlWin, LCONTROL, false, |_| true), None);
    }

    #[test]
    fn a_shortcut_cancels() {
        let mut keys = Tracker::new();
        keys.key(Combo::CtrlWin, LCONTROL, true, |_| true);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, true, |_| true), Some(Press::Down));
        assert_eq!(keys.key(Combo::CtrlWin, 0x44, true, |_| true), Some(Press::Cancel)); // D: show the desktop
        assert_eq!(keys.key(Combo::CtrlWin, 0x44, false, |_| true), None);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, false, |_| true), None);
    }

    #[test]
    fn not_with_other_keys_already_down() {
        let mut keys = Tracker::new();
        keys.key(Combo::CtrlWin, 0xA0, true, |_| true); // Left Shift
        keys.key(Combo::CtrlWin, LCONTROL, true, |_| true);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, true, |_| true), None);
    }

    #[test]
    fn right_alt_is_altgr_too() {
        let mut keys = Tracker::new();
        // AltGr: Windows sends Left Ctrl, then Right Alt.
        assert_eq!(keys.key(Combo::RightAlt, LCONTROL, true, |_| true), None);
        assert_eq!(keys.key(Combo::RightAlt, RMENU, true, |_| true), Some(Press::Down));
        assert_eq!(keys.key(Combo::RightAlt, RMENU, false, |_| true), Some(Press::Up));
        assert_eq!(keys.key(Combo::RightAlt, LCONTROL, false, |_| true), None); // AltGr's Left Ctrl goes up with it
        // Right Ctrl alone.
        assert_eq!(keys.key(Combo::RightCtrl, RCONTROL, true, |_| true), Some(Press::Down));
        assert_eq!(keys.key(Combo::RightCtrl, RCONTROL, false, |_| true), Some(Press::Up));
    }

    #[test]
    fn a_key_let_go_unseen_is_forgotten() {
        // Left Shift went down, and came up while an administrator's window had the keyboard: never seen going up.
        let mut keys = Tracker::new();
        keys.key(Combo::RightCtrl, 0xA0, true, |_| true);
        let held = |k: u32| k != 0xA0;
        assert_eq!(keys.key(Combo::RightCtrl, RCONTROL, true, held), Some(Press::Down));
        assert_eq!(keys.key(Combo::RightCtrl, RCONTROL, false, held), Some(Press::Up));
    }

    #[test]
    fn shift_while_held_makes_it_a_command() {
        let mut keys = Tracker::new();
        keys.key(Combo::CtrlWin, LCONTROL, true, |_| true);
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, true, |_| true), Some(Press::Down));
        assert_eq!(keys.key(Combo::CtrlWin, 0xA0, true, |_| true), Some(Press::Command));
        assert_eq!(keys.key(Combo::CtrlWin, 0xA0, false, |_| true), None);
        assert_eq!(keys.key(Combo::CtrlWin, 0xA1, true, |_| true), None); // once is enough
        assert!(keys.is_active());
        assert_eq!(keys.key(Combo::CtrlWin, LWIN, false, |_| true), Some(Press::Up));
    }

    #[test]
    fn names_round_trip() {
        for combo in Combo::ALL {
            assert_eq!(Combo::from_name(combo.name()), combo);
            assert_eq!(Combo::from_index(combo.index()), combo);
        }
        assert_eq!(Combo::from_name(""), Combo::CtrlWin);
    }

    #[test]
    fn a_dropped_hook_is_noticed_and_the_press_still_counts() {
        // Windows dropped the hook: Right Ctrl is held, but no event ever reached the tracker.
        let mut keys = Tracker::new();
        let mut watch = Watch::new();
        let held = |k: u32| k == RCONTROL;
        assert_eq!(watch.look(&mut keys, Combo::RightCtrl, held, false), Fix::Fine); // one look isn't enough
        assert_eq!(watch.look(&mut keys, Combo::RightCtrl, held, false), Fix::Revive);
        assert!(keys.is_active());
        // The new hook hears the release: the dictation ends as usual.
        assert_eq!(keys.key(Combo::RightCtrl, RCONTROL, false, |_| false), Some(Press::Up));
        // And with nothing held, all is well.
        assert_eq!(watch.look(&mut keys, Combo::RightCtrl, |_| false, false), Fix::Fine);
        assert!(keys.is_idle());
    }

    #[test]
    fn a_release_never_heard_ends_the_dictation() {
        let mut keys = Tracker::new();
        let mut watch = Watch::new();
        assert_eq!(keys.key(Combo::RightAlt, RMENU, true, |_| true), Some(Press::Down));
        // Held: fine, however long.
        for _ in 0..10 {
            assert_eq!(watch.look(&mut keys, Combo::RightAlt, |k| k == RMENU, false), Fix::Fine);
        }
        // Let go while an administrator's window had the keyboard: the hook never heard it.
        assert_eq!(watch.look(&mut keys, Combo::RightAlt, |_| false, false), Fix::Fine);
        assert_eq!(watch.look(&mut keys, Combo::RightAlt, |_| false, false), Fix::Up);
        assert!(!keys.is_active());
    }

    #[test]
    fn the_watchdog_leaves_working_hooks_and_shortcuts_alone() {
        // A working hook: it heard Ctrl + Windows go down, so the watchdog has nothing to do.
        let mut keys = Tracker::new();
        let mut watch = Watch::new();
        keys.key(Combo::CtrlWin, LCONTROL, true, |_| true);
        keys.key(Combo::CtrlWin, LWIN, true, |_| true);
        let held = |k: u32| k == LCONTROL || k == LWIN;
        for _ in 0..5 {
            assert_eq!(watch.look(&mut keys, Combo::CtrlWin, held, false), Fix::Fine);
        }
        // A shortcut (Shift held too) with a dropped hook isn't taken for dictation.
        let mut keys = Tracker::new();
        let mut watch = Watch::new();
        for _ in 0..5 {
            assert_eq!(watch.look(&mut keys, Combo::CtrlWin, held, true), Fix::Fine);
        }
        assert!(!keys.is_active());
    }

    #[test]
    fn a_mismatch_for_one_look_is_not_enough() {
        // The keyboard's state is updated just after the hook hears a key: one look can see them disagree.
        let mut keys = Tracker::new();
        let mut watch = Watch::new();
        assert_eq!(keys.key(Combo::RightCtrl, RCONTROL, true, |_| true), Some(Press::Down));
        assert_eq!(watch.look(&mut keys, Combo::RightCtrl, |_| false, false), Fix::Fine);
        assert_eq!(watch.look(&mut keys, Combo::RightCtrl, |k| k == RCONTROL, false), Fix::Fine);
        assert_eq!(watch.look(&mut keys, Combo::RightCtrl, |_| false, false), Fix::Fine);
        assert!(keys.is_active());
    }
}
