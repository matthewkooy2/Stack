#[path = "provider_mail.rs"]
mod mail;
use crate::{account, auth::random_id, now, score_docs};
pub use mail::{google_missing, project, schedule_sync, worker_connection};
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const READ: &str = "https://www.googleapis.com/auth/gmail.readonly";
pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS google_pending(
        state TEXT PRIMARY KEY,owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        sealed TEXT NOT NULL,capabilities TEXT NOT NULL,expires REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS google_pending_expiration ON google_pending(expires);
        CREATE TABLE IF NOT EXISTS google_connections(
        id TEXT PRIMARY KEY,owner TEXT NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
        sealed TEXT NOT NULL,scopes TEXT NOT NULL,state TEXT NOT NULL,tracking INTEGER NOT NULL,
        generation TEXT NOT NULL,checkpoint TEXT NOT NULL DEFAULT '',calendar_id TEXT NOT NULL DEFAULT '',updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS google_calendar_receipts(owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,interview TEXT NOT NULL,receipt TEXT NOT NULL,PRIMARY KEY(owner,interview));
        CREATE TABLE IF NOT EXISTS push_devices(owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        key TEXT NOT NULL,sealed TEXT NOT NULL,PRIMARY KEY(owner,key));
        CREATE TABLE IF NOT EXISTS push_notifications(id TEXT PRIMARY KEY,owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        run_id TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'queued', deliveries TEXT NOT NULL DEFAULT '[]', initialized INTEGER NOT NULL DEFAULT 0,
        receipt TEXT NOT NULL DEFAULT '', due REAL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS push_due ON push_notifications(due);
        CREATE INDEX IF NOT EXISTS push_notice_owner ON push_notifications(owner);")
}
fn helper(a: &Value) -> Result<Value> {
    score_docs::helper(
        a,
        include_str!("providers.py"),
        "Provider integration is unavailable.",
    )
}
fn error(s: &str) -> Value {
    json!({"error":s})
}
fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}
pub fn connections(db: &Connection, owner: &str) -> Result<Vec<Value>> {
    let policy = account::policy(db, owner)?;
    let legacy = policy["enabled"] == true
        && policy["expires_at"].as_f64().unwrap_or(0.0) > now()
        && policy["actions"]
            .as_array()
            .is_some_and(|v| v.contains(&json!("gmail_read")));
    let mut q =
        db.prepare_cached("SELECT id,state,scopes,tracking FROM google_connections WHERE owner=?")?;
    q.query_map([owner],|r|{
        let state:String=r.get(1)?;let scopes:Value=r.get(2)?;
        let tracking=state=="connected" && scopes.as_array().is_some_and(|v|v.contains(&json!(READ))) && (r.get::<_,bool>(3)? || legacy);
        Ok(json!({"id":r.get::<_,String>(0)?,"provider":"google","state":state,"scopes":scopes,"tracking":tracking}))
    })?.collect()
}
pub fn handles(m: &str) -> bool {
    matches!(
        m,
        "agent_google_start"
            | "agent_google_start_native"
            | "agent_google_finish"
            | "agent_disconnect"
            | "agent_register_push"
            | "agent_remove_push"
            | "agent_notification_status"
            | "gmail_scan_dismiss"
            | "gmail_scan_status"
            | "gmail_scan_start"
            | "agent_resolve_event"
    )
}
fn hash(v: &str) -> String {
    hex::encode(Sha256::digest(v.as_bytes()))
}

pub fn external(m: &str) -> bool {
    matches!(
        m,
        "agent_google_start"
            | "agent_google_start_native"
            | "agent_google_finish"
            | "agent_register_push"
    )
}
fn admitted(db: &Connection, token: &str) -> Result<Option<String>> {
    let Some((owner, invited)) = crate::auth::principal(db, token)? else {
        return Ok(None);
    };
    Ok(crate::auth::admitted(invited)
        .ok()
        .filter(|v| *v)
        .map(|_| owner))
}
pub fn external_rpc(
    db: &mut Connection,
    m: &str,
    token: &str,
    a: &Value,
) -> Result<crate::Response> {
    let denied = || {
        (
            axum::http::StatusCode::FORBIDDEN,
            json!({"ok":false,"error":{"message":"Sign in and accept your beta invitation."}}),
        )
    };
    let Some(owner) = admitted(db, token)? else {
        return Ok(denied());
    };
    if let Some(response) = crate::arguments::missing(m, a) {
        return Ok(response);
    }
    let state = format!(
        "{}{}",
        if m.ends_with("_native") || a["native"] == true {
            "native."
        } else {
            ""
        },
        random_id()
    );
    let mut caps = a["capabilities"].clone();
    let device = s(a, "device_token");
    let mut generation = None;
    let payload = match m {
        "agent_google_start" | "agent_google_start_native" => {
            if !caps
                .as_array()
                .is_some_and(|v| v.iter().all(Value::is_string))
            {
                return Ok(crate::result(error("Unsupported Google capability.")));
            }
            json!({"op":"google_start","state":state,"capabilities":caps})
        }
        "agent_google_finish" => {
            let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if admitted(&tx, token)?.as_ref() != Some(&owner) {
                return Ok(denied());
            }
            let item=tx.query_row("DELETE FROM google_pending WHERE state=? AND owner=? AND expires>? RETURNING sealed,capabilities",params![hash(s(a,"state")),owner,now()],|r|Ok((r.get::<_,String>(0)?,r.get::<_,Value>(1)?))).optional()?;
            let Some((sealed, capabilities)) = item else {
                return Ok(crate::result(error(
                    "Google connection belongs to another account or has expired.",
                )));
            };
            generation = tx
                .query_row(
                    "SELECT generation FROM google_connections WHERE owner=?",
                    [&owner],
                    |r| r.get::<_, String>(0),
                )
                .optional()?;
            tx.commit()?;
            caps = capabilities;
            json!({"op":"google_finish","code":s(a,"code"),"sealed":sealed,"capabilities":caps})
        }
        "agent_register_push" => {
            if !(device.starts_with("ExponentPushToken[") || device.starts_with("ExpoPushToken[")) {
                return Ok(crate::result(error("Unsupported push token.")));
            }
            if device.chars().count() > 200 {
                return Ok(crate::result(error("Invalid push token.")));
            }
            json!({"op":"seal_push","device":device})
        }
        _ => return Err(rusqlite::Error::InvalidQuery),
    };
    let out = helper(&payload)?;
    if out.get("error").is_some() {
        return Ok(crate::result(out));
    }
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    if admitted(&tx, token)?.as_ref() != Some(&owner) {
        return Ok(denied());
    }
    let value = match m {
        "agent_register_push" => {
            tx.execute(
                "INSERT INTO push_devices VALUES(?,?,?) ON CONFLICT DO NOTHING",
                params![owner, push_key(device), out["sealed"].as_str()],
            )?;
            json!({"registered":true})
        }
        "agent_google_finish" => {
            let latest = tx
                .query_row(
                    "SELECT generation FROM google_connections WHERE owner=?",
                    [&owner],
                    |r| r.get::<_, String>(0),
                )
                .optional()?;
            if generation != latest {
                return Ok(crate::result(error(
                    "Google connection changed. Start a new connection.",
                )));
            }
            let tracking = caps.as_array().is_some_and(|v| v.contains(&json!("read")));
            tx.execute("INSERT INTO google_connections(id,owner,sealed,scopes,state,tracking,generation,updated)
              VALUES(?,?,?,?,'connected',?,?,?) ON CONFLICT(owner) DO UPDATE SET sealed=excluded.sealed,scopes=excluded.scopes,
              state='connected',tracking=tracking OR excluded.tracking,generation=excluded.generation,updated=excluded.updated",
              params![random_id(),owner,out["sealed"].as_str(),out["scopes"],tracking,random_id(),now()])?;
            settings(&tx, &owner)?
        }
        _ => {
            tx.execute("DELETE FROM google_pending WHERE expires<=?", [now()])?;
            tx.execute(
                "INSERT INTO google_pending VALUES(?,?,?,?,?)",
                params![
                    hash(&state),
                    owner,
                    out["sealed"].as_str(),
                    caps,
                    now() + 600.0
                ],
            )?;
            json!({"url":out["url"]})
        }
    };
    tx.commit()?;
    Ok(crate::result(value))
}
fn settings(db: &Connection, owner: &str) -> Result<Value> {
    account::dispatch(db, owner, "agent_settings", &json!({}))?.ok_or(rusqlite::Error::InvalidQuery)
}
fn push_key(device: &str) -> String {
    let mut encoded = String::new();
    for c in serde_json::to_string(device).unwrap().chars() {
        if c.is_ascii() && c != '\x7f' {
            encoded.push(c);
        } else {
            for u in c.encode_utf16(&mut [0u16; 2]) {
                encoded.push_str(&format!("\\u{u:04x}"));
            }
        }
    }
    hash(&encoded)
}
fn notification_status(db: &Connection, owner: &str, id: &str) -> Result<Value> {
    let mut q=db.prepare("SELECT id,run_id,state,deliveries FROM push_notifications WHERE owner=?1 AND (?2='' OR id=?2) ORDER BY rowid")?;
    let rows=q.query_map(params![owner,id],|r|{
        let deliveries:Value=r.get(3)?;
        let devices:Vec<_>=deliveries.as_array().into_iter().flatten().map(|d|json!({"state":d["state"],"attempts":d["attempts"],"receipt_attempts":d["receipt_attempts"],"ticket":d["ticket"],"error":d["error"]})).collect();
        Ok(json!({"id":r.get::<_,String>(0)?,"run_id":r.get::<_,String>(1)?,"state":r.get::<_,String>(2)?,"devices":devices}))
    })?.collect::<Result<Vec<_>>>()?;
    Ok(if id.is_empty() {
        json!({"notifications":rows})
    } else {
        rows.into_iter()
            .next()
            .unwrap_or_else(|| error("Notification not found."))
    })
}
pub fn scan_status(db: &Connection, owner: &str) -> Result<Value> {
    let mut q=db.prepare("SELECT id,data FROM career_records WHERE owner=? AND kind='mail_event' AND json_type(data,'$.discovery')='object'
        AND coalesce(json_extract(data,'$.ambiguous'),0) AND NOT coalesce(json_extract(data,'$.resolved'),0) ORDER BY rowid")?;
    let reviews = q
        .query_map([owner], |r| {
            let mut data: Value = r.get(1)?;
            data["id"] = json!(r.get::<_, String>(0)?);
            Ok(data)
        })?
        .collect::<Result<Vec<_>>>()?;
    Ok(json!({"scan":mail::latest(db,owner)?,"reviews":reviews}))
}
pub fn dispatch(db: &Connection, owner: &str, m: &str, a: &Value) -> Result<Option<Value>> {
    let id = s(a, "id");
    let result=match m {
        "agent_disconnect"=>{
            if db.execute("UPDATE google_connections SET state='revoked',sealed='',checkpoint='',tracking=0,generation=lower(hex(randomblob(16))) WHERE owner=? AND id=?",params![owner,id])?==0 {
                error("Connection not found.")
            }else{settings(db,owner)?}
        }
        "agent_remove_push"=>{
            db.execute("DELETE FROM push_devices WHERE owner=? AND key=?",params![owner,push_key(s(a,"device_token"))])?;
            json!({"removed":true})
        }
        "agent_notification_status"=>notification_status(db,owner,id)?,
        "gmail_scan_status"=>scan_status(db,owner)?,
        "gmail_scan_start"=>mail::start(db,owner,a)?,
        "agent_resolve_event"=>mail::resolve(db,owner,a)?,
        "gmail_scan_dismiss"=>{
            let item=db.query_row("SELECT data FROM career_records WHERE owner=? AND kind='mail_event' AND id=? AND json_type(data,'$.discovery')='object'",params![owner,id],|r|r.get::<_,Value>(0)).optional()?;
            if let Some(mut item)=item {
                if item["ambiguous"]==true {
                    item["resolved"]=json!(true);item["ambiguous"]=json!(false);item["dismissed"]=json!(true);
                    db.execute("UPDATE career_records SET data=? WHERE owner=? AND kind='mail_event' AND id=?",params![item,owner,id])?;
                }
                scan_status(db,owner)?
            }else{error("This message was not found.")}
        }
        _=>return Ok(None)
    };
    Ok(Some(result))
}

pub fn notify(db: &Connection, owner: &str, id: &str, run: &Value) -> Result<()> {
    let status = s(run, "status");
    if !(matches!(
        status,
        "needs_input" | "failed" | "uncertain" | "review" | "blocked"
    ) || (status == "completed" && run["kind"] == "calendar"))
    {
        return Ok(());
    }
    let enabled:bool=db.query_row("SELECT coalesce((SELECT json_extract(data,'$.notifications') FROM job_records WHERE kind='profile' AND owner=? LIMIT 1),1)",[owner],|r|r.get(0))?;
    if enabled {
        let key = hash(&json!([id, status, run["index"]]).to_string());
        db.execute(
            "INSERT INTO push_notifications(id,owner,run_id) VALUES(?,?,?) ON CONFLICT DO NOTHING",
            params![key, owner, id],
        )?;
    }
    Ok(())
}
pub fn start_worker(path: String) {
    std::thread::spawn(move || {
        loop {
            let result = crate::open(&path).and_then(|db| -> Result<()> {
                loop {
                    let due: bool = db.query_row(
                        "SELECT EXISTS(SELECT 1 FROM push_notifications WHERE due<=?)",
                        [now()],
                        |r| r.get(0),
                    )?;
                    if due {
                        let script = concat!(
                            include_str!("push_delivery.py"),
                            "\n",
                            include_str!("providers.py")
                        );
                        let value = score_docs::helper(
                            &json!({"op":"deliver","path":path}),
                            script,
                            "Push delivery is unavailable.",
                        )?;
                        if value["worked"] == true {
                            continue;
                        }
                    }
                    std::thread::sleep(std::time::Duration::from_secs(3));
                }
            });
            if let Err(e) = result {
                eprintln!("Notification database error: {e}");
            }
            std::thread::sleep(std::time::Duration::from_secs(3));
        }
    });
}
pub fn revoke_account(db: &Connection, owner: &str) -> Result<Option<Value>> {
    let sealed = db
        .query_row(
            "SELECT sealed FROM google_connections WHERE owner=? AND sealed<>''",
            [owner],
            |r| r.get::<_, String>(0),
        )
        .optional()?;
    if let Some(sealed) = sealed {
        let out = helper(&json!({"op":"revoke","sealed":sealed}))?;
        if out["revoked"] != true {
            return Ok(Some(error(
                "Could not disconnect Google. Please retry account deletion.",
            )));
        }
    }
    Ok(None)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scan_review_updates_only_its_application_and_is_idempotent() {
        let db = crate::open(":memory:").unwrap();
        crate::auth::init(&db).unwrap();
        crate::account::init(&db).unwrap();
        crate::career::init(&db).unwrap();
        crate::jobs::init(&db).unwrap();
        crate::resumes::init(&db).unwrap();
        for owner in ["alpha", "beta"] {
            db.execute(
                "INSERT INTO accounts(id,username,password) VALUES(?,?,'fixture')",
                params![owner, owner],
            )
            .unwrap();
        }
        let app = json!({"id":"app","job_id":"job","demo":false,"job":{"id":"job","company":"Fixture","title":"Engineer"},"history":[]});
        db.execute(
            "INSERT INTO job_records VALUES('alpha','application','app',?)",
            [app],
        )
        .unwrap();
        let event = json!({"discovery":{"confirmed":false},"ambiguous":true,"key":"m","quote":"interview","at":42});
        mail::store_event(&db, "alpha", "mail_event", "message", &event, 2.0).unwrap();
        let args = json!({"application_id":"app","id":"message","status":"Interview"});
        assert_eq!(
            mail::resolve(&db, "beta", &args).unwrap()["error"],
            "This message was not found."
        );
        for _ in 0..2 {
            assert_eq!(
                mail::resolve(&db, "alpha", &args).unwrap()["events"][0]["resolved"],
                true
            );
        }
        let value: Value = db
            .query_row(
                "SELECT data FROM job_records WHERE owner='alpha' AND key='app'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(value["status"], "Interview");
        assert_eq!(value["history"].as_array().unwrap().len(), 1);
        assert!(
            scan_status(&db, "alpha").unwrap()["reviews"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            mail::start(&db, "alpha", &json!({"since":100})).unwrap()["error"],
            "Connect Gmail before starting a scan."
        );
    }
}
