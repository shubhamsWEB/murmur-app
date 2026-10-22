//! Checking an API key before relying on it (the Mac's KeyCheck): its shape first, then what a refusal means.

use super::Provider;

/// What looks wrong with a key's shape, or None.
pub fn shape_problem(provider: Provider, key: &str) -> Option<String> {
    let key = key.trim();
    let start: String = key.chars().take(6).collect();
    match provider {
        Provider::OpenAI if !key.starts_with("sk-") => Some(format!(
            "OpenAI keys start with “sk-” (project keys with “sk-proj-”). This one starts with “{start}…”, so part of it may be missing.")),
        Provider::Anthropic if !key.starts_with("sk-ant-") => Some(format!(
            "Anthropic keys start with “sk-ant-”. This one starts with “{start}…”, so part of it may be missing.")),
        _ if key.chars().count() < 20 => Some("That key looks too short.".into()),
        _ => None,
    }
}

/// What to do about a provider's refusal, in plain words, when it's one of the usual ones.
pub fn advice(provider: &str, code: u16, detail: &str) -> Option<String> {
    let lower = detail.to_lowercase();
    if provider == "OpenAI" && (lower.contains("missing scopes") || lower.contains("insufficient permissions")) {
        return Some(format!(
            "OpenAI rejected the API key ({code}): it's a restricted key that isn't allowed to make chat requests. At \
             platform.openai.com → API keys, edit the key and set Permissions to All (or Restricted with Model \
             capabilities → Write), then try again."));
    }
    if code == 404 || lower.contains("does not exist") || lower.contains("model_not_found")
        || (lower.contains("not_found_error") && lower.contains("model")) {
        return Some(format!(
            "{provider} can't use that model with this key ({code}). Choose another model in Settings → Commands & AI."));
    }
    if code == 429 && (lower.contains("quota") || lower.contains("billing") || lower.contains("credit")) {
        return Some(format!(
            "{provider} says the account has no API credit left ({code}). API use is billed separately from a ChatGPT \
             or Claude subscription: add credit in the {provider} console."));
    }
    None
}

/// Anthropic said this organization-wide key needs a workspace ID.
pub fn workspace_needed(message: &str) -> bool {
    let lower = message.to_lowercase();
    lower.contains("workspace-id") || lower.contains("not scoped to a workspace")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes() {
        assert!(shape_problem(Provider::OpenAI, "sk-proj-abcdefghijklmnopqrstuvwxyz").is_none());
        assert!(shape_problem(Provider::OpenAI, "proj-abcdefghijklmnopqrstuvwxyz").unwrap().contains("“proj-a…”"));
        assert!(shape_problem(Provider::Anthropic, "sk-ant-api03-abcdefghijklmnopqrstuvwxyz").is_none());
        assert!(shape_problem(Provider::Anthropic, "sk-abcdefghijklmnopqrstuvwxyz").is_some());
        assert_eq!(shape_problem(Provider::Anthropic, "sk-ant-x").as_deref(), Some("That key looks too short."));
    }

    #[test]
    fn advice_for_the_usual_refusals() {
        assert!(advice("OpenAI", 401, "You have insufficient permissions for this operation. Missing scopes: model.request").unwrap().contains("restricted key"));
        assert!(advice("Anthropic", 404, "not_found_error: model: claude-x").unwrap().contains("Choose another model"));
        assert!(advice("OpenAI", 429, "You exceeded your current quota").unwrap().contains("no API credit"));
        assert!(advice("OpenAI", 429, "Rate limit reached").is_none());
        assert!(workspace_needed("anthropic-workspace-id header is required"));
    }
}
