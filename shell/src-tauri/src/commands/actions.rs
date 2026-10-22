//! What a command does on Windows: the Mac's MacActions, through Win32. Apps from the Start menu's list (Get-StartApps)
//! and their open windows; Settings pages, folders and web pages through the shell; the volume through the audio
//! endpoint; brightness through WMI; keys through SendInput; text through the clipboard (paste.rs). Every function
//! says, in a sentence, what it did, for the model and the log.

#![cfg(windows)]

use super::places;
use std::os::windows::process::CommandExt;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{CloseHandle, GlobalFree, HWND, LPARAM, WPARAM};
use windows_sys::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData};
use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows_sys::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP,
};
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetForegroundWindow, GetWindow, GetWindowLongPtrW, GetWindowTextLengthW, GetWindowTextW,
    GetWindowThreadProcessId, IsIconic, IsWindowVisible, PostMessageW, SetForegroundWindow, ShowWindow, GWL_EXSTYLE,
    GW_OWNER, SW_MINIMIZE, SW_RESTORE, SW_SHOWNORMAL, WM_CLOSE, WS_EX_TOOLWINDOW,
};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

/// Opens a file, a folder, an address or a program through the shell, as a double-click does.
fn shell_open(target: &str, arguments: Option<&str>) -> Result<(), String> {
    let verb = wide("open");
    let file = wide(target);
    let args = arguments.map(wide);
    let result = unsafe {
        ShellExecuteW(std::ptr::null_mut(), verb.as_ptr(), file.as_ptr(),
                      args.as_ref().map_or(std::ptr::null(), |a| a.as_ptr()), std::ptr::null(), SW_SHOWNORMAL)
    };
    // Above 32: it worked; at or below, one of ShellExecute's error numbers.
    if result as isize > 32 { Ok(()) } else { Err(format!("Windows couldn't open it (error {})", result as isize)) }
}

/// PowerShell, hidden, with UTF-8 out: its output, or None.
fn powershell(script: &str, timeout: Duration) -> Option<String> {
    let mut child = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
               &format!("[Console]::OutputEncoding=[Text.Encoding]::UTF8; {script}")])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .stdin(std::process::Stdio::null())
        .spawn().ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() > timeout => {
                let _ = child.kill();
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(40)),
            Err(_) => return None,
        }
    }
    let output = child.wait_with_output().ok()?;
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

// MARK: Installed apps (the Start menu's list)

#[derive(Clone, Debug)]
struct App {
    name: String,
    id: String,
}

static CATALOG: OnceLock<Mutex<Option<(Instant, Vec<App>)>>> = OnceLock::new();

/// The Start menu's apps, read once and again after ten minutes (a second or two the first time: `warm` does it
/// early, in the background).
fn catalog() -> Vec<App> {
    let cell = CATALOG.get_or_init(|| Mutex::new(None));
    if let Some((at, apps)) = cell.lock().unwrap().as_ref() {
        if at.elapsed() < Duration::from_secs(600) {
            return apps.clone();
        }
    }
    let apps = read_catalog();
    if !apps.is_empty() {
        *cell.lock().unwrap() = Some((Instant::now(), apps.clone()));
    }
    apps
}

fn read_catalog() -> Vec<App> {
    let Some(json) = powershell("Get-StartApps | Select-Object Name,AppID | ConvertTo-Json -Compress", Duration::from_secs(15)) else {
        return Vec::new();
    };
    let value: serde_json::Value = serde_json::from_str(&json).unwrap_or_default();
    let items = match value {
        serde_json::Value::Array(items) => items,
        single @ serde_json::Value::Object(_) => vec![single],
        _ => Vec::new(),
    };
    items.iter().filter_map(|item| Some(App { name: item["Name"].as_str()?.to_string(), id: item["AppID"].as_str()?.to_string() }))
        .collect()
}

/// Reads the app list ahead of the first command.
pub fn warm() {
    std::thread::spawn(|| {
        let _ = catalog();
    });
}

fn find_app(name: &str) -> Option<App> {
    let apps = catalog();
    let names: Vec<String> = apps.iter().map(|a| a.name.clone()).collect();
    places::match_app(name, &names).map(|i| apps[i].clone())
}

/// Whether an installed app goes by this name.
pub fn resolves(name: &str) -> bool {
    find_app(name).is_some() || places::browser_program(name).is_some()
}

pub fn is_browser(name: &str) -> bool {
    places::browser_program(name).is_some()
}

// MARK: Open windows

#[derive(Clone, Debug)]
pub struct Window {
    pub hwnd: isize,
    pub title: String,
    /// The program's file name: "chrome.exe", "ApplicationFrameHost.exe" (a Store app).
    pub program: String,
}

