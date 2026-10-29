# Murmur agent-harness plan

## Goal

Make Murmur dependable for consequential, multi-step work without turning a quick voice command into a slow
multi-agent task. The design borrows the useful parts of an agent harness: scoped context, deterministic policy,
visible plans, verification, and evidence-backed learning.

## Architecture

```
utterance → intent/request envelope → policy + scoped memory → workflow/agent loop → tool executor
                                                                    ↓                    ↓
                                                          plan and evidence        event ledger
                                                                    ↓                    ↓
                                                        reviewed learning ← verification
```

The model proposes tool calls. Policy, memory scope, and verification remain application code, so they cannot be
overridden by an ambiguous prompt, a stale command, or page content.

## Delivery phases

### 1. Safe context and consequential actions

- [x] Restrict command history to explicit follow-ups; one-off recipients are not general person entities.
- [x] Add a deterministic recipient binding after the model chooses `send_message`: a clearly spoken recipient wins
  over a stale/model-supplied recipient.
- [ ] Give every memory item a source (`told`, `episode`, `inferred`), scope, confidence, expiry, and explanation.
- [ ] Centralize tool risk policy and add pre/post hooks for message, terminal, delete, purchase, and login actions.
- [ ] Add recipient/contact resolution evidence to the message approval card and result trace.
- [x] See the whole screen before answering or acting: `read_screen` says when the list or document goes on past
  what's in view; `scroll` moves any app's window or list (the page in a browser) and reports where it got to;
  `read_everything` scrolls through a whole list, chat, inbox, feed, table or document and joins the screens without
  the overlap (`PageDigest.merge`), then puts the window back.
- [x] Completeness check: a `reply`/`done` about all of something ("all", "every", "how many", "latest", "unread",
  "cheapest", "saare", "kitne") made from one screenful makes Murmur read the rest first, once, and the model
  continues from all of it.
- [x] Whole-page reads in the browser handle lists that keep only what's near the screen (Gmail, X, Slack,
  LinkedIn): read a screenful at a time from the top and joined.
- [x] Long tasks don't stop half-way: a plain-text answer with task-list steps still open goes on like a reply would
  (up to three times); the read-everything check waits until the task list is finished and never fires on a single
  opened item; going back in web apps without page scripting falls back to the page's own back button.
- [x] PDFs in the browser are read from the file itself (PDFKit), every page numbered, instead of the viewer's
  Accessibility text, which stopped at 12,000 characters (about 4 of 21 pages) while claiming to be the whole page.
  "Summarise page 10" reads just that page; a page read that's cut short now says so.
- [ ] Verify scrolling on real apps (Mail, Slack, WhatsApp, Finder, System Settings, Chrome/Safari) and tune the
  scroll-area choice for Electron apps that don't expose one.

### 1b. Universal perception and action (works in every app, not only where Accessibility does)

Goal: never act or answer from half the screen. Every observation says how complete it is; when one way of seeing
fails, the next one is tried; nothing is called done until it has been checked.

**Seeing, best source first** (each says what it covered and whether it reached the end):

1. The app's own data: AppleScript/JXA (Mail, Notes, Calendar, Finder…), page scripts or the Murmur Chrome extension,
   the file itself (PDFKit for PDFs, `textutil`/`mdls` for documents), local commands.
2. Accessibility, read by scrolling through (`read_everything`), with scroll position and "more below" markers.
3. Vision: a screenshot of the front window. With a cloud model (Claude or OpenAI chosen in Settings) the image goes to
   that model; with the local model, on-device text recognition (Vision) only. Used automatically when Accessibility
   gives little (canvas apps, games, remote desktops, images, charts, video), and on request (`look`).

**Acting, surest route first:** a local command or app script → an Accessibility press or click on a numbered element →
a page action in the browser → a click, type or scroll at a point on the screenshot (`click_at`, `scroll_at`). A
click at a point is checked against the element under it, so "Send", "Delete" or "Pay" still asks first.

