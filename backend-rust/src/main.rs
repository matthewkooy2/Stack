mod account;
#[cfg(test)]
mod api_tests;
mod arguments;
mod auth;
mod browser;
mod career;
mod deployment;
mod identity_state;
mod jobs;
mod providers;
mod recording;
mod resumes;
mod runs;
mod score_docs;
mod sso_web;
mod tasks;
mod web;
mod writes;

use axum::{
    Json, Router,
    body::Bytes,
    extract::{ConnectInfo, DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode},
    middleware::{self, Next},
    response::IntoResponse,
    routing::{get, post},
};
use rusqlite::{Connection, Result, TransactionBehavior};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    env,
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::Semaphore;

type Response = (StatusCode, Value);
#[derive(Eq, Hash, PartialEq)]
enum Allowance {
    Account(String),
    Anonymous(IpAddr),
    Identity(IpAddr),
    Poll(IpAddr),
}

#[derive(Default)]
struct RateLimits {
    minute: u64,
    counts: HashMap<Allowance, u16>,
}

impl RateLimits {
    fn admit(&mut self, key: Allowance, minute: u64) -> bool {
        if self.minute != minute {
            self.minute = minute;
            self.counts.clear();
        }
        let count = self.counts.entry(key).or_default();
        if *count >= 300 {
            return false;
        }
        *count += 1;
        true
    }
}
struct Service {
    database: String,
    trusted_proxy: Option<IpAddr>,
    connections: Mutex<Vec<Connection>>,
    dummy_hash: String,
    slots: Arc<Semaphore>,
    requests: Semaphore,
    writer: writes::Writer,
    rate: Mutex<RateLimits>,
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn failure(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        json!({"ok":false,"type":"error","error":{"code":code,"message":message},"data":null}),
    )
}
fn result(value: Value) -> Response {
    (
        StatusCode::OK,
        json!({"ok":true,"type":"response","data":{"result":value,"reports":[]},"error":null}),
    )
}
fn open(path: &str) -> Result<Connection> {
    let db = Connection::open(path)?;
    db.busy_timeout(Duration::from_secs(10))?;
    db.pragma_update(None, "foreign_keys", true)?;
    db.pragma_update(None, "secure_delete", true)?;
    Ok(db)
}
fn known(name: &str) -> bool {
    matches!(
        name,
        "agent_admission" | "agent_accept_invite" | "account_delete"
    ) || jobs::handles(name)
        || career::handles(name)
        || resumes::handles(name)
        || recording::handles(name)
        || account::handles(name)
        || providers::handles(name)
        || runs::handles(name)
        || browser::handles(name)
        || score_docs::handles(name)
}
fn read_only(name: &str) -> bool {
    matches!(
        name,
        "bootstrap"
            | "get_job"
            | "source_status"
            | "agent_admission"
            | "read_resume"
            | "prep_catalog"
            | "prep_sessions"
            | "prep_get"
            | "agent_contacts"
            | "practice_options"
            | "resume_bank"
            | "agent_events"
            | "agent_settings"
            | "account_export"
            | "agent_export"
            | "agent_run"
            | "agent_traces"
            | "agent_model_logs"
            | "agent_activity"
            | "agent_features"
            | "score_resume"
            | "read_resume_source"
            | "read_tailored_resume"
            | "agent_notification_status"
            | "transcription_list"
            | "transcription_get"
            | "transcription_audio"
            | "resume_bank_attachment"
    )
}
fn rpc(db: &mut Connection, name: &str, token: &str, args: &Value) -> Result<Response> {
    if jobs::ranked(name) {
        return jobs::ranked_request(db, name, args, |db| {
            let Some((owner, invited)) = auth::principal(db, token)? else {
                return Ok(Err(denied()));
            };
            match auth::admitted(invited) {
                Ok(true) => Ok(arguments::missing(name, args).map_or(Ok(owner), Err)),
                Ok(false) => Ok(Err(denied())),
                Err(_) => Ok(Err(failure(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "UNAVAILABLE",
                    "Check Stack admission configuration.",
                ))),
            }
        });
    }
    if name == "upload_resume" {
        return resumes::upload_rpc(db, token, args);
    }
    if browser::handles(name) {
        return browser::rpc(db, name, token, args);
    }
    if providers::external(name) {
        return providers::external_rpc(db, name, token, args);
    }
    // User data and the session's continued validity share one database snapshot.
    let revocations = if name == "account_delete" {
        if let Some((owner, _)) = auth::principal(db, token)? {
            if !auth::verify_owner(db, &owner, args)? {
                return Ok(result(
                    json!({"error":"This sign-in belongs to another account."}),
                ));
            }
            let before = account::grants(db, &owner)?;
            if !identity_state::revoke_apple(db, &owner)? {
                return Ok(result(
                    json!({"error":"Could not disconnect Apple. Please retry account deletion."}),
                ));
            }
            if let Some(e) = providers::revoke_account(db, &owner)? {
                return Ok(result(e));
            }
            Some((owner, before))
        } else {
            None
        }
    } else {
        None
    };
    let tx = db.transaction_with_behavior(if read_only(name) {
        TransactionBehavior::Deferred
    } else {
        TransactionBehavior::Immediate
    })?;
    if let Some((owner, before)) = revocations {
        if auth::principal(&tx, token)?.is_none_or(|(id, _)| id != owner) {
            return Ok(failure(
                StatusCode::UNAUTHORIZED,
                "UNAUTHORIZED",
                "Unauthorized: unknown user",
            ));
        }
        if account::grants(&tx, &owner)? != before {
            return Ok(result(
                json!({"error":"Your connections changed. Please retry account deletion."}),
            ));
        }
        auth::erase_sessions(&tx, &owner)?;
        jobs::delete_owner(&tx, &owner)?;
        career::delete_owner(&tx, &owner)?;
        tx.execute("DELETE FROM accounts WHERE id=?", [&owner])?;
        tx.commit()?;
        return Ok(result(json!({"deleted":true})));
    }
    let response = rpc_inner(&tx, name, token, args)?;
    if should_commit(&response) {
        tx.commit()?;
    }
    Ok(response)
}

