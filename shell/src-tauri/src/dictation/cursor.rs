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

/// Where the words would go, looked at when the key goes down: whether the focus is in a box you can type in, and
/// the text selected there (for "summarise this", "translate this").
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Spot {
    /// Some(true): a text field or document you can type in; Some(false): something else has the focus (a list, a
    /// button, the desktop); None: the app doesn't say.
    pub text_field: Option<bool>,
    pub selection: Option<String>,
    /// A terminal is in front: Ctrl+C there stops what's running, so the selection isn't copied with it.
    pub terminal: bool,
}

#[cfg(windows)]
pub use imp::{around, is_word, spot};

#[cfg(not(windows))]
pub fn spot() -> Spot {
    Spot::default()
}

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
        CUIAutomation, IUIAutomation, IUIAutomation2, IUIAutomationElement, IUIAutomationTextPattern,
        IUIAutomationValuePattern, TextPatternRangeEndpoint_End, TextPatternRangeEndpoint_Start, TextUnit_Character,
        UIA_ButtonControlTypeId, UIA_CheckBoxControlTypeId, UIA_ComboBoxControlTypeId, UIA_DataGridControlTypeId,
        UIA_DataItemControlTypeId, UIA_DocumentControlTypeId, UIA_EditControlTypeId, UIA_HyperlinkControlTypeId,
        UIA_ImageControlTypeId, UIA_ListControlTypeId, UIA_ListItemControlTypeId, UIA_MenuBarControlTypeId,
        UIA_MenuControlTypeId, UIA_MenuItemControlTypeId, UIA_RadioButtonControlTypeId, UIA_SliderControlTypeId,
        UIA_SplitButtonControlTypeId, UIA_TabItemControlTypeId, UIA_TableControlTypeId, UIA_TextPatternId,
        UIA_ToolBarControlTypeId, UIA_TreeControlTypeId, UIA_TreeItemControlTypeId, UIA_ValuePatternId,
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

    /// The focused element, asked with a short timeout: an app that's busy answers within a third of a second or not
    /// at all, as on the Mac.
    fn focused() -> Option<IUIAutomationElement> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
            if let Ok(automation) = automation.cast::<IUIAutomation2>() {
                let _ = automation.SetConnectionTimeout(300);
                let _ = automation.SetTransactionTimeout(300);
            }
            automation.GetFocusedElement().ok()
        }
    }

    /// Whether the focus is somewhere to type, and the text selected there.
    pub fn spot() -> super::Spot {
        if in_terminal() {
            return super::Spot { text_field: Some(true), selection: None, terminal: true };
        }
        let Some(element) = focused() else { return super::Spot::default() };
        unsafe {
            let kind = element.CurrentControlType().ok();
            let value: Option<IUIAutomationValuePattern> = element.GetCurrentPatternAs(UIA_ValuePatternId).ok();
            let read_only = value.as_ref().and_then(|v| v.CurrentIsReadOnly().ok()).map(|b| b.as_bool());
            // Things that clearly aren't for typing in (the desktop's icons, a folder's files, a player's buttons). Panes,
            // groups and custom elements stay unknown: a web app's own text box can look like one.
            let not_text = [UIA_ListControlTypeId, UIA_ListItemControlTypeId, UIA_TreeControlTypeId, UIA_TreeItemControlTypeId,
                            UIA_DataGridControlTypeId, UIA_DataItemControlTypeId, UIA_TableControlTypeId, UIA_ButtonControlTypeId,
                            UIA_SplitButtonControlTypeId, UIA_MenuItemControlTypeId, UIA_MenuControlTypeId, UIA_MenuBarControlTypeId,
                            UIA_TabItemControlTypeId, UIA_ImageControlTypeId, UIA_CheckBoxControlTypeId, UIA_RadioButtonControlTypeId,
                            UIA_SliderControlTypeId, UIA_HyperlinkControlTypeId, UIA_ToolBarControlTypeId];
            let text_field = match kind {
                Some(k) if k == UIA_EditControlTypeId || k == UIA_ComboBoxControlTypeId => Some(read_only != Some(true)),
                // A document: Word's and Notepad's take typing; a web page's says it's read-only.
                Some(k) if k == UIA_DocumentControlTypeId => Some(read_only != Some(true)),
                Some(k) if not_text.contains(&k) => Some(false),
                _ => None,
            };
            let selection = element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId).ok()
                .and_then(|pattern| pattern.GetSelection().ok())
                .and_then(|ranges| if ranges.Length().ok()? > 0 { ranges.GetElement(0).ok() } else { None })
                .and_then(|range| range.GetText(20_000).ok())
                .map(|text| text.to_string())
                .filter(|text| !text.trim().is_empty());
            super::Spot { text_field, selection, terminal: false }
        }
    }

    /// Up to three characters before the cursor (or the selection) and two after it. None when the app doesn't say.
    pub fn around() -> Option<(String, String)> {
        if in_terminal() {
            return None;
        }
        unsafe {
            let element = focused()?;
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
