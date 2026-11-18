use super::{decode, error, get, now, profile, put, string};
use rusqlite::{Connection, OptionalExtension, Result, params};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::{Condvar, LazyLock, Mutex, mpsc};
use std::time::Duration;

// Non-string legacy titles still reach the original matcher under the empty key.
const INDEXED_TITLE: &str =
    "CASE WHEN json_type(data,'$.title')='text' THEN json_extract(data,'$.title') ELSE '' END";
const FRESH: &str = "json_extract(data,'$.active') AND json_extract(data,'$.checked_at')>=?1
    AND (coalesce(json_extract(data,'$.expires_at'),0)=0 OR coalesce(json_extract(data,'$.expires_at'),0)>?2)";

pub(super) fn init(db: &Connection) -> Result<()> {
    let tx = rusqlite::Transaction::new_unchecked(db, rusqlite::TransactionBehavior::Immediate)?;
    let upgrade: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info('job_match_cache') WHERE name='owner')
            AND NOT EXISTS(SELECT 1 FROM pragma_table_info('job_match_cache') WHERE name='slot')",
        [],
        |row| row.get(0),
    )?;
    if upgrade {
        tx.execute_batch(
            "DROP TRIGGER IF EXISTS catalog_insert;
            DROP TRIGGER IF EXISTS catalog_update;
            DROP TRIGGER IF EXISTS catalog_delete;
            ALTER TABLE job_match_cache RENAME TO job_match_cache_single;
            ALTER TABLE job_match_cards RENAME TO job_match_cards_single;",
        )?;
    }
    tx.execute_batch("CREATE TABLE IF NOT EXISTS catalog_jobs(id TEXT PRIMARY KEY, data TEXT NOT NULL CHECK(json_valid(data)));
        CREATE VIEW IF NOT EXISTS public_catalog_jobs AS SELECT id,json_remove(data,'$.dedupe_bucket','$.first_seen_at','$.last_seen_at') AS data FROM catalog_jobs;
        CREATE TABLE IF NOT EXISTS catalog_brands(domain TEXT PRIMARY KEY,png TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS catalog_brand_keys(lookup TEXT PRIMARY KEY,domain TEXT NOT NULL REFERENCES catalog_brands(domain) ON DELETE CASCADE);
        CREATE TABLE IF NOT EXISTS catalog_sources(id TEXT PRIMARY KEY, data TEXT NOT NULL CHECK(json_valid(data)));
        CREATE TABLE IF NOT EXISTS catalog_unlisted_sources(id TEXT PRIMARY KEY REFERENCES catalog_sources(id) ON DELETE CASCADE);
        CREATE TABLE IF NOT EXISTS catalog_sweeps(id TEXT PRIMARY KEY, data TEXT NOT NULL CHECK(json_valid(data)));
        CREATE TABLE IF NOT EXISTS job_match_cache(owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, search TEXT NOT NULL, meta TEXT NOT NULL,
            slot INTEGER NOT NULL DEFAULT 0 CHECK(slot IN (0,1)), PRIMARY KEY(owner,slot));
        CREATE TABLE IF NOT EXISTS job_match_cards(owner TEXT NOT NULL, position INTEGER NOT NULL, cursor TEXT NOT NULL, card TEXT NOT NULL,
            slot INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(owner,slot,position), UNIQUE(owner,slot,cursor),
            FOREIGN KEY(owner,slot) REFERENCES job_match_cache(owner,slot) ON DELETE CASCADE);
        CREATE TABLE IF NOT EXISTS catalog_revision(singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL);
        INSERT OR IGNORE INTO catalog_revision VALUES(1,0);
        CREATE TRIGGER IF NOT EXISTS catalog_rev_insert AFTER INSERT ON catalog_jobs BEGIN UPDATE catalog_revision SET revision=revision+1; END;
        CREATE TRIGGER IF NOT EXISTS catalog_rev_update AFTER UPDATE ON catalog_jobs BEGIN UPDATE catalog_revision SET revision=revision+1; END;
        CREATE TRIGGER IF NOT EXISTS catalog_rev_delete AFTER DELETE ON catalog_jobs BEGIN UPDATE catalog_revision SET revision=revision+1; END;
        CREATE TRIGGER IF NOT EXISTS catalog_insert AFTER INSERT ON catalog_jobs BEGIN DELETE FROM job_match_cache; END;
        CREATE TRIGGER IF NOT EXISTS catalog_update AFTER UPDATE ON catalog_jobs BEGIN DELETE FROM job_match_cache; END;
        CREATE TRIGGER IF NOT EXISTS catalog_delete AFTER DELETE ON catalog_jobs BEGIN DELETE FROM job_match_cache; END;")?;
    if upgrade {
        tx.execute_batch("INSERT INTO job_match_cache(owner,search,meta) SELECT owner,search,meta FROM job_match_cache_single;
            INSERT INTO job_match_cards(owner,position,cursor,card) SELECT owner,position,cursor,card FROM job_match_cards_single;
            DROP TABLE job_match_cards_single;
            DROP TABLE job_match_cache_single;")?;
    }
    tx.execute_batch(&format!(
        "CREATE INDEX IF NOT EXISTS catalog_rank_title ON catalog_jobs(
            {INDEXED_TITLE}, json_extract(data,'$.checked_at'), coalesce(json_extract(data,'$.expires_at'),0))
         WHERE json_extract(data,'$.active')"
    ))?;
    tx.commit()
}
pub(super) fn delete_owner(db: &Connection, owner: &str) -> Result<()> {
    db.execute("DELETE FROM job_match_cards WHERE owner=?", [owner])?;
    db.execute("DELETE FROM job_match_cache WHERE owner=?", [owner])?;
    Ok(())
}

fn io_error(e: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(e))
}
fn start() -> Result<Child> {
    let root = std::env::var_os("STACK_DISCOVERY_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".."));
    Command::new(if cfg!(windows) { "python" } else { "python3" })
        .current_dir(root)
        .args([
            "-I",
            "-X",
            "utf8",
            "-c",
            include_str!("jobs_matching.py").trim_start_matches('\u{feff}'),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(io_error)
}
fn write_line(w: &mut impl Write, value: &Value) -> Result<()> {
    serde_json::to_writer(&mut *w, value).map_err(io_error)?;
    w.write_all(b"\n").map_err(io_error)
}
struct Scorer {
    child: Child,
    output: BufReader<ChildStdout>,
}

impl Scorer {
    fn new() -> Result<Self> {
        let mut child = start()?;
        let output = BufReader::new(child.stdout.take().unwrap());
        Ok(Self { child, output })
    }

    fn compute(&mut self, request: &Value) -> Result<Value> {
        let input = self.child.stdin.as_mut().unwrap();
        write_line(input, request)?;
        input.flush().map_err(io_error)?;
        let mut line = String::new();
        self.output.read_line(&mut line).map_err(io_error)?;
        decode(line)
    }
}

impl Drop for Scorer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

type ScoringJob = (Value, mpsc::SyncSender<Result<Value>>);
static SCORER: LazyLock<mpsc::Sender<ScoringJob>> = LazyLock::new(|| {
    let (sender, receiver) = mpsc::channel::<ScoringJob>();
    std::thread::spawn(move || {
        while let Ok((request, reply)) = receiver.recv() {
            let mut worker = match Scorer::new() {
                Ok(worker) => worker,
                Err(e) => {
                    let _ = reply.send(Err(e));
                    continue;
                }
            };
            let mut task = (request, reply);
            loop {
                let result = worker.compute(&task.0);
                let healthy = result.is_ok();
                let _ = task.1.send(result);
                if !healthy {
                    break;
                }
                match receiver.recv_timeout(Duration::from_secs(60)) {
                    Ok(next) => task = next,
                    Err(_) => break,
                }
            }
        }
    });
    sender
});

fn compute(request: &Value, job: Option<&Value>) -> Result<Value> {
    let mut request = request.clone();
    if let Some(job) = job {
        request["records"] = json!([job]);
    }
    let (send, receive) = mpsc::sync_channel(1);
    SCORER
        .send((request, send))
        .map_err(|_| rusqlite::Error::InvalidQuery)?;
    receive.recv().map_err(io_error)?
}
pub(super) fn preferences(previous: &Value, changes: &Value, mode: &str) -> Result<Value> {
    let mut p = json!({});
    for k in [
        "stage",
        "years",
        "education",
        "modes",
        "employment_types",
        "salary_min",
        "salary_period",
        "exclude_companies",
        "exclude_terms",
        "soft",
    ] {
        p[k] = previous[k].clone();
    }
    if changes.is_null() || changes == "None" || changes == "{}" {
        p["modes"] = if mode == "Any" {
            json!([])
        } else {
            json!([mode])
        };
        return Ok(p);
    }
    let Some(changes) = changes.as_object() else {
        return Ok(error("Preferences must be an object."));
    };
    if changes.iter().all(|(k, v)| p.get(k) == Some(v)) {
        return Ok(p);
    }
    for (k, v) in changes {
        p[k] = v.clone();
    }
    compute(&json!({"op":"preferences","prefs":p}), None)
}

pub(super) fn listing(db: &Connection, id: &str) -> Result<Option<Value>> {
    let raw = db
        .query_row(
            "SELECT data FROM public_catalog_jobs WHERE id=?",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(raw) = raw {
        let mut job = decode(raw)?;
        let expires = job["expires_at"].as_f64().unwrap_or_default();
        job["active"] = json!(job["active"] == true && (expires == 0.0 || expires > now()));
        job["stale"] = json!(job["checked_at"].as_f64().unwrap_or_default() < now() - 604800.0);
        return Ok(Some(job));
    }
    Ok(None)
}
fn saved(db: &Connection, owner: &str) -> Result<Value> {
    Ok(get(db, owner, "search", "saved")?.unwrap_or_else(|| json!({"query":"","filters":{}})))
}
pub(super) fn detail(db: &Connection, owner: &str, job: Value) -> Result<Value> {
    compute(
        &json!({"op":"detail","search":saved(db,owner)?,"prefs":profile(db,owner)?["preferences"]}),
        Some(&job),
    )
}
/// Refresh all saved real listings in one pass, including changed preferences and withdrawn sources.
pub(super) fn application_views(db: &Connection, owner: &str, apps: &mut [Value]) -> Result<()> {
    let ids: Vec<&str> = apps
        .iter()
        .filter(|a| a["demo"] == false)
        .map(|a| string(a, "job_id"))
        .collect();
    if ids.is_empty() {
        return Ok(());
    }
    let mut live = std::collections::HashMap::new();
    let mut stmt = db.prepare_cached(
        "SELECT id,data FROM public_catalog_jobs WHERE id IN (SELECT value FROM json_each(?))",
    )?;
    let mut rows = stmt.query([json!(ids).to_string()])?;
    let at = now();
    while let Some(row) = rows.next()? {
        let mut job = decode(row.get(1)?)?;
        let expires = job["expires_at"].as_f64().unwrap_or_default();
        job["active"] = json!(job["active"] == true && (expires == 0.0 || expires > at));
        job["stale"] = json!(job["checked_at"].as_f64().unwrap_or_default() < at - 604800.0);
        live.insert(row.get::<_, String>(0)?, job);
    }
    let mut disabled=db.prepare_cached("SELECT EXISTS(SELECT 1 FROM catalog_sources WHERE id=? AND json_extract(data,'$.status')='disabled')")?;
    let mut needed = Vec::new();
    for app in &mut *apps {
        if app["demo"] == true {
            continue;
        }
        let id = string(app, "job_id").to_owned();
        if let Some(job) = live.remove(&id) {
            needed.push(json!({"job":job,"retained":false}));
        } else if disabled.query_row([string(&app["job"], "source_id")], |r| r.get::<_, bool>(0))? {
            app["job"] = json!({"id":id,"title":"Listing no longer available","company":"Source removed","url":"","color":"#EDF2FF","initial":"S","active":false,"demo":false});
        } else {
            needed.push(json!({"job":app["job"],"retained":true}));
        }
    }
    if !needed.is_empty() {
        let request = json!({"op":"application_views","search":saved(db,owner)?,"prefs":profile(db,owner)?["preferences"]});
        let updated = compute(&request, Some(&json!(needed)))?;
        for app in apps {
            if let Some(job) = updated.get(string(app, "job_id")) {
                app["job"] = job.clone();
            }
        }
    }
    Ok(())
}
struct Ranking {
    meta: Value,
    cards: Vec<(String, String)>,
}

// Only admitted Jobs requests wait here, on dedicated blocking threads. The WAL
// read snapshot remains valid while queued and is revalidated before publishing.
static FREE_RANK_SLOTS: (Mutex<u8>, Condvar) = (Mutex::new(2), Condvar::new());

struct RankPermit;

impl RankPermit {
    fn acquire() -> Self {
        let (slots, ready) = &FREE_RANK_SLOTS;
        let mut free = ready
            .wait_while(slots.lock().unwrap(), |n| *n == 0)
            .unwrap();
        *free -= 1;
        Self
    }
}

impl Drop for RankPermit {
    fn drop(&mut self) {
        *FREE_RANK_SLOTS.0.lock().unwrap() += 1;
        FREE_RANK_SLOTS.1.notify_one();
    }
}

fn rank(db: &Connection, request: &Value) -> Result<Ranking> {
    let _permit = RankPermit::acquire();
    let mut child = start()?;
    let generated = (|| {
        let mut input = BufWriter::new(child.stdin.take().unwrap());
        let mut output = BufReader::new(child.stdout.take().unwrap());
        let at = now();
        let since = at - 604800.0;
        let search = &request["search"];
        let mut selected = Value::Bool(true);
        if search["filters"]["any_role"] != true
            && (!string(search, "query").is_empty()
                || !string(&request["prefs"], "roles").is_empty())
        {
            let mut stmt = db.prepare(&format!(
                "SELECT DISTINCT {INDEXED_TITLE} FROM catalog_jobs INDEXED BY catalog_rank_title WHERE {FRESH}"
            ))?;
            let titles = stmt
                .query_map(params![since, at], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>>>()?;
            let mut probe = request.clone();
            probe["op"] = json!("candidate_titles");
            probe["records"] = json!(titles);
            write_line(&mut input, &probe)?;
            input.flush().map_err(io_error)?;
            let mut line = String::new();
            output.read_line(&mut line).map_err(io_error)?;
            selected = decode(line)?;
            if selected.get("error").is_some() {
                return Ok(Ranking {
                    meta: selected,
                    cards: vec![],
                });
            }
        }
        write_line(&mut input, request)?;
        let query = if selected.is_array() {
            format!("SELECT data FROM catalog_jobs INDEXED BY catalog_rank_title
                WHERE {INDEXED_TITLE} IN (SELECT value FROM json_each(?3)) AND {FRESH} ORDER BY rowid")
        } else {
            format!("SELECT data FROM catalog_jobs NOT INDEXED WHERE {FRESH} ORDER BY rowid")
        };
        let mut listings = db.prepare(&query)?;
        let mut rows = if selected.is_array() {
            listings.query(params![since, at, selected])?
        } else {
            listings.query(params![since, at])?
        };
        while let Some(row) = rows.next()? {
            let raw: String = row.get(0)?;
            input.write_all(raw.as_bytes()).map_err(io_error)?;
            input.write_all(b"\n").map_err(io_error)?;
        }
        input.flush().map_err(io_error)?;
        drop(input);
        let mut lines = output.lines();
        let first = lines
            .next()
            .transpose()
            .map_err(io_error)?
            .ok_or(rusqlite::Error::QueryReturnedNoRows)?;
        let meta = decode(first)?;
        let mut cards = Vec::new();
        for line in lines {
            let raw = line.map_err(io_error)?;
            let (cursor, card) = raw.split_once('\t').ok_or(rusqlite::Error::InvalidQuery)?;
            cards.push((cursor.to_owned(), card.to_owned()));
        }
        // First-page reads stay a single SQLite cache lookup.
        let mut first = cards
            .iter()
            .take(25)
            .map(|(_, card)| decode(card.clone()))
            .collect::<Result<Vec<_>>>()?;
        render_cards(db, &mut first, &meta["criteria"]["location"])?;
        for (row, card) in cards.iter_mut().zip(first) {
            row.1 = card.to_string();
        }
        Ok(Ranking { meta, cards })
    })();
    if generated.is_err() {
        let _ = child.kill();
    }
    if !child.wait().map_err(io_error)?.success() && generated.is_ok() {
        return Err(io_error(std::io::Error::other("discovery rules failed")));
    }
    generated
}
fn cached(
    db: &Connection,
    owner: &str,
    slot: u8,
    key: &str,
    legacy: &str,
) -> Result<Option<Value>> {
    db.query_row(
        "SELECT meta FROM job_match_cache WHERE owner=?1 AND slot=?2 AND search IN (?3,'paged:' || ?3,?4,'paged:' || ?4)",
        params![owner, slot, key, legacy],
        |r| r.get(0),
    )
    .optional()?
    .map(decode)
    .transpose()
}

fn publish(db: &Connection, owner: &str, slot: u8, key: &str, ranking: &Ranking) -> Result<()> {
    db.execute(
        "DELETE FROM job_match_cache WHERE owner=? AND slot=?",
        params![owner, slot],
    )?;
    db.execute(
        "INSERT INTO job_match_cache(owner,slot,search,meta) VALUES(?,?,?,?)",
        params![
            owner,
            slot,
            format!("paged:{key}"),
            ranking.meta.to_string()
        ],
    )?;
    let mut insert = db.prepare_cached(
        "INSERT INTO job_match_cards(owner,slot,position,cursor,card) VALUES(?,?,?,?,?)",
    )?;
    for (position, (cursor, card)) in ranking.cards.iter().enumerate() {
        insert.execute(params![owner, slot, position as i64, cursor, card])?;
    }
    Ok(())
}

fn page(db: &Connection, owner: &str, slot: u8, cursor: &str, mut result: Value) -> Result<Value> {
    let start = if cursor.is_empty() {
        -1
    } else {
        let pos: Option<i64> = db
            .query_row(
                "SELECT position FROM job_match_cards WHERE owner=? AND slot=? AND cursor=?",
                params![owner, slot, cursor],
                |r| r.get(0),
            )
            .optional()?;
        let Some(p) = pos else {
            return Ok(error(
                "Search changed or cursor expired. Refresh the results.",
            ));
        };
        p
    };
    let mut stmt=db.prepare_cached("SELECT cursor,card FROM job_match_cards WHERE owner=? AND slot=? AND position>? ORDER BY position LIMIT 26")?;
    let mut rows = stmt.query(params![owner, slot, start])?;
    let mut cards = Vec::new();
    let mut last = String::new();
    let mut next = String::new();
    for i in 0..26 {
        let Some(row) = rows.next()? else { break };
        if i == 25 {
            next = last;
            break;
        }
        last = row.get(0)?;
        let card = decode(row.get(1)?)?;
        let expires = card["expires_at"].as_f64().unwrap_or_default();
        if expires == 0.0 || expires > now() {
            cards.push(card);
        }
    }
    render_cards(db, &mut cards, &result["criteria"]["location"])?;
    result["employer_logos"] = brand_cards(db, &mut cards)?;
    result["jobs"] = json!(cards);
    result["next_cursor"] = json!(next);

    Ok(result)
}
fn render_cards(db: &Connection, cards: &mut [Value], location: &Value) -> Result<()> {
    let mut input = Vec::new();
    let mut stmt = db.prepare_cached("SELECT data FROM public_catalog_jobs WHERE id=?")?;
    for card in cards.iter() {
        if let Some(fields) = card.get("_ranked") {
            let raw = stmt.query_row([string(fields, "id")], |row| row.get(0))?;
            input.push(json!([decode(raw)?, fields]));
        }
    }
    if !input.is_empty() {
        let output = compute(
            &json!({"op":"cards","location":location}),
            Some(&Value::Array(input)),
        )?;
        let mut values = match output {
            Value::Array(v) => v.into_iter(),
            _ => return Err(rusqlite::Error::InvalidQuery),
        };
        for card in cards.iter_mut().filter(|c| c.get("_ranked").is_some()) {
            *card = values.next().ok_or(rusqlite::Error::InvalidQuery)?;
        }
    }
    Ok(())
}
fn brand_keys(card: &Value) -> (String, String) {
    let domain = string(card, "employer_domain").trim().to_lowercase();
    let domain = domain
        .strip_prefix("www.")
        .unwrap_or(&domain)
        .trim_end_matches('.');
    let board = string(card, "source_id");
    (
        if domain.is_empty() {
            String::new()
        } else {
            format!("domain:{domain}")
        },
        if board.is_empty() {
            String::new()
        } else {
            format!("board:{board}")
        },
    )
}
fn brand_cards(db: &Connection, cards: &mut [Value]) -> Result<Value> {
    let mut keys = std::collections::BTreeSet::new();
    for c in cards.iter() {
        let (domain, board) = brand_keys(c);
        if !domain.is_empty() {
            keys.insert(domain);
        }
        if !board.is_empty() {
            keys.insert(board);
        }
    }
    let mut logos = json!({});
    if keys.is_empty() {
        return Ok(logos);
    }
    let mut stmt=db.prepare_cached("SELECT lookup,b.domain,b.png FROM catalog_brand_keys k JOIN catalog_brands b ON k.domain=b.domain WHERE lookup IN (SELECT value FROM json_each(?))")?;
    let mut rows = stmt.query([json!(keys).to_string()])?;
    let mut mapping = std::collections::HashMap::<String, String>::new();
    let mut artwork = std::collections::HashMap::<String, String>::new();
    while let Some(row) = rows.next()? {
        let domain: String = row.get(1)?;
        mapping.insert(row.get(0)?, domain.clone());
        artwork.entry(domain).or_insert(row.get(2)?);
    }
    for card in cards {
        let (employer, board) = brand_keys(card);
        let key = if employer.is_empty() {
            &board
        } else {
            &employer
        };
        if let Some(domain) = mapping.get(key)
            && mapping.get(&board).is_none_or(|known| known == domain)
        {
            card["employer_brand"] = json!(domain);
            if logos.get(domain).is_none() {
                logos[domain] = json!(artwork[domain]);
            }
        }
    }
    Ok(logos)
}
fn same(a: &Value, b: &Value) -> bool {
    if let (Some(a), Some(b)) = (a.as_str(), b.as_str()) {
        return a.trim().to_lowercase() == b.trim().to_lowercase();
    }
    if let (Some(a), Some(b)) = (a.as_f64(), b.as_f64()) {
        return a == b;
    }
    a == b
}
pub(super) fn call(db: &Connection, owner: &str, m: &str, a: &Value) -> Result<Value> {
    match m {
        "get_job" => match listing(db, string(a, "id"))? {
            Some(j) => detail(db, owner, j),
            None => Ok(error("Job not found.")),
        },
        "source_status" => {
            let mut stmt = db.prepare(
                "SELECT data FROM catalog_sources WHERE json_extract(data,'$.status')!='disabled'
                AND id NOT IN (SELECT id FROM catalog_unlisted_sources) ORDER BY rowid",
            )?;
            let rows = stmt
                .query_map([], |r| decode(r.get(0)?))?
                .collect::<Result<Vec<_>>>()?;
            // SweepRun belongs to the collector. Personal sessions can read the source summaries.
            Ok(json!({"sources":rows,"sweep":{}}))
        }
        _ => Err(rusqlite::Error::InvalidQuery),
    }
}

pub(crate) fn ranked(name: &str) -> bool {
    matches!(
        name,
        "job_feed" | "search_jobs" | "save_search" | "reset_search"
    )
}

fn search_config(method: &str, a: &Value, saved: &Value, prefs: &Value) -> Result<Value> {
    match method {
        "reset_search" | "save_search" if method == "reset_search" || a["reset"] == true => {
            Ok(json!({"query":"","filters":{}}))
        }
        "save_search" => {
            let mut config = compute(
                &json!({"op":"validate","prefs":prefs,"search":{"query":a["query"],"filters":a["filters"]}}),
                None,
            )?;
            if config.get("error").is_some() {
                return Ok(config);
            }
            if same(&config["query"], &prefs["roles"]) {
                config["query"] = json!("");
            }
            if let Some(filters) = config["filters"].as_object_mut() {
                filters.retain(|k, v| {
                    !matches!(
                        k.as_str(),
                        "location"
                            | "modes"
                            | "employment_types"
                            | "salary_min"
                            | "salary_period"
                            | "exclude_companies"
                            | "exclude_terms"
                            | "soft"
                    ) || !same(v, &prefs[k])
                });
            }
            Ok(config)
        }
        "search_jobs" => {
            let f = &a["filters"];
            Ok(
                json!({"query":a.get("query").cloned().unwrap_or(json!("")),"filters":if f.is_null()||f=="None"||f=="{}"{json!({})}else{f.clone()}}),
            )
        }
        _ => Ok(saved.clone()),
    }
}

fn revision(db: &Connection) -> Result<i64> {
    db.query_row(
        "SELECT revision FROM catalog_revision WHERE singleton=1",
        [],
        |r| r.get(0),
    )
}

fn canonical_search(config: &Value, prefs: &Value) -> Result<Value> {
    // Avoid a scorer round trip for the common unfiltered feed/search. Other
    // shapes, including legacy aliases and explicit empty overrides, use the
    // same validator that constructs the ranking cursor fingerprint.
    if let (Some(query), Some(filters)) = (config["query"].as_str(), config["filters"].as_object())
        && query.len() <= 160
        && query.bytes().all(|b| (0x20..=0x7e).contains(&b))
        && filters
            .iter()
            .all(|(k, v)| (k == "country" && v == "US") || (k == "sort" && v == "relevance"))
    {
        return Ok(json!({"query":query.trim(),"filters":{"country":"US","sort":"relevance"}}));
    }
    compute(
        &json!({"op":"validate","prefs":prefs,"search":config}),
        None,
    )
}

fn reply(method: &str, args: &Value, config: &Value, feed: Value) -> crate::Response {
    crate::result(match method {
        "reset_search" | "save_search" if method == "reset_search" || args["reset"] == true => {
            json!({"saved":true,"feed":feed})
        }
        "save_search" => {
            json!({"saved":true,"query":config["query"],"filters":config["filters"],"feed":feed})
        }
        _ => feed,
    })
}

pub(crate) fn ranked_request(
    db: &Connection,
    method: &str,
    args: &Value,
    authorize: impl Fn(&Connection) -> Result<std::result::Result<String, crate::Response>>,
) -> Result<crate::Response> {
    let save = matches!(method, "save_search" | "reset_search");
    let cursor = if save { "" } else { string(args, "cursor") };
    for _ in 0..3 {
        let read = db.unchecked_transaction()?;
        let owner = match authorize(&read)? {
            Ok(owner) => owner,
            Err(rejected) => return Ok(rejected),
        };
        let prefs = profile(&read, &owner)?["preferences"].take();
        let prior = saved(&read, &owner)?;
        let config = search_config(method, args, &prior, &prefs)?;
        if config.get("error").is_some() {
            return Ok(crate::result(config));
        }
        let normalized = canonical_search(&config, &prefs)?;
        if normalized.get("error").is_some() {
            return Ok(crate::result(normalized));
        }
        // Slot 0 pins the saved feed. Slot 1 holds the most recent distinct search.
        let slot = u8::from(
            method == "search_jobs"
                && config != prior
                && normalized != canonical_search(&prior, &prefs)?,
        );
        let legacy = json!({"op":"rank","search":config,"prefs":prefs}).to_string();
        let request = json!({"op":"rank","search":normalized,"prefs":prefs});
        let key = request.to_string();
        let version = revision(&read)?;
        let prepared = if let Some(meta) = cached(&read, &owner, slot, &key, &legacy)? {
            if !save || prior == config {
                return Ok(reply(
                    method,
                    args,
                    &config,
                    page(&read, &owner, slot, cursor, meta)?,
                ));
            }
            None
        } else {
            let ranking = rank(&read, &request)?;
            if ranking.meta.get("error").is_some() {
                return Ok(crate::result(ranking.meta));
            }
            Some(ranking)
        };
        read.commit()?;

        let write =
            rusqlite::Transaction::new_unchecked(db, rusqlite::TransactionBehavior::Immediate)?;
        match authorize(&write)? {
            Ok(current) if current == owner => (),
            Ok(_) => return Ok(crate::denied()),
            Err(rejected) => return Ok(rejected),
        }
        if saved(&write, &owner)? != prior {
            if save {
                return Ok(crate::result(error(
                    "Saved search changed. Refresh and try again.",
                )));
            }
            continue;
        }
        if revision(&write)? != version || profile(&write, &owner)?["preferences"] != prefs {
            continue;
        }
        let meta = if let Some(meta) = cached(&write, &owner, slot, &key, &legacy)? {
            meta
        } else if let Some(ranking) = prepared {
            publish(&write, &owner, slot, &key, &ranking)?;
            ranking.meta
        } else {
            continue;
        };
        if save && prior != config {
            put(&write, &owner, "search", "saved", &config)?;
        }
        let feed = page(&write, &owner, slot, cursor, meta)?;
        write.commit()?;
        return Ok(reply(method, args, &config, feed));
    }
    Ok(crate::result(error("Search changed. Refresh the results.")))
}