fn title_of(hwnd: HWND) -> String {
    unsafe {
        let length = GetWindowTextLengthW(hwnd);
        if length <= 0 {
            return String::new();
        }
        let mut buffer = vec![0u16; length as usize + 1];
        let got = GetWindowTextW(hwnd, buffer.as_mut_ptr(), buffer.len() as i32);
        String::from_utf16_lossy(&buffer[..got.max(0) as usize])
    }
}

fn program_of(hwnd: HWND) -> String {
    unsafe {
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, &mut pid);
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return String::new();
        }
        let mut buffer = vec![0u16; 1024];
        let mut size = buffer.len() as u32;
        let ok = QueryFullProcessImageNameW(process, 0, buffer.as_mut_ptr(), &mut size);
        CloseHandle(process);
        if ok == 0 {
            return String::new();
        }
        let path = String::from_utf16_lossy(&buffer[..size as usize]);
        path.rsplit('\\').next().unwrap_or_default().to_string()
    }
}

/// The app windows on screen (visible, titled, not tool windows or owned dialogs), front to back.
pub fn windows() -> Vec<Window> {
    unsafe extern "system" fn each(hwnd: HWND, list: LPARAM) -> i32 {
        let list = &mut *(list as *mut Vec<Window>);
        if IsWindowVisible(hwnd) == 0 || !GetWindow(hwnd, GW_OWNER).is_null() {
            return 1;
        }
        if GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW != 0 {
            return 1;
        }
        let title = title_of(hwnd);
        if title.trim().is_empty() || title == "Program Manager" {
            return 1;
        }
        list.push(Window { hwnd: hwnd as isize, title, program: program_of(hwnd) });
        1
    }
    let mut list: Vec<Window> = Vec::new();
    unsafe { EnumWindows(Some(each), &mut list as *mut Vec<Window> as LPARAM) };
    // Murmur's own windows (the pill, the answer) aren't the user's apps.
    list.retain(|w| !w.program.eq_ignore_ascii_case("murmur.exe") && !w.program.to_lowercase().starts_with("murmur-shell"));
    list
}

/// The window in front: (its handle, its program's file name, its title).
pub fn front() -> Option<Window> {
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.is_null() {
        return None;
    }
    Some(Window { hwnd: hwnd as isize, title: title_of(hwnd), program: program_of(hwnd) })
}

/// What people call the app a window belongs to: "chrome", "WhatsApp" (a Store app's window says its name).
pub fn app_name(window: &Window) -> String {
    let stem = window.program.trim_end_matches(".exe").trim_end_matches(".EXE");
    if stem.eq_ignore_ascii_case("ApplicationFrameHost") || stem.is_empty() {
        return window.title.rsplit(" - ").next().unwrap_or(&window.title).trim().to_string();
    }
    stem.to_string()
}

/// The windows of an app asked for by name.
fn windows_of(name: &str) -> Vec<Window> {
    let asked = name.trim().to_lowercase();
    let asked = asked.trim_start_matches("the ").trim_end_matches(" app");
    let program = places::browser_program(asked).map(|p| p.trim_end_matches(".exe").to_string());
    let catalog_name = find_app(asked).map(|app| app.name.to_lowercase());
    let squeezed = asked.replace(' ', "");
    windows().into_iter().filter(|w| {
        let stem = w.program.to_lowercase().trim_end_matches(".exe").to_string();
        let title = w.title.to_lowercase();
        stem == squeezed || program.as_deref() == Some(stem.as_str())
            || catalog_name.as_deref().is_some_and(|n| title == n || title.ends_with(&format!(" - {n}")) || title.ends_with(&format!(" – {n}")))
            || title == asked || title.ends_with(&format!(" - {asked}"))
    }).collect()
}

/// Brings a window to the front (Windows only lets the app in front do that, so an Alt press first, as is usual).
pub fn bring_to_front(hwnd: isize) -> bool {
    let hwnd = hwnd as HWND;
    unsafe {
        if IsIconic(hwnd) != 0 {
            ShowWindow(hwnd, SW_RESTORE);
        }
        if GetForegroundWindow() == hwnd {
            return true;
        }
        send(&[key_event(0x12, false), key_event(0x12, true)]);
        SetForegroundWindow(hwnd);
        std::thread::sleep(Duration::from_millis(120));
        GetForegroundWindow() == hwnd
    }
}

// MARK: Apps

/// Opens an app, or brings it forward when it's open already.
pub fn open_app(name: &str) -> String {
    if let Some(window) = windows_of(name).first() {
        bring_to_front(window.hwnd);
        return format!("Switched to {}.", app_name(window));
    }
    launch(name)
}

