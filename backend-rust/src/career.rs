use regex::Regex;
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashSet};
use std::sync::LazyLock;
use std::time::{SystemTime, UNIX_EPOCH};

mod bank;
pub(crate) use bank::validate_records;
mod interview;
pub(crate) use interview::queue as queue_interview;
mod library;
mod prep;
pub(crate) use prep::{coach, problem};

static LIBRARY: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../../agents/data/practice_questions.json")).unwrap()
});
static CATALOG: LazyLock<Vec<Value>> =
    LazyLock::new(|| serde_json::from_str(include_str!("career/prep_catalog.json")).unwrap());

pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS career_records(
        owner TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL,
        updated REAL NOT NULL, PRIMARY KEY(owner,kind,id)
    );
    CREATE TABLE IF NOT EXISTS career_files(owner TEXT NOT NULL,id TEXT NOT NULL,content BLOB NOT NULL,PRIMARY KEY(owner,id));
    CREATE TRIGGER IF NOT EXISTS career_file_cleanup AFTER DELETE ON career_records WHEN old.kind='bank' BEGIN
        DELETE FROM career_files WHERE owner=old.owner AND id=old.id;
    END;
    CREATE INDEX IF NOT EXISTS career_by_time ON career_records(owner,kind,updated DESC);
    CREATE UNIQUE INDEX IF NOT EXISTS career_replay ON career_records(owner,kind,json_extract(data,'$.data.client_id')) WHERE kind IN ('interview','practice_attempt');
    CREATE INDEX IF NOT EXISTS career_question ON career_records(owner,json_extract(data,'$.data.problem_id')) WHERE kind='practice_attempt';",
    )
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn id(db: &Connection) -> Result<String> {
    db.query_row("SELECT lower(hex(randomblob(16)))", [], |row| row.get(0))
}
fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}
fn err(message: impl AsRef<str>) -> Value {
    json!({"error":message.as_ref()})
}
fn decode(row: &rusqlite::Row<'_>) -> Result<Value> {
    let data: String = row.get(0)?;
    serde_json::from_str(&data).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
    })
}
fn get(db: &Connection, owner: &str, kind: &str, id: &str) -> Result<Option<Value>> {
    db.query_row(
        "SELECT data FROM career_records WHERE owner=? AND kind=? AND id=?",
        params![owner, kind, id],
        decode,
    )
    .optional()
}
fn put(db: &Connection, owner: &str, kind: &str, id: &str, data: &Value) -> Result<()> {
    db.execute("INSERT INTO career_records(owner,kind,id,data,updated) VALUES(?,?,?,?,?) ON CONFLICT(owner,kind,id) DO UPDATE SET data=excluded.data,updated=excluded.updated",params![owner,kind,id,data.to_string(),now()])?;
    Ok(())
}
fn list(db: &Connection, owner: &str, kind: &str) -> Result<Vec<Value>> {
    let mut q = db.prepare_cached(
        "SELECT data FROM career_records WHERE owner=? AND kind=? ORDER BY rowid",
    )?;
    let rows = q.query_map(params![owner, kind], decode)?;
    rows.collect()
}
fn remove(db: &Connection, owner: &str, kind: &str, id: &str) -> Result<()> {
    db.execute(
        "DELETE FROM career_records WHERE owner=? AND kind=? AND id=?",
        params![owner, kind, id],
    )?;
    Ok(())
}
fn industry(db: &Connection, owner: &str) -> Result<Value> {
    Ok(get(db, owner, "settings", "industry")?.unwrap_or(json!("")))
}
pub fn delete_owner(db: &Connection, owner: &str) -> Result<()> {
    db.execute("DELETE FROM career_records WHERE owner=?", [owner])?;
    Ok(())
}
pub fn export(db: &Connection, owner: &str) -> Result<Value> {
    let mut q=db.prepare_cached("SELECT data FROM career_records WHERE owner=? AND kind IN ('prep','interview','practice_attempt') ORDER BY rowid")?;
    let sessions = q
        .query_map([owner], |r| {
            let mut p = decode(r)?;
            p.as_object_mut().unwrap().retain(|k, _| {
                matches!(
                    k.as_str(),
                    "id" | "data" | "revision" | "results" | "feedback" | "recordings"
                )
            });
            Ok(p)
        })?
        .collect::<Result<Vec<_>>>()?;
    Ok(json!({"contacts":contacts(db,owner)?,"sessions":sessions,"bank":bank::export(db,owner)?}))
}
pub fn enrich_bootstrap(db: &Connection, owner: &str, b: &mut Value) -> Result<()> {
    b["profile"]["industry"] = industry(db, owner)?;
    Ok(())
}

