#[path = "resume_assets.rs"]
mod assets;
use crate::{auth::random_id, jobs, now};
pub(crate) use assets::read_source;
pub use assets::{save_tailored, source_export, start_source_worker, tailored_export};
use base64::{Engine, engine::general_purpose::STANDARD};
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    env,
    io::Write,
    path::Path,
    process::{Command, Stdio},
};

pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS resumes (
       id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
       name TEXT NOT NULL, content BLOB NOT NULL, digest TEXT NOT NULL, created_at REAL NOT NULL,
       review TEXT NOT NULL, revision INTEGER NOT NULL, confirmed INTEGER NOT NULL, processing TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS resumes_owner ON resumes(owner);
    CREATE TABLE IF NOT EXISTS resume_selection (
       owner TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
       id TEXT NOT NULL REFERENCES resumes(id) ON DELETE CASCADE);")?;
    assets::init(db)
}
pub fn selected_resume(db: &Connection, owner: &str) -> Result<String> {
    Ok(db
        .query_row(
            "SELECT id FROM resume_selection WHERE owner=?",
            [owner],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or_default())
}
pub fn resume_exists(db: &Connection, owner: &str, id: &str) -> Result<bool> {
    db.query_row(
        "SELECT EXISTS(SELECT 1 FROM resumes WHERE owner=? AND id=?)",
        params![owner, id],
        |r| r.get(0),
    )
}
fn label(key: &str) -> Option<&'static str> {
    Some(match key {
        "classic" => "Classic",
        "jake" => "Jake's Resume",
        "awesome-cv" => "Awesome-CV",
        "bill-ryan" => "Bill Ryan's Elegant Resume",
        "sb2nov" => "Sourabh Bajaj's Resume",
        "deedy" => "Deedy Resume",
        "jan-kuster" => "Jan Kuster's Classic CV",
        _ => return None,
    })
}
pub fn enrich_bootstrap(db: &Connection, owner: &str, view: &mut Value) -> Result<()> {
    let mut stmt=db.prepare("SELECT id,name,length(content),created_at,json_extract(review,'$.template'),revision,confirmed,processing,(SELECT format FROM resume_sources WHERE resume=resumes.id)
                             FROM resumes WHERE owner=? ORDER BY rowid")?;
    let rows=stmt.query_map([owner],|r|{
        let design:Option<String>=r.get(4)?;
        let confirmed:bool=r.get(6)?;
        let artifact:Option<Value>=r.get(8)?;
        let format=artifact.filter(|v|v["kind"]=="upload"||design.is_none()).unwrap_or_else(||match design.as_deref(){
            Some(t)=>json!({"kind":"records","label":label(t),"template":t,"summary":{},"pages":0,"skipped":[]}),
            None=>json!({"kind":"","label":"Review imported content","template":"","summary":{},"pages":0,"skipped":[]})
        });
        Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"size":r.get::<_,i64>(2)?,
            "created_at":r.get::<_,f64>(3)?,"details_status":if confirmed {"Confirmed"} else if design.is_some() {"Review"} else {"Processing"},
            "review_revision":r.get::<_,i64>(5)?,"processing":r.get::<_,Value>(7)?,"format":format}))
    })?.collect::<Result<Vec<_>>>()?;
    let selected = selected_resume(db, owner)?;
    if let Some(apps) = view["applications"].as_array_mut() {
        for app in apps {
            let resolved = rows
                .iter()
                .find(|r| r["id"] == app["resume_id"])
                .or_else(|| rows.iter().find(|r| r["id"] == selected))
                .or_else(|| if rows.len() == 1 { rows.first() } else { None });
            app["tailor"]=resolved.map(|r| json!({"resume_id":r["id"],"resume_name":r["name"],"ready":r["details_status"]=="Confirmed" || r["format"]["kind"]=="upload"}))
                .unwrap_or(json!({"resume_id":"","resume_name":"","ready":false}));
        }
    }
    view["resumes"] = json!(rows);
    view["selected_resume"] = json!(selected);
    assets::enrich(db, owner, view)
}
const READER: &str = include_str!("../documents.py");
pub(crate) fn inspect(name: &str, bytes: &[u8]) -> Result<Value> {
    document("validate", name, bytes)
}
fn document(action: &str, name: &str, bytes: &[u8]) -> Result<Value> {
    let root = env::var("STACK_DISCOVERY_ROOT").unwrap_or_else(|_| "..".into());
    let python = env::var("STACK_DOCUMENT_PYTHON").unwrap_or_else(|_| "python3".into());
    let mut child = Command::new(python)
        .args(["-I", "-c", READER, &root, action, name])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|_| rusqlite::Error::InvalidQuery)?;
    let sent = child.stdin.take().unwrap().write_all(bytes);
    let output = child
        .wait_with_output()
        .map_err(|_| rusqlite::Error::InvalidQuery)?;
    if sent.is_err() || !output.status.success() {
        return Err(rusqlite::Error::InvalidQuery);
    }
    serde_json::from_slice(&output.stdout).map_err(|_| rusqlite::Error::InvalidQuery)
}
fn queue_import(
    db: &Connection,
    id: &str,
    name: &str,
    digest: &str,
    created: f64,
    elapsed: f64,
) -> Result<Value> {
    let ticket = random_id();
    let task = json!({"id":ticket,"status":"queued","message":name,"fingerprint":digest,"attempt":0,
        "queued_at":created,"stage_at":0.0,"timings":{"transfer_ms":(elapsed>0.0).then_some(elapsed),
        "queue_ms":0.0,"parse_ms":0.0,"compile_ms":0.0}});
    db.execute("INSERT INTO resume_import_jobs(resume,ticket,name,due) VALUES(?,?,?,?)
                ON CONFLICT(resume) DO UPDATE SET ticket=excluded.ticket,name=excluded.name,due=excluded.due,lease=''",
               params![id,ticket,name,created])?;
    db.execute(
        "UPDATE resumes SET processing=json_set(processing,'$.import',json(?)) WHERE id=?",
        params![task, id],
    )?;
    Ok(task)
}

