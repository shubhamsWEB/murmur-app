# Murmur

Murmur is a free, fully local voice assistant for macOS, built on [DigUp](https://github.com/ARahim3/DigUp) (MIT).
Speech recognition, cleanup and search all run on your Mac. The design spec is in your Claude docs:
"Local Voice Assistant for Mac — Design Spec".

## Milestone 1: dictation core (this commit)

- **Hold Fn (🌐)** to talk, release to insert the text into whatever app you're typing in.
- **Double-tap Fn** for hands-free dictation. Tap Fn again to finish, or press Esc to cancel.
- Speech to text is Parakeet TDT v3 on the Neural Engine, through [FluidAudio](https://github.com/FluidInference/FluidAudio).
  The model downloads once (about 600 MB) on first launch, then works offline.
- Text goes in with clipboard + ⌘V, and your clipboard is restored afterwards.
- No Fn key on your keyboard? Pick **Right ⌥** in the menu bar under **Dictation Key**.
- DigUp's search panel still opens with **⇧⌘Space**.

Code: `Sources/VoiceKit` (new). Small hooks in `Sources/DigUpApp/AppController.swift` and `StatusMenu.swift`.

## Commands (milestones 3 and 5)

Just hold **Fn** and speak: Murmur decides whether it's a command or text to type (Commands & Assistants →
Detect Commands Automatically, on by default). **Fn+⌃** always means a command.

How it decides, cheapest first: ⌃ held → command; no text field focused → command; a known command like "open Slack"
→ command; starts with "Murmur…" → command; in a text field and it opens like an instruction ("send…", "summarise…",
"what's…") → the router model decides in under ~0.5 s (typed if it can't answer in 2.5 s); anything else → typed.
The log line `intent: … (reason)` says which rule decided.

- **Instant, no model:** "open Slack", "quit Spotify", "hide Xcode", "volume 30", "volume up", "mute", "brightness
  down", "lock the screen", "take a screenshot", "search the web for …", "find my files about …", "open downloads",
  "open github.com", "run shortcut Morning".
- **Everything else** goes to a small local model in Ollama (default `qwen3:4b`) that picks tools: apps, files, web,
  system, Shortcuts, writing text into the app you're in ("make this shorter" works on the selected text), or
  answering in a small panel.
- **Claude Code and Codex as helpers:** off until you allow them in the menu (Commands & Assistants). The router
  sends them a focused sub-task, reads the answer, and decides what to do with it. Each run asks first. They run with
  your own login: Claude Code with `--permission-mode dontAsk`, Codex with `--sandbox read-only`, so they can't change
  files on their own.
- **Asks first:** quitting an app, running a Shortcut, and every Claude Code or Codex run.

Setup: install [Ollama](https://ollama.com) (you have it), then `ollama pull qwen3:4b`. Pick another router model
under Commands & Assistants (`qwen3:1.7b` is faster, `qwen3:8b` is smarter).

## Build and run

Needs an Apple Silicon Mac, macOS 14+, and Xcode 26 (Swift 6.2).

```bash
cd ~/IdeaProjects/murmur
./build.sh                         # first build fetches packages and compiles llama.cpp: 10+ minutes
open build.noindex/Murmur.app
```

To work in Xcode instead: `open Package.swift`, pick the **DigUpApp** scheme, and run. Use `./build.sh` to test
permissions, because only a signed .app bundle keeps them.

### Signing (so permissions stick between builds)

With no identity, `build.sh` signs ad hoc, and macOS forgets the Accessibility permission after every rebuild.
Use your free Apple Development certificate instead (Xcode → Settings → Accounts → add your Apple ID):

```bash
security find-identity -v -p codesigning     # copy the "Apple Development: …" name
echo "Apple Development: Your Name (TEAMID)" > .sign-id
```

## First launch checklist

1. **Microphone:** allow when asked.
2. **Accessibility:** System Settings → Privacy & Security → Accessibility → turn on Murmur. Murmur needs this to
   see the Fn key and to paste. It starts working within 2 seconds of being allowed.
3. **Fn key:** System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**. Otherwise Fn also opens the
   emoji picker or Apple's dictation.
4. Wait for the menu bar menu to say "Speech model ready", then hold Fn in Notes and talk.

Optional: DigUp's search model (865 MB) downloads again into Murmur's own folder. If DigUp is already installed,
copy its model instead (APFS clones it, so it takes no extra space):

```bash
mkdir -p ~/Library/Application\ Support/Murmur
cp -cR ~/Library/Application\ Support/DigUp/Models ~/Library/Application\ Support/Murmur/
```

## Known limits in milestone 1

- No LLM cleanup yet: you get Parakeet's text as heard, with its punctuation (milestone 2).
- English and 24 other European languages only. Hindi arrives with WhisperKit in milestone 3.
- The first word can be clipped if you start talking the instant you press Fn (the mic takes about 0.2 s to open).
- Internal names (the `DigUpApp` target, `DigUpKit`) still say DigUp; everything you see says Murmur.

## Data and privacy

Murmur's settings, index and models live in `~/Library/Application Support/Murmur`, apart from DigUp's.
Audio is held in memory only for transcription and is never saved. The only network use is the one-time model
downloads from Hugging Face. DigUp's update checks are turned off.
