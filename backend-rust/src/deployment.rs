use serde_json::{Value, json};
use std::sync::OnceLock;

static PUBLIC: OnceLock<Value> = OnceLock::new();

pub fn init() -> Result<(), Box<dyn std::error::Error>> {
    if let Some(path) = std::env::var_os("STACK_PUBLIC_SETTINGS") {
        let settings: Value = serde_json::from_slice(&std::fs::read(path)?)?;
        if !settings["web_url"].is_string()
            || !settings["model_provider"]["configured"].is_boolean()
            || !settings["voice_error"].is_string()
            || !settings["first_party_only"].is_boolean()
        {
            return Err("Invalid public deployment settings".into());
        }
        PUBLIC
            .set(settings)
            .map_err(|_| "Deployment settings already initialized")?;
    }
    Ok(())
}

pub fn settings() -> &'static Value {
    PUBLIC.get_or_init(|| json!({
        "web_url":std::env::var("STACK_WEB_URL").unwrap_or_default(),
        "first_party_only":true, "linkedin_browser":false,
        "model_provider":{"provider":"local","model":"","configured":false,"billing":"local","message":"Model execution is unavailable on this server."},
        "voice_error":"Live voice is unavailable on this deployment.",
        "action_daily_limits":{}
    }))
}