pub fn upload_rpc(db: &mut Connection, token: &str, a: &Value) -> Result<crate::Response> {
    if crate::admitted_owner(db, token)?.is_none() {
        return Ok(crate::denied());
    }
    if let Some(response) = crate::arguments::missing("upload_resume", a) {
        return Ok(response);
    }
    let name = a["name"].as_str().unwrap_or("");
    if name.trim().is_empty() || name.chars().count() > 160 {
        return Ok(crate::result(err("Use a filename under 160 characters.")));
    }
    let input = a["content"].as_str().unwrap_or("");
    if input.len() > 13_981_016 {
        return Ok(crate::result(err("Resume must be 10 MB or smaller.")));
    }
    let Ok(raw) = STANDARD.decode(input) else {
        return Ok(crate::result(err("Invalid resume encoding.")));
    };
    let validation = document("validate", name, &raw)?;
    if validation.get("error").is_some() {
        return Ok(crate::result(validation));
    }
    let digest = hex::encode(Sha256::digest(&raw));
    let name = Path::new(name)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let Some(owner) = crate::admitted_owner(&tx, token)? else {
        return Ok(crate::denied());
    };
    let exists: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM resumes WHERE owner=? AND digest=? AND name=?)",
        params![owner, digest, name],
        |r| r.get(0),
    )?;
    if !exists {
        let id = random_id();
        let created = now();
        let elapsed = a["transfer_ms"]
            .as_f64()
            .unwrap_or(0.0)
            .clamp(0.0, 86400000.0);
        tx.execute(
            "INSERT INTO resumes VALUES (?,?,?,?,?,?,'{}',0,0,'{}')",
            params![id, owner, name, raw, digest, created],
        )?;
        queue_import(&tx, &id, name, &digest, created, elapsed)?;
        tx.execute(
            "INSERT INTO resume_selection VALUES (?,?) ON CONFLICT DO NOTHING",
            params![owner, id],
        )?;
    }
    let mut value = jobs::bootstrap(&tx, &owner)?;
    crate::career::enrich_bootstrap(&tx, &owner, &mut value)?;
    enrich_bootstrap(&tx, &owner, &mut value)?;
    tx.commit()?;
    Ok(crate::result(value))
}
fn err(text: &str) -> Value {
    json!({"error":text})
}
pub fn handles(m: &str) -> bool {
    matches!(
        m,
        "upload_resume"
            | "read_resume"
            | "change_resume"
            | "agent_extract_resume"
            | "resume_save_details"
            | "resume_save_records"
            | "use_resume_template"
            | "upload_resume_source"
            | "retry_resume_processing"
            | "read_tailored_resume"
            | "check_tailored_resume"
            | "delete_tailored_resume"
            | "resume_transfer_complete"
    )
}
pub fn dispatch(db: &Connection, owner: &str, m: &str, a: &Value) -> Result<Option<Value>> {
    if !handles(m) {
        return Ok(None);
    }
    let id = a["id"].as_str().unwrap_or("");
    if m.ends_with("_tailored_resume") {
        return assets::artifact(db, owner, m, id).map(Some);
    }
    if m == "upload_resume_source" {
        return assets::upload(db, owner, id, a).map(Some);
    }
    let meta = db
        .query_row(
            "SELECT name,review,revision,confirmed,processing FROM resumes WHERE owner=? AND id=?",
            params![owner, id],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Value>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, bool>(3)?,
                    r.get::<_, Value>(4)?,
                ))
            },
        )
        .optional()?;
    let Some((name, mut review, revision, confirmed, mut processing)) = meta else {
        return Ok(Some(err(
            if matches!(m, "resume_transfer_complete" | "retry_resume_processing") {
                "Resume processing not found."
            } else {
                "Resume not found."
            },
        )));
    };
    let result = match m {
        "retry_resume_processing" => {
            assets::retry(db, owner, id, a["kind"].as_str().unwrap_or(""), &processing)?
        }
        "read_resume" => {
            let content: Vec<u8> = db.query_row(
                "SELECT content FROM resumes WHERE owner=? AND id=?",
                params![owner, id],
                |r| r.get(0),
            )?;
            review["confirmed"] = json!(confirmed);
            review["revision"] = json!(revision);
            json!({"content":STANDARD.encode(content),"name":name,"review":review})
        }
        "change_resume" => {
            match a["action"].as_str().unwrap_or("") {
                "delete" => {
                    let _ = crate::account::resume_facts(db, owner, id, &json!([]))?;
                    jobs::detach_resume(db, owner, id)?;
                    db.execute(
                        "DELETE FROM resumes WHERE owner=? AND id=?",
                        params![owner, id],
                    )?;
                }
                "select" => {
                    db.execute("INSERT INTO resume_selection VALUES (?,?) ON CONFLICT(owner) DO UPDATE SET id=excluded.id",params![owner,id])?;
                }
                "rename" => {
                    let name = a["name"].as_str().unwrap_or("");
                    if name.trim().is_empty() || name.chars().count() > 160 {
                        return Ok(Some(err("Enter a name under 160 characters.")));
                    }
                    db.execute(
                        "UPDATE resumes SET name=? WHERE owner=? AND id=?",
                        params![name.trim(), owner, id],
                    )?;
                }
                _ => return Ok(Some(err("Invalid resume action."))),
            }
            jobs::bootstrap(db, owner)?
        }
        "agent_extract_resume" | "resume_save_details" => {
            let save = m == "resume_save_details";
            if save && a["revision"].as_i64() != Some(revision) {
                return Ok(Some(err("Resume review changed. Reload it before saving.")));
            }
            if save && review.get("records").is_none() {
                return Ok(Some(err(
                    "Wait for resume import before editing its details.",
                )));
            }
            if !save {
                let previous = &processing["import"];
                let details_missing =
                    review["details"].is_null() && review["details_error"].is_null();
                let has_records = review["records"].as_array().is_some_and(|r| !r.is_empty());
                if (!has_records && previous.is_null())
                    || (has_records
                        && details_missing
                        && (previous.is_null() || previous["status"] == "completed"))
                {
                    let input = previous["message"].as_str().unwrap_or(&name);
                    let ext = Path::new(input)
                        .extension()
                        .and_then(|s| s.to_str())
                        .unwrap_or("")
                        .to_lowercase();
                    if matches!(ext.as_str(), "pdf" | "docx") {
                        let digest: String = db.query_row(
                            "SELECT digest FROM resumes WHERE owner=? AND id=?",
                            params![owner, id],
                            |r| r.get(0),
                        )?;
                        processing["import"] = queue_import(db, id, input, &digest, now(), 0.0)?;
                    }
                }
            }
            let confirm = if save {
                a["confirm"].as_bool().unwrap_or(false)
            } else {
                confirmed
            };
            let payload = json!({"review":review,"values":a["values"],"revision":revision,"id":id,"confirm":confirm,"now":now()});
            let data = document(
                if save { "save" } else { "view" },
                &name,
                &serde_json::to_vec(&payload).unwrap(),
            )?;
            if data.get("error").is_some() {
                return Ok(Some(data));
            }
            if save {
                review = data["review"].clone();
                assets::invalidate_builtin(db, id, &mut processing)?;
                if let Some(error) = crate::account::resume_facts(db, owner, id, &data["facts"])? {
                    return Ok(Some(error));
                }
                db.execute("UPDATE resumes SET review=?,confirmed=?,revision=revision+1,processing=? WHERE owner=? AND id=?",params![review,confirm,processing,owner,id])?;
            }
            let view = review.as_object_mut().unwrap();
            view.remove("details");
            view.remove("values");
            view.extend(data["view"].as_object().unwrap().clone());
            review["revision"] = json!(revision + i64::from(save));
            review["confirmed"] = json!(confirm);
            review["processing"] = processing["import"]
                .as_object()
                .cloned()
                .map(Value::Object)
                .unwrap_or(json!({}));
            review["trusted_source"] = if confirm {
                review["records_source"].clone()
            } else {
                json!("")
            };
            review
        }
        "use_resume_template" => {
            let design = a["template"].as_str().unwrap_or("");
            if !design.is_empty() {
                if label(design).is_none() {
                    return Ok(Some(err("Choose one of the built-in templates.")));
                }
                if !confirmed {
                    return Ok(Some(err(
                        "Confirm your resume details first, so Stack can fill the template.",
                    )));
                }
                if !review["records"].as_array().is_some_and(|v| !v.is_empty()) {
                    let raw =
                        serde_json::to_vec(&json!({"template":design,"values":review["values"]}))
                            .unwrap();
                    return assets::queue(db, owner, id, design, raw, true, 0.0).map(Some);
                }
                if review["template"].as_str().unwrap_or("classic") != design {
                    review["template"] = json!(design);
                    db.execute(
                        "UPDATE resumes SET review=?,revision=revision+1 WHERE owner=? AND id=?",
                        params![review, owner, id],
                    )?;
                }
            }
            assets::remove_source(db, id)?;
            jobs::bootstrap(db, owner)?
        }
        "resume_transfer_complete" => {
            let kind = ["import", "source"]
                .into_iter()
                .find(|k| processing[*k]["id"].is_string() && processing[*k]["id"] == a["job_id"]);
            let Some(kind) = kind else {
                return Ok(Some(err("Resume processing not found.")));
            };
            processing[kind]["timings"]["transfer_ms"] = json!(
                a["elapsed_ms"]
                    .as_f64()
                    .unwrap_or(0.0)
                    .clamp(0.0, 86400000.0)
            );
            db.execute(
                "UPDATE resumes SET processing=? WHERE owner=? AND id=?",
                params![processing, owner, id],
            )?;
            json!({"saved":true})
        }
        "resume_save_records" => {
            let design = a["template"].as_str().unwrap_or("classic");
            if label(design).is_none() {
                return Ok(Some(err("Choose one of the built-in templates.")));
            }
            let records = match crate::career::validate_records(&a["records"]) {
                Ok(r) => r,
                Err(message) => return Ok(Some(err(&message))),
            };
            if a["revision"].as_i64() != Some(revision) {
                return Ok(Some(err("Resume review changed. Reload it before saving.")));
            }
            if review.get("imported_records").is_none() {
                return Ok(Some(err(
                    "Wait for resume import before reviewing its records.",
                )));
            }
            let confirm = a["confirm"].as_bool().unwrap_or(false);
            let mut history = review["record_history"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            if history.is_empty() {
                history.push(json!({"revision":revision,"records":review["records"],"confirmed":confirmed,"source":format!("Previously reviewed import: {name}"),"saved_at":review["confirmed_at"].as_f64().unwrap_or(0.0)}))
            }
            if history.len() >= 100 {
                return Ok(Some(err(
                    "This resume has 100 record revisions. Export before importing a new copy.",
                )));
            }
            history.push(json!({"revision":revision+1,"records":records,"confirmed":confirm,"source":format!("User-reviewed import: {name}"),"saved_at":now()}));
            let _ = crate::account::resume_facts(db, owner, id, &json!([]))?;
            if review["details"].is_object() {
                review["details"]["confirmed"] = json!(false);
                review["details"]["confirmed_at"] = json!(0.0);
            }
            assets::invalidate_builtin(db, id, &mut processing)?;
            review["records"] = json!(records);
            review["template"] = json!(design);
            review["records_source"] = json!("records");
            review["record_history"] = json!(history);
            review["confirmed_at"] = json!(if confirm { now() } else { 0.0 });
            db.execute("UPDATE resumes SET review=?,confirmed=?,revision=revision+1,processing=? WHERE owner=? AND id=?",params![review,confirm,processing,owner,id])?;
            review
                .as_object_mut()
                .unwrap()
                .retain(|k, _| k != "details" && k != "values");
            review["confirmed"] = json!(confirm);
            review["revision"] = json!(revision + 1);
            review["trusted_source"] = json!(if confirm { "records" } else { "" });
            review
        }
        _ => return Ok(None),
    };
    Ok(Some(result))
}

fn retry_import(db: &Connection, owner: &str, id: &str, processing: &Value) -> Result<Value> {
    let mut task = processing["import"].clone();
    let queued = now();
    let ticket = task["id"].as_str().ok_or(rusqlite::Error::InvalidQuery)?;
    db.execute("INSERT INTO resume_import_jobs(resume,ticket,name,due)
                SELECT id,?,COALESCE(json_extract(processing,'$.import.message'),name),? FROM resumes WHERE owner=? AND id=?
                ON CONFLICT(resume) DO UPDATE SET ticket=excluded.ticket,name=excluded.name,due=excluded.due,lease=''",
               params![ticket,queued,owner,id])?;
    task.as_object_mut()
        .ok_or(rusqlite::Error::InvalidQuery)?
        .remove("error");
    task["status"] = json!("queued");
    task["attempt"] = json!(0);
    task["queued_at"] = json!(queued);
    task["stage_at"] = json!(0.0);
    for key in ["queue_ms", "parse_ms", "compile_ms"] {
        task["timings"][key] = json!(0.0);
    }
    db.execute("UPDATE resumes SET processing=json_set(processing,'$.import',json(?)) WHERE owner=? AND id=?",
               params![task,owner,id])?;
    jobs::bootstrap(db, owner)
}
