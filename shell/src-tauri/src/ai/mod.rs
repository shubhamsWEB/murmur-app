//! The models behind AI clean-up and voice commands, as the Mac app's AgentKit has them (Router.swift): a local model
//! through Ollama, or Claude or OpenAI with the person's own API key. One conversation shape for all three (turns,
//! tool calls, tool results); each provider's wire format is built and read by pure functions here, tested without a
//! network. The calls are async (reqwest, over Windows' own certificate store and proxy settings, as the updater's
//! are); `blocking` runs one from a plain thread (dictation's).
//!
//! The cloud keys are kept in Windows' Credential Manager (keys.rs), never in the settings file.

pub mod check;
pub mod cleanup;
pub mod keys;
pub mod output;

use serde_json::{json, Map, Value};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// Which model picks the actions for a command (and tidies dictation).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Local,
    Anthropic,
    OpenAI,
}

impl Provider {
    #[allow(dead_code)]
    pub const ALL: [Provider; 3] = [Provider::Local, Provider::Anthropic, Provider::OpenAI];

    pub fn from_name(name: &str) -> Provider {
        match name {
            "anthropic" => Provider::Anthropic,
            "openai" => Provider::OpenAI,
            _ => Provider::Local,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Provider::Local => "local",
            Provider::Anthropic => "anthropic",
            Provider::OpenAI => "openai",
        }
    }

    /// As people know the company.
    pub fn company(self) -> &'static str {
        match self {
            Provider::Local => "Ollama",
            Provider::Anthropic => "Anthropic",
            Provider::OpenAI => "OpenAI",
        }
    }

    /// Where its key is kept (none for the local model).
    pub fn key_account(self) -> Option<&'static str> {
        match self {
            Provider::Local => None,
            Provider::Anthropic => Some("anthropic"),
            Provider::OpenAI => Some("openai"),
        }
    }

    pub fn has_key(self) -> bool {
        self.key_account().and_then(keys::get).is_some()
    }
}

/// What Settings → Commands & AI says (settings.rs keeps it).
#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub provider: Provider,
    /// The Ollama model ("qwen3:4b").
    pub local_model: String,
    pub anthropic_model: String,
    pub openai_model: String,
    /// An organization-wide Anthropic key names its workspace on every request.
    pub anthropic_workspace: String,
}

pub const DEFAULT_LOCAL_MODEL: &str = "qwen3:4b";
pub const DEFAULT_ANTHROPIC_MODEL: &str = "claude-haiku-5-5";
pub const DEFAULT_OPENAI_MODEL: &str = "gpt-6-luna";

impl Default for Config {
    fn default() -> Config {
        Config {
            provider: Provider::Local,
            local_model: DEFAULT_LOCAL_MODEL.into(),
            anthropic_model: DEFAULT_ANTHROPIC_MODEL.into(),
            openai_model: DEFAULT_OPENAI_MODEL.into(),
            anthropic_workspace: String::new(),
        }
    }
}

/// A conversation turn, whatever the provider.
#[derive(Clone, Debug, PartialEq)]
pub enum Turn {
    User(String),
    Assistant { text: String, calls: Vec<Call> },
    ToolResult { id: String, name: String, content: String },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Call {
    pub id: String,
    pub name: String,
    pub arguments: Map<String, Value>,
}

impl Call {
    /// An argument as text: a string as it is, a number or a true/false written out, nothing as "".
    pub fn text(&self, key: &str) -> String {
        match self.arguments.get(key) {
            Some(Value::String(s)) => s.trim().to_string(),
            Some(Value::Null) | None => String::new(),
            Some(other) => other.to_string(),
        }
    }

    pub fn number(&self, key: &str) -> Option<f64> {
        match self.arguments.get(key) {
            Some(Value::Number(n)) => n.as_f64(),
            Some(Value::String(s)) => s.trim().trim_end_matches('%').trim().parse().ok(),
            _ => None,
        }
    }

