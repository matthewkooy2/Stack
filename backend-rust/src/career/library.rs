use super::*;
use std::collections::HashMap;

static SCORE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?im)^\W*(specificity|ownership|structure|reflection)\W*[:=\-]\s*([0-4](?:\.\d)?)\s*(?:/\s*4)?\W*$").unwrap()
});
static HEADING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?im)^\W*scores?\W*$").unwrap());
fn attempt(db: &Connection, owner: &str, p: &Value) -> Result<Value> {
    let recent:Option<String>=db.query_row("SELECT id FROM agent_runs WHERE owner=? AND json_extract(data,'$.kind')='prep' AND json_extract(data,'$.target_id')=? ORDER BY created DESC,rowid DESC LIMIT 1",params![owner,s(p,"id")],|row|row.get(0)).optional()?;
    let run = if let Some(id) = recent {
        crate::runs::detail(db, owner, &id)?
    } else {
        json!({})
    };
    let coached = p["feedback"]
        .as_array()
        .unwrap()
        .iter()
        .rev()
        .find(|f| f["revision"] == p["revision"]);
    let text = coached.map_or("", |f| s(&f["data"], "text"));
    let mut scores = json!({});
    for cap in SCORE.captures_iter(text) {
        let value = cap[2].parse::<f64>().unwrap().clamp(0.0, 4.0);
        scores[&cap[1].to_ascii_lowercase()] = json!(value);
    }
    let score = if scores.as_object().unwrap().len() == 4 {
        json!(
            (scores
                .as_object()
                .unwrap()
                .values()
                .map(|v| v.as_f64().unwrap())
                .sum::<f64>()
                * 6.25)
                .round_ties_even() as i64
        )
    } else {
        Value::Null
    };
    let cutoff = HEADING
        .find_iter(text)
        .last()
        .map_or(text.len(), |m| m.start());
    let cleaned = SCORE.replace_all(&text[..cutoff], "");
    let data = &p["data"];
    Ok(
        json!({"id":p["id"],"question_id":data["problem_id"],"created_at":p["created_at"],"revision":p["revision"],"transcript":data["answer"],
        "video_id":data["video_id"],"recording_id":data["recording_id"],"duration":data["duration"],"score":score,"rubric":scores,"feedback":cleaned.trim(),
        "status":if !score.is_null(){"scored"}else if coached.is_some(){"unscored"}else{run["status"].as_str().unwrap_or("not_started")},"run":run}),
    )
}
fn better(a: &Value, b: &Value) -> std::cmp::Ordering {
    b["score"].as_i64().cmp(&a["score"].as_i64()).then_with(|| {
        b["created_at"]
            .as_f64()
            .unwrap()
            .total_cmp(&a["created_at"].as_f64().unwrap())
    })
}
pub(super) fn attempts(db: &Connection, owner: &str, key: &str) -> Result<Vec<Value>> {
    let mut q=db.prepare_cached("SELECT data FROM career_records WHERE owner=? AND kind='practice_attempt' AND json_extract(data,'$.data.problem_id')=? ORDER BY rowid DESC")?;
    let mut rows = q
        .query_map(params![owner, key], |r| attempt(db, owner, &decode(r)?))?
        .collect::<Result<Vec<_>>>()?;
    rows.sort_by(better);
    Ok(rows)
}
pub(super) fn best_by_question(
    db: &Connection,
    owner: &str,
) -> Result<HashMap<String, (usize, Value)>> {
    let mut out: HashMap<String, (usize, Value)> = HashMap::new();
    let mut q=db.prepare_cached("SELECT data FROM career_records WHERE owner=? AND kind='practice_attempt' ORDER BY rowid DESC")?;
    let mut rows = q.query([owner])?;
    while let Some(row) = rows.next()? {
        let current = attempt(db, owner, &decode(row)?)?;
        let slot = out
            .entry(s(&current, "question_id").to_string())
            .or_insert_with(|| (0, Value::Null));
        if slot.0 == 0 || better(&current, &slot.1).is_lt() {
            slot.1 = current;
        }
        slot.0 += 1;
    }
    Ok(out)
}
pub(super) fn dispatch(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Value> {
    let key = s(a, "id");
    if method == "practice_attempt_create" {
        let client = s(a, "client_id");
        let answer = s(a, "answer");
        if client.is_empty() || client.chars().count() > 100 {
            return Ok(err("A bounded request ID is required."));
        }
        if answer.trim().is_empty() {
            return Ok(err("Review your answer transcript before scoring."));
        }
        let rid = s(a, "recording_id");
        let vid = s(a, "video_id");
        if answer.chars().count() > 30000 || rid.chars().count() > 100 || vid.chars().count() > 100
        {
            return Ok(err("This answer is too long."));
        }
        let question = s(a, "question_id");
        if !LIBRARY["questions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|q| q["id"] == question)
        {
            return Ok(err("Practice question not found."));
        }
        let old=db.query_row("SELECT data FROM career_records WHERE owner=? AND kind='practice_attempt' AND json_extract(data,'$.data.client_id')=?",params![owner,client],decode).optional()?;
        if let Some(p) = old {
            return attempt(db, owner, &p);
        }
        if !rid.is_empty() && crate::recording::get(db, owner, rid)?.is_none() {
            return Ok(err("Recording not found."));
        }
        let key = id(db)?;
        let duration = a["duration"].as_f64().unwrap_or(0.0).clamp(0.0, 3600.0);
        let data = json!({"mode":"library","problem_id":question,"track":"behavioral","industry":industry(db,owner)?,"language":"","answer":answer.trim(),
            "code":"","notes":"","transcript":"","canvas":{},"elapsed_seconds":0,"client_id":client,"recording_id":rid,"video_id":vid,"duration":duration});
        let stored = json!({"id":key,"data":data,"created_at":now(),"revision":0,"feedback":[],"results":[],"recordings":[]});
        put(db, owner, "practice_attempt", &key, &stored)?;
        let context = json!({"session":stored["data"],"session_revision":0,"problem":super::problem(question),"test_results":[]});
        let run = crate::runs::enqueue(db, owner, "prep", &key, &context, "0")?;
        if run.get("error").is_some() {
            return Ok(run);
        }
        return attempt(db, owner, &stored);
    }
    let Some(p) = get(db, owner, "practice_attempt", key)? else {
        return Ok(err("Practice attempt not found."));
    };
    if method == "practice_attempt_get" {
        return attempt(db, owner, &p);
    }
    if !s(&p["data"], "recording_id").is_empty() {
        crate::recording::remove(db, owner, s(&p["data"], "recording_id"))?;
    }
    let mut q=db.prepare("SELECT id FROM agent_runs WHERE owner=? AND json_extract(data,'$.kind')='prep' AND json_extract(data,'$.target_id')=? AND json_extract(data,'$.status') NOT IN ('completed','cancelled','failed')")?;
    let ids = q
        .query_map(params![owner, key], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>>>()?;
    drop(q);
    for id in ids {
        crate::runs::dispatch(db, owner, "agent_cancel", &json!({"id":id}))?;
    }
    remove(db, owner, "practice_attempt", key)?;
    Ok(json!({"deleted":true,"id":key}))
}
