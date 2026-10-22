//! The Claude and OpenAI API keys, kept where Windows keeps passwords: the Credential Manager (generic credentials
//! "Murmur/anthropic" and "Murmur/openai", for this user only), as the Mac app keeps them in the Keychain. Never in the
//! settings file. Elsewhere (the Linux shell, tests) they're a file only this user can read in the config folder.

const TARGET_PREFIX: &str = "Murmur/";

/// The key saved for `account` ("anthropic", "openai").
pub fn get(account: &str) -> Option<String> {
    imp::get(&format!("{TARGET_PREFIX}{account}")).filter(|key| !key.trim().is_empty())
}

/// Saves a key (replacing any before), or removes it when `key` is empty.
pub fn set(account: &str, key: &str) -> Result<(), String> {
    let target = format!("{TARGET_PREFIX}{account}");
    let key = key.trim();
    if key.is_empty() { imp::delete(&target) } else { imp::set(&target, key) }
}

#[cfg(windows)]
mod imp {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::Security::Credentials::{
        CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    };

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(std::iter::once(0)).collect()
    }

    pub fn get(target: &str) -> Option<String> {
        let target = wide(target);
        unsafe {
            let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
            if CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) == 0 || credential.is_null() {
                return None;
            }
            let blob = std::slice::from_raw_parts((*credential).CredentialBlob, (*credential).CredentialBlobSize as usize);
            let key = String::from_utf8(blob.to_vec()).ok();
            CredFree(credential as *const _);
            key
        }
    }

    pub fn set(target: &str, key: &str) -> Result<(), String> {
        let mut target = wide(target);
        let mut user = wide("Murmur");
        let mut blob = key.as_bytes().to_vec();
        let credential = CREDENTIALW {
            Flags: 0,
            Type: CRED_TYPE_GENERIC,
            TargetName: target.as_mut_ptr(),
            Comment: std::ptr::null_mut(),
            LastWritten: FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 },
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            // This user, on this PC (not roamed to other PCs).
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            AttributeCount: 0,
            Attributes: std::ptr::null_mut(),
            TargetAlias: std::ptr::null_mut(),
            UserName: user.as_mut_ptr(),
        };
        unsafe {
            if CredWriteW(&credential, 0) == 0 {
                return Err(format!("Windows couldn't save the key (error {})", std::io::Error::last_os_error()));
            }
        }
        Ok(())
    }

    pub fn delete(target: &str) -> Result<(), String> {
        let target = wide(target);
        unsafe {
            CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0);
        }
        Ok(())
    }
}

#[cfg(not(windows))]
mod imp {
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    fn file() -> Option<PathBuf> {
        if let Some(path) = std::env::var_os("MURMUR_KEYS_FILE") {
            return Some(PathBuf::from(path));
        }
        let base = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
        Some(base.join("com.copico.Murmur").join("keys.json"))
    }

    fn read() -> BTreeMap<String, String> {
        file().and_then(|path| std::fs::read(path).ok()).and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    fn write(keys: &BTreeMap<String, String>) -> Result<(), String> {
        let path = file().ok_or("no config folder")?;
        if let Some(folder) = path.parent() {
            std::fs::create_dir_all(folder).map_err(|error| error.to_string())?;
        }
        std::fs::write(&path, serde_json::to_vec(keys).map_err(|error| error.to_string())?).map_err(|error| error.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }

    pub fn get(target: &str) -> Option<String> {
        read().get(target).cloned()
    }

    pub fn set(target: &str, key: &str) -> Result<(), String> {
        let mut keys = read();
        keys.insert(target.to_string(), key.to_string());
        write(&keys)
    }

    pub fn delete(target: &str) -> Result<(), String> {
        let mut keys = read();
        keys.remove(target);
        write(&keys)
    }
}

/// The key as Settings shows it: the start and the end, the middle hidden.
pub fn masked(key: &str) -> String {
    let chars: Vec<char> = key.chars().collect();
    if chars.len() <= 12 {
        return "•".repeat(chars.len());
    }
    let start: String = chars[..7].iter().collect();
    let end: String = chars[chars.len() - 4..].iter().collect();
    format!("{start}…{end}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saves_reads_and_removes() {
        let file = std::env::temp_dir().join(format!("murmur-keys-{}.json", std::process::id()));
        std::env::set_var("MURMUR_KEYS_FILE", &file);
        set("openai-test", "sk-proj-1234567890abcdefghij").unwrap();
        assert_eq!(get("openai-test").as_deref(), Some("sk-proj-1234567890abcdefghij"));
        set("openai-test", "").unwrap();
        assert_eq!(get("openai-test"), None);
        assert_eq!(masked("sk-proj-1234567890abcdefghij"), "sk-proj…ghij");
        assert_eq!(masked("short"), "•••••");
        let _ = std::fs::remove_file(file);
    }
}
