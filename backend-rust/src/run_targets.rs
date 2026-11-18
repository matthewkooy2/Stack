use super::*;

pub(super) fn career_row(
    db: &Connection,
    owner: &str,
    kind: &str,
    id: &str,
) -> Result<Option<Value>> {
    db.query_row(
        "SELECT data FROM career_records WHERE owner=? AND kind=? AND id=?",
        params![owner, kind, id],
        |r| r.get(0),
    )
    .optional()
}
pub fn start(db: &Connection, owner: &str, kind: &str, id: &str) -> Result<Value> {
    if kind == "application" {
        return Ok(err(
            "The application assistant has been retired. Apply on the employer site yourself.",
        ));
    }
    if kind == "autofill" {
        return crate::browser::start(db, owner, id);
    }
    let profile = jobs::profile(db, owner)?;
    let missing = || err("This agent target was not found or is unavailable.");
    let (target, context, nonce) = match kind {
        "jobs" | "resume" => {
            let Some(job) = jobs::application_job(db, owner, id)? else {
                return Ok(missing());
            };
            let ctx = application_context(db, owner, id, kind, &profile, &job)?;
            if ctx.get("error").is_some() {
                return Ok(ctx);
            }
            (id, ctx, String::new())
        }
        "profile" => (
            "self",
            json!({"profile":{"name":profile["name"],"role":profile["role"],"location":profile["location"]}}),
            String::new(),
        ),
        "network" => {
            let Some(c) = career_row(db, owner, "contact", id)?
                .filter(|c| c["selected"] == true && c["stopped"] != true)
            else {
                return Ok(missing());
            };
            (
                id,
                json!({"contact":c,"profile":{"name":profile["name"]},"thread_id":s(&c,"thread_id")}),
                String::new(),
            )
        }
        "code" | "prep" => {
            if career_row(db, owner, "interview", id)?.is_some() {
                return Ok(err("Use the interview controls for this session."));
            }
            let Some(p) = career_row(db, owner, "prep", id)?.or(career_row(
                db,
                owner,
                "practice_attempt",
                id,
            )?) else {
                return Ok(missing());
            };
            let Some(problem) = career::problem(s(&p["data"], "problem_id")) else {
                return Ok(missing());
            };
            let tests = p["results"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|row| row["revision"] == p["revision"])
                .collect::<Vec<_>>();
            let mut ctx = json!({"session":p["data"],"session_revision":p["revision"],"problem":problem,"test_results":tests});
            if let Some(job) = jobs::application_job(db, owner, s(&p["data"], "application_id"))? {
                ctx["job"] = job;
            }
            (id, ctx, p["revision"].to_string())
        }
        _ => return Ok(missing()),
    };
    enqueue(db, owner, kind, target, &context, &nonce)
}
pub fn respond(db: &Connection, owner: &str, r: &mut Value, a: &Value) -> Result<Option<Value>> {
    if !matches!(s(r, "status"), "needs_input" | "blocked") {
        return Ok(Some(err("This run is not waiting for input.")));
    }
    let values = helper(
        json!({"op":"validate_facts","values":a.get("values").cloned().unwrap_or(json!([]))}),
    )?;
    let Some(items) = values.as_array() else {
        return Ok(Some(values));
    };
    let mut facts = account::facts(db, owner)?;
    let rows = facts.as_array_mut().ok_or(rusqlite::Error::InvalidQuery)?;
    rows.retain(|f| !items.iter().any(|v| v["key"] == f["key"]));
    rows.extend(items.iter().cloned());
    if a["reuse"].as_bool().unwrap_or(true) {
        let p = account::policy(db, owner)?;
        db.execute("INSERT INTO account_preferences VALUES(?,?,?,1) ON CONFLICT(owner) DO UPDATE SET facts=excluded.facts,revision=revision+1",params![owner,p,facts])?;
    }
    r["context"]["facts"] = facts;
    r["context"]["fact_overrides"] = if a["reuse"].as_bool().unwrap_or(true) {
        json!([])
    } else {
        values.clone()
    };
    if !items.is_empty() && matches!(s(r, "kind"), "resume" | "jobs") {
        r["index"] = json!(0);
        r["artifacts"] = json!({})
    }
    status(r, "queued", "Ready to resume");
    r["requests"] = json!([]);
    r["attempts"] = json!(0);
    r["next_at"] = json!(0);
    Ok(None)
}

