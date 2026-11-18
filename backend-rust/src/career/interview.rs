use super::*;
use std::path::PathBuf;
use std::process::{Command, Stdio};

pub(super) fn handles(method: &str) -> bool {
    matches!(
        method,
        "interview_create"
            | "interview_get"
            | "interview_sessions"
            | "interview_answer"
            | "interview_correct"
            | "interview_continue"
    )
}
fn build(request: &Value) -> Result<Value> {
    let root = std::env::var_os("STACK_DISCOVERY_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".."));
    let mut child = Command::new(if cfg!(windows) { "python" } else { "python3" })
        .current_dir(root)
        .args([
            "-I",
            "-B",
            "-X",
            "utf8",
            "-c",
            include_str!("interview_questions.py"),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(io_error)?;
    if let Err(e) = serde_json::to_writer(child.stdin.take().unwrap(), request) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io_error(e));
    }
    let output = child.wait_with_output().map_err(io_error)?;
    if !output.status.success() {
        return Err(io_error(std::io::Error::other(
            "interview question builder unavailable",
        )));
    }
    serde_json::from_slice(&output.stdout).map_err(io_error)
}
fn io_error(e: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(e))
}
fn evidence(db: &Connection, owner: &str, app: &str) -> Result<(String, Vec<Value>)> {
    let mut query=db.prepare_cached("SELECT id,name,revision,confirmed,json_extract(review,'$.records') FROM resumes WHERE owner=? ORDER BY rowid")?;
    let mut rows = Vec::new();
    let mut all_ids = Vec::new();
    for r in query.query_map([owner],|r|{
        let records:Option<String>=r.get(4)?;
        let records:Value=serde_json::from_str(records.as_deref().unwrap_or("[]")).map_err(io_error)?;
        Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"revision":r.get::<_,i64>(2)?,"confirmed":r.get::<_,bool>(3)?,"records":records}))
    })? {
        let row=r?;
        all_ids.push(s(&row,"id").to_string());
        if row["records"].as_array().is_some_and(|v|!v.is_empty()){rows.push(row)}
    }
    let mut key:Option<String>=db.query_row("SELECT json_extract(data,'$.resume_id') FROM job_records WHERE owner=? AND kind='application' AND key=?",params![owner,app],|r|r.get::<_,Option<String>>(0)).optional()?.flatten();
    if !all_ids.contains(key.as_ref().unwrap_or(&String::new())) {
        key = Some(crate::resumes::selected_resume(db, owner)?);
        if !all_ids.contains(key.as_ref().unwrap()) {
            key = (all_ids.len() == 1).then(|| all_ids[0].clone());
        }
    }
    let mut bank=db.prepare_cached("SELECT json_remove(data,'$.history','$.attachment') FROM career_records WHERE owner=? AND kind='bank' ORDER BY rowid")?;
    for r in bank.query_map([owner], decode)? {
        let mut row = r?;
        row["kind"] = json!("experience_bank");
        rows.push(row);
    }
    Ok((key.unwrap_or_default(), rows))
}
fn next_revision(p: &mut Value) {
    p["revision"] = json!(p["revision"].as_u64().unwrap() + 1)
}
fn save(db: &Connection, owner: &str, p: Value) -> Result<Value> {
    put(db, owner, "interview", s(&p, "id"), &p)?;
    client_view(db, owner, p)
}
fn client_view(db: &Connection, owner: &str, mut p: Value) -> Result<Value> {
    p.as_object_mut().unwrap().remove("coaching_message");
    p.as_object_mut().unwrap().remove("coaching_available");
    let pending = s(&p["data"], "pending");
    p["run"] = if pending.is_empty() {
        json!({})
    } else {
        let v = crate::runs::detail(db, owner, pending)?;
        if v["error"].is_string() { json!({}) } else { v }
    };
    if p["data"]["analysis"]
        .as_object()
        .is_some_and(|v| !v.is_empty())
        || p["data"]["coaching"]
            .as_object()
            .is_some_and(|v| !v.is_empty())
    {
        p["data"] = build(&json!({"op":"client","data":p["data"]}))?;
    }
    Ok(p)
}

pub(crate) fn queue(
    db: &Connection,
    owner: &str,
    p: &mut Value,
    final_review: bool,
    index: Option<usize>,
) -> Result<()> {
    let attempt = p["data"]["model_attempt"].as_u64().unwrap_or(0) + 1;
    let context = build(
        &json!({"op":"context","data":p["data"],"revision":p["revision"],"final":final_review,"index":index}),
    )?;
    let kind = if final_review {
        "interview_coach"
    } else {
        "interview_turn"
    };
    let run = crate::runs::enqueue(
        db,
        owner,
        kind,
        s(p, "id"),
        &context,
        &format!("{}:{attempt}", p["revision"]),
    )?;
    let key = run["id"].as_str().ok_or(rusqlite::Error::InvalidQuery)?;
    p["data"]["pending"] = json!(key);
    p["data"]["model_attempt"] = json!(attempt);
    Ok(())
}

