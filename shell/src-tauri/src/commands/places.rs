//! Where Windows' tools go, worked out apart from doing it (actions.rs does it): a Settings page's address, a web
//! address from what was said, a site's own search, a standard folder, the keys in "ctrl+shift+t", and which installed
//! app a spoken name means.

// Windows' tools use these (actions.rs); elsewhere only the tests do.
#![cfg_attr(not(windows), allow(dead_code))]

/// The Settings page for what was said, and how to say it: ("ms-settings:windowsupdate", "Windows Update").
pub fn settings_page(page: &str) -> (String, String) {
    let asked = page.trim().to_lowercase().replace(['-', '_'], " ");
    const PAGES: &[(&[&str], &str, &str)] = &[
        (&["windows update", "update", "updates", "system update", "check for updates"], "ms-settings:windowsupdate", "Windows Update"),
        (&["store updates", "app updates", "store"], "ms-windows-store://downloadsandupdates", "Microsoft Store's updates"),
        (&["wifi", "wi fi", "wireless", "network", "internet"], "ms-settings:network-wifi", "Wi-Fi"),
        (&["bluetooth", "devices", "bluetooth devices"], "ms-settings:bluetooth", "Bluetooth & devices"),
        (&["display", "screen", "resolution", "brightness", "night light", "monitor"], "ms-settings:display", "Display"),
        (&["sound", "audio", "volume", "speakers", "microphone", "mic"], "ms-settings:sound", "Sound"),
        (&["battery", "power", "power and battery", "battery saver", "sleep"], "ms-settings:powersleep", "Power & battery"),
        (&["privacy", "security", "privacy and security", "permissions"], "ms-settings:privacy", "Privacy & security"),
        (&["apps", "installed apps", "programs", "uninstall"], "ms-settings:appsfeatures", "Installed apps"),
        (&["default apps", "defaults", "default browser"], "ms-settings:defaultapps", "Default apps"),
        (&["startup", "startup apps"], "ms-settings:startupapps", "Startup apps"),
        (&["notifications", "notification", "do not disturb", "focus"], "ms-settings:notifications", "Notifications"),
        (&["storage", "disk", "disk space", "space"], "ms-settings:storagesense", "Storage"),
        (&["mouse", "touchpad", "trackpad"], "ms-settings:mousetouchpad", "Mouse"),
        (&["keyboard", "typing", "language", "languages", "input"], "ms-settings:typing", "Typing"),
        (&["personalization", "personalisation", "wallpaper", "background", "theme", "themes", "colors", "colours", "dark mode"],
         "ms-settings:personalization", "Personalization"),
        (&["accounts", "account", "sign in", "sign in options", "password"], "ms-settings:signinoptions", "Sign-in options"),
        (&["date", "time", "date and time", "clock", "time zone"], "ms-settings:dateandtime", "Date & time"),
        (&["vpn"], "ms-settings:network-vpn", "VPN"),
        (&["hotspot", "mobile hotspot"], "ms-settings:network-mobilehotspot", "Mobile hotspot"),
        (&["printers", "printer", "scanners"], "ms-settings:printers", "Printers & scanners"),
        (&["about", "system info", "about this pc", "specs"], "ms-settings:about", "About"),
        (&["accessibility", "ease of access"], "ms-settings:easeofaccess", "Accessibility"),
        (&["taskbar"], "ms-settings:taskbar", "Taskbar"),
        (&["camera", "webcam"], "ms-settings:privacy-webcam", "Camera privacy"),
    ];
    let trimmed = asked.trim_start_matches("the ").trim_end_matches(" settings").trim_end_matches(" page").trim();
    if trimmed.is_empty() || trimmed == "settings" || trimmed == "system" {
        return ("ms-settings:".into(), "Settings".into());
    }
    for (names, uri, shown) in PAGES {
        if names.contains(&trimmed) {
            return (uri.to_string(), shown.to_string());
        }
    }
    for (names, uri, shown) in PAGES {
        if names.iter().any(|n| n.len() > 3 && (trimmed.contains(n) || n.contains(trimmed))) {
            return (uri.to_string(), shown.to_string());
        }
    }
    ("ms-settings:".into(), "Settings".into())
}