fn should_commit(response: &Response) -> bool {
    response.0.is_success()
        && !response.1["data"]["result"]
            .as_object()
            .is_some_and(|o| o.len() == 1 && o.contains_key("error"))
}

fn denied() -> Response {
    (
        StatusCode::FORBIDDEN,
        json!({"ok":false,"error":{"message":"Sign in and accept your beta invitation."}}),
    )
}
fn admitted_owner(db: &Connection, token: &str) -> Result<Option<String>> {
    Ok(auth::principal(db, token)?
        .and_then(|(owner, invited)| auth::admitted(invited).unwrap_or(false).then_some(owner)))
}
fn rpc_inner(tx: &Connection, name: &str, token: &str, args: &Value) -> Result<Response> {
    let Some((owner, invited)) = auth::principal(tx, token)? else {
        return Ok(
            if matches!(
                name,
                "agent_admission" | "account_delete" | "agent_accept_invite"
            ) {
                failure(
                    StatusCode::UNAUTHORIZED,
                    "UNAUTHORIZED",
                    if auth::unknown_user(tx, token)? {
                        "Unauthorized: unknown user"
                    } else {
                        "Unauthorized"
                    },
                )
            } else {
                denied()
            },
        );
    };
    let value = match name {
        "agent_accept_invite" => auth::accept(tx, &owner, args)?,
        "account_delete" => return Err(rusqlite::Error::InvalidQuery),
        _ => {
            let Ok(admitted) = auth::admitted(invited) else {
                return Ok(failure(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "UNAVAILABLE",
                    "Check Stack admission configuration.",
                ));
            };
            if name == "agent_admission" {
                json!({"admitted":admitted})
            } else if !admitted {
                return Ok(denied());
            } else if let Some(response) = arguments::missing(name, args) {
                return Ok(response);
            } else {
                let mut value = if jobs::handles(name) {
                    jobs::dispatch(tx, &owner, name, args)?
                } else if career::handles(name) {
                    career::dispatch(tx, &owner, name, args)?
                } else if score_docs::handles(name) {
                    score_docs::dispatch(tx, &owner, name, args)?
                } else if account::handles(name) {
                    account::dispatch(tx, &owner, name, args)?
                } else if providers::handles(name) {
                    providers::dispatch(tx, &owner, name, args)?
                } else if runs::handles(name) {
                    runs::dispatch(tx, &owner, name, args)?
                } else if recording::handles(name) {
                    recording::dispatch(tx, &owner, name, args)?
                } else {
                    resumes::dispatch(tx, &owner, name, args)?
                }
                .ok_or(rusqlite::Error::InvalidQuery)?;
                if value.get("user_id").is_some() && value.get("profile").is_some() {
                    career::enrich_bootstrap(tx, &owner, &mut value)?;
                    resumes::enrich_bootstrap(tx, &owner, &mut value)?;
                }
                value
            }
        }
    };
    Ok(result(value))
}
struct RequestData {
    path: String,
    token: String,
    args: Value,
}
impl Service {
    fn with_connection<T>(&self, work: impl FnOnce(&mut Connection) -> Result<T>) -> Result<T> {
        let cached = self.connections.lock().unwrap().pop();
        let mut db = match cached {
            Some(db) => db,
            None => open(&self.database)?,
        };
        let value = work(&mut db);
        self.connections.lock().unwrap().push(db);
        value
    }
}
fn run(service: &Service, request: RequestData) -> Result<Response> {
    service.with_connection(|db| match request.path.as_str() {
        path if identity_state::handles(path) => {
            identity_state::provider(db, path, &request.token, &request.args)
        }
        "/user/login" | "/user/register" => auth::identity(
            db,
            request.path == "/user/register",
            &request.args,
            &service.dummy_hash,
        ),
        path => rpc(
            db,
            path.trim_start_matches("/function/"),
            &request.token,
            &request.args,
        ),
    })
}