pub(super) fn project_step(
    db: &Connection,
    owner: &str,
    id: &str,
    current: &str,
    r: &mut Value,
    artifact: &mut Value,
) -> Result<Option<String>> {
    let target = s(r, "target_id").to_owned();
    if current == "approve_resume" {
        if let Some(approved) = artifact
            .as_object_mut()
            .and_then(|a| a.remove("tailor"))
            .and_then(|a| a.as_object().cloned())
            && let Some(base) = r["artifacts"]["tailor"].as_object_mut()
        {
            base.extend(approved);
        }
    } else if current == "send" {
        if let Some(mut contact) = career_row(db, owner, "contact", &target)? {
            let policy = account::policy(db, owner)?;
            contact["thread_id"] = json!(s(artifact, "thread_id"));
            if r["context"]["followup"] == true {
                contact["followups"] = json!(contact["followups"].as_u64().unwrap_or(0) + 1);
            }
            contact["next_at"] = json!(if s(artifact, "thread_id").is_empty() {
                0.
            } else {
                now() + policy["followup_days"].as_f64().unwrap_or(7.) * 86400.
            });
            db.execute("UPDATE career_records SET data=?,updated=? WHERE owner=? AND kind='contact' AND id=?",params![contact,now(),owner,target])?;
        }
    } else if matches!(
        current,
        "coach" | "execute" | "interview_turn" | "interview_coach"
    ) {
        let kind = if current.starts_with("interview_") {
            "interview"
        } else if current == "coach"
            && career_row(db, owner, "practice_attempt", &target)?.is_some()
        {
            "practice_attempt"
        } else {
            "prep"
        };
        let Some(mut p) = career_row(db, owner, kind, &target)? else {
            return Ok(Some("Practice session not found.".into()));
        };
        if current.starts_with("interview_") && p["data"]["pending"] != id {
            return Ok(Some("The transcript changed while analysis was running. Saved answers are safe; request analysis again.".into()));
        }
        if current != "execute" && p["revision"] != r["context"]["session_revision"] {
            return Ok(Some("Practice changed while coaching was running. Request coaching again for your saved answer.".into()));
        }
        if current == "execute" {
            let revision = r["context"]["session_revision"].clone();
            p["results"]
                .as_array_mut()
                .ok_or(rusqlite::Error::InvalidQuery)?
                .push(json!({"at":now(),"revision":revision,"data":artifact}));
        } else {
            let clean = helper(json!({"op":"coaching","artifact":artifact}))?;
            if let Some(message) = clean["error"].as_str() {
                return Ok(Some(message.into()));
            }
            *artifact = clean;
            if current == "coach" {
                let mut artifacts = r["artifacts"].clone();
                artifacts[current] = artifact.clone();
                let version = helper(json!({"op":"artifact_hash","artifacts":artifacts}))?;
                p["feedback"].as_array_mut().ok_or(rusqlite::Error::InvalidQuery)?.push(json!({"at":now(),"revision":r["context"]["session_revision"],"run_id":id,"output_version":version,"data":artifact}));
            } else {
                let data = helper(
                    json!({"op":"interview","session":p,"run":r,"step":current,"artifact":artifact}),
                )?;
                if let Some(message) = data["error"].as_str() {
                    return Ok(Some(message.into()));
                }
                p["data"] = data;
                if current == "interview_turn"
                    && p["data"]["final_after"] == true
                    && p["data"]["status"] == "finished"
                {
                    career::queue_interview(db, owner, &mut p, true, None)?;
                    p["data"]["final_after"] = json!(false);
                }
            }
        }
        db.execute(
            "UPDATE career_records SET data=?,updated=? WHERE owner=? AND kind=? AND id=?",
            params![p, now(), owner, kind, target],
        )?;
    }
    Ok(None)
}
pub(super) fn worker_data(db: &Connection, owner: &str, r: &Value, m: &str) -> Result<Value> {
    let current = step(r);
    if m == "agent_worker_resume_source" {
        if !matches!(current.as_str(), "tailor" | "approve_resume") {
            return Ok(err("This step cannot read resume sources."));
        }
        return Ok(score_docs::dispatch(
            db,
            owner,
            "worker_resume_source",
            &json!({"id":r["context"]["resume_id"]}),
        )?
        .unwrap_or_else(|| {
            err("Choose a resume for this application on the Resume tab, then try again.")
        }));
    }
    if !matches!(
        current.as_str(),
        "tailor" | "approve_resume" | "interview_turn" | "interview_coach" | "coach"
    ) {
        return Ok(err("This step cannot read the memory bank."));
    }
    let bank = career::dispatch(db, owner, "resume_bank", &json!({}))?
        .ok_or(rusqlite::Error::InvalidQuery)?;
    let mut resumes = bank["sources"].as_array().cloned().unwrap_or_default();
    for entry in &mut resumes {
        if entry["kind"] != "imported_resume"
            && !bank["resumes"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|r| r["id"] == entry["id"])
        {
            entry["kind"] = json!("experience_bank");
        }
    }
    let mut q = db
        .prepare("SELECT data FROM career_records WHERE owner=? AND kind='story' ORDER BY rowid")?;
    let stories = q
        .query_map([owner], |r| r.get::<_, Value>(0))?
        .collect::<Result<Vec<_>>>()?;
    helper(
        json!({"op":"memory","owner":owner,"resumes":resumes,"facts":account::facts(db,owner)?,"stories":stories}),
    )
}
pub(super) fn model_log(
    db: &Connection,
    owner: &str,
    id: &str,
    r: &mut Value,
    recording: &Value,
) -> Result<Value> {
    let current = step(r);
    if !matches!(
        current.as_str(),
        "interview"
            | "linkedin_review"
            | "fit"
            | "tailor"
            | "draft"
            | "coach"
            | "profile"
            | "story"
            | "interview_turn"
            | "interview_coach"
    ) || !matches!(
        s(recording, "status"),
        "started" | "received" | "accepted" | "rejected" | "error" | "completed"
    ) {
        return Ok(err("Invalid model log."));
    }
    let attempt = s(recording, "attempt_id");
    if attempt.is_empty() || attempt.chars().count() > 64 {
        return Ok(err("Invalid model attempt."));
    }
    let mut log = json!({"run_id":id,"attempt_id":attempt,"step":current,"updated_at":now(),"created_at":now()});
    for k in [
        "provider",
        "model",
        "status",
        "raw_response",
        "response_format",
        "error",
    ] {
        if let Some(v) = recording.get(k) {
            log[k] = v.clone();
        }
    }
    if let Some(previous) = history(db, id, "model_log")?
        .into_iter()
        .find(|v| v["attempt_id"] == attempt)
    {
        if previous["step"] != current {
            return Ok(err("Model attempt belongs to another step."));
        }
        for k in ["created_at", "id", "at"] {
            log[k] = previous[k].clone();
        }
        db.execute(
            "UPDATE run_history SET data=? WHERE run_id=? AND id=?",
            params![log, id, previous["id"].as_str()],
        )?;
    } else {
        record(db, id, "model_log", log)?;
    }
    if recording["status"] == "accepted" {
        r["provider"] = recording["provider"].clone();
        save(db, owner, id, r)?;
    }
    Ok(json!({"saved":true}))
}

