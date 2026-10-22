//! The fast path: common commands are recognised by pattern and run at once, with no model ("open Slack", "quit
//! Spotify", "volume 30", "search the web for…"), as the Mac app's QuickCommands, with Windows' words (Settings pages,
//! the Videos folder, "update my PC"). Anything else goes to the model.

use fancy_regex::{Captures, Regex};
use std::collections::BTreeMap;
use std::sync::OnceLock;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Action {
    pub tool: String,
    pub arguments: BTreeMap<String, String>,
}

fn action(tool: &str, arguments: &[(&str, &str)]) -> Action {
    Action { tool: tool.into(), arguments: arguments.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect() }
}

/// What the quick path needs to know about this PC: whether an app by that name is installed.
pub trait Apps {
    fn resolves(&self, name: &str) -> bool;
}

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("a valid pattern"))
}

/// Normalizes what the speech model wrote: lowercase, no trailing punctuation, no "please" / "hey murmur".
pub fn clean(text: &str) -> String {
    static END: OnceLock<regex::Regex> = OnceLock::new();
    static POLITE: OnceLock<regex::Regex> = OnceLock::new();
    static POLITE_END: OnceLock<regex::Regex> = OnceLock::new();
    static SPACES: OnceLock<regex::Regex> = OnceLock::new();
    static CV: OnceLock<regex::Regex> = OnceLock::new();
    static PDF: OnceLock<regex::Regex> = OnceLock::new();
    static FALSE_START: OnceLock<Regex> = OnceLock::new();
    static COMMA_VERB: OnceLock<regex::Regex> = OnceLock::new();
    let r = |cell: &'static OnceLock<regex::Regex>, p: &str| cell.get_or_init(|| regex::Regex::new(p).unwrap());
    let mut s = text.trim().to_lowercase();
    s = r(&END, r"[.!?,;:]+$").replace(&s, "").into_owned();
    if let Some(rest) = super::wake::strip(&s).filter(|rest| !rest.is_empty()) {
        s = rest.to_lowercase(); // "Murmur, …" (or how the speech model spelled it)
    }
    s = r(&POLITE, r"^(please |can you |could you )+").replace(&s, "").into_owned();
    s = r(&POLITE_END, r"( please)$").replace(&s, "").into_owned();
    s = r(&SPACES, r"\s+").replace_all(&s, " ").into_owned();
    // Spelled-out letters: "C V" → "cv", "P D F" → "pdf".
    s = r(&CV, r"\bc\.? ?v\b\.?").replace_all(&s, "cv").into_owned();
    s = r(&PDF, r"\bp\.? ?d\.? ?f\b\.?").replace_all(&s, "pdf").into_owned();
    // A false start before the command: "a search for…", "uh, open…", "so find…".
    s = re(&FALSE_START, r"^(?:a|uh|um|erm|so|and|okay so|ok so),? (?=(?:search|find|open|show|look|pull|bring)\b)")
        .replace(&s, "").into_owned();
    // "Search, my resume": the comma after the verb isn't a pause between two commands.
    s = r(&COMMA_VERB, r"^([a-z]+), ").replace(&s, "$1 ").into_owned();
    s.trim().to_string()
}

/// Sites people open by name, and their home pages.
pub const SITES: &[(&str, &str)] = &[
    ("youtube", "https://www.youtube.com"), ("you tube", "https://www.youtube.com"), ("gmail", "https://mail.google.com"),
    ("google", "https://www.google.com"), ("github", "https://github.com"), ("linkedin", "https://www.linkedin.com"),
    ("twitter", "https://x.com"), ("reddit", "https://www.reddit.com"), ("amazon", "https://www.amazon.in"),
    ("flipkart", "https://www.flipkart.com"), ("netflix", "https://www.netflix.com"), ("wikipedia", "https://en.wikipedia.org"),
    ("instagram", "https://www.instagram.com"), ("facebook", "https://www.facebook.com"),
    ("whatsapp web", "https://web.whatsapp.com"), ("chatgpt", "https://chatgpt.com"), ("claude", "https://claude.ai"),
    ("perplexity", "https://www.perplexity.ai"), ("google maps", "https://www.google.com/maps"),
    ("google drive", "https://drive.google.com"), ("drive", "https://drive.google.com"),
    ("google docs", "https://docs.google.com"), ("google sheets", "https://sheets.google.com"),
    ("google calendar", "https://calendar.google.com"), ("stack overflow", "https://stackoverflow.com"),
    ("stackoverflow", "https://stackoverflow.com"), ("hacker news", "https://news.ycombinator.com"),
    ("spotify", "https://open.spotify.com"), ("notion", "https://www.notion.so"), ("figma", "https://www.figma.com"),
    ("outlook", "https://outlook.live.com"), ("youtube music", "https://music.youtube.com"),
    ("hotstar", "https://www.hotstar.com"), ("prime video", "https://www.primevideo.com"), ("swiggy", "https://www.swiggy.com"),
    ("zomato", "https://www.zomato.com"), ("myntra", "https://www.myntra.com"),
];

