use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use rusqlite::{Connection, OptionalExtension, Result};
use serde_json::Value;
use sha2::Sha256;
use subtle::ConstantTimeEq;

pub fn schema(db: &Connection) -> Result<()> {
    db.execute_batch(include_str!("identity_schema.sql"))
}

pub fn user_id(db: &Connection, owner: &str) -> Result<Option<String>> {
    db.query_row(
        "SELECT user_id FROM jac_principals WHERE owner=?",
        [owner],
        |r| r.get(0),
    )
    .optional()
}

pub fn matches(password: &str, encoded: &str) -> bool {
    let fields: Vec<_> = encoded.split('$').collect();
    if fields.len() != 6 || fields[0] != "scrypt" || fields[2] != "8" || fields[3] != "1" {
        return false;
    }
    let Ok(n) = fields[1].parse::<u32>() else {
        return false;
    };
    if !n.is_power_of_two() || !(2..=32768).contains(&n) {
        return false;
    }
    let (Ok(salt), Ok(expected)) = (
        URL_SAFE_NO_PAD.decode(fields[4]),
        URL_SAFE_NO_PAD.decode(fields[5]),
    ) else {
        return false;
    };
    if salt.len() != 16 || expected.len() != 64 {
        return false;
    }
    let Ok(params) = scrypt::Params::new(n.ilog2() as u8, 8, 1, 64) else {
        return false;
    };
    let mut actual = [0_u8; 64];
    scrypt::scrypt(password.as_bytes(), &salt, &params, &mut actual).is_ok()
        && bool::from(actual.as_slice().ct_eq(expected.as_slice()))
}

fn claims(token: &str, secret: &[u8], now: f64) -> Option<(String, f64)> {
    let (body, signature) = token.rsplit_once('.')?;
    let (header, payload) = body.split_once('.')?;
    let mut mac = Hmac::<Sha256>::new_from_slice(secret).ok()?;
    mac.update(body.as_bytes());
    mac.verify_slice(&URL_SAFE_NO_PAD.decode(signature).ok()?)
        .ok()?;
    let header: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(header).ok()?).ok()?;
    let payload: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).ok()?).ok()?;
    if header["alg"] != "HS256" || payload["type"] == "api_key" || payload["exp"].as_f64()? <= now {
        return None;
    }
    let issued = payload["iat"].as_f64()?;
    let subject = payload["sub"].as_str()?;
    if issued > now || issued < 0.0 || payload["user_id"] != subject {
        return None;
    }
    Some((subject.to_owned(), issued))
}

