//! What the model may do on Windows, and its instructions: the Mac's tool list and system prompt (CommandAgent), cut
//! to the tools this PC has. Screen reading and clicking, browser automation and sending messages come later: the model
//! isn't offered them, and says so when asked.

use crate::ai::ToolSpec;
use serde_json::{json, Map, Value};

fn tool(name: &str, description: &str, properties: &[(&str, &str, &str)], required: Option<&[&str]>) -> ToolSpec {
    let mut props = Map::new();
    for (key, kind, detail) in properties {
        props.insert(key.to_string(), json!({"type": kind, "description": detail}));
    }
    let required: Vec<&str> = required.map(|r| r.to_vec()).unwrap_or_else(|| properties.iter().map(|p| p.0).collect());
    ToolSpec { name: name.into(), description: description.into(),
               parameters: json!({"type": "object", "properties": Value::Object(props), "required": required}) }
}

pub fn all() -> Vec<ToolSpec> {
    vec![
        tool("open_app", "Open or switch to an app", &[("name", "string", "app name as spoken")], None),
        tool("quit_app", "Close a running app (asks the user first)", &[("name", "string", "app name")], None),
        tool("hide_app", "Minimise a running app's windows", &[("name", "string", "app name")], None),
        tool("find_apps", "List installed apps matching a name", &[("query", "string", "part of the name")], None),
        tool("list_running_apps", "List the apps with open windows", &[], None),
        tool("open_folder", "Open a standard folder in File Explorer",
             &[("name", "string", "downloads, documents, desktop, pictures, music, videos or home")], None),
        tool("open_settings", "Open a page of Windows Settings (windows update, wifi, bluetooth, display, sound, \
              battery, privacy, apps, default apps, notifications, storage, mouse, keyboard…) or \"store updates\"",
             &[("page", "string", "the page")], None),
        tool("open_file", "Open the user's own file: by its full path or exact name when you know it (a match listed \
              earlier), else a description in the user's own words, e.g. \"lease 2025 pdf\": a clear best match opens, \
              otherwise you get the matches to pick from",
             &[("query", "string", "the file's full path, its exact name, or the user's description")], None),
        tool("search_files", "Search the user's files by meaning and show the results in Murmur's window",
             &[("query", "string", "what to look for")], None),
        tool("open_url", "Open a website, in a named browser if the user said one (\"open youtube on chrome\")",
             &[("url", "string", "address, e.g. github.com or youtube.com"),
               ("browser", "string", "browser to use, e.g. Chrome or Edge; empty for the default")], Some(&["url"])),
        tool("web_search", "Search the web in the browser",
             &[("query", "string", "search terms"), ("browser", "string", "browser to use; empty for the default")], Some(&["query"])),
        tool("site_search", "Search a website in the browser (youtube, google, amazon, flipkart, github, maps, \
              wikipedia, reddit, linkedin, spotify…)",
             &[("site", "string", "the site"), ("query", "string", "what to search")], None),
        tool("set_volume", "Set the output volume", &[("percent", "number", "0 to 100")], None),
        tool("change_volume", "Turn the volume up or down", &[("direction", "string", "up or down")], None),
        tool("mute", "Mute or unmute the sound", &[("on", "boolean", "true to mute")], None),
        tool("media_control", "Play or pause what's playing (a video, a song), or skip to the next or previous",
             &[("action", "string", "pause, play, next or previous")], None),
        tool("set_brightness", "Set the screen brightness to a percentage (a laptop's own screen)",
             &[("percent", "number", "0 to 100")], None),
        tool("brightness", "Make the screen brighter or dimmer", &[("direction", "string", "up or down")], None),
        tool("lock_screen", "Lock the PC", &[], None),
        tool("screenshot", "Open Windows' screenshot tool (Snipping Tool's overlay)", &[], None),
        tool("write_in_app", "Open an app (Notepad, Word, OneNote, Sticky Notes…), start a new document or note, and \
              type the text",
             &[("app", "string", "app name"), ("text", "string", "the full finished text to write"),
               ("new_document", "boolean", "true for a new document (default), false to add to the open one")],
             Some(&["app", "text"])),
        tool("insert_text", "Type finished text into the box the user was typing in when they spoke",
             &[("text", "string", "the text")], None),
        tool("replace_selection", "Put finished text in place of the user's selected text (a translation, a rewrite, \
              a fix)", &[("text", "string", "the finished text")], None),
        tool("type_text", "Type text into the app in front now (submit presses Enter)",
             &[("text", "string", "what to type"), ("submit", "boolean", "press Enter afterwards")], Some(&["text"])),
        tool("press_keys", "Press a key or shortcut in the app in front",
             &[("keys", "string", "e.g. enter, ctrl+l, ctrl+n, alt+tab, down, pagedown")], None),
        tool("read_clipboard", "Read the text on the clipboard (what the user copied)", &[], None),
        tool("copy_text", "Put text on the clipboard", &[("text", "string", "the text")], None),
        tool("paste_clipboard", "Paste what's on the clipboard into the box the user was typing in", &[], None),
        tool("wait", "Wait for an app or page to load", &[("seconds", "number", "0.5 to 6")], None),
        tool("run_command", "Run a PowerShell command on this PC (in the user's home folder) and return its output",
             &[("command", "string", "the command"),
               ("purpose", "string", "one short line on what it does, shown when the user is asked")], Some(&["command"])),
        tool("reply", "Show a short answer to the user", &[("text", "string", "the answer")], None),
        tool("remember", "Keep a lasting fact or preference the user told you, for every later command",
             &[("subject", "string", "what it's about, in a word or two: a person's name, \"browser\", \"message style\""),
               ("fact", "string", "the fact in plain words, e.g. \"Mom is Roma\"")], None),
        tool("forget_fact", "Forget a fact or preference the user told you before",
             &[("about", "string", "its subject or words from it")], None),
        tool("recall", "Look back through earlier commands and what they did (files and pages opened, answers given)",
             &[("query", "string", "words to find: a person, file, site or topic; empty for everything recent"),
               ("days", "number", "how far back, in days (default 30)")], Some(&["query"])),
        tool("done", "Finish when nothing more is needed", &[], None),
    ]
}

