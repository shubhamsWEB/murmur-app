// Murmur's window: the sidebar and the Home page, as the Mac app's (Sources/MurmurApp/Home.swift). The sidebar switches
// the pages (window.murmurPage, which the tray, the panel and window.js use too) and says how Murmur is doing; Home says
// whether Murmur is ready, how to talk to it, and where each model is. Search is window.js's page, and Settings,
// Folders and About are settings.js's.
(() => {
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const $ = (id) => document.getElementById(id);
const PAGES = ["home", "search", "folders", "settings", "about"];

let dictation = null;   // dictation_info, kept current by its events
let settings = {};      // settings_info: the shortcut, the folders, indexing (its "state" events)
let page = null;

// MARK: Pages

function showPage(name) {
  if (!PAGES.includes(name)) name = "home";
  page = name;
  for (const id of PAGES) $(`page-${id}`).hidden = id !== name;
  for (const button of document.querySelectorAll("[data-page]")) {
    if (button.closest(".sidebar")) {
      if (button.dataset.page === name) button.setAttribute("aria-current", "page");
      else button.removeAttribute("aria-current");
    }
  }
  window.murmurSettings?.shown(name);
  if (name === "search") $("query").focus();
  try { localStorage.setItem("murmur.page", name); } catch { /* the next window opens on Home */ }
}

window.murmurPage = showPage;
for (const button of document.querySelectorAll("[data-page]")) button.addEventListener("click", () => showPage(button.dataset.page));
$("ready-card").addEventListener("click", () => showPage(readiness().page || "home"));
// The tray's Settings… and Choose Folders…, the panel's "Show all": the page to show.
tauri.event.listen("show-page", ({ payload }) => showPage(payload));

// MARK: How Murmur is doing

/// What the dictation key is called ("Ctrl + Windows").
function keyTitle() {
  const d = dictation;
  return d ? (d.keys.find((key) => key.id === d.key) || {}).title || "Ctrl + Windows" : "Ctrl + Windows";
}

/// Whether Murmur can be used now, in a few words (the Mac's Readiness): title, detail, busy, problem, and the page
/// that helps.
function readiness() {
  const d = dictation;
  if (!d || !d.available) return { title: "Search is ready", detail: "Dictation is on Windows only", busy: false, problem: false };
  if (!d.enabled) return { title: "Dictation is off", detail: "Turn it on in Settings", busy: false, problem: true, page: "settings" };
  const model = d.modelState || {};
  const percent = model.total > 0 ? Math.floor((100 * model.bytes) / model.total) : null;
  switch (model.state) {
    case "downloading":
      return { title: "Getting ready", detail: `Downloading speech${percent != null ? ` · ${percent}%` : "…"}`, busy: true, page: "settings" };
    case "checking": case "loading": case "waiting":
      return { title: "Getting ready", detail: model.state === "waiting" ? "Waiting for the internet" : "Preparing the speech model", busy: true, page: "settings" };
    case "failed": case "missing":
      return { title: "Speech didn't load", detail: "See Settings", problem: true, page: "settings" };
  }
  if (d.keyProblem) return { title: "Almost ready", detail: "The dictation key isn't working", problem: true, page: "settings" };
  if (d.phase === "listening") {
    return { title: "Listening…", detail: d.handsFree ? `Tap ${keyTitle()} to finish, Esc to cancel` : `Let go of ${keyTitle()} to finish`, busy: true };
  }
  if (d.phase === "working") return { title: "Writing it down…", detail: "One moment", busy: true };
  return { title: "Ready when you are", detail: `Hold ${keyTitle()} anywhere to talk`, busy: false, problem: false };
}

function dotClass(element, ready, big) {
  element.className = `dot${big ? " dot-lg" : ""}${ready.problem ? " problem" : ready.busy ? " busy" : ""}`;
}

function render() {
  renderVersion();
  const ready = readiness();
  dotClass($("ready-dot"), ready, false);
  $("ready-title").textContent = ready.title;
  $("ready-detail").textContent = ready.detail;

  // The sidebar's accessories: the search shortcut, Folders to set up or indexing.
  $("nav-hotkey").textContent = (settings.hotkey || "").replaceAll("+", " ");
  const folders = (settings.folders || []).length > 0, state = settings.state || {};
  const badge = !folders ? ["Set up", "attention"] : state.pending > 0 || state.busy ? ["Indexing", "busy"] : null;
  $("nav-folders").replaceChildren(...(badge ? [pill(badge[0], badge[1])] : []));
  $("nav-settings").replaceChildren(...(ready.problem && ready.page === "settings" ? [pill("Fix", "attention")] : []));

  // Home.
  dotClass($("home-dot"), ready, true);
  $("home-title").textContent = ready.title;
  $("home-subtitle").textContent = `Hold ${keyTitle()} and talk in any app. Murmur types what you say, right where your cursor is.`;
  const fix = ready.problem ? ready : null;
  $("home-fix").hidden = !fix;
  if (fix) {
    $("home-fix-text").textContent = fix.title === "Dictation is off" ? "Dictation is turned off."
      : fix.title === "Almost ready" ? `Murmur can't see ${keyTitle()}: ${dictation.keyProblem}` : "The speech model isn't ready.";
    $("home-fix-go").textContent = "Open Settings";
    $("home-fix-go").onclick = () => showPage("settings");
  }
  const keys = keyTitle().split(" + ");
  $("live-key").replaceChildren(...keys.flatMap((key, i) => i ? [document.createElement("br"), document.createTextNode(`+ ${key}`)] : [document.createTextNode(key)]));
  $("live-key").classList.toggle("lit", dictation?.phase === "listening");
  $("gesture-keys").replaceChildren(...caps(keys));
  $("hands-free-keys").replaceChildren(...caps(keys),
    Object.assign(document.createElement("span"), { className: "plus", textContent: "×2" }));
  renderWeek();
  $("search-keys").replaceChildren(...caps((settings.hotkey || "Ctrl+Space").split("+").filter(Boolean)));
  $("home-quiet").textContent = dictation?.quietVoice
    ? "On: soft and whispered speech is lifted before it's turned into words. Change it in Settings."
    : "Off. Turn it on in Settings to dictate quietly in a shared room.";

  // On this PC: the speech model and the search model.
  if (dictation) {
    const model = (dictation.models || []).find((m) => m.id === dictation.model) || {};
    const engine = dictation.model === "hinglish" ? "Whisper" : "Parakeet";
    $("card-speech").textContent = `${engine} · ${model.title || ""}`;
    const s = dictation.modelState || {};
    const percent = s.total > 0 ? Math.floor((100 * s.bytes) / s.total) : null;
    setPill($("card-speech-state"), s.state === "ready" ? ["On device", "good"]
      : s.state === "downloading" ? [`Downloading${percent != null ? ` ${percent}%` : ""}`, "busy"]
      : ["checking", "loading", "waiting"].includes(s.state) ? ["Preparing", "busy"]
      : s.state === "failed" ? ["Didn't download", "attention"] : ["Not downloaded", "attention"]);
    $("card-speech-bar").hidden = s.state !== "downloading";
    $("card-speech-fill").style.width = `${percent || 0}%`;
  }
  const searchModel = state.model || {};
  setPill($("card-search-state"), !folders ? ["Choose folders", "attention"]
    : searchModel.state === "downloading" ? ["Downloading", "busy"]
    : state.pending > 0 ? [`Indexing · ${(state.pending || 0).toLocaleString()} to go`, "busy"]
    : [`${(state.searchable || 0).toLocaleString()} files`, "good"]);
}

function pill(text, tone) {
  const element = document.createElement("span");
  setPill(element, [text, tone]);
  return element;
}

function setPill(element, [text, tone]) {
  element.className = `pill ${tone}`;
  element.textContent = text;
}

// This week (from Monday, on this PC's calendar): words dictated, minutes saved against typing (about 40 words a
// minute typed, 150 spoken, as on the Mac), and words today. The history has when and how many words, never the text.
/// This version under the brand, and the card that offers a newer one (updates.rs: available, downloading, installing).
function renderVersion() {
  $("side-version").textContent = settings.version ? ` · ${settings.version}` : "";
  const update = settings.state && settings.state.update;
  $("update-card").hidden = !update;
  if (!update) return;
  const busy = update.state === "downloading" || update.state === "installing";
  $("update-card-title").textContent = update.state === "downloading"
    ? `Downloading Murmur ${update.version}…` + (update.percent != null ? ` ${update.percent}%` : "")
    : update.state === "installing" ? `Installing Murmur ${update.version}…` : `Murmur ${update.version} is ready`;
  $("update-card-detail").textContent = settings.version ? `You have ${settings.version}` : "";
  $("update-now").hidden = busy;
}
$("update-now").addEventListener("click", () => invoke("offer_update").catch(() => {}));

function renderWeek() {
  const on = dictation?.keepHistory !== false;
  $("week-off").hidden = on;
  for (const stat of document.querySelectorAll("#week .stat")) stat.hidden = !on;
  if (!on) return;
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const monday = today - ((now.getDay() + 6) % 7) * 86_400_000;
  const items = (dictation?.history || []).filter((item) => item.kind === "dictation");
  const words = (since) => items.filter((item) => item.at >= since).reduce((sum, item) => sum + item.words, 0);
  const week = words(monday);
  $("week-words").textContent = week.toLocaleString();
  $("week-minutes").textContent = `${Math.round(week / 40 - week / 150)} min`;
  $("week-today").textContent = words(today).toLocaleString();
}

function caps(keys) {
  const out = [];
  keys.forEach((key, index) => {
    if (index) out.push(Object.assign(document.createElement("span"), { className: "plus", textContent: "+" }));
    out.push(Object.assign(document.createElement("span"), { className: "cap", textContent: key }));
  });
  return out;
}

// MARK: Start

tauri.event.listen("dictation", ({ payload }) => { dictation = { ...dictation, ...payload }; render(); });
tauri.event.listen("state", ({ payload }) => { settings.state = payload; render(); });
window.addEventListener("focus", () => load().catch(() => {}));

async function load() {
  [dictation, settings] = await Promise.all([invoke("dictation_info").catch(() => null), invoke("settings_info")]);
  render();
}

async function start() {
  await load().catch(() => {});
  if (page) return;   // window.js already asked for Search (a search handed over)
  const asked = new URLSearchParams(location.search).get("page");   // the shell's ?page=settings, dev snapshots
  let last = null;
  try { last = localStorage.getItem("murmur.page"); } catch { /* none */ }
  showPage(asked || last || "home");
}

start();
})();