fn application_context(
    db: &Connection,
    owner: &str,
    id: &str,
    kind: &str,
    profile: &Value,
    job: &Value,
) -> Result<Value> {
    let resume = score_docs::resolve_resume(db, owner, id)?.unwrap_or_default();
    let mut ctx = json!({"application_id":id,"job":job,"profile":{"name":profile["name"],"role":profile["role"],"location":profile["location"],"preferences":profile["preferences"]},"resume_id":resume,"resume_format":""});
    if !resume.is_empty() {
        let (name, review, confirmed, format, revision): (String, Value, bool, Option<Value>, i64) =
            db.query_row(
                "SELECT r.name,r.review,r.confirmed,s.format,r.revision FROM resumes r
                 LEFT JOIN resume_sources s ON r.id=s.resume WHERE r.id=? AND r.owner=?",
                params![resume, owner],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )?;
        let form = format.unwrap_or(Value::Null);
        let records = review["records"].as_array();
        ctx["resume_name"] = json!(name);
        ctx["resume_format"] = json!(if form["kind"] == "upload" {
            "latex"
        } else if confirmed && records.is_some_and(|r| !r.is_empty()) {
            "records"
        } else if confirmed && form["kind"] == "builtin" {
            "builtin"
        } else {
            ""
        });
        ctx["resume_text"] = json!(if let Some(rows) = records {
            rows.iter()
                .map(|r| s(r, "text"))
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            s(&review, "text").to_string()
        });
        if kind == "resume" {
            ctx["resume_revision"] = json!(revision);
            ctx["resume_template"] = json!(review["template"].as_str().unwrap_or("classic"));
        }
        if kind == "resume" && ctx["resume_format"] == "" {
            return Ok(err(&format!(
                "Review and confirm the imported records for {name} or upload its LaTeX."
            )));
        }
        db.execute("UPDATE job_records SET data=json_set(data,'$.resume_id',?) WHERE owner=? AND kind='application' AND key=?",params![resume,owner,id])?;
    } else if kind == "resume" {
        return Ok(err("Upload your resume on the Resume tab first."));
    }
    Ok(ctx)
}

