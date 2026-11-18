use crate::{account, auth, career, jobs, now, providers, score_docs};
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

#[path = "run_worker.rs"]
mod runtime;
pub use runtime::{leased, worker, worker_authorized, worker_handles};
#[path = "run_targets.rs"]
mod targets;

pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS agent_runs(
        id TEXT PRIMARY KEY,owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        data TEXT NOT NULL CHECK(json_valid(data)),created REAL NOT NULL,updated REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS runs_owner ON agent_runs(owner,created DESC);
        CREATE INDEX IF NOT EXISTS runnable_due ON agent_runs(COALESCE(json_extract(data,'$.next_at'),0),created) WHERE json_extract(data,'$.status') IN ('queued','running');
        CREATE UNIQUE INDEX IF NOT EXISTS runs_key ON agent_runs(owner,json_extract(data,'$.key')) WHERE COALESCE(json_extract(data,'$.stopped_for_model_switch'),0)=0;
        CREATE TABLE IF NOT EXISTS run_history(id TEXT PRIMARY KEY,run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,kind TEXT NOT NULL,data TEXT NOT NULL,at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS run_history_lookup ON run_history(run_id,kind,at);
        CREATE TABLE IF NOT EXISTS run_action_usage(day INTEGER NOT NULL, action TEXT NOT NULL,scope TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(day,action,scope));")
}
fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or_default()
}
fn err(s: &str) -> Value {
    json!({"error":s})
}
fn helper(args: Value) -> Result<Value> {
    score_docs::helper(
        &args,
        include_str!("runs.py"),
        "Stack workflow contracts are unavailable.",
    )
}
fn step(r: &Value) -> String {
    let steps = r["steps"].as_array();
    steps
        .and_then(|a| {
            a.get((r["index"].as_u64().unwrap_or(0) as usize).min(a.len().saturating_sub(1)))
        })
        .and_then(Value::as_str)
        .unwrap_or_default()
        .into()
}
fn status(r: &mut Value, state: &str, message: &str) {
    r["status"] = json!(state);
    r["message"] = json!(message);
}
fn terminal(r: &Value) -> bool {
    matches!(s(r, "status"), "cancelled" | "failed" | "completed")
}
fn attention(r: &Value) -> bool {
    matches!(
        s(r, "status"),
        "needs_input" | "blocked" | "uncertain" | "review" | "paused"
    ) || (r["status"] == "failed" && r["dismissed"] != true)
}
fn load(db: &Connection, owner: &str, id: &str) -> Result<Option<Value>> {
    db.query_row(
        "SELECT data FROM agent_runs WHERE id=? AND owner=?",
        params![id, owner],
        |r| r.get(0),
    )
    .optional()
}
fn history(db: &Connection, id: &str, kind: &str) -> Result<Vec<Value>> {
    let mut q =
        db.prepare("SELECT data FROM run_history WHERE run_id=? AND kind=? ORDER BY at,rowid")?;
    q.query_map(params![id, kind], |r| r.get(0))?.collect()
}
fn record(db: &Connection, id: &str, kind: &str, mut data: Value) -> Result<()> {
    let key = auth::random_id();
    let at = now();
    data["id"] = json!(key);
    data["at"] = json!(at);
    db.execute(
        "INSERT INTO run_history VALUES(?,?,?,?,?)",
        params![key, id, kind, data, at],
    )?;
    Ok(())
}
fn trace(db: &Connection, id: &str, r: &Value, event: &str, data: Value) -> Result<()> {
    let clean = helper(
        json!({"op":"trace","data":data,"stage_context":event=="stage_start","stage_result":if event=="stage_end"{step(r)}else{String::new()},"model_event":matches!(event,"model_request"|"model_response"|"model_validation"|"provider_fallback")}),
    )?;
    record(
        db,
        id,
        "trace",
        json!({"attempt":r["trace_attempt"],"step":step(r),"event":event,"data":clean}),
    )
}
pub fn save(db: &Connection, owner: &str, id: &str, r: &mut Value) -> Result<()> {
    let display = helper(json!({"op":"display","run":r}))?;
    if !display["presentation"].is_object() {
        return Err(rusqlite::Error::InvalidQuery);
    }
    r["presentation"] = display["presentation"].clone();
    r["output_version"] = display["output_version"].clone();
    r["updated_at"] = json!(now());
    let n = db.execute(
        "UPDATE agent_runs SET data=?,updated=? WHERE owner=? AND id=?",
        params![&*r, r["updated_at"].as_f64(), owner, id],
    )?;
    if n != 1 {
        return Err(rusqlite::Error::QueryReturnedNoRows);
    }
    providers::notify(db, owner, id, r)?;
    Ok(())
}
fn render(db: &Connection, id: &str, r: &Value, detail: bool) -> Result<Value> {
    let mut v = r["presentation"].clone();
    for k in [
        "kind",
        "target_id",
        "status",
        "message",
        "created_at",
        "updated_at",
        "cost_cents",
        "provider",
        "subscription_calls",
        "dismissed",
        "workflow_version",
        "upgrade_pending",
    ] {
        v[k] = r[k].clone();
    }
    let current = step(r);
    v["id"] = json!(id);
    v["step"] = json!(current);
    v["attention"] = json!(attention(r));
    v["browser"] = json!({"supported":matches!(s(r,"kind"),"linkedin"|"autofill"),"available":r["index"]==0 && (r["kind"]=="linkedin" || (r["kind"]=="autofill" && !terminal(r)))});
    v["needs_resume_review"] = json!(
        r["status"] == "needs_input"
            && current == "tailor"
            && !matches!(
                s(&r["context"], "resume_format"),
                "records" | "latex" | "builtin"
            )
    );
    v["has_requests"] = json!(r["requests"].as_array().is_some_and(|a| !a.is_empty()));
    v["retry_at"] = if r["status"] == "queued" && r["attempts"].as_i64().unwrap_or(0) > 0 {
        r["next_at"].clone()
    } else {
        json!(0.0)
    };
    if r["status"] == "review" {
        v["review"] = r["review"].clone();
    }
    if r["stopped_for_model_switch"] == true {
        v["stopped_for_model_switch"] = json!(true);
    }
    if r["context"]["manual_scan"] == true {
        let mut scan = json!({});
        for k in [
            "since",
            "until",
            "scanned",
            "imported",
            "updated",
            "to_review",
        ] {
            scan[k] = r["context"].get(k).cloned().unwrap_or(json!(0));
        }
        v["scan"] = scan;
    }
    if detail {
        for k in ["requests", "artifacts", "output_version"] {
            v[k] = r[k].clone();
        }
        for k in ["resume_id", "resume_name"] {
            v[k] = json!(s(&r["context"], k));
        }
        let items = history(db, id, "feedback")?
            .into_iter()
            .rev()
            .take(50)
            .map(|mut f| {
                f.as_object_mut().unwrap().remove("snapshot");
                f.as_object_mut().unwrap().remove("run_id");
                f
            })
            .collect::<Vec<_>>();
        v["feedback"] = json!(items);
    }
    Ok(v)
}
pub fn view(db: &Connection, owner: &str, id: &str, detail: bool) -> Result<Value> {
    match load(db, owner, id)? {
        Some(r) => render(db, id, &r, detail),
        None => Ok(err("Run not found.")),
    }
}
pub fn detail(db: &Connection, owner: &str, id: &str) -> Result<Value> {
    view(db, owner, id, true)
}
pub fn enqueue(
    db: &Connection,
    owner: &str,
    kind: &str,
    target: &str,
    context: &Value,
    nonce: &str,
) -> Result<Value> {
    let selection = account::selection(db, owner)?;
    let input = helper(
        json!({"op":"enqueue","kind":kind,"target":target,"context":context,"facts":account::facts(db,owner)?,"nonce":nonce,"selection":selection}),
    )?;
    if input.get("error").is_some() {
        return Ok(input);
    }
    let key = s(&input, "key");
    let old:Option<String>=db.query_row("SELECT id FROM agent_runs WHERE owner=? AND json_extract(data,'$.key')=? AND COALESCE(json_extract(data,'$.stopped_for_model_switch'),0)=0",params![owner,key],|r|r.get(0)).optional()?;
    if let Some(id) = old {
        return detail(db, owner, &id);
    }
    let id = auth::random_id();
    let at = now();
    let mut r = json!({"kind":kind,"target_id":target,"context":input["context"],"steps":input["steps"],"key":key,"created_at":at,"updated_at":at,
        "index":0,"status":"queued","message":"Queued","model_selection":selection,"requests":[],"artifacts":{},"cost_cents":0,"provider":"",
        "subscription_calls":0,"dismissed":false,"workflow_version":2,"upgrade_pending":false,"approvals":{},"review":{},"lease":"","lease_until":0.0,
        "attempts":0,"next_at":0.0,"trace_attempt":"","requested_model":"","projected":false});
    db.execute(
        "INSERT INTO agent_runs(id,owner,data,created,updated) VALUES(?,?,?,?,?)",
        params![id, owner, r, at, at],
    )?;
    save(db, owner, &id, &mut r)?;
    render(db, &id, &r, true)
}
fn rows(db: &Connection, owner: &str) -> Result<Vec<(String, Value)>> {
    let mut q = db.prepare("SELECT id,data FROM agent_runs WHERE owner=? ORDER BY created DESC")?;
    q.query_map([owner], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect()
}
pub fn summary(db: &Connection, owner: &str) -> Result<Value> {
    let all = rows(db, owner)?;
    let count = all.iter().filter(|(_, r)| attention(r)).count();
    let active = all
        .iter()
        .filter(|(_, r)| matches!(s(r, "status"), "queued" | "running" | "waiting"))
        .count();
    let mut out = vec![];
    for (id, r) in all
        .iter()
        .filter(|(_, r)| attention(r))
        .chain(all.iter().take(30).filter(|(_, r)| !attention(r)))
    {
        out.push(render(db, id, r, false)?);
    }
    Ok(json!({"needs_input":count,"attention":count,"active":active,"runs":out}))
}
pub fn export(db: &Connection, owner: &str) -> Result<Value> {
    let mut runs = vec![];
    let mut feedback = vec![];
    let mut logs = vec![];
    for (id, r) in rows(db, owner)? {
        let mut v = render(db, &id, &r, true)?;
        v["trace"] = json!(history(db, &id, "trace")?);
        runs.push(v);
        feedback.extend(history(db, &id, "feedback")?);
        logs.extend(history(db, &id, "model_log")?);
    }
    Ok(json!({"runs":runs,"feedback":feedback,"model_logs":logs}))
}
pub fn handles(m: &str) -> bool {
    matches!(
        m,
        "agent_start"
            | "agent_continue_tailoring"
            | "linkedin_pdf_review"
            | "agent_run"
            | "agent_approve"
            | "agent_respond"
            | "agent_retry"
            | "agent_reconcile"
            | "agent_cancel"
            | "agent_dismiss"
            | "agent_feedback"
            | "agent_traces"
            | "agent_model_logs"
    )
}
pub fn dispatch(db: &Connection, owner: &str, m: &str, a: &Value) -> Result<Option<Value>> {
    if !handles(m) {
        return Ok(None);
    }
    if m == "linkedin_pdf_review" {
        return targets::linkedin_pdf(db, owner, a).map(Some);
    }
    if m == "agent_start" {
        return targets::start(db, owner, s(a, "kind"), s(a, "target_id")).map(Some);
    }
    let id = s(a, "id");
    let run = load(db, owner, id)?;
    if m == "agent_respond"
        && run.as_ref().is_none_or(|r| r["kind"] != "linkedin")
        && !a["values"].is_array()
    {
        return Ok(Some(err("Save at most 250 facts at a time.")));
    }
    let Some(mut r) = run else {
        return Ok(Some(err(match m {
            "agent_continue_tailoring" => "Task not found.",
            "agent_approve" => "This task is not waiting for your review.",
            "agent_model_logs" => "Task not found.",
            "agent_respond" => "This run is not waiting for input.",
            "agent_reconcile" => "This run does not need reconciliation.",
            _ => "Run not found.",
        })));
    };
    let current = step(&r);
    let reply = match m {
        "agent_run" => return render(db, id, &r, true).map(Some),
        "agent_traces" => return Ok(Some(json!({"events":history(db,id,"trace")?}))),
        "agent_model_logs" => return Ok(Some(json!({"attempts":history(db,id,"model_log")?}))),
        "agent_cancel" if terminal(&r) => return render(db, id, &r, true).map(Some),
        "agent_cancel" => {
            if r["intent"].is_object() {
                status(
                    &mut r,
                    "uncertain",
                    "Cancellation requested; reconcile the dispatched action.",
                )
            } else {
                status(&mut r, "cancelled", "Cancelled")
            }
            r["lease"] = json!("");
            None
        }
        "agent_dismiss" if !terminal(&r) => {
            Some(err("Cancel or finish this task before dismissing it."))
        }
        "agent_dismiss" => {
            r["dismissed"] = json!(true);
            None
        }
        "agent_retry"
            if !matches!(s(&r, "status"), "failed" | "blocked") || r["kind"] == "live" =>
        {
            Some(err("Only a failed or paused task can be retried."))
        }
        "agent_retry" if r["intent"].is_object() => Some(err(
            "An action may have been dispatched. Reconcile it first.",
        )),
        "agent_retry" => {
            status(&mut r, "queued", "Retry requested");
            r["attempts"] = json!(0);
            r["next_at"] = json!(0);
            r["dismissed"] = json!(false);
            r["lease"] = json!("");
            None
        }
        "agent_continue_tailoring" => targets::continue_tailoring(db, owner, &mut r, a)?,
        "agent_respond" => targets::respond(db, owner, &mut r, a)?,
        "agent_reconcile"
            if !matches!(s(a, "outcome"), "confirmed" | "not_sent")
                || s(a, "evidence").trim().chars().count() < 10 =>
        {
            Some(err(
                "Provide the confirmation or evidence that nothing was sent.",
            ))
        }
        "agent_reconcile" if r["status"] != "uncertain" => {
            Some(err("This run does not need reconciliation."))
        }
        "agent_reconcile" => {
            if a["outcome"] == "confirmed" {
                r["artifacts"][&current] = json!({"receipt":a["evidence"],"user_confirmed":true});
                runtime::advance(&mut r);
            } else {
                status(&mut r, "queued", "Reconciled by you");
            }
            record(
                db,
                id,
                "receipt",
                json!({"outcome":a["outcome"],"evidence":a["evidence"],"step":current}),
            )?;
            r["message"] = json!("Reconciled by you");
            r["intent"] = Value::Null;
            r["next_at"] = json!(0);
            r["attempts"] = json!(0);
            None
        }
        "agent_approve" if r["status"] != "review" => {
            Some(err("This task is not waiting for your review."))
        }
        "agent_approve"
            if s(a, "step") != current
                || r["review"]["step"] != current
                || r["review"]["hash"] != a["review_hash"] =>
        {
            Some(err(
                "This review changed. Look it over again before approving.",
            ))
        }
        "agent_approve" => {
            if let Some(missing) = providers::google_missing(db, owner, &current)? {
                return Ok(Some(err(missing)));
            }
            let approved =
                helper(json!({"op":"approve","run":r,"step":current,"edits":a["edits"]}))?;
            if approved["error"].is_string() {
                return Ok(Some(approved));
            }
            r["artifacts"] = approved["artifacts"].clone();
            r["approvals"][&current] = approved["review"]["hash"].clone();
            r["review"] = json!({});
            r["attempts"] = json!(0);
            r["next_at"] = json!(0);
            status(&mut r, "queued", "Approved by you. Continuing.");
            None
        }
        "agent_feedback" => return feedback(db, id, &r, a).map(Some),
        _ => return Ok(None),
    };
    if let Some(error) = reply {
        return Ok(Some(error));
    }
    save(db, owner, id, &mut r)?;
    render(db, id, &r, true).map(Some)
}
fn feedback(db: &Connection, id: &str, r: &Value, a: &Value) -> Result<Value> {
    let note = s(a, "note").trim();
    if !matches!(s(a, "rating"), "good" | "mixed" | "bad")
        || note.is_empty()
        || note.chars().count() > 4000
    {
        return Ok(err(
            "Choose a rating and enter feedback (1-4,000 characters).",
        ));
    }
    if r["artifacts"].as_object().is_none_or(|v| v.is_empty())
        || a["output_version"] != r["output_version"]
    {
        return Ok(err(
            "The output changed. Refresh the task before leaving feedback.",
        ));
    }
    let clean = helper(
        json!({"op":"trace","data":{"note":note,"snapshot":{"artifacts":r["artifacts"],"provider":r["provider"],"requested_model":r["requested_model"],"attempt":r["trace_attempt"]}}}),
    )?;
    if !history(db, id, "feedback")?.iter().any(|f| {
        f["output_version"] == a["output_version"]
            && f["rating"] == a["rating"]
            && f["note"] == clean["note"]
    }) {
        record(
            db,
            id,
            "feedback",
            json!({"run_id":id,"output_version":a["output_version"],"rating":a["rating"],"note":clean["note"],"snapshot":clean["snapshot"]}),
        )?;
    }
    render(db, id, r, true)
}
