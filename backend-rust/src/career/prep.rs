use super::*;

pub(super) fn handles(method: &str) -> bool {
    matches!(
        method,
        "practice_profile"
            | "practice_options"
            | "practice_slots"
            | "practice_attempts"
            | "practice_attempt_get"
            | "practice_attempt_create"
            | "practice_attempt_delete"
            | "prep_catalog"
            | "prep_create"
            | "prep_get"
            | "prep_live"
            | "prep_sessions"
            | "prep_save"
            | "prep_save_coaching"
            | "prep_progress"
            | "prep_for_application"
    )
}
fn library() -> &'static [Value] {
    LIBRARY["questions"].as_array().unwrap()
}
pub(crate) fn problem(key: &str) -> Option<&'static Value> {
    CATALOG.iter().chain(library()).find(|q| s(q, "id") == key)
}

fn snapshot(data: &Value) -> std::result::Result<Value, String> {
    let spec = problem(s(data, "problem_id")).ok_or("Practice question not found.")?;
    let lang = s(data, "language");
    let languages = spec["languages"].as_array().unwrap();
    if !(languages.iter().any(|l| l == lang) || (languages.is_empty() && lang.is_empty())) {
        return Err("Choose a supported language.".into());
    }
    let mut out = json!({"problem_id":spec["id"],"language":lang});
    for (f, title, n) in [
        ("answer", "Answer", 30000),
        ("code", "Code", 30000),
        ("notes", "Notes", 10000),
        ("transcript", "Transcript", 30000),
    ] {
        let text = s(data, f);
        if text.chars().count() > n {
            return Err(format!("{title} is too long."));
        }
        out[f] = json!(text);
    }
    let canvas = data
        .get("canvas")
        .cloned()
        .unwrap_or_else(|| json!({"nodes":[],"edges":[]}));
    if !canvas.is_object() || json_len(&canvas) > 50000 {
        return Err("Diagram is too large.".into());
    }
    let seconds = data.get("elapsed_seconds").map_or(Some(0), Value::as_u64);
    if !seconds.is_some_and(|v| v <= 86400) {
        return Err("Invalid elapsed time.".into());
    }
    out["canvas"] = canvas;
    out["elapsed_seconds"] = json!(seconds);
    Ok(out)
}
// The original contract bounds Python json.dumps (ensure_ascii and spaced separators).
fn json_len(v: &Value) -> usize {
    let compact = v.to_string();
    let mut result = compact.len();
    let mut quoted = false;
    let mut escaped = false;
    for c in compact.chars() {
        if !c.is_ascii() {
            result += 6 * c.len_utf16() - c.len_utf8()
        }
        if escaped {
            escaped = false;
            continue;
        }
        if quoted && c == '\\' {
            escaped = true;
            continue;
        }
        if c == '"' {
            quoted = !quoted
        }
        if !quoted && matches!(c, ',' | ':') {
            result += 1
        }
    }
    result
}
fn options(db: &Connection, owner: &str) -> Result<Value> {
    Ok(
        json!({"industries":LIBRARY["industries"],"tracks":LIBRARY["tracks"],"industry":industry(db,owner)?}),
    )
}
fn create(
    db: &Connection,
    owner: &str,
    problem_id: &str,
    language: &str,
    application: &str,
) -> Result<Value> {
    let Some(spec) = problem(problem_id) else {
        return Ok(err("Practice question not found."));
    };
    let mut data = match snapshot(
        &json!({"problem_id":problem_id,"language":language,"code":s(&spec["starter"],language)}),
    ) {
        Ok(v) => v,
        Err(e) => return Ok(err(e)),
    };
    data["application_id"] = json!(application);
    let key = id(db)?;
    let mut session =
        json!({"id":key,"data":data,"revision":0,"results":[],"feedback":[],"recordings":[]});
    put(db, owner, "prep", &key, &session)?;
    session.as_object_mut().unwrap().remove("recordings");
    Ok(session)
}
fn get_session(db: &Connection, owner: &str, key: &str) -> Result<Value> {
    for kind in ["prep", "interview", "practice_attempt"] {
        if let Some(mut row) = get(db, owner, kind, key)? {
            row.as_object_mut().unwrap().retain(|k, _| {
                matches!(
                    k.as_str(),
                    "id" | "data" | "revision" | "results" | "feedback" | "recordings"
                )
            });
            return Ok(row);
        }
    }
    Ok(err("Practice session not found."))
}
fn store_answer(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Value> {
    let coaching = method == "prep_save_coaching";
    let sub = if coaching { &a["submission"] } else { a };
    let mut data = match snapshot(&sub["data"]) {
        Ok(v) => v,
        Err(e) => return Ok(err(e)),
    };
    let key = s(sub, "key");
    let feedback = &sub["feedback"];
    if coaching
        && (key.is_empty()
            || key.chars().count() > 100
            || !feedback.is_object()
            || json_len(feedback) > 50000)
    {
        return Ok(err("Invalid coaching result."));
    }
    let sid = s(a, "id");
    let (kind, mut p) = if let Some(p) = get(db, owner, "prep", sid)? {
        ("prep", p)
    } else if let Some(p) = get(db, owner, "practice_attempt", sid)? {
        if !coaching {
            return Ok(err(
                "Practice library answers are saved as attempts. Record a new attempt instead.",
            ));
        }
        ("practice_attempt", p)
    } else {
        if !coaching && get(db, owner, "interview", sid)?.is_some() {
            return Ok(err("Use interview controls to preserve the conversation."));
        }
        return Ok(err("Practice session not found."));
    };
    data["application_id"] = p["data"]["application_id"].clone();
    if coaching
        && let Some(old) = p["feedback"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| s(v, "submission_id") == key)
    {
        return Ok(if old["session"] == data && &old["data"] == feedback {
            p
        } else {
            err("This coaching result was already saved with different content.")
        });
    }
    if p["revision"].as_u64() == sub["revision"].as_u64() {
        if kind == "practice_attempt" {
            p["data"]["answer"] = data["answer"].clone();
        } else {
            p["data"] = data.clone();
        }
        p["revision"] = json!(p["revision"].as_u64().unwrap() + 1);
    } else if !coaching {
        return Ok(err(
            "This session changed on another device. Reload before saving.",
        ));
    }
    if coaching {
        let item = json!({"at":now(),"revision":p["revision"],"submission_id":key,"session":data,"answer":data["answer"],"data":feedback});
        p["feedback"].as_array_mut().unwrap().push(item);
    }
    put(db, owner, kind, sid, &p)?;
    Ok(p)
}
fn plan(db: &Connection, owner: &str, app: &str) -> Result<Value> {
    let Some(job) = crate::jobs::application_job(db, owner, app)? else {
        return Ok(json!({"plan":[]}));
    };
    let text = format!("{} {}", s(&job, "title"), s(&job, "description")).to_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| text.contains(w));
    let mut choices = vec![
        (
            "role-specific",
            "",
            "Practice requirements from this job description.",
        ),
        (
            "project",
            "",
            "Explain your contribution using a specific verified example.",
        ),
    ];
    if has(&[
        "software",
        "python",
        "c++",
        "backend",
        "frontend",
        "full stack",
    ]) {
        choices.push((
            "two-sum",
            if text.contains("c++") {
                "cpp"
            } else {
                "python"
            },
            "The role includes software implementation.",
        ));
        choices.push((
            "debug-endpoint",
            "",
            "Practice explaining a debugging investigation.",
        ));
        if has(&["senior", "staff", "principal", "architect", "distributed"]) {
            choices.push((
                "design-tracker",
                "",
                "The role calls for architectural decisions and tradeoffs.",
            ))
        }
    }
    if text.contains("sql") {
        choices.push(("sql-funnel", "sql", "SQL appears in the job description."))
    }
    let mut sql=db.prepare_cached("SELECT json_extract(data,'$.feedback[#-1].data.rubric') FROM career_records WHERE owner=? AND kind='prep' AND json_type(data,'$.feedback[#-1].data.rubric')='array'")?;
    let mut edge = false;
    let mut reflection = false;
    for rubric in sql.query_map([owner], decode)? {
        let rubric = rubric?;
        for c in rubric
            .as_array()
            .into_iter()
            .flatten()
            .filter(|c| c["score"].as_f64().unwrap_or(4.0) < 2.0)
        {
            let name = s(c, "criterion").to_lowercase();
            edge |= name.contains("edge") || name.contains("correct");
            reflection |= name.contains("reflection");
        }
    }
    if edge {
        choices.push((
            "brackets",
            "python",
            "Recent feedback identified edge cases or correctness as a practice area.",
        ))
    }
    if reflection {
        choices.push((
            "setback",
            "",
            "Recent feedback identified reflection as a practice area.",
        ))
    }
    let mut out = Vec::new();
    for (pid, lang, reason) in choices.into_iter().take(7) {
        let old:Option<String>=db.query_row("SELECT id FROM career_records WHERE owner=? AND kind='prep' AND json_extract(data,'$.data.application_id')=? AND json_extract(data,'$.data.problem_id')=? ORDER BY rowid LIMIT 1",params![owner,app,pid],|r|r.get(0)).optional()?;
        let key = match old {
            Some(k) => k,
            None => s(&create(db, owner, pid, lang, app)?, "id").to_string(),
        };
        out.push(json!({"problem_id":pid,"language":lang,"reason":reason,"session_id":key}));
    }
    Ok(json!({"plan":out}))
}
// Capture the revision and ownership before inference. The client saves feedback separately
// against that revision, so a later edit cannot be overwritten by a slow model response.
pub(crate) fn coach(db: &mut Connection, token: &str, args: &Value) -> Result<crate::Response> {
    static INFERENCE: std::sync::LazyLock<tokio::sync::Semaphore> =
        std::sync::LazyLock::new(|| tokio::sync::Semaphore::new(1));

    let id = s(args, "id");
    let tx = db.transaction()?;
    let Some(owner) = crate::admitted_owner(&tx, token)? else {
        return Ok(crate::denied());
    };
    if let Some(response) = crate::arguments::missing("prep_coach", args) {
        return Ok(response);
    }
    let mut data = match snapshot(&args["data"]) {
        Ok(data) => data,
        Err(message) => return Ok(crate::result(err(message))),
    };
    if s(&data, "answer").trim().is_empty() {
        return Ok(crate::result(err("Type or transcribe your answer first.")));
    }
    let row = match get(&tx, &owner, "prep", id)? {
        Some(session) => session,
        None => match get(&tx, &owner, "practice_attempt", id)? {
            Some(attempt) => attempt,
            None => return Ok(crate::result(err("Practice session not found."))),
        },
    };
    data["application_id"] = row["data"]["application_id"].clone();
    let revision = row["revision"].clone();
    tx.commit()?;

    let Ok(_permit) = INFERENCE.try_acquire() else {
        return Ok(crate::result(err("Practice coaching is busy. Try again shortly.")));
    };
    let mut question = problem(s(&data, "problem_id")).unwrap().clone();
    if let Some(prompt) = data["canvas"]["stack_prep_workflow_v1"]["prompt"].as_str()
        && !prompt.trim().is_empty()
    {
        question["prompt"] = json!(prompt);
    }
    let output = crate::score_docs::helper(
        &json!({"session":{"answer":data["answer"]},"question":question}),
        include_str!("../../prep-coach.py"),
        "Practice coaching is temporarily unavailable. Please retry.",
    )?;
    if crate::admitted_owner(db, token)?.as_deref() != Some(owner.as_str()) {
        return Ok(crate::denied());
    }
    if let Some(message) = output["error"].as_str() {
        return Ok(crate::result(err(message)));
    }
    let feedback = &output["feedback"];
    if (s(feedback, "text").trim().is_empty() && s(feedback, "summary").trim().is_empty())
        || json_len(feedback) > 50000
    {
        return Ok(crate::result(err("The coach returned incomplete feedback. Please retry.")));
    }
    Ok(crate::result(json!({"id":id,"revision":revision,"data":data,"feedback":feedback})))
}

