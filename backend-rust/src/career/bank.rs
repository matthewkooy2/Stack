use super::*;

static TYPES: LazyLock<Vec<Value>> =
    LazyLock::new(|| serde_json::from_str(include_str!("entry_types.json")).unwrap());
pub(super) fn handles(method: &str) -> bool {
    matches!(
        method,
        "resume_bank"
            | "resume_bank_save"
            | "resume_bank_delete"
            | "resume_bank_select"
            | "resume_bank_attachment_save"
            | "resume_bank_attachment"
    )
}
fn arr<'a>(v: &'a Value, k: &str) -> &'a [Value] {
    v.get(k)
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

pub(crate) fn validate_records(records: &Value) -> std::result::Result<Vec<Value>, String> {
    let rows = records
        .as_array()
        .filter(|a| !a.is_empty() && a.len() <= 300)
        .ok_or("Review between 1 and 300 resume records.")?;
    let mut ids = HashSet::new();
    let mut text_size = 0;
    let mut out = Vec::new();
    for r in rows {
        if !r.is_object() {
            return Err("Invalid resume record.".into());
        }
        let key = s(r, "id");
        let kind = s(r, "kind");
        let text = s(r, "text");
        let eligible = r.get("allow_omit").map_or(Some(false), Value::as_bool);
        if !key.strip_prefix('r').is_some_and(|suffix| {
            (1..=4).contains(&suffix.len()) && suffix.bytes().all(|b| b.is_ascii_digit())
        }) || !ids.insert(key)
            || !matches!(kind, "title" | "heading" | "paragraph" | "bullet")
            || eligible.is_none()
            || text.trim().is_empty()
            || text.chars().count() > 2000
            || text
                .chars()
                .any(|c| (c < ' ' && c != '\t' && c != '\n') || c == '\x7f')
        {
            return Err(
                "Each record needs a unique id, supported kind and 1–2,000 text characters.".into(),
            );
        }
        let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
        text_size += text.chars().count();
        let mut record = json!({"id":key,"kind":kind,"text":text});
        if eligible == Some(true) {
            record["allow_omit"] = json!(true)
        }
        out.push(record)
    }
    if text_size > 60000 {
        return Err("Resume text exceeds the supported limit.".into());
    }
    Ok(out)
}

