// Meetings (window.html's page; src-tauri/src/meeting): the notes saved in Documents › Murmur Meetings, newest first,
// searched and read in place; starting notes; and how meetings are answered. In a scope of its own.
(() => {
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const $ = (id) => document.getElementById(id);

let list = null;       // meetings_list
let open = null;       // the meeting whose notes are shown

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function escape(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

function rich(tag, text) {
  const node = element(tag);
  node.innerHTML = escape(text).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  return node;
}

function markdown(text) {
  const box = element("div");
  let bullets = null;
  for (const raw of String(text).split("\n")) {
    const line = raw.trimEnd();
    const heading = line.match(/^(#{1,3})\s+(.*)$/);
    const bullet = line.match(/^\s*(?:[-*•]|\d+[.)])\s+(.*)$/);
    if (bullet) {
      if (!bullets) { bullets = element("ul"); box.append(bullets); }
      bullets.append(rich("li", bullet[1].replace(/^\[ \]\s*/, "☐ ").replace(/^\[[xX]\]\s*/, "☑ ")));
      continue;
    }
    bullets = null;
    if (heading) box.append(rich(`h${heading[1].length}`, heading[2]));
    else if (line.trim()) box.append(rich("p", line.trim()));
  }
  return box;
}

function fail(error) {
  $("meetings-problem").textContent = String(error);
  $("meetings-problem").hidden = false;
}

const act = (action, value) => invoke("meeting_action", { action, value: value === undefined ? null : value })
  .then(load).catch(fail);

function render() {
  if (!list) return;
  const state = list.state || {};
  $("meeting-start").textContent = list.running ? "Show Notes" : "Take Notes Now";
  $("meeting-now-title").textContent = list.running ? `Taking notes${state.app ? ` · ${state.app}` : ""}` : "Take meeting notes";
  $("meeting-offers").checked = state.offers !== false;
  $("meeting-auto").checked = state.autoAnswer !== false;
  const ai = $("meeting-ai");
  const keys = state.keys || {};
  const options = [["", `Same as commands: ${state.commandsAi || ""}`], ["anthropic", "Claude (Sonnet)"], ["openai", "OpenAI"],
                   ["sarvam", "Sarvam"], ["local", "On this PC (Ollama)"]];
  ai.replaceChildren(...options.map(([value, title]) => {
    const option = element("option", null, title + (value && value !== "local" && !keys[value] ? " · needs a key" : ""));
    option.value = value;
    return option;
  }));
  ai.value = state.ai || "";
  $("meeting-speech").value = state.speech || "";
  $("meeting-end-quiet").checked = !state.stayWhenQuiet;
  renderPeople();
  const nav = $("nav-meeting");
  if (nav) nav.textContent = list.running ? "●" : "";

  const words = $("meetings-search").value.toLowerCase().split(/\s+/).filter(Boolean);
  const meetings = (list.meetings || []).filter((m) => words.every((w) => `${m.title} ${m.text}`.toLowerCase().includes(w)));
  const box = $("meetings-list");
  if (!(list.meetings || []).length) {
    box.replaceChildren(element("p", "note", "No meetings yet. Take notes from here or the tray, or say yes when Murmur offers as a "
      + "call starts. Each meeting's notes and transcript are saved in Documents › Murmur Meetings."));
    return;
  }
  if (!meetings.length) {
    box.replaceChildren(element("p", "note", `No meeting mentions “${$("meetings-search").value}”.`));
    return;
  }
  box.replaceChildren(...meetings.map(card));
}

/// People: the voices you asked Murmur to remember, each with Rename and Forget.
function renderPeople() {
  const people = list.people || [];
  $("people-label").hidden = $("people").hidden = !people.length;
  $("people").replaceChildren(...people.map((person) => {
    const row = element("div", "srow");
    const text = element("div", "stext");
    const seen = person.lastSeen ? new Date(person.lastSeen * 1000).toLocaleDateString() : "";
    text.append(element("b", null, person.name),
                element("span", null, `Known by voice · learned from ${person.samples} stretches of speech${seen ? ` · last heard ${seen}` : ""}`));
    const controls = element("div", "sctl");
    const rename = element("button", "secondary", "Rename");
    rename.onclick = () => {
      const input = element("input", "field");
      input.value = person.name;
      const done = () => { if (input.value.trim() && input.value.trim() !== person.name) act("renamePerson", { id: person.id, name: input.value.trim() }); else render(); };
      input.onkeydown = (event) => { if (event.key === "Enter") done(); if (event.key === "Escape") render(); };
      input.onblur = done;
      text.replaceChildren(input);
      input.focus();
      input.select();
    };
    const forget = element("button", "secondary", "Forget");
    forget.onclick = () => act("forgetPerson", person.id);
    controls.append(rename, forget);
    row.append(text, controls);
    return row;
  }));
}

function card(meeting) {
  const box = element("div", "meeting-card");
  const head = element("button", "meeting-head");
  const text = element("span", "meeting-text");
  text.append(element("b", null, meeting.title));
  const when = [meeting.date, meeting.time, meeting.app, meeting.lines ? `${meeting.lines} lines` : ""].filter(Boolean).join(" · ");
  text.append(element("span", "meeting-sub", when));
  const expanded = open === meeting.path;
  if (!expanded && meeting.gist) text.append(element("span", "meeting-gist", meeting.gist));
  head.append(text, element("span", "meeting-sub", expanded ? "▴" : "▾"));
  head.onclick = () => { open = expanded ? null : meeting.path; render(); };
  box.append(head);
  if (expanded) {
    const body = element("div", "meeting-body");
    body.append(markdown(meeting.notes));
    const actions = element("div", "meeting-actions");
    const copy = element("button", "secondary", "Copy Notes");
    copy.onclick = async () => {
      try { await navigator.clipboard.writeText(meeting.notes); copy.textContent = "Copied"; } catch (error) { fail(error); }
    };
    const show = element("button", "secondary", "Show File");
    show.onclick = () => invoke("reveal", { path: meeting.path }).catch(fail);
    const openFile = element("button", "secondary", "Open");
    openFile.onclick = () => invoke("open_path", { path: meeting.path }).catch(fail);
    actions.append(copy, show, openFile);
    body.append(actions);
    box.append(body);
  }
  return box;
}

async function load() {
  $("meetings-problem").hidden = true;
  list = await invoke("meetings_list").catch((error) => { fail(error); return list; });
  render();
}

$("meeting-start").onclick = () => act("start");
$("meetings-folder").onclick = () => act("openFolder");
$("meeting-offers").onchange = () => act("offers", $("meeting-offers").checked);
$("meeting-auto").onchange = () => act("auto", $("meeting-auto").checked);
$("meeting-ai").onchange = () => act("ai", $("meeting-ai").value);
$("meeting-speech").onchange = () => act("speech", $("meeting-speech").value);
$("meeting-end-quiet").onchange = () => act("stayWhenQuiet", !$("meeting-end-quiet").checked);
$("meetings-search").addEventListener("input", render);
tauri.event.listen("meeting-people", () => load());
tauri.event.listen("meetings-changed", () => load());
tauri.event.listen("meeting-running", () => load());

window.murmurMeetings = { load };
})();
