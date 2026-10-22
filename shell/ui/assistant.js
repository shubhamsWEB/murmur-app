// Settings → Commands & AI (window.html; src-tauri/src/commands): telling commands from dictation, AI clean-up and
// its style for each kind of app, the model (Ollama on this PC, or Claude or OpenAI with a key kept in Windows'
// Credential Manager), and what Murmur remembers. In a scope of its own, beside settings.js.
(() => {
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const $ = (id) => document.getElementById(id);

let info = null;          // assistant_info
let models = undefined;   // Ollama's models (null: it isn't running; undefined: not asked yet)

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function fail(error) {
  $("problem").textContent = String(error);
  $("problem").hidden = false;
}

async function set(choice, value) {
  $("problem").hidden = true;
  try {
    await invoke("set_assistant", { choice, value });
  } catch (error) {
    fail(error);
  }
  await load();
}

const company = { anthropic: "Anthropic", openai: "OpenAI" };
const modelKey = { anthropic: "anthropicModel", openai: "openaiModel" };

function render() {
  if (!info) return;
  $("ai-detect").checked = info.detect;
  $("ai-cleanup").checked = info.cleanup;

  // A style for each kind of app, while clean-up is on.
  const styles = $("ai-styles");
  styles.replaceChildren(...(info.cleanup ? info.categories : []).map((category) => {
    const row = element("div", "srow sub");
    const text = element("div", "stext");
    text.append(element("b", null, category.title), element("span", null, category.examples));
    const select = element("select", "field");
    for (const style of category.styles) {
      const option = element("option", null, style.title);
      option.value = style.id;
      select.append(option);
    }
    select.value = category.style;
    select.onchange = () => set("style", { category: category.id, style: select.value });
    row.append(text, select);
    return row;
  }));

  const provider = info.provider;
  $("ai-provider").value = provider;
  $("ai-model-about").textContent = provider === "local"
    ? "Ollama runs the model on this PC: nothing you say leaves it. Commands and clean-up are quicker with a cloud model."
    : `What you say as a command, and dictation to tidy, go to ${company[provider]} with your key. ` +
      "Without a working key, the model on this PC is used.";
  const problem = info.lastError && provider !== "local" ? info.lastError : "";
  $("ai-last-error").textContent = problem;
  $("ai-last-error").hidden = !problem;

  // The local model: Ollama's own list, once it's been asked.
  $("ai-local-row").hidden = provider !== "local";
  const chosen = info.localModel || info.defaults.local;
  const names = Array.isArray(models) ? [...models] : [];
  if (!names.includes(chosen)) names.unshift(chosen);
  const select = $("ai-local-model");
  select.replaceChildren(...names.map((name) => {
    const option = element("option", null, name);
    option.value = name;
    return option;
  }));
  select.value = chosen;
  $("ai-local-about").textContent = !info.ollamaInstalled
    ? "Ollama isn't installed. Get it from ollama.com, then run “ollama pull " + info.defaults.local + "”."
    : models === null ? "Ollama isn't running: open the Ollama app."
    : Array.isArray(models) && !models.includes(chosen) ? `Not downloaded yet: run “ollama pull ${chosen}”.`
    : "A small model (about 4B) answers in a second or two on most PCs.";

  // A cloud model: its key (masked once saved), the workspace (Anthropic), and the model's name.
  const cloud = provider !== "local";
  $("ai-key-row").hidden = !cloud;
  $("ai-cloud-model-row").hidden = !cloud;
  $("ai-workspace-row").hidden = provider !== "anthropic";
  if (cloud) {
    const saved = info.keys[provider];
    $("ai-key-title").textContent = `${company[provider]} API key`;
    $("ai-key-about").textContent = saved
      ? `Saved in Windows' Credential Manager: ${saved}. Paste a new one to replace it, or save it empty to remove it.`
      : `From ${provider === "anthropic" ? "console.anthropic.com → API Keys" : "platform.openai.com → API keys"}. ` +
        "Kept in Windows' Credential Manager.";
    $("ai-key").placeholder = saved ? saved : provider === "anthropic" ? "sk-ant-…" : "sk-…";
    $("ai-key-check").hidden = !saved;
    if (document.activeElement !== $("ai-workspace")) $("ai-workspace").value = info.workspace || "";
    const field = $("ai-cloud-model");
    field.placeholder = info.defaults[provider];
    if (document.activeElement !== field) field.value = info[modelKey[provider]] || "";
    $("ai-cloud-model-about").textContent = `Empty for ${info.defaults[provider]}.`;
  }

  // Memory: what you told Murmur, each removable, and how many commands it keeps.
  const facts = info.facts || [];
  $("ai-memory-about").textContent = (facts.length
    ? `${facts.length} thing${facts.length === 1 ? "" : "s"} you told it`
    : "Nothing you told it yet (“remember that Mom is Roma”, “from now on open links in Chrome”)")
    + `, and ${info.commands} recent command${info.commands === 1 ? "" : "s"}, for follow-ups. Kept on this PC.`;
  $("ai-facts").replaceChildren(...facts.map((fact) => {
    const row = element("div", "row");
    const text = element("div", "text");
    text.append(element("span", "name", fact.text));
    const remove = element("button", "secondary", "Forget");
    remove.onclick = async () => {
      await invoke("forget_memory", { id: fact.id }).catch(fail);
      await load();
    };
    row.append(text, remove);
    return row;
  }));
  $("ai-facts").hidden = facts.length === 0;
}

function showResult(problem, saved) {
  const result = $("ai-key-result");
  result.hidden = false;
  result.classList.toggle("problem", Boolean(problem));
  result.textContent = problem || (saved ? "Saved. The key works." : "The key works.");
}

async function load() {
  info = await invoke("assistant_info").catch(() => null);
  render();
}

async function loadModels() {
  models = await invoke("ollama_models").catch(() => null);
  render();
}

$("ai-detect").addEventListener("change", () => set("detect", $("ai-detect").checked));
$("ai-cleanup").addEventListener("change", () => set("cleanup", $("ai-cleanup").checked));
$("ai-provider").addEventListener("change", async () => {
  $("ai-key-result").hidden = true;
  $("ai-key").value = "";
  await set("provider", $("ai-provider").value);
  if ($("ai-provider").value === "local") loadModels();
});
$("ai-local-model").addEventListener("change", () => set("localModel", $("ai-local-model").value));
$("ai-local-check").onclick = async () => {
  const button = $("ai-local-check");
  button.disabled = true;
  button.textContent = "Checking…";
  const problem = await invoke("check_ai", { provider: "local" }).catch((error) => String(error));
  button.disabled = false;
  button.textContent = "Check";
  $("ai-local-about").textContent = problem || "It answers. Commands and clean-up use it.";
  loadModels();
};
$("ai-key-save").onclick = async () => {
  const provider = info.provider;
  const key = $("ai-key").value;
  const button = $("ai-key-save");
  button.disabled = true;
  button.textContent = key.trim() ? "Checking…" : "Removing…";
  try {
    const problem = await invoke("save_api_key", { provider, key });
    if (key.trim()) showResult(problem, true); else $("ai-key-result").hidden = true;
    if (!problem) $("ai-key").value = "";
  } catch (error) {
    showResult(String(error), false);
  }
  button.disabled = false;
  button.textContent = "Save";
  await load();
};
$("ai-key").addEventListener("keydown", (event) => { if (event.key === "Enter") $("ai-key-save").click(); });
$("ai-key-check").onclick = async () => {
  const button = $("ai-key-check");
  button.disabled = true;
  button.textContent = "Checking…";
  const problem = await invoke("check_ai", { provider: info.provider }).catch((error) => String(error));
  showResult(problem, false);
  button.disabled = false;
  button.textContent = "Check";
  await load();
};
$("ai-workspace").addEventListener("change", () => set("workspace", $("ai-workspace").value));
$("ai-cloud-model").addEventListener("change", () => set(modelKey[info.provider], $("ai-cloud-model").value));
// Clearing everything takes a second click, within a few seconds.
let clearing = null;
$("ai-forget-all").onclick = async () => {
  const button = $("ai-forget-all");
  if (!clearing) {
    button.textContent = "Click Again to Clear";
    clearing = setTimeout(() => { clearing = null; button.textContent = "Clear Memory"; }, 4000);
    return;
  }
  clearTimeout(clearing);
  clearing = null;
  button.textContent = "Clear Memory";
  await invoke("forget_memory", { id: "all" }).catch(fail);
  await load();
};

// Shown afresh when the window comes back (a command may have remembered something meanwhile).
window.addEventListener("focus", () => { load().catch(() => {}); });

load().then(() => { if (info && info.provider === "local") loadModels(); });
})();