pub fn handles(method: &str) -> bool {
    matches!(
        method,
        "agent_contacts" | "agent_save_contact" | "agent_stop_contact" | "agent_import_contacts"
    ) || bank::handles(method)
        || prep::handles(method)
        || interview::handles(method)
}
pub fn dispatch(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Option<Value>> {
    if interview::handles(method) {
        return interview::dispatch(db, owner, method, a).map(Some);
    }
    if bank::handles(method) {
        return bank::dispatch(db, owner, method, a).map(Some);
    }
    if prep::handles(method) {
        return prep::dispatch(db, owner, method, a).map(Some);
    }
    let res = match method {
        "agent_contacts" => contacts(db, owner)?,
        "agent_stop_contact" => {
            let key = s(a, "id");
            let Some(mut contact) = get(db, owner, "contact", key)? else {
                return Ok(Some(err("Contact not found.")));
            };
            contact["stopped"] = json!(true);
            contact["next_at"] = json!(0);
            put(db, owner, "contact", key, &contact)?;
            contacts(db, owner)?
        }
        "agent_save_contact" => {
            let mut data = match validate_contact(&a["data"]) {
                Ok(v) => v,
                Err(e) => return Ok(Some(err(e))),
            };
            let supplied = s(a, "id");
            let key = if supplied.is_empty() {
                id(db)?
            } else {
                let Some(previous) = get(db, owner, "contact", supplied)? else {
                    return Ok(Some(err("Contact not found.")));
                };
                for field in ["stopped", "next_at", "followups"] {
                    data[field] = previous[field].clone()
                }
                data["id"] = json!(supplied);
                if data == previous {
                    return contacts(db, owner).map(Some);
                }
                supplied.to_string()
            };
            data["id"] = json!(&key);
            put(db, owner, "contact", &key, &data)?;
            contacts(db, owner)?
        }
        "agent_import_contacts" => {
            let records = match parse_contacts(s(a, "content")) {
                Ok(r) => r,
                Err(e) => return Ok(Some(err(e))),
            };
            let mut known: HashSet<String> = list(db, owner, "contact")?
                .iter()
                .map(|c| s(c, "email").to_owned())
                .collect();
            for mut record in records {
                let email = s(&record, "email");
                if !email.is_empty() && !known.insert(email.to_owned()) {
                    continue;
                }
                let key = id(db)?;
                record["id"] = json!(&key);
                put(db, owner, "contact", &key, &record)?;
            }
            contacts(db, owner)?
        }
        _ => return Ok(None),
    };
    Ok(Some(res))
}
fn contacts(db: &Connection, owner: &str) -> Result<Value> {
    Ok(json!({"contacts":list(db,owner,"contact")?}))
}

static EMAIL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$").unwrap());
static EMAILS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b").unwrap()
});

fn validate_contact(data: &Value) -> std::result::Result<Value, String> {
    let name = s(data, "name").trim();
    let email = s(data, "email").trim().to_lowercase();
    if name.is_empty()
        || name.chars().count() > 120
        || (!email.is_empty() && !EMAIL.is_match(&email))
    {
        return Err("Enter a name and a valid, verified email address.".into());
    }
    let mut contact = json!({"name":name,"email":email,"stopped":false,"selected":data["selected"]==true,"followups":0,"next_at":0.0});
    for (field, limit) in [
        ("company", 160),
        ("role", 160),
        ("source_url", 2000),
        ("source", 2000),
        ("relationship", 2000),
    ] {
        contact[field] = json!(s(data, field).chars().take(limit).collect::<String>());
    }
    let url = s(&contact, "source_url");
    if !url.is_empty()
        && !url
            .get(..6)
            .is_some_and(|scheme| scheme.eq_ignore_ascii_case("https:"))
    {
        return Err("Use an HTTPS research source.".into());
    }
    Ok(contact)
}
fn parse_contacts(content: &str) -> std::result::Result<Vec<Value>, String> {
    if content.chars().count() > 200000 {
        return Err("Import at most 200 KB at a time.".into());
    }
    let mut reader = csv::ReaderBuilder::new()
        .flexible(true)
        .from_reader(content.as_bytes());
    let csv_error = |_: csv::Error| "Invalid contact CSV.".to_owned();
    let headers: Vec<_> = reader
        .headers()
        .map_err(csv_error)?
        .iter()
        .map(|h| h.trim().to_lowercase())
        .collect();
    if !headers.iter().any(|h| h == "email") {
        let emails: BTreeSet<_> = EMAILS.find_iter(content).map(|m| m.as_str()).collect();
        if emails.len() > 200 {
            return Err("Import at most 200 contacts.".into());
        }
        let source: String = content.chars().take(2000).collect();
        return emails
            .into_iter()
            .map(|e| validate_contact(&json!({"name":e,"email":e,"source":source})))
            .collect();
    }
    let mut values = Vec::new();
    for record in reader.records() {
        if values.len() >= 200 {
            return Err("Import at most 200 contacts at a time.".into());
        }
        let record = record.map_err(csv_error)?;
        let mut data = json!({});
        for (key, value) in headers.iter().zip(record.iter()) {
            data[key] = json!(value);
        }
        if s(&data, "source").is_empty() {
            data["source"] = json!("User supplied CSV")
        }
        data["selected"] = json!(false);
        values.push(validate_contact(&data)?);
    }
    Ok(values)
}

#[cfg(test)]
mod tests;
