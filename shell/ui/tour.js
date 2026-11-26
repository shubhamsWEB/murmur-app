// A walk around Murmur's window with the starling as the guide, as the Mac's (Sources/MurmurApp/Tour.swift). The page
// dims; the bird flies to the part being explained (tapping the page's name in the sidebar on the way when it's on
// another page), the spotlight opens around it, and a card unfolds out of the bird: what it is and how it works. Next
// folds the card back into the bird and it flies on. Three things are done for real (talk into the box on the card,
// rewrite its text by voice, press the search keys), and the card waits until Murmur sees you do it; each can be
// skipped. At the end the bird flies down towards the tray, where Murmur lives.
//
// Starts once, the first time the window is in front after this version is installed (or right after setup), and
// again from About & Help. With reduced motion it doesn't fly: each card simply appears.
(() => {
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const $ = (id) => document.getElementById(id);
const SEEN = "murmur.tourSeen";
const still = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const wait = (ms) => new Promise((done) => setTimeout(done, ms));

const BIRD = `<svg viewBox="10 26 82 62" aria-hidden="true">
  <path d="M30 58 L12 47 L16 67 Z" fill="#E2554A"/>
  <ellipse cx="48" cy="60" rx="24" ry="19" fill="#FF6F61"/>
  <circle cx="66" cy="42" r="13" fill="#FF6F61"/>
  <path d="M78 40.5 L89 44 L78 47.5 Z" fill="#FBF7F2"/>
  <circle cx="69" cy="39" r="2.6" fill="#221E1C"/>
  <path class="wave" d="M31 60 q4.5 -8 9 0 t9 0 t9 0" stroke="#FFF6EF" stroke-width="3.6" stroke-linecap="round" fill="none"/>
</svg>`;

// MARK: The stops

/// The stops, with the talk key and the search shortcut as they're set. `page`: the page shown; `via`: the page's
/// name in the sidebar, which the bird taps on its way; `target`: what the spotlight opens around (none: the card in
/// the middle); `wait`: what the stop waits for before Next ("dictate", "command", "search").
function stops(key, search) {
  const row = (id) => () => $(id)?.closest(".srow");
  return [
    { id: "hello", page: "home", title: "Hi, I'm Murmur",
      body: "I live in your system tray and work in every app. Let me show you around. It takes two minutes.",
      button: "Show me around" },
    { id: "talk", page: "home", target: () => $("live-key")?.closest(".card"),
      title: `Hold ${key} and talk`,
      body: "Let go, and I type it where your cursor is, in any app.",
      wait: "dictate", tryIt: `Click the box, hold ${key} and say something.`,
      done: "That's it. It works the same in Outlook, Slack, anywhere." },
    { id: "ask", page: "home", target: () => $("live-key")?.closest(".card"),
      title: "Or tell me what to do",
      body: "“Open Spotify”, “summarise this”. Select some text first and I rewrite it right where it is.",
      wait: "command", tryIt: `Select the text, hold ${key} + Alt and say “make it polite”.`,
      practice: "hey can u send me the slides from yesterdays meeting when ur free",
      done: "Rewritten in place." },
    { id: "find", page: "home", target: () => document.querySelector('.sidebar [data-page="search"]'),
      title: "Find any file by describing it",
      body: `Press ${search} anywhere: “the rent agreement from last year”. Enter opens it.`,
      wait: "search", tryIt: `Press ${search}.`, done: "That's the search panel. Esc closes it." },
    { id: "offer", page: "meetings", via: "meetings", target: row("meeting-offers"),
      title: "When a call starts, I offer to take notes",
      body: "Once Teams, Zoom, Meet in your browser or another call app turns on your microphone, a small card asks "
        + "whether to take notes. Ignore it and it goes away." },
    { id: "live", page: "meetings", target: row("meeting-start"),
      title: "Live: what to say, as they ask",
      body: "I hear both sides of the call and keep notes, a transcript and who said what. When they finish a "
        + "question, an answer appears in the panel, ready to read out. Ctrl+Alt+Enter answers at once. Nobody on "
        + "the call sees the panel: it's left out of screen sharing." },
    { id: "ended", page: "meetings", target: () => $("meetings-search"),
      title: "Afterwards, it's all here",
      body: "When the call ends, its notes and transcript are saved on this page and in Documents › Murmur "
        + "Meetings. Search them by a name, a decision or a number." },
    { id: "models", page: "settings", via: "settings", target: row("ai-provider"),
      title: "On your PC, or in the cloud",
      body: "Pick the AI that does commands, tidies dictation and writes meeting notes. On this PC runs a model "
        + "through Ollama: free and private, a little slower. Claude, OpenAI and Sarvam are faster and use your "
        + "own key." },
    { id: "cloud", page: "settings", target: row("ai-provider"),
      title: "What a cloud model sees",
      body: "Only what the task needs: a command's words, the app in front and text you select; a meeting's "
        + "transcript for its notes. With On this PC, nothing leaves. Your keys stay in Windows' Credential Manager." },
    { id: "speech", page: "settings", target: row("speech-model"),
      title: "Your voice, turned to text here",
      body: "Speech to text runs on this PC, offline: English, Hindi with English, or 25 European languages. Sarvam "
        + "adds more Indian languages from the cloud: then your recordings go to Sarvam." },
    { id: "yours", page: "settings", target: row("ai-grammar"),
      title: "Make me yours",
      body: "Change the talk key, pick your microphone, and turn on Fix grammar." },
    { id: "bye", page: "home", title: "That's everything",
      body: `Hold ${key} in any app to start. I'm down in the system tray if you need me.`, button: "Done" },
  ];
}

// MARK: The overlay

let root = null, hole, bird, card;
let steps = [], index = 0, generation = 0, on = false, didStep = false;
let at = { x: 0, y: 0 };          // where the bird is
let unlisten = [];

function build() {
  root = document.createElement("div");
  root.className = "tour";
  root.innerHTML = `<div class="tour-hole none"></div>
    <div class="tour-card" role="dialog" aria-live="polite">
      <div class="tour-count"></div><h2></h2><p class="tour-body"></p>
      <div class="tour-try" hidden><b></b><textarea spellcheck="false"></textarea><div class="tour-done"></div></div>
      <div class="tour-buttons"><button class="tour-end">Skip tour</button><span class="spacer"></span>
        <button class="tour-skip-step" hidden>Skip</button><button class="tour-next">Next</button></div>
    </div>
    <div class="tour-bird">${BIRD}</div>`;
  document.body.appendChild(root);
  hole = root.querySelector(".tour-hole");
  bird = root.querySelector(".tour-bird");
  card = root.querySelector(".tour-card");
  card.querySelector(".tour-next").addEventListener("click", next);
  card.querySelector(".tour-skip-step").addEventListener("click", next);
  card.querySelector(".tour-end").addEventListener("click", finish);
  card.querySelector("textarea").addEventListener("input", check);
  // Clicks on the dimmed page do nothing while the tour is on.
  root.addEventListener("mousedown", (event) => { if (!event.target.closest(".tour-card")) event.preventDefault(); });
}

function place(element, x, y) {
  at = { x, y };
  element.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
}

/// The bird flies to (x, y) along a shallow arc, slow, quick, slow.
async function fly(x, y, seconds) {
  const from = { ...at };
  if (still() || (Math.abs(x - from.x) < 2 && Math.abs(y - from.y) < 2)) return place(bird, x, y);
  bird.classList.toggle("left", x < from.x - 4);
  bird.classList.add("flying");
  const lift = Math.min(90, 30 + Math.hypot(x - from.x, y - from.y) * 0.18);
  const middle = { x: (from.x + x) / 2, y: Math.min(from.y, y) - lift };
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const frames = [];
  for (let i = 0; i <= 24; i++) {
    const t = ease(i / 24), u = 1 - t;
    const px = u * u * from.x + 2 * u * t * middle.x + t * t * x;
    const py = u * u * from.y + 2 * u * t * middle.y + t * t * y;
    frames.push({ transform: `translate(${px.toFixed(1)}px, ${py.toFixed(1)}px)`, offset: i / 24 });
  }
  const flight = bird.animate(frames, { duration: seconds * 1000, easing: "linear" });
  place(bird, x, y);
  await flight.finished.catch(() => {});
  bird.classList.remove("flying", "left");
}

/// The spotlight around `element` (none: the whole window dimmed).
function spotlight(element) {
  const box = element?.getBoundingClientRect();
  if (!box || !box.width) {
    hole.classList.add("none");
    Object.assign(hole.style, { left: innerWidth / 2 + "px", top: innerHeight / 2 + "px", width: "0px", height: "0px" });
    return null;
  }
  hole.classList.remove("none");
  const frame = { left: box.left - 8, top: box.top - 8, width: box.width + 16, height: box.height + 16 };
  Object.assign(hole.style, { left: frame.left + "px", top: frame.top + "px", width: frame.width + "px", height: frame.height + "px" });
  return { ...frame, right: frame.left + frame.width, bottom: frame.top + frame.height };
}

/// Where the card goes: beside the spotlight where there's room (right, left, below, above), else the middle.
function cardSpot(frame) {
  const width = card.offsetWidth, height = card.offsetHeight, gap = 20, edge = 14;
  const clampX = (x) => Math.max(edge, Math.min(x, innerWidth - width - edge));
  const clampY = (y) => Math.max(edge + 30, Math.min(y, innerHeight - height - edge));
  if (!frame) return { x: clampX((innerWidth - width) / 2), y: clampY((innerHeight - height) / 2) };
  if (frame.right + gap + width <= innerWidth - edge) return { x: frame.right + gap, y: clampY(frame.top) };
  if (frame.left - gap - width >= edge) return { x: frame.left - gap - width, y: clampY(frame.top) };
  if (frame.bottom + gap + 30 + height <= innerHeight - edge) return { x: clampX(frame.left), y: frame.bottom + gap + 30 };
  if (frame.top - gap - height >= edge + 30) return { x: clampX(frame.left), y: frame.top - gap - height };
  return { x: clampX((innerWidth - width) / 2), y: clampY(innerHeight - height - edge) };
}

function fill(step) {
  const middle = steps.length - 2;
  card.querySelector(".tour-count").textContent = index > 0 && index <= middle ? `${index} of ${middle}` : "";
  card.querySelector("h2").textContent = step.title;
  card.querySelector(".tour-body").textContent = step.body;
  const tryIt = card.querySelector(".tour-try"), box = card.querySelector("textarea");
  tryIt.hidden = !step.wait;
  tryIt.querySelector("b").textContent = step.tryIt || "";
  box.hidden = step.wait === "search";
  box.value = step.practice || "";
  box.placeholder = step.wait === "dictate" ? "Click here, then talk" : "";
  card.querySelector(".tour-done").textContent = step.done || "";
  card.classList.remove("did");
  const nextButton = card.querySelector(".tour-next");
  nextButton.textContent = step.button || "Next";
  nextButton.disabled = !!step.wait;
  card.querySelector(".tour-skip-step").hidden = !step.wait;
  card.querySelector(".tour-end").textContent = index === 0 ? "Later" : "Skip tour";
  card.querySelector(".tour-end").hidden = index === steps.length - 1;
}

async function go(to) {
  const run = ++generation;
  index = to;
  didStep = false;
  const step = steps[index];
  card.classList.remove("open", "folding");
  // Another page: the bird taps its name in the sidebar on the way, and the page changes.
  if (step.via && !still()) {
    const item = document.querySelector(`.sidebar [data-page="${step.via}"]`);
    const box = item?.getBoundingClientRect();
    if (box) {
      await fly(box.left + box.width - 18, box.top + box.height / 2 + 8, 0.75);
      if (run !== generation) return;
      bird.classList.add("tapping");
      item.classList.add("tour-tapped");
      await wait(160);
      window.murmurPage(step.page);
      await wait(180);
      bird.classList.remove("tapping");
      item.classList.remove("tour-tapped");
    }
  }
  if (run !== generation) return;
  window.murmurPage(step.page);
  const target = step.target?.();
  target?.scrollIntoView({ block: "center" });
  fill(step);
  const frame = spotlight(target);
  const spot = cardSpot(frame);
  card.style.left = spot.x + "px";
  card.style.top = spot.y + "px";
  await fly(spot.x + 34, spot.y + 2, index === 0 ? 1.1 : step.via ? 0.8 : 0.95);
  if (run !== generation) return;
  card.classList.add("open");
  if (step.wait === "dictate" || step.wait === "command") {
    const box = card.querySelector("textarea");
    box.focus();
    if (step.wait === "command") box.select();
  } else {
    card.querySelector(".tour-next").focus({ preventScroll: true });
  }
}

/// The stop's try-it is done: the dictation landed in the box, the box's text was rewritten, or the search panel opened.
function check() {
  const step = steps[index];
  if (!on || didStep || !step?.wait || step.wait === "search") return;
  const text = card.querySelector("textarea").value.trim();
  if (step.wait === "dictate" ? text !== "" : text !== "" && text !== step.practice) markDone();
}

function markDone() {
  if (didStep) return;
  didStep = true;
  card.classList.add("did");
  card.querySelector(".tour-next").disabled = false;
  card.querySelector(".tour-skip-step").hidden = true;
}

async function next() {
  if (!on || card.classList.contains("folding")) return;
  const run = generation;
  if (!still()) {
    card.classList.add("folding");
    card.classList.remove("open");
    await wait(300);
    if (run !== generation) return;
  }
  if (index + 1 < steps.length) return go(index + 1);
  // The end: down towards the tray, then gone.
  root.classList.add("leaving");
  await fly(innerWidth - 40, innerHeight + 60, 0.9);
  finish();
}

/// Ends it now (Skip tour, Later, Esc, the last stop).
function finish() {
  if (!on) return;
  on = false;
  generation++;
  for (const stop of unlisten) stop();
  unlisten = [];
  root.remove();
  root = null;
  window.murmurPage("home");
}

async function start() {
  if (on) return;
  on = true;
  // Seen from the moment it starts: it never starts by itself again, even if Murmur quits halfway.
  try { localStorage.setItem(SEEN, "1"); } catch { /* it may start once more */ }
  const [dictation, settings] = await Promise.all([invoke("dictation_info").catch(() => null), invoke("settings_info").catch(() => ({}))]);
  const key = (dictation && (dictation.keys.find((k) => k.id === dictation.key) || {}).title) || "Ctrl + Windows";
  const search = (settings.hotkey || "Ctrl+Space").split("+").filter(Boolean).join(" + ");
  steps = stops(key, search);
  build();
  root.classList.remove("leaving");
  place(bird, innerWidth / 2, -50);
  // The search panel opened (the search stop), and a dictation or command finished (the box may not have changed yet).
  const heard = (name, handler) => tauri.event.listen(name, handler).then((stop) => (on ? unlisten.push(stop) : stop()));
  heard("panel-shown", () => { if (on && steps[index]?.wait === "search") markDone(); });
  heard("dictation", () => setTimeout(check, 150));
  const onKey = (event) => { if (event.key === "Escape" && !event.target.closest?.("textarea")) finish(); };
  const onResize = () => {
    if (!on) return;
    const frame = spotlight(steps[index].target?.());
    const spot = cardSpot(frame);
    card.style.left = spot.x + "px";
    card.style.top = spot.y + "px";
    place(bird, spot.x + 34, spot.y + 2);
  };
  document.addEventListener("keydown", onKey);
  window.addEventListener("resize", onResize);
  unlisten.push(() => document.removeEventListener("keydown", onKey), () => window.removeEventListener("resize", onResize));
  go(0);
}

window.murmurTour = { start };
$("tour-start")?.addEventListener("click", start);

// Once, the first time the window is in front.
function firstTime() {
  let seen = true;
  try { seen = !!localStorage.getItem(SEEN); } catch { /* no storage: it's only started from About & Help */ }
  if (seen || on || document.visibilityState !== "visible" || !document.hasFocus()) return;
  setTimeout(() => { if (document.hasFocus()) start(); }, 700);
}
window.addEventListener("focus", firstTime);
window.addEventListener("load", firstTime);
})();