/// Starts an app afresh (a new window even when one is open).
fn launch(name: &str) -> String {
    if let Some(app) = find_app(name) {
        return match shell_open("explorer.exe", Some(&format!("shell:AppsFolder\\{}", app.id))) {
            Ok(()) => format!("Opened {}.", app.name),
            Err(error) => format!("Couldn't open {}: {error}", app.name),
        };
    }
    if let Some(program) = places::browser_program(name) {
        return match shell_open(program, None) {
            Ok(()) => format!("Opened {name}."),
            Err(_) => format!("{name} isn't installed."),
        };
    }
    // Programs Windows knows by name (notepad, mspaint, cmd), not always in the Start menu's list.
    let plain = name.trim().to_lowercase().replace(' ', "");
    if plain.chars().all(|c| c.is_ascii_alphanumeric()) && shell_open(&format!("{plain}.exe"), None).is_ok() {
        return format!("Opened {name}.");
    }
    format!("No app called \"{name}\" is installed. find_apps lists what is.")
}

pub fn quit_app(name: &str) -> String {
    let found = windows_of(name);
    if found.is_empty() {
        return format!("\"{name}\" isn't running.");
    }
    for window in &found {
        unsafe { PostMessageW(window.hwnd as HWND, WM_CLOSE, 0 as WPARAM, 0 as LPARAM) };
    }
    format!("Closed {} ({} window{}).", app_name(&found[0]), found.len(), if found.len() == 1 { "" } else { "s" })
}

pub fn hide_app(name: &str) -> String {
    let found = windows_of(name);
    if found.is_empty() {
        return format!("\"{name}\" isn't open.");
    }
    for window in &found {
        unsafe { ShowWindow(window.hwnd as HWND, SW_MINIMIZE) };
    }
    format!("Minimised {}.", app_name(&found[0]))
}

pub fn find_apps(query: &str) -> String {
    let query = query.trim().to_lowercase();
    let names: Vec<String> = catalog().into_iter().map(|a| a.name)
        .filter(|n| query.is_empty() || n.to_lowercase().contains(&query)).take(30).collect();
    if names.is_empty() {
        format!("No installed app matches \"{query}\".")
    } else {
        format!("Installed apps matching \"{query}\": {}", names.join(", "))
    }
}

pub fn running_apps() -> String {
    let mut seen: Vec<String> = Vec::new();
    for window in windows() {
        let line = format!("{} (\"{}\")", app_name(&window), crate::ai::cut(&window.title, 60));
        if !seen.iter().any(|s| s.starts_with(&app_name(&window))) {
            seen.push(line);
        }
    }
    if seen.is_empty() { "No app windows are open.".into() } else { format!("Open: {}", seen.join(", ")) }
}

// MARK: Places

pub fn open_folder(name: &str) -> String {
    match places::folder(name) {
        Some((shell, shown)) => match shell_open("explorer.exe", Some(shell)) {
            Ok(()) => format!("Opened {shown}."),
            Err(error) => format!("Couldn't open {shown}: {error}"),
        },
        None => format!("\"{name}\" isn't a standard folder: open_file or search_files finds others."),
    }
}

pub fn open_settings(page: &str) -> String {
    let (uri, shown) = places::settings_page(page);
    match shell_open(&uri, None) {
        Ok(()) => format!("Opened {shown}{}.", if shown == "Settings" || shown.contains("Store") { "" } else { " in Settings" }),
        Err(error) => format!("Couldn't open Settings: {error}"),
    }
}

/// A web page, in the browser named (or the default one).
pub fn open_page(url: &str, browser: Option<&str>) -> Result<(), String> {
    if let Some(program) = browser.and_then(places::browser_program) {
        if shell_open(program, Some(url)).is_ok() {
            return Ok(());
        }
    }
    shell_open(url, None)
}

pub fn open_url(text: &str, browser: Option<&str>) -> String {
    let Some(url) = places::web_address(text) else { return "That doesn't look like a web address.".into() };
    match open_page(&url, browser) {
        Ok(()) => format!("Opened {}{}.", url.trim_start_matches("https://").trim_start_matches("www."),
                          browser.map(|b| format!(" in {b}")).unwrap_or_default()),
        Err(error) => format!("Couldn't open {url}: {error}"),
    }
}

pub fn web_search(query: &str, browser: Option<&str>) -> String {
    match open_page(&places::web_search_address(query), browser) {
        Ok(()) => format!("Searching the web for \"{query}\"."),
        Err(error) => format!("Couldn't search: {error}"),
    }
}