/// A web address from what was said: "youtube" (a known site), "github.com", "saleshq dot ai", a full address.
pub fn web_address(text: &str) -> Option<String> {
    let mut text = text.trim().trim_end_matches(['.', ',']).to_string();
    if text.is_empty() {
        return None;
    }
    if let Some(url) = super::quick::site(&text.to_lowercase()) {
        return Some(url.to_string());
    }
    text = text.replace(" dot ", ".").replace(' ', "");
    if text.starts_with("http://") || text.starts_with("https://") {
        return Some(text);
    }
    let host = text.split('/').next().unwrap_or_default();
    let looks = host.contains('.') && host.rsplit('.').next().is_some_and(|tld| tld.len() >= 2 && tld.chars().all(char::is_alphabetic))
        && host.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-');
    looks.then(|| format!("https://{text}"))
}

/// A query in a web address.
pub fn encode(query: &str) -> String {
    let mut out = String::new();
    for byte in query.trim().bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

pub fn web_search_address(query: &str) -> String {
    format!("https://www.google.com/search?q={}", encode(query))
}

/// A site's own search: "youtube", "lofi" → YouTube's results. Sites without one: Google, within that site.
pub fn site_search_address(site: &str, query: &str) -> String {
    let q = encode(query);
    let site = site.trim().to_lowercase().replace("stack overflow", "stackoverflow");
    let address = match site.as_str() {
        "youtube" | "you tube" => format!("https://www.youtube.com/results?search_query={q}"),
        "youtube music" => format!("https://music.youtube.com/search?q={q}"),
        "google" | "web" => web_search_address(query),
        "google images" | "images" => format!("https://www.google.com/search?tbm=isch&q={q}"),
        "google maps" | "maps" => format!("https://www.google.com/maps/search/{q}"),
        "amazon" => format!("https://www.amazon.in/s?k={q}"),
        "flipkart" => format!("https://www.flipkart.com/search?q={q}"),
        "github" => format!("https://github.com/search?q={q}"),
        "wikipedia" => format!("https://en.wikipedia.org/w/index.php?search={q}"),
        "reddit" => format!("https://www.reddit.com/search/?q={q}"),
        "twitter" | "x" => format!("https://x.com/search?q={q}"),
        "linkedin" => format!("https://www.linkedin.com/search/results/all/?keywords={q}"),
        "stackoverflow" => format!("https://stackoverflow.com/search?q={q}"),
        "spotify" => format!("https://open.spotify.com/search/{}", q.replace('+', "%20")),
        "netflix" => format!("https://www.netflix.com/search?q={q}"),
        "myntra" => format!("https://www.myntra.com/{}", q.replace('+', "-")),
        "bing" => format!("https://www.bing.com/search?q={q}"),
        "duckduckgo" => format!("https://duckduckgo.com/?q={q}"),
        other => {
            let domain = super::quick::site(other).map(|url| url.trim_start_matches("https://").trim_start_matches("www.").to_string())
                .or_else(|| web_address(other).map(|url| url.trim_start_matches("https://").to_string()));
            match domain {
                Some(domain) => web_search_address(&format!("site:{domain} {query}")),
                None => web_search_address(&format!("{other} {query}")),
            }
        }
    };
    address
}

/// A standard folder: its shell name (which follows a folder moved to OneDrive) and how to say it.
pub fn folder(name: &str) -> Option<(&'static str, &'static str)> {
    let name = name.trim().to_lowercase();
    let name = name.trim_start_matches("my ").trim_start_matches("the ").trim_end_matches(" folder");
    Some(match name {
        "downloads" | "download" => ("shell:Downloads", "Downloads"),
        "documents" | "document" | "docs" => ("shell:Personal", "Documents"),
        "desktop" => ("shell:Desktop", "Desktop"),
        "pictures" | "photos" | "images" => ("shell:My Pictures", "Pictures"),
        "music" | "songs" => ("shell:My Music", "Music"),
        "videos" | "movies" | "video" => ("shell:My Video", "Videos"),
        "home" | "user" | "profile" => ("shell:Profile", "your home folder"),
        "screenshots" => ("shell:Screenshots", "Screenshots"),
        "recycle bin" | "trash" | "bin" => ("shell:RecycleBinFolder", "the Recycle Bin"),
        "this pc" | "my computer" | "computer" | "drives" => ("shell:MyComputerFolder", "This PC"),
        _ => return None,
    })
}

// MARK: Keys

/// The virtual-key codes of "ctrl+shift+t", "enter", "alt+tab", "page down": modifiers first, the key last.
pub fn keys(spoken: &str) -> Option<Vec<u16>> {
    let text = spoken.trim().to_lowercase().replace(" + ", "+").replace(" plus ", "+");
    let mut codes = Vec::new();
    for part in text.split(['+', ' ']).filter(|p| !p.is_empty()) {
        codes.push(key(part)?);
    }
    (!codes.is_empty()).then_some(codes)
}

fn key(name: &str) -> Option<u16> {
    Some(match name {
        "ctrl" | "control" | "cmd" | "command" => 0x11,
        "shift" => 0x10,
        "alt" | "option" => 0x12,
        "win" | "windows" | "super" | "meta" => 0x5B,
        "enter" | "return" => 0x0D,
        "tab" => 0x09,
        "esc" | "escape" => 0x1B,
        "space" | "spacebar" => 0x20,
        "backspace" => 0x08,
        "delete" | "del" => 0x2E,
        "insert" | "ins" => 0x2D,
        "home" => 0x24,
        "end" => 0x23,
        "pageup" | "pgup" => 0x21,
        "pagedown" | "pgdn" => 0x22,
        "up" | "uparrow" => 0x26,
        "down" | "downarrow" => 0x28,
        "left" | "leftarrow" => 0x25,
        "right" | "rightarrow" => 0x27,
        "[" => 0xDB,
        "]" => 0xDD,
        "," | "comma" => 0xBC,
        "." | "period" | "dot" => 0xBE,
        "/" | "slash" => 0xBF,
        "-" | "minus" => 0xBD,
        "=" | "equals" => 0xBB,
        ";" => 0xBA,
        "'" => 0xDE,
        "`" => 0xC0,
        "\\" => 0xDC,
        f if f.starts_with('f') && f.len() <= 3 && f[1..].parse::<u16>().is_ok_and(|n| (1..=24).contains(&n)) => {
            0x6F + f[1..].parse::<u16>().ok()?
        }
        c if c.chars().count() == 1 => {
            let ch = c.chars().next()?.to_ascii_uppercase();
            if ch.is_ascii_alphanumeric() { ch as u16 } else { return None }
        }
        "page" => return None,
        _ => return None,
    })
}

// MARK: Apps

/// Browsers by what people call them, and their programs.
pub const BROWSERS: &[(&str, &str)] = &[
    ("chrome", "chrome.exe"), ("google chrome", "chrome.exe"), ("edge", "msedge.exe"), ("microsoft edge", "msedge.exe"),
    ("firefox", "firefox.exe"), ("mozilla firefox", "firefox.exe"), ("brave", "brave.exe"), ("opera", "opera.exe"),
    ("vivaldi", "vivaldi.exe"), ("arc", "arc.exe"),
];

pub fn browser_program(name: &str) -> Option<&'static str> {
    let name = name.trim().to_lowercase();
    let name = name.trim_end_matches(" browser");
    BROWSERS.iter().find(|(n, _)| *n == name).map(|(_, exe)| *exe)
}