fn context(source: &Value) -> Vec<String> {
    let Some(t) = TYPES.iter().find(|t| t["key"] == source["entry_type"]) else {
        return Vec::new();
    };
    arr(t, "fields")
        .iter()
        .filter_map(|f| {
            let val = s(&source["fields"], s(f, "key"));
            (!val.is_empty()).then(|| format!("{}: {}", s(f, "label"), val))
        })
        .collect()
}
fn normalize(kind: &str, fields: &Value, confirm: bool) -> std::result::Result<Value, String> {
    let def = TYPES
        .iter()
        .find(|t| t["key"] == kind)
        .ok_or("Choose a supported memory bank entry type.")?;
    let obj = fields
        .as_object()
        .ok_or("Send the entry fields as a map of field names to text.")?;
    let defs = arr(def, "fields");
    if obj.keys().any(|k| !defs.iter().any(|f| s(f, "key") == k)) {
        return Err("Use the fields defined for this entry type.".into());
    }
    let mut checked = json!({});
    for (k, v) in obj {
        let text = v
            .as_str()
            .filter(|v| v.chars().count() <= 1500)
            .ok_or("Keep each memory bank field to 1,500 text characters or less.")?
            .trim();
        if !text.is_empty() {
            checked[k] = json!(text)
        }
    }
    if confirm {
        let missing: Vec<_> = defs
            .iter()
            .filter(|f| f["required_on_confirm"] == true && checked[s(f, "key")].is_null())
            .map(|f| s(f, "label"))
            .collect();
        if !missing.is_empty() {
            return Err(format!(
                "Complete these fields before confirming: {}.",
                missing.join(", ")
            ));
        }
    }
    Ok(checked)
}
fn group(
    previous: Option<&Value>,
    a: &Value,
    revision: u64,
    at: f64,
) -> std::result::Result<Value, String> {
    let name = s(a, "name").trim();
    let source = s(a, "source").trim();
    if !(1..=160).contains(&name.chars().count()) {
        return Err("Name this experience in 160 characters or less.".into());
    }
    if !(1..=500).contains(&source.chars().count()) {
        return Err("Describe the source of these facts in 500 characters or less.".into());
    }
    let default = json!({"entry_type":"other","fields":{},"attachment":{},"history":[]});
    let old = previous.unwrap_or(&default);
    let kind = if s(a, "entry_type").is_empty() {
        s(old, "entry_type")
    } else {
        s(a, "entry_type")
    };
    let confirm = a["confirm"] == true;
    let input = if a["fields"].is_null() || a["fields"] == "None" {
        &old["fields"]
    } else {
        &a["fields"]
    };
    let fields = normalize(kind, input, confirm)?;
    let records = if a["records"] == json!([]) {
        Vec::new()
    } else {
        validate_records(&a["records"])?
    };
    if confirm && records.is_empty() && fields.as_object().unwrap().is_empty() {
        return Err("Add a field or factual record before confirming this entry.".into());
    }
    if records
        .iter()
        .any(|r| !matches!(s(r, "kind"), "paragraph" | "bullet"))
    {
        return Err("Use paragraphs or bullets for experience facts; the experience name supplies the heading.".into());
    }
    let mut snapshot = json!({"name":name,"source":source,"records":records,"schema_version":1,"entry_type":kind,"fields":fields,
        "attachment":old["attachment"],"confirmed":confirm,"revision":revision+1,"saved_at":at});
    let mut combined: Vec<Value> = context(&snapshot)
        .into_iter()
        .map(|l| json!({"kind":"paragraph","text":l}))
        .chain(records.iter().cloned())
        .collect();
    for (i, r) in combined.iter_mut().enumerate() {
        r["id"] = json!(format!("r{i}"))
    }
    if !combined.is_empty() {
        validate_records(&json!(combined))?;
    }
    let mut history = arr(old, "history").to_vec();
    if history.len() >= 100 {
        return Err(
            "This experience has 100 revisions. Export it before creating a new group.".into(),
        );
    }
    history.push(snapshot.clone());
    snapshot.as_object_mut().unwrap().remove("saved_at");
    snapshot["history"] = json!(history);
    snapshot["editable"] = json!(true);
    snapshot["confirmed_at"] = json!(if confirm { at } else { 0.0 });
    snapshot["upload_digest"] = json!("");
    Ok(snapshot)
}
fn imported_resume(row: &rusqlite::Row<'_>) -> Result<Value> {
    let id: String = row.get(0)?;
    let name: String = row.get(1)?;
    let digest: String = row.get(2)?;
    let review: String = row.get(3)?;
    let review: Value = serde_json::from_str(&review).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(3, rusqlite::types::Type::Text, Box::new(e))
    })?;
    let revision: i64 = row.get(4)?;
    let confirmed: bool = row.get(5)?;
    let source = review
        .get("source")
        .cloned()
        .unwrap_or_else(|| json!(format!("Imported resume: {name}")));
    Ok(
        json!({"id":id,"name":name,"records":arr(&review,"records"),"revision":revision,"schema_version":1,"entry_type":"imported_resume","fields":{},"attachment":{},
        "confirmed":confirmed,"editable":false,"upload_digest":digest,"confirmed_at":review.get("confirmed_at").cloned().unwrap_or(json!(0.0)),
        "source":source,"history":review.get("history").or(review.get("record_history")).cloned().unwrap_or(json!([])),"selection":arr(&review,"bank_selection")}),
    )
}
fn view(db: &Connection, owner: &str) -> Result<Value> {
    let mut sources = list(db, owner, "bank")?;
    let mut query=db.prepare_cached("SELECT id,name,digest,review,revision,confirmed FROM resumes WHERE owner=? AND json_array_length(review,'$.records')>0 ORDER BY rowid")?;
    let mut resumes = vec![];
    for row in query.query_map([owner], imported_resume)? {
        let mut source = row?;
        resumes.push(json!({"id":source["id"],"name":source["name"],"revision":source["revision"],"confirmed":source["confirmed"],"selection":source["selection"]}));
        source.as_object_mut().unwrap().remove("selection");
        sources.push(source);
    }
    Ok(
        json!({"schema_version":1,"entry_types":*TYPES,"sources":sources,"resumes":resumes,
        "limits":{"groups":100,"records_per_group":300,"records_per_resume":300,"attachment_bytes":10485760,"attachments_per_group":1,"attachment_extensions":[".pdf",".docx"]}}),
    )
}
fn compose(
    base: &Value,
    selections: &Value,
    sources: &[Value],
) -> std::result::Result<Vec<Value>, String> {
    let mut records = validate_records(base)?;
    let groups = selections
        .as_array()
        .filter(|g| g.len() <= 100)
        .ok_or("Choose up to 100 experience sources.")?;
    let mut seen = HashSet::new();
    let mut next = 1 + records
        .iter()
        .map(|r| s(r, "id")[1..].parse::<u64>().unwrap())
        .max()
        .unwrap();
    let mut checked = Vec::new();
    for selection in groups {
        if !selection.is_object() {
            return Err("Invalid experience selection.".into());
        }
        let id = selection["id"]
            .as_str()
            .ok_or("Invalid experience source or revision.")?;
        let revision = selection["revision"]
            .as_i64()
            .ok_or("Invalid experience source or revision.")?;
        let unavailable = "Selected experience changed or is unavailable. Review your bullet bank selection again.";
        let source = sources
            .iter()
            .find(|v| v["id"] == id && v["confirmed"] == true && v["revision"] == revision)
            .ok_or(unavailable)?;
        let ids = selection["record_ids"].as_array().ok_or(unavailable)?;
        let mut selected = HashSet::new();
        if !seen.insert(id)
            || (ids.is_empty() && source["fields"].as_object().is_none_or(|f| f.is_empty()))
            || ids
                .iter()
                .any(|i| i.as_str().is_none_or(|x| !selected.insert(x)))
        {
            return Err(unavailable.into());
        }
        let available = arr(source, "records");
        if selected
            .iter()
            .any(|i| !available.iter().any(|r| r["id"] == *i))
        {
            return Err(
                "A selected experience record is unavailable. Review your selection again.".into(),
            );
        }
        let mut lines = vec![json!({"kind":"heading","text":source["name"]})];
        lines.extend(
            context(source)
                .into_iter()
                .map(|l| json!({"kind":"paragraph","text":l})),
        );
        lines.extend(
            available
                .iter()
                .filter(|r| {
                    selected.contains(s(r, "id"))
                        || source["editable"] == false && r["kind"] != "bullet"
                })
                .cloned(),
        );
        for mut line in lines {
            line["id"] = json!(format!("r{next}"));
            next += 1;
            records.push(line);
        }
        checked.push(json!({"id":id,"revision":revision,"record_ids":ids}));
    }
    validate_records(&json!(records))?;
    Ok(checked)
}
pub(super) fn dispatch(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Value> {
    let key = s(a, "id");
    let revision = a["revision"].as_u64().unwrap_or(0);
    match method {
        "resume_bank" => {}
        "resume_bank_attachment" => return attachment(db, owner, key),
        "resume_bank_attachment_save" => return save_attachment(db, owner, key, a, revision),
        "resume_bank_save" => {
            let previous = get(db, owner, "bank", key)?;
            if !key.is_empty() && previous.is_none() {
                return Ok(err("Experience not found."));
            }
            if key.is_empty() {
                let count: usize = db.query_row(
                    "SELECT count(*) FROM career_records WHERE owner=? AND kind='bank'",
                    [owner],
                    |r| r.get(0),
                )?;
                if revision != 0 || count >= 100 {
                    return Ok(err("Create up to 100 experience groups."));
                }
            } else if previous
                .as_ref()
                .is_some_and(|v| v["revision"].as_u64() != Some(revision))
            {
                return Ok(err("Experience changed. Reload before saving."));
            }
            let mut source = match group(previous.as_ref(), a, revision, now()) {
                Ok(v) => v,
                Err(e) => return Ok(err(e)),
            };
            let key = if key.is_empty() {
                id(db)?
            } else {
                key.to_string()
            };
            source["id"] = json!(key);
            put(db, owner, "bank", &key, &source)?;
        }
        "resume_bank_delete" => {
            let Some(source) = get(db, owner, "bank", key)? else {
                return Ok(err("Experience not found."));
            };
            if source["revision"] != revision {
                return Ok(err("Experience changed. Reload before deleting."));
            }
            remove(db, owner, "bank", key)?;
        }
        "resume_bank_select" => {
            let mut query=db.prepare_cached("SELECT id,name,digest,review,revision,confirmed FROM resumes WHERE owner=? AND id=?")?;
            let Some(base) = query
                .query_row(params![owner, key], imported_resume)
                .optional()?
            else {
                return Ok(err("Resume not found."));
            };
            if base["revision"] != revision {
                return Ok(err("Resume changed. Reload before choosing experience."));
            }
            if base["confirmed"] != true || arr(&base, "records").is_empty() {
                return Ok(err(
                    "Use a confirmed PDF/DOCX record resume for bullet bank selection.",
                ));
            }
            let v = view(db, owner)?;
            let sources: Vec<_> = arr(&v, "sources")
                .iter()
                .filter(|s| s["id"] != key)
                .cloned()
                .collect();
            let checked = match compose(&base["records"], &a["selection"], &sources) {
                Ok(v) => v,
                Err(e) => return Ok(err(e)),
            };
            db.execute("UPDATE resumes SET revision=revision+1,review=json_set(review,'$.bank_selection',json(?)) WHERE owner=? AND id=?",
                params![json!(checked).to_string(),owner,key])?;
        }
        _ => unreachable!(),
    }
    view(db, owner)
}
fn attachment(db: &Connection, owner: &str, key: &str) -> Result<Value> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let row=db.query_row("SELECT json_extract(r.data,'$.attachment'), f.content FROM career_records r JOIN career_files f ON f.owner=r.owner AND f.id=r.id WHERE r.owner=? AND r.kind='bank' AND r.id=?",params![owner,key],|r|Ok((decode(r)?,r.get::<_,Vec<u8>>(1)?))).optional()?;
    let Some((mut meta, content)) = row else {
        return Ok(err("Supporting document not found."));
    };
    meta["content"] = json!(STANDARD.encode(content));
    Ok(meta)
}
fn save_attachment(
    db: &Connection,
    owner: &str,
    key: &str,
    a: &Value,
    revision: u64,
) -> Result<Value> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use sha2::{Digest, Sha256};
    let name = s(a, "name");
    let encoded = s(a, "content");
    if name.chars().count() > 160 || encoded.len() > 13981016 {
        return Ok(err(
            "Use a filename under 160 characters and a file of 10 MB or less.",
        ));
    }
    let Some(mut previous) = get(db, owner, "bank", key)? else {
        return Ok(err("Memory bank entry not found."));
    };
    if previous["revision"] != revision {
        return Ok(err("Entry changed. Reload before changing its file."));
    }
    let bytes = if name.is_empty() && encoded.is_empty() {
        vec![]
    } else {
        let Ok(raw) = STANDARD.decode(encoded) else {
            return Ok(err("Invalid document encoding."));
        };
        let inspected = crate::resumes::inspect(name, &raw)?;
        if inspected.get("error").is_some() {
            return Ok(inspected);
        }
        raw
    };
    let meta = if bytes.is_empty() {
        json!({})
    } else {
        let basename = std::path::Path::new(name)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(name);
        json!({"name":basename,"size":bytes.len(),"digest":hex::encode(Sha256::digest(&bytes))})
    };
    previous["attachment"] = meta;
    let args = json!({"name":previous["name"],"source":previous["source"],"records":previous["records"],"confirm":false});
    let mut saved = match group(Some(&previous), &args, revision, now()) {
        Ok(v) => v,
        Err(e) => return Ok(err(e)),
    };
    saved["id"] = json!(key);
    put(db, owner, "bank", key, &saved)?;
    if bytes.is_empty() {
        db.execute(
            "DELETE FROM career_files WHERE owner=? AND id=?",
            params![owner, key],
        )?;
    } else {
        db.execute("INSERT INTO career_files(owner,id,content) VALUES(?,?,?) ON CONFLICT(owner,id) DO UPDATE SET content=excluded.content",params![owner,key,bytes])?;
    }
    view(db, owner)
}
pub(super) fn export(db: &Connection, owner: &str) -> Result<Vec<Value>> {
    let mut values = list(db, owner, "bank")?;
    for group in &mut values {
        let history = arr(group, "history");
        let created = history
            .first()
            .and_then(|e| e.get("saved_at"))
            .cloned()
            .unwrap_or(json!(0));
        let review = json!({"schema_version":1,"kind":"experience_bank","entry_type":group["entry_type"],"fields":group["fields"],"attachment":group["attachment"],
            "records":group["records"],"source":group["source"],"template":"classic","original":history.first(),"history":history,"confirmed_at":group["confirmed_at"]});
        group["created_at"] = created;
        group["review"] = review;
        group["supporting_document"] = if group["attachment"]["name"].is_string() {
            attachment(db, owner, s(group, "id"))?
        } else {
            json!({})
        };
    }
    Ok(values)
}