pub fn system_prompt() -> String {
    [
        "You are Murmur, a voice assistant on the user's Windows PC. The user spoke a command; carry it out with tools.",
        "Rules:",
        "- Respond only with tool calls. Work in steps until the WHOLE request is done: each response does what it can \
         (several calls in order are fine), then you see the results and go on. When everything the user asked for is \
         done, call done. If one response does it all (\"open Slack\"), put done at the end of that same response.",
        "- Apps: open_app, quit_app, hide_app, find_apps, list_running_apps. Use the app name the user said.",
        "- The user may speak Hinglish (Hindi in English letters) or Hindi. Understand it like English: kholo / kholkar \
         do / khol do = open; band karo = close or quit; chalao / bajao / play karo = play; dhundo / search karo = find; \
         dikhao = show; batao = tell; badhao / kam karo = turn up / down; mujhe = for me. \"Mujhe PDF kholkar do\" → \
         open_file \"PDF\".",
        "- Files: \"search\", \"find\" or \"look for\" means the user's own files on this PC: search_files. Opening one \
         (\"open my resume pdf\"): open_file with the description in the user's own distinctive words (\"Q3 sales \
         report\", \"lease 2025\"), never a generic word like \"document\". If it gives you matches, pick the user's \
         one and call open_file with its exact path, or reply that none fits. open_folder for standard folders.",
        "- The user's own documents (\"my resume\", \"my Aadhaar card\", \"my PAN card\", \"my passport\"): open_file with \
         what the document is, not the user's name: a name matches every file about them.",
        "- Web: web_search only when the user says web, online, internet or Google, or after opening a browser; \
         open_url for a site; site_search for a site's own search (\"search YouTube for lofi\").",
        "- Windows settings and updates: open_settings (\"check for updates\" → windows update). Wi-Fi and Bluetooth \
         can only be opened in Settings for the user to switch.",
        "- System: set_volume, change_volume, mute, media_control (pause or resume a playing video or song, next, \
         previous), set_brightness, brightness, lock_screen, screenshot.",
        "- To write something in an app (\"open Notepad and write a shopping list\", \"open Word and draft a letter \
         to…\"): call write_in_app ONCE with the app and the finished text, written by you in full (plain text, a \
         short title line first for notes). Don't call open_app as well.",
        "- Selected text (below, when there is any) is what \"this\", \"it\" and \"the selection\" mean. Do the whole \
         request in one go: write the summary, translation or rewrite yourself, then put it where the user asked. In \
         place of the selection: replace_selection. In another app: write_in_app. To read: reply.",
        "- To write text where the user is typing (no selection to replace), call insert_text with the finished text \
         only. type_text and press_keys work in the app in front now (after you opened it).",
        "- Terminal: run_command runs a PowerShell command on this PC and gives you its output (anything that changes \
         something is shown to the user first). Use it for what the other tools don't cover: disk space (Get-PSDrive), \
         battery (Get-CimInstance Win32_Battery), Wi-Fi details (netsh wlan show interfaces), IP address, file \
         operations (copy, move, rename, Compress-Archive), git, installed tools (winget list). One command at a time; \
         read the output, then go on or reply with the answer. Never run anything as administrator.",
        "- You can't see the screen, click, read web pages or send messages on Windows yet: when a request needs one \
         of those, reply in a sentence saying so, and what the user can do instead (select the text and ask again, \
         open the chat and dictate the message).",
        "- To answer a question, call reply with a short answer. reply ends the command: use it once, for the final \
         answer, never to describe a step.",
        "- Memory first: before acting, check the memory below. Use the user's name for their own documents, \
         nicknames for people, their chosen browser and apps, and every preference they told you.",
        "- Personal facts and preferences: when the user tells you something lasting about themselves or how they like \
         things done (\"remember that Mom is Roma\", \"from now on open links in Chrome\", \"call me Shubham\"), call \
         remember (the same subject again replaces it; the user's own name goes under subject \"my name\" as \"My name \
         is <full name>\"; forget_fact drops one), then reply in a few words. For anything further back than the \
         commands listed below, call recall.",
        "- Follow-ups: a request that continues an earlier command (listed below) uses its app, file or page. \"Open it \
         again\" → the same file; \"do it again\" → repeat it.",
        "- Don't give up after one try: when a step fails, try another way (another tool, or run_command). Only reply \
         that something can't be done once the tools truly can't do it.",
        "- When nothing more is needed, call done.",
    ].join("\n")
}

/// The tools that bring something up, and nothing more: on their own, they rarely finish a request with more than
/// one part ("open notepad and write…" isn't done when Notepad is open).
pub const OPENING_TOOLS: &[&str] = &["open_app", "open_url", "web_search", "site_search", "open_settings", "open_folder", "wait"];

#[cfg(test)]
mod tests {
    #[test]
    fn every_tool_is_named_once_and_described() {
        let tools = super::all();
        let mut names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
        let count = names.len();
        names.sort();
        names.dedup();
        assert_eq!(names.len(), count);
        for tool in &tools {
            assert!(!tool.description.is_empty());
            for required in tool.parameters["required"].as_array().unwrap() {
                assert!(tool.parameters["properties"].get(required.as_str().unwrap()).is_some(), "{} requires what it lacks", tool.name);
            }
        }
        let prompt = super::system_prompt();
        for name in ["open_file", "write_in_app", "insert_text", "remember", "run_command", "done"] {
            assert!(prompt.contains(name), "the prompt explains {name}");
        }
    }
}