pub fn site(name: &str) -> Option<&'static str> {
    SITES.iter().find(|(n, _)| *n == name).map(|(_, url)| *url)
}

fn site_pattern() -> String {
    let mut names: Vec<&str> = SITES.iter().map(|(n, _)| *n).collect();
    names.sort_by_key(|n| std::cmp::Reverse(n.len()));
    names.iter().map(|n| fancy_regex::escape(n).into_owned()).collect::<Vec<_>>().join("|")
}

fn g<'a>(m: &'a Captures, i: usize) -> &'a str {
    m.get(i).map(|x| x.as_str()).unwrap_or("")
}

fn rules() -> &'static Vec<(Regex, fn(&Captures) -> Option<Action>)> {
    static RULES: OnceLock<Vec<(Regex, fn(&Captures) -> Option<Action>)>> = OnceLock::new();
    RULES.get_or_init(|| {
        let open_site = format!(r"^(?:open|go to|visit|launch|pull up|bring up) (?:the )?({})(?: website| site| page)?$", site_pattern());
        let table: Vec<(String, fn(&Captures) -> Option<Action>)> = vec![
            // "check for updates", "update my pc", "is there a windows update"
            (r"^(?:check|look|search)(?: for)? (?:any |new |the )?(?:windows |system |software )?updates?(?: (?:on|for) (?:my |the |this )?(?:pc|laptop|computer|system|windows))?$|^(?:update|upgrade) (?:my |the |this )?(?:pc|laptop|computer|system|windows)$|^(?:is there|are there) (?:a |an |any )?(?:windows |system |software )?updates?.*$".into(),
             |_| Some(action("open_settings", &[("page", "windows update")]))),
            (r"^(?:check for |update |show )?(?:my |all )?app (?:store )?updates$|^update (?:my |all )?apps$".into(),
             |_| Some(action("open_settings", &[("page", "store updates")]))),
            // "open wifi settings", "show display settings", "open settings for bluetooth", "open settings"
            (r"^(?:open|show|go to) (?:the |my )?(?:system |windows )?(?:settings|preferences|control panel)(?: for)?(?: (.+))?$|^(?:open|show|go to) (?:the |my )?(.+?) (?:settings|preferences)$".into(),
             |m| Some(action("open_settings", &[("page", if g(m, 1).is_empty() { g(m, 2) } else { g(m, 1) })]))),
            // "open my resume pdf", "pull up the lease document", "open my cv": the best match, straight away.
            (r"^(?:open|pull up|bring up)(?: up)? (?:my |the |that |this |our )?((?:.+? )?(?:pdfs?|docx?|documents?|word doc|files?|photos?|pictures?|images?|videos?|screenshots?|recordings?|spreadsheets?|sheets?|slides|decks?|presentations?|resumes?|résumés?|cvs?|receipts?|invoices?|contracts?|leases?|statements?|notes?))$".into(),
             |m| {
                 let query = g(m, 1);
                 // "open notes and write…" is a chain for the model, not a file called that.
                 if regex::Regex::new(r"\b(and|then)\b").unwrap().is_match(query) { return None; }
                 // "open photos" / "open notes" are apps; a file needs more than the type word.
                 if !query.contains(' ') && !["resume", "resumes", "résumé", "cv", "receipt", "invoice", "contract", "lease"].contains(&query) {
                     return None;
                 }
                 Some(action("open_file", &[("query", query)]))
             }),
            // The standard folders by name ("open videos" is the Videos folder, not a search for videos).
            (r"^open (?:my |the )?(downloads|documents|desktop|pictures|music|videos|movies|home)(?: folder)?$".into(),
             |m| Some(action("open_folder", &[("name", g(m, 1))]))),
            // "my photos on the beach", "show me pictures of the dog", "screenshots from last week"
            (r"^(?:show me |show |find |get |open |search for |look for )?(?:all )?(?:my |the |some )?((?:photos?|pictures?|pics|images?|screenshots?|videos?|clips?|recordings?|documents?|docs|pdfs?|files?|slides|presentations?|spreadsheets?|receipts?|invoices?)\b.*)$".into(),
             |m| Some(action("search_files", &[("query", g(m, 1))]))),
            (r"^(?:find|search for|search) (?:my |the )?(?:file|files|document|documents|pdf|photo|picture)s?(?: about| called| named| with)? (.+)$".into(),
             |m| Some(action("search_files", &[("query", g(m, 1))]))),
            // A site's own search: "search youtube for lofi", "find usb hubs on amazon".
            (r"^(?:search|look up|find|look for) (?:on |in )?(youtube|google images|google maps|google|amazon|flipkart|github|wikipedia|reddit|twitter|linkedin|stack ?overflow|spotify|netflix|maps)(?: for)? (.+)$".into(),
             |m| Some(action("site_search", &[("site", g(m, 1)), ("query", g(m, 2))]))),
            (r"^(?:search|look up|find|look for) (?:for )?(.+?) (?:on|in) (youtube|google images|google maps|amazon|flipkart|github|wikipedia|reddit|twitter|linkedin|stack ?overflow|spotify|netflix)$".into(),
             |m| Some(action("site_search", &[("site", g(m, 2)), ("query", g(m, 1))]))),
            // The web only when you say so: "google …", "search the web for …", "… on google", "look up …".
            (r"^(?:search|look) (?:on |in )?(?:the web|the internet|online|google)(?: for)? (.+)$".into(),
             |m| Some(action("web_search", &[("query", g(m, 1))]))),
            (r"^(?:search|look up|find) (?:for )?(.+?) (?:on google|on the web|on the internet|online)$".into(),
             |m| Some(action("web_search", &[("query", g(m, 1))]))),
            (r"^google (?:for )?(.+)$".into(), |m| Some(action("web_search", &[("query", g(m, 1))]))),
            (r"^look up (.+)$".into(), |m| Some(action("web_search", &[("query", g(m, 1))]))),
            // Everything else called "search" or "find" is your own files: "find the lease", "search my laptop for…".
            (r"^(?:search|find|look for)(?: (?:my |the )?(?:laptop|pc|computer|files|drive|disk))?(?: for)? (.+?)(?: (?:on|in) (?:my |the )?(?:laptop|pc|computer|files|drive|disk))?$".into(),
             |m| Some(action("search_files", &[("query", g(m, 1))]))),
            (r"^(?:open|go to|visit) ((?:https?://)?[a-z0-9-]+(?:\.| dot )[a-z.]{2,}(?:/\S*)?)$".into(),
             |m| Some(action("open_url", &[("url", &g(m, 1).replace(" dot ", "."))]))),
            (open_site, |m| Some(action("open_url", &[("url", site(g(m, 1)).unwrap_or(g(m, 1))), ("site", g(m, 1))]))),
            (r"^(?:open|launch|start|switch to|go to|show) (?:the )?(.+?)(?: app)?$".into(),
             |m| Some(action("open_app", &[("name", g(m, 1))]))),
            (r"^(?:quit|close|exit|kill) (?:the )?(.+?)(?: app)?$".into(), |m| Some(action("quit_app", &[("name", g(m, 1))]))),
            (r"^(?:hide|minimi[sz]e) (?:the )?(.+?)(?: app)?$".into(), |m| Some(action("hide_app", &[("name", g(m, 1))]))),
            (r"^(?:set )?(?:the )?volume (?:to )?(\d{1,3})(?: percent|%)?$".into(), |m| Some(action("set_volume", &[("percent", g(m, 1))]))),
            (r"^(?:turn )?(?:the )?volume (up|down)$|^turn (up|down) (?:the )?volume$|^(louder|quieter|softer)$".into(),
             |m| {
                 let word = [g(m, 1), g(m, 2), g(m, 3)].into_iter().find(|w| !w.is_empty()).unwrap_or("up");
                 Some(action("change_volume", &[("direction", if word == "louder" || word == "up" { "up" } else { "down" })]))
             }),
            // "stop the video", "pause", "pause the music on spotify", "resume": the media keys.
            (r"^(pause|stop|resume|unpause|continue|play)(?: playing)?(?: (?:the |this |my |that )?(?:video|music|song|playback|media|youtube|spotify|audio|track|podcast|movie|it))?(?: (?:on|in) (?:youtube|spotify|chrome|edge|music))?(?: again)?$".into(),
             |m| Some(action("media_control", &[("action", if ["play", "resume", "unpause", "continue"].contains(&g(m, 1)) { "play" } else { "pause" })]))),
            (r"^(?:next|skip)(?: (?:to the next )?(?:the |this )?(?:video|song|track|one))?$|^(?:play |go to )?(?:the )?next (?:video|song|track|one)$".into(),
             |_| Some(action("media_control", &[("action", "next")]))),
            (r"^(?:play |go to )?(?:the )?(?:previous|last) (?:video|song|track|one)$|^previous(?: (?:video|song|track))?$".into(),
             |_| Some(action("media_control", &[("action", "previous")]))),
            (r"^(?:(?:set|make|change|put|turn|bring) )?(?:the )?(?:screen |display )?brightness (?:to |at |up to |down to )?(\d{1,3})(?: ?percent| ?%)?$".into(),
             |m| Some(action("set_brightness", &[("percent", g(m, 1))]))),
            // Wi-Fi and Bluetooth: Windows lets an app open their settings, not switch them.
            (r"^(?:turn|switch|put) (?:on|off) (?:the |my )?(bluetooth|wi-?fi|wifi|wireless)$|^(?:turn|switch|put) (?:the |my )?(bluetooth|wi-?fi|wifi|wireless) (?:on|off)$|^(?:enable|disable) (?:the |my )?(bluetooth|wi-?fi|wifi|wireless)$".into(),
             |m| {
                 let thing = [g(m, 1), g(m, 2), g(m, 3)].into_iter().find(|w| !w.is_empty()).unwrap_or("wifi");
                 Some(action("open_settings", &[("page", if thing == "bluetooth" { "bluetooth" } else { "wifi" })]))
             }),
            (r"^(mute|unmute)(?: (?:the )?(?:sound|volume|audio|pc|computer))?$".into(),
             |m| Some(action("mute", &[("on", if g(m, 1) == "mute" { "true" } else { "false" })]))),
            (r"^(?:turn )?(?:the )?(?:screen )?brightness (up|down)$|^(brighter|dimmer)$".into(),
             |m| {
                 let word = if g(m, 1).is_empty() { g(m, 2) } else { g(m, 1) };
                 Some(action("brightness", &[("direction", if word == "up" || word == "brighter" { "up" } else { "down" })]))
             }),
            (r"^lock (?:the |my )?(?:screen|pc|computer|laptop)$".into(), |_| Some(action("lock_screen", &[]))),
            (r"^(?:take a )?screenshot$|^take a screen shot$".into(), |_| Some(action("screenshot", &[]))),
        ];
        table.into_iter().map(|(pattern, make)| (Regex::new(&pattern).expect("a valid rule"), make)).collect()
    })
}

