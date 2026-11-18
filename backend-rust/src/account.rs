use crate::{career, jobs, now, recording, resumes};
use regex::Regex;
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashSet};
use std::sync::LazyLock;

static FACT_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[a-zA-Z0-9_.:-]{1,100}$").unwrap());
static EMAIL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[^\s@]+@[^\s@]+\.[^\s@]+$").unwrap());
static DOMAIN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$").unwrap());

pub fn init(db: &Connection) -> Result<()> {
    crate::providers::init(db)?;
    crate::runs::init(db)?;
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS account_preferences(
        owner TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
        policy TEXT NOT NULL, facts TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0);
         CREATE TABLE IF NOT EXISTS model_selection(owner TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE, selection TEXT NOT NULL);",
    )
}
fn defaults() -> Value {
    json!({"enabled":false,"actions":[],"domains":[],"daily_limits":{},"expires_at":0,"followup_limit":0,"followup_days":7,"analyze_top_matches":false})
}
pub fn selection(db: &Connection, owner: &str) -> Result<String> {
    Ok(db
        .query_row(
            "SELECT selection FROM model_selection WHERE owner=?",
            [owner],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or_default())
}
pub fn grants(db: &Connection, owner: &str) -> Result<Vec<(String, String)>> {
    let mut q=db.prepare_cached("SELECT client,sealed FROM apple_grants WHERE owner=?1 UNION ALL SELECT generation,sealed FROM google_connections WHERE owner=?1 ORDER BY 1,2")?;
    q.query_map([owner], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect()
}
pub fn policy(db: &Connection, owner: &str) -> Result<Value> {
    Ok(db
        .query_row(
            "SELECT policy FROM account_preferences WHERE owner=?",
            [owner],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or_else(defaults))
}
pub fn facts(db: &Connection, owner: &str) -> Result<Value> {
    Ok(db
        .query_row(
            "SELECT facts FROM account_preferences WHERE owner=?",
            [owner],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(json!([])))
}
fn validate_policy(v: &Value) -> std::result::Result<Value, &'static str> {
    let mut p = defaults();
    for (k, val) in p.as_object_mut().unwrap() {
        if let Some(value) = v.get(k) {
            *val = value.clone();
        }
    }
    let valid = |a: &str| matches!(a, "send_email" | "calendar_write" | "gmail_read" | "model");
    let actions = p["actions"]
        .as_array()
        .ok_or("Choose valid agent permissions.")?;
    if !p["enabled"].is_boolean() || !actions.iter().all(|a| a.as_str().is_some_and(valid)) {
        return Err("Choose valid agent permissions.");
    }
    p["actions"] = json!(
        actions
            .iter()
            .filter(|a| a.as_str() != Some("model"))
            .collect::<Vec<_>>()
    );
    if !p["analyze_top_matches"].is_boolean() {
        return Err("Choose whether to analyze top matches.");
    }
    let domains = p["domains"]
        .as_array()
        .filter(|d| d.len() <= 100)
        .ok_or("Use at most 100 destination domains.")?;
    let normalized: BTreeSet<_> = domains
        .iter()
        .map(|v| v.as_str().unwrap_or("").trim().to_lowercase())
        .collect();
    if !normalized.iter().all(|d| DOMAIN.is_match(d)) {
        return Err("Use exact domain names, without wildcards or URLs.");
    }
    p["domains"] = json!(normalized);
    let limits = p["daily_limits"]
        .as_object_mut()
        .ok_or("Daily limits must be between 1 and 100.")?;
    if !limits
        .iter()
        .all(|(a, n)| valid(a) && n.as_i64().is_some_and(|n| (1..=100).contains(&n)))
    {
        return Err("Daily limits must be between 1 and 100.");
    }
    limits.remove("model");
    let expires = p["expires_at"]
        .as_f64()
        .ok_or("Choose a valid permission expiration.")?;
    if p["enabled"] == true && (expires <= now() || expires > now() + 366.0 * 86400.0) {
        return Err("Permissions must expire within one year.");
    }
    if !p["followup_limit"]
        .as_i64()
        .is_some_and(|n| (0..=3).contains(&n))
    {
        return Err("Choose zero to three follow-ups.");
    }
    if !p["followup_days"]
        .as_i64()
        .is_some_and(|n| (3..=30).contains(&n))
    {
        return Err("Space follow-ups between 3 and 30 days apart.");
    }
    Ok(p)
}
fn validate_facts(values: &Value) -> std::result::Result<Vec<Value>, &'static str> {
    let input = values
        .as_array()
        .filter(|x| x.len() <= 250)
        .ok_or("Save at most 250 facts at a time.")?;
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for fact in input {
        let key = fact["key"].as_str().unwrap_or("").trim();
        let value = fact["value"].as_str().unwrap_or("").trim();
        if !FACT_KEY.is_match(key) || value.is_empty() || value.chars().count() > 8000 {
            return Err("Each fact needs a key and a value under 8,000 characters.");
        }
        if key == "email" && !EMAIL.is_match(value) {
            return Err("Enter a valid email address.");
        }
        if !seen.insert(key) {
            return Err("Fact keys must be unique.");
        }
        out.push(json!({"key":key,"value":value,"verified":fact["verified"]==true,
            "source":fact["source"].as_str().unwrap_or("User confirmed").chars().take(500).collect::<String>(),
            "resume_id":fact["resume_id"].as_str().unwrap_or("").chars().take(100).collect::<String>(),"updated_at":now()}));
    }
    Ok(out)
}
fn save(db: &Connection, owner: &str, policy: &Value, facts: &Value) -> Result<()> {
    db.execute(
        "INSERT INTO account_preferences VALUES (?,?,?,1) ON CONFLICT(owner)
        DO UPDATE SET policy=excluded.policy,facts=excluded.facts,revision=revision+1",
        params![owner, policy, facts],
    )?;
    Ok(())
}
pub fn resume_facts(db: &Connection, owner: &str, id: &str, new: &Value) -> Result<Option<Value>> {
    let mut previous = facts(db, owner)?;
    let list = previous
        .as_array_mut()
        .ok_or(rusqlite::Error::InvalidQuery)?;
    let before = list.len();
    list.retain(|f| {
        !(f["resume_id"] == id && f["key"].as_str().is_some_and(|k| k.starts_with("resume.")))
    });
    let new = match validate_facts(new) {
        Ok(v) => v,
        Err(e) => return Ok(Some(json!({"error":e}))),
    };
    if list.len() != before || !new.is_empty() {
        list.extend(new);
        save(db, owner, &policy(db, owner)?, &previous)?;
    }
    Ok(None)
}
fn summary(db: &Connection, owner: &str) -> Result<Value> {
    let mut summary = jobs::agent_summary(db, owner)?;
    summary.as_object_mut().unwrap().remove("features");
    Ok(summary)
}
fn settings(db: &Connection, owner: &str) -> Result<Value> {
    let activity = summary(db, owner)?;
    let mut model = activity["model_provider"].clone();
    if !model.is_object() {
        model = json!({"provider":"local","model":"","configured":false,"billing":"local","message":"Model execution is unavailable on this development backend."})
    }
    model["selection"] = json!("local");
    let revision: i64 = db
        .query_row(
            "SELECT revision FROM account_preferences WHERE owner=?",
            [owner],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(0);
    Ok(
        json!({"account_id":owner,"active_model_tasks":active_model(db,owner)?.len(),"model_selection":"local","model_options":[model],"facts":facts(db,owner)?,
        "policy":policy(db,owner)?,"revision":revision,"connections":crate::providers::connections(db,owner)?,"web_url":crate::deployment::settings()["web_url"],"activity":activity}),
    )
}
fn active_model(db: &Connection, owner: &str) -> Result<Vec<(String, Value)>> {
    let mut q=db.prepare_cached("SELECT id,data FROM agent_runs WHERE owner=? AND json_extract(data,'$.status') IN ('queued','running','waiting')
        AND (json_extract(data,'$.kind') IN ('live','linkedin') OR json_extract(data,'$.context.manual_scan') OR EXISTS
        (SELECT 1 FROM json_each(data,'$.steps') WHERE key>=json_extract(data,'$.index') AND value IN ('linkedin_review','fit','tailor','draft','coach','profile','story','interview_turn','interview_coach')))")?;
    q.query_map([owner], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect()
}
fn event_rows(db: &Connection, owner: &str, kind: &str, visible: bool) -> Result<Vec<Value>> {
    let mut query=db.prepare_cached("SELECT id,data FROM career_records WHERE owner=?1 AND kind=?2
        AND (NOT ?3 OR NOT coalesce(json_extract(data,'$.dismissed'),0)) ORDER BY updated DESC,rowid DESC
        LIMIT CASE WHEN ?3 AND ?2='mail_event' THEN 100 ELSE -1 END")?;
    query
        .query_map(params![owner, kind, visible], |r| {
            let mut data: Value = r.get(1)?;
            if visible {
                data["id"] = Value::String(r.get(0)?);
            }
            Ok(data)
        })?
        .collect()
}

fn export(db: &Connection, owner: &str, full: bool) -> Result<Value> {
    let mut career = career::export(db, owner)?;
    let mut agents = crate::runs::export(db, owner)?;
    agents["settings"] = settings(db, owner)?;
    agents["contacts"] = career["contacts"].take();
    agents["sessions"] = career["sessions"].take();
    agents["events"] = json!(event_rows(db, owner, "mail_event", false)?);
    if !full {
        return Ok(agents);
    }
    let mut account = jobs::bootstrap(db, owner)?;
    career::enrich_bootstrap(db, owner, &mut account)?;
    resumes::enrich_bootstrap(db, owner, &mut account)?;
    let mut files = Vec::new();
    for item in account["resumes"].as_array().unwrap() {
        let mut file = resumes::dispatch(db, owner, "read_resume", &json!({"id":item["id"]}))?
            .ok_or(rusqlite::Error::InvalidQuery)?;
        file["id"] = item["id"].clone();
        file["format"] = item["format"].clone();
        if let Some(source) = resumes::source_export(db, owner, item["id"].as_str().unwrap())? {
            file["source"] = source;
        }
        files.push(file);
    }
    if let Some(bank) = career["bank"].as_array_mut() {
        files.append(bank)
    }
    let mut stories = event_rows(db, owner, "story", false)?;
    for story in &mut stories {
        if let Some(fields) = story.as_object_mut() {
            fields.remove("created_at");
        }
    }
    Ok(
        json!({"account":account,"agents":agents,"stories":stories,"recordings":recording::list(db,owner)?,"resumes":files,"tailored_resumes":resumes::tailored_export(db,owner)?}),
    )
}
pub fn handles(m: &str) -> bool {
    matches!(
        m,
        "agent_events"
            | "agent_settings"
            | "agent_save_model"
            | "agent_activity"
            | "agent_save_facts"
            | "agent_save_policy"
            | "agent_export"
            | "account_export"
    )
}
pub fn dispatch(db: &Connection, owner: &str, m: &str, a: &Value) -> Result<Option<Value>> {
    let value = match m {
        "agent_events" => {
            json!({"events":event_rows(db,owner,"mail_event",true)?,"interviews":event_rows(db,owner,"calendar_interview",true)?})
        }
        "agent_settings" => settings(db, owner)?,
        "agent_save_model" => match a["selection"].as_str() {
            Some("local") => {
                if selection(db, owner)? != "local" {
                    let active = active_model(db, owner)?;
                    if !active.is_empty() && a["stop_tasks"] != true {
                        return Ok(Some(
                            json!({"error":"Wait for your AI tasks to finish or stop them before changing models."}),
                        ));
                    }
                    if active.iter().any(|(_, r)| r["kind"] == "linkedin") {
                        return Ok(Some(
                            json!({"error":"Stop the LinkedIn browser task in Tasks before changing models."}),
                        ));
                    }
                    for (id, mut run) in active {
                        run["status"] = json!("cancelled");
                        run["message"] = json!("Stopped to change models.");
                        run["stopped_for_model_switch"] = json!(true);
                        run["lease"] = json!("");
                        run["lease_until"] = json!(0);
                        crate::runs::save(db, owner, &id, &mut run)?;
                    }
                }
                db.execute("INSERT INTO model_selection VALUES (?,'local') ON CONFLICT(owner) DO UPDATE SET selection='local' WHERE selection!='local'",[owner])?;
                settings(db, owner)?
            }
            _ if crate::deployment::settings()["first_party_only"] == true => {
                json!({"error":"This deployment uses only Stack-hosted AI."})
            }
            _ => json!({"error":"Choose a model configured for this deployment."}),
        },
        "agent_activity" => summary(db, owner)?,
        "agent_save_facts" => {
            let validated = match validate_facts(&a["facts"]) {
                Ok(v) => v,
                Err(e) => return Ok(Some(json!({"error":e}))),
            };
            let keys: HashSet<_> = validated
                .iter()
                .map(|f| f["key"].as_str().unwrap())
                .collect();
            let mut current = facts(db, owner)?;
            let list = current
                .as_array_mut()
                .ok_or(rusqlite::Error::InvalidQuery)?;
            list.retain(|f| !keys.contains(f["key"].as_str().unwrap_or("")));
            list.extend(validated);
            save(db, owner, &policy(db, owner)?, &current)?;
            settings(db, owner)?
        }
        "agent_save_policy" => {
            let p = match validate_policy(&a["policy"]) {
                Ok(v) => v,
                Err(e) => return Ok(Some(json!({"error":e}))),
            };
            save(db, owner, &p, &facts(db, owner)?)?;
            settings(db, owner)?
        }
        "account_export" | "agent_export" => export(db, owner, m == "account_export")?,
        _ => return Ok(None),
    };
    Ok(Some(value))
}
