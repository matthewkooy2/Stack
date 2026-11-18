use base64::{Engine, engine::general_purpose::STANDARD};
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
#[path = "recording_queue.rs"]
mod queue;
pub use queue::{worker, worker_handles};

const MAX_BYTES: usize = 10 * 1024 * 1024;
const NOT_FOUND: &str = "Recording not found.";
const TEXT_LIMIT: &str = "Transcript must be 30,000 characters or less.";

pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS recordings(
        id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, client_id TEXT NOT NULL,
        digest BLOB NOT NULL,size INTEGER NOT NULL,created REAL NOT NULL,data TEXT NOT NULL,audio BLOB NOT NULL,
        UNIQUE(owner,client_id));
        CREATE INDEX IF NOT EXISTS recordings_owner_created ON recordings(owner,created DESC);
        CREATE INDEX IF NOT EXISTS recording_sizes ON recordings(owner,size);
        CREATE INDEX IF NOT EXISTS recording_queue ON recordings(json_extract(data,'$.status'),created);
        CREATE TABLE IF NOT EXISTS recording_leases(id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,lease TEXT NOT NULL,deadline REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS transcription_runtime(id INTEGER PRIMARY KEY CHECK(id=1),data TEXT NOT NULL);")
}
pub fn handles(method: &str) -> bool {
    matches!(
        method,
        "transcription_upload"
            | "transcription_list"
            | "transcription_get"
            | "transcription_audio"
            | "transcription_action"
            | "transcription_transfer_complete"
            | "transcription_retry_setup"
    )
}
fn err(s: &str) -> Value {
    json!({"error":s})
}
fn string<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}
fn uuid() -> String {
    let mut id = rand::random::<[u8; 16]>();
    id[6] = (id[6] & 0x0f) | 0x40;
    id[8] = (id[8] & 0x3f) | 0x80;
    let s = hex::encode(id);
    format!(
        "{}-{}-{}-{}-{}",
        &s[..8],
        &s[8..12],
        &s[12..16],
        &s[16..20],
        &s[20..]
    )
}

