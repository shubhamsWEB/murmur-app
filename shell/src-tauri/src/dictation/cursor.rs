//! The text around the cursor in the app the words are going into, so dictation can be fitted to the sentence it lands
//! in (fit.rs): the Mac's CursorContext, through Windows' UI Automation instead of Accessibility. A few characters before
//! the cursor (or the selection being replaced) and after it, from the focused element's text pattern. Apps that don't
//! say (some Electron apps, games, terminals) give nothing, and the text goes in as heard. Whether a word is an
//! ordinary dictionary word (so names keep their capital) is Windows' own spell checker.

/// Dictated text fitted to where it's going, or as heard when the app doesn't say what's around the cursor.
pub fn fit(text: &str) -> String {
    match around() {
        Some((before, after)) => super::fit::fit(text, &before, &after, is_word),
        None => text.to_string(),
    }
}

#[cfg(windows)]
pub use imp::{around, is_word};

#[cfg(not(windows))]
pub fn around() -> Option<(String, String)> {
    None
}

#[cfg(not(windows))]
pub fn is_word(_word: &str) -> bool {
    true
}

#[cfg(windows)]
mod imp {
    use windows::core::{Interface, HSTRING};
    use windows::Win32::Globalization::{ISpellCheckerFactory, SpellCheckerFactory};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, IUIAutomation, IUIAutomation2, IUIAutomationTextPattern, TextPatternRangeEndpoint_End,
        TextPatternRangeEndpoint_Start, TextUnit_Character, UIA_TextPatternId,
    };
    use windows::Win32::UI::WindowsAndMessaging::{GetClassNameW, GetForegroundWindow};

    /// Windows whose text before the cursor is a prompt, not a sentence: terminals.
    const TERMINALS: [&str; 8] = [
        "CASCADIA_HOSTING_WINDOW_CLASS", "ConsoleWindowClass", "mintty", "org.wezfurlong.wezterm", "Alacritty",
        "VirtualConsoleClass", "PuTTY", "TMobaXtermForm",
    ];

    fn in_terminal() -> bool {
        unsafe {
            let window = GetForegroundWindow();
            let mut name = [0u16; 128];
            let length = GetClassNameW(window, &mut name);
            let class = String::from_utf16_lossy(&name[..length.max(0) as usize]);
            TERMINALS.iter().any(|terminal| class == *terminal)
        }
    }

    /// Up to three characters before the cursor (or the selection) and two after it. None when the app doesn't say.
    pub fn around() -> Option<(String, String)> {
        if in_terminal() {
            return None;
        }
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
            // An app that's busy answers within a third of a second or not at all, as on the Mac.
            if let Ok(automation) = automation.cast::<IUIAutomation2>() {
                let _ = automation.SetConnectionTimeout(300);
                let _ = automation.SetTransactionTimeout(300);
            }
            let element = automation.GetFocusedElement().ok()?;
            let pattern: IUIAutomationTextPattern = element.GetCurrentPatternAs(UIA_TextPatternId).ok()?;
            let selections = pattern.GetSelection().ok()?;
            if selections.Length().ok()? < 1 {
                return None;
            }
            let selection = selections.GetElement(0).ok()?;
            let before = selection.Clone().ok()?;
            before.MoveEndpointByRange(TextPatternRangeEndpoint_End, &selection, TextPatternRangeEndpoint_Start).ok()?;
            before.MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -3).ok()?;
            let after = selection.Clone().ok()?;
            after.MoveEndpointByRange(TextPatternRangeEndpoint_Start, &selection, TextPatternRangeEndpoint_End).ok()?;
            after.MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 2).ok()?;
            let before = before.GetText(16).ok()?.to_string();
            let after = after.GetText(16).ok()?.to_string();
            Some((before, after))
        }
    }

    /// Whether a lowercase word is in Windows' English dictionary as it is (names and places aren't in lowercase).
    /// Without a spell checker every word counts, so a name may lose its capital mid-sentence.
    pub fn is_word(word: &str) -> bool {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let Ok(factory) = CoCreateInstance::<_, ISpellCheckerFactory>(&SpellCheckerFactory, None, CLSCTX_INPROC_SERVER) else {
                return true;
            };
            let Ok(checker) = factory.CreateSpellChecker(&HSTRING::from("en-US")) else { return true };
            let Ok(errors) = checker.Check(&HSTRING::from(word)) else { return true };
            let mut error = None;
            // S_FALSE and nothing: no spelling errors.
            let _ = errors.Next(&mut error);
            error.is_none()
        }
    }
}
