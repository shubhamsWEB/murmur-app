//! A plain-text answer as it's written, a few words at a time (meeting answers show while they're being written
//! instead of all at once after a few seconds), as the Mac's RouterStream.swift: server-sent events from Claude,
//! OpenAI and Sarvam, Ollama's one JSON object per line. With a picture for the models that look at pictures (Claude,
//! OpenAI). If a stream fails before any text came, it's asked once more without streaming.
//!
//! `thorough`: quality over speed (meeting answers and notes): Claude's stronger model at medium effort, and some
//! reasoning for an OpenAI model that takes an effort.

use super::{anthropic, client, ollama, openai, AiError, Router, Turn};
use serde_json::{json, Value};
use std::time::Duration;

/// Claude's model for meeting answers and notes (Sonnet), unless `MURMUR_MEETING_MODEL` names another.
pub const THOROUGH_ANTHROPIC_MODEL: &str = "claude-sonnet-5-5";

pub fn thorough_anthropic_model() -> String {
    std::env::var("MURMUR_MEETING_MODEL").ok().filter(|m| !m.trim().is_empty())
        .unwrap_or_else(|| THOROUGH_ANTHROPIC_MODEL.to_string())
}

/// A picture to look at with the prompt: its bytes and media type ("image/png").
#[derive(Clone, Debug)]
pub struct Picture {
    pub bytes: Vec<u8>,
    pub media: &'static str,
}

impl Picture {
    fn base64(&self) -> String {
        base64(&self.bytes)
    }
}

impl Router {
    /// Whether this router's model can look at a picture.
    pub fn looks_at_images(&self) -> bool {
        matches!(self, Router::Anthropic { .. } | Router::OpenAI { .. })
    }

    /// The model that answers when `thorough` ("Claude (claude-sonnet-5-5)"), for the panel and the log.
    pub fn display(&self, thorough: bool) -> String {
        match self {
            Router::Anthropic { model, .. } => format!("Claude ({})", if thorough { thorough_anthropic_model() } else { model.clone() }),
            Router::OpenAI { model } => format!("OpenAI ({model})"),
            Router::Sarvam { model } => format!("Sarvam ({model})"),
            Router::Ollama { model } => format!("Local model ({model})"),
        }
    }

    /// Writes an answer, handing each new piece of text to `piece` as it comes; the whole text at the end. `stop`:
    /// asked between pieces, true to give up (the answer's no longer wanted).
    pub async fn write(&self, system: &str, prompt: &str, picture: Option<&Picture>, max_tokens: u64, thorough: bool,
                       piece: &mut (dyn FnMut(&str) + Send), stop: &(dyn Fn() -> bool + Sync)) -> Result<String, AiError> {
        let picture = picture.filter(|_| self.looks_at_images());
        let mut text = String::new();
        let streamed = self.stream(system, prompt, picture, max_tokens, thorough, &mut |new: &str| {
            text.push_str(new);
            piece(new);
        }, stop).await;
        match streamed {
            Ok(()) => Ok(text),
            Err(error) if !text.is_empty() || stop() => Err(error),
            // Nothing came: once more, all at once.
            Err(_) => {
                let reply = self.chat(system, &[Turn::User(prompt.to_string())], &[], Duration::from_secs(120)).await?;
                piece(&reply.text);
                Ok(reply.text)
            }
        }
    }

    async fn stream(&self, system: &str, prompt: &str, picture: Option<&Picture>, max_tokens: u64, thorough: bool,
                    piece: &mut (dyn FnMut(&str) + Send), stop: &(dyn Fn() -> bool + Sync)) -> Result<(), AiError> {
        match self {
            Router::Anthropic { model, workspace } => {
                let mut body = anthropic::base(model, system, max_tokens);
                if thorough {
                    body["model"] = json!(thorough_anthropic_model());
                    body["output_config"] = json!({"effort": "medium"});
                }
                body["messages"] = json!([{"role": "user", "content": match picture {
                    Some(picture) => json!([
                        {"type": "image", "source": {"type": "base64", "media_type": picture.media, "data": picture.base64()}},
                        {"type": "text", "text": prompt},
                    ]),
                    None => json!(prompt),
                }}]);
                body["stream"] = json!(true);
                let headers = anthropic::headers(workspace)?;
                lines(ANTHROPIC, &headers, &body, "Anthropic", piece, stop, anthropic_piece).await
            }
            Router::OpenAI { model } | Router::Sarvam { model } => {
                let sarvam = matches!(self, Router::Sarvam { .. });
                let user = match picture {
                    Some(picture) => json!({"role": "user", "content": [
                        {"type": "text", "text": prompt},
                        {"type": "image_url", "image_url": {"url": format!("data:{};base64,{}", picture.media, picture.base64())}},
                    ]}),
                    None => json!({"role": "user", "content": prompt}),
                };
                let mut body = json!({
                    "model": model, "stream": true,
                    "messages": [{"role": "system", "content": system}, user],
                    // As little reasoning as the model takes; some, for a thorough answer from OpenAI.
                    "reasoning_effort": if thorough && !sarvam { "low" } else { "none" },
                });
                if sarvam {
                    body["max_tokens"] = json!(max_tokens);
                } else {
                    body["max_completion_tokens"] = json!(max_tokens.max(4000));
                }
                let (url, company) = if sarvam { (SARVAM, "Sarvam") } else { (OPENAI, "OpenAI") };
                let headers = openai::headers(if sarvam { "sarvam" } else { "openai" })?;
                let mut wrote = false;
                let first = lines(url, &headers, &body, company, &mut |new: &str| {
                    wrote = true;
                    piece(new);
                }, stop, openai_piece).await;
                match first {
                    // A model that won't take that reasoning setting: asked without it.
                    Err(AiError::Http { code: 400, detail, .. }) if !wrote && detail.to_lowercase().contains("reason") => {
                        body.as_object_mut().unwrap().remove("reasoning_effort");
                        lines(url, &headers, &body, company, piece, stop, openai_piece).await
                    }
                    other => other,
                }
            }
            Router::Ollama { model } => {
                let body = json!({
                    "model": model, "stream": true, "think": false, "keep_alive": "30m",
                    "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}],
                    "options": ollama::options(json!({"num_predict": max_tokens})),
                });
                lines(OLLAMA_CHAT, &[], &body, "Ollama", piece, stop, |json| json["message"]["content"].as_str().map(String::from)).await
            }
        }
    }
}

