//! What the person chose: the folders Murmur searches, what it skips in them, the hotkey, and whether setup is done. A
//! JSON file in the app's config folder (%APPDATA%\com.copico.Murmur on Windows, ~/.config/com.copico.Murmur on
//! Linux). Launch arguments (`--roots`, `--hotkey`) stand in for it in dev runs.

use crate::hours::Hours;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    /// The folders searched and kept indexed.
    pub folders: Vec<String>,
    /// Folders inside them that aren't (`FolderSelection` in the engine).
    pub skipped: Vec<String>,
    /// File extensions left out ("heic", "txt").
    pub skip_types: Vec<String>,
    /// The panel's hotkey (Tauri's accelerator form); empty: the default.
    pub hotkey: String,
    /// Onboarding is done: the shell starts in the tray.
    pub set_up: bool,
    /// The panel sits centered where the desktop places windows itself (Wayland), in a window that fills the screen.
    pub center_panel: bool,
    /// Index only between these times of day (hours.rs); the times are kept while it's off.
    pub index_hours_on: bool,
    pub index_hours: Hours,
    /// Code search: its folders (an index of its own, code.sqlite), the folders skipped inside them, and the editor its
    /// results open in (editors.rs: an editor's id, "" for the first one found, "default" for the file's default app).
    pub code_folders: Vec<String>,
    pub code_skipped: Vec<String>,
    pub code_editor: String,
    /// Code search was turned off and its index is still to be deleted (Windows won't delete a file a helper has open).
    pub delete_code_index: bool,
    /// Where the window was left, for the next time it opens.
    pub window: Option<WindowPlace>,
    /// A click on the tray icon (Windows): "panel" shows the search panel, anything else opens the window.
    pub tray_click: String,
    /// The daily check for updates was turned off (Settings → General; it's on by default).
    pub update_checks_off: bool,
    /// The model runs on the processor even where the graphics card measured faster (Settings → General): for a card
    /// whose results come back wrong or empty. The helpers get `MURMUR_DEVICE=cpu`.
    pub processor_only: bool,
    /// When Murmur last checked for updates (seconds since 1970).
    pub update_checked: u64,
    /// Dictation (Settings → Dictation; dictation/mod.rs): turned off, the key held to talk ("" for Ctrl + Windows),
    /// the speech model ("" for English), the microphone ("" for the system's default), and Quiet Voice turned off
    /// (it's on by default, as on the Mac).
    pub dictation_off: bool,
    pub dictation_key: String,
    pub speech_model: String,
    pub microphone: String,
    pub quiet_voice_off: bool,
    /// With the Sarvam model: how it writes ("" for English letters, "spoken", "english") and the language it expects
    /// ("" for detecting it).
    pub sarvam_output: String,
    pub sarvam_language: String,
    /// The Murmur button on screen (on unless turned off), and where it was left (physical pixels).
    pub floating_button_off: bool,
    /// Dictation's history (on unless turned off: Home's "This week"), and keeping every recording (off).
    pub history_off: bool,
    pub keep_recordings: bool,
    pub floating_button_at: Option<(i32, i32)>,
    /// Commands & AI (commands/mod.rs): the model ("" or "local" for Ollama on this PC, "anthropic", "openai",
    /// "sarvam"), each
    /// one's model name ("" for the default), the Anthropic workspace for an organization's key, AI clean-up of
    /// dictation (off by default, as on the Mac) and its style for each kind of app ("personal": "casual"…), and
    /// commands told apart from dictation without Shift (on unless turned off). The keys themselves are in Windows'
    /// Credential Manager, not here.
    pub ai_provider: String,
    pub local_model: String,
    pub anthropic_model: String,
    pub openai_model: String,
    pub sarvam_model: String,
    pub anthropic_workspace: String,
    pub ai_cleanup: bool,
    /// The model clean-up uses: "" for Murmur Cleanup when it's in Ollama (else the commands' model), "commands" for
    /// the commands' model always.
    pub cleanup_model: String,
    pub cleanup_styles: BTreeMap<String, String>,
    /// Grammar fixing of dictation (off by default, as on the Mac), on the clean-up model.
    pub grammar_fix: bool,
    pub detect_commands_off: bool,
    /// Commands don't learn from their mistakes (they do unless this is turned on).
    pub learn_off: bool,
    /// Murmur's windows show in screen sharing and recordings (they're left out unless this is turned on).
    pub show_in_sharing: bool,
    /// Meeting notes (meeting/mod.rs): offering them when a meeting app turns on the microphone (on unless turned off),
    /// answering by itself (on unless turned off), the AI for answers and notes ("" for the commands' model), who
    /// transcribes ("" for dictation's model, "sarvam", "openai"), your standing instructions, and the panel's look.
    pub meeting_offer_off: bool,
    /// A meeting with nothing said for ten minutes ends itself, unless this is on.
    pub meeting_stay_when_quiet: bool,
    pub meeting_auto_answer_off: bool,
    pub meeting_ai: String,
    pub meeting_speech: String,
    pub meeting_instructions: String,
    pub meeting_layout: String,
    pub meeting_opacity: Option<f64>,
    pub meeting_solid_on_hover_off: bool,
    pub meeting_text_size: Option<f64>,
}

impl Settings {
    /// Dictation as chosen here.
    pub fn dictation(&self) -> crate::dictation::Config {
        crate::dictation::Config {
            enabled: !self.dictation_off,
            key: crate::dictation::keys::Combo::from_name(&self.dictation_key),
            model: crate::dictation::speech::Model::from_name(&self.speech_model),
            microphone: self.microphone.clone(),
            quiet_voice: !self.quiet_voice_off,
            floating_button: !self.floating_button_off,
            keep_history: !self.history_off,
            keep_recordings: self.keep_recordings,
            sarvam: crate::dictation::cloud::Sarvam {
                output: crate::dictation::cloud::Output::from_name(&self.sarvam_output),
                language: if self.sarvam_language == "unknown" { String::new() } else { self.sarvam_language.clone() },
            },
        }
    }
}

impl Settings {
    /// Commands & AI as chosen here.
    pub fn assistant(&self) -> crate::commands::Choices {
        crate::commands::Choices {
            ai: crate::ai::Config {
                provider: crate::ai::Provider::from_name(&self.ai_provider),
                local_model: self.local_model.clone(),
                anthropic_model: self.anthropic_model.clone(),
                openai_model: self.openai_model.clone(),
                sarvam_model: self.sarvam_model.clone(),
                anthropic_workspace: self.anthropic_workspace.clone(),
            },
            cleanup: self.ai_cleanup,
            grammar: self.grammar_fix,
            own_cleanup: self.cleanup_model != "commands",
            styles: self.cleanup_styles.clone(),
            detect: !self.detect_commands_off,
            learn: !self.learn_off,
        }
    }
}

/// The window's size inside its frame (logical pixels), where it was (physical; Wayland doesn't tell), and whether it
/// filled the screen.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct WindowPlace {
    pub width: f64,
    pub height: f64,
    pub x: Option<i32>,
    pub y: Option<i32>,
    pub maximized: bool,
}

impl Settings {
    /// The file's settings, or the defaults when there's none (or it can't be read).
    pub fn load(path: &Path) -> Settings {
        std::fs::read(path).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    /// Written whole to a temporary file first, so a crash never leaves half of it.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(folder) = path.parent() {
            std::fs::create_dir_all(folder)?;
        }
        let temporary = path.with_extension("json.new");
        std::fs::write(&temporary, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(temporary, path)
    }
}