/// Spoken names for apps whose names in the Start menu differ.
const ALIASES: &[(&str, &str)] = &[
    ("chrome", "google chrome"), ("edge", "microsoft edge"), ("word", "word"), ("ms word", "word"),
    ("microsoft word", "word"), ("excel", "excel"), ("powerpoint", "powerpoint"), ("power point", "powerpoint"),
    ("vs code", "visual studio code"), ("vscode", "visual studio code"), ("code", "visual studio code"),
    ("teams", "microsoft teams"), ("explorer", "file explorer"), ("files", "file explorer"),
    ("file manager", "file explorer"), ("calculator", "calculator"), ("calc", "calculator"),
    ("terminal", "terminal"), ("command prompt", "command prompt"), ("cmd", "command prompt"),
    ("store", "microsoft store"), ("photos", "photos"), ("camera", "camera"), ("paint", "paint"),
    ("snipping tool", "snipping tool"), ("task manager", "task manager"), ("control panel", "control panel"),
    ("whatsapp", "whatsapp"), ("sticky notes", "sticky notes"), ("notes", "sticky notes"), ("mail", "outlook"),
    ("clock", "clock"), ("alarms", "clock"), ("settings", "settings"), ("onenote", "onenote"),
];

/// Which of `names` (the Start menu's) a spoken app name means: exactly, by an alias, as the start of a name, or with
/// every word in it. None when nothing fits well.
pub fn match_app(asked: &str, names: &[String]) -> Option<usize> {
    let asked = asked.trim().to_lowercase();
    let asked = asked.trim_start_matches("the ").trim_end_matches(" app").trim();
    if asked.is_empty() {
        return None;
    }
    let lower: Vec<String> = names.iter().map(|n| n.to_lowercase()).collect();
    if let Some(i) = lower.iter().position(|n| n == asked) {
        return Some(i);
    }
    let wanted = ALIASES.iter().find(|(a, _)| *a == asked).map(|(_, n)| *n).unwrap_or(asked);
    if let Some(i) = lower.iter().position(|n| n == wanted) {
        return Some(i);
    }
    // "word" → "Word", "Microsoft Word", "Word 2016"; the shortest name wins (the app, not its helpers).
    let words: Vec<&str> = wanted.split_whitespace().collect();
    let mut best: Option<(usize, usize)> = None;
    for (i, name) in lower.iter().enumerate() {
        let parts: Vec<&str> = name.split(|c: char| !c.is_alphanumeric()).filter(|p| !p.is_empty()).collect();
        let fits = name.starts_with(&format!("{wanted} ")) || words.iter().all(|w| parts.contains(w));
        // Not the uninstallers, readmes and help files the Start menu also lists.
        let helper = ["uninstall", "readme", "help", "documentation", "website", "release notes", "license"].iter().any(|h| name.contains(h));
        if fits && !helper && best.is_none_or(|(_, len)| name.len() < len) {
            best = Some((i, name.len()));
        }
    }
    best.map(|(i, _)| i)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_pages() {
        assert_eq!(settings_page("windows update").0, "ms-settings:windowsupdate");
        assert_eq!(settings_page("wifi").0, "ms-settings:network-wifi");
        assert_eq!(settings_page("Bluetooth settings").0, "ms-settings:bluetooth");
        assert_eq!(settings_page("").0, "ms-settings:");
        assert_eq!(settings_page("dark mode").0, "ms-settings:personalization");
        assert_eq!(settings_page("something odd").1, "Settings");
    }

    #[test]
    fn addresses() {
        assert_eq!(web_address("youtube").as_deref(), Some("https://www.youtube.com"));
        assert_eq!(web_address("github.com/anthropics").as_deref(), Some("https://github.com/anthropics"));
        assert_eq!(web_address("saleshq dot ai").as_deref(), Some("https://saleshq.ai"));
        assert_eq!(web_address("not a site"), None);
        assert_eq!(site_search_address("youtube", "lofi beats"), "https://www.youtube.com/results?search_query=lofi+beats");
        assert_eq!(site_search_address("swiggy", "biryani"), "https://www.google.com/search?q=site%3Aswiggy.com+biryani");
        assert_eq!(encode("c++ & you"), "c%2B%2B+%26+you");
    }

    #[test]
    fn folders() {
        assert_eq!(folder("my downloads folder").unwrap().0, "shell:Downloads");
        assert_eq!(folder("videos").unwrap().1, "Videos");
        assert!(folder("taxes").is_none());
    }

    #[test]
    fn key_names() {
        assert_eq!(keys("ctrl+shift+t"), Some(vec![0x11, 0x10, b'T' as u16]));
        assert_eq!(keys("Enter"), Some(vec![0x0D]));
        assert_eq!(keys("alt + tab"), Some(vec![0x12, 0x09]));
        assert_eq!(keys("pagedown"), Some(vec![0x22]));
        assert_eq!(keys("f5"), Some(vec![0x74]));
        assert_eq!(keys("cmd+l"), Some(vec![0x11, b'L' as u16]));
        assert_eq!(keys("ctrl+nonsense"), None);
    }

    #[test]
    fn apps_by_spoken_name() {
        let names: Vec<String> = ["Google Chrome", "Word", "Visual Studio Code", "Uninstall Visual Studio Code", "Spotify",
                                  "Microsoft Teams", "File Explorer", "WhatsApp", "Notepad", "Notepad++"]
            .iter().map(|s| s.to_string()).collect();
        let found = |asked: &str| match_app(asked, &names).map(|i| names[i].as_str());
        assert_eq!(found("chrome"), Some("Google Chrome"));
        assert_eq!(found("vs code"), Some("Visual Studio Code"));
        assert_eq!(found("Spotify"), Some("Spotify"));
        assert_eq!(found("teams"), Some("Microsoft Teams"));
        assert_eq!(found("notepad"), Some("Notepad"));
        assert_eq!(found("the whatsapp app"), Some("WhatsApp"));
        assert_eq!(found("photoshop"), None);
        assert_eq!(browser_program("Edge"), Some("msedge.exe"));
    }
}