/// Words a chained command can start with ("open chrome and search facebook", "mute then lock the screen").
const VERBS: &[&str] = &["open", "launch", "start", "switch", "go", "visit", "show", "quit", "close", "exit", "kill",
                           "hide", "search", "google", "look", "find", "set", "turn", "volume", "mute", "unmute",
                           "louder", "quieter", "softer", "brightness", "brighter", "dimmer", "lock", "take",
                           "screenshot", "run", "my", "photos", "pictures", "play", "watch", "type", "write", "press",
                           "pause", "next", "skip", "minimize", "minimise", "resume", "stop"];

/// All the actions in a chained command, in order, or None unless every part is a known command. Splits only where
/// the next part starts with a command verb, so "search for salt and pepper" stays whole.
pub fn parse_all(utterance: &str, apps: &dyn Apps) -> Option<Vec<Action>> {
    let text = clean(utterance);
    if text.is_empty() || text.chars().count() >= 200 {
        return None;
    }
    let words: Vec<String> = text.replace(',', " ,").split_whitespace().map(String::from).collect();
    let joiners = ["and", "then", ","];
    let (mut parts, mut current): (Vec<String>, Vec<String>) = (vec![], vec![]);
    let mut i = 0;
    while i < words.len() {
        if joiners.contains(&words[i].as_str()) && !current.is_empty() {
            let mut j = i;
            while j < words.len() && joiners.contains(&words[j].as_str()) {
                j += 1;
            }
            if j < words.len() && VERBS.contains(&words[j].as_str()) {
                parts.push(current.join(" "));
                current.clear();
                i = j;
                continue;
            }
        }
        if words[i] != "," {
            current.push(words[i].clone());
        }
        i += 1;
    }
    if !current.is_empty() {
        parts.push(current.join(" "));
    }
    let actions: Option<Vec<Action>> = parts.iter().map(|part| parse(part, apps)).collect();
    actions.filter(|a| !a.is_empty())
}

