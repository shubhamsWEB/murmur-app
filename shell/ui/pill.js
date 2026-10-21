// The dictation pill's page: told what to show by the shell (src-tauri/src/dictation/pill.rs) through "pill" events
// ({mode: listening|starting|working|message|hidden, text, tone}) and the microphone's level through "pill-level".
// Opening: the capsule is drawn closed (the small Starling pill), then widened to what the words measure; closing:
// the reverse, after which the shell hides the window.
"use strict";

const tauri = window.__TAURI__;
const $ = (id) => document.getElementById(id);
const pill = $("pill"), contents = $("contents"), text = $("text"), bird = $("bird"), halo = $("halo"), mark = $("mark");
const CLOSED = 44;

let isOpen = false;

function setMode(state) {
  pill.className = pill.className.replace(/\b(listening|starting|working|message|info|problem|done)\b/g, "").trim();
  if (state.mode === "hidden") return close();
  pill.classList.add(state.mode);
  if (state.mode === "message") pill.classList.add(state.tone || "info");
  mark.textContent = state.tone === "problem" ? "!" : "";
  text.textContent = state.text || "";
  open();
}

/// Open (or re-measure, when the words changed while open): the capsule's width follows the contents' own.
function open() {
  pill.classList.remove("closing");
  if (!isOpen) {
    pill.style.width = CLOSED + "px";
    pill.classList.add("shown");
    // Drawn closed first, so the opening is seen.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      pill.classList.add("open");
      pill.style.width = Math.ceil(contents.scrollWidth) + "px";
    }));
    isOpen = true;
  } else {
    pill.style.width = Math.ceil(contents.scrollWidth) + "px";
  }
}

function close() {
  if (!isOpen) return;
  isOpen = false;
  pill.classList.add("closing");
  pill.classList.remove("open");
  pill.style.width = CLOSED + "px";
  pill.classList.remove("shown");
}

function setLevel(level) {
  const v = Math.max(0, Math.min(1, Number(level) || 0));
  bird.style.transform = `scale(${1 + 0.28 * v})`;
  halo.style.transform = `scale(${1 + 0.75 * v})`;
}

tauri.event.listen("pill", ({ payload }) => setMode(payload));
tauri.event.listen("pill-level", ({ payload }) => setLevel(payload));
