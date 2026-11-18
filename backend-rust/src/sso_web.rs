use axum::{
    body::Body,
    extract::State,
    http::{HeaderMap, Method, StatusCode, Uri, header},
    response::Response,
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
    sync::Arc,
};

fn empty(status: StatusCode) -> Response {
    Response::builder()
        .status(status)
        .body(Body::empty())
        .unwrap()
}

fn redirect(location: &str, cookie: Option<String>) -> Response {
    let Ok(location) = axum::http::HeaderValue::from_str(location) else {
        return empty(StatusCode::BAD_REQUEST);
    };
    let mut builder = Response::builder()
        .status(StatusCode::SEE_OTHER)
        .header(header::LOCATION, location)
        .header(header::CONTENT_LENGTH, 0);
    if let Some(value) = cookie {
        builder = builder.header(header::SET_COOKIE, value);
    }
    builder.body(Body::empty()).unwrap()
}

fn query(raw: &str, limit: usize) -> Option<BTreeMap<String, String>> {
    let mut args = BTreeMap::new();
    for (k, v) in form_urlencoded::parse(raw.as_bytes()) {
        if args.len() == limit || args.insert(k.into_owned(), v.into_owned()).is_some() {
            return None;
        }
    }
    Some(args)
}

fn state(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
}

fn native_start(args: &BTreeMap<String, String>, origin: &str) -> Option<Response> {
    let url = args.get("url")?;
    if args.len() != 1 || url.contains('#') {
        return None;
    }
    let (target, raw) = url.split_once('?')?;
    if target != "https://accounts.google.com/o/oauth2/v2/auth" {
        return None;
    }
    let options = query(raw, 30)?;
    let origin = origin.parse::<Uri>().ok()?;
    if origin.scheme_str() != Some("https") {
        return None;
    }
    let callback = format!("https://{}/sso/google/callback", origin.authority()?);
    let attempt = options.get("state")?;
    let scopes: BTreeSet<_> = options.get("scope")?.split_whitespace().collect();
    if !state(attempt)
        || options.get("redirect_uri")? != &callback
        || options.get("response_type")? != "code"
        || options.get("code_challenge_method")? != "S256"
        || scopes != BTreeSet::from(["openid", "email", "profile"])
    {
        return None;
    }
    Some(redirect(
        url,
        Some(format!(
            "stack_native_signin={attempt}; Max-Age=600; Path=/sso/google/callback; Secure; HttpOnly; SameSite=Lax"
        )),
    ))
}

fn allowed_query(args: &BTreeMap<String, String>) -> String {
    let mut q = form_urlencoded::Serializer::new(String::new());
    for key in ["code", "state", "error"] {
        if let Some(value) = args.get(key) {
            q.append_pair(key, value);
        }
    }
    q.finish()
}

pub(super) async fn serve(
    State(service): State<Arc<crate::Service>>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    if uri.to_string().len() > 8192 {
        return empty(StatusCode::URI_TOO_LONG);
    }
    let Some(args) = query(uri.query().unwrap_or(""), 20) else {
        return empty(StatusCode::BAD_REQUEST);
    };
    let origin = std::env::var("STACK_SSO_CALLBACK_URL").unwrap_or_default();
    match uri.path() {
        "/auth/google/start" => {
            native_start(&args, &origin).unwrap_or_else(|| empty(StatusCode::BAD_REQUEST))
        }
        "/oauth/google" if args.get("state").is_some_and(|s| s.starts_with("native.")) => redirect(
            &format!("stack://oauth/google?{}", allowed_query(&args)),
            None,
        ),
        "/auth/google" | "/auth/apple" | "/oauth/google" => {
            crate::web::serve(Method::GET, Uri::from_static("/index.html")).await
        }
        "/sso/google/callback" => {
            let Some(attempt) = args.get("state").filter(|v| state(v)) else {
                return empty(StatusCode::BAD_REQUEST);
            };
            let attempt = attempt.clone();
            let json_args = serde_json::to_value(&args).unwrap_or(Value::Null);
            let Ok(permit) = service.slots.clone().acquire_owned().await else {
                return empty(StatusCode::SERVICE_UNAVAILABLE);
            };
            let outcome = tokio::task::spawn_blocking(move || {
                let _permit = permit;
                let db = crate::open(&service.database)?;
                crate::identity_state::provider(&db, "/sso/google/callback", "", &json_args)
            })
            .await;
            let Ok(Ok((StatusCode::OK, result))) = outcome else {
                return empty(StatusCode::BAD_REQUEST);
            };
            if result["mode"] == "web" {
                let Some(location) = result["redirect"].as_str() else {
                    return empty(StatusCode::BAD_REQUEST);
                };
                let Some((destination, q)) = location.split_once('?') else {
                    return empty(StatusCode::BAD_REQUEST);
                };
                if destination != origin
                    || !destination.starts_with("https://")
                    || !destination.ends_with("/auth/google")
                    || !query(q, 3).is_some_and(|fields| {
                        fields.get("state") == Some(&attempt)
                            && fields
                                .keys()
                                .all(|k| matches!(k.as_str(), "code" | "error" | "state"))
                    })
                {
                    return empty(StatusCode::BAD_REQUEST);
                }
                return redirect(location, None);
            }
            if result["mode"] != "native" {
                return empty(StatusCode::BAD_REQUEST);
            }
            let cookie = headers
                .get(header::COOKIE)
                .and_then(|h| h.to_str().ok())
                .unwrap_or("");
            if cookie
                .split(';')
                .map(str::trim)
                .any(|s| s.strip_prefix("stack_native_signin=") == Some(attempt.as_str()))
            {
                return redirect(&format!("com.matthewkooy.stack://auth/google?state={attempt}"),
                    Some("stack_native_signin=; Max-Age=0; Path=/sso/google/callback; Secure; HttpOnly; SameSite=Lax".into()));
            }
            let file = if result["success"] == json!(true) {
                "signin-success"
            } else {
                "signin-failure"
            };
            let dir = std::env::var("STACK_WEB_DIST").unwrap_or_else(|_| "web-dist".into());
            let Ok(template) = tokio::fs::read_to_string(Path::new(&dir).join(file)).await else {
                return empty(StatusCode::SERVICE_UNAVAILABLE);
            };
            Response::builder()
                .status(200)
                .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
                .body(Body::from(template.replace(&"S".repeat(43), &attempt)))
                .unwrap()
        }
        _ => empty(StatusCode::NOT_FOUND),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_handoff_preserves_provider_and_cookie() {
        let fields = BTreeMap::from([
            ("scope", "openid email profile"),
            ("code_challenge_method", "S256"),
            ("response_type", "code"),
            ("redirect_uri", "https://stack.example/sso/google/callback"),
            ("state", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
        ]);
        let params = form_urlencoded::Serializer::new(String::new())
            .extend_pairs(fields)
            .finish();
        let url = format!("https://accounts.google.com/o/oauth2/v2/auth?{params}");
        let args = BTreeMap::from([("url".into(), url.clone())]);
        let response = native_start(&args, "https://stack.example/auth/google").unwrap();
        assert_eq!(response.status(), 303);
        assert_eq!(response.headers()[header::LOCATION], url);
        assert!(
            response.headers()[header::SET_COOKIE]
                .to_str()
                .unwrap()
                .contains("HttpOnly")
        );
        assert!(native_start(&args, "https://different.example/auth/google").is_none());
    }
}
