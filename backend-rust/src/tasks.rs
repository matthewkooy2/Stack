use crate::{now, providers, runs, score_docs};
use rusqlite::{Connection, Result, TransactionBehavior};
use serde_json::json;
use std::{thread, time::Duration};

const STAGES: &[&str] = &[
    "browser_autofill",
    "research",
    "approve_resume",
    "send",
    "sync",
    "calendar",
    "execute",
];

fn run(db: &mut Connection, token: &str) -> Result<bool> {
    let at = now();
    let due:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM agent_runs WHERE json_extract(data,'$.status') IN ('queued','running')
        AND coalesce(json_extract(data,'$.next_at'),0)<=?1 AND coalesce(json_extract(data,'$.lease_until'),0)<=?1
        AND NOT coalesce(json_extract(data,'$.context.manual_scan'),0)
        AND json_extract(data,'$.steps[' || json_extract(data,'$.index') || ']') IN (SELECT value FROM json_each(?2)))",
        rusqlite::params![at,json!(STAGES)],|r|r.get(0))?;
    if !due {
        return Ok(false);
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let claim = runs::worker(
        &tx,
        "agent_claim",
        &json!({"token":token,"steps":STAGES,"non_inference":true}),
    )?;
    tx.commit()?;
    if !claim["lease"].is_string() {
        return Ok(false);
    }
    if claim["context"]["manual_scan"] == true
        || !STAGES.contains(&claim["step"].as_str().unwrap_or_default())
    {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let output = score_docs::helper(
        &claim,
        include_str!("task_dispatch.py"),
        "The task worker is unavailable.",
    )?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    runs::worker(
        &tx,
        "agent_complete",
        &json!({"token":token,"owner":claim["owner"],"id":claim["id"],"lease":claim["lease"],"result":output}),
    )?;
    tx.commit()?;
    Ok(true)
}

fn schedule(db: &mut Connection) -> Result<()> {
    let owners = db
        .prepare_cached("SELECT owner FROM google_connections WHERE state='connected'")?
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>>>()?;
    for owner in owners {
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        providers::schedule_sync(&tx, &owner, "")?;
        tx.commit()?;
    }
    Ok(())
}

pub fn start(path: String) {
    let Ok(token) = std::env::var("STACK_AGENT_WORKER_TOKEN") else {
        return;
    };
    if token.is_empty() || std::env::var_os("STACK_PRIVATE_BIND").is_none() {
        return;
    }
    thread::spawn(move || {
        loop {
            let polling = crate::open(&path).and_then(|mut db| -> Result<()> {
                let mut next = 0.0;
                loop {
                    if now() >= next {
                        schedule(&mut db)?;
                        next = now() + 300.0;
                    }
                    if !run(&mut db, &token)? {
                        thread::sleep(Duration::from_secs(2));
                    }
                }
            });
            if polling.is_err() {
                eprintln!("Task worker will retry its database connection.");
            }
            thread::sleep(Duration::from_secs(3));
        }
    });
}