    #[cfg_attr(not(windows), allow(dead_code))]
    pub fn flag(&self, key: &str) -> Option<bool> {
        match self.arguments.get(key) {
            Some(Value::Bool(b)) => Some(*b),
            Some(Value::String(s)) => match s.trim().to_lowercase().as_str() {
                "true" | "yes" | "on" | "1" => Some(true),
                "false" | "no" | "off" | "0" => Some(false),
                _ => None,
            },
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Reply {
    pub text: String,
    pub calls: Vec<Call>,
}

#[derive(Clone, Debug)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    /// JSON Schema for the arguments.
    pub parameters: Value,
}

#[derive(Clone, Debug, PartialEq)]
pub enum AiError {
    NoKey(&'static str),
    Http { provider: &'static str, code: u16, detail: String },
    Unreachable(&'static str),
    OllamaNotRunning,
    OllamaModelMissing(String),
}

impl std::fmt::Display for AiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AiError::NoKey(provider) => write!(f, "No {provider} API key. Add one in Settings → Commands & AI."),
            AiError::Http { provider, code, detail } => {
                let why = detail.trim();
                if let Some(advice) = check::advice(provider, *code, why) {
                    return f.write_str(&advice);
                }
                match code {
                    401 | 403 => write!(f, "{provider} rejected the API key ({code}){}",
                                        if why.is_empty() { ".".to_string() } else { format!(": {}", cut(why, 160)) }),
                    429 => write!(f, "{provider} says you're over your rate limit or quota (429)."),
                    _ => write!(f, "{provider} returned {code}: {}", cut(why, 120)),
                }
            }
            AiError::Unreachable(provider) => write!(f, "Couldn't reach {provider}."),
            AiError::OllamaNotRunning => f.write_str(if ollama_installed() {
                "Ollama isn't running. Open the Ollama app, then try again."
            } else {
                NEEDS_MODEL
            }),
            AiError::OllamaModelMissing(model) => write!(f, "The model {model} isn't installed. Run: ollama pull {model}"),
        }
    }
}

pub const NEEDS_MODEL: &str =
    "Commands like this need a model. Install Ollama, or add a Claude or OpenAI key in Settings → Commands & AI.";

pub fn cut(text: &str, chars: usize) -> String {
    text.chars().take(chars).collect()
}

// MARK: What went wrong last (a rejected key isn't asked again until a new one is saved)

static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);

pub fn last_error() -> Option<String> {
    LAST_ERROR.lock().unwrap().clone()
}

pub fn set_last_error(error: Option<String>) {
    *LAST_ERROR.lock().unwrap() = error;
}

/// Errors that mean the API key is wrong.
pub fn is_key_problem(error: Option<&str>) -> bool {
    let Some(error) = error else { return false };
    error.contains("rejected the API key") || error.contains("(401)") || error.contains("(403)")
        || check::workspace_needed(error)
        || (error.starts_with("No ") && error.contains("API key"))
}

// MARK: The model for this request

/// A model that can call tools.
#[derive(Clone, Debug, PartialEq)]
pub enum Router {
    Ollama { model: String },
    Anthropic { model: String, workspace: String },
    OpenAI { model: String },
}

/// The model chosen; a cloud choice without a key, or whose key was just rejected, falls back to the local one.
pub fn current(config: &Config) -> Router {
    let rejected = is_key_problem(last_error().as_deref());
    match config.provider {
        Provider::Anthropic if Provider::Anthropic.has_key() && !rejected => Router::Anthropic {
            model: or_default(&config.anthropic_model, DEFAULT_ANTHROPIC_MODEL),
            workspace: config.anthropic_workspace.trim().to_string(),
        },
        Provider::OpenAI if Provider::OpenAI.has_key() && !rejected => Router::OpenAI {
            model: or_default(&config.openai_model, DEFAULT_OPENAI_MODEL),
        },
        _ => local(config),
    }
}

pub fn local(config: &Config) -> Router {
    Router::Ollama { model: or_default(&config.local_model, DEFAULT_LOCAL_MODEL) }
}

fn or_default(value: &str, default: &str) -> String {
    let value = value.trim();
    if value.is_empty() { default.to_string() } else { value.to_string() }
}

impl Router {
    /// For the log and the pill: "Claude", "OpenAI", "Local model".
    pub fn name(&self) -> &'static str {
        match self {
            Router::Ollama { .. } => "Local model",
            Router::Anthropic { .. } => "Claude",
            Router::OpenAI { .. } => "OpenAI",
        }
    }

    pub fn is_local(&self) -> bool {
        matches!(self, Router::Ollama { .. })
    }