pub fn principal(db: &Connection, token: &str) -> Result<Option<(String, bool)>> {
    if token.len() > 8192 || token.matches('.').count() != 2 {
        return Ok(None);
    }
    let Ok(secret) = std::env::var("JAC_SERVE_AUTH_SECRET") else {
        return Ok(None);
    };
    if secret.trim().is_empty() {
        return Ok(None);
    }
    let Some((subject, issued)) = claims(token, secret.trim().as_bytes(), crate::now()) else {
        return Ok(None);
    };
    db.query_row(
        "SELECT a.id,a.invited FROM jac_principals j JOIN accounts a ON a.id=j.owner
         WHERE j.user_id=?1 AND j.jwt_cutoff>=?2",
        rusqlite::params![subject, issued],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
}

pub fn handles(path: &str) -> bool {
    matches!(
        path,
        "/sso/google/begin"
            | "/sso/google/finish"
            | "/sso/google/poll"
            | "/sso/google/callback"
            | "/function/auth_apple_begin"
            | "/function/auth_apple_web_begin"
            | "/function/auth_apple_finish"
    )
}

fn provider_call(
    db: &Connection,
    platform: &str,
    method: &str,
    owner: Option<String>,
    args: &Value,
) -> Result<Value> {
    let database = db
        .path()
        .ok_or(rusqlite::Error::InvalidPath("provider database".into()))?;
    crate::score_docs::helper(
        &serde_json::json!({"database":database,"platform":platform,"method":method,
        "owner":owner,"args":args}),
        include_str!("../identity_provider.py"),
        "Sign-in is temporarily unavailable.",
    )
}

fn configured(key: &str) -> bool {
    std::env::var(key).is_ok_and(|v| !v.trim().is_empty())
}

fn missing(args: &Value, fields: &[&str]) -> Option<crate::Response> {
    let detail: Vec<_> = fields
        .iter()
        .filter(|name| args.get(**name).is_none())
        .map(
            |name| serde_json::json!({"type":"missing","loc":["body",name],"msg":"Field required"}),
        )
        .collect();
    (!detail.is_empty()).then(|| {
        (
            axum::http::StatusCode::UNPROCESSABLE_ENTITY,
            serde_json::json!({"detail":detail}),
        )
    })
}

pub fn provider(db: &Connection, path: &str, token: &str, args: &Value) -> Result<crate::Response> {
    use axum::http::StatusCode;
    use serde_json::json;
    if let Some(method) = path.strip_prefix("/function/auth_apple_") {
        if method == "finish"
            && let Some(response) = missing(args, &["state", "identity_token"])
        {
            return Ok(response);
        }
        let response = |value: Value| {
            (
                StatusCode::OK,
                json!({"ok":true,"type":"response","data":{"result":value,"reports":[]},"error":null}),
            )
        };
        let error = match method {
            "web_begin" => {
                "Apple web sign-in is not configured. Set the Apple Services ID and registered HTTPS return URL on the Stack server."
            }
            "finish" => "Apple sign-in could not finish. Please try again.",
            _ => "Stack could not prepare Apple sign-in. Please retry.",
        };
        if std::env::var("STACK_APPLE_ENABLED").as_deref() != Ok("1") {
            return Ok(response(json!({"ok":false,"error":error})));
        }
        let mut value = provider_call(db, "apple", method, None, args)?;
        if value.get("ok").is_none() {
            value = json!({"ok":false,"error":error});
        }
        return Ok(response(value));
    }
    let Some(method) = path.strip_prefix("/sso/google/") else {
        return Err(rusqlite::Error::InvalidQuery);
    };
    let mut owner = None;
    if method == "begin" && !token.is_empty() {
        if let Some((id, invited)) = crate::auth::principal(db, token)?
            && crate::auth::admitted(invited).unwrap_or(false)
        {
            owner = Some(id);
        } else {
            return Ok((
                StatusCode::FORBIDDEN,
                json!({"ok":false,"error":{"message":"Sign in and accept your beta invitation."}}),
            ));
        }
    }
    let required: &[&str] = match method {
        "begin" => &["challenge"],
        "finish" => &["code", "state", "verifier"],
        "poll" => &["poll"],
        _ => &[],
    };
    if let Some(response) = missing(args, required) {
        return Ok(response);
    }
    if !configured("GOOGLE_CLIENT_ID") || !configured("GOOGLE_CLIENT_SECRET") {
        return Ok(crate::failure(
            StatusCode::INTERNAL_SERVER_ERROR,
            "SSO_NOT_CONFIGURED",
            "SSO provider is not configured",
        ));
    }
    let data = provider_call(db, "google", method, owner, args)?;
    if method == "callback" {
        return Ok((StatusCode::OK, data));
    }
    Ok((
        StatusCode::OK,
        json!({"ok":true,"type":"response","data":data,"error":null}),
    ))
}

pub fn revoke_apple(db: &Connection, owner: &str) -> Result<bool> {
    let mut stmt = db.prepare("SELECT client,sealed FROM apple_grants WHERE owner=?")?;
    let grants: Vec<(String, String)> = stmt
        .query_map([owner], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_>>()?;
    if grants.is_empty() {
        return Ok(true);
    }
    Ok(provider_call(
        db,
        "apple",
        "revoke",
        None,
        &serde_json::json!({"grants":grants}),
    )?["ok"]
        == true)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn jac_password_and_session_contract() {
        let salt = URL_SAFE_NO_PAD.encode([0_u8; 16]);
        let mut digest = [0; 64];
        scrypt::scrypt(
            b"fixture",
            &[0; 16],
            &scrypt::Params::new(4, 8, 1, 64).unwrap(),
            &mut digest,
        )
        .unwrap();
        let hash = format!("scrypt$16$8$1${salt}${}", URL_SAFE_NO_PAD.encode(digest));
        assert!(matches("fixture", &hash));
        assert!(!matches("incorrect", &hash));

        let head = URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256"}"#);
        let payload =
            URL_SAFE_NO_PAD.encode(br#"{"sub":"fixture","user_id":"fixture","iat":1,"exp":3}"#);
        let body = format!("{head}.{payload}");
        let mut mac = Hmac::<Sha256>::new_from_slice(b"fixture-secret").unwrap();
        mac.update(body.as_bytes());
        let token = format!(
            "{body}.{}",
            URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
        );
        assert_eq!(
            claims(&token, b"fixture-secret", 2.0),
            Some(("fixture".to_string(), 1.0))
        );
        assert_eq!(claims(&token, b"fixture-secret", 3.0), None);
        assert_eq!(claims(&token, b"other", 2.0), None);
    }
}