fn wav_duration(raw: &[u8]) -> std::result::Result<f64, &'static str> {
    const INVALID: &str = "Invalid or interrupted WAV recording.";
    const PCM: &str = "Use 16 kHz mono, 16-bit PCM WAV audio.";
    const INCOMPLETE: &str =
        "The recording is incomplete. Keep it and retry after stopping the microphone.";
    if !(44..=MAX_BYTES).contains(&raw.len()) || &raw[..4] != b"RIFF" || &raw[8..12] != b"WAVE" {
        return Err("Use a WAV recording of 10 MB or less.");
    }
    let u16le = |bytes: &[u8]| u16::from_le_bytes(bytes[..2].try_into().unwrap());
    let u32le = |bytes: &[u8]| u32::from_le_bytes(bytes[..4].try_into().unwrap());
    let riff_end = 8usize
        .saturating_add(u32le(&raw[4..]) as usize)
        .min(raw.len());
    let mut pos = 12;
    let mut format = false;
    while pos + 8 <= riff_end {
        let tag = &raw[pos..pos + 4];
        let size = u32le(&raw[pos + 4..]) as usize;
        pos += 8;
        let end = pos.checked_add(size).ok_or(INVALID)?;
        if tag == b"data" {
            if !format {
                return Err(INVALID);
            }
            let count = size / 2;
            let seconds = count as f64 / 16000.0;
            if !(0.3..=300.0).contains(&seconds) {
                return Err("Record between 0.3 seconds and five minutes.");
            }
            if end > riff_end || !size.is_multiple_of(2) {
                return Err(INCOMPLETE);
            }
            let energy: u64 = raw[pos..end]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|pair| {
                    let sample = i16::from_le_bytes([pair[0], pair[1]]) as i64;
                    (sample * sample) as u64
                })
                .sum();
            if energy < 1600 * count as u64 {
                return Err("No audible answer detected. Check your microphone and record again.");
            }
            return Ok(seconds);
        }
        if end > riff_end {
            return Err(INVALID);
        }
        if tag == b"fmt " {
            if size < 16 {
                return Err(INVALID);
            }
            let chunk = &raw[pos..end];
            let encoding = u16le(chunk);
            let extensible_pcm = [
                1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71,
            ];
            let pcm = encoding == 1
                || encoding == 0xfffe && size >= 40 && chunk[24..40] == extensible_pcm;
            if !pcm
                || u16le(&chunk[2..]) != 1
                || u32le(&chunk[4..]) != 16000
                || u16le(&chunk[14..]) != 16
            {
                return Err(PCM);
            }
            format = true;
        }
        pos = end + size % 2;
    }
    Err(INVALID)
}
pub fn get(db: &Connection, owner: &str, id: &str) -> Result<Option<Value>> {
    db.query_row(
        "SELECT data FROM recordings WHERE owner=? AND id=?",
        params![owner, id],
        |r| r.get(0),
    )
    .optional()
}
pub fn list(db: &Connection, owner: &str) -> Result<Vec<Value>> {
    let mut q =
        db.prepare_cached("SELECT data FROM recordings WHERE owner=? ORDER BY created DESC,id")?;
    let rows = q.query_map([owner], |r| r.get(0))?;
    rows.collect()
}
pub fn remove(db: &Connection, owner: &str, id: &str) -> Result<bool> {
    Ok(db.execute(
        "DELETE FROM recordings WHERE owner=? AND id=?",
        params![owner, id],
    )? > 0)
}
fn upload(db: &Connection, owner: &str, a: &Value) -> Result<Value> {
    let Some(supplied) = a.get("local_transcript").map_or(Some(""), Value::as_str) else {
        return Ok(err(TEXT_LIMIT));
    };
    if supplied.chars().count() > 30000 {
        return Ok(err(TEXT_LIMIT));
    }
    let original = supplied.trim();
    let client = string(a, "client_id");
    if !(12..=80).contains(&client.len())
        || !client
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    {
        return Ok(err("A stable recording identifier is required."));
    }
    let Some(encoded) = a["content"]
        .as_str()
        .filter(|text| text.len() <= MAX_BYTES.div_ceil(3) * 4)
    else {
        return Ok(err("Recording must be 10 MB or less."));
    };
    let Ok(raw) = STANDARD.decode(encoded) else {
        return Ok(err("Invalid recording transfer."));
    };
    let duration = match wav_duration(&raw) {
        Ok(v) => v,
        Err(error) => return Ok(err(error)),
    };
    let digest = Sha256::digest(&raw);
    let old: Option<(Vec<u8>, Value)> = db
        .query_row(
            "SELECT digest,data FROM recordings WHERE owner=? AND client_id=?",
            params![owner, client],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((prev, saved)) = old {
        if prev[..] != digest[..] {
            return Ok(err(
                "This recording identifier already belongs to different audio.",
            ));
        }
        if !original.is_empty()
            && (saved["model"] != "Apple SpeechTranscriber"
                || saved["original_transcript"] != original)
        {
            return Ok(err(
                "This recording identifier already belongs to another transcription. Reopen the saved recording.",
            ));
        }
        return Ok(saved);
    }
    let (count, owned): (u64, u64) = db.query_row(
        "SELECT count(*),coalesce(sum(size),0) FROM recordings WHERE owner=?",
        [owner],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let bytes = raw.len() as u64;
    if count >= 50 || owned + bytes > 500 * 1024 * 1024 {
        return Ok(err(
            "Recording storage is full. Delete a saved recording before uploading another.",
        ));
    }
    let total: u64 = db.query_row("SELECT coalesce(sum(size),0) FROM recordings", [], |r| {
        r.get(0)
    })?;
    if total + bytes > 5 * 1024u64.pow(3) || (original.is_empty() && queue::full(db, owner)?) {
        return Ok(err(
            "The transcription queue is full. Your recording stays on this phone; retry later.",
        ));
    }
    let id = uuid();
    let at = crate::now();
    let local = !original.is_empty();
    let data = json!({"id":id,"client_id":client,"created_at":at,"duration_seconds":duration,"size":bytes,
        "status":if local{"completed"}else{"queued"},"attempts":0,"stage_at":at,"percent":if local{Some(100)}else{None},
        "error":"","original_transcript":original,"transcript":original,"revision":if local{1}else{0},
        "model":if local{"Apple SpeechTranscriber"}else{"whisper.cpp/base.en"},"timings":{"transfer_ms":null,"queue_ms":0,"decode_ms":0,"load_ms":0,"transcribe_ms":0}});
    db.execute("INSERT INTO recordings(id,owner,client_id,digest,size,created,data,audio) VALUES(?,?,?,?,?,?,?,?)",
        params![id,owner,client,&digest[..],bytes,at,data,raw])?;
    Ok(data)
}
fn update(db: &Connection, owner: &str, key: &str, data: &Value) -> Result<()> {
    db.execute(
        "UPDATE recordings SET data=? WHERE owner=? AND id=?",
        params![data, owner, key],
    )?;
    Ok(())
}
pub fn dispatch(db: &Connection, owner: &str, method: &str, a: &Value) -> Result<Option<Value>> {
    if !handles(method) {
        return Ok(None);
    }
    let key = string(a, "id");
    let result = match method {
        "transcription_list" => {
            json!({"recordings":list(db,owner)?,"runtime":queue::public_runtime(db)?,"client_transcripts":true})
        }
        "transcription_retry_setup" => queue::retry_setup(db)?,
        "transcription_upload" => upload(db, owner, a)?,
        "transcription_get" => get(db, owner, key)?.unwrap_or_else(|| err(NOT_FOUND)),
        "transcription_audio" => {
            let content: Option<Vec<u8>> = db
                .query_row(
                    "SELECT audio FROM recordings WHERE owner=? AND id=?",
                    params![owner, key],
                    |r| r.get(0),
                )
                .optional()?;
            match content {
                Some(raw) => json!({"name":format!("{key}.wav"),"content":STANDARD.encode(raw)}),
                None => err(NOT_FOUND),
            }
        }
        "transcription_transfer_complete" => {
            let ms = a["elapsed_ms"]
                .as_f64()
                .or_else(|| a["elapsed_ms"].as_str()?.parse::<f64>().ok());
            let Some(ms) = ms.filter(|v| (0.0..=86400000.0).contains(v)) else {
                return Ok(Some(err("Invalid upload timing.")));
            };
            let Some(mut data) = get(db, owner, key)? else {
                return Ok(Some(err(NOT_FOUND)));
            };
            data["timings"]["transfer_ms"] = json!(ms);
            update(db, owner, key, &data)?;
            json!({"saved":true})
        }
        "transcription_action" => {
            let Some(mut data) = get(db, owner, key)? else {
                return Ok(Some(err(NOT_FOUND)));
            };
            match string(a, "action") {
                "save" => {
                    if data["status"] != "completed" {
                        return Ok(Some(err(
                            "Wait for transcription to finish before editing.",
                        )));
                    }
                    if data["revision"].as_u64() != a["revision"].as_u64() {
                        return Ok(Some(err(
                            "The transcript changed on another device. Reopen it before saving.",
                        )));
                    }
                    let Some(text) = a
                        .get("text")
                        .map_or(Some(""), Value::as_str)
                        .filter(|t| t.chars().count() <= 30000)
                    else {
                        return Ok(Some(err(TEXT_LIMIT)));
                    };
                    data["transcript"] = json!(text);
                    data["revision"] = json!(data["revision"].as_u64().unwrap() + 1);
                    update(db, owner, key, &data)?;
                    data
                }
                "cancel" | "retry" => {
                    queue::action(db, owner, key, &mut data, string(a, "action"))?
                }
                "delete" => {
                    remove(db, owner, key)?;
                    json!({"deleted":true})
                }
                _ => err("Unknown recording action."),
            }
        }
        _ => unreachable!(),
    };
    Ok(Some(result))
}
#[cfg(test)]
mod tests {
    use super::*;

    fn open() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON; CREATE TABLE accounts(id TEXT PRIMARY KEY); INSERT INTO accounts VALUES ('a'),('b');").unwrap();
        init(&db).unwrap();
        db
    }
    fn wav(value: i16) -> Vec<u8> {
        let count = 4800;
        let data_size = (count * 2) as u32;
        let mut bytes = Vec::new();
        bytes.extend(b"RIFF");
        bytes.extend((36 + data_size).to_le_bytes());
        bytes.extend(b"WAVEfmt ");
        bytes.extend(16u32.to_le_bytes());
        bytes.extend(1u16.to_le_bytes());
        bytes.extend(1u16.to_le_bytes());
        bytes.extend(16000u32.to_le_bytes());
        bytes.extend(32000u32.to_le_bytes());
        bytes.extend(2u16.to_le_bytes());
        bytes.extend(16u16.to_le_bytes());
        bytes.extend(b"data");
        bytes.extend(data_size.to_le_bytes());
        for _ in 0..count {
            bytes.extend(value.to_le_bytes());
        }
        bytes
    }
    fn rpc(db: &Connection, owner: &str, op: &str, args: Value) -> Value {
        dispatch(db, owner, op, &args).unwrap().unwrap()
    }
    #[test]
    fn recording_original_replay_edit_audio_isolation_and_deletion() {
        let db = open();
        let audio = STANDARD.encode(wav(500));
        let args = json!({"content":audio,"client_id":"synthetic-test-00001","local_transcript":" First draft "});
        let rec = rpc(&db, "a", "transcription_upload", args.clone());
        let id = &rec["id"];
        assert_eq!(rec["original_transcript"], "First draft");
        assert_eq!(rec["duration_seconds"], 0.3);
        assert_eq!(rec["status"], "completed");
        assert_eq!(rec["model"], "Apple SpeechTranscriber");
        assert!(rec.get("owner").is_none());
        let edited = rpc(
            &db,
            "a",
            "transcription_action",
            json!({"id":id,"action":"save","text":"New draft","revision":1}),
        );
        assert_eq!(edited["revision"], 2);
        assert_eq!(edited["original_transcript"], "First draft");
        assert_eq!(rpc(&db, "a", "transcription_upload", args.clone()), edited);
        assert_eq!(
            rpc(&db, "a", "transcription_audio", json!({"id":id}))["content"],
            audio
        );
        assert!(
            rpc(
                &db,
                "a",
                "transcription_action",
                json!({"id":id,"action":"save","text":"Stale","revision":1})
            )["error"]
                .as_str()
                .unwrap()
                .contains("another device")
        );
        let mut conflicting = args.clone();
        conflicting["local_transcript"] = json!("Replaced original");
        assert!(
            rpc(&db, "a", "transcription_upload", conflicting)["error"]
                .as_str()
                .unwrap()
                .contains("another transcription")
        );
        let mut different = args.clone();
        different["content"] = json!(STANDARD.encode(wav(501)));
        assert!(
            rpc(&db, "a", "transcription_upload", different)["error"]
                .as_str()
                .unwrap()
                .contains("different audio")
        );
        assert_eq!(
            rpc(
                &db,
                "a",
                "transcription_transfer_complete",
                json!({"id":id,"elapsed_ms":750})
            )["saved"],
            true
        );
        assert_eq!(
            rpc(&db, "a", "transcription_get", json!({"id":id}))["timings"]["transfer_ms"],
            750.0
        );
        for (op, a) in [
            ("transcription_audio", json!({"id":id})),
            ("transcription_get", json!({"id":id})),
            ("transcription_action", json!({"id":id,"action":"delete"})),
            (
                "transcription_transfer_complete",
                json!({"id":id,"elapsed_ms":1}),
            ),
        ] {
            assert_eq!(rpc(&db, "b", op, a)["error"], NOT_FOUND);
        }
        let other = rpc(&db, "b", "transcription_upload", args);
        assert_ne!(id, &other["id"]);
        db.execute("DELETE FROM accounts WHERE id='a'", []).unwrap();
        assert!(list(&db, "a").unwrap().is_empty());
        assert_eq!(list(&db, "b").unwrap().len(), 1);
        assert_eq!(
            rpc(
                &db,
                "b",
                "transcription_action",
                json!({"id":other["id"],"action":"delete"})
            )["deleted"],
            true
        );
    }
    #[test]
    fn rejects_invalid_pcm_and_queues_valid_audio() {
        assert!(wav_duration(&wav(0)).unwrap_err().contains("No audible"));
        let mut truncated = wav(100);
        truncated.pop();
        assert!(wav_duration(&truncated).unwrap_err().contains("incomplete"));
        let mut stereo = wav(500);
        stereo[22] = 2;
        assert!(wav_duration(&stereo).unwrap_err().contains("mono"));
        let db = open();
        let args = json!({"client_id":"audio-only-case","content":STANDARD.encode(wav(600))});
        let rec = rpc(&db, "a", "transcription_upload", args.clone());
        assert_eq!(rec["status"], "queued");
        assert_eq!(rec["attempts"], 0);
        assert_eq!(rec["original_transcript"], "");
        assert_eq!(rpc(&db, "a", "transcription_upload", args), rec);
        assert_eq!(
            rpc(
                &db,
                "a",
                "transcription_action",
                json!({"id":rec["id"],"action":"retry"})
            ),
            err("Only failed or cancelled transcriptions can be retried.")
        );
        assert_eq!(
            rpc(&db, "a", "transcription_retry_setup", json!({}))["probe_passed"],
            false
        );
        assert_eq!(
            rpc(&db, "a", "transcription_list", json!({}))["client_transcripts"],
            true
        );
    }
    #[test]
    fn worker_supplied_transcript_requires_live_owned_lease() {
        let db = open();
        let call = |m: &str, a: Value| queue::authorized(&db, m, &a).unwrap();
        let audio = STANDARD.encode(wav(500));
        let rec = rpc(
            &db,
            "a",
            "transcription_upload",
            json!({"client_id":"fixture-first-recording","content":audio}),
        );
        let id = &rec["id"];
        let local = rpc(
            &db,
            "b",
            "transcription_upload",
            json!({"client_id":"fixture-local-recording","content":audio,"local_transcript":"Own transcript"}),
        );
        let first = call("transcription_processing_claim", json!({}));
        assert_eq!(&first["id"], id);
        assert_eq!(first["content"], audio);
        assert!(call("transcription_processing_claim", json!({}))["idle"] == true);
        assert!(
            get(&db, "a", id.as_str().unwrap())
                .unwrap()
                .unwrap()
                .get("lease")
                .is_none()
        );
        let mut auth = json!({"id":id,"owner":"b","lease":first["lease"],"stage":"transcribing","percent":75,"timings":{"load_ms":12}});
        assert_eq!(
            call("transcription_processing_progress", auth.clone()),
            err(NOT_FOUND)
        );
        auth["owner"] = json!("a");
        assert_eq!(
            call("transcription_processing_progress", auth.clone())["saved"],
            true
        );
        auth["stage"] = json!("loading");
        assert!(call("transcription_processing_progress", auth.clone())["error"].is_string());
        rpc(
            &db,
            "a",
            "transcription_action",
            json!({"action":"cancel","id":id}),
        );
        auth["result"] = json!({"text":"stale synthetic text"});
        assert!(call("transcription_processing_finish", auth.clone())["error"].is_string());
        let retry = rpc(
            &db,
            "a",
            "transcription_action",
            json!({"action":"retry","id":id}),
        );
        assert_eq!(retry["status"], "queued");
        let second = call("transcription_processing_claim", json!({}));
        assert_ne!(second["lease"], first["lease"]);
        db.execute(
            "UPDATE recording_leases SET deadline=0 WHERE id=?",
            [id.as_str().unwrap()],
        )
        .unwrap();
        auth["lease"] = second["lease"].clone();
        assert!(call("transcription_processing_finish", auth.clone())["error"].is_string());
        let third = call("transcription_processing_claim", json!({}));
        auth["lease"] = third["lease"].clone();
        auth["result"] = json!({"text":" Synthetic worker transcript ","transcribe_ms":55});
        assert_eq!(call("transcription_processing_finish", auth)["saved"], true);
        let done = get(&db, "a", id.as_str().unwrap()).unwrap().unwrap();
        assert_eq!(done["transcript"], "Synthetic worker transcript");
        assert_eq!(done["revision"], 1);
        assert_eq!(done["percent"], 100);
        assert_eq!(
            get(&db, "b", local["id"].as_str().unwrap())
                .unwrap()
                .unwrap()["original_transcript"],
            "Own transcript"
        );
        assert_eq!(
            call("transcription_processing_claim", json!({}))["idle"],
            true
        );
    }

    #[test]
    fn pending_limits_and_retry_after_interrupted_leases() {
        let db = open();
        let audio = STANDARD.encode(wav(500));
        let mut ids = vec![];
        for i in 0..3 {
            let v = rpc(
                &db,
                "a",
                "transcription_upload",
                json!({"client_id":format!("queue-fixture-{i}"),"content":audio}),
            );
            ids.push(v["id"].clone());
        }
        let fourth = json!({"client_id":"queue-fixture-fourth","content":audio});
        assert!(rpc(&db, "a", "transcription_upload", fourth.clone())["error"].is_string());
        for _ in 0..3 {
            let claim =
                queue::authorized(&db, "transcription_processing_claim", &json!({})).unwrap();
            assert_eq!(claim["id"], ids[0]);
            db.execute(
                "UPDATE recording_leases SET deadline=0 WHERE id=?",
                [ids[0].as_str().unwrap()],
            )
            .unwrap();
        }
        let next = queue::authorized(&db, "transcription_processing_claim", &json!({})).unwrap();
        assert_eq!(next["id"], ids[1]);
        assert_eq!(
            get(&db, "a", ids[0].as_str().unwrap()).unwrap().unwrap()["status"],
            "failed"
        );
        assert_eq!(
            rpc(&db, "a", "transcription_upload", fourth)["status"],
            "queued"
        );
        assert!(
            rpc(
                &db,
                "a",
                "transcription_action",
                json!({"id":ids[0],"action":"retry"})
            )["error"]
                .is_string()
        );
    }

    #[test]
    fn readiness_generation_protects_worker_reports() {
        let db = open();
        let call =
            |a: Value| queue::authorized(&db, "transcription_processing_runtime", &a).unwrap();
        let old = call(json!({"action":"start"}));
        let new = call(json!({"action":"start"}));
        assert!(call(json!({"action":"report","generation":old["generation"],"result":{"status":"ready"}}))["error"].is_string());
        let report = call(
            json!({"action":"report","generation":new["generation"],"result":{"status":"unavailable","stage":"failed","message":"Synthetic setup fixture","missing_tools":["cmake"]}}),
        );
        assert_eq!(report["status"], "unavailable");
        let view = rpc(&db, "a", "transcription_list", json!({}));
        assert!(view["runtime"].get("generation").is_none());
        assert_eq!(view["runtime"]["missing_tools"], json!(["cmake"]));
        assert_eq!(
            rpc(&db, "a", "transcription_retry_setup", json!({}))["status"],
            "pending"
        );
        assert_eq!(call(json!({}))["status"], "pending");
    }
}
