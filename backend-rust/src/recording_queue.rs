use super::*;

const STAGES: [&str; 3] = ["decoding", "loading", "transcribing"];
const EXPIRED: &str = "Transcription expired or was cancelled.";
const TIMINGS: [&str; 3] = ["decode_ms", "load_ms", "transcribe_ms"];

pub(super) fn full(db: &Connection, owner: &str) -> Result<bool> {
    db.query_row("SELECT count(*)>=100 OR count(*) FILTER(WHERE owner=?)>=3 FROM recordings WHERE json_extract(data,'$.status') NOT IN ('completed','failed','cancelled')",[owner],|r|r.get(0))
}
fn clear(db: &Connection, id: &str) -> Result<()> {
    db.execute("DELETE FROM recording_leases WHERE id=?", [id])?;
    Ok(())
}
pub(super) fn action(
    db: &Connection,
    owner: &str,
    id: &str,
    data: &mut Value,
    action: &str,
) -> Result<Value> {
    let current = string(data, "status");
    if action == "cancel" {
        if !matches!(current, "completed" | "failed" | "cancelled") {
            data["status"] = json!("cancelled");
            data["error"] = json!("Transcription cancelled. The audio is saved; retry when ready.");
        }
    } else {
        if !matches!(current, "failed" | "cancelled") {
            return Ok(err(
                "Only failed or cancelled transcriptions can be retried.",
            ));
        }
        if full(db, owner)? {
            return Ok(err("The transcription queue is full. Retry later."));
        }
        data["status"] = json!("queued");
        data["attempts"] = json!(0);
        data["stage_at"] = json!(crate::now());
        data["percent"] = Value::Null;
        data["error"] = json!("");
        data["model"] = json!("whisper.cpp/base.en");
        for k in TIMINGS.into_iter().chain(["queue_ms"]) {
            data["timings"][k] = json!(0)
        }
    }
    clear(db, id)?;
    update(db, owner, id, data)?;
    Ok(data.clone())
}
fn claim(db: &Connection) -> Result<Value> {
    let at = crate::now();
    let busy: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM recording_leases WHERE deadline>?)",
        [at],
        |r| r.get(0),
    )?;
    if busy {
        return Ok(json!({"idle":true}));
    }
    let mut q=db.prepare("SELECT r.id,r.owner,r.data FROM recordings r LEFT JOIN recording_leases l ON l.id=r.id
        WHERE json_extract(r.data,'$.status')='queued' OR (json_extract(r.data,'$.status') IN ('decoding','loading','transcribing') AND COALESCE(l.deadline,0)<=?)
        ORDER BY r.created,r.rowid LIMIT 100")?;
    let candidates = q
        .query_map([at], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Value>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>>>()?;
    drop(q);
    for (id, owner, mut data) in candidates {
        let attempts = data["attempts"].as_u64().unwrap_or(0);
        if attempts >= 3 {
            data["status"] = json!("failed");
            data["error"] = json!(
                "Transcription was interrupted three times. The recording is saved; retry when the worker is available."
            );
            clear(db, &id)?;
            update(db, &owner, &id, &data)?;
            continue;
        }
        let waited = (at - data["stage_at"].as_f64().unwrap_or(at)).max(0.) * 1000.;
        data["status"] = json!("decoding");
        data["attempts"] = json!(attempts + 1);
        data["stage_at"] = json!(at);
        data["percent"] = Value::Null;
        data["error"] = json!("");
        data["timings"]["queue_ms"] = json!(waited);
        for k in TIMINGS {
            data["timings"][k] = json!(0);
        }
        let lease = crate::auth::random_id();
        let deadline = at + 30.;
        db.execute("INSERT INTO recording_leases VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET lease=excluded.lease,deadline=excluded.deadline",params![id,lease,deadline])?;
        update(db, &owner, &id, &data)?;
        let raw: Vec<u8> = db.query_row(
            "SELECT audio FROM recordings WHERE id=? AND owner=?",
            params![id, owner],
            |r| r.get(0),
        )?;
        data["owner"] = json!(owner);
        data["lease"] = json!(lease);
        data["lease_until"] = json!(deadline);
        data["content"] = json!(STANDARD.encode(raw));
        return Ok(data);
    }
    Ok(json!({"idle":true}))
}
fn timings(data: &mut Value, values: &Value) {
    for k in TIMINGS {
        if let Some(n) = values[k].as_f64().filter(|n| n.is_finite()) {
            data["timings"][k] = json!(n.max(0.));
        }
    }
}
fn progress(db: &Connection, owner: &str, id: &str, data: &mut Value, a: &Value) -> Result<Value> {
    let stage = string(a, "stage");
    let Some(next) = STAGES.iter().position(|s| s == &stage) else {
        return Ok(err("Invalid transcription stage."));
    };
    if next
        < STAGES
            .iter()
            .position(|s| s == &string(data, "status"))
            .unwrap_or(0)
    {
        return Ok(err("Transcription stage cannot move backwards."));
    }
    if !a["percent"].is_null() {
        let n = a["percent"]
            .as_f64()
            .or_else(|| a["percent"].as_str()?.parse::<f64>().ok());
        let Some(n) = n.filter(|n| n.is_finite()) else {
            return Ok(err("Invalid transcription progress."));
        };
        data["percent"] = json!(data["percent"].as_f64().unwrap_or(0.).max(n.clamp(0., 99.)));
    }
    let at = crate::now();
    if data["status"] != stage {
        data["stage_at"] = json!(at)
    }
    data["status"] = json!(stage);
    timings(data, &a["timings"]);
    db.execute(
        "UPDATE recording_leases SET deadline=? WHERE id=?",
        params![at + 30., id],
    )?;
    update(db, owner, id, data)?;
    Ok(json!({"saved":true}))
}
fn finish(
    db: &Connection,
    owner: &str,
    id: &str,
    data: &mut Value,
    result: &Value,
) -> Result<Value> {
    if let Some(reason) = result["error"].as_str().filter(|s| !s.is_empty()) {
        data["status"] = json!("failed");
        data["error"] = json!(reason.chars().take(500).collect::<String>());
    } else {
        let Some(text) = result["text"]
            .as_str()
            .filter(|t| !t.trim().is_empty() && t.chars().count() <= 30000)
        else {
            return Ok(err("Invalid transcription result."));
        };
        data["status"] = json!("completed");
        data["original_transcript"] = json!(text.trim());
        data["transcript"] = data["original_transcript"].clone();
        data["revision"] = json!(1);
        data["percent"] = json!(100);
    }
    timings(data, result);
    clear(db, id)?;
    update(db, owner, id, data)?;
    Ok(json!({"saved":true}))
}
fn runtime(db: &Connection) -> Result<Value> {
    Ok(db.query_row("SELECT data FROM transcription_runtime WHERE id=1",[],|r|r.get(0)).optional()?.unwrap_or_else(||
        json!({"status":"pending","stage":"checking","message":"Local transcription is starting. Audio stays saved while setup completes.","generation":"","updated_at":crate::now(),"probe_passed":false,"missing_tools":[]})))
}
fn store_runtime(db: &Connection, state: &Value) -> Result<()> {
    db.execute("INSERT INTO transcription_runtime VALUES(1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",[state])?;
    Ok(())
}
fn public(mut state: Value) -> Value {
    if let Some(v) = state.as_object_mut() {
        v.remove("generation");
    }
    state
}
pub(super) fn public_runtime(db: &Connection) -> Result<Value> {
    runtime(db).map(public)
}
pub(super) fn retry_setup(db: &Connection) -> Result<Value> {
    let mut state = runtime(db)?;
    if state["status"] == "unavailable" {
        state["status"] = json!("pending");
        state["stage"] = json!("checking");
        state["message"] = json!("Local transcription setup will retry.");
        state["updated_at"] = json!(crate::now());
        store_runtime(db, &state)?;
    }
    Ok(public(state))
}
fn runtime_worker(db: &Connection, a: &Value) -> Result<Value> {
    let mut state = runtime(db)?;
    match a.get("action").and_then(Value::as_str).unwrap_or("get") {
        "get" => return Ok(state),
        "start" => {
            state["generation"] = json!(uuid().replace('-', ""));
            state["status"] = json!("preparing");
            state["stage"] = json!("checking");
            state["message"] = json!("Checking local transcription setup.");
            state["probe_passed"] = json!(false);
            state["missing_tools"] = json!([]);
        }
        "report" => {
            if string(a, "generation").is_empty() || a["generation"] != state["generation"] {
                return Ok(err("Setup was replaced."));
            }
            let result = &a["result"];
            if !matches!(
                string(result, "status"),
                "ready" | "preparing" | "unavailable"
            ) {
                return Ok(err("Invalid setup state."));
            }
            for k in [
                "status",
                "stage",
                "message",
                "probe_passed",
                "missing_tools",
                "setup_ms",
                "load_ms",
                "transcribe_ms",
            ] {
                if let Some(v) = result.get(k) {
                    state[k] = v.clone();
                }
            }
        }
        _ => return Ok(err("Invalid setup action.")),
    }
    state["updated_at"] = json!(crate::now());
    store_runtime(db, &state)?;
    Ok(state)
}
pub fn worker_handles(m: &str) -> bool {
    matches!(
        m,
        "transcription_processing_runtime"
            | "transcription_processing_claim"
            | "transcription_processing_progress"
            | "transcription_processing_finish"
    )
}
pub fn worker(db: &Connection, m: &str, a: &Value) -> Result<Value> {
    if !crate::runs::worker_authorized(a) {
        return Ok(err("Worker authorization required."));
    }
    authorized(db, m, a)
}
pub(super) fn authorized(db: &Connection, m: &str, a: &Value) -> Result<Value> {
    match m {
        "transcription_processing_claim" => return claim(db),
        "transcription_processing_runtime" => return runtime_worker(db, a),
        "transcription_processing_progress" if !STAGES.contains(&string(a, "stage")) => {
            return Ok(err("Invalid transcription stage."));
        }
        "transcription_processing_progress" | "transcription_processing_finish" => {}
        _ => return Ok(err("Unknown transcription worker operation.")),
    }
    let id = string(a, "id");
    let owner = string(a, "owner");
    let lease = string(a, "lease");
    let Some(mut data) = get(db, owner, id)? else {
        return Ok(err(NOT_FOUND));
    };
    let valid: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM recording_leases WHERE id=? AND lease=? AND deadline>=?)",
        params![id, lease, crate::now()],
        |r| r.get(0),
    )?;
    if lease.is_empty() || !valid || !STAGES.contains(&string(&data, "status")) {
        return Ok(err(EXPIRED));
    }
    if m == "transcription_processing_progress" {
        progress(db, owner, id, &mut data, a)
    } else {
        finish(db, owner, id, &mut data, &a["result"])
    }
}