    /// One turn of the conversation. Plain text (no tools) is capped, so a summary can't run to pages.
    pub async fn chat(&self, system: &str, turns: &[Turn], tools: &[ToolSpec], timeout: Duration) -> Result<Reply, AiError> {
        match self {
            Router::Ollama { model } => {
                let mut body = ollama::body(model, system, turns, tools, if tools.is_empty() { Some(700) } else { None });
                let mut parsed = ollama::parse(&post(OLLAMA_CHAT, &[], &body, timeout, "Ollama").await?);
                // Only reasoning came back (the model ignored "think": false and ran out of room mid-thought): once
                // more, with Qwen's own switch and more room.
                if parsed.reply.text.is_empty() && parsed.reply.calls.is_empty() && parsed.reasoned {
                    ollama::no_think(&mut body, if tools.is_empty() { Some(1500) } else { None });
                    parsed = ollama::parse(&post(OLLAMA_CHAT, &[], &body, timeout, "Ollama").await?);
                }
                Ok(parsed.reply)
            }
            Router::Anthropic { model, workspace } => {
                let body = anthropic::body(model, system, turns, tools, 2048);
                Ok(anthropic::parse(&post(ANTHROPIC, &anthropic::headers(workspace)?, &body, timeout, "Anthropic").await?))
            }
            Router::OpenAI { model } => {
                let mut body = openai::body(model, system, turns, tools);
                let headers = openai::headers()?;
                let json = match post(OPENAI, &headers, &body, timeout, "OpenAI").await {
                    // An older model that won't take reasoning_effort "none": ask without it.
                    Err(AiError::Http { code: 400, detail, .. }) if body.get("reasoning_effort").is_some()
                        && detail.to_lowercase().contains("reasoning_effort") => {
                        body.as_object_mut().unwrap().remove("reasoning_effort");
                        post(OPENAI, &headers, &body, timeout, "OpenAI").await?
                    }
                    other => other?,
                };
                Ok(openai::parse(&json))
            }
        }
    }

    /// Picks one of `options` (a forced single answer). None on failure or after `timeout`.
    pub async fn choose(&self, system: &str, user: &str, field: &str, options: &[&str], timeout: Duration) -> Option<String> {
        let schema = json!({"type": "object", "properties": {field: {"type": "string", "enum": options}}, "required": [field]});
        let result = match self {
            Router::Ollama { model } => {
                let body = json!({
                    "model": model, "stream": false, "think": false, "keep_alive": "30m", "format": schema,
                    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                    "options": ollama::options(json!({"temperature": 0, "num_predict": 24})),
                });
                post(OLLAMA_CHAT, &[], &body, timeout, "Ollama").await.ok().and_then(|json| {
                    let content = json["message"]["content"].as_str()?.to_string();
                    let answer: Value = serde_json::from_str(&content).ok()?;
                    answer[field].as_str().map(String::from)
                })
            }
            Router::Anthropic { model, workspace } => {
                let mut body = anthropic::base(model, system, 64);
                body["messages"] = json!([{"role": "user", "content": user}]);
                body["tools"] = json!([{"name": "answer", "description": "Give the answer", "input_schema": schema}]);
                body["tool_choice"] = json!({"type": "tool", "name": "answer"});
                match post(ANTHROPIC, &anthropic::headers(workspace).ok()?, &body, timeout, "Anthropic").await {
                    Ok(json) => {
                        set_last_error(None);
                        anthropic::parse(&json).calls.first().map(|call| call.text(field))
                    }
                    Err(error) => {
                        set_last_error(Some(error.to_string()));
                        None
                    }
                }
            }
            Router::OpenAI { model } => {
                let tool = ToolSpec { name: "answer".into(), description: "Give the answer".into(), parameters: schema };
                let mut body = json!({
                    "model": model,
                    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                    "tools": openai::tool_list(&[tool]),
                    "tool_choice": {"type": "function", "function": {"name": "answer"}},
                    "reasoning_effort": "none",
                });
                let headers = openai::headers().ok()?;
                let result = match post(OPENAI, &headers, &body, timeout, "OpenAI").await {
                    Err(AiError::Http { code: 400, detail, .. }) if detail.to_lowercase().contains("reasoning_effort") => {
                        body.as_object_mut().unwrap().remove("reasoning_effort");
                        post(OPENAI, &headers, &body, timeout, "OpenAI").await
                    }
                    other => other,
                };
                match result {
                    Ok(json) => {
                        set_last_error(None);
                        openai::parse(&json).calls.first().map(|call| call.text(field))
                    }
                    Err(error) => {
                        set_last_error(Some(error.to_string()));
                        None
                    }
                }
            }
        };
        result.filter(|answer| options.contains(&answer.as_str()))
    }
}

// MARK: HTTP

const OLLAMA: &str = "http://127.0.0.1:11434";
const OLLAMA_CHAT: &str = "http://127.0.0.1:11434/api/chat";
const ANTHROPIC: &str = "https://api.anthropic.com/v1/messages";
const OPENAI: &str = "https://api.openai.com/v1/chat/completions";

fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        // As the updater does: the ring provider, unless something already chose one.
        if rustls::crypto::CryptoProvider::get_default().is_none() {
            let _ = rustls::crypto::ring::default_provider().install_default();
        }
        reqwest::Client::builder().connect_timeout(Duration::from_secs(10)).build().unwrap_or_default()
    })
}