pub fn site_search(site: &str, query: &str, browser: Option<&str>) -> String {
    match open_page(&places::site_search_address(site, query), browser) {
        Ok(()) => format!("Searching {site} for \"{query}\"."),
        Err(error) => format!("Couldn't search {site}: {error}"),
    }
}

pub fn open_path(path: &str) -> Result<(), String> {
    shell_open(path, None)
}

// MARK: Keys

fn key_event(code: u16, up: bool) -> INPUT {
    // The keys that sit apart from the number pad say so, or Windows takes them for the pad's.
    let extended = matches!(code, 0x21..=0x28 | 0x2D | 0x2E | 0x5B | 0x5C | 0xA3 | 0xA5);
    let mut flags = if up { KEYEVENTF_KEYUP } else { 0 };
    if extended {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: code, wScan: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

fn send(inputs: &[INPUT]) {
    unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
}

/// Presses keys together: each down in order, then up in reverse.
fn chord(codes: &[u16]) {
    let mut inputs: Vec<INPUT> = codes.iter().map(|c| key_event(*c, false)).collect();
    inputs.extend(codes.iter().rev().map(|c| key_event(*c, true)));
    send(&inputs);
}

pub fn press_keys(spoken: &str) -> String {
    match places::keys(spoken) {
        Some(codes) => {
            chord(&codes);
            std::thread::sleep(Duration::from_millis(250));
            format!("Pressed {spoken}.")
        }
        None => format!("Don't know the keys \"{spoken}\": write them like ctrl+shift+t, enter, alt+tab, pagedown."),
    }
}

pub fn type_text(text: &str, submit: bool) -> String {
    if let Err(error) = crate::dictation::paste::insert(text) {
        return format!("Couldn't type it: {error}");
    }
    if submit {
        std::thread::sleep(Duration::from_millis(200));
        chord(&[0x0D]);
        std::thread::sleep(Duration::from_millis(500));
    }
    format!("Typed {} characters{}.", text.chars().count(), if submit { " and pressed Enter" } else { "" })
}

/// Opens an app, starts a new document or note in it, and types the text: (what happened, whether it was written).
pub fn write_in_app(app: &str, text: &str, new_document: bool) -> (String, bool) {
    let before = front().map(|w| w.hwnd);
    let opened = if new_document { launch(app) } else { open_app(app) };
    if opened.starts_with("No app") || opened.starts_with("Couldn't") {
        return (opened, false);
    }
    // Its window, in front: up to eight seconds for an app that's slow to start.
    let started = Instant::now();
    let mut ready = None;
    while started.elapsed() < Duration::from_secs(8) {
        if let Some(window) = windows_of(app).into_iter().next() {
            let in_front = front().is_some_and(|f| f.hwnd == window.hwnd);
            if in_front || (Some(window.hwnd) != before && bring_to_front(window.hwnd)) {
                ready = Some(window);
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    let Some(window) = ready else {
        return (format!("{opened} But its window didn't come to the front, so nothing was typed."), false);
    };
    // A moment for the app to be ready to type in, then a new document (Ctrl+N) unless it's adding to the open one.
    std::thread::sleep(Duration::from_millis(if started.elapsed() > Duration::from_secs(1) { 900 } else { 500 }));
    if new_document {
        chord(&[0x11, b'N' as u16]);
        std::thread::sleep(Duration::from_millis(800));
    }
    match crate::dictation::paste::insert(text) {
        Ok(()) => (format!("Wrote it in {}.", app_name(&window)), true),
        Err(error) => (format!("{} opened, but the text couldn't be typed: {error}", app_name(&window)), false),
    }
}

// MARK: Sound, screen, the PC

pub fn media(action: &str) -> String {
    let (code, said) = match action.trim().to_lowercase().as_str() {
        "next" | "skip" => (0xB0, "Skipped to the next one."),
        "previous" | "back" | "prev" => (0xB1, "Went back to the previous one."),
        "pause" | "stop" => (0xB3, "Paused."),
        _ => (0xB3, "Playing."),
    };
    chord(&[code]);
    said.to_string()
}

pub fn change_volume(up: bool) -> String {
    // Five presses: ten points, with Windows' own volume showing it.
    let code = if up { 0xAF } else { 0xAE };
    for _ in 0..5 {
        chord(&[code]);
    }
    match volume::get() {
        Some(level) => format!("Volume {} to {}%.", if up { "up" } else { "down" }, (level * 100.0).round()),
        None => format!("Turned the volume {}.", if up { "up" } else { "down" }),
    }
}

pub fn set_volume(percent: f64) -> String {
    let percent = percent.clamp(0.0, 100.0);
    match volume::set(percent as f32 / 100.0) {
        Ok(()) => format!("Volume set to {percent:.0}%."),
        Err(error) => format!("Couldn't set the volume: {error}"),
    }
}

pub fn mute(on: bool) -> String {
    match volume::mute(on) {
        Ok(()) => (if on { "Muted." } else { "Unmuted." }).into(),
        Err(error) => format!("Couldn't change mute: {error}"),
    }
}

/// The laptop screen's brightness (WMI; an external monitor doesn't take it).
pub fn set_brightness(percent: Option<f64>, step: i32) -> String {
    let script = match percent {
        Some(p) => format!("$v={}; ", p.clamp(0.0, 100.0).round()),
        None => format!("$c=(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1).CurrentBrightness; \
                         $v=[Math]::Max(0,[Math]::Min(100,$c+({step}))); "),
    } + "$m=Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop | Select-Object -First 1; \
         Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{Timeout=0;Brightness=[byte]$v} | Out-Null; \"ok $v\"";
    match powershell(&script, Duration::from_secs(10)) {
        Some(out) if out.starts_with("ok ") => format!("Brightness set to {}%.", out.trim_start_matches("ok ")),
        _ => "This screen's brightness can't be set from Windows (an external monitor sets its own): open_settings display."
            .into(),
    }
}

pub fn lock_screen() -> String {
    let ok = unsafe { windows_sys::Win32::System::Shutdown::LockWorkStation() } != 0;
    if ok { "Locked the PC.".into() } else { "Couldn't lock the PC.".into() }
}

pub fn screenshot() -> String {
    match shell_open("ms-screenclip:", None) {
        Ok(()) => "Opened the screenshot tool: choose what to capture.".into(),
        Err(_) => {
            chord(&[0x5B, 0x10, b'S' as u16]);
            "Opened the screenshot tool (Windows + Shift + S).".into()
        }
    }
}

// MARK: The clipboard

const CF_UNICODETEXT: u32 = 13;

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

pub fn clipboard_text() -> Option<String> {
    with_clipboard(|| unsafe {
        let handle = GetClipboardData(CF_UNICODETEXT);
        if handle.is_null() {
            return None;
        }
        let data = GlobalLock(handle as _) as *const u16;
        if data.is_null() {
            return None;
        }
        let mut length = 0;
        while *data.add(length) != 0 {
            length += 1;
        }
        let text = String::from_utf16_lossy(std::slice::from_raw_parts(data, length));
        GlobalUnlock(handle as _);
        Some(text)
    }).flatten()
}

pub fn copy_text(text: &str) -> bool {
    let units: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    with_clipboard(|| unsafe {
        EmptyClipboard();
        let memory = GlobalAlloc(GMEM_MOVEABLE, units.len() * 2);
        if memory.is_null() {
            return false;
        }
        let target = GlobalLock(memory) as *mut u16;
        if target.is_null() {
            GlobalFree(memory);
            return false;
        }
        std::ptr::copy_nonoverlapping(units.as_ptr(), target, units.len());
        GlobalUnlock(memory);
        if SetClipboardData(CF_UNICODETEXT, memory as _).is_null() {
            GlobalFree(memory);
            return false;
        }
        true
    }).unwrap_or(false)
}

/// Ctrl+V in the app in front.
pub fn paste() {
    chord(&[0x11, b'V' as u16]);
    std::thread::sleep(Duration::from_millis(300));
}

// MARK: The volume (the default speakers' endpoint, through COM)

mod volume {
    use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
    use windows::Win32::Media::Audio::{eConsole, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};

    fn endpoint() -> windows::core::Result<IAudioEndpointVolume> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
            let speakers = devices.GetDefaultAudioEndpoint(eRender, eConsole)?;
            speakers.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None)
        }
    }

    pub fn get() -> Option<f32> {
        unsafe { endpoint().ok()?.GetMasterVolumeLevelScalar().ok() }
    }

    pub fn set(level: f32) -> Result<(), String> {
        unsafe {
            let endpoint = endpoint().map_err(|e| e.message().to_string())?;
            if level > 0.0 {
                let _ = endpoint.SetMute(false, std::ptr::null());
            }
            endpoint.SetMasterVolumeLevelScalar(level, std::ptr::null()).map_err(|e| e.message().to_string())
        }
    }

    pub fn mute(on: bool) -> Result<(), String> {
        unsafe {
            let endpoint = endpoint().map_err(|e| e.message().to_string())?;
            endpoint.SetMute(on, std::ptr::null()).map_err(|e| e.message().to_string())
        }
    }
}
