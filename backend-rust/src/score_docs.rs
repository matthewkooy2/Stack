use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use std::{
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
};

pub fn handles(method: &str) -> bool {
    matches!(method, "score_resume" | "read_resume_source")
}
fn error(message: impl AsRef<str>) -> Value {
    json!({"error":message.as_ref()})
}

pub(crate) fn resolve_resume(
    db: &Connection,
    owner: &str,
    application: &str,
) -> Result<Option<String>> {
    db.query_row("SELECT r.id FROM resumes r
      LEFT JOIN resume_selection s ON s.owner=r.owner AND s.id=r.id
      JOIN job_records a ON a.owner=r.owner AND a.kind='application' AND a.key=?2 AND NOT json_extract(a.data,'$.demo')
      WHERE r.owner=?1 AND (r.id=json_extract(a.data,'$.resume_id') OR s.id IS NOT NULL OR (SELECT count(*) FROM resumes WHERE owner=?1)=1)
      ORDER BY (r.id=json_extract(a.data,'$.resume_id')) DESC,(s.id IS NOT NULL) DESC LIMIT 1",
      params![owner,application],|r|r.get(0)).optional()
}

pub(crate) fn rules(input: &Value) -> Result<Value> {
    helper(
        input,
        include_str!("score_docs.py"),
        "The resume scoring or document renderer is unavailable.",
    )
}

pub(crate) fn helper(input: &Value, script: &str, unavailable: &str) -> Result<Value> {
    let root = std::env::var_os("STACK_SCORE_DOCS_ROOT")
        .or_else(|| std::env::var_os("STACK_DISCOVERY_ROOT"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".."));
    let python = std::env::var_os("STACK_DOCUMENT_PYTHON").unwrap_or_else(|| "python3".into());
    let mut child = match Command::new(python)
        .args(["-I", "-X", "utf8", "-c", script])
        .arg(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => {
            return Ok(error(unavailable));
        }
    };
    let mut stdin = child.stdin.take().unwrap();
    let sent = serde_json::to_writer(&mut stdin, input).is_ok() && stdin.flush().is_ok();
    drop(stdin);
    if !sent {
        let _ = child.kill();
    }
    let out = match child.wait_with_output() {
        Ok(o) if sent && o.status.success() => o,
        _ => {
            return Ok(error(unavailable));
        }
    };
    Ok(serde_json::from_slice(&out.stdout).unwrap_or_else(|_| error(unavailable)))
}

pub fn dispatch(db: &Connection, owner: &str, method: &str, args: &Value) -> Result<Option<Value>> {
    let worker_source = method == "worker_resume_source";
    if !worker_source && !handles(method) {
        return Ok(None);
    }
    let scoring = method == "score_resume";
    let aid = args["application_id"].as_str().unwrap_or_default();
    let (id, job) = if scoring {
        let Some(job) = crate::jobs::application_job(db, owner, aid)? else {
            return Ok(Some(error("Saved job not found.")));
        };
        let Some(id) = resolve_resume(db, owner, aid)? else {
            return Ok(Some(error("Upload your resume on the Resume tab first.")));
        };
        (id, job)
    } else {
        (
            args["id"].as_str().unwrap_or_default().to_owned(),
            Value::Null,
        )
    };
    if worker_source && let Some(encoded) = crate::resumes::source_export(db, owner, &id)? {
        let format: Value = db.query_row(
            "SELECT format FROM resume_sources WHERE resume=?",
            [&id],
            |r| r.get(0),
        )?;
        if format["kind"] == "upload" {
            let mut out = encoded;
            out["format"] = json!("latex");
            return Ok(Some(out));
        }
    }
    if !scoring
        && !worker_source
        && let Some(view) = crate::resumes::read_source(db, owner, &id)?
    {
        return Ok(Some(view));
    }
    let row = db
        .query_row(
            "SELECT name,digest,review,revision,confirmed FROM resumes WHERE id=? AND owner=?",
            params![id, owner],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Value>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, bool>(4)?,
                ))
            },
        )
        .optional()?;
    let Some((name, digest, review, revision, confirmed)) = row else {
        return Ok(Some(error("Resume not found.")));
    };
    if !confirmed || !review["records"].as_array().is_some_and(|r| !r.is_empty()) {
        let why = if scoring {
            format!(
                "Confirm your details for {name} on the Resume tab. The job score uses only information you confirmed."
            )
        } else {
            format!("Review and confirm the imported records for {name} before tailoring.")
        };
        return Ok(Some(error(why)));
    }

    let selection = review
        .get("bank_selection")
        .cloned()
        .unwrap_or_else(|| json!([]));
    let mut sources = Vec::new();
    if selection.as_array().is_some_and(|s| !s.is_empty()) {
        // The existing private bank view keeps selection revisions and source metadata identical to editing.
        let bank = crate::career::dispatch(db, owner, "resume_bank", &json!({}))?
            .ok_or(rusqlite::Error::InvalidQuery)?;
        let selected: std::collections::HashSet<_> = selection
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|s| s["id"].as_str())
            .collect();
        for s in bank["sources"]
            .as_array()
            .ok_or(rusqlite::Error::InvalidQuery)?
        {
            if let Some(key) = s["id"].as_str()
                && key != id
                && selected.contains(key)
            {
                sources.push(s.clone());
            }
        }
    }
    let as_of = args["as_of"]
        .as_str()
        .filter(|s| !s.is_empty() && *s != "None");
    let template = review["template"].as_str().unwrap_or("classic");
    let mut out = rules(
        &json!({"operation":if scoring{"score"}else if worker_source{"worker_source"}else{"preview"},"job":job,"as_of":as_of,
        "records":review["records"],"template":template,"revision":revision,"digest":digest,"selection":selection,"sources":sources}),
    )?;
    if out.get("error").is_some() {
        return Ok(Some(out));
    }
    if worker_source {
        return Ok(Some(out));
    }
    if scoring {
        out["application_id"] = json!(aid);
        out["resume_id"] = json!(id);
        out["resume_name"] = json!(name);
        out["source"] = json!("confirmed_records");
    } else {
        out["id"] = json!(id);
        out["name"] = json!(name);
        let label = match template {
            "classic" => "Classic",
            "jake" => "Jake's Resume",
            "awesome-cv" => "Awesome-CV",
            "bill-ryan" => "Bill Ryan's Elegant Resume",
            "deedy" => "Deedy Resume",
            "jan-kuster" => "Jan Kuster's Classic CV",
            "sb2nov" => "Sourabh Bajaj's Resume",
            _ => "Stack reviewed records",
        };
        out["format"] = json!({"kind":"records","template":template,"label":label,"pages":out["preview"]["pages"],"summary":{},"skipped":[]});
    }
    Ok(Some(out))
}