**Local commands are a first-class route**, not a fallback: files, folders, disk, network, git, processes, converting
and extracting (a PDF's text, an image's details) go through `run_command`. Commands that only read run at once;
anything that changes something asks first; nothing runs as administrator.

**The browser everywhere:** a Murmur Chrome extension (and Safari web extension later) talks to the app over native
messaging, so reading, clicking, typing, scrolling, tabs and PDFs work in every page with no Chrome setting to turn
on. The AppleScript route and Accessibility stay as fallbacks.

**Done means checked:** after each action, a change check (page, window, screenshot); before `done`/`reply`, a check
that the task list is finished, that answers about "all" of something read all of it, and that the result is on
screen (message in the thread, form submitted, file exists). Failures from real use become replayable test cases.

Phases:

- [x] 1b.1 Screen vision, on this Mac by default: Qwen3-VL through Ollama (8B with 16 GB+, else 4B) describes a
  screenshot (text, clickable things with positions, whether it's cut off) and finds things to click; the screenshot
  never leaves the Mac, and the planning model, even a cloud one, gets text. Settings → Commands & AI → Screen vision
  chooses On this Mac / The cloud model (images to Claude or OpenAI, latest two kept) / Nowhere (the Mac's text
  recognition, with positions). Tools: `look`, `click_on` (Accessibility first, then sight), `click_at`, `scroll_at`;
  a look happens by itself when Accessibility shows little, and after each click or scroll by sight; what's under a
  point is checked so Send/Delete/Pay still ask. Needs verifying on the Mac.
- [x] 1b.1a Getting the vision model: offered in onboarding's commands step ("Let Murmur see your screen", on when
  Ollama is installed and there's room; 8B or 4B by memory), downloaded in the background after setup with Screen
  Recording asked for at the same moment; Settings shows its progress and a Download button; the first command that
  needs to see an app offers it once if it was skipped. Until it's in, the Mac's text recognition is used.
- [ ] 1b.2 Murmur Chrome extension with native messaging: read (whole page, scrolled panels, PDFs), click, type, upload
  files to file inputs, tabs, history; replaces "Allow JavaScript from Apple Events".
- [ ] 1b.3 Source-aware readers: Mail/Notes/Calendar through scripts first, documents through local commands, with
  coverage ("read 214 of 214 emails") in every result.
- [ ] 1b.4 Completion checks per action type, and a replay set built from logged failures (Gmail triage, PDF
  summaries, job-form filling, chat apps), run in CI.

### 2. Workflow and plan artifacts

- [ ] Replace prompt-only long-task plans with a persisted workflow artifact: steps, state, approvals, evidence, and
  retry policy.
- [ ] Show it in the app as an editable Plan page; `continue` resumes its exact checkpoint.
- [ ] Add deterministic postconditions (message sent, file exists, event created, form reaches confirmation).

### 3. Trustworthy learning and research

- [ ] Turn repeated behavior into reviewable suggestions rather than automatic global preferences.
- [ ] Build research mode with source capture, claim/evidence separation, citations, and an inference label.
- [ ] Add a skill manifest: requested tools, memory access, source URL, version, and trust status for imports.

### 4. Evaluations and optional specialist workers

- [ ] Record redacted request/action/result fixtures and replay them in CI.
- [ ] Add adversarial tests for stale memory, recipient confusion, page prompt injection, and approval bypasses.
- [ ] Add isolated reviewer/research workers only for slow or high-stakes workflows—not routine voice commands.

## First vertical slice

Phase 1 starts at `send_message`, because sending to the wrong person is irreversible. `MessageIntent` extracts only
high-confidence, explicitly spoken recipients. `CommandAgent` treats that target as authoritative after the model
returns a tool call, then resolves aliases and asks for approval using that final recipient. This preserves natural
follow-ups such as “tell her…” while preventing an earlier recipient from leaking into “message Neha…”.

The second slice is seeing all of the screen. A model left to scroll for itself read one screenful and answered
("3 unread emails" with 40 more below). Murmur now tells the model when there is more, gives it `scroll` and
`read_everything`, and reads the rest itself before an answer about all of a list.
