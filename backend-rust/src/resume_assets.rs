use super::{err, label};
use crate::{auth::random_id, jobs, now, score_docs};
use base64::{Engine, engine::general_purpose::STANDARD};
use rusqlite::{Connection, OptionalExtension, Result, TransactionBehavior, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{path::Path, thread, time::Duration};

pub(super) fn init(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS resume_sources(
        resume TEXT PRIMARY KEY REFERENCES resumes(id) ON DELETE CASCADE, format TEXT NOT NULL,
        encoded TEXT NOT NULL, preview BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS resume_import_jobs(
            resume TEXT PRIMARY KEY REFERENCES resumes(id) ON DELETE CASCADE, ticket TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL, due REAL NOT NULL, lease TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS resume_import_due ON resume_import_jobs(due);
        CREATE TABLE IF NOT EXISTS resume_source_jobs(
        resume TEXT PRIMARY KEY REFERENCES resumes(id) ON DELETE CASCADE, ticket TEXT UNIQUE NOT NULL,
        fingerprint TEXT NOT NULL, name TEXT NOT NULL, raw BLOB NOT NULL, builtin INTEGER NOT NULL,
        state TEXT NOT NULL, lease TEXT NOT NULL DEFAULT '', deadline REAL NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS resume_jobs_due ON resume_source_jobs(state,deadline);
        CREATE TABLE IF NOT EXISTS tailored_resumes(
        id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        view TEXT NOT NULL, pdf BLOB, docx BLOB, has_docx INTEGER NOT NULL,
        tex TEXT NOT NULL, change_record TEXT NOT NULL, records TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS tailored_owner ON tailored_resumes(owner);")
}

pub(super) fn queue(
    db: &Connection,
    owner: &str,
    id: &str,
    name: &str,
    raw: Vec<u8>,
    builtin: bool,
    elapsed: f64,
) -> Result<Value> {
    if !super::resume_exists(db, owner, id)? {
        return Ok(err("Resume not found."));
    }
    let mut digest = Sha256::new();
    if !builtin {
        digest.update(name.as_bytes());
    }
    digest.update(&raw);
    let fingerprint = hex::encode(digest.finalize());
    let affected=db.execute("INSERT INTO resume_source_jobs(resume,ticket,fingerprint,name,raw,builtin,state) VALUES (?,?,?,?,?,?,'queued')
        ON CONFLICT(resume) DO UPDATE SET ticket=excluded.ticket,fingerprint=excluded.fingerprint,name=excluded.name,raw=excluded.raw,builtin=excluded.builtin,state='queued',lease='',deadline=0
        WHERE fingerprint<>excluded.fingerprint",params![id,random_id(),fingerprint,Path::new(name).file_name().and_then(|s|s.to_str()).unwrap_or(name),raw,builtin])?;
    if affected > 0 {
        let ticket: String = db.query_row(
            "SELECT ticket FROM resume_source_jobs WHERE resume=?",
            [id],
            |r| r.get(0),
        )?;
        let task = json!({"id":ticket,"status":"queued","message":name,"fingerprint":fingerprint,"attempt":0,"queued_at":now(),"stage_at":0.0,"timings":{"transfer_ms":if elapsed>0.0{json!(elapsed.min(86400000.0))}else{Value::Null},"queue_ms":0.0,"parse_ms":0.0,"compile_ms":0.0}});
        db.execute(
            "UPDATE resumes SET processing=json_set(processing,'$.source',json(?)) WHERE id=?",
            params![task, id],
        )?;
    }
    jobs::bootstrap(db, owner)
}

pub(super) fn upload(db: &Connection, owner: &str, id: &str, a: &Value) -> Result<Value> {
    let name = a["name"].as_str().unwrap_or("");
    let ext = Path::new(name)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if name.trim().is_empty()
        || name.chars().count() > 160
        || !matches!(ext.as_str(), "tex" | "zip")
    {
        return Ok(err("Choose a .tex file or Overleaf source .zip."));
    }
    let content = a["content"].as_str().unwrap_or("");
    let too_big = "Upload a LaTeX source of 2 MB or less.";
    if content.len() > 2796204 {
        return Ok(err(too_big));
    }
    let Ok(raw) = STANDARD.decode(content) else {
        return Ok(err("This file could not be read. Choose it again."));
    };
    if raw.is_empty() || raw.len() > 2097152 {
        return Ok(err(too_big));
    }
    queue(
        db,
        owner,
        id,
        name,
        raw,
        false,
        a["transfer_ms"].as_f64().unwrap_or(0.0),
    )
}

pub(super) fn remove_source(db: &Connection, id: &str) -> Result<()> {
    db.execute("DELETE FROM resume_source_jobs WHERE resume=?", [id])?;
    db.execute("DELETE FROM resume_sources WHERE resume=?", [id])?;
    db.execute(
        "UPDATE resumes SET processing=json_remove(processing,'$.source') WHERE id=?",
        [id],
    )?;
    Ok(())
}

pub fn source_export(db: &Connection, owner: &str, id: &str) -> Result<Option<Value>> {
    db.query_row("SELECT s.encoded FROM resume_sources s JOIN resumes r ON r.id=s.resume WHERE r.owner=? AND r.id=?",params![owner,id],|r|r.get(0)).optional()
}
pub(crate) fn read_source(db: &Connection, owner: &str, id: &str) -> Result<Option<Value>> {
    db.query_row("SELECT r.name,s.format,s.encoded,s.preview FROM resume_sources s JOIN resumes r ON r.id=s.resume WHERE r.owner=? AND r.id=?
       AND (json_extract(s.format,'$.kind')='upload' OR NOT(r.confirmed AND json_array_length(r.review,'$.records')>0))",params![owner,id],|r| {
        let src:Value=r.get(2)?;
        let main=src["main"].as_str().ok_or(rusqlite::Error::InvalidQuery)?;
        let tex=STANDARD.decode(src["files"][main].as_str().unwrap_or("")).map_err(|_|rusqlite::Error::InvalidQuery)?;
        Ok(json!({"id":id,"name":r.get::<_,String>(0)?,"format":r.get::<_,Value>(1)?,
          "preview":{"name":"Resume preview.pdf","content":STANDARD.encode(r.get::<_,Vec<u8>>(3)?)},
          "tex":String::from_utf8_lossy(&tex).chars().take(200000).collect::<String>()}))
    }).optional()
}

pub fn start_source_worker(path: String) {
    thread::spawn(move || {
        loop {
            let attempt = crate::open(&path).and_then(|mut db| {
                loop {
                    let imported = process_import(&mut db)?;
                    let source = process(&mut db)?;
                    if !imported && !source {
                        thread::sleep(Duration::from_secs(2));
                    }
                }
            });
            if let Err(error) = attempt as Result<()> {
                eprintln!("Document processor database error: {error}");
            }
            thread::sleep(Duration::from_secs(3));
        }
    });
}
fn process_import(db: &mut Connection) -> Result<bool> {
    let ready = now();
    let due: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM resume_import_jobs WHERE due<=?)",
        [ready],
        |r| r.get(0),
    )?;
    if !due {
        return Ok(false);
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let job=tx.query_row("SELECT j.resume,j.ticket,j.name,j.due,r.content,r.processing -> '$.import' FROM resume_import_jobs j
            JOIN resumes r ON r.id=j.resume WHERE j.due<=? ORDER BY j.due LIMIT 1",[ready],
        |r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,f64>(3)?,r.get::<_,Vec<u8>>(4)?,
               r.get::<_,Option<Value>>(5)?))).optional()?;
    let Some((id, ticket, name, due, raw, task)) = job else {
        return Ok(false);
    };
    let mut task = task.unwrap_or(Value::Null);
    if task["id"] != ticket || task["attempt"].as_u64().unwrap_or(0) >= 3 {
        tx.execute("DELETE FROM resume_import_jobs WHERE ticket=?", [&ticket])?;
        if task["id"] == ticket {
            task["status"] = json!("failed");
            task["error"] = json!(
                "Processing was interrupted three times. Retry when the worker is available."
            );
            tx.execute(
                "UPDATE resumes SET processing=json_set(processing,'$.import',json(?)) WHERE id=?",
                params![task, id],
            )?;
        }
        tx.commit()?;
        return Ok(true);
    }
    let lease = random_id();
    tx.execute(
        "UPDATE resume_import_jobs SET lease=?,due=? WHERE ticket=?",
        params![lease, ready + 180.0, ticket],
    )?;
    task["status"] = json!("parsing");
    task["stage_at"] = json!(ready);
    task["attempt"] = json!(task["attempt"].as_u64().unwrap_or(0) + 1);
    task["timings"]["queue_ms"] = json!((ready - due).max(0.0) * 1000.0);
    tx.execute(
        "UPDATE resumes SET processing=json_set(processing,'$.import',json(?)) WHERE id=?",
        params![task, id],
    )?;
    tx.commit()?;

    let start = std::time::Instant::now();
    let parsed = super::document("import", &name, &raw)
        .unwrap_or_else(|_| err("Resume processing failed. Retry processing."));
    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let saved=tx.query_row("SELECT r.review,r.processing -> '$.import' FROM resumes r
            JOIN resume_import_jobs j ON j.resume=r.id WHERE r.id=? AND j.ticket=? AND j.lease=? AND j.due>?
            AND json_extract(r.processing,'$.import.id')=j.ticket",params![id,ticket,lease,now()],
            |r|Ok((r.get::<_,Value>(0)?,r.get::<_,Value>(1)?))).optional()?;
    let Some((mut review, mut task)) = saved else {
        return Ok(true);
    };
    task["timings"]["parse_ms"] = json!(elapsed);
    if let Some(imported) = parsed.get("review").filter(|v| v["records"].is_array()) {
        let first = review["records"].as_array().is_none_or(Vec::is_empty);
        if first {
            for key in [
                "records",
                "imported_records",
                "template",
                "upload_digest",
                "records_source",
            ] {
                review[key] = imported[key].clone();
            }
        }
        if !review["details"].is_object() {
            if imported["details"].is_object() {
                review["details"] = imported["details"].clone();
                review["values"] = imported["values"].clone();
                if let Some(map) = review.as_object_mut() {
                    map.remove("details_error");
                }
            } else if let Some(error) = imported.get("details_error") {
                review["details_error"] = error.clone();
            }
        }
        tx.execute("UPDATE resumes SET review=?,revision=revision+1,confirmed=CASE WHEN ? THEN 0 ELSE confirmed END WHERE id=?",
            params![review,first,id])?;
        task["status"] = json!("completed");
        if let Some(map) = task.as_object_mut() {
            map.remove("error");
        }
    } else {
        task["status"] = json!("failed");
        let error = parsed
            .get("processing_error")
            .or_else(|| parsed.get("error"))
            .and_then(Value::as_str)
            .unwrap_or("Resume processing failed.");
        task["error"] = json!(error.chars().take(500).collect::<String>());
    }
    tx.execute(
        "UPDATE resumes SET processing=json_set(processing,'$.import',json(?)) WHERE id=?",
        params![task, id],
    )?;
    tx.execute(
        "DELETE FROM resume_import_jobs WHERE ticket=? AND lease=?",
        params![ticket, lease],
    )?;
    tx.commit()?;
    Ok(true)
}

fn process(db: &mut Connection) -> Result<bool> {
    let due:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM resume_source_jobs WHERE state='queued' OR (state='parsing' AND deadline<?))",[now()],|r|r.get(0))?;
    if !due {
        return Ok(false);
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let job=tx.query_row("SELECT resume,ticket,name,raw,builtin FROM resume_source_jobs WHERE state='queued' OR (state='parsing' AND deadline<?)
         ORDER BY rowid LIMIT 1",[now()],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,Vec<u8>>(3)?,r.get::<_,bool>(4)?))).optional()?;
    let Some((id, ticket, name, raw, builtin)) = job else {
        return Ok(false);
    };
    let lease = random_id();
    tx.execute(
        "UPDATE resume_source_jobs SET state='parsing',lease=?,deadline=? WHERE ticket=?",
        params![lease, now() + 300.0, ticket],
    )?;
    tx.execute("UPDATE resumes SET processing=json_set(processing,'$.source.status','parsing','$.source.stage_at',?1,'$.source.timings.queue_ms',MAX(0,?1-json_extract(processing,'$.source.queued_at'))*1000,'$.source.attempt',json_extract(processing,'$.source.attempt')+1) WHERE id=?2",params![now(),id])?;
    tx.commit()?;
    let out = score_docs::rules(
        &json!({"operation":"source","name":name,"raw":STANDARD.encode(raw),"builtin":builtin,
        "label":label(&name)}),
    )?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let pdf = out["preview"]
        .as_str()
        .and_then(|s| STANDARD.decode(s).ok())
        .filter(|v| !v.is_empty());
    let failure = if pdf.is_none() {
        Some(
            out["error"]
                .as_str()
                .unwrap_or("Resume processing failed. Retry processing."),
        )
    } else {
        None
    };
    let status = if failure.is_some() {
        "failed"
    } else {
        "completed"
    };
    if tx.execute(
        "UPDATE resume_source_jobs SET state=?,deadline=0,lease='' WHERE ticket=? AND lease=?",
        params![status, ticket, lease],
    )? == 1
    {
        tx.execute("UPDATE resumes SET processing=json_set(processing,'$.source.status',?,'$.source.stage_at',?,'$.source.timings.parse_ms',?,'$.source.timings.compile_ms',?) WHERE id=?",params![status,now(),out["parse_ms"].as_f64().unwrap_or(0.0),out["compile_ms"].as_f64().unwrap_or(0.0),id])?;
        if let Some(message) = failure {
            tx.execute(
                "UPDATE resumes SET processing=json_set(processing,'$.source.error',?) WHERE id=?",
                params![message, id],
            )?;
        } else {
            tx.execute("INSERT INTO resume_sources VALUES(?,?,?,?) ON CONFLICT(resume) DO UPDATE SET encoded=excluded.encoded,format=excluded.format,preview=excluded.preview",params![id,out["format"],out["encoded"],pdf])?;
        }
    }
    tx.commit()?;
    Ok(true)
}
pub(super) fn retry(
    db: &Connection,
    owner: &str,
    id: &str,
    kind: &str,
    processing: &Value,
) -> Result<Value> {
    if kind == "pdf" {
        return Ok(err("PDF detail extraction is temporarily unavailable."));
    }
    if !matches!(kind, "source" | "import") || processing[kind]["id"].is_null() {
        return Ok(err("Resume processing not found."));
    }
    if processing[kind]["status"] == "failed" {
        if kind == "import" {
            return super::retry_import(db, owner, id, processing);
        }
        if db.execute(
            "UPDATE resume_source_jobs SET state='queued' WHERE resume=? AND state='failed'",
            [id],
        )? != 1
        {
            return Ok(err("Resume processing not found."));
        }
        db.execute("UPDATE resumes SET processing=json_set(json_remove(processing,'$.source.error'),'$.source.status','queued','$.source.attempt',0,'$.source.queued_at',?,'$.source.stage_at',0,'$.source.timings.queue_ms',0,'$.source.timings.parse_ms',0,'$.source.timings.compile_ms',0) WHERE id=?",params![now(),id])?;
    }
    jobs::bootstrap(db, owner)
}
pub(super) fn enrich(db: &Connection, owner: &str, view: &mut Value) -> Result<()> {
    let mut q=db.prepare("SELECT view FROM tailored_resumes WHERE owner=? ORDER BY json_extract(view,'$.created_at') DESC")?;
    view["tailored_resumes"] = json!(
        q.query_map([owner], |r| r.get::<_, Value>(0))?
            .collect::<Result<Vec<_>>>()?
    );
    Ok(())
}
fn tailored(db: &Connection, owner: &str, id: &str) -> Result<Value> {
    let row=db.query_row("SELECT view,pdf,docx,has_docx,tex,change_record FROM tailored_resumes WHERE owner=? AND id=?",params![owner,id],|r|Ok((r.get::<_,Value>(0)?,r.get::<_,Option<Vec<u8>>>(1)?,r.get::<_,Option<Vec<u8>>>(2)?,r.get::<_,bool>(3)?,r.get::<_,String>(4)?,r.get::<_,Value>(5)?))).optional()?;
    let Some((v, pdf, docx, has_docx, tex, changes)) = row else {
        return Ok(err("Tailored resume not found."));
    };
    let Some(pdf) = pdf else {
        return Ok(err("This file is unavailable."));
    };
    let stem = [
        v["company"].as_str().unwrap_or(""),
        v["job_title"].as_str().unwrap_or(""),
    ]
    .into_iter()
    .filter(|s| !s.is_empty())
    .collect::<Vec<_>>()
    .join(" - ")
    .chars()
    .take(120)
    .collect::<String>()
    .replace('/', "-");
    let mut out = json!({"id":id,"name":v["name"],"pdf":{"name":format!("Resume - {stem}.pdf"),"content":STANDARD.encode(pdf)},"tex":tex,"change_record":changes});
    if has_docx {
        let Some(docx) = docx else {
            return Ok(err("The editable DOCX is unavailable."));
        };
        out["docx"] =
            json!({"name":format!("Resume - {stem}.docx"),"content":STANDARD.encode(docx)});
    }
    Ok(out)
}
pub fn tailored_export(db: &Connection, owner: &str) -> Result<Vec<Value>> {
    let mut q = db.prepare("SELECT id FROM tailored_resumes WHERE owner=? ORDER BY rowid")?;
    q.query_map([owner], |r| r.get::<_, String>(0))?
        .map(|id| tailored(db, owner, &id?))
        .collect()
}
pub(super) fn artifact(db: &Connection, owner: &str, m: &str, id: &str) -> Result<Value> {
    if m == "read_tailored_resume" {
        return tailored(db, owner, id);
    }
    if m == "delete_tailored_resume" {
        if db.execute(
            "DELETE FROM tailored_resumes WHERE owner=? AND id=?",
            params![owner, id],
        )? == 0
        {
            return Ok(err("Tailored resume not found."));
        }
    } else {
        let row = db
            .query_row(
                "SELECT view,pdf,docx,records FROM tailored_resumes WHERE owner=? AND id=?",
                params![owner, id],
                |r| {
                    Ok((
                        r.get::<_, Value>(0)?,
                        r.get::<_, Option<Vec<u8>>>(1)?,
                        r.get::<_, Option<Vec<u8>>>(2)?,
                        r.get::<_, Value>(3)?,
                    ))
                },
            )
            .optional()?;
        let Some((view, pdf, docx, records)) = row else {
            return Ok(err("Tailored resume not found."));
        };
        let mut parse = if view["format"] == "records" && view["has_docx"] == true {
            match (pdf, docx) {
                (Some(pdf), Some(docx)) => score_docs::rules(
                    &json!({"operation":"check","pdf":STANDARD.encode(pdf),"docx":STANDARD.encode(docx),"records":records}),
                )?,
                _ => err("This file is unavailable."),
            }
        } else {
            json!({"available":false,"ok":false,"error":"PDF parser checks are temporarily unavailable.","checks":[],"passed":0,"total":0})
        };
        if parse["error"].is_string() && parse.get("available").is_none() {
            parse["available"] = json!(true);
            parse["ok"] = json!(false);
        }
        parse["checked_at"] = json!(now());
        db.execute("UPDATE tailored_resumes SET view=json_set(view,'$.parse',json(?)) WHERE owner=? AND id=?",params![parse,owner,id])?;
    }
    jobs::bootstrap(db, owner)
}

pub(super) fn invalidate_builtin(db: &Connection, id: &str, processing: &mut Value) -> Result<()> {
    if db.execute(
        "DELETE FROM resume_source_jobs WHERE resume=? AND builtin",
        [id],
    )? > 0
    {
        processing.as_object_mut().unwrap().remove("source");
    }
    db.execute(
        "DELETE FROM resume_sources WHERE resume=? AND json_extract(format,'$.kind')='builtin'",
        [id],
    )?;
    Ok(())
}
pub fn save_tailored(db: &Connection, owner: &str, id: &str, r: &Value) -> Result<Option<String>> {
    let t = &r["artifacts"]["tailor"];
    if t["final"] != true {
        return Ok(None);
    }
    let exists:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM tailored_resumes WHERE owner=? AND json_extract(view,'$.run_id')=?)",params![owner,id],|r|r.get(0))?;
    if exists {
        return Ok(None);
    }
    let bytes = |file: &Value| -> Result<Option<Vec<u8>>> {
        file["content"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(|s| {
                STANDARD
                    .decode(s)
                    .map_err(|_| rusqlite::Error::InvalidQuery)
            })
            .transpose()
    };
    let Some(pdf) = bytes(&t["pdf"])? else {
        return Ok(None);
    };
    let docx = bytes(&t["docx"])?;
    let ctx = &r["context"];
    let job = &ctx["job"];
    let text = |v: &Value, n| v.as_str().unwrap_or("").chars().take(n).collect::<String>();
    let title = text(&job["title"], 200);
    let company = text(&job["company"], 200);
    let name = match (title.is_empty(), company.is_empty()) {
        (false, false) => format!("{title} at {company}"),
        (false, true) => title.clone(),
        (true, false) => company.clone(),
        _ => "Tailored resume".to_string(),
    };
    let artifact = random_id();
    let view = json!({"id":artifact,"name":name.chars().take(200).collect::<String>(),"job_title":title,"company":company,
        "application_id":ctx["application_id"].as_str().unwrap_or(""),"run_id":id,"source_name":ctx["resume_name"].as_str().unwrap_or(""),
        "created_at":now(),"pages":t["pdf"]["pages"].as_u64().unwrap_or(1),"format":t["format"].as_str().unwrap_or(""),"parse":{},
        "score":t.get("score").cloned().unwrap_or(json!({})),"has_docx":docx.is_some()});
    db.execute(
        "INSERT INTO tailored_resumes VALUES(?,?,?,?,?,?,?,?,?)",
        params![
            artifact,
            owner,
            view,
            pdf,
            docx,
            docx.is_some(),
            text(&t["tex"], 400000),
            t.get("change_record").cloned().unwrap_or(json!({})),
            t.get("records").cloned().unwrap_or(json!([]))
        ],
    )?;
    Ok(Some(artifact))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn db() -> Connection {
        let db = crate::open(":memory:").unwrap();
        crate::auth::init(&db).unwrap();
        crate::jobs::init(&db).unwrap();
        crate::career::init(&db).unwrap();
        crate::account::init(&db).unwrap();
        crate::resumes::init(&db).unwrap();
        for owner in ["alpha", "beta"] {
            db.execute(
                "INSERT INTO accounts(id,username,password) VALUES(?,?,'fixture')",
                params![owner, owner],
            )
            .unwrap();
        }
        db.execute(
            "INSERT INTO resumes VALUES('r','alpha','Fixture',X'00','digest',1,'{}',0,0,'{}')",
            [],
        )
        .unwrap();
        db
    }
    #[test]
    fn duplicate_and_replaced_source_tickets_are_owner_scoped() {
        let db = db();
        let source = json!({"name":"fixture.tex","content":STANDARD.encode("fixture")});
        upload(&db, "alpha", "r", &source).unwrap();
        let ticket = || {
            db.query_row(
                "SELECT ticket FROM resume_source_jobs WHERE resume='r'",
                [],
                |r| r.get::<_, String>(0),
            )
            .unwrap()
        };
        let first = ticket();
        upload(&db, "alpha", "r", &source).unwrap();
        assert_eq!(ticket(), first);
        assert_eq!(
            upload(&db, "beta", "r", &source).unwrap()["error"],
            "Resume not found."
        );
        upload(
            &db,
            "alpha",
            "r",
            &json!({"name":"fixture.tex","content":STANDARD.encode("replacement")}),
        )
        .unwrap();
        assert_ne!(ticket(), first);
        db.execute("UPDATE resume_source_jobs SET state='failed'", [])
            .unwrap();
        let proc = json!({"source":{"status":"failed","id":ticket()}});
        retry(&db, "alpha", "r", "source", &proc).unwrap();
        assert_eq!(
            db.query_row("SELECT state FROM resume_source_jobs", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "queued"
        );
        remove_source(&db, "r").unwrap();
        assert_eq!(
            db.query_row("SELECT count(*) FROM resume_source_jobs", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
    #[test]
    fn finalized_artifact_read_export_check_and_delete() {
        let db = db();
        let r = json!({"context":{"job":{"title":"Engineer","company":"Synthetic"},"resume_name":"Fixture"},"artifacts":{
            "tailor":{"final":true,"pdf":{"pages":1,"content":STANDARD.encode(b"synthetic-pdf")},"format":"latex","tex":"fixture"}}});
        let id = save_tailored(&db, "alpha", "run", &r).unwrap().unwrap();
        assert!(save_tailored(&db, "alpha", "run", &r).unwrap().is_none());
        let view = tailored(&db, "alpha", &id).unwrap();
        assert_eq!(view["pdf"]["name"], "Resume - Synthetic - Engineer.pdf");
        assert_eq!(view["tex"], "fixture");
        assert_eq!(tailored_export(&db, "alpha").unwrap(), vec![view]);
        assert_eq!(
            tailored(&db, "beta", &id).unwrap()["error"],
            "Tailored resume not found."
        );
        artifact(&db, "alpha", "check_tailored_resume", &id).unwrap();
        let mut bootstrap = json!({});
        enrich(&db, "alpha", &mut bootstrap).unwrap();
        assert_eq!(
            bootstrap["tailored_resumes"][0]["parse"]["available"],
            false
        );
        assert_eq!(
            artifact(&db, "beta", "delete_tailored_resume", &id).unwrap()["error"],
            "Tailored resume not found."
        );
        artifact(&db, "alpha", "delete_tailored_resume", &id).unwrap();
        assert!(tailored_export(&db, "alpha").unwrap().is_empty());
    }
}