/// The action for a common command, or None to let the model decide.
pub fn parse(utterance: &str, apps: &dyn Apps) -> Option<Action> {
    static SUFFIX: OnceLock<Regex> = OnceLock::new();
    static CHAIN_WORDS: OnceLock<regex::Regex> = OnceLock::new();
    let mut text = clean(utterance);
    if text.is_empty() || text.chars().count() >= 120 {
        return None;
    }
    // "… on chrome", "… in edge", "… using firefox": which browser, said at the end ("" = the default one).
    let mut browser: Option<String> = None;
    if let Ok(Some(found)) = re(&SUFFIX, r" (?:on|in|using|with|from) (?:the |my )?(google chrome|chrome|firefox|brave|microsoft edge|edge|opera|vivaldi|arc|browser|web browser)$").captures(&text) {
        let name = g(&found, 1).to_string();
        let start = found.get(0).unwrap().start();
        browser = Some(if name.ends_with("browser") { String::new() } else { name });
        text.truncate(start);
    }
    if let Some(browser) = browser {
        if text.is_empty() {
            return None; // "open chrome" and nothing else is just the app
        }
        for (rule, make) in rules() {
            let Ok(Some(m)) = rule.captures(&text) else { continue };
            let Some(mut found) = make(&m) else { continue };
            // "search flights on chrome": with a browser named, a search means the web.
            if found.tool == "search_files" {
                found = action("web_search", &[("query", found.arguments.get("query").map(String::as_str).unwrap_or_default())]);
            } else if found.tool == "open_app" {
                // "open notion on chrome": a site we don't know by name; open it as an address.
                let name = found.arguments.get("name").cloned().unwrap_or_default();
                if name.contains(' ') && name.chars().count() >= 20 {
                    return None;
                }
                found = action("open_url", &[("url", &format!("{}.com", name.replace(' ', "")))]);
            } else if !["open_url", "web_search", "site_search"].contains(&found.tool.as_str()) {
                return None;
            }
            if !browser.is_empty() {
                found.arguments.insert("browser".into(), browser.clone());
            }
            return Some(found);
        }
        return None;
    }
    for (rule, make) in rules() {
        let Ok(Some(m)) = rule.captures(&text) else { continue };
        let Some(found) = make(&m) else { continue };
        // "open spotify" with the Spotify app installed: the app, not the website.
        if found.tool == "open_url" {
            if let Some(site) = found.arguments.get("site") {
                if apps.resolves(site) {
                    continue;
                }
            }
        }
        // "open X" only takes the fast path when X is a real app; otherwise the model decides.
        if ["open_app", "quit_app", "hide_app"].contains(&found.tool.as_str()) {
            let name = found.arguments.get("name").cloned().unwrap_or_default();
            // "open notepad and write a list": more than opening an app; the model does the whole thing.
            if CHAIN_WORDS.get_or_init(|| regex::Regex::new(r"\b(and|then|to|with|about)\b").unwrap()).is_match(&name) {
                return None;
            }
            if found.tool == "open_app" && !apps.resolves(&name) {
                return None;
            }
            if name.split_whitespace().count() > 4 {
                return None;
            }
        }
        return Some(found);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    struct These(&'static [&'static str]);
    impl Apps for These {
        fn resolves(&self, name: &str) -> bool {
            self.0.iter().any(|app| app.eq_ignore_ascii_case(name))
        }
    }
    const APPS: These = These(&["slack", "spotify", "notepad", "chrome", "visual studio code", "word"]);

    fn one(text: &str) -> Option<(String, Vec<(String, String)>)> {
        parse(text, &APPS).map(|a| (a.tool, a.arguments.into_iter().collect()))
    }

    fn tool(text: &str) -> Option<String> {
        parse(text, &APPS).map(|a| a.tool)
    }

    fn arg(text: &str, key: &str) -> String {
        parse(text, &APPS).and_then(|a| a.arguments.get(key).cloned()).unwrap_or_default()
    }

    #[test]
    fn cleaning() {
        assert_eq!(clean("Murmur, please open Spotify."), "open spotify");
        assert_eq!(clean("Uh, open my C V"), "open my cv");
        assert_eq!(clean("Search, my resume"), "search my resume");
        assert_eq!(clean("can you   find the P D F please"), "find the pdf");
    }

    #[test]
    fn apps_and_sites() {
        assert_eq!(one("Open Slack."), Some(("open_app".into(), vec![("name".into(), "slack".into())])));
        assert_eq!(tool("open some app nobody has"), None, "not installed: the model decides");
        assert_eq!(tool("open notepad and write a shopping list"), None);
        assert_eq!(arg("open youtube", "url"), "https://www.youtube.com");
        assert_eq!(tool("open spotify"), Some("open_app".into()), "the app, when it's installed");
        assert_eq!(arg("go to github dot com", "url"), "github.com");
        assert_eq!(one("quit spotify"), Some(("quit_app".into(), vec![("name".into(), "spotify".into())])));
        assert_eq!(tool("minimise chrome"), Some("hide_app".into()));
    }

    #[test]
    fn searches() {
        assert_eq!(one("search youtube for lofi beats").unwrap().1,
                   vec![("query".into(), "lofi beats".into()), ("site".into(), "youtube".into())]);
        assert_eq!(arg("find usb hubs on amazon", "site"), "amazon");
        assert_eq!(arg("google the weather in pune", "query"), "the weather in pune");
        assert_eq!(arg("search the web for flights to goa", "query"), "flights to goa");
        assert_eq!(tool("find the lease"), Some("search_files".into()));
        assert_eq!(arg("search my laptop for the invoice", "query"), "the invoice");
        assert_eq!(arg("my photos from goa", "query"), "photos from goa");
        // A browser named: the web, in that browser.
        let found = parse("search flights to goa on chrome", &APPS).unwrap();
        assert_eq!(found.tool, "web_search");
        assert_eq!(found.arguments["browser"], "chrome");
        assert_eq!(parse("open notion on edge", &APPS).unwrap().arguments["url"], "https://www.notion.so");
        assert_eq!(parse("open saleshq on edge", &APPS).unwrap().arguments["url"], "saleshq.com");
    }

    #[test]
    fn files_and_folders() {
        assert_eq!(arg("open my resume pdf", "query"), "resume pdf");
        assert_eq!(arg("open my cv", "query"), "cv");
        assert_eq!(tool("open notes"), None, "an app name, not a file");
        assert_eq!(arg("open the downloads folder", "name"), "downloads");
        assert_eq!(arg("open videos", "name"), "videos");
    }

    #[test]
    fn system() {
        assert_eq!(arg("set the volume to 30%", "percent"), "30");
        assert_eq!(arg("volume 30", "percent"), "30");
        assert_eq!(arg("louder", "direction"), "up");
        assert_eq!(arg("turn down the volume", "direction"), "down");
        assert_eq!(arg("pause the video", "action"), "pause");
        assert_eq!(arg("resume", "action"), "play");
        assert_eq!(arg("next song", "action"), "next");
        assert_eq!(arg("brightness 40", "percent"), "40");
        assert_eq!(arg("dimmer", "direction"), "down");
        assert_eq!(arg("mute", "on"), "true");
        assert_eq!(arg("unmute the sound", "on"), "false");
        assert_eq!(arg("turn off bluetooth", "page"), "bluetooth");
        assert_eq!(arg("enable wifi", "page"), "wifi");
        assert_eq!(tool("lock my pc"), Some("lock_screen".into()));
        assert_eq!(tool("take a screenshot"), Some("screenshot".into()));
        assert_eq!(arg("check for updates", "page"), "windows update");
        assert_eq!(arg("update my laptop", "page"), "windows update");
        assert_eq!(arg("open display settings", "page"), "display");
        assert_eq!(arg("open settings", "page"), "");
    }

    #[test]
    fn chains() {
        let actions = parse_all("open chrome and search facebook", &APPS).unwrap();
        assert_eq!(actions.iter().map(|a| a.tool.as_str()).collect::<Vec<_>>(), ["open_app", "search_files"]);
        let actions = parse_all("mute, then lock the screen", &APPS).unwrap();
        assert_eq!(actions.iter().map(|a| a.tool.as_str()).collect::<Vec<_>>(), ["mute", "lock_screen"]);
        assert_eq!(parse_all("search for salt and pepper", &APPS).unwrap().len(), 1);
        assert!(parse_all("open spotify and tell me a joke", &APPS).is_none(), "one part unknown: the model");
        assert!(parse_all("I'll call you back in an hour", &APPS).is_none());
    }
}
