//! Puts the dictated words where the person is typing, as the Mac app's TextInserter does: what's on the clipboard is
//! kept, the words go on it (marked so Windows' clipboard history and cloud clipboard leave them out), Ctrl+V is
//! pressed in the app in front, then the clipboard gets back what it had.

#[cfg(windows)]
pub fn insert(text: &str) -> Result<(), String> {
    windows::insert(text)
}

#[cfg(not(windows))]
pub fn insert(_text: &str) -> Result<(), String> {
    Err("typing the words in works on Windows for now".into())
}

#[cfg(windows)]
mod windows {
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL};
    use windows_sys::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, OpenClipboard,
        RegisterClipboardFormatW, SetClipboardData,
    };
    use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_CONTROL,
    };

    const CF_UNICODETEXT: u32 = 13;
    /// Formats that aren't memory blocks (bitmaps, metafiles, palettes) or that Windows makes from others: left out of
    /// the copy kept (the picture still comes back, as its CF_DIB).
    const NOT_MEMORY: [u32; 9] = [2, 3, 9, 14, 0x0080, 0x0082, 0x0083, 0x008E, 0x0081];

    pub fn insert(text: &str) -> Result<(), String> {
        wait_for_modifiers();
        let kept = with_clipboard(|| unsafe { snapshot() }).unwrap_or_default();
        with_clipboard(|| unsafe {
            EmptyClipboard();
            put(CF_UNICODETEXT, &utf16(text));
            // Not in Win+V's history, nor synced (Microsoft's documented formats for this).
            let zero = 0u32.to_le_bytes();
            put(format("ExcludeClipboardContentFromMonitorProcessing"), &[]);
            put(format("CanIncludeInClipboardHistory"), &zero);
            put(format("CanUploadToCloudClipboard"), &zero);
        })
        .ok_or("the clipboard is busy (another app has it open)")?;
        press_paste();
        // The app reads the clipboard when it handles the keys: give it that moment before putting it back.
        std::thread::sleep(Duration::from_millis(350));
        if !kept.is_empty() {
            with_clipboard(|| unsafe {
                EmptyClipboard();
                for (format, data) in &kept {
                    put(*format, data);
                }
            });
        }
        Ok(())
    }

    /// The paste happens after the dictation key is let go, but a slow finger can still be on Ctrl or Windows: wait
    /// (up to half a second) for every modifier to be up, so Ctrl+V isn't Ctrl+Windows+V.
    fn wait_for_modifiers() {
        let started = Instant::now();
        while started.elapsed() < Duration::from_millis(500) {
            let held = [0x10, 0x11, 0x12, 0x5B, 0x5C].iter().any(|key| unsafe { GetAsyncKeyState(*key) } as u16 & 0x8000 != 0);
            if !held {
                return;
            }
            std::thread::sleep(Duration::from_millis(15));
        }
    }

    fn press_paste() {
        let key = |code: u16, up: bool| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT { wVk: code, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { 0 }, time: 0, dwExtraInfo: 0 },
            },
        };
        let v = b'V' as u16;
        let inputs = [key(VK_CONTROL, false), key(v, false), key(v, true), key(VK_CONTROL, true)];
        unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
    }

    /// Runs `work` with the clipboard open (tried for a moment: another app may hold it).
    fn with_clipboard<T>(work: impl FnOnce() -> T) -> Option<T> {
        for _ in 0..20 {
            if unsafe { OpenClipboard(std::ptr::null_mut()) } != 0 {
                let result = work();
                unsafe { CloseClipboard() };
                return Some(result);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        None
    }

    /// Every memory-block format on the clipboard, copied.
    unsafe fn snapshot() -> Vec<(u32, Vec<u8>)> {
        let mut kept = Vec::new();
        let mut format = EnumClipboardFormats(0);
        while format != 0 {
            if !NOT_MEMORY.contains(&format) {
                let handle = GetClipboardData(format);
                if !handle.is_null() {
                    let size = GlobalSize(handle as HGLOBAL);
                    let data = GlobalLock(handle as HGLOBAL) as *const u8;
                    if !data.is_null() {
                        kept.push((format, std::slice::from_raw_parts(data, size).to_vec()));
                        GlobalUnlock(handle as HGLOBAL);
                    }
                }
            }
            format = EnumClipboardFormats(format);
        }
        kept
    }

    /// A copy of `data` as the clipboard's `format` (the clipboard owns it from then on).
    unsafe fn put(format: u32, data: &[u8]) {
        let memory = GlobalAlloc(GMEM_MOVEABLE, data.len().max(1));
        if memory.is_null() {
            return;
        }
        let target = GlobalLock(memory) as *mut u8;
        if target.is_null() {
            GlobalFree(memory);
            return;
        }
        std::ptr::copy_nonoverlapping(data.as_ptr(), target, data.len());
        GlobalUnlock(memory);
        if SetClipboardData(format, memory as HANDLE).is_null() {
            GlobalFree(memory);
        }
    }

    fn format(name: &str) -> u32 {
        let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        unsafe { RegisterClipboardFormatW(wide.as_ptr()) }
    }

    /// UTF-16 with its terminating zero, as bytes.
    fn utf16(text: &str) -> Vec<u8> {
        text.encode_utf16().chain(Some(0)).flat_map(|unit| unit.to_le_bytes()).collect()
    }
}