/// POSTs JSON; the reply's JSON on 200, else what the provider said was wrong.
async fn post(url: &str, headers: &[(String, String)], body: &Value, timeout: Duration, provider: &'static str)
    -> Result<Value, AiError> {
    let mut request = client().post(url).timeout(timeout).json(body);
    for (name, value) in headers {
        request = request.header(name.as_str(), value.as_str());
    }
    let response = request.send().await.map_err(|_| {
        if provider == "Ollama" { AiError::OllamaNotRunning } else { AiError::Unreachable(provider) }
    })?;
    let code = response.status().as_u16();
    let text = response.text().await.unwrap_or_default();
    let json: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    if code == 200 {
        return Ok(json);
    }
    let detail = json["error"]["message"].as_str().or_else(|| json["error"].as_str()).map(String::from)
        .unwrap_or_else(|| cut(&text, 300));
    if provider == "Ollama" && (code == 404 || detail.contains("not found")) {
        return Err(AiError::OllamaModelMissing(body["model"].as_str().unwrap_or_default().to_string()));
    }
    Err(AiError::Http { provider, code, detail })
}

/// Runs one of these async calls from a plain thread (dictation's), never from the async runtime's own threads.
pub fn blocking<T>(future: impl std::future::Future<Output = T>) -> T {
    tauri::async_runtime::block_on(future)
}

// MARK: Ollama (local)

/// Whether Ollama is installed: its app, or `ollama` on the PATH.
pub fn ollama_installed() -> bool {
    let local = std::env::var_os("LOCALAPPDATA").map(std::path::PathBuf::from);
    if local.map(|folder| folder.join("Programs").join("Ollama").join("ollama.exe").exists()).unwrap_or(false) {
        return true;
    }
    let exe = if cfg!(windows) { "ollama.exe" } else { "ollama" };
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|folder| folder.join(exe).exists()))
        .unwrap_or(false)
}

/// The models Ollama has pulled ("qwen3:4b"…); None when it isn't running.
pub async fn ollama_models() -> Option<Vec<String>> {
    let response = client().get(format!("{OLLAMA}/api/tags")).timeout(Duration::from_millis(1500)).send().await.ok()?;
    let json: Value = response.json().await.ok()?;
    Some(json["models"].as_array()?.iter().filter_map(|model| model["name"].as_str().map(String::from)).collect())
}

/// Loads the model ahead of the first command, so it answers fast.
pub async fn ollama_warm_up(model: &str) {
    let body = json!({"model": model, "keep_alive": "30m", "options": ollama::options(json!({}))});
    let _ = client().post(format!("{OLLAMA}/api/generate")).timeout(Duration::from_secs(60)).json(&body).send().await;
}

mod ollama {
    use super::{output, Call, Reply, ToolSpec, Turn};
    use serde_json::{json, Value};

    /// The context the model gets, in tokens: Ollama's own default (4,096) silently cuts Murmur's instructions and
    /// tools from the start. Every call sends the same size (another makes Ollama reload the model).
    pub fn context_window() -> u64 {
        if super::total_memory_gb().is_some_and(|gb| gb <= 9.0) { 8192 } else { 16384 }
    }

    pub fn options(extra: Value) -> Value {
        let mut options = json!({"num_ctx": context_window()});
        if let Value::Object(extra) = extra {
            for (key, value) in extra {
                options[key] = value;
            }
        }
        options
    }