pub(super) fn continue_tailoring(
    db: &Connection,
    owner: &str,
    r: &mut Value,
    a: &Value,
) -> Result<Option<Value>> {
    if r["status"] != "needs_input" || super::step(r) != "tailor" {
        return Ok(Some(err("This task is not waiting for a resume.")));
    }
    let target = r["context"]["application_id"]
        .as_str()
        .unwrap_or(s(r, "target_id"));
    let Some(job) = jobs::application_job(db, owner, target)? else {
        return Ok(Some(err(
            "This saved job was removed. Start tailoring from another job.",
        )));
    };
    let selected = s(a, "resume_id");
    if !selected.is_empty() {
        if !crate::resumes::resume_exists(db, owner, selected)? {
            return Ok(Some(err("Resume not found.")));
        }
        db.execute("UPDATE job_records SET data=json_set(data,'$.resume_id',?) WHERE owner=? AND kind='application' AND key=?",params![selected,owner,target])?;
    }
    let ctx = application_context(
        db,
        owner,
        target,
        "resume",
        &jobs::profile(db, owner)?,
        &job,
    )?;
    if ctx.get("error").is_some() {
        return Ok(Some(ctx));
    }
    for (k, v) in ctx.as_object().unwrap() {
        if k.starts_with("resume_") {
            r["context"][k] = v.clone();
        }
    }
    respond(db, owner, r, &json!({"reuse":false,"values":[]}))
}
pub(super) fn linkedin_pdf(db: &Connection, owner: &str, a: &Value) -> Result<Value> {
    let capture = helper(json!({"op":"linkedin_pdf","name":s(a,"name"),"content":s(a,"content")}))?;
    if capture.get("error").is_some() {
        return Ok(capture);
    }
    let role = s(a, "target_role")
        .trim()
        .chars()
        .take(120)
        .collect::<String>();
    let out = enqueue(
        db,
        owner,
        "linkedin_pdf",
        "self",
        &json!({"target_role":role,"file":capture["file"]}),
        &auth::random_id(),
    )?;
    let Some(id) = out["id"].as_str() else {
        return Ok(out);
    };
    let mut r = load(db, owner, id)?.ok_or(rusqlite::Error::InvalidQuery)?;
    r["artifacts"]["linkedin_pdf"] = capture;
    r["index"] = json!(1);
    status(&mut r, "queued", "Queued for profile review");
    save(db, owner, id, &mut r)?;
    render(db, id, &r, true)
}
