use axum::{
    body::Body,
    http::{Method, StatusCode, Uri, header},
    response::Response,
};
use std::path::Path;

pub async fn serve(method: Method, uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    let (file, mime) = match path {
        "" | "index.html" => ("index.html", "text/html; charset=utf-8"),
        "styles.css" => (path, "text/css; charset=utf-8"),
        ".well-known/apple-app-site-association" => ("association.json", "application/json"),
        "privacy" | "support" | "about" | "open" => (path, "text/html; charset=utf-8"),
        "open/jobs" | "open/resume" | "open/applications" | "open/network" | "open/prep" => {
            (path, "text/html; charset=utf-8")
        }
        name if name.starts_with("client.")
            && name.ends_with(".js")
            && name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b".-_".contains(&c)) =>
        {
            (name, "application/javascript")
        }
        _ => return empty(StatusCode::NOT_FOUND),
    };
    if method != Method::GET && method != Method::HEAD {
        return empty(StatusCode::METHOD_NOT_ALLOWED);
    }
    let dir = std::env::var("STACK_WEB_DIST").unwrap_or_else(|_| "web-dist".into());
    let disk = if file == "open" { "open/index" } else { file };
    let Ok(bytes) = tokio::fs::read(Path::new(&dir).join(disk)).await else {
        return empty(StatusCode::NOT_FOUND);
    };
    Response::builder()
        .status(200)
        .header(header::CONTENT_TYPE, mime)
        .header(header::CONTENT_LENGTH, bytes.len())
        .body(if method == Method::HEAD {
            Body::empty()
        } else {
            Body::from(bytes)
        })
        .unwrap()
}
fn empty(status: StatusCode) -> Response {
    Response::builder()
        .status(status)
        .body(Body::empty())
        .unwrap()
}