    pub fn messages(system: &str, turns: &[Turn]) -> Vec<Value> {
        let mut out = vec![json!({"role": "system", "content": system})];
        for turn in turns {
            out.push(match turn {
                Turn::User(text) => json!({"role": "user", "content": text}),
                Turn::Assistant { text, calls } => json!({
                    "role": "assistant", "content": text,
                    "tool_calls": calls.iter().map(|call| json!({"function": {"name": call.name, "arguments": call.arguments}})).collect::<Vec<_>>(),
                }),
                Turn::ToolResult { name, content, .. } => json!({"role": "tool", "tool_name": name, "content": content}),
            });
        }
        out
    }

    pub fn body(model: &str, system: &str, turns: &[Turn], tools: &[ToolSpec], max_tokens: Option<u64>) -> Value {
        let mut extra = json!({"temperature": 0});
        if let Some(cap) = max_tokens {
            extra["num_predict"] = json!(cap);
        }
        json!({
            "model": model,
            "messages": messages(system, turns),
            "tools": super::openai::tool_list(tools),
            "stream": false,
            "think": false,          // a router needs a decision, not a chain of thought
            "keep_alive": "30m",     // stay loaded between commands
            "options": options(extra),
        })
    }

    /// Asks again with Qwen's own "don't think" switch, and more room.
    pub fn no_think(body: &mut Value, max_tokens: Option<u64>) {
        if let Some(messages) = body["messages"].as_array_mut() {
            if let Some(last) = messages.iter_mut().rev().find(|m| m["role"] == "user") {
                let text = last["content"].as_str().unwrap_or_default().to_string();
                last["content"] = json!(format!("{text}\n\n/no_think Reply with the answer only."));
            }
        }
        if let Some(cap) = max_tokens {
            body["options"]["num_predict"] = json!(cap);
        }
    }

    pub struct Parsed {
        pub reply: Reply,
        /// The raw answer had reasoning in it.
        pub reasoned: bool,
    }

    pub fn parse(json: &Value) -> Parsed {
        let message = &json["message"];
        let raw = message["content"].as_str().unwrap_or_default();
        let calls = message["tool_calls"].as_array().map(|calls| {
            calls.iter().enumerate().filter_map(|(index, call)| {
                let function = &call["function"];
                let name = function["name"].as_str()?.to_string();
                let mut arguments = super::arguments(&function["arguments"]);
                // Text a tool call carries never includes the model's reasoning either.
                for value in arguments.values_mut() {
                    if let Value::String(text) = value {
                        if output::had_reasoning(text) {
                            *text = output::answer(text);
                        }
                    }
                }
                Some(Call { id: format!("call_{index}"), name, arguments })
            }).collect()
        }).unwrap_or_default();
        Parsed { reply: Reply { text: output::answer(raw), calls }, reasoned: output::had_reasoning(raw) }
    }
}

/// A tool call's arguments: an object, or an object written as a string.
fn arguments(raw: &Value) -> Map<String, Value> {
    match raw {
        Value::Object(map) => map.clone(),
        Value::String(text) => serde_json::from_str::<Value>(text).ok()
            .and_then(|value| value.as_object().cloned()).unwrap_or_default(),
        _ => Map::new(),
    }
}

// MARK: Anthropic

mod anthropic {
    use super::{AiError, Call, Reply, ToolSpec, Turn};
    use serde_json::{json, Value};

    pub fn headers(workspace: &str) -> Result<Vec<(String, String)>, AiError> {
        let key = super::keys::get("anthropic").ok_or(AiError::NoKey("Anthropic"))?;
        let mut headers = vec![("x-api-key".to_string(), key), ("anthropic-version".to_string(), "2023-06-01".to_string())];
        if !workspace.is_empty() {
            headers.push(("anthropic-workspace-id".to_string(), workspace.to_string()));
        }
        Ok(headers)
    }

    /// Fastest settings: no extended thinking, low effort.
    pub fn base(model: &str, system: &str, max_tokens: u64) -> Value {
        json!({"model": model, "max_tokens": max_tokens, "system": system,
               "thinking": {"type": "disabled"}, "output_config": {"effort": "low"}})
    }

