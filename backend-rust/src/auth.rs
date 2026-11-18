use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier, password_hash::SaltString};
use axum::http::StatusCode;
use hmac::{Hmac, Mac};
use rand::{RngCore, rngs::OsRng};
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{env, fs, io};

use crate::{Response, failure, now};

pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch("
        CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL,
            password TEXT NOT NULL, invited INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS sessions (
            digest BLOB PRIMARY KEY, owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            expires INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS sessions_owner ON sessions(owner);
        CREATE TABLE IF NOT EXISTS token_key (singleton INTEGER PRIMARY KEY CHECK(singleton=1), key BLOB NOT NULL);
        INSERT OR IGNORE INTO token_key VALUES (1,randomblob(32));
        CREATE TABLE IF NOT EXISTS revoked_sessions(digest BLOB PRIMARY KEY, expires INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS invites (digest BLOB PRIMARY KEY, expires INTEGER NOT NULL);
        DELETE FROM sessions WHERE expires<=unixepoch();
        DELETE FROM revoked_sessions WHERE expires<=unixepoch();
    ")?;
    crate::identity_state::schema(db)
}

pub fn random_id() -> String {
    let mut bytes = [0; 32];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

fn digest(input: &str) -> Vec<u8> {
    Sha256::digest(input.as_bytes()).to_vec()
}

pub fn new_invite(db: &Connection) -> Result<String> {
    let value = random_id();
    db.execute(
        "INSERT INTO invites VALUES (?,unixepoch()+86400)",
        [digest(&value)],
    )?;
    Ok(value)
}

pub fn admitted(invited: bool) -> io::Result<bool> {
    let Some(path) = env::var_os("STACK_AGENT_CONFIG") else {
        return Ok(invited);
    };
    let raw = match fs::read(path) {
        Ok(raw) => raw,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(invited),
        Err(e) => return Err(e),
    };
    let config: serde_json::Map<String, Value> = serde_json::from_slice(&raw)?;
    for key in [
        "monthly_cents",
        "user_monthly_cents",
        "local_model_timeout",
        "local_model_context_tokens",
        "max_output_tokens",
    ] {
        if let Some(value) = config.get(key)
            && !value.is_number()
            && !value.is_boolean()
            && !value
                .as_str()
                .is_some_and(|n| n.trim().parse::<i64>().is_ok())
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid Stack configuration limit.",
            ));
        }
    }
    Ok(invited || config.get("invite_only") == Some(&Value::Bool(false)))
}

pub fn erase_sessions(db: &Connection, owner: &str) -> Result<()> {
    db.execute(
        "DELETE FROM revoked_sessions WHERE expires<=unixepoch()",
        [],
    )?;
    db.execute("INSERT OR IGNORE INTO revoked_sessions SELECT digest,expires FROM sessions WHERE owner=? AND expires>unixepoch()",[owner])?;
    Ok(())
}
fn signer(db: &Connection) -> Result<Hmac<Sha256>> {
    let key: Vec<u8> = db.query_row("SELECT key FROM token_key WHERE singleton=1", [], |r| {
        r.get(0)
    })?;
    Hmac::new_from_slice(&key).map_err(|_| rusqlite::Error::InvalidQuery)
}

pub fn issue(db: &Connection, owner: &str) -> Result<String> {
    let payload = format!("s1.{owner}.{}.{}", now() as u64 + 7 * 86400, random_id());
    let mut signer = signer(db)?;
    signer.update(payload.as_bytes());
    Ok(format!(
        "{payload}.{}",
        hex::encode(signer.finalize().into_bytes())
    ))
}

fn signed_owner<'a>(db: &Connection, token: &'a str) -> Result<Option<&'a str>> {
    let Some((payload, signature)) = token.rsplit_once('.') else {
        return Ok(None);
    };
    let mut fields = payload.split('.');
    let (Some("s1"), Some(owner), Some(expires), Some(_), None) = (
        fields.next(),
        fields.next(),
        fields.next(),
        fields.next(),
        fields.next(),
    ) else {
        return Ok(None);
    };
    if expires
        .parse::<u64>()
        .ok()
        .is_none_or(|end| end <= now() as u64)
    {
        return Ok(None);
    }
    let mut mac = [0; 32];
    if hex::decode_to_slice(signature, &mut mac).is_err() {
        return Ok(None);
    }
    let mut signer = signer(db)?;
    signer.update(payload.as_bytes());
    Ok(signer.verify_slice(&mac).is_ok().then_some(owner))
}

