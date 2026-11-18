use super::{READ, connections, error, helper, s};
use crate::{account, auth::random_id, career, jobs, now, runs};
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

const SEND: &str = "https://www.googleapis.com/auth/gmail.send";
const CALENDAR: &str = "https://www.googleapis.com/auth/calendar.app.created";
const STATUSES: [&str; 5] = ["Submitted", "Assessment", "Interview", "Offer", "Rejected"];
pub fn google_missing(db: &Connection, owner: &str, step: &str) -> Result<Option<&'static str>> {
    let (scope, message) = match step {
        "send" => (
            SEND,
            "Gmail sending is not connected. Connect it in your email settings to send from Stack, or copy this draft into your own email and cancel the task.",
        ),
        "calendar" => (
            CALENDAR,
            "Google Calendar is not connected. Connect it in your email settings, or add the event yourself and cancel the task.",
        ),
        _ => return Ok(None),
    };
    let allowed = connections(db, owner)?.iter().any(|c| {
        c["state"] == "connected"
            && c["scopes"]
                .as_array()
                .is_some_and(|v| v.contains(&json!(scope)))
    });
    Ok((!allowed).then_some(message))
}
fn current(db: &Connection, owner: &str) -> Result<Option<(String, String)>> {
    if !connections(db, owner)?
        .iter()
        .any(|c| c["tracking"] == true)
    {
        return Ok(None);
    }
    db.query_row(
        "SELECT id,generation FROM google_connections WHERE owner=?",
        [owner],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
}
fn records(db: &Connection, owner: &str, kind: &str) -> Result<Vec<Value>> {
    let mut q = db.prepare_cached(
        "SELECT id,data FROM career_records WHERE owner=? AND kind=? ORDER BY rowid",
    )?;
    q.query_map(params![owner, kind], |r| {
        let mut v: Value = r.get(1)?;
        v["id"] = json!(r.get::<_, String>(0)?);
        Ok(v)
    })?
    .collect()
}
fn apps(db: &Connection, owner: &str) -> Result<Vec<Value>> {
    let mut q=db.prepare_cached("SELECT data FROM job_records WHERE owner=? AND kind='application' AND NOT json_extract(data,'$.demo') ORDER BY rowid")?;
    q.query_map([owner], |r| r.get(0))?.collect()
}
pub fn mail_context(db: &Connection, owner: &str) -> Result<Value> {
    let mut applications = Vec::new();
    for app in apps(db, owner)? {
        let id = s(&app, "id");
        if let Some(job) = jobs::application_job(db, owner, id)? {
            applications
                .push(json!({"id":id,"job":{"title":job["title"],"company":job["company"]}}));
        }
    }
    let contacts: Vec<_> = records(db, owner, "contact")?
        .into_iter()
        .map(|c| json!({"email":c["email"]}))
        .collect();
    let interviews: Vec<_> = records(db, owner, "calendar_interview")?
        .into_iter()
        .map(|c| json!({"key":c["uid"],"application_id":c["application_id"]}))
        .collect();
    let mut threads: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for e in records(db, owner, "mail_event")? {
        if e["ambiguous"] != true
            && !s(&e, "thread_id").is_empty()
            && applications.iter().any(|v| v["id"] == e["application_id"])
        {
            threads
                .entry(s(&e, "thread_id").to_string())
                .or_default()
                .insert(s(&e, "application_id").to_string());
        }
    }
    let threads: BTreeMap<_, _> = threads
        .into_iter()
        .filter_map(|(k, v)| (v.len() == 1).then(|| (k, v.into_iter().next().unwrap())))
        .collect();
    Ok(
        json!({"applications":applications,"contacts":contacts,"interviews":interviews,"threads":threads}),
    )
}
pub fn schedule_sync(db: &Connection, owner: &str, wake_key: &str) -> Result<bool> {
    if current(db, owner)?.is_none() {
        return Ok(false);
    }
    let nonce = if wake_key.is_empty() {
        ((now() / 300.0) as i64).to_string()
    } else {
        format!("push:{wake_key}")
    };
    runs::enqueue(
        db,
        owner,
        "sync",
        "google",
        &mail_context(db, owner)?,
        &nonce,
    )?;
    Ok(true)
}
pub(super) fn start(db: &Connection, owner: &str, args: &Value) -> Result<Value> {
    let Some(since) = args["since"].as_f64().filter(|v| (0.0..=now()).contains(v)) else {
        return Ok(error("Choose a search start date in the past."));
    };
    let Some((id, generation)) = current(db, owner)? else {
        return Ok(error("Connect Gmail before starting a scan."));
    };
    let active:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM agent_runs WHERE owner=? AND json_extract(data,'$.kind')='sync' AND json_extract(data,'$.context.manual_scan') AND json_extract(data,'$.status') IN ('queued','running'))",[owner],|r|r.get(0))?;
    if !active {
        let mut ctx = mail_context(db, owner)?;
        let known: Vec<_> = records(db, owner, "mail_event")?
            .into_iter()
            .filter(|e| {
                (!s(e, "application_id").is_empty() && e["ambiguous"] != true)
                    || e["dismissed"] == true
            })
            .map(|e| e["key"].clone())
            .collect();
        ctx.as_object_mut().unwrap().extend(json!({"manual_scan":true,"since":since as i64,"until":now(),"scan_cursor":"","scanned":0,
            "imported":0,"updated":0,"to_review":0,"connection_id":id,"connection_generation":generation,"known_messages":known}).as_object().unwrap().clone());
        runs::enqueue(db, owner, "sync", "google", &ctx, &random_id())?;
    }
    super::scan_status(db, owner)
}
pub(super) fn latest(db: &Connection, owner: &str) -> Result<Value> {
    let id=db.query_row("SELECT id FROM agent_runs WHERE owner=? AND json_extract(data,'$.kind')='sync' AND json_extract(data,'$.context.manual_scan') ORDER BY created DESC LIMIT 1",[owner],|r|r.get::<_,String>(0)).optional()?;
    match id {
        Some(id) => runs::view(db, owner, &id, false),
        None => Ok(json!({})),
    }
}
pub fn worker_connection(db: &mut Connection, owner: &str, id: &str, lease: &str) -> Result<Value> {
    fn check(
        db: &Connection,
        owner: &str,
        id: &str,
        lease: &str,
    ) -> Result<std::result::Result<(String, String, Value, String), Value>> {
        let Some(run) = runs::leased(db, owner, id, lease)? else {
            return Ok(Err(error("Task lease expired or cancelled.")));
        };
        let step = run["index"]
            .as_u64()
            .and_then(|i| run["steps"][i as usize].as_str())
            .unwrap_or("");
        let scope = match step {
            "send" => SEND,
            "calendar" => CALENDAR,
            "sync" => READ,
            _ => return Ok(Err(error("This step cannot access Google."))),
        };
        let row=db.query_row("SELECT sealed,generation,checkpoint,calendar_id,id FROM google_connections WHERE owner=? AND state='connected' AND EXISTS(SELECT 1 FROM json_each(scopes) WHERE value=?)",
            params![owner,scope],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?))).optional()?;
        let Some((sealed, generation, checkpoint, calendar, id)) = row else {
            return Ok(Err(error(
                "Connect Google with the required email permission.",
            )));
        };
        if step == "sync" {
            if current(db, owner)?.is_none() {
                return Ok(Err(error("Connect Gmail to turn on application tracking.")));
            }
            let ctx = &run["context"];
            if ctx["manual_scan"] == true
                && (ctx["connection_id"] != id || ctx["connection_generation"] != generation)
            {
                return Ok(Err(error(
                    "Gmail changed during this scan. Start a new scan.",
                )));
            }
        } else {
            let action = if step == "send" {
                "send_email"
            } else {
                "calendar_write"
            };
            let p = account::policy(db, owner)?;
            if p["enabled"] != true
                || p["expires_at"].as_f64().unwrap_or(0.0) <= now()
                || !p["actions"]
                    .as_array()
                    .is_some_and(|v| v.contains(&json!(action)))
            {
                return Ok(Err(error(&format!(
                    "Enable an unexpired standing permission for {}.",
                    action.replace('_', " ")
                ))));
            }
        }
        let checkpoint = if checkpoint.is_empty() {
            json!({})
        } else {
            serde_json::from_str(&checkpoint).map_err(|_| rusqlite::Error::InvalidQuery)?
        };
        Ok(Ok((sealed, generation, checkpoint, calendar)))
    }
    let snapshot = db.transaction()?;
    let (sealed, generation, _, _) = match check(&snapshot, owner, id, lease)? {
        Ok(r) => r,
        Err(e) => return Ok(e),
    };
    snapshot.commit()?;
    let refreshed = helper(&json!({"op":"refresh","sealed":sealed}))?;
    if refreshed.get("error").is_some() {
        return Ok(refreshed);
    }
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let (old, new_generation, checkpoint, calendar) = match check(&tx, owner, id, lease)? {
        Ok(r) => r,
        Err(e) => return Ok(e),
    };
    if new_generation != generation || old != sealed {
        return Ok(error("Google connection changed. Retry the task."));
    }
    tx.execute(
        "UPDATE google_connections SET sealed=?,updated=? WHERE owner=? AND generation=?",
        params![refreshed["sealed"].as_str(), now(), owner, generation],
    )?;
    tx.commit()?;
    Ok(json!({"tokens":refreshed["tokens"],"checkpoint":checkpoint,"calendar_id":calendar}))
}
pub(super) fn store_event(
    db: &Connection,
    owner: &str,
    kind: &str,
    id: &str,
    data: &Value,
    at: f64,
) -> Result<()> {
    db.execute("INSERT INTO career_records(owner,kind,id,data,updated) VALUES(?,?,?,?,?) ON CONFLICT(owner,kind,id) DO UPDATE SET data=excluded.data,updated=excluded.updated",
        params![owner,kind,id,data,at])?;
    Ok(())
}
fn application_from_event(
    db: &Connection,
    owner: &str,
    event: &Value,
) -> Result<Option<(String, bool)>> {
    if !s(event, "application_id").is_empty() {
        let id = s(event, "application_id");
        return Ok(jobs::application_job(db, owner, id)?.map(|_| (id.to_string(), false)));
    }
    let d = &event["discovery"];
    if d["confirmed"] != true {
        return Ok(None);
    }
    let owned = apps(db, owner)?;
    let candidates=owned.iter().map(|v|json!({"id":v["id"],"company":v["job"]["company"],"title":v["job"]["title"],"reference":v["job"]["gmail_reference"]})).collect::<Vec<_>>();
    let matched = helper(
        &json!({"op":"match_application","items":candidates,"discovery":d,"thread":s(event,"thread_id")}),
    )?;
    if matched.get("error").is_some() {
        return Err(rusqlite::Error::InvalidQuery);
    }
    if matched["conflict"] == true {
        return Ok(None);
    }
    let at = event["at"].as_f64().unwrap_or(0.0);
    if let Some(id) = matched["id"].as_str() {
        let mut app = owned
            .into_iter()
            .find(|v| v["id"] == id)
            .ok_or(rusqlite::Error::InvalidQuery)?;
        if app["job"]["gmail_import"] == true {
            app["created_at"] = json!(app["created_at"].as_f64().unwrap_or(at).min(at));
        }
        if !s(d, "reference").is_empty() {
            app["job"]["gmail_reference"] = d["reference"].clone();
        }
        db.execute(
            "UPDATE job_records SET data=? WHERE owner=? AND kind='application' AND key=?",
            params![app, owner, id],
        )?;
        return Ok(Some((id.to_string(), false)));
    }
    let job = &matched["snapshot"];
    let id = random_id();
    let app = json!({"id":id,"job_id":job["id"],"job":job,"demo":false,"created_at":at,"notes":"","status":"Ready to apply","resume_id":"","history":[]});
    db.execute(
        "INSERT INTO job_records VALUES(?,'application',?,?)",
        params![owner, id, app],
    )?;
    Ok(Some((id, true)))
}
fn apply(db: &Connection, owner: &str, e: &Value) -> Result<()> {
    if e["ambiguous"] == true {
        return Ok(());
    }
    let aid = s(e, "application_id");
    let at = e["at"].as_f64().unwrap_or(0.0);
    if let Some(cal) = e["calendar"].as_object().filter(|v| !v.is_empty()) {
        let event = json!(cal);
        let uid = s(&event, "uid");
        let old=db.query_row("SELECT id,data,updated FROM career_records WHERE owner=? AND kind='calendar_interview' AND json_extract(data,'$.uid')=?",
            params![owner,uid],|r|Ok((r.get::<_,String>(0)?,r.get::<_,Value>(1)?,r.get::<_,f64>(2)?))).optional()?;
        let (id, mut view, when) = match old {
            Some((id, v, old_at)) if old_at >= at => (id, v, old_at),
            Some((id, v, _)) => {
                let mut ev = event.clone();
                ev["application_id"] = v["application_id"].clone();
                (id, ev, at)
            }
            None => {
                let mut v = event.clone();
                v["application_id"] = json!(aid);
                (random_id(), v, at)
            }
        };
        let mut source = view.clone();
        source
            .as_object_mut()
            .unwrap()
            .retain(|k, _| k != "application_id" && k != "study_plan");
        let plan = career::dispatch(
            db,
            owner,
            "prep_for_application",
            &json!({"application_id":aid}),
        )?
        .ok_or(rusqlite::Error::InvalidQuery)?;
        view["study_plan"] = plan["plan"].clone();
        store_event(db, owner, "calendar_interview", &id, &view, when)?;
        runs::enqueue(
            db,
            owner,
            "calendar",
            &id,
            &json!({"event":source}),
            &when.to_string(),
        )?;
    }
    let status = s(e, "status");
    if !STATUSES.contains(&status) {
        return Ok(());
    }
    let row=db.query_row("SELECT data FROM job_records WHERE owner=? AND kind='application' AND key=? AND NOT json_extract(data,'$.demo')",params![owner,aid],|r|r.get::<_,Value>(0)).optional()?;
    let Some(mut app) = row else {
        return Ok(());
    };
    let mut history = app["history"].as_array().cloned().unwrap_or_default();
    if !history.iter().any(|h| h["message_id"] == e["key"]) {
        history.push(json!({"status":status,"at":at,"source":"Gmail","evidence":e["quote"],"message_id":e["key"]}));
        history.sort_by(|a, b| {
            a["at"]
                .as_f64()
                .unwrap_or(0.0)
                .total_cmp(&b["at"].as_f64().unwrap_or(0.0))
        });
    }
    let last_status = app["status_at"].as_f64().unwrap_or_else(|| {
        history
            .iter()
            .filter(|h| h["source"] == "User confirmed")
            .filter_map(|h| h["at"].as_f64())
            .fold(0.0, f64::max)
    });
    if at > last_status
        && !(status == "Submitted"
            && ["Assessment", "Interview", "Offer", "Rejected"].contains(&s(&app, "status")))
    {
        app["status"] = json!(status);
        app["status_at"] = json!(at);
    }
    app["history"] = json!(history);
    db.execute(
        "UPDATE job_records SET data=? WHERE owner=? AND kind='application' AND key=?",
        params![app, owner, aid],
    )?;
    Ok(())
}
pub(super) fn resolve(db: &Connection, owner: &str, a: &Value) -> Result<Value> {
    let status = s(a, "status");
    if !STATUSES.contains(&status) {
        return Ok(error("Choose the status confirmed by this message."));
    }
    let id = s(a, "id");
    let row = db
        .query_row(
            "SELECT data FROM career_records WHERE owner=? AND kind='mail_event' AND id=?",
            params![owner, id],
            |r| r.get::<_, Value>(0),
        )
        .optional()?;
    let Some(mut e) = row else {
        return Ok(error("This message was not found."));
    };
    if e["resolved"] != true {
        let mut aid = s(a, "application_id").to_string();
        if aid.is_empty() && e["discovery"].is_object() {
            let company = s(a, "company").trim();
            let title = s(a, "title").trim();
            if company.is_empty()
                || title.is_empty()
                || company.chars().count() > 200
                || title.chars().count() > 300
            {
                return Ok(error("Enter the company and job title from this message."));
            }
            let mut candidate = e.clone();
            candidate["discovery"]["company"] = json!(company);
            candidate["discovery"]["title"] = json!(title);
            candidate["discovery"]["confirmed"] = json!(true);
            let Some((found, _)) = application_from_event(db, owner, &candidate)? else {
                return Ok(error(
                    "Choose which existing application this message belongs to.",
                ));
            };
            aid = found;
        }
        if jobs::application_job(db, owner, &aid)?.is_none() {
            return Ok(error("This application was not found."));
        }
        e["application_id"] = json!(aid);
        e["status"] = json!(status);
        e["ambiguous"] = json!(false);
        e["resolved"] = json!(true);
        db.execute(
            "UPDATE career_records SET data=? WHERE owner=? AND kind='mail_event' AND id=?",
            params![e, owner, id],
        )?;
        apply(db, owner, &e)?;
    }
    account::dispatch(db, owner, "agent_events", &json!({}))?.ok_or(rusqlite::Error::InvalidQuery)
}
pub fn project(db: &Connection, owner: &str, id: &str, run: &mut Value) -> Result<()> {
    if run["projected"] == true || run["status"] != "completed" {
        return Ok(());
    }
    let artifact = run["artifacts"][s(run, "kind")].clone();
    if run["kind"] == "calendar" {
        if let Some(calendar) = artifact["calendar_id"].as_str().filter(|v| !v.is_empty()) {
            db.execute(
                "UPDATE google_connections SET calendar_id=? WHERE owner=?",
                params![calendar, owner],
            )?;
        }
        db.execute("INSERT INTO google_calendar_receipts(owner,interview,receipt) VALUES(?,?,?) ON CONFLICT(owner,interview) DO UPDATE SET receipt=excluded.receipt",params![owner,s(run,"target_id"),s(&artifact,"receipt")])?;
        run["projected"] = json!(true);
        return Ok(());
    }
    if run["kind"] != "sync" {
        return Ok(());
    }
    let manual = run["context"]["manual_scan"] == true;
    if manual {
        let connection = current(db, owner)?;
        if !connection.is_some_and(|(id, gen_id)| {
            run["context"]["connection_id"] == id
                && run["context"]["connection_generation"] == gen_id
        }) {
            run["status"] = json!("cancelled");
            run["message"] = json!("Gmail changed during this scan. Start a new scan.");
            return Ok(());
        }
    }
    let events = if manual {
        let checked = helper(
            &json!({"op":"validate_page","page":artifact,"context":{"since":run["context"]["since"],"until":run["context"]["until"]}}),
        )?;
        if checked.get("error").is_some() {
            run["status"] = json!("failed");
            run["index"] = json!(0);
            run["message"] = checked["error"].clone();
            return Ok(());
        }
        checked["events"].as_array().cloned().unwrap_or_default()
    } else {
        db.execute(
            "UPDATE google_connections SET checkpoint=? WHERE owner=?",
            params![
                artifact
                    .get("checkpoint")
                    .cloned()
                    .unwrap_or(json!({}))
                    .to_string(),
                owner
            ],
        )?;
        artifact["events"].as_array().cloned().unwrap_or_default()
    };
    for mut event in events {
        let earlier=db.query_row("SELECT id,data FROM career_records WHERE owner=? AND kind='mail_event' AND json_extract(data,'$.key')=?",params![owner,s(&event,"key")],|r|Ok((r.get::<_,String>(0)?,r.get::<_,Value>(1)?))).optional()?;
        if earlier
            .as_ref()
            .is_some_and(|(_, e)| !manual || e["ambiguous"] != true)
        {
            continue;
        }
        if manual {
            event["scan_id"] = json!(id);
            let field = if let Some((aid, created)) = application_from_event(db, owner, &event)? {
                event["application_id"] = json!(aid);
                event["ambiguous"] = json!(false);
                if created { "imported" } else { "updated" }
            } else {
                event["ambiguous"] = json!(true);
                "to_review"
            };
            run["context"][field] = json!(run["context"][field].as_i64().unwrap_or(0) + 1);
        } else if let Some(sender) = event["sender"].as_str() {
            db.execute("UPDATE career_records SET data=json_set(data,'$.stopped',json('true'),'$.next_at',0) WHERE owner=? AND kind='contact' AND json_extract(data,'$.email')=?",params![owner,sender])?;
        }
        if let Some((existing, _)) = earlier {
            db.execute(
                "UPDATE career_records SET data=? WHERE owner=? AND kind='mail_event' AND id=?",
                params![event, owner, existing],
            )?;
        } else {
            store_event(db, owner, "mail_event", &random_id(), &event, now())?;
        }
        apply(db, owner, &event)?;
    }
    run["projected"] = json!(true);
    if manual {
        let done = artifact["done"] == true;
        let ctx = &mut run["context"];
        ctx["scanned"] =
            json!(ctx["scanned"].as_i64().unwrap_or(0) + artifact["scanned"].as_i64().unwrap_or(0));
        ctx["scan_cursor"] = artifact["scan_cursor"].clone();
        ctx.as_object_mut()
            .unwrap()
            .extend(mail_context(db, owner)?.as_object().unwrap().clone());
        run["projected"] = json!(done);
        if !done {
            run["index"] = json!(0);
            run["status"] = json!("queued");
            run["attempts"] = json!(0);
            run["next_at"] = json!(0.0);
        }
        run["message"] = json!(if done {
            "Scan complete"
        } else {
            "Scanning email"
        });
    }
    Ok(())
}