    pub fn messages(turns: &[Turn]) -> Vec<Value> {
        let mut out: Vec<Value> = vec![];
        for turn in turns {
            match turn {
                Turn::User(text) => out.push(json!({"role": "user", "content": text})),
                Turn::Assistant { text, calls } => {
                    let mut blocks = vec![];
                    if !text.is_empty() {
                        blocks.push(json!({"type": "text", "text": text}));
                    }
                    for call in calls {
                        blocks.push(json!({"type": "tool_use", "id": call.id, "name": call.name, "input": call.arguments}));
                    }
                    out.push(json!({"role": "assistant", "content": blocks}));
                }
                Turn::ToolResult { id, content, .. } => {
                    let block = json!({"type": "tool_result", "tool_use_id": id, "content": content});
                    // Consecutive results belong in one user message.
                    if let Some(last) = out.last_mut() {
                        if last["role"] == "user" && last["content"][0]["type"] == "tool_result" {
                            last["content"].as_array_mut().unwrap().push(block);
                            continue;
                        }
                    }
                    out.push(json!({"role": "user", "content": [block]}));
                }
            }
        }
        out
    }

    pub fn body(model: &str, system: &str, turns: &[Turn], tools: &[ToolSpec], max_tokens: u64) -> Value {
        let mut body = base(model, system, max_tokens);
        body["messages"] = json!(messages(turns));
        if !tools.is_empty() {
            body["tools"] = json!(tools.iter().map(|tool| json!({
                "name": tool.name, "description": tool.description, "input_schema": tool.parameters,
            })).collect::<Vec<_>>());
        }
        body
    }

    pub fn parse(json: &Value) -> Reply {
        let mut reply = Reply::default();
        for block in json["content"].as_array().into_iter().flatten() {
            match block["type"].as_str() {
                Some("text") => reply.text.push_str(block["text"].as_str().unwrap_or_default()),
                Some("tool_use") => reply.calls.push(Call {
                    id: block["id"].as_str().map(String::from).unwrap_or_else(|| format!("call_{}", reply.calls.len())),
                    name: block["name"].as_str().unwrap_or_default().to_string(),
                    arguments: super::arguments(&block["input"]),
                }),
                _ => {}
            }
        }
        reply
    }
}

// MARK: OpenAI

mod openai {
    use super::{AiError, Call, Reply, ToolSpec, Turn};
    use serde_json::{json, Value};

    pub fn headers() -> Result<Vec<(String, String)>, AiError> {
        let key = super::keys::get("openai").ok_or(AiError::NoKey("OpenAI"))?;
        Ok(vec![("Authorization".to_string(), format!("Bearer {key}"))])
    }

    pub fn tool_list(tools: &[ToolSpec]) -> Vec<Value> {
        tools.iter().map(|tool| json!({"type": "function", "function": {
            "name": tool.name, "description": tool.description, "parameters": tool.parameters,
        }})).collect()
    }

    pub fn messages(system: &str, turns: &[Turn]) -> Vec<Value> {
        let mut out = vec![json!({"role": "system", "content": system})];
        for turn in turns {
            out.push(match turn {
                Turn::User(text) => json!({"role": "user", "content": text}),
                Turn::Assistant { text, calls } => {
                    let mut message = json!({"role": "assistant", "content": text});
                    if !calls.is_empty() {
                        message["tool_calls"] = json!(calls.iter().map(|call| json!({
                            "id": call.id, "type": "function",
                            "function": {"name": call.name, "arguments": Value::Object(call.arguments.clone()).to_string()},
                        })).collect::<Vec<_>>());
                    }
                    message
                }
                Turn::ToolResult { id, content, .. } => json!({"role": "tool", "tool_call_id": id, "content": content}),
            });
        }
        out
    }

    pub fn body(model: &str, system: &str, turns: &[Turn], tools: &[ToolSpec]) -> Value {
        let mut body = json!({"model": model, "messages": messages(system, turns)});
        if !tools.is_empty() {
            // An empty list is an error; none means plain text. Tools with reasoning on are refused by newer
            // models: a router picks tools fast with it off.
            body["tools"] = json!(tool_list(tools));
            body["reasoning_effort"] = json!("none");
        }
        body
    }