fn bearer(headers: &HeaderMap) -> &str {
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("")
}

async fn check_rate(
    service: &Arc<Service>,
    peer: IpAddr,
    headers: &HeaderMap,
    path: &str,
    identity: bool,
) -> std::result::Result<(), (StatusCode, Json<Value>)> {
    let client = client_address(peer, service.trusted_proxy, headers);
    let key = allowance(service, client, path, identity, bearer(headers))
        .await
        .ok_or((StatusCode::SERVICE_UNAVAILABLE, Json(Value::Null)))?;
    if service.rate.lock().unwrap().admit(key, now() as u64 / 60) {
        Ok(())
    } else {
        Err((
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({"error":{"message":"Too many requests"}})),
        ))
    }
}

async fn allowance(
    service: &Arc<Service>,
    client: IpAddr,
    path: &str,
    identity: bool,
    token: &str,
) -> Option<Allowance> {
    if path == "/sso/google/poll" {
        return Some(Allowance::Poll(client));
    }
    if identity {
        return Some(Allowance::Identity(client));
    }
    if token.is_empty() {
        return Some(Allowance::Anonymous(client));
    }
    // All supported session formats resolve through the same verified account owner.
    let service = Arc::clone(service);
    let token = token.to_owned();
    let permit = service.slots.clone().acquire_owned().await.ok()?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        service.with_connection(|db| {
            Ok(
                auth::principal(db, &token)?.map_or(Allowance::Anonymous(client), |(owner, _)| {
                    Allowance::Account(owner)
                }),
            )
        })
    })
    .await
    .ok()?
    .ok()
}

fn client_address(peer: IpAddr, trusted: Option<IpAddr>, headers: &HeaderMap) -> IpAddr {
    if trusted != Some(peer) {
        return peer;
    }
    headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.rsplit(',').next())
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(peer)
}