const ANTHROPIC: &str = "https://api.anthropic.com/v1/messages";
const OPENAI: &str = "https://api.openai.com/v1/chat/completions";
const SARVAM: &str = "https://api.sarvam.ai/v2/chat/completions";
const OLLAMA_CHAT: &str = "http://127.0.0.1:11434/api/chat";

fn anthropic_piece(json: &Value) -> Option<String> {
    (json["type"] == "content_block_delta" && json["delta"]["type"] == "text_delta")
        .then(|| json["delta"]["text"].as_str().map(String::from)).flatten()
}

fn openai_piece(json: &Value) -> Option<String> {
    json["choices"][0]["delta"]["content"].as_str().map(String::from)
}

/// Posts `body` and reads the reply line by line as it arrives (server-sent events, or one JSON object per line),
/// handing each line's JSON to `read`, which says what new text is in it.
async fn lines(url: &str, headers: &[(String, String)], body: &Value, provider: &'static str,
               piece: &mut (dyn FnMut(&str) + Send), stop: &(dyn Fn() -> bool + Sync),
               read: fn(&Value) -> Option<String>) -> Result<(), AiError> {
    let mut request = client().post(url).timeout(Duration::from_secs(180)).json(body);
    for (name, value) in headers {
        request = request.header(name.as_str(), value.as_str());
    }
    let mut response = request.send().await.map_err(|_| {
        if provider == "Ollama" { AiError::OllamaNotRunning } else { AiError::Unreachable(provider) }
    })?;
    let code = response.status().as_u16();
    if code != 200 {
        let text = response.text().await.unwrap_or_default();
        let json: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        let detail = json["error"]["message"].as_str().or_else(|| json["error"].as_str()).map(String::from)
            .unwrap_or_else(|| super::cut(&text, 300));
        return Err(AiError::Http { provider, code, detail });
    }
    let mut pending: Vec<u8> = Vec::new();
    loop {
        if stop() {
            return Ok(());
        }
        let chunk = response.chunk().await.map_err(|_| AiError::Unreachable(provider))?;
        let Some(chunk) = chunk else { break };
        pending.extend_from_slice(&chunk);
        while let Some(end) = pending.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = pending.drain(..=end).collect();
            handle(&String::from_utf8_lossy(&line), provider, code, piece, read)?;
        }
    }
    if !pending.is_empty() {
        handle(&String::from_utf8_lossy(&pending), provider, code, piece, read)?;
    }
    Ok(())
}

fn handle(line: &str, provider: &'static str, code: u16, piece: &mut (dyn FnMut(&str) + Send),
          read: fn(&Value) -> Option<String>) -> Result<(), AiError> {
    let mut payload = line.trim();
    if let Some(rest) = payload.strip_prefix("data:") {
        payload = rest.trim();
    }
    if payload.is_empty() || payload == "[DONE]" || payload.starts_with("event:") {
        return Ok(());
    }
    let Ok(json) = serde_json::from_str::<Value>(payload) else { return Ok(()) };
    if let Some(error) = json.get("error").filter(|e| !e.is_null()) {
        let detail = error["message"].as_str().map(String::from).unwrap_or_else(|| error.to_string());
        return Err(AiError::Http { provider, code, detail });
    }
    if let Some(text) = read(&json).filter(|t| !t.is_empty()) {
        piece(&text);
    }
    Ok(())
}

/// Standard base64, with padding.
pub fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pieces_from_each_provider() {
        let anthropic: Value = serde_json::from_str(r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#).unwrap();
        assert_eq!(anthropic_piece(&anthropic).as_deref(), Some("Hi"));
        let other: Value = serde_json::from_str(r#"{"type":"message_start"}"#).unwrap();
        assert_eq!(anthropic_piece(&other), None);
        let openai: Value = serde_json::from_str(r#"{"choices":[{"delta":{"content":" there"}}]}"#).unwrap();
        assert_eq!(openai_piece(&openai).as_deref(), Some(" there"));
    }

    #[test]
    fn lines_are_read_as_events() {
        let mut text = String::new();
        let mut add = |piece: &str| text.push_str(piece);
        for line in ["event: content_block_delta", "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"A\"}}",
                     "", "data: [DONE]"] {
            handle(line, "Anthropic", 200, &mut add, anthropic_piece).unwrap();
        }
        assert_eq!(text, "A");
        let error = handle(r#"data: {"error":{"message":"overloaded"}}"#, "Anthropic", 200, &mut |_| {}, anthropic_piece);
        assert!(matches!(error, Err(AiError::Http { detail, .. }) if detail == "overloaded"));
    }

    #[test]
    fn base64_matches_the_standard() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }
}
