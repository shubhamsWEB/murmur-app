// Meeting notes' panel (meeting.html; src-tauri/src/meeting): told the meeting's state ("meeting"), each answer as
// it's written ("meeting-answer") and the meters ("meeting-level"); everything it does goes back as meeting_action.
(() => {
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const $ = (id) => document.getElementById(id);
const act = (action, value) => invoke("meeting_action", { action, value: value === undefined ? null : value })
  .catch((error) => showProblem(String(error)));

let state = null;
let tab = "live";
let hovering = false;
let following = true;      // the newest answer is shown as it comes, unless you stepped back

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function escape(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

/// **bold** and `code`, inline, in escaped text.
function inline(text) {
  return escape(text).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>").replace(/`([^`]+)`/g, "<code>$1</code>");
}

function rich(tag, className, text) {
  const node = element(tag, className);
  node.innerHTML = inline(text);
  return node;
}

// MARK: The offer

const offered = new URLSearchParams(location.search).get("offer");
if (offered !== null) {
  $("offer").hidden = false;
  $("offer-app").textContent = `${offered || "A meeting app"} has the microphone on.`;
  $("offer-yes").onclick = () => act("offerAccept");
  $("offer-no").onclick = () => act("offerDismiss");
  return;
}

// MARK: Rendering

function render() {
  if (!state) return;
  document.documentElement.style.setProperty("--answer-size", `${state.textSize}px`);
  document.body.classList.toggle("strip", state.layout === "strip" && !state.collapsed);
  $("folded").hidden = !state.collapsed;
  $("panel").hidden = state.collapsed;
  applyOpacity();
  if (state.collapsed) {
    $("folded").classList.toggle("unread", state.unread);
    $("folded-dot").className = "dot" + (state.running ? " on" : "");
    $("folded-text").textContent = state.unread ? "Answer ready · open" : state.running ? "Meeting notes · listening" : "Meeting notes";
    return;
  }
  $("live-dot").className = "dot" + (state.running ? " on" : "");
  $("title").textContent = state.running ? `${state.app || "Listening"} · ${elapsed()}`
    : state.finishing ? "Writing the final notes…" : "Meeting notes";
  $("hotkey").textContent = state.hotkey;
  $("auto").checked = state.autoAnswer;
  $("mute").checked = state.micMuted;
  $("problem").hidden = !state.problem;
  $("problem-text").textContent = state.problem || "";
  $("stop").textContent = state.running ? "Stop" : "Take notes";
  $("stop").disabled = state.finishing;
  $("show-file").hidden = !state.saved;
  $("status").textContent = state.finishing ? "Finishing…" : `Answers with ${state.aiName}`;
  $("layout").title = state.layout === "strip" ? "Show beside the call" : "Read near the camera";
  for (const button of document.querySelectorAll(".tabs button")) {
    button.setAttribute("aria-selected", String(button.dataset.tab === tab));
  }
  for (const name of ["live", "notes", "transcript", "context"]) $(`tab-${name}`).hidden = name !== tab;
  if (tab === "live") renderLive();
  if (tab === "notes") renderNotes();
  if (tab === "transcript") renderLines();
  if (tab === "context") renderContext();
}

function elapsed() {
  const seconds = Math.max(0, Math.floor(Date.now() / 1000 - state.started));
  const minutes = Math.floor(seconds / 60);
  return minutes >= 60 ? `${Math.floor(minutes / 60)} h ${minutes % 60} min` : `${minutes}:${String(seconds % 60).padStart(2, "0")}`;
}

function renderLive() {
  const reader = $("reader");
  const answers = state.answers || [];
  if (!answers.length) {
    reader.replaceChildren(empty());
    $("pager").hidden = true;
    return;
  }
  const index = Math.min(state.shown, answers.length - 1);
  reader.replaceChildren(answerView(answers[index]));
  $("pager").hidden = false;
  $("page").textContent = `${index + 1} of ${answers.length}`;
  $("previous").disabled = index <= 0;
  $("next").disabled = index >= answers.length - 1;
}

function empty() {
  const box = element("div", "empty");
  if (state.running) {
    box.append(element("b", null, "Listening"),
      `When someone asks you something, an answer shows here as it's written. Press Answer now (${state.hotkey}) to answer at once.`);
  } else if (state.finishing) {
    box.append(element("b", null, "Finishing the notes"), "The final notes and the transcript are being saved.");
  } else {
    box.append(element("b", null, "Notes aren't running"), "Take notes to listen to the call and your microphone.");
  }
  return box;
}

function answerView(answer) {
  const box = element("div");
  const question = element("p", "question");
  if (answer.usedScreen) question.append(element("span", "screen", answer.looking ? "Looking at the screen… " : "From the screen · "));
  question.append(`“${answer.question}”`);
  box.append(question);
  const spoken = answer.spoken || {};
  if (spoken.headline) box.append(rich("p", "headline", spoken.headline));
  if ((spoken.points || []).length) {
    const list = element("ul", "points");
    for (const point of spoken.points) list.append(rich("li", null, point));
    box.append(list);
  }
  if ((spoken.say || []).length) {
    const say = element("div", "say");
    for (const sentence of spoken.say) say.append(rich("p", null, sentence));
    box.append(say);
  }
  if (spoken.example) {
    const example = element("div", "example");
    example.append(element("b", null, "For example"));
    example.append(rich("span", null, spoken.example));
    box.append(example);
  }
  for (const code of spoken.code || []) box.append(codeView(code));
  if ((spoken.also || []).length) {
    const also = element("div", "also");
    also.append(element("h3", null, answer.alsoTitle));
    const list = element("ul");
    for (const item of spoken.also) list.append(rich("li", null, item));
    also.append(list);
    box.append(also);
  }
  if (answer.writing && !answer.looking) box.append(element("p", "writing", answer.text ? "Writing…" : "Drafting an answer…"));
  return box;
}

function codeView(code) {
  const block = element("div", "code");
  const head = element("header");
  head.append(element("span", null, code.language || "code"), element("span", "spacer"));
  const copy = element("button", "small", "Copy");
  copy.onclick = () => copyText(code.text, copy);
  head.append(copy);
  const pre = element("pre");
  pre.textContent = code.text;
  block.append(head, pre);
  return block;
}

/// Notes in Markdown: headings, bullets, tasks, bold, paragraphs.
function markdown(text) {
  const box = element("div");
  let list = null;
  for (const raw of String(text).split("\n")) {
    const line = raw.trimEnd();
    const heading = line.match(/^(#{1,3})\s+(.*)$/);
    const bullet = line.match(/^\s*(?:[-*•]|\d+[.)])\s+(.*)$/);
    if (bullet) {
      if (!list) { list = element("ul"); box.append(list); }
      const task = bullet[1].match(/^\[( |x|X)\]\s*(.*)$/);
      const item = task ? rich("li", "task", `${task[1].trim() ? "☑" : "☐"} ${task[2]}`) : rich("li", null, bullet[1]);
      list.append(item);
      continue;
    }
    list = null;
    if (heading) box.append(rich(`h${heading[1].length}`, null, heading[2]));
    else if (line.trim()) box.append(rich("p", null, line.trim()));
  }
  return box;
}

function renderNotes() {
  const notes = $("notes");
  if (state.notes) {
    notes.replaceChildren(markdown(state.notes));
    if (state.writingNotes) notes.append(element("p", "writing", "Updating the notes…"));
  } else {
    notes.replaceChildren(element("p", "empty", state.writingNotes ? "Writing the notes…"
      : "Notes show here after a minute or so of talk: what was decided, who does what, and the specifics."));
  }
  const email = $("email");
  const box = element("div", "box");
  if (state.email) {
    box.append(element("b", null, `Subject: ${state.email.subject}`));
    const body = element("pre");
    body.textContent = state.email.body;
    const row = element("div", "row");
    const copy = element("button", "small", "Copy email");
    copy.onclick = () => copyText(`Subject: ${state.email.subject}\n\n${state.email.body}`, copy);
    const mail = element("button", "primary", "Open in Mail");
    mail.onclick = () => act("mail", state.email);
    const redo = element("button", "small", "Redo");
    redo.onclick = () => act("email");
    row.append(copy, mail, redo);
    box.append(body, row);
  } else if (state.draftingEmail) {
    box.append(element("p", "writing", "Drafting the follow-up email…"));
  } else {
    box.append(element("b", null, "Follow-up email"));
    box.append(element("p", "note", "Thanks, what was agreed, who does what, and the next step."));
    const draft = element("button", "primary", "Draft");
    draft.disabled = !(state.notes || (state.lines || []).length);
    draft.onclick = () => act("email");
    box.append(draft);
  }
  email.replaceChildren(box);
}

function renderLines() {
  const lines = $("lines");
  const atEnd = lines.scrollTop + lines.clientHeight >= lines.scrollHeight - 30;
  if (!(state.lines || []).length) {
    lines.replaceChildren(element("p", "empty", "What's said shows here, a stretch of speech at a time."));
    return;
  }
  lines.replaceChildren(...state.lines.map((line) => {
    const row = element("p", "line " + (line.side || line.speaker).toLowerCase());
    // The call's voices can be named: click who said it.
    const who = element(line.voice ? "button" : "span", "who", line.speaker);
    if (line.voice) {
      who.title = "Name this speaker";
      who.onclick = (event) => editSpeaker(line.voice, event.currentTarget);
    }
    row.append(element("span", "time", line.time), who, line.text);
    return row;
  }));
  if (atEnd) lines.scrollTop = lines.scrollHeight;
}

// MARK: Naming a speaker

/// A small card under the speaker's label: their name (the names heard in the meeting and the voices you saved are
/// offered), whether to remember the voice for later meetings, and "the same person as" another voice.
function editSpeaker(voice, anchor) {
  closeSpeaker();
  const info = (state.voices || []).find((v) => v.voice === voice) || { voice, label: "Them", name: "" };
  const card = element("div", "speaker-card");
  card.id = "speaker-card";
  const title = element("b", null, info.name ? info.name : `Who is ${info.label}?`);
  const input = element("input", "field");
  input.type = "text";
  input.value = info.name || "";
  input.placeholder = "Their name";
  input.setAttribute("list", "speaker-people");
  const people = element("datalist");
  people.id = "speaker-people";
  for (const name of state.people || []) people.append(Object.assign(document.createElement("option"), { value: name }));
  const offers = element("div", "offers");
  for (const name of (state.people || []).slice(0, 6)) {
    const chip = element("button", "chip", name);
    chip.onclick = () => { input.value = name; input.focus(); };
    offers.append(chip);
  }
  const remember = element("label", "remember");
  const box = element("input");
  box.type = "checkbox";
  box.checked = !!info.saved;
  box.disabled = !info.canRemember;
  remember.append(box, info.canRemember ? "Remember this voice in later meetings"
    : "Murmur needs to hear a little more of this voice to remember it");
  const why = info.evidence ? element("p", "why", `Named from ${info.evidence}`) : null;
  const buttons = element("div", "buttons");
  const save = element("button", "primary", "Save");
  const done = (name) => {
    act("nameVoice", { voice, name, remember: box.checked && !!name });
    closeSpeaker();
  };
  save.onclick = () => done(input.value.trim());
  input.onkeydown = (event) => {
    if (event.key === "Enter") done(input.value.trim());
    if (event.key === "Escape") closeSpeaker();
  };
  buttons.append(save);
  if (info.name) {
    const wrong = element("button", "secondary", "Not them");
    wrong.onclick = () => done("");
    buttons.append(wrong);
  }
  // Two labels for one person: put them together.
  const others = (state.voices || []).filter((v) => v.voice !== voice);
  let same = null;
  if (others.length) {
    same = element("select", "field");
    same.append(Object.assign(document.createElement("option"), { value: "", textContent: "Same person as…" }));
    for (const other of others) same.append(Object.assign(document.createElement("option"), { value: other.voice, textContent: other.label }));
    same.onchange = () => {
      if (same.value) act("mergeVoices", { from: voice, into: Number(same.value) });
      closeSpeaker();
    };
  }
  card.append(title, input, people, ...(offers.childElementCount ? [offers] : []), remember, ...(why ? [why] : []), buttons, ...(same ? [same] : []));
  document.body.append(card);
  const box2 = anchor.getBoundingClientRect();
  card.style.left = Math.max(8, Math.min(box2.left, window.innerWidth - card.offsetWidth - 8)) + "px";
  card.style.top = Math.max(8, Math.min(box2.bottom + 6, window.innerHeight - card.offsetHeight - 8)) + "px";
  input.focus();
  input.select();
  setTimeout(() => document.addEventListener("mousedown", outsideSpeaker), 0);
}

function outsideSpeaker(event) {
  if (!event.target.closest("#speaker-card")) closeSpeaker();
}

function closeSpeaker() {
  document.removeEventListener("mousedown", outsideSpeaker);
  $("speaker-card")?.remove();
}

function renderContext() {
  if (document.activeElement !== $("about")) $("about").value = state.about || "";
  if (document.activeElement !== $("instructions")) $("instructions").value = state.instructions || "";
  $("documents").replaceChildren(...(state.documents || []).map((document, index) => {
    const row = element("div", "document");
    row.append(element("span", null, document.name));
    const remove = element("button", "link", "Remove");
    remove.onclick = () => act("removeDocument", index);
    row.append(remove);
    return row;
  }));
  $("add-documents").disabled = (state.documents || []).length >= 5;
  const ai = $("ai");
  const options = [["", `Same as commands: ${state.commandsAi}`], ["anthropic", "Claude (Sonnet)"], ["openai", "OpenAI"],
                   ["sarvam", "Sarvam"], ["local", "On this PC (Ollama)"]];
  ai.replaceChildren(...options.map(([value, title]) => {
    const option = element("option", null, title + (value && value !== "local" && !state.keys[value] ? " · needs a key" : ""));
    option.value = value;
    return option;
  }));
  ai.value = state.ai || "";
  $("speech").value = state.speech || "";
  $("opacity").value = Math.round(state.opacity * 100);
  $("opacity-value").textContent = `${Math.round(state.opacity * 100)} %`;
  $("solid").checked = state.solidOnHover;
  $("offers").checked = state.offers;
}

function applyOpacity() {
  const solid = hovering && state.solidOnHover;
  const opacity = solid ? 1 : state.opacity;
  $("panel").style.opacity = String(opacity);
  $("folded").style.opacity = String(Math.max(opacity, 0.8));
}

let problemTimer = null;
function showProblem(text) {
  if (!state) return;
  state.problem = text;
  render();
  clearTimeout(problemTimer);
  problemTimer = setTimeout(() => act("dismissProblem"), 8000);
}

async function copyText(text, button) {
  try {
    await navigator.clipboard.writeText(text);
    if (button) {
      const before = button.textContent;
      button.textContent = "Copied";
      setTimeout(() => { button.textContent = before; }, 1200);
    }
  } catch (error) {
    showProblem(`Couldn't copy: ${error}`);
  }
}

function spokenText(answer) {
  const s = answer.spoken || {};
  const parts = [s.headline, ...(s.points || []), ...(s.say || []), s.example].filter(Boolean);
  let text = parts.join("\n").replace(/\*\*/g, "");
  for (const code of s.code || []) text += `\n\n${code.text}`;
  if ((s.also || []).length) text += `\n\n${answer.alsoTitle}:\n` + s.also.map((a) => `- ${a}`).join("\n");
  return text;
}

// MARK: Controls

for (const button of document.querySelectorAll(".tabs button")) {
  button.onclick = () => { tab = button.dataset.tab; render(); };
}
$("answer-now").onclick = () => act("answerNow");
$("screen").onclick = () => act("screen");
$("more").onclick = (event) => { event.stopPropagation(); $("menu").hidden = !$("menu").hidden; };
document.addEventListener("click", () => { $("menu").hidden = true; });
$("say-next").onclick = () => act("sayNext");
$("follow-ups").onclick = () => act("followUps");
$("recap").onclick = () => act("recap");
$("ask-form").onsubmit = (event) => {
  event.preventDefault();
  const text = $("ask").value.trim();
  if (!text) return;
  $("ask").value = "";
  act("ask", text);
};
$("auto").onchange = () => act("auto", $("auto").checked);
$("mute").onchange = () => act("mute", $("mute").checked);
$("previous").onclick = () => { following = false; act("show", Math.max(0, state.shown - 1)); };
$("next").onclick = () => {
  following = state.shown + 1 >= state.answers.length - 1;
  act("show", Math.min(state.answers.length - 1, state.shown + 1));
};
$("copy-answer").onclick = () => {
  const answer = state.answers[state.shown];
  if (answer) copyText(spokenText(answer), $("copy-answer"));
};
$("copy-notes").onclick = () => copyText(state.notes || (state.lines || []).map((l) => `${l.time} ${l.speaker}: ${l.text}`).join("\n"), $("copy-notes"));
$("show-file").onclick = () => act("openSaved");
$("stop").onclick = () => act(state.running ? "stop" : "start");
$("close").onclick = () => act("close");
$("fold").onclick = () => act("collapse");
$("folded").onclick = () => act("expand");
$("layout").onclick = () => act("layout", state.layout === "strip" ? "card" : "strip");
$("problem-close").onclick = () => act("dismissProblem");
$("about").addEventListener("change", () => act("about", $("about").value));
$("instructions").addEventListener("change", () => act("instructions", $("instructions").value));
$("add-documents").onclick = () => act("addDocuments");
$("ai").onchange = () => act("ai", $("ai").value);
$("speech").onchange = () => act("speech", $("speech").value);
$("opacity").oninput = () => {
  state.opacity = Number($("opacity").value) / 100;
  $("opacity-value").textContent = `${$("opacity").value} %`;
  applyOpacity();
};
$("opacity").onchange = () => act("opacity", Number($("opacity").value) / 100);
$("solid").onchange = () => act("solidOnHover", $("solid").checked);
$("offers").onchange = () => act("offers", $("offers").checked);
$("bigger").onclick = () => act("textSize", Math.min(30, state.textSize + 2));
$("smaller").onclick = () => act("textSize", Math.max(15, state.textSize - 2));
document.addEventListener("mouseenter", () => { hovering = true; if (state) applyOpacity(); });
document.addEventListener("mouseleave", () => { hovering = false; if (state) applyOpacity(); });
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") $("menu").hidden = true;
  if (event.ctrlKey && (event.key === "=" || event.key === "+")) { event.preventDefault(); $("bigger").click(); }
  if (event.ctrlKey && event.key === "-") { event.preventDefault(); $("smaller").click(); }
});

// MARK: Events

tauri.event.listen("meeting", ({ payload }) => {
  const before = state ? state.answers.length : 0;
  state = payload;
  // A new answer: shown, and the Live tab comes up for it.
  if (state.answers.length > before && following) tab = "live";
  render();
});
tauri.event.listen("meeting-answer", ({ payload }) => {
  if (!state) return;
  state.answers[payload.index] = payload.answer;
  if (tab === "live" && state.shown === payload.index) renderLive();
});
tauri.event.listen("meeting-level", ({ payload }) => {
  $("meter-call").style.width = `${Math.round((payload.call || 0) * 100)}%`;
  $("meter-mic").style.width = `${Math.round((payload.mic || 0) * 100)}%`;
});
setInterval(() => { if (state && state.running && !state.collapsed) $("title").textContent = `${state.app || "Listening"} · ${elapsed()}`; }, 1000);

invoke("meeting_state").then((payload) => { state = payload; render(); }).catch(() => {});
})();