fn pending(db: &Connection, owner: &str, p: &Value) -> Result<Value> {
    Ok(db.query_row("SELECT data FROM agent_runs WHERE owner=? AND id=? AND json_extract(data,'$.target_id')=?",params![owner,s(&p["data"],"pending"),s(p,"id")],|r|r.get(0)).optional()?.unwrap_or(Value::Null))
}
fn cancel(db: &Connection, owner: &str, p: &Value) -> Result<()> {
    let mut run = pending(db, owner, p)?;
    if run.is_object() && !matches!(s(&run, "status"), "completed" | "cancelled" | "failed") {
        run["status"] = json!("cancelled");
        run["lease"] = json!("");
        run["lease_until"] = json!(0);
        run["message"] = json!("Cancelled");
        crate::runs::save(db, owner, s(&p["data"], "pending"), &mut run)?;
    }
    Ok(())
}
fn create(db: &Connection, owner: &str, a: &Value) -> Result<Value> {
    let client = s(a, "client_id");
    if client.is_empty() || client.chars().count() > 100 {
        return Ok(err("A bounded request ID is required."));
    }
    let old=db.query_row("SELECT data FROM career_records WHERE owner=? AND kind='interview' AND json_extract(data,'$.data.client_id')=?",params![owner,client],decode).optional()?;
    if let Some(p) = old {
        return client_view(db, owner, p);
    }
    let app = s(a, "application_id");
    let Some(job) = crate::jobs::application_job(db, owner, app)? else {
        return Ok(err("Choose one of your saved roles."));
    };
    let (resume_id, resumes) = evidence(db, owner, app)?;
    let data = build(
        &json!({"owner":owner,"application_id":app,"client_id":client,"job":job,"resume_id":resume_id,"resumes":resumes,"facts":crate::account::facts(db,owner)?}),
    )?;
    if data.get("error").is_some() {
        return Ok(data);
    }
    let p = json!({"id":id(db)?,"revision":0,"recordings":[],"results":[],"feedback":[],"data":data,"run":{}});
    save(db, owner, p)
}
fn mutate(db: &Connection, owner: &str, method: &str, a: &Value, mut p: Value) -> Result<Value> {
    if matches!(method, "interview_answer" | "interview_correct") {
        let answer = s(a, "answer");
        if answer.trim().is_empty() || answer.chars().count() > 4000 {
            return Ok(err(
                "Review an answer of 1 to 4,000 characters before saving.",
            ));
        }
        let text = answer.trim();
        let turns = p["data"]["turns"].as_array().unwrap();
        if method == "interview_answer" {
            let client = s(a, "client_id");
            if client.is_empty() || client.chars().count() > 100 {
                return Ok(err("A bounded answer request ID is required."));
            }
            if turns.iter().any(|t| s(t, "client_id") == client) {
                return client_view(db, owner, p);
            }
            if p["revision"] != a["revision"] {
                return Ok(err(
                    "This transcript changed. Reopen it before saving; your typed draft is retained.",
                ));
            }
            if p["data"]["status"] != "active"
                || !s(&p["data"], "pending").is_empty()
                || turns.len() >= p["data"]["questions"].as_array().unwrap().len()
            {
                return Ok(err(
                    "Continue or finish the saved interview before answering.",
                ));
            }
            if turns.len() >= 6 {
                return Ok(err("Finish this short interview after six answers."));
            }
            let recording_id = s(a, "recording_id");
            let original = if recording_id.is_empty() {
                text.to_string()
            } else {
                let Some(recording) = crate::recording::get(db, owner, recording_id)? else {
                    return Ok(err("Recording not found."));
                };
                if recording["status"] != "completed" {
                    return Ok(err("Wait for local transcription, or type your answer."));
                }
                s(&recording, "original_transcript").to_string()
            };
            let question = p["data"]["questions"][turns.len()].clone();
            p["data"]["turns"].as_array_mut().unwrap().push(json!({"question":question,"original":original,"answer":text,"recording_id":recording_id,"client_id":client}));
        } else {
            let count = turns.len();
            let index = a["index"].as_u64().and_then(|i| usize::try_from(i).ok());
            if p["revision"] != a["revision"] || index.is_none_or(|i| i >= count) {
                return Ok(err("This transcript changed. Reopen it before correcting."));
            }
            let index = index.unwrap();
            cancel(db, owner, &p)?;
            let turn = &mut p["data"]["turns"][index];
            if turn["answer"] != text {
                let previous = turn["answer"].clone();
                if !turn["previous"].is_array() {
                    turn["previous"] = json!([])
                }
                let history = turn["previous"].as_array_mut().unwrap();
                history.push(previous);
                if history.len() > 5 {
                    history.remove(0);
                }
            }
            turn["answer"] = json!(text);
            let q = p["data"]["questions"].as_array_mut().unwrap();
            let mut i = 0;
            q.retain(|v| {
                i += 1;
                i <= count || v["kind"] != "followup"
            });
            p["data"]["analysis"]
                .as_object_mut()
                .unwrap()
                .remove(&(index + 1).to_string());
        }
        p["data"]["coaching"] = json!({});
        p["data"]["pending"] = json!("");
        next_revision(&mut p);
        if p["data"]["status"] == "active" {
            queue(
                db,
                owner,
                &mut p,
                false,
                if method == "interview_correct" {
                    a["index"].as_u64().map(|n| n as usize)
                } else {
                    None
                },
            )?;
        }
    } else {
        if p["revision"] != a["revision"] {
            return Ok(err("This interview changed. Reopen it before continuing."));
        }
        let turns = p["data"]["turns"].as_array().unwrap();
        match a
            .get("action")
            .and_then(Value::as_str)
            .unwrap_or("followup")
        {
            "finish" => {
                if p["data"]["status"] == "finished" {
                    return client_view(db, owner, p);
                }
                if turns.is_empty() {
                    return Ok(err(
                        "Answer at least one question before finishing. An interview without answers gets no assessment.",
                    ));
                }
                let mut run = pending(db, owner, &p)?;
                let live = run["kind"] == "interview_turn"
                    && matches!(s(&run, "status"), "queued" | "running");
                if !live {
                    cancel(db, owner, &p)?;
                    p["data"]["pending"] = json!("");
                }
                p["data"]["status"] = json!("finished");
                p["data"]["finished_at"] = json!(now());
                next_revision(&mut p);
                if live {
                    run["context"]["session_revision"] = p["revision"].clone();
                    crate::runs::save(db, owner, s(&p["data"], "pending"), &mut run)?;
                }
            }
            "analyze" => {
                if turns.is_empty() {
                    return Ok(err("Wait for the current task, or retry it below."));
                }
                let final_review = p["data"]["status"] == "finished";
                if !s(&p["data"], "pending").is_empty() {
                    let run = pending(db, owner, &p)?;
                    if final_review
                        && run["kind"] == "interview_turn"
                        && matches!(s(&run, "status"), "queued" | "running")
                    {
                        p["data"]["final_after"] = json!(true);
                    } else {
                        return Ok(err("Wait for the current task, or retry it below."));
                    }
                } else {
                    queue(db, owner, &mut p, final_review, None)?;
                }
            }
            action @ ("next" | "followup") => {
                let count = turns.len();
                if p["data"]["status"] != "active" || count == 0 {
                    return Ok(err("Save a reviewed answer before continuing."));
                }
                if action == "next" {
                    if count >= p["data"]["questions"].as_array().unwrap().len() {
                        return Ok(err(
                            "All saved role questions are answered. Finish, or request a follow-up.",
                        ));
                    }
                    cancel(db, owner, &p)?;
                    p["data"]["pending"] = json!("");
                } else {
                    if !s(&p["data"], "pending").is_empty() {
                        return Ok(err("Wait for analysis before requesting a follow-up."));
                    }
                    let analysis = &p["data"]["analysis"][count.to_string()];
                    if analysis.is_null() {
                        return Ok(err(
                            "Analyze the reviewed answer first, or continue with the saved role question.",
                        ));
                    }
                    if count >= 6 {
                        return Ok(err(
                            "This short interview has reached six answers. Finish and review it.",
                        ));
                    }
                    let text =
                        build(&json!({"op":"followup","analysis":analysis,"data":p["data"]}))?;
                    let q = json!({"question":text,"evidence":[],"kind":"followup","basis_revision":p["revision"]});
                    let questions = p["data"]["questions"].as_array_mut().unwrap();
                    let remaining = questions.split_off(count);
                    questions.push(q);
                    questions.extend(remaining.into_iter().filter(|q| q["kind"] != "followup"));
                    next_revision(&mut p);
                }
            }
            _ => return Ok(err("Unknown interview action.")),
        }
    }
    save(db, owner, p)
}
pub(super) fn dispatch(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Value> {
    match method {
        "interview_create" => create(db, owner, a),
        "interview_sessions" => {
            let mut q=db.prepare_cached("SELECT data,updated FROM career_records WHERE owner=? AND kind='interview' ORDER BY updated DESC,rowid DESC LIMIT 50")?;
            let rows=q.query_map([owner],|r|{let p=decode(r)?;Ok(json!({"id":p["id"],"data":p["data"],"revision":p["revision"],"updated_at":r.get::<_,f64>(1)?}))})?.collect::<Result<Vec<_>>>()?;
            Ok(json!({"sessions":rows}))
        }
        _ => {
            let Some(p) = get(db, owner, "interview", s(a, "id"))? else {
                return Ok(err("Interview session not found."));
            };
            if method == "interview_get" {
                client_view(db, owner, p)
            } else {
                mutate(db, owner, method, a, p)
            }
        }
    }
}
