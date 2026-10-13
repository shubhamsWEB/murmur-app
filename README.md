<p align="center"><img src="Resources/AppIcon/preview-1024.png" width="112" alt=""></p>

<h1 align="center">Murmur</h1>

<p align="center"><b>Talk anywhere. Find anything.</b><br>
A free voice assistant for your Mac. Dictation, commands and search, with speech recognised on your Mac.</p>

## What it does

- **Dictation in any app.** Hold **Fn**, speak, let go: the text appears where you're typing. Double-tap Fn for
  hands-free; tap again to finish, Esc to cancel. Whisper Mode boosts quiet speech.
- **Commands.** "Open Chrome and search Facebook", "quit Spotify", "volume 30", "summarise this" (with text
  selected). Murmur tells commands from dictation by itself; Fn+⌃ always means a command.
- **Search your files by meaning.** "The clause about pets in the lease", "a dog on the beach", "where they talk
  about sleep": photos, PDFs, documents, audio and video, searched on your Mac (⇧⌘Space, or by voice).

Speech recognition: NVIDIA Parakeet on the Neural Engine. File search: Google DeepMind's EmbeddingGemma 2. Commands:
a local model in Ollama, or optionally Claude Haiku or GPT-6 Luna with your own API key.

## Commands

Just hold **Fn** and speak: Murmur decides whether it's a command or text to type (Commands & Assistants →
Detect Commands Automatically, on by default). **Fn+⌃** always means a command.

How it decides (typing is the default): ⌃ held → command; a known command like "open Slack" or "open chrome and
search facebook" → command; starts with "Murmur…" → command; doesn't open like an instruction to the computer → typed (messages and questions like "send…" or "what's…" are
typed unless you say "Murmur" first or hold ⌃); opens like one ("open…", "summarise…", "translate…") → command if you're somewhere you can't type (Finder, desktop),
otherwise the router decides (typed if it can't answer in 2.5 s). Chrome and Electron apps often hide their text
fields from Accessibility; that counts as "might be a text field", never as "nowhere to type".
If a guessed command only produces an answer, the words are typed instead. Murmur's menu → Open Log shows each
decision as `intent: … (reason)`.

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

**Router choice** (Commands & Assistants → Router): Local (Ollama, free, offline), Claude (`claude-haiku-5-5`,
fastest, thinking off and low effort) or OpenAI (`gpt-6-luna`). Cloud routers need an API key, added from the same
menu and kept in the macOS Keychain. Only command text goes to the cloud (your words, the front app's name and any
selected text), never audio. If the cloud call fails, Murmur falls back to the local model. Other model ids:
`defaults write com.copico.Murmur anthropicModel <id>` / `openaiModel <id>`.

Setup: install [Ollama](https://ollama.com) (you have it), then `ollama pull qwen3:4b`. Pick another router model
under Commands & Assistants (`qwen3:1.7b` is faster, `qwen3:8b` is smarter).

## Build and run

Needs an Apple Silicon Mac, macOS 14+, and Xcode 26 (Swift 6.2).

```bash
cd ~/IdeaProjects/murmur
./build.sh                         # first build fetches packages and compiles llama.cpp: 10+ minutes
open build.noindex/Murmur.app
```

To work in Xcode instead: `open Package.swift`, pick the **MurmurApp** scheme, and run. Use `./build.sh` to test
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

## Data and privacy

Murmur's settings, index and models live in `~/Library/Application Support/Murmur`.
Audio is held in memory only for transcription and is never saved. The only network use is the one-time model
downloads from Hugging Face, and (only if you choose a cloud router) command text sent to that provider.

## Credits

Murmur is built on [DigUp](https://github.com/ARahim3/DigUp) by Abdur Rahim (MIT), which provides its file index and
search. Speech recognition runs on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0). Full
notices: `Resources/Acknowledgements.txt` and `LICENSE`.