pub fn unknown_user(db: &Connection, token: &str) -> Result<bool> {
    if let Some(owner) = signed_owner(db, token)? {
        return db.query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM accounts WHERE id=?)",
            [owner],
            |r| r.get(0),
        );
    }
    db.query_row(
        "SELECT EXISTS(SELECT 1 FROM revoked_sessions WHERE digest=? AND expires>unixepoch())",
        [digest(token)],
        |r| r.get(0),
    )
}
pub fn principal(db: &Connection, token: &str) -> Result<Option<(String, bool)>> {
    if let Some(owner) = signed_owner(db, token)? {
        return db
            .query_row("SELECT id,invited FROM accounts WHERE id=?", [owner], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional();
    }
    let opaque = db
        .query_row(
            "SELECT a.id,a.invited FROM sessions s JOIN accounts a ON a.id=s.owner
                  WHERE s.digest=? AND s.expires>unixepoch()",
            [digest(token)],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    match opaque {
        Some(principal) => Ok(Some(principal)),
        None => crate::identity_state::principal(db, token),
    }
}

fn matches(password: &str, encoded: &str) -> bool {
    if encoded.starts_with("scrypt$") {
        return crate::identity_state::matches(password, encoded);
    }
    PasswordHash::new(encoded).is_ok_and(|hash| {
        Argon2::default()
            .verify_password(password.as_bytes(), &hash)
            .is_ok()
    })
}

pub fn verify_owner(db: &Connection, owner: &str, args: &Value) -> Result<bool> {
    if ["username", "password"]
        .iter()
        .any(|key| args.get(key).is_some_and(|v| !v.is_string()))
    {
        return Ok(false);
    }
    let username = args["username"].as_str().unwrap_or_default();
    let password = args["password"].as_str().unwrap_or_default();
    if username.is_empty() && password.is_empty() {
        return Ok(true);
    }
    let hash: Option<String> = db
        .query_row(
            "SELECT password FROM accounts WHERE id=? AND username=?",
            params![owner, username],
            |r| r.get(0),
        )
        .optional()?;
    Ok(hash.is_some_and(|h| matches(password, &h)))
}

pub fn identity(
    db: &mut Connection,
    register: bool,
    args: &Value,
    dummy_hash: &str,
) -> Result<Response> {
    let identity = if register {
        &args["identities"][0]
    } else {
        &args["identity"]
    };
    let username = identity["value"]
        .as_str()
        .unwrap_or("")
        .trim()
        .to_lowercase();
    let password = args["credential"]["password"].as_str().unwrap_or("");
    if identity["type"] != "username"
        || args["credential"]["type"] != "password"
        || username.is_empty()
        || username.len() > 128
        || password.is_empty()
        || password.len() > 1024
    {
        return Ok(failure(
            StatusCode::BAD_REQUEST,
            "VALIDATION_ERROR",
            "Invalid identity or credential.",
        ));
    }
    let (owner, new_hash) = if register {
        if password.chars().count() < 8 {
            return Ok(failure(
                StatusCode::BAD_REQUEST,
                "VALIDATION_ERROR",
                "Password must be at least 8 characters long.",
            ));
        }
        (random_id(), Some(hash_password(password)))
    } else {
        let account = db
            .query_row(
                "SELECT id,password FROM accounts WHERE username=?",
                [&username],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?;
        let verified = matches(
            password,
            account.as_ref().map_or(dummy_hash, |a| a.1.as_str()),
        );
        let Some((id, _)) = account.filter(|_| verified) else {
            return Ok(failure(
                StatusCode::UNAUTHORIZED,
                "UNAUTHORIZED",
                "Invalid credentials",
            ));
        };
        (id, None)
    };
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    if let Some(hash) = new_hash
        && tx.execute("INSERT INTO accounts(id,username,password) VALUES (?,?,?) ON CONFLICT(username) DO NOTHING",
            params![owner,username,hash])? == 0 {
            return Ok(failure(StatusCode::CONFLICT,"CONFLICT","Identity already exists"));
        }
    if !register
        && !tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=?)",
            [&owner],
            |r| r.get::<_, bool>(0),
        )?
    {
        return Ok(failure(
            StatusCode::UNAUTHORIZED,
            "UNAUTHORIZED",
            "Invalid credentials",
        ));
    }
    let token = issue(&tx, &owner)?;
    let user_id =
        crate::identity_state::user_id(&tx, &owner)?.unwrap_or_else(|| hex::encode(digest(&owner)));
    tx.commit()?;
    let mut data = json!({"token":token,"root_id":owner,"username":username,"user_id":user_id});
    data[if register { "message" } else { "role" }] = if register {
        json!("User registered successfully")
    } else {
        json!("user")
    };
    Ok((
        if register {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        json!({"ok":true,"type":"response","data":data,"error":null}),
    ))
}

pub fn hash_password(password: &str) -> String {
    Argon2::default()
        .hash_password(password.as_bytes(), &SaltString::generate(&mut OsRng))
        .expect("valid argon2 parameters")
        .to_string()
}

pub fn accept(db: &Connection, owner: &str, args: &Value) -> Result<Value> {
    let token = args["invite"].as_str().unwrap_or_default();
    if db.execute(
        "DELETE FROM invites WHERE digest=? AND expires>unixepoch()",
        [digest(token)],
    )? == 0
    {
        return Ok(json!({"error":"Invitation is invalid, expired, or already used."}));
    }
    db.execute("UPDATE accounts SET invited=1 WHERE id=?", [owner])?;
    Ok(json!({"admitted":true}))
}

#[cfg(test)]
mod session_tests {
    use super::*;

    #[test]
    fn sessions_survive_reopen_and_expire() {
        let path = std::env::temp_dir().join(format!("stack-token-{}", random_id()));
        let db = Connection::open(&path).unwrap();
        init(&db).unwrap();
        db.execute(
            "INSERT INTO accounts(id,username,password) VALUES ('owner','synthetic','unused')",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO sessions VALUES (?, 'owner', unixepoch()+60)",
            [digest("old-opaque")],
        )
        .unwrap();
        let signed = issue(&db, "owner").unwrap();
        assert_ne!(signed, issue(&db, "owner").unwrap());
        drop(db);
        let db = Connection::open(&path).unwrap();
        init(&db).unwrap();
        for token in [&signed[..], "old-opaque"] {
            assert_eq!(
                principal(&db, token).unwrap(),
                Some(("owner".into(), false))
            );
        }
        let payload = "s1.owner.0.synthetic";
        let mut mac = signer(&db).unwrap();
        mac.update(payload.as_bytes());
        let expired = format!("{payload}.{}", hex::encode(mac.finalize().into_bytes()));
        assert!(principal(&db, &expired).unwrap().is_none());
        drop(db);
        std::fs::remove_file(path).unwrap();
    }
}
