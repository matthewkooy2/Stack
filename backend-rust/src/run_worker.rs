use super::*;

pub fn worker_authorized(a: &Value) -> bool {
    let key = std::env::var("STACK_AGENT_WORKER_TOKEN")
        .ok()
        .filter(|v| !v.is_empty())
        .or_else(|| {
            let dir = std::env::var_os("CREDENTIALS_DIRECTORY")?;
            std::fs::read_to_string(std::path::Path::new(&dir).join("worker_token")).ok()
        });
    key.is_some_and(|k| {
        !k.trim().is_empty()
            && bool::from(
                Sha256::digest(k.trim().as_bytes())
                    .ct_eq(&Sha256::digest(s(a, "token").as_bytes())),
            )
    })
}
pub fn worker_handles(m: &str) -> bool {
    matches!(
        m,
        "agent_claim"
            | "agent_lease_active"
            | "agent_trace"
            | "agent_authorize"
            | "agent_finish"
            | "agent_complete"
            | "agent_report"
            | "agent_invite"
            | "agent_model_log"
            | "agent_worker_memory"
            | "agent_worker_resume_source"
    )
}
fn admitted(db: &Connection, owner: &str) -> Result<bool> {
    let invited: Option<bool> = db
        .query_row("SELECT invited FROM accounts WHERE id=?", [owner], |r| {
            r.get(0)
        })
        .optional()?;
    Ok(invited.is_some_and(|i| auth::admitted(i).unwrap_or(false)))
}
pub fn leased(db: &Connection, owner: &str, id: &str, lease: &str) -> Result<Option<Value>> {
    if lease.is_empty() || !admitted(db, owner)? {
        return Ok(None);
    }
    Ok(load(db, owner, id)?.filter(|r| {
        r["lease"] == lease
            && r["status"] == "running"
            && r["kind"] != "application"
            && r["lease_until"].as_f64().unwrap_or(0.) >= now()
    }))
}
pub fn advance(r: &mut Value) {
    let index = r["index"].as_u64().unwrap_or(0) + 1;
    r["index"] = json!(index);
    r["attempts"] = json!(0);
    r["next_at"] = json!(0);
    if index as usize >= r["steps"].as_array().map_or(0, Vec::len) {
        status(r, "completed", "Completed")
    } else {
        status(r, "queued", "Ready for next step")
    }
}
fn claim(db: &Connection, args: &Value) -> Result<Value> {
    let filter = match args.get("steps") {
        None => None,
        Some(Value::Array(v)) if v.iter().all(Value::is_string) => Some(v),
        Some(_) => return Ok(err("Choose a valid worker step filter.")),
    };
    let at = now();
    // Scan eligible keys first. A backlog may contain PDFs or other large artifacts.
    let mut q=db.prepare("SELECT owner,id FROM agent_runs WHERE json_extract(data,'$.status') IN ('queued','running')
        AND COALESCE(json_extract(data,'$.next_at'),0)<=?1 AND COALESCE(json_extract(data,'$.lease_until'),0)<=?1
        AND (?2 IS NULL OR json_extract(data,'$.steps['||json_extract(data,'$.index')||']') IN (SELECT value FROM json_each(?2)))
        AND (?3=0 OR COALESCE(json_extract(data,'$.context.manual_scan'),0)=0)
        ORDER BY COALESCE(json_extract(data,'$.next_at'),0),created")?;
    let allowed = filter.map(|v| json!(v));
    let candidates = q
        .query_map(params![at, allowed, args["non_inference"] == true], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>>>()?;
    drop(q);
    for (owner, id) in candidates {
        let Some(mut r) = load(db, &owner, &id)? else {
            continue;
        };
        let mut current = step(&r);
        if args["non_inference"] == true && r["context"]["manual_scan"] == true {
            continue;
        }
        if matches!(s(&r, "kind"), "linkedin" | "application")
            || filter.is_some_and(|v| !v.iter().any(|s| s == &current))
        {
            continue;
        }
        if r["status"] == "running" && r["intent"].is_object() {
            status(
                &mut r,
                "uncertain",
                "The action may have completed. Verify its receipt before continuing.",
            );
            save(db, &owner, &id, &mut r)?;
            continue;
        }
        if r["attempts"].as_u64().unwrap_or(0) >= 3 {
            status(
                &mut r,
                "failed",
                "This step failed three times. Review the error before retrying.",
            );
            save(db, &owner, &id, &mut r)?;
            continue;
        }
        if !admitted(db, &owner)? {
            status(
                &mut r,
                "blocked",
                "An invitation is required for this beta.",
            );
            save(db, &owner, &id, &mut r)?;
            continue;
        }
        let facts = helper(json!({"op":"facts","run":r,"facts":account::facts(db,&owner)?}))?;
        if !facts.is_array() {
            return Err(rusqlite::Error::InvalidQuery);
        }
        if facts != r["context"]["facts"] && matches!(s(&r, "kind"), "jobs" | "resume") {
            r["index"] = json!(0);
            r["artifacts"] = json!({});
            current = step(&r);
        }
        r["context"]["facts"] = facts;
        if filter.is_some_and(|v| !v.iter().any(|s| s == &current)) {
            save(db, &owner, &id, &mut r)?;
            continue;
        }
        if current == "tailor"
            && !matches!(
                s(&r["context"], "resume_format"),
                "latex" | "builtin" | "records"
            )
        {
            let message = if s(&r["context"], "resume_id").is_empty() {
                "Upload a resume before tailoring."
            } else {
                "Review and confirm this resume's imported records or add its LaTeX before tailoring."
            };
            status(&mut r, "needs_input", message);
            save(db, &owner, &id, &mut r)?;
            continue;
        }
        if matches!(current.as_str(), "send" | "calendar" | "approve_resume") {
            if current != "approve_resume" {
                let policy = helper(
                    json!({"op":"policy","step":current,"policy":account::policy(db,&owner)?,"run":r}),
                )?;
                if let Some(message) = policy["error"].as_str() {
                    status(&mut r, "blocked", message);
                    trace(db, &id, &r, "blocked", policy)?;
                    save(db, &owner, &id, &mut r)?;
                    continue;
                }
            }
            let reviewed = helper(json!({"op":"review","step":current,"run":r}))?;
            if !reviewed["review"]["hash"].is_string() {
                return Err(rusqlite::Error::InvalidQuery);
            }
            if r["approvals"][&current] != reviewed["review"]["hash"] {
                let mut review = reviewed["review"].clone();
                if let Some(message) = providers::google_missing(db, &owner, &current)? {
                    review["blocked"] = json!(message);
                    review["notes"].as_array_mut().unwrap().push(json!(message));
                }
                status(
                    &mut r,
                    "review",
                    &format!("Review before Stack continues: {}", s(&review, "title")),
                );
                r["review"] = review;
                save(db, &owner, &id, &mut r)?;
                continue;
            }
        }
        let cfg = helper(json!({"op":"config","run":r,"step":current,"owner":owner}))?;
        if let Some(message) = cfg["error"].as_str() {
            status(&mut r, "blocked", message);
            trace(db, &id, &r, "blocked", json!({"message":message}))?;
            save(db, &owner, &id, &mut r)?;
            continue;
        }
        if matches!(
            current.as_str(),
            "linkedin_review"
                | "fit"
                | "tailor"
                | "draft"
                | "coach"
                | "profile"
                | "story"
                | "interview_turn"
                | "interview_coach"
        ) {
            r["provider"] = cfg["provider"].clone();
        }
        status(&mut r, "running", &format!("Working on {current}"));
        r["lease"] = json!(auth::random_id());
        r["lease_until"] = json!(at + cfg["seconds"].as_f64().unwrap_or(180.));
        r["attempts"] = json!(r["attempts"].as_u64().unwrap_or(0) + 1);
        r["stage_started_at"] = json!(now());
        r["trace_attempt"] = json!(auth::random_id());
        r["requested_model"] = cfg["model"].clone();
        trace(
            db,
            &id,
            &r,
            "stage_start",
            json!({"provider":cfg["provider"],"requested_model":r["requested_model"],"attempt_number":r["attempts"],"prompt_version":r["context"]["prompt_version"],"context":r["context"]}),
        )?;
        save(db, &owner, &id, &mut r)?;
        return Ok(
            json!({"id":id,"owner":owner,"lease":r["lease"],"step":current,"context":r["context"],"artifacts":r["artifacts"],"model_selection":r["model_selection"],"provider_config_hash":cfg["hash"]}),
        );
    }
    Ok(json!({"idle":true}))
}

fn authorize(db: &Connection, owner: &str, id: &str, r: &mut Value, a: &Value) -> Result<Value> {
    let current = step(r);
    if !matches!(current.as_str(), "send" | "calendar") {
        return Ok(err("This step has no external action."));
    }
    if !a["payload_hash"].is_string() || r["approvals"][&current] != a["payload_hash"] {
        return Ok(err(
            "This action does not match what you approved. Review it again.",
        ));
    }
    let policy = account::policy(db, owner)?;
    let allowed = helper(json!({"op":"policy","step":current,"policy":policy,"run":r}))?;
    if allowed.get("error").is_some() {
        return Ok(allowed);
    }
    if providers::google_missing(db, owner, &current)?.is_some() {
        return Ok(err("Google authorization was revoked or is unavailable."));
    }
    if current == "send"
        && !targets::career_row(db, owner, "contact", s(r, "target_id"))?.is_some_and(|c| {
            c["email"] == r["context"]["contact"]["email"]
                && c["selected"] == true
                && c["stopped"] != true
        })
    {
        return Ok(err("This contact is not selected or outreach has stopped."));
    }
    if r["intent"].is_object() {
        return Ok(err(
            "This action was already dispatched; reconcile its receipt.",
        ));
    }
    let day = now() as i64 / 86400;
    let action = s(&allowed, "action");
    let limits = [
        ("", allowed["cap"].as_i64().unwrap_or(0)),
        (owner, policy["daily_limits"][action].as_i64().unwrap_or(0)),
    ];
    for (scope, cap) in limits {
        let used: i64 = db
            .query_row(
                "SELECT count FROM run_action_usage WHERE day=? AND action=? AND scope=?",
                params![day, action, scope],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0);
        if used >= cap {
            return Ok(err(
                "Set an available operator and user daily limit for this action.",
            ));
        }
    }
    for (scope, _) in limits {
        db.execute("INSERT INTO run_action_usage VALUES(?,?,?,1) ON CONFLICT(day,action,scope) DO UPDATE SET count=count+1",params![day,action,scope])?;
    }
    let revision: i64 = db.query_row(
        "SELECT revision FROM account_preferences WHERE owner=?",
        [owner],
        |r| r.get(0),
    )?;
    let intent = json!({"action_id":auth::random_id(),"step":current,"policy_revision":revision,"payload_hash":a["payload_hash"]});
    r["intent"] = intent.clone();
    save(db, owner, id, r)?;
    Ok(json!({"authorized":true,"action_id":intent["action_id"],"policy_revision":revision}))
}
fn complete(db: &Connection, owner: &str, id: &str, r: &mut Value, data: &Value) -> Result<Value> {
    let current = step(r);
    let intent = r["intent"].is_object();
    let started = r["stage_started_at"].as_f64().unwrap_or(now());
    let trace_result = data;
    trace(
        db,
        id,
        r,
        "stage_end",
        json!({"outcome":if data["error"].is_string(){"error"}else if data["needs_input"]==true {"needs_input"}else{"result_received"},"duration_ms":((now()-started).max(0.)*1000.) as u64,"result":trace_result}),
    )?;
    r["lease"] = json!("");
    r["lease_until"] = json!(0);
    if data["interrupted"] == true {
        let stopping = matches!(s(&data["control"], "mode"), "stopping" | "stopped");
        status(
            r,
            if intent {
                "uncertain"
            } else if stopping {
                "cancelled"
            } else {
                "paused"
            },
            if stopping {
                "Browser task stopped."
            } else {
                "Browser activity paused."
            },
        );
    } else if let Some(message) = data["error"].as_str() {
        status(
            r,
            if intent { "uncertain" } else { "queued" },
            &message.chars().take(1000).collect::<String>(),
        );
        r["next_at"] =
            json!(now() + 15. * 2f64.powi(r["attempts"].as_i64().unwrap_or(1).clamp(0, 4) as i32));
    } else if data["blocked"] == true {
        status(
            r,
            if intent { "uncertain" } else { "blocked" },
            data["message"]
                .as_str()
                .unwrap_or("This step could not complete. Retry when ready."),
        );
        r["requests"] = json!([]);
    } else if data["needs_input"] == true {
        status(
            r,
            if intent { "uncertain" } else { "needs_input" },
            if intent {
                "An action was dispatched; reconcile it before resuming."
            } else {
                data["message"].as_str().unwrap_or("Your input is needed.")
            },
        );
        r["requests"] = data.get("requests").cloned().unwrap_or(json!([]));
        if current == "browser_autofill" {
            r["artifacts"][&current] = data["artifact"].clone();
        }
    } else {
        let mut artifact = data.get("artifact").cloned().unwrap_or(json!({}));
        if matches!(current.as_str(), "send" | "calendar")
            && (!intent || s(&artifact, "receipt").is_empty())
        {
            status(r, "uncertain", "No confirmation receipt was returned.");
        } else if let Some(message) =
            targets::project_step(db, owner, id, &current, r, &mut artifact)?
        {
            status(r, "needs_input", &message);
        } else {
            r["artifacts"][&current] = artifact.clone();
            if intent {
                record(
                    db,
                    id,
                    "receipt",
                    json!({"intent":r["intent"],"receipt":artifact}),
                )?;
                r["intent"] = Value::Null;
            }
            advance(r);
            providers::project(db, owner, id, r)?;
            if r["status"] == "completed" {
                crate::resumes::save_tailored(db, owner, id, r)?;
            }
        }
    }
    save(db, owner, id, r)?;
    render(db, id, r, true)
}
pub fn worker(db: &Connection, m: &str, a: &Value) -> Result<Value> {
    if !worker_authorized(a) {
        return Ok(err("Worker authorization required."));
    }
    match m {
        "agent_claim" => return claim(db, a),
        "agent_invite" => return auth::new_invite(db).map(|i| json!({"invite":i})),
        "agent_report" => {
            let mut q=db.prepare("SELECT json_extract(data,'$.status'),COALESCE(json_extract(data,'$.next_at'),0) FROM agent_runs ORDER BY created")?;
            let queue = q
                .query_map([], |r| {
                    Ok(json!({"state":r.get::<_,String>(0)?,"due_at":r.get::<_,f64>(1)?}))
                })?
                .collect::<Result<Vec<_>>>()?;
            let mut u=db.prepare("SELECT 'action:'||date(day*86400,'unixepoch')||':'||action||CASE WHEN scope='' THEN '' ELSE ':'||scope END,count FROM run_action_usage")?;
            let usage = u
                .query_map([], |r| {
                    Ok(json!({"key":r.get::<_,String>(0)?,"actions":r.get::<_,i64>(1)?,"cents":0}))
                })?
                .collect::<Result<Vec<_>>>()?;
            return Ok(json!({"queue":queue,"usage":usage}));
        }
        _ => {}
    }
    let owner = s(a, "owner");
    let id = s(a, "id");
    let lease = s(a, "lease");
    let loaded = leased(db, owner, id, lease)?;
    if m == "agent_lease_active" {
        return Ok(json!({"active":loaded.is_some()}));
    }
    let Some(mut r) = loaded else {
        return Ok(err("Run lease expired or cancelled."));
    };
    match m {
        "agent_authorize" => authorize(db, owner, id, &mut r, a),
        "agent_finish" | "agent_complete" => complete(db, owner, id, &mut r, &a["result"]),
        "agent_worker_memory" | "agent_worker_resume_source" => {
            targets::worker_data(db, owner, &r, m)
        }
        "agent_trace" => {
            let event = s(a, "event");
            if !matches!(
                event,
                "model_request" | "model_response" | "model_validation" | "provider_fallback"
            ) {
                return Ok(err("Unsupported trace event."));
            }
            trace(db, id, &r, event, a["data"].clone())?;
            Ok(json!({"saved":true}))
        }
        "agent_model_log" => targets::model_log(db, owner, id, &mut r, &a["record"]),
        _ => Ok(err("Unknown worker operation.")),
    }
}