pub(super) fn dispatch(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Value> {
    Ok(match method {
        "prep_catalog" => json!({"problems":*CATALOG}),
        "prep_create" => create(
            db,
            owner,
            s(a, "problem_id"),
            s(a, "language"),
            s(a, "application_id"),
        )?,
        "prep_get" => get_session(db, owner, s(a, "id"))?,
        "prep_live" => {
            let session = get_session(db, owner, s(a, "id"))?;
            if session.get("error").is_some() {
                session
            } else if session["data"]["mode"] == "interview" {
                err(
                    "This interview uses recorded answers and agent coaching. Live voice is not enabled.",
                )
            } else {
                let message = crate::deployment::settings()["voice_error"]
                    .as_str()
                    .unwrap_or_default();
                err(if message.is_empty() {
                    "Live voice is unavailable on this deployment."
                } else {
                    message
                })
            }
        }
        "prep_save" | "prep_save_coaching" => store_answer(db, owner, method, a)?,
        "prep_for_application" => plan(db, owner, s(a, "application_id"))?,
        "prep_sessions" | "prep_progress" => {
            let sessions = method == "prep_sessions";
            let sql = if sessions {
                "SELECT data,updated FROM career_records WHERE owner=? AND kind='prep' ORDER BY updated DESC,rowid DESC LIMIT 50"
            } else {
                "SELECT data,updated FROM career_records WHERE owner=? AND kind IN ('prep','interview','practice_attempt') ORDER BY rowid"
            };
            let mut query = db.prepare_cached(sql)?;
            let rows=query.query_map([owner],|r|{
                let v=decode(r)?;
                let updated:f64=r.get(1)?;
                Ok(if sessions {json!({"id":v["id"],"data":v["data"],"revision":v["revision"],"updated_at":updated})}
                    else{json!({"id":v["id"],"problem_id":v["data"]["problem_id"],"revision":v["revision"],"test_results":v["results"],"feedback":v["feedback"],"updated_at":updated})})
            })?.collect::<Result<Vec<_>>>()?;
            if sessions {
                json!({"sessions":rows})
            } else {
                json!({"attempts":rows})
            }
        }
        "practice_options" => options(db, owner)?,
        "practice_profile" => {
            let selection = s(a, "industry");
            if !LIBRARY["industries"]
                .as_array()
                .unwrap()
                .iter()
                .any(|i| s(i, "id") == selection)
            {
                return Ok(err("Choose one of the listed industries."));
            }
            put(db, owner, "settings", "industry", &json!(selection))?;
            options(db, owner)?
        }
        "practice_slots" => {
            let selection = industry(db, owner)?;
            if selection == "" {
                return Ok(json!({"industry":"","slots":[],"needs_industry":true}));
            }
            let track = a
                .get("track")
                .and_then(Value::as_str)
                .unwrap_or("behavioral");
            if !LIBRARY["tracks"]
                .as_array()
                .unwrap()
                .iter()
                .any(|t| s(t, "id") == track && t["available"] == true)
            {
                return Ok(err("This practice track is not available yet."));
            }
            let mut questions: Vec<_> = library()
                .iter()
                .filter(|q| {
                    track == "behavioral"
                        && q["industries"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .any(|v| v == "*" || v == &selection)
                })
                .collect();
            questions.sort_by_key(|q| (q["order"].as_i64(), s(q, "id")));
            let mut scores = super::library::best_by_question(db, owner)?;
            let mut slots = Vec::new();
            for question in questions {
                let (count, best) = scores
                    .remove(s(question, "id"))
                    .unwrap_or_else(|| (0, json!({})));
                slots.push(json!({"question":question,"attempt_count":count,"best":best}));
            }
            json!({"industry":selection,"track":track,"slots":slots})
        }
        "practice_attempts" => {
            let key = s(a, "question_id");
            let Some(q) = library().iter().find(|v| s(v, "id") == key) else {
                return Ok(err("Practice question not found."));
            };
            json!({"question":q,"attempts":super::library::attempts(db,owner,key)?})
        }
        "practice_attempt_get" | "practice_attempt_create" | "practice_attempt_delete" => {
            super::library::dispatch(db, owner, method, a)?
        }
        _ => unreachable!(),
    })
}
