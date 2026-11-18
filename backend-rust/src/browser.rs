use crate::{Response, auth, jobs, result, runs};
use reqwest::blocking::Client;
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use std::{env, io::Read, sync::LazyLock, time::Duration};

static HTTP: LazyLock<Client> = LazyLock::new(|| {
    Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap()
});

pub fn handles(name: &str) -> bool {
    matches!(
        name,
        "agent_browser" | "agent_browser_subscribe" | "agent_browser_control"
    )
}

pub async fn stream(
    axum::extract::State(service): axum::extract::State<std::sync::Arc<crate::Service>>,
    axum::extract::ConnectInfo(peer): axum::extract::ConnectInfo<std::net::SocketAddr>,
    headers: axum::http::HeaderMap,
    axum::Json(args): axum::Json<Value>,
) -> axum::response::Response {
    use axum::{
        body::Body,
        http::{StatusCode, header},
        response::IntoResponse,
    };
    use futures_util::StreamExt;
    if let Err(rejected) =
        crate::check_rate(&service, peer.ip(), &headers, "/browser/stream", false).await
    {
        return rejected.into_response();
    }
    let token = crate::bearer(&headers).to_owned();
    if token.is_empty() {
        return StatusCode::FORBIDDEN.into_response();
    }
    let Ok(permit) = service.slots.clone().try_acquire_owned() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let grant = tokio::task::spawn_blocking(move || {
        let mut db = crate::open(&service.database)?;
        rpc(&mut db, "agent_browser_subscribe", &token, &args)
    })
    .await;
    let Ok(Ok((_, body))) = grant else {
        return StatusCode::FORBIDDEN.into_response();
    };
    let Some(ticket) = body["data"]["result"]["ticket"].as_str() else {
        return StatusCode::FORBIDDEN.into_response();
    };
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(30))
        .build();
    let Ok(client) = client else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let endpoint = format!(
        "{}/stream",
        env::var("STACK_BROWSER_URL")
            .unwrap_or_default()
            .trim_end_matches('/')
    );
    let Ok(response) = client
        .post(endpoint)
        .json(&json!({"ticket":ticket}))
        .send()
        .await
    else {
        return StatusCode::BAD_GATEWAY.into_response();
    };
    if !response.status().is_success()
        || !response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.starts_with("text/event-stream"))
    {
        return StatusCode::BAD_GATEWAY.into_response();
    }
    let chunks = futures_util::stream::unfold(
        (response.bytes_stream(), 4 * 1024 * 1024usize, permit),
        |(mut stream, left, permit)| async move {
            if left == 0 {
                return None;
            }
            let chunk = stream.next().await?;
            let sent = chunk.as_ref().map_or(0, |v| v.len().min(left));
            Some((
                chunk.map(|v| v.slice(..sent)),
                (stream, left - sent, permit),
            ))
        },
    );
    (
        [
            (header::CONTENT_TYPE, "text/event-stream"),
            (header::CACHE_CONTROL, "no-store, no-transform"),
            (header::HeaderName::from_static("x-accel-buffering"), "no"),
        ],
        Body::from_stream(chunks),
    )
        .into_response()
}

pub fn configured() -> bool {
    ["STACK_BROWSER_TOKEN", "STACK_BROWSER_URL"]
        .iter()
        .all(|k| env::var(k).is_ok_and(|v| !v.is_empty()))
}

fn err(message: &str) -> Value {
    json!({"error":message})
}
fn s<'a>(data: &'a Value, key: &str) -> &'a str {
    data[key].as_str().unwrap_or_default()
}

fn destination(value: &str) -> Option<String> {
    let mut url = reqwest::Url::parse(value.trim()).ok()?;
    let host = url.host_str()?;
    let workday = host
        .strip_suffix(".myworkdayjobs.com")
        .and_then(|s| s.rsplit_once(".wd"))
        .is_some_and(|(tenant, n)| {
            !tenant.is_empty()
                && tenant
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
                && !n.is_empty()
                && n.bytes().all(|c| c.is_ascii_digit())
                && url.path().contains("/job/")
        });
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port_or_known_default() != Some(443)
        || url.path() == "/"
        || !(workday
            || matches!(
                host,
                "boards.greenhouse.io"
                    | "job-boards.greenhouse.io"
                    | "boards.eu.greenhouse.io"
                    | "jobs.ashbyhq.com"
                    | "jobs.lever.co"
                    | "jobs.eu.lever.co"
            ))
    {
        return None;
    }
    url.set_fragment(None);
    Some(url.to_string())
}

