use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use std::sync::LazyLock;
use std::time::{SystemTime, UNIX_EPOCH};

#[path = "jobs_catalog.rs"]
mod catalog;
pub(crate) use catalog::{ranked, ranked_request};
#[path = "jobs_features.rs"]
mod features;

static DEMO: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("jobs_demo.json")).expect("valid demo fixtures")
});

pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS job_records (
        owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        kind TEXT NOT NULL, key TEXT NOT NULL, data TEXT NOT NULL CHECK(json_valid(data)),
        PRIMARY KEY(owner,kind,key));
        CREATE UNIQUE INDEX IF NOT EXISTS applications_once ON job_records(owner,json_extract(data,'$.job_id')) WHERE kind='application';")?;
    catalog::init(db)
}

pub fn delete_owner(db: &Connection, owner: &str) -> Result<()> {
    db.execute("DELETE FROM job_records WHERE owner=?1", [owner])?;
    catalog::delete_owner(db, owner)
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn string<'a>(a: &'a Value, k: &str) -> &'a str {
    a[k].as_str().unwrap_or_default()
}
fn error(message: &str) -> Value {
    json!({"error":message})
}
fn decode(raw: String) -> Result<Value> {
    serde_json::from_str(&raw).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
    })
}
fn get(db: &Connection, owner: &str, kind: &str, key: &str) -> Result<Option<Value>> {
    db.query_row(
        "SELECT data FROM job_records WHERE owner=? AND kind=? AND key=?",
        params![owner, kind, key],
        |row| row.get(0),
    )
    .optional()?
    .map(decode)
    .transpose()
}
fn list(db: &Connection, owner: &str, kind: &str) -> Result<Vec<Value>> {
    let mut stmt =
        db.prepare_cached("SELECT data FROM job_records WHERE owner=? AND kind=? ORDER BY rowid")?;
    let mut rows = stmt.query(params![owner, kind])?;
    let mut result = Vec::new();
    while let Some(row) = rows.next()? {
        result.push(decode(row.get(0)?)?);
    }
    Ok(result)
}
fn put(db: &Connection, owner: &str, kind: &str, key: &str, data: &Value) -> Result<()> {
    db.execute("INSERT INTO job_records(owner,kind,key,data) VALUES(?,?,?,?) ON CONFLICT(owner,kind,key) DO UPDATE SET data=excluded.data",
        params![owner,kind,key,data.to_string()])?;
    Ok(())
}
fn uuid(db: &Connection) -> Result<String> {
    db.query_row("SELECT lower(hex(randomblob(16)))", [], |r| r.get(0))
}
fn default_profile() -> Value {
    json!({"name":"","role":"","linkedin_url":"","linkedin_target_role":"","location":"United States","mode":"Any","industry":"","onboarded":false,"notifications":true,
        "graduation_month":"","available_from":"","preferences":{"roles":"","location":"","modes":[],"stage":"","years":null,"education":"","employment_types":[],
        "salary_min":0.0,"salary_period":"year","exclude_companies":[],"exclude_terms":[],"soft":[],"graduation_month":"","available_from":""}})
}
pub(crate) fn profile(db: &Connection, owner: &str) -> Result<Value> {
    Ok(get(db, owner, "profile", "profile")?.unwrap_or_else(default_profile))
}
fn contacts(db: &Connection, owner: &str) -> Result<Vec<Value>> {
    use sha2::{Digest, Sha256};
    let mut stored = list(db, owner, "contact")?;
    let mut contacts = Vec::with_capacity(DEMO["people"].as_array().unwrap().len());
    for person in DEMO["people"].as_array().unwrap() {
        if let Some(index) = stored.iter().position(|c| c["person_id"] == person["id"]) {
            contacts.push(stored.swap_remove(index));
        } else {
            let key = format!("contact/{}/{}", owner, string(person, "id"));
            let id = format!("{:x}", Sha256::digest(key.as_bytes()));
            contacts.push(json!({"id":&id[..32],"person_id":person["id"],"saved":false,"draft":person["draft"],"notes":""}));
        }
    }
    Ok(contacts)
}
fn contact(db: &Connection, owner: &str, id: &str) -> Result<Option<Value>> {
    Ok(contacts(db, owner)?.into_iter().find(|c| c["id"] == id))
}
pub fn agent_summary(db: &Connection, owner: &str) -> Result<Value> {
    features::summary(db, owner)
}
pub fn bootstrap(db: &Connection, owner: &str) -> Result<Value> {
    let mut applications = list(db, owner, "application")?;
    catalog::application_views(db, owner, &mut applications)?;
    let mut jobs = Vec::with_capacity(applications.len());
    for app in &mut applications {
        if app["demo"] == true {
            let age = now() - app["created_at"].as_f64().unwrap_or_default();
            app["status"] = json!(if age < 3.0 {
                "Queued"
            } else if age < 8.0 {
                "Preparing"
            } else {
                "Submitted"
            });
        }
        jobs.push(app["job"].clone());
    }
    Ok(
        json!({"user_id":owner,"profile":profile(db,owner)?,"jobs":jobs,
        "saved_search":get(db,owner,"search","saved")?.unwrap_or(json!({})),"decisions":list(db,owner,"decision")?,
        "applications":applications,"people":DEMO["people"],"contacts":contacts(db,owner)?,
        "resumes":[],"selected_resume":"","tailored_resumes":[],
        "agents":features::summary(db,owner)?,
        "reminders":list(db,owner,"reminder")?}),
    )
}