    pub fn parse(json: &Value) -> Reply {
        let message = &json["choices"][0]["message"];
        let calls = message["tool_calls"].as_array().into_iter().flatten().enumerate().filter_map(|(index, call)| {
            let function = &call["function"];
            Some(Call {
                id: call["id"].as_str().map(String::from).unwrap_or_else(|| format!("call_{index}")),
                name: function["name"].as_str()?.to_string(),
                arguments: super::arguments(&function["arguments"]),
            })
        }).collect();
        Reply { text: message["content"].as_str().unwrap_or_default().to_string(), calls }
    }
}

/// This computer's memory, in GB (for the local model's context size).
fn total_memory_gb() -> Option<f64> {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
        let mut status: MEMORYSTATUSEX = std::mem::zeroed();
        status.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
        if GlobalMemoryStatusEx(&mut status) != 0 {
            return Some(status.ullTotalPhys as f64 / 1_073_741_824.0);
        }
    }
    None
}

// MARK: Checking a key

/// Asks the provider whether the saved key works, with a one-token request to the same model and endpoint commands
/// use. None when it works, else what's wrong, in plain words.
pub async fn verify(provider: Provider, config: &Config) -> Option<String> {
    let account = provider.key_account()?;
    let Some(key) = keys::get(account) else { return Some("No key saved.".into()) };
    let company = provider.company();
    let (url, headers, body) = match provider {
        Provider::OpenAI => (OPENAI, vec![("Authorization".to_string(), format!("Bearer {key}"))],
                             json!({"model": or_default(&config.openai_model, DEFAULT_OPENAI_MODEL), "max_completion_tokens": 16,
                                    "messages": [{"role": "user", "content": "Reply with OK."}]})),
        Provider::Anthropic => {
            let mut headers = vec![("x-api-key".to_string(), key), ("anthropic-version".to_string(), "2023-06-01".to_string())];
            if !config.anthropic_workspace.trim().is_empty() {
                headers.push(("anthropic-workspace-id".to_string(), config.anthropic_workspace.trim().to_string()));
            }
            (ANTHROPIC, headers, json!({"model": or_default(&config.anthropic_model, DEFAULT_ANTHROPIC_MODEL), "max_tokens": 1,
                                         "messages": [{"role": "user", "content": "Reply with OK."}]}))
        }
        Provider::Local => return None,
    };
    let company_static: &'static str = provider.company();
    match post(url, &headers, &body, Duration::from_secs(20), company_static).await {
        Ok(_) => {
            set_last_error(None);
            None
        }
        Err(AiError::Unreachable(_)) => Some(format!("Couldn't reach {company} to check the key. Check your internet connection.")),
        Err(AiError::Http { code, detail, .. }) => {
            if check::workspace_needed(&detail) {
                set_last_error(Some(detail));
                return Some("This Anthropic key belongs to your whole organization, so Murmur also needs the ID of the \
                             workspace to use. Find it in the Anthropic Console under Settings → Workspaces.".into());
            }
            let error = AiError::Http { provider: company_static, code, detail: detail.clone() };
            set_last_error(Some(error.to_string()));
            if let Some(advice) = check::advice(company, code, &detail) {
                return Some(advice);
            }
            let said = if detail.is_empty() { ".".to_string() } else {
                let detail = cut(detail.trim(), 200);
                // "invalid x-api-key" → "invalid x-api-key.": a sentence follows.
                if detail.ends_with(['.', '!', '?']) { format!(": {detail}") } else { format!(": {detail}.") }
            };
            match code {
                401 => Some(format!("{company} rejected this key (401){said} Copy the whole key again from your {company} account.")),
                403 => Some(format!("{company} refused this key (403){said} Check the key's project or workspace permissions in your {company} console.")),
                // Signed in fine; the request itself was refused (a model's parameter rules): commands may still work.
                400 => {
                    set_last_error(None);
                    None
                }
                _ => Some(format!("{company} answered {code} when checking the key{said}. It may still work; try a command.")),
            }
        }
        Err(other) => Some(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(name: &str, arguments: Value) -> Call {
        Call { id: "call_1".into(), name: name.into(), arguments: arguments.as_object().unwrap().clone() }
    }

    fn tools() -> Vec<ToolSpec> {
        vec![ToolSpec { name: "open_app".into(), description: "Open an app".into(),
                        parameters: json!({"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}) }]
    }

    #[test]
    fn anthropic_round_trip() {
        let turns = vec![
            Turn::User("open slack".into()),
            Turn::Assistant { text: String::new(), calls: vec![call("open_app", json!({"name": "Slack"}))] },
            Turn::ToolResult { id: "call_1".into(), name: "open_app".into(), content: "Opened Slack.".into() },
            Turn::ToolResult { id: "call_2".into(), name: "done".into(), content: "ok".into() },
        ];
        let body = anthropic::body("claude-haiku-5-5", "sys", &turns, &tools(), 2048);
        assert_eq!(body["system"], "sys");
        assert_eq!(body["thinking"]["type"], "disabled");
        assert_eq!(body["tools"][0]["input_schema"]["required"][0], "name");
        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3, "both tool results share one user message");
        assert_eq!(messages[1]["content"][0]["type"], "tool_use");
        assert_eq!(messages[1]["content"][0]["input"]["name"], "Slack");
        assert_eq!(messages[2]["content"].as_array().unwrap().len(), 2);
        let reply = anthropic::parse(&json!({"content": [
            {"type": "text", "text": "Opening it."},
            {"type": "tool_use", "id": "toolu_1", "name": "open_app", "input": {"name": "Slack"}},
        ]}));
        assert_eq!(reply.text, "Opening it.");
        assert_eq!(reply.calls[0].id, "toolu_1");
        assert_eq!(reply.calls[0].text("name"), "Slack");
    }

    #[test]
    fn openai_round_trip() {
        let turns = vec![
            Turn::User("volume 30".into()),
            Turn::Assistant { text: String::new(), calls: vec![call("set_volume", json!({"percent": 30}))] },
            Turn::ToolResult { id: "call_1".into(), name: "set_volume".into(), content: "Volume 30%.".into() },
        ];
        let body = openai::body("gpt-6-luna", "sys", &turns, &tools());
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["reasoning_effort"], "none");
        assert_eq!(body["messages"][2]["tool_calls"][0]["function"]["arguments"], "{\"percent\":30}");
        assert_eq!(body["messages"][3]["tool_call_id"], "call_1");
        assert!(openai::body("m", "s", &turns, &[]).get("tools").is_none(), "no tools: none sent");
        let reply = openai::parse(&json!({"choices": [{"message": {"content": null, "tool_calls": [
            {"id": "c9", "type": "function", "function": {"name": "set_volume", "arguments": "{\"percent\": \"30\"}"}}
        ]}}]}));
        assert_eq!(reply.calls[0].number("percent"), Some(30.0));
        assert_eq!(reply.text, "");
    }

    #[test]
    fn ollama_drops_reasoning() {
        let parsed = ollama::parse(&json!({"message": {"content": "<think>hmm</think>It's 4 pm.", "tool_calls": [
            {"function": {"name": "reply", "arguments": {"text": "<think>x</think>Sure"}}}
        ]}}));
        assert_eq!(parsed.reply.text, "It's 4 pm.");
        assert!(parsed.reasoned);
        assert_eq!(parsed.reply.calls[0].text("text"), "Sure");
        let body = ollama::body("qwen3:4b", "sys", &[Turn::User("hi".into())], &[], Some(700));
        assert_eq!(body["think"], false);
        assert_eq!(body["options"]["num_predict"], 700);
        assert!(body["options"]["num_ctx"].as_u64().unwrap() >= 8192);
    }

    #[test]
    fn arguments_as_text() {
        let call = call("x", json!({"on": "true", "n": 5, "s": " hi ", "b": false}));
        assert_eq!(call.flag("on"), Some(true));
        assert_eq!(call.flag("b"), Some(false));
        assert_eq!(call.text("n"), "5");
        assert_eq!(call.text("s"), "hi");
        assert_eq!(call.text("missing"), "");
    }

    #[test]
    fn key_problems() {
        assert!(is_key_problem(Some("Anthropic rejected the API key (401).")));
        assert!(is_key_problem(Some("No OpenAI API key. Add one in Settings → Commands & AI.")));
        assert!(!is_key_problem(Some("Couldn't reach OpenAI.")));
        assert!(!is_key_problem(None));
        let error = AiError::Http { provider: "OpenAI", code: 429, detail: "You exceeded your current quota, please check your plan and billing".into() };
        assert!(error.to_string().contains("no API credit left"));
    }

    #[test]
    fn provider_names_round_trip() {
        for provider in Provider::ALL {
            assert_eq!(Provider::from_name(provider.name()), provider);
        }
        assert_eq!(Provider::from_name(""), Provider::Local);
    }
}