pub fn start(db: &Connection, owner: &str, target: &str) -> Result<Value> {
    let Some(job) = jobs::application_job(db, owner, target)? else {
        return Ok(err("This agent target was not found or is unavailable."));
    };
    let Some(url) = destination(s(&job, "url")) else {
        return Ok(err(
            "Autofill supports hosted Greenhouse, Ashby, Lever and tenant Workday job URLs. Open custom employer pages yourself.",
        ));
    };
    if !configured() {
        return Ok(err(
            "Autofill needs the isolated browser worker. Configure it before starting.",
        ));
    }
    let old:Option<String>=db.query_row("SELECT id FROM agent_runs WHERE owner=? AND json_extract(data,'$.kind')='autofill' AND json_extract(data,'$.target_id')=? AND json_extract(data,'$.status') NOT IN ('completed','failed','cancelled') LIMIT 1",params![owner,target],|r|r.get(0)).optional()?;
    if let Some(id) = old {
        return runs::detail(db, owner, &id);
    }
    let profile = jobs::profile(db, owner)?;
    let (resume_id,name): (String,String)=db.query_row("SELECT r.id,r.name FROM resumes r JOIN job_records a ON a.owner=r.owner AND a.kind='application' AND a.key=?2 WHERE r.owner=?1 AND (r.id=json_extract(a.data,'$.resume_id') OR r.id=(SELECT id FROM resume_selection WHERE owner=?1) OR (SELECT count(*) FROM resumes WHERE owner=?1)=1) ORDER BY (r.id=json_extract(a.data,'$.resume_id')) DESC LIMIT 1",params![owner,target],|r|Ok((r.get(0)?,r.get(1)?))).optional()?.unwrap_or_default();
    let facts = if profile["onboarded"] == true && !s(&profile, "name").is_empty() {
        json!([{"key":"name","value":profile["name"],"verified":true,"source":"Saved Profile name"}])
    } else {
        json!([])
    };
    runs::enqueue(
        db,
        owner,
        "autofill",
        target,
        &json!({"application_id":target,"job":job,"application_url":url,"autofill_profile":facts,"resume_id":resume_id,"resume_name":name}),
        &auth::random_id(),
    )
}

fn call(op: &str, body: Value, seconds: u64) -> Value {
    if !configured() {
        return err("Browser automation is unavailable until the browser worker is configured.");
    }
    let base = env::var("STACK_BROWSER_URL").unwrap_or_default();
    let response = HTTP
        .post(format!("{}/{op}", base.trim_end_matches('/')))
        .timeout(Duration::from_secs(seconds))
        .bearer_auth(env::var("STACK_BROWSER_TOKEN").unwrap_or_default())
        .json(&body)
        .send()
        .and_then(|r| r.error_for_status());
    if let Ok(response) = response {
        let mut raw = Vec::new();
        if response
            .take(16 * 1024 * 1024 + 1)
            .read_to_end(&mut raw)
            .is_ok()
            && raw.len() <= 16 * 1024 * 1024
            && let Ok(value) = serde_json::from_slice::<Value>(&raw)
            && value.is_object()
        {
            return value;
        }
    }
    err("Stack could not confirm browser input. Reconnect before continuing.")
}