pub fn application_job(db: &Connection, owner: &str, id: &str) -> Result<Option<Value>> {
    let Some(mut app) = get(db, owner, "application", id)?.filter(|a| a["demo"] == false) else {
        return Ok(None);
    };
    catalog::application_views(db, owner, std::slice::from_mut(&mut app))?;
    Ok(Some(app["job"].take()))
}
fn valid_month(m: &str) -> bool {
    m.is_empty()
        || (m.len() == 7
            && m.is_ascii()
            && m.starts_with("20")
            && m[2..4].bytes().all(|b| b.is_ascii_digit())
            && &m[4..5] == "-"
            && m[5..].bytes().all(|b| b.is_ascii_digit())
            && matches!(m[5..].parse::<u8>(), Ok(1..=12)))
}
fn update_profile(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Value> {
    let mut p = profile(db, owner)?;
    let old = p["preferences"].clone();
    if method == "save_profile" {
        for (key, max, msg) in [
            ("name", 100, "Keep your name to 100 characters or fewer."),
            (
                "role",
                160,
                "Keep your target roles to 160 characters or fewer.",
            ),
            (
                "location",
                160,
                "Keep your location to 160 characters or fewer.",
            ),
        ] {
            let Some(s) = a[key].as_str() else {
                return Ok(error("Missing or invalid profile field."));
            };
            if s.chars().count() > max {
                return Ok(error(msg));
            }
            if key != "name" || !s.trim().is_empty() {
                p[key] = json!(s.trim());
            }
        }
        let Some(mode) = a["mode"].as_str() else {
            return Ok(error(
                "Choose Any, Remote, Hybrid or On-site for work arrangement.",
            ));
        };
        let mode = if mode.trim().is_empty() { "Any" } else { mode };
        if !matches!(mode, "Any" | "Remote" | "Hybrid" | "On-site") {
            return Ok(error(
                "Choose Any, Remote, Hybrid or On-site for work arrangement.",
            ));
        }
        let Some(n) = a["notifications"].as_bool() else {
            return Ok(error("Invalid notification setting."));
        };
        let clean = catalog::preferences(&old, &a["preferences"], mode)?;
        if clean.get("error").is_some() {
            return Ok(clean);
        }
        let prefs = &mut p["preferences"];
        for (k, v) in clean.as_object().expect("validated preferences") {
            prefs[k] = v.clone();
        }
        let modes = prefs["modes"].as_array().unwrap();
        p["mode"] = if modes.len() == 1 {
            modes[0].clone()
        } else {
            json!("Any")
        };
        p["preferences"]["roles"] = p["role"].clone();
        p["preferences"]["location"] = p["location"].clone();
        p["onboarded"] = json!(true);
        p["notifications"] = json!(n);
    }
    for k in ["graduation_month", "available_from"] {
        let value = match a.get(k) {
            Some(Value::String(s)) if s != "None" => s.as_str(),
            None if method == "save_timeline" && k == "available_from" => "",
            Some(Value::Null) | None if method == "save_profile" => string(&p, k),
            Some(Value::String(_)) if method == "save_profile" => string(&p, k),
            _ => {
                return Ok(error(
                    "Use YYYY-MM for graduation and availability, or leave blank.",
                ));
            }
        };
        if !valid_month(value) {
            return Ok(error(
                "Use YYYY-MM for graduation and availability, or leave blank.",
            ));
        }
        let value = json!(value);
        p[k] = value.clone();
        p["preferences"][k] = value;
    }
    if let Some(mut search) = get(db, owner, "search", "saved")? {
        for (k, v) in old.as_object().unwrap() {
            if p["preferences"][k] == *v {
                continue;
            }
            if k == "roles" {
                search["query"] = json!("");
            }
            if let Some(filters) = search["filters"].as_object_mut() {
                filters.remove(k);
                if k == "roles" {
                    filters.remove("any_role");
                }
                if k == "salary_min" {
                    filters.remove("salary_period");
                }
            }
        }
        put(db, owner, "search", "saved", &search)?;
    }
    put(db, owner, "profile", "profile", &p)?;
    bootstrap(db, owner)
}
fn swipe(db: &Connection, owner: &str, a: &Value) -> Result<Value> {
    let id = string(a, "job_id");
    let action = string(a, "action");
    let sample = DEMO["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|j| j["id"] == id);
    let demo = sample.is_some();
    let job = if let Some(j) = sample {
        let mut j = j.clone();
        j["demo"] = json!(true);
        Some(j)
    } else {
        catalog::listing(db, id)?
    };
    let Some(mut job) = job.filter(|_| matches!(action, "apply" | "pass")) else {
        return Ok(error("Invalid job or action."));
    };
    if !demo && (job["active"] != true || job["stale"] == true) {
        return Ok(error(
            "This listing is no longer verified active. Refresh your search.",
        ));
    }
    if get(db, owner, "decision", id)?.is_none() {
        put(
            db,
            owner,
            "decision",
            id,
            &json!({"job_id":id,"action":action}),
        )?;
        if action == "apply" {
            if !demo {
                job = catalog::detail(db, owner, job)?;
            }
            let app = uuid(db)?;
            put(
                db,
                owner,
                "application",
                &app,
                &json!({"id":app,"job_id":id,"job":job,"demo":demo,"created_at":now(),
                "notes":"","status":if demo {""}else{"Ready to apply"},"resume_id":crate::resumes::selected_resume(db,owner)?,
                "history":[],"tailor":{"resume_id":"","resume_name":"","ready":false}}),
            )?;
        }
    }
    bootstrap(db, owner)
}
fn update_application(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Value> {
    let id = string(a, "id");
    let action = match method {
        "save_application" => "notes",
        "mark_application_submitted" => "submit",
        "select_application_resume" => "resume",
        _ => string(a, "action"),
    };
    if action == "notes"
        && !a["notes"]
            .as_str()
            .is_some_and(|s| s.chars().count() <= 5000)
    {
        return Ok(error("Notes must be under 5,000 characters."));
    }
    if action == "resume"
        && !string(a, "resume_id").is_empty()
        && !crate::resumes::resume_exists(db, owner, string(a, "resume_id"))?
    {
        return Ok(error("Resume not found."));
    }
    let missing = if action == "submit" {
        "Real application not found."
    } else {
        "Application not found."
    };
    let Some(mut app) = get(db, owner, "application", id)? else {
        return Ok(error(missing));
    };
    match action {
        "notes" => app["notes"] = a["notes"].clone(),
        "resume" => {
            if !a["resume_id"].is_string() {
                return Ok(error("Resume not found."));
            }
            app["resume_id"] = a["resume_id"].clone();
        }
        "submit" if app["demo"] == false => {
            if app["status"] != "Submitted" {
                app["status"] = json!("Submitted");
                app["history"]
                    .as_array_mut()
                    .unwrap()
                    .push(json!({"status":"Submitted","at":now(),"source":"User confirmed"}));
            }
        }
        "submit" => return Ok(error(missing)),
        _ => return Ok(error("Invalid application action.")),
    }
    put(db, owner, "application", id, &app)?;
    bootstrap(db, owner)
}
fn save_contact(db: &Connection, owner: &str, a: &Value) -> Result<Value> {
    let id = string(a, "id");
    if ["draft", "notes"]
        .iter()
        .any(|k| !a[*k].as_str().is_some_and(|s| s.chars().count() <= 5000))
    {
        return Ok(error("Keep notes and drafts under 5,000 characters."));
    }
    let Some(mut c) = contact(db, owner, id)? else {
        return Ok(error("Contact not found."));
    };
    if !a["saved"].is_boolean() {
        return Ok(error("Invalid saved state."));
    }
    for k in ["saved", "draft", "notes"] {
        c[k] = a[k].clone();
    }
    put(db, owner, "contact", id, &c)?;
    bootstrap(db, owner)
}
fn update_reminder(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Value> {
    let mut id = string(a, "id").to_owned();
    let action = if method == "save_reminder" {
        if id.is_empty() {
            "create"
        } else {
            "reschedule"
        }
    } else {
        string(a, "action")
    };
    if action == "create" || action == "reschedule" {
        let title = string(a, "title");
        let due = a["due_at"].as_f64().unwrap_or_default();
        if title.trim().is_empty() || title.chars().count() > 160 || due <= now() {
            return Ok(error("Choose a title and a future date."));
        }
        let target = string(a, "target_type");
        let target_id = string(a, "target_id");
        let exists = match target {
            "application" => get(db, owner, target, target_id)?.is_some(),
            "contact" => contact(db, owner, target_id)?.is_some(),
            _ => false,
        };
        if !exists {
            return Ok(error("Reminder target not found."));
        }
        let mut r = if action == "create" {
            if !id.is_empty() {
                return Ok(error("Invalid reminder action."));
            }
            id = uuid(db)?;
            json!({"id":id,"target_type":target,"target_id":target_id})
        } else {
            let Some(r) = get(db, owner, "reminder", &id)? else {
                return Ok(error("Reminder not found."));
            };
            r
        };
        r["title"] = json!(title.trim());
        r["due_at"] = json!(due);
        r["done"] = json!(false);
        put(db, owner, "reminder", &id, &r)?;
    } else {
        let Some(mut r) = get(db, owner, "reminder", &id)? else {
            return Ok(error("Reminder not found."));
        };
        match action {
            "complete" => {
                r["done"] = json!(true);
                put(db, owner, "reminder", &id, &r)?;
            }
            "delete" => {
                db.execute(
                    "DELETE FROM job_records WHERE owner=? AND kind='reminder' AND key=?",
                    params![owner, id],
                )?;
            }
            _ => return Ok(error("Invalid reminder action.")),
        }
    }
    bootstrap(db, owner)
}
pub fn handles(m: &str) -> bool {
    matches!(
        m,
        "agent_features"
            | "agent_linkedin_profile"
            | "bootstrap"
            | "save_profile"
            | "save_timeline"
            | "swipe"
            | "save_application"
            | "select_application_resume"
            | "mark_application_submitted"
            | "update_application"
            | "save_contact"
            | "save_reminder"
            | "change_reminder"
            | "update_reminder"
            | "job_feed"
            | "get_job"
            | "search_jobs"
            | "save_search"
            | "reset_search"
            | "import_job_url"
            | "get_import_status"
            | "source_status"
    )
}
pub fn dispatch(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Option<Value>> {
    let out = match method {
        "agent_features" => json!({"features":features::summary(db,owner)?["features"]}),
        "agent_linkedin_profile" => {
            let mut value = profile(db, owner)?;
            let before = value.clone();
            let url = string(a, "url");
            if !url.is_empty() {
                let url = url.trim();
                value["linkedin_url"] = if url.contains("://") {
                    json!(url)
                } else {
                    json!(format!("https://{url}"))
                };
            }
            if let Some(role) = a["target_role"].as_str().filter(|v| *v != "None") {
                value["linkedin_target_role"] = json!(role.trim());
            }
            if value != before {
                put(db, owner, "profile", "profile", &value)?;
            }
            json!({"url":value["linkedin_url"],"target_role":value["linkedin_target_role"],"model_selection":crate::account::selection(db, owner)?})
        }
        "bootstrap" => bootstrap(db, owner)?,
        "save_profile" | "save_timeline" => update_profile(db, owner, method, a)?,
        "swipe" => swipe(db, owner, a)?,
        "save_application"
        | "select_application_resume"
        | "mark_application_submitted"
        | "update_application" => update_application(db, owner, method, a)?,
        "save_contact" => save_contact(db, owner, a)?,
        "save_reminder" | "change_reminder" | "update_reminder" => {
            update_reminder(db, owner, method, a)?
        }
        "import_job_url" | "get_import_status" => error("Importing job links isn't available yet."),
        "get_job" | "source_status" => catalog::call(db, owner, method, a)?,
        _ => return Ok(None),
    };
    Ok(Some(out))
}
pub fn detach_resume(db: &Connection, owner: &str, id: &str) -> Result<()> {
    db.execute("UPDATE job_records SET data=json_set(data,'$.resume_id','') WHERE owner=? AND kind='application' AND json_extract(data,'$.resume_id')=?",params![owner,id])?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn database() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON; CREATE TABLE accounts(id TEXT PRIMARY KEY); INSERT INTO accounts VALUES('alice'),('bob');").unwrap();
        crate::account::init(&db).unwrap();
        crate::career::init(&db).unwrap();
        crate::resumes::init(&db).unwrap();
        init(&db).unwrap();
        db
    }
    fn run(db: &Connection, owner: &str, name: &str, args: Value) -> Value {
        if ranked(name) {
            return ranked_request(db, name, &args, |_| Ok(Ok(owner.to_owned())))
                .unwrap()
                .1["data"]["result"]
                .clone();
        }
        let tx = db.unchecked_transaction().unwrap();
        let value = dispatch(&tx, owner, name, &args).unwrap().unwrap();
        tx.commit().unwrap();
        value
    }
    #[test]
    fn account_workflow_keeps_contacts_private_and_restores_reminders() {
        let db = database();
        let first = run(&db, "alice", "bootstrap", json!({}));
        assert_eq!(first["people"].as_array().unwrap().len(), 4);
        let id = &first["contacts"][0]["id"];
        assert_eq!(
            run(&db, "alice", "bootstrap", json!({}))["contacts"][0]["id"],
            *id
        );
        let input = json!({"id":id,"saved":true,"draft":"Synthetic note","notes":"synthetic"});
        assert_eq!(
            run(&db, "bob", "save_contact", input.clone())["error"],
            "Contact not found."
        );
        assert_eq!(
            run(&db, "alice", "save_contact", input)["contacts"][0]["saved"],
            true
        );
        let due = now() + 60.0;
        let reminder = json!({"id":"","target_type":"contact","target_id":id,"due_at":due,"title":" Follow up "});
        let r = run(&db, "alice", "save_reminder", reminder.clone());
        let rid = &r["reminders"][0]["id"];
        assert_eq!(r["reminders"][0]["title"], "Follow up");
        assert_eq!(
            run(
                &db,
                "bob",
                "change_reminder",
                json!({"id":rid,"action":"complete"})
            )["error"],
            "Reminder not found."
        );
        assert_eq!(
            run(
                &db,
                "alice",
                "change_reminder",
                json!({"id":rid,"action":"complete"})
            )["reminders"][0]["done"],
            true
        );
        let mut r = reminder;
        r["id"] = rid.clone();
        assert_eq!(
            run(&db, "alice", "save_reminder", r)["reminders"][0]["done"],
            false
        );
        assert_eq!(
            run(
                &db,
                "alice",
                "change_reminder",
                json!({"id":rid,"action":"delete"})
            )["reminders"],
            json!([])
        );
    }
    #[test]
    fn profile_rejects_bad_timeline_without_partial_writes() {
        let db = database();
        let mut args = json!({"name":" Synthetic ","role":"Engineer","location":"US","mode":"Remote","notifications":false,"graduation_month":"2027-05"});
        let p = run(&db, "alice", "save_profile", args.clone());
        assert_eq!(p["profile"]["name"], "Synthetic");
        assert_eq!(p["profile"]["preferences"]["modes"], json!(["Remote"]));
        args["name"] = json!("Changed");
        args["graduation_month"] = json!("2027-13");
        assert!(run(&db, "alice", "save_profile", args)["error"].is_string());
        assert_eq!(
            run(&db, "alice", "bootstrap", json!({}))["profile"]["name"],
            "Synthetic"
        );
        assert_eq!(
            run(&db, "bob", "bootstrap", json!({}))["profile"]["onboarded"],
            false
        );
    }
    #[test]
    fn feature_checks_follow_owned_permissions_and_confirmed_inputs() {
        let db = database();
        let before = run(&db, "alice", "agent_features", json!({}));
        assert_eq!(before["features"].as_array().unwrap().len(), 11);
        db.execute("INSERT INTO account_preferences(owner,policy,facts) VALUES(?,?,?)",params!["alice",
            json!({"enabled":true,"expires_at":now()+600.0,"domains":["example.invalid"],"actions":["calendar_write"],"daily_limits":{"calendar_write":2}}).to_string(),
            json!([{"key":"custom.synthetic","verified":true}]).to_string()]).unwrap();
        fn check<'a>(view: &'a Value, feature: &str, key: &str) -> &'a Value {
            view["agents"]["features"]
                .as_array()
                .unwrap()
                .iter()
                .find(|f| f["key"] == feature)
                .unwrap()["checks"]
                .as_array()
                .unwrap()
                .iter()
                .find(|c| c["key"] == key)
                .unwrap()
        }
        let alice = run(&db, "alice", "bootstrap", json!({}));
        let bob = run(&db, "bob", "bootstrap", json!({}));
        assert_eq!(check(&alice, "profile", "facts")["ok"], true);
        assert_eq!(check(&bob, "profile", "facts")["ok"], false);
        assert_eq!(check(&alice, "calendar", "rules")["ok"], true);
        assert_eq!(check(&alice, "calendar", "perm:calendar_write")["ok"], true);
        assert_eq!(check(&alice, "networking", "domains")["ok"], true);
        assert_eq!(alice["agents"]["model_provider"]["configured"], false);
    }
    #[test]
    fn cold_feed_allows_catalog_writes_and_discards_the_stale_rank() {
        let path = std::env::temp_dir().join(format!("stack-rank-{}.db", crate::auth::random_id()));
        let reader = Connection::open(&path).unwrap();
        reader.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE accounts(id TEXT PRIMARY KEY); INSERT INTO accounts VALUES('alice');").unwrap();
        init(&reader).unwrap();
        let writer = Connection::open(&path).unwrap();
        writer.busy_timeout(std::time::Duration::ZERO).unwrap();
        let entered = std::cell::Cell::new(0);
        let (_, result) = ranked_request(&reader, "job_feed", &json!({}), |db| {
            let _: String = db.query_row("SELECT id FROM accounts", [], |r| r.get(0))?;
            if entered.get() == 0 {
                writer.execute("INSERT INTO catalog_jobs(id,data) VALUES('test','{}')", [])?;
            }
            entered.set(entered.get() + 1);
            Ok(Ok("alice".into()))
        })
        .unwrap();
        assert_eq!(result["data"]["result"]["total"], 0);
        assert_eq!(
            entered.get(),
            4,
            "discard the first read snapshot and reauthorize before publication"
        );
        drop(writer);
        drop(reader);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn populated_feed_pages_and_preserves_a_saved_listing() {
        let db = database();
        for i in 0..27 {
            let id = format!("job_{i:032x}");
            let row = json!({"id":id,"country":"US","title":"Software Engineer","company":"Synthetic","source_id":"synthetic-board","location":"United States","active":true,"stale":false,
                "expires_at":0,"checked_at":now(),"demo":false,"description":"Design software systems.","posted_at":1000+i,"mode":"Remote"});
            db.execute(
                "INSERT INTO catalog_jobs VALUES(?,?)",
                params![id, row.to_string()],
            )
            .unwrap();
        }
        let first = run(&db, "alice", "job_feed", json!({}));
        assert_eq!(first["total"], 27);
        assert_eq!(first["jobs"].as_array().unwrap().len(), 25);
        let equivalent = run(
            &db,
            "alice",
            "search_jobs",
            json!({"query":"","filters":{"country":"US","sort":"relevance"}}),
        );
        assert_eq!(equivalent["computed_at"], first["computed_at"]);
        let recent = json!({"query":"Software Engineer","filters":{}});
        let searched = run(&db, "alice", "search_jobs", recent.clone());
        assert_eq!(searched["total"], 27);
        assert_ne!(searched["next_cursor"], first["next_cursor"]);
        let wrong_cursor = run(
            &db,
            "alice",
            "job_feed",
            json!({"cursor":searched["next_cursor"]}),
        );
        assert!(wrong_cursor["error"].is_string());
        let next = run(
            &db,
            "alice",
            "job_feed",
            json!({"cursor":first["next_cursor"]}),
        );
        assert_eq!(next["jobs"].as_array().unwrap().len(), 2);
        assert_eq!(next["next_cursor"], "");
        assert!(next["jobs"][0]["highlights"].is_object());
        assert!(next["jobs"][0]["match"].is_object());
        assert!(next["jobs"][0].get("_ranked").is_none());
        assert_eq!(first["computed_at"], next["computed_at"]);
        assert_eq!(
            run(&db, "alice", "search_jobs", recent)["computed_at"],
            searched["computed_at"]
        );
        run(
            &db,
            "alice",
            "search_jobs",
            json!({"query":"Data Analyst","filters":{}}),
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM job_match_cache WHERE owner='alice'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            2
        );
        assert_eq!(
            run(&db, "alice", "job_feed", json!({}))["computed_at"],
            first["computed_at"]
        );
        assert_ne!(first["jobs"][24]["id"], next["jobs"][0]["id"]);
        let job = first["jobs"][0]["id"].clone();
        let d = run(&db, "alice", "get_job", json!({"id":job}));
        assert_eq!(d["description"], "Design software systems.");
        assert!(d["match"].is_object());
        assert!(run(&db, "alice", "job_feed", json!({"cursor":"broken"}))["error"].is_string());
        assert!(
            run(
                &db,
                "alice",
                "save_search",
                json!({"query":"","filters":{"bad":true}})
            )["error"]
                .is_string()
        );
        let row = json!({"job_id":job,"action":"apply"});
        let a = run(&db, "alice", "swipe", row.clone());
        let id = a["applications"][0]["id"].clone();
        assert!(id.is_string());
        assert_eq!(
            run(&db, "alice", "swipe", row)["applications"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            run(
                &db,
                "bob",
                "save_application",
                json!({"id":id,"notes":"other"})
            )["error"],
            "Application not found."
        );
        for _ in 0..2 {
            let a = run(&db, "alice", "mark_application_submitted", json!({"id":id}));
            assert_eq!(a["applications"][0]["history"].as_array().unwrap().len(), 1);
        }
        let updated = run(
            &db,
            "alice",
            "save_profile",
            json!({"name":"","role":"Physician","location":"","mode":"Any","notifications":true}),
        );
        assert_eq!(updated["applications"][0]["job"]["match"]["excluded"], true);
        db.execute("UPDATE catalog_jobs SET data=json_set(data,'$.description','A current role description') WHERE id=?",[job.as_str().unwrap()]).unwrap();
        assert_eq!(
            run(&db, "alice", "bootstrap", json!({}))["applications"][0]["job"]["description"],
            "A current role description"
        );
        db.execute(
            "DELETE FROM catalog_jobs WHERE id=?",
            [job.as_str().unwrap()],
        )
        .unwrap();
        assert_eq!(
            run(&db, "alice", "bootstrap", json!({}))["applications"][0]["job"]["id"],
            job
        );
        assert_eq!(run(&db, "alice", "job_feed", json!({}))["total"], 0);
        assert_eq!(run(&db, "bob", "job_feed", json!({}))["total"], 26);
        db.execute("INSERT INTO catalog_sources VALUES('synthetic-board','{\"id\":\"synthetic-board\",\"status\":\"disabled\"}')",[]).unwrap();
        let redacted = run(&db, "alice", "bootstrap", json!({}));
        assert_eq!(
            redacted["applications"][0]["job"]["title"],
            "Listing no longer available"
        );
        assert!(
            redacted["applications"][0]["job"]
                .get("description")
                .is_none()
        );
    }
}
