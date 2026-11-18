//! Which meeting app has the microphone on, as the Mac's MicUsers: Windows keeps, for each app that may use the
//! microphone, when it last started and stopped (Settings › Privacy › Microphone shows it as "Currently in use"). An
//! app whose last start has no stop after it has the microphone now. Desktop apps are under `NonPackaged`, by their
//! path (with `#` for `\`); Store apps (the new Teams) by their package name.
//!
//! Only meeting apps and browsers (a call on the web) count; Murmur's own dictation doesn't.

/// A meeting app with the microphone on: its name ("Zoom") and its program's file name ("zoom.exe"), for finding its
/// window. None when none is.
pub fn meeting() -> Option<(String, String)> {
    #[cfg(windows)]
    return windows::in_use().into_iter().find_map(|key| known(&key));
    #[cfg(not(windows))]
    None
}

/// A registry key's name as a meeting app: (its name, its program).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn known(key: &str) -> Option<(String, String)> {
    let lower = key.to_lowercase();
    let program = lower.rsplit(['#', '\\']).next().unwrap_or(&lower).to_string();
    const APPS: [(&str, &str, &str); 19] = [
        ("zoom.exe", "Zoom", "zoom.exe"), ("ms-teams.exe", "Teams", "ms-teams.exe"), ("teams.exe", "Teams", "teams.exe"),
        ("msteams_", "Teams", "ms-teams.exe"), ("webex", "Webex", "webex"), ("atmgr.exe", "Webex", "atmgr.exe"),
        ("slack.exe", "Slack", "slack.exe"), ("discord.exe", "Discord", "discord.exe"), ("whatsapp", "WhatsApp", "whatsapp"),
        ("skype", "Skype", "skype"), ("gotomeeting", "GoTo Meeting", "goto"), ("chrome.exe", "Chrome", "chrome.exe"),
        ("msedge.exe", "Edge", "msedge.exe"), ("firefox.exe", "Firefox", "firefox.exe"), ("brave.exe", "Brave", "brave.exe"),
        ("opera.exe", "Opera", "opera.exe"), ("vivaldi.exe", "Vivaldi", "vivaldi.exe"), ("arc.exe", "Arc", "arc.exe"),
        ("facebook.messenger", "Messenger", "messenger"),
    ];
    APPS.iter().find(|(needle, _, _)| program.starts_with(needle) || (needle.ends_with('_') && lower.starts_with(needle))
                                       || (!needle.contains('.') && lower.contains(needle)))
        .map(|(_, name, program)| (name.to_string(), program.to_string()))
}

#[cfg(windows)]
mod windows {
    use windows_sys::Win32::Foundation::ERROR_SUCCESS;
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegEnumKeyExW, RegOpenKeyExW, RegQueryValueExW, HKEY, HKEY_CURRENT_USER, KEY_READ,
    };

    const STORE: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    /// The keys (apps) whose microphone use has started and not stopped.
    pub fn in_use() -> Vec<String> {
        let mut out = Vec::new();
        for folder in [format!(r"{STORE}\NonPackaged"), STORE.to_string()] {
            unsafe {
                let mut key: HKEY = std::ptr::null_mut();
                if RegOpenKeyExW(HKEY_CURRENT_USER, wide(&folder).as_ptr(), 0, KEY_READ, &mut key) != ERROR_SUCCESS {
                    continue;
                }
                let mut index = 0;
                loop {
                    let mut name = vec![0u16; 512];
                    let mut length = name.len() as u32;
                    let status = RegEnumKeyExW(key, index, name.as_mut_ptr(), &mut length, std::ptr::null_mut(),
                                               std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut());
                    if status != ERROR_SUCCESS {
                        break;
                    }
                    index += 1;
                    let name = String::from_utf16_lossy(&name[..length as usize]);
                    if name == "NonPackaged" {
                        continue;
                    }
                    let mut app: HKEY = std::ptr::null_mut();
                    if RegOpenKeyExW(key, wide(&name).as_ptr(), 0, KEY_READ, &mut app) != ERROR_SUCCESS {
                        continue;
                    }
                    let start = quad(app, "LastUsedTimeStart");
                    let stop = quad(app, "LastUsedTimeStop");
                    RegCloseKey(app);
                    if start.is_some_and(|s| s > 0) && stop == Some(0) {
                        out.push(name);
                    }
                }
                RegCloseKey(key);
            }
        }
        out
    }

    unsafe fn quad(key: HKEY, name: &str) -> Option<u64> {
        let mut value = 0u64;
        let mut size = std::mem::size_of::<u64>() as u32;
        let status = RegQueryValueExW(key, wide(name).as_ptr(), std::ptr::null(), std::ptr::null_mut(),
                                      &mut value as *mut u64 as *mut u8, &mut size);
        (status == ERROR_SUCCESS).then_some(value)
    }
}

#[cfg(test)]
mod tests {
    use super::known;

    #[test]
    fn meeting_apps_by_their_keys() {
        assert_eq!(known(r"C:#Users#me#AppData#Roaming#Zoom#bin#Zoom.exe").unwrap().0, "Zoom");
        assert_eq!(known("MSTeams_8wekyb3d8bbwe").unwrap().0, "Teams");
        assert_eq!(known(r"C:#Program Files#Google#Chrome#Application#chrome.exe").unwrap().0, "Chrome");
        assert!(known(r"C:#Program Files#Murmur#Murmur.exe").is_none());
        assert!(known("Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe").is_none());
    }
}
