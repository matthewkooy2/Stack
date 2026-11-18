// The display catalog and disconnected checks are the deterministic output of
// agents/experience.jac::feature_status. Only account-specific facts vary here.
use rusqlite::{Connection, OptionalExtension, Result};
use serde_json::{Value, json};
use std::sync::LazyLock;

static FEATURES: LazyLock<Vec<Value>> =
    LazyLock::new(|| serde_json::from_str(include_str!("jobs_features.json")).unwrap());

fn configured(c: &mut Value, ok: bool) {
    c["ok"] = json!(ok);
    if ok {
        c["fix"] = json!("");
        c["action"] = json!("");
    }
}
pub(super) fn summary(db: &Connection, owner: &str) -> Result<Value> {
    let policy = crate::account::policy(db, owner)?;
    let deployment = crate::deployment::settings();
    let facts = crate::account::facts(db, owner)?;
    let enabled = policy["enabled"] == true;
    let expires = policy["expires_at"].as_f64().unwrap_or_default();
    let verified = facts.as_array().map(Vec::as_slice).unwrap_or_default();
    let resume_fact = verified
        .iter()
        .any(|f| f["verified"] == true && super::string(f, "key").starts_with("resume."));
    let any_fact = verified.iter().any(|f| f["verified"] == true);
    let (real,selected_contact,resumes):(bool,bool,i64)=db.query_row(
        "SELECT EXISTS(SELECT 1 FROM job_records WHERE owner=?1 AND kind='application' AND NOT json_extract(data,'$.demo')),
         EXISTS(SELECT 1 FROM career_records WHERE owner=?1 AND kind='contact' AND json_extract(data,'$.selected') AND NOT coalesce(json_extract(data,'$.stopped'),0)),
         (SELECT COUNT(*) FROM resumes WHERE owner=?1)",[owner],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
    let default:Option<(String,bool)>=db.query_row("SELECT name, (confirmed AND coalesce(json_array_length(review,'$.records'),0)>0) OR EXISTS(SELECT 1 FROM resume_sources WHERE resume=resumes.id) FROM resumes
        WHERE owner=?1 AND (id=(SELECT id FROM resume_selection WHERE owner=?1) OR ?2=1) LIMIT 1",
        rusqlite::params![owner,resumes],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    let google = crate::providers::connections(db, owner)?
        .into_iter()
        .find(|c| c["state"] == "connected");
    let google_client = std::env::var("GOOGLE_CLIENT_ID").is_ok_and(|v| !v.is_empty())
        && std::env::var("GOOGLE_REDIRECT_URI").is_ok_and(|v| v.starts_with("https://"));
    let mut features = FEATURES.clone();
    for f in &mut features {
        let feature = super::string(f, "key").to_owned();
        let checks = f["checks"].as_array_mut().unwrap();
        for c in &mut *checks {
            let ok = match super::string(c, "key") {
                k if google_client && k.starts_with("google:") => {
                    let scope = k[7..].to_owned();
                    let url = match scope.as_str() {
                        "send" => "https://www.googleapis.com/auth/gmail.send",
                        "read" => "https://www.googleapis.com/auth/gmail.readonly",
                        "calendar" => "https://www.googleapis.com/auth/calendar.app.created",
                        _ => continue,
                    };
                    c["user_fixable"] = json!(true);
                    c["action"] = json!(format!("connect:{scope}"));
                    c["fix"] = json!(if scope == "read" {
                        "Connect Gmail to track application updates automatically."
                    } else {
                        "Connect Google in Email & calendar."
                    });
                    google.as_ref().is_some_and(|g| {
                        g["scopes"]
                            .as_array()
                            .is_some_and(|v| v.contains(&json!(url)))
                            && (feature != "email" || g["tracking"] == true)
                    })
                }
                "sandbox" => {
                    std::env::var("STACK_SANDBOX_URL").is_ok_and(|v| !v.is_empty())
                        || deployment["sandbox_available"] == true
                }
                "model" if feature != "linkedin" => {
                    c["fix"] = deployment["model_provider"]["message"].clone();
                    deployment["model_provider"]["configured"] == true
                }
                "web" => deployment["web_url"]
                    .as_str()
                    .is_some_and(|url| !url.is_empty()),
                "voice" => {
                    c["fix"] = deployment["voice_error"].clone();
                    deployment["voice_error"] == ""
                }
                key if key.starts_with("operator:") => {
                    deployment["action_daily_limits"][&key[9..]]
                        .as_i64()
                        .unwrap_or(0)
                        > 0
                }
                "applications" => real,
                "browser" => crate::browser::configured(),
                "contacts" => selected_contact,
                "resume" => resumes > 0,
                "rules" => enabled && expires > super::now(),
                "domains" => policy["domains"].as_array().is_some_and(|s| !s.is_empty()),
                "facts" if feature == "tailoring" => {
                    if let Some((name, _)) = &default {
                        c["fix"] = json!(format!(
                            "Review and confirm imported records for {name}, or upload its LaTeX on the Resume tab."
                        ));
                    }
                    default.as_ref().is_some_and(|(_, ready)| *ready)
                }
                "facts" if feature == "fit" => resume_fact,
                "facts" => any_fact,
                perm if perm.starts_with("perm:") => {
                    let action = &perm[5..];
                    let permitted = policy["actions"]
                        .as_array()
                        .is_some_and(|a| a.iter().any(|v| v == action));
                    permitted
                        && policy["daily_limits"][action]
                            .as_i64()
                            .is_some_and(|x| x > 0)
                }
                _ => continue,
            };
            configured(c, ok);
        }
        let missing = checks
            .iter()
            .filter(|c| c["ok"] != true && c["optional"] != true)
            .collect::<Vec<_>>();
        let state = if missing.is_empty() {
            "ready"
        } else if missing.iter().any(|c| c["user_fixable"] != true) {
            "unavailable"
        } else {
            "setup"
        };
        let limited = state == "ready"
            && checks
                .iter()
                .any(|c| c["optional"] == true && c["ok"] != true);
        let total = checks.len();
        let ready = total - missing.len();
        f["total"] = json!(total);
        f["ready_count"] = json!(ready);
        f["state"] = json!(state);
        f["limited"] = json!(limited);
    }
    let mut summary = crate::runs::summary(db, owner)?;
    summary["enabled"] = json!(enabled);
    summary["admitted"] = json!(true);
    summary["expires_at"] = policy.get("expires_at").cloned().unwrap_or(json!(0));
    summary["features"] = json!(features);
    summary["model_provider"] = deployment["model_provider"].clone();
    Ok(summary)
}