fn active(r: &Value) -> bool {
    r["kind"] == "autofill" && !matches!(s(r, "status"), "completed" | "cancelled" | "failed")
}
fn load(db: &Connection, owner: &str, id: &str) -> Result<Value> {
    Ok(db
        .query_row(
            "SELECT data FROM agent_runs WHERE owner=? AND id=?",
            params![owner, id],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(Value::Null))
}
fn snapshot(
    db: &Connection,
    owner: &str,
    id: &str,
    event: &mut Value,
    run: &Value,
) -> Result<Value> {
    let kind = event["type"].as_str().unwrap_or("snapshot");
    if kind != "snapshot" && run["status"] != "paused" {
        return Ok(err("Take control before using the browser."));
    }
    let frame = kind == "snapshot";
    if kind == "upload_resume" {
        use base64::{Engine, engine::general_purpose::STANDARD};
        let row:Option<(String,Vec<u8>)>=db.query_row("SELECT name,content FROM resumes WHERE owner=? AND id=? AND length(content)<=8388608",params![owner,s(&run["context"],"resume_id")],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        let Some((name, bytes)) = row else {
            return Ok(err(
                "Choose a PDF or DOCX resume up to 8 MB for this application, then start a new autofill task.",
            ));
        };
        let ext = if bytes.starts_with(b"%PDF-") {
            "pdf"
        } else if bytes.starts_with(b"PK\x03\x04") {
            "docx"
        } else {
            return Ok(err(
                "This application needs an uploaded PDF or DOCX resume.",
            ));
        };
        let base = name.rsplit(['/', '\\']).next().unwrap_or("Resume");
        let stem = base.rsplit_once('.').map_or(base, |x| x.0);
        event["document"] =
            json!({"name":format!("{stem}.{ext}"),"content":STANDARD.encode(bytes)});
    }
    let mut value = call(
        if frame { "frame" } else { "handoff" },
        json!({"owner":owner,"id":id,"event":event}),
        10,
    );
    if value.get("error").is_none() {
        value["control"] = call(
            "control",
            json!({"owner":owner,"id":id,"action":"status"}),
            2,
        );
    }
    Ok(value)
}

pub fn rpc(db: &mut Connection, name: &str, token: &str, args: &Value) -> Result<Response> {
    let Some(owner) = crate::admitted_owner(db, token)? else {
        return Ok(crate::denied());
    };
    if let Some(response) = crate::arguments::missing(name, args) {
        return Ok(response);
    }
    let id = s(args, "id");
    let run = load(db, &owner, id)?;
    if name == "agent_browser_subscribe" {
        if !active(&run) {
            return Ok(result(err("This task has no active browser.")));
        }
        let grant = call("subscribe", json!({"owner":owner,"id":id}), 5);
        return Ok(result(if grant["ticket"].is_string() {
            json!({"ticket":grant["ticket"],"url":format!("{}/stream",env::var("STACK_BROWSER_URL").unwrap_or_default().trim_end_matches('/'))})
        } else {
            err("The browser stream is unavailable. Reconnect to try again.")
        }));
    }
    let mut event = args["event"].clone();
    let action = if name == "agent_browser_control" {
        s(args, "action")
    } else {
        s(&event, "type")
    }
    .to_owned();
    if name == "agent_browser" {
        if !active(&run) {
            return Ok(result(err("This task has no active browser session.")));
        }
        if !matches!(action.as_str(), "take" | "resume" | "stop") {
            return snapshot(db, &owner, id, &mut event, &run).map(result);
        }
    }
    if run["kind"] != "autofill" {
        return Ok(result(err("This task has no browser.")));
    }
    if action == "stop" {
        let mut cancelled = crate::rpc(db, "agent_cancel", token, &json!({"id":id}))?;
        if cancelled.0.is_success() {
            cancelled.1["data"]["result"]["control"] =
                call("control", json!({"owner":owner,"id":id,"action":"stop"}), 2);
        }
        return Ok(cancelled);
    }
    if !active(&run) {
        return Ok(result(err("This browser task has ended.")));
    }
    if !matches!(action.as_str(), "take" | "resume" | "status") {
        return Ok(result(err("Unknown browser control.")));
    }
    let input = if name == "agent_browser" {
        &event
    } else {
        args
    };
    if action == "take" {
        if run["intent"].is_object() {
            return Ok(result(err(
                "An approved action is already being sent. Wait for its receipt before taking control.",
            )));
        }
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let mut current = load(&tx, &owner, id)?;
        if !active(&current) {
            return Ok(result(err("This browser step has ended.")));
        }
        if current["intent"].is_object() {
            return Ok(result(err(
                "Wait for the approved action's receipt before taking control.",
            )));
        }
        if current["status"] != "paused" {
            current["context"]["browser_return"] = current["status"].clone();
        }
        current["status"] = json!("paused");
        current["lease"] = json!("");
        current["lease_until"] = json!(0);
        runs::save(&tx, &owner, id, &mut current)?;
        tx.commit()?;
    } else if action == "resume" && run["status"] != "paused" {
        return Ok(result(err("This task is not paused for browser control.")));
    }
    let state = call(
        "control",
        json!({"owner":owner,"id":id,"action":action,"generation":input["generation"].as_i64().unwrap_or(-1),"controller":s(input,"controller"),"instance":s(input,"instance")}),
        5,
    );
    if state.get("error").is_some() {
        return Ok(result(state));
    }
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    if crate::admitted_owner(&tx, token)?.as_deref() != Some(owner.as_str()) {
        return Ok(crate::denied());
    }
    let mut current = load(&tx, &owner, id)?;
    if !active(&current) {
        return Ok(result(err(
            "The browser step ended while control was changing.",
        )));
    }
    if action != "status" {
        let generation = state["generation"].as_i64();
        if generation.is_none()
            || !state["instance"].is_string()
            || (current["context"]["browser_instance"] == state["instance"]
                && current["context"]["browser_generation"].as_i64() > generation)
        {
            return Ok(result(err(
                "Browser control changed while this request was finishing. Reconnect before continuing.",
            )));
        }
        current["context"]["browser_generation"] = state["generation"].clone();
        current["context"]["browser_instance"] = state["instance"].clone();
        if action == "resume" {
            if current["status"] != "paused" {
                return Ok(result(err("This task is not paused for browser control.")));
            }
            current["status"] = json!("queued");
            current["message"] = json!("Browser returned to the agent.");
            current["requests"] = json!([]);
            current["attempts"] = json!(0);
            current["next_at"] = json!(0);
            current["context"]
                .as_object_mut()
                .unwrap()
                .remove("browser_return");
        } else {
            current["message"] =
                json!("Pausing browser activity. Your controls unlock when the browser confirms.");
        }
        runs::save(&tx, &owner, id, &mut current)?;
    }
    let mut view = runs::detail(&tx, &owner, id)?;
    view["control"] = state;
    tx.commit()?;
    Ok(result(view))
}