async fn handle(
    State(service): State<Arc<Service>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    path: axum::http::Uri,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    let path = path.path();
    let provider = identity_state::handles(path) && path != "/sso/google/callback";
    let identity = matches!(path, "/user/login" | "/user/register") || provider;
    if matches!(
        path,
        "/function/agent_linkedin_profile" | "/function/agent_linkedin_start"
    ) && deployment::settings()["linkedin_browser"] != true
    {
        return (StatusCode::NOT_FOUND, Json(Value::Null));
    }
    if !identity && !path.strip_prefix("/function/").is_some_and(known) {
        return (StatusCode::NOT_FOUND, Json(Value::Null));
    }
    if let Err(rejected) = check_rate(&service, peer.ip(), &headers, path, identity).await {
        return rejected;
    }
    if body.is_empty() {
        return (StatusCode::PAYLOAD_TOO_LARGE, Json(Value::Null));
    }
    let args = match serde_json::from_slice::<Value>(&body) {
        Ok(v) if v.is_object() => v,
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"ok":false,"error":{"message":"Expected a JSON object."}})),
            );
        }
    };
    let request = RequestData {
        path: path.into(),
        token: bearer(&headers).to_owned(),
        args,
    };
    let name = path.trim_start_matches("/function/");
    let outcome = if !identity
        && !read_only(name)
        && !jobs::ranked(name)
        && !providers::external(name)
        && !browser::handles(name)
        && !matches!(name, "account_delete" | "upload_resume")
    {
        service.writer.execute(request).await
    } else {
        static RANK_REQUESTS: std::sync::LazyLock<Arc<Semaphore>> =
            std::sync::LazyLock::new(|| Arc::new(Semaphore::new(6)));
        let permit = if jobs::ranked(name) {
            RANK_REQUESTS.clone().try_acquire_owned().ok()
        } else {
            service.slots.clone().acquire_owned().await.ok()
        };
        let Some(permit) = permit else {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"ok":false,"error":{"message":"Stack is busy. Please retry."}})),
            );
        };
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            run(&service, request)
        })
        .await
        .ok()
        .and_then(Result::ok)
    };
    let (status, body) = match outcome {
        Some(response) => response,
        None => {
            eprintln!("Stack request failed during storage operation");
            failure(
                StatusCode::SERVICE_UNAVAILABLE,
                "UNAVAILABLE",
                "Stack is temporarily unavailable",
            )
        }
    };
    (status, Json(body))
}
async fn headers(
    State(service): State<Arc<Service>>,
    request: axum::extract::Request,
    next: Next,
) -> axum::response::Response {
    let id = request
        .headers()
        .get("x-request-id")
        .filter(|v| v.len() <= 100)
        .cloned()
        .unwrap_or_else(|| auth::random_id().parse().unwrap());
    let mut response = match service.requests.try_acquire() {
        Ok(_permit) => next.run(request).await,
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"ok":false,"error":{"message":"Stack is busy. Please retry."}})),
        )
            .into_response(),
    };
    let headers = response.headers_mut();
    headers.insert("x-request-id", id);
    headers.insert("x-stack-backend", "rust".parse().unwrap());
    headers
        .entry("cache-control")
        .or_insert("no-store".parse().unwrap());
    headers.insert("x-content-type-options", "nosniff".parse().unwrap());
    headers.insert("content-security-policy","default-src 'self'; script-src 'self' https://appleid.cdn-apple.com; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' https://appleid.apple.com; frame-src https://appleid.apple.com; frame-ancestors 'none'; base-uri 'none'".parse().unwrap());
    headers.insert("referrer-policy", "no-referrer".parse().unwrap());
    response
}
async fn private_worker(
    State(service): State<Arc<Service>>,
    axum::extract::Path(name): axum::extract::Path<String>,
    Json(args): Json<Value>,
) -> impl IntoResponse {
    if !runs::worker_handles(&name)
        && !recording::worker_handles(&name)
        && name != "agent_worker_connection"
    {
        return (StatusCode::NOT_FOUND, Json(Value::Null));
    }
    if !runs::worker_authorized(&args) {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({"error":"Worker authorization required."})),
        );
    }
    let Ok(permit) = service.slots.clone().acquire_owned().await else {
        return (StatusCode::SERVICE_UNAVAILABLE, Json(Value::Null));
    };
    let response = tokio::task::spawn_blocking(move || -> Result<Response> {
        let _permit = permit;
        let mut db = open(&service.database)?;
        let value = if name == "agent_worker_connection" {
            providers::worker_connection(
                &mut db,
                args["owner"].as_str().unwrap_or(""),
                args["id"].as_str().unwrap_or(""),
                args["lease"].as_str().unwrap_or(""),
            )?
        } else {
            let tx = db.transaction_with_behavior(
                if name == "agent_lease_active"
                    || name == "agent_worker_memory"
                    || name == "agent_worker_resume_source"
                    || (name == "transcription_processing_runtime" && args["action"] == "get")
                {
                    TransactionBehavior::Deferred
                } else {
                    TransactionBehavior::Immediate
                },
            )?;
            let value = if recording::worker_handles(&name) {
                recording::worker(&tx, &name, &args)?
            } else {
                runs::worker(&tx, &name, &args)?
            };
            tx.commit()?;
            value
        };
        Ok(result(value))
    })
    .await;
    let (code, value) = response.ok().and_then(Result::ok).unwrap_or_else(|| {
        failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "UNAVAILABLE",
            "Worker storage unavailable.",
        )
    });
    (code, Json(value))
}
#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> std::result::Result<(), Box<dyn std::error::Error>> {
    deployment::init()?;
    let database = env::var("STACK_RUST_DB").unwrap_or_else(|_| "stack-rust.db".into());
    let db = open(&database)?;
    db.pragma_update(None, "journal_mode", "WAL")?;
    auth::init(&db)?;
    account::init(&db)?;
    resumes::init(&db)?;
    recording::init(&db)?;
    jobs::init(&db)?;
    career::init(&db)?;
    if env::args().nth(1).as_deref() == Some("invite") {
        println!("{}", auth::new_invite(&db)?);
        return Ok(());
    }

    resumes::start_source_worker(database.clone());
    providers::start_worker(database.clone());
    tasks::start(database.clone());
    let trusted_proxy = env::var("STACK_TRUSTED_PROXY")
        .ok()
        .map(|value| value.parse())
        .transpose()?;
    let service = Arc::new(Service {
        trusted_proxy,
        writer: writes::Writer::start(open(&database)?)?,
        database,
        requests: Semaphore::new(
            env::var("STACK_HTTP_CONCURRENCY")
                .ok()
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(16)
                .clamp(16, 64),
        ),
        connections: Mutex::new(vec![db]),
        dummy_hash: auth::hash_password(&auth::random_id()),
        slots: Arc::new(Semaphore::new(8)),
        rate: Mutex::default(),
    });
    let app = Router::new()
        .route("/auth/google/start", get(sso_web::serve))
        .route("/auth/google", get(sso_web::serve))
        .route("/auth/apple", get(sso_web::serve))
        .route("/oauth/google", get(sso_web::serve))
        .route("/sso/google/callback", get(sso_web::serve))
        .route("/browser/stream", post(browser::stream))
        .route("/user/{action}", post(handle))
        .route("/sso/google/begin", post(handle))
        .route("/sso/google/finish", post(handle))
        .route("/sso/google/poll", post(handle))
        .route("/function/{name}", post(handle))
        .fallback(web::serve)
        .layer(DefaultBodyLimit::max(15_000_000))
        .layer(middleware::from_fn_with_state(service.clone(), headers))
        .with_state(service.clone());
    if let Ok(addr) = env::var("STACK_PRIVATE_BIND") {
        let addr: SocketAddr = addr.parse()?;
        if !addr.ip().is_loopback() {
            return Err("Private worker API must bind to loopback".into());
        }
        let listener = tokio::net::TcpListener::bind(addr).await?;
        let internal = Router::new()
            .route("/function/{name}", post(private_worker))
            .layer(DefaultBodyLimit::max(15_000_000))
            .with_state(service);
        tokio::spawn(async move {
            if let Err(e) = axum::serve(listener, internal).await {
                eprintln!("Private worker listener stopped: {e}");
            }
        });
    }
    let address = env::var("STACK_RUST_BIND").unwrap_or_else(|_| "127.0.0.1:8180".into());
    let listener = tokio::net::TcpListener::bind(address).await?;
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}
