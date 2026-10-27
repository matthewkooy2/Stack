"""Shared catalog. Only the token-gated daily sweep writes listings; accounts read their stored matches."""
import time;
import json;
import os;
import secrets;
import from pathlib { Path }
import from uuid { uuid4 }
import from threading { RLock }
import from urllib.parse { urlsplit, urlunsplit, parse_qsl, urlencode }
import from jaclang.runtime.runtime { JacRuntime }
import from discovery.normalize { digest, canonical, validate_filters, taxonomy, classify, dedupe_bucket, same_opening }
import from discovery.card { card_view }
import from discovery.matching { facts, current_facts, criteria, evaluate, FACTS_VERSION }
import from core.preferences { _match_preferences }
import from discovery.ranking { rank, encode_cursor, decode_cursor, posting_label }
import from core.timeline { _timeline_preferences }
import from discovery.timeline { analyze, assess, VERSION }
glob _catalog_lock = RLock();
glob ATS: list[str] = ["greenhouse","ashby","lever","smartrecruiters"];
glob PAGE: int = 25;
glob STALE_AFTER: float = 604800.0;
glob DISCOVERED_LIMIT: int = 300;

node CatalogJob {
    has key: str, canonical_url: str, identity: str, data: dict[str, any], observations: dict[str, any] = {}, active: bool = True, checked_at: float = 0.0, discovered_at: float = 0.0, bucket: str = "";
}
node JobAlias { has key: str, target: str; }
node JobSource {
    has key: str, config: dict[str, any], status: str = "pending", message: str = "", checkpoint: dict[str, any] = {}, next_at: float = 0.0, lease: str = "", lease_until: float = 0.0, cycle: str = "", seen: list[str] = [], last_success: float = 0.0, failures: int = 0, imported: int = 0, unique_added: int = 0, cycle_invalid: int = 0;
}
"""One daily collection. `sources` maps source id to that run's outcome."""
node SweepRun {
    has key: str, started_at: float, finished_at: float = 0.0, status: str = "collecting", sources: dict[str, any] = {}, after: str = "", prepared: int = 0, deactivated: int = 0;
}
"""An account's ranked matches for its saved search, refreshed by the sweep or when the search changes."""
node JobMatches {
    has fingerprint: str = "", computed_at: float = 0.0, rows: list[dict[str, any]] = [], meta: dict[str, any] = {};
}
node SavedSearch { has query: str = "", filters: dict[str, any] = {}; }
# Retired by the daily sweep. Declared until existing rows are removed by `jobs_sweep_finish`.
node DiscoveryRequest {
    has key: str, kind: str, payload: dict[str, any], created_at: float, status: str = "queued", source_ids: list[str] = [], message: str = "";
}
node PreparedJobFeed { has key: str, result: dict[str, any]; }
node DailyJobsRefresh { has day: str = "", finished: bool = True, failed: bool = False, successes: int = 0; }
node TimelineMigration { has version: int = 0, after_key: str = "", complete: bool = False; }
node Usage { has key: str, amount: int = 0; }

def _fresh() -> None {
    ctx=JacRuntime.get_context(); owner=str(ctx.user_root.id); ctx.mem.abort(); ctx.set_user_root(owner);
}
def _worker_allowed(token: str) -> bool {
    path=Path("storage/discovery/worker-token");
    return path.exists() and secrets.compare_digest(token,path.read_text().strip()) and jid(root)==jid(root.shared);
}
# Lookups name the predicate inside the reference so the store answers them with an index.
# Bound names must not shadow a stored field.
def _source(wanted: str) -> JobSource | None {
    for s in [root.shared --> [?:JobSource, key==wanted]] { return s; }
    return None;
}
def _job(wanted: str) -> CatalogJob | None {
    for j in [root.shared --> [?:CatalogJob, key==wanted]] { return j; }
    return None;
}
def _listing_url(data: dict[str, any]) -> str {
    url=str(data.get("url", ""));
    # SmartRecruiters applyUrl skips the description when oga is present.
    # Derive the reading link at response time for old and new records alike;
    # keep application destinations and persisted deduplication identities intact.
    if data.get("source")=="smartrecruiters" {
        parsed=urlsplit(url);
        if parsed.hostname=="jobs.smartrecruiters.com" and not parsed.path.startswith("/oneclick-ui/") {
            query=[(k,v) for (k,v) in parse_qsl(parsed.query,keep_blank_values=True) if k.lower()!="oga"];
            return urlunsplit((parsed.scheme,parsed.netloc,parsed.path,urlencode(query),parsed.fragment));
        }
    }
    return url;
}
def _job_view(j: CatalogJob) -> dict[str, any] {
    data=dict(j.data); data["posted"]=posting_label(data.get("posted_at",0)); data["occupation"]=classify(str(data["title"])); data["id"]=j.key; data["active"]=j.active and (not data.get("expires_at") or data["expires_at"]>time.time()); data["checked_at"]=j.checked_at;
    data["discovered_at"]=j.discovered_at; data["stale"]=j.checked_at<time.time()-STALE_AFTER; data["sources"]=[v for v in j.observations.values()];
    data["listing_url"]=_listing_url(data);
    # Tags come from the same facts matching uses; the sweep stores them with the listing.
    data["facts"]=current_facts(data); data["tags"]=[x for x in data["facts"]["employment"]+[data["facts"]["level"]] if x];
    return data;
}
"""Every listing an account can be matched against: active, unexpired and confirmed by a sweep this week."""
def _match_records() -> list[dict[str, any]] {
    cutoff=time.time()-STALE_AFTER;
    return [v for v in [_job_view(j) for j in [root.shared --> [?:CatalogJob, active==True, checked_at>=cutoff]]] if v["active"]];
}
def _saved_search() -> dict[str, any] {
    items=[root -->][?:SavedSearch]; return {"query":items[0].query,"filters":items[0].filters} if items else {};
}
def _catalog_job(id: str) -> dict[str, any] {
    j=_job(id); if j is None { return {}; } result=_job_view(j);result["timeline"]=assess(result,_timeline_preferences());
    saved=_saved_search();
    try { result["match"]=evaluate(result,_criteria(saved.get("query",""),saved.get("filters",{}))); } except Exception { result["match"]={}; }
    return result;
}
"""Profile defaults merged with explicit search overrides."""
def _criteria(query: str, filters: dict[str, any]) -> dict[str, any] {
    c=criteria(_match_preferences(),query,filters);
    if filters.get("any_role") { c=criteria({**_match_preferences(),"roles":""},"",{k:v for (k,v) in filters.items() if k!="any_role"}); c["sources"]["roles"]="search"; }
    return c;
}
def _criteria_view(c: dict[str, any]) -> dict[str, any] {
    keys=["roles","location","modes","stage","years","education","employment_types","salary_min","salary_period","exclude_companies","exclude_terms","soft","levels","graduation_month","available_from","confirmed_only","confirmed_level","timeline","sources","notices"];
    return {k:c[k] for k in keys};
}
"""Everything that decides an account's matches. Matcher versions are included so a rules change recomputes."""
def _fingerprint(search: dict[str, any]) -> str {
    return digest(json.dumps([search,_match_preferences(),_timeline_preferences(),FACTS_VERSION,VERSION],sort_keys=True));
}
def _search_or_saved(query: str | None, filters: dict[str, any] | None) -> dict[str, any] {
    if query is None and filters is None { saved=_saved_search(); query=saved.get("query",""); filters=saved.get("filters",{}); }
    return validate_filters(query or "",filters or {});
}

"""Ranks `records` for the current account. Pure: no reads beyond the account's own preferences, no writes."""
def _compute_matches(search: dict[str, any], records: list[dict[str, any]]) -> dict[str, any] {
    c=_criteria(search["query"],search["filters"]);preferences=_timeline_preferences();order=search["filters"]["sort"];
    rows: list[dict[str, any]]=[]; excluded: dict[str, int]={};
    for record in records {
        view=dict(record);view["timeline"]=assess(view,preferences);
        outcome=evaluate(view,c);
        if outcome["excluded"] {
            conflicts=[x["label"] for x in outcome["checks"] if x["required"] and x["status"]=="conflict"];
            if conflicts and conflicts[0]!="Role" { excluded[conflicts[0]]=excluded.get(conflicts[0],0)+1; }
            continue;
        }
        view["match"]=outcome;
        rows.append({"id":view["id"],"rank":list(rank(view,order)),"match":outcome,"timeline":{k:v for (k,v) in view["timeline"].items() if k!="evidence"}});
    }
    rows=sorted(rows,key=lambda (row: dict[str, any]) { tuple(row["rank"]); });
    meta={"timeline_preferences":preferences,"criteria":_criteria_view(c),"total":len(rows),
        "excluded":[{"reason":k,"count":v} for (k,v) in sorted(excluded.items(),key=lambda (kv: tuple[str, int]) { -kv[1]; })]};
    return {"fingerprint":_fingerprint(search),"computed_at":time.time(),"rows":rows,"meta":meta};
}
def _store_matches(result: dict[str, any]) -> None {
    items=[root -->][?:JobMatches];
    m=items[0] if items else root ++> JobMatches();
    m.fingerprint=result["fingerprint"];m.computed_at=result["computed_at"];m.rows=result["rows"];m.meta=result["meta"];
}
"""The account's matches for `search`: stored ones while they still apply, otherwise recomputed now and stored."""
def _matches_for(search: dict[str, any]) -> dict[str, any] {
    wanted=_fingerprint(search);
    for m in [root -->][?:JobMatches] {
        if m.fingerprint==wanted { return {"fingerprint":m.fingerprint,"computed_at":m.computed_at,"rows":m.rows,"meta":m.meta}; }
    }
    result=_compute_matches(search,_match_records());
    with _catalog_lock { _fresh(); _store_matches(result); commit(); }
    return result;
}
def _stored_match_ids() -> list[str] {
    for m in [root -->][?:JobMatches] { return [str(r["id"]) for r in m.rows]; }
    return [];
}
# Callers must not catch broadly around this: the runtime retries a first write at a stricter isolation level.
def _feed_page(search: dict[str, any], cursor: str) -> dict[str, any] {
    try { _criteria(search["query"],search["filters"]); } except Exception as e { return {"error":str(e)}; }
    result=_matches_for(search);
    try { after=decode_cursor(cursor,result["fingerprint"]); } except Exception as e { return {"error":str(e)}; }
    rows=[r for r in result["rows"] if after is None or tuple(r["rank"])>after][:PAGE+1];
    next_cursor="";
    if len(rows)>PAGE { rows=rows[:PAGE];next_cursor=encode_cursor(result["fingerprint"],tuple(rows[-1]["rank"])); }
    cards: list[dict[str, any]]=[];
    for row in rows {
        j=_job(row["id"]);
        # Stored matches name listings; a listing that closed or expired since then is left out.
        view=_job_view(j) if j is not None else {};
        if view and view["active"] { cards.append(card_view({**view,"match":row["match"],"timeline":row["timeline"]})); }
    }
    return {**result["meta"],"jobs":cards,"next_cursor":next_cursor,"sources":[],"occupations":[x["name"] for x in taxonomy()],"checked_at":result["computed_at"],"computed_at":result["computed_at"]};
}

"""The signed-in account's matches for its saved search, one page at a time. Never collects listings."""
def:priv job_feed(cursor: str = "") -> dict[str, any] {
    try { search=_search_or_saved(None,None); } except Exception as e { return {"error":str(e)}; }
    return _feed_page(search,cursor);
}
"""Kept for app builds released before `job_feed`. `refresh` is accepted and ignored: collection is daily only."""
def:priv search_jobs(query: str = "", filters: dict[str, any] | None = None, cursor: str = "", refresh: bool = False) -> dict[str, any] {
    # Jac's HTTP binder can deliver a serialized container default when omitted.
    if filters is None or filters in ["None","{}"] { filters={}; }
    try { search=validate_filters(query,filters); } except Exception as e { return {"error":str(e)}; }
    return _feed_page(search,cursor);
}
def:priv get_job(id: str) -> dict[str, any] {
    result=_catalog_job(id); return result if result else {"error":"Job not found."};
}
"""Saves the search and answers with its first page, so the app needs no second request."""
def:priv save_search(query: str, filters: dict[str, any]) -> dict[str, any] {
    try { config=validate_filters(query,filters); _criteria(config["query"],config["filters"]); } except Exception as e { return {"error":str(e)}; }
    profile=_match_preferences();
    # Store only real overrides, so later profile edits still apply to everything else.
    stored={k:v for (k,v) in config["filters"].items() if not (k in PROFILE_KEYS and _same(v,profile.get(k)))};
    stored_query="" if _same(config["query"],profile.get("roles","")) else config["query"];
    with _catalog_lock {
        _fresh(); items=[root -->][?:SavedSearch];
        s=items[0] if items else root ++> SavedSearch(); s.query=stored_query; s.filters=stored;
        commit();
    }
    return {"saved":True,"query":stored_query,"filters":stored,"feed":job_feed()};
}
glob PROFILE_KEYS: list[str] = ["location","modes","employment_types","salary_min","salary_period","exclude_companies","exclude_terms","soft"];
def _same(a: any, b: any) -> bool {
    if isinstance(a,str) and isinstance(b,str) { return a.strip().lower()==b.strip().lower(); }
    if isinstance(a,(int,float)) and isinstance(b,(int,float)) { return float(a)==float(b); }
    return a==b;
}
def:priv reset_search() -> dict[str, any] {
    with _catalog_lock {
        _fresh(); for s in [root -->][?:SavedSearch] { s.query="";s.filters={}; } commit();
    }
    return {"saved":True,"feed":job_feed()};
}
"""Profile edits win over older search overrides of the same inputs."""
def _drop_overrides(keys: list[str]) -> None {
    for s in [root -->][?:SavedSearch] {
        if "roles" in keys { s.query="";s.filters.pop("any_role",None); }
        s.filters={k:v for (k,v) in s.filters.items() if k not in keys and not (k=="salary_period" and "salary_min" in keys)};
    }
}
glob IMPORT_DEFERRED: str = "Importing job links isn't available yet.";
def:priv import_job_url(url: str) -> dict[str, any] { return {"error":IMPORT_DEFERRED}; }
def:priv get_import_status(id: str) -> dict[str, any] { return {"error":IMPORT_DEFERRED}; }

"""Configured sources plus the job boards the configured GitHub lists point to."""
def _configured() -> list[dict[str, any]] { return json.loads(Path("discovery/sources.json").read_text()); }
def _swept_sources() -> list[JobSource] {
    configured={c["id"] for c in _configured()};
    return [s for s in [root.shared -->][?:JobSource] if s.status!="disabled" and (s.key in configured or s.config.get("found_by","") in configured)];
}
def _source_views() -> list[dict[str, any]] {
    return [{"id":s.key,"name":s.config["name"],"adapter":s.config["adapter"],"sector":s.config.get("sector","Uncategorized"),"status":s.status,"message":s.message,"last_success":s.last_success,"imported":s.imported,"unique_added":s.unique_added} for s in _swept_sources()];
}
def _last_sweep() -> dict[str, any] {
    for r in [root.shared --> [?:SweepRun, -started_at]][:1] { return {"started_at":r.started_at,"finished_at":r.finished_at,"status":r.status}; }
    return {};
}
def:priv source_status() -> dict[str, any] { return {"sources":_source_views(),"sweep":_last_sweep()}; }
def _register(config: dict[str, any]) -> JobSource {
    s=_source(config["id"]);
    if s is not None { return s; }
    s=root.shared ++> JobSource(key=config["id"],config=config,status="pending" if config.get("approved") else "review");
    grant(s,level=AccessLevel.READ); return s;
}
def _sweep_run(wanted: str) -> SweepRun | None {
    for r in [root.shared --> [?:SweepRun, key==wanted]] { return r; }
    return None;
}

"""Starts the daily collection. Returns every source to collect, in order: GitHub lists first, so the boards
they point to can be added to this same run.
`only` is an operator override that collects just those source configurations (single-source checks and tests)."""
def:pub jobs_sweep_begin(token: str, only: list[dict[str, any]] | None = None) -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    only=only if isinstance(only,list) else None;
    with _catalog_lock {
        _fresh();
        for r in [root.shared --> [?:SweepRun, status!="done"]] { if r.status!="failed" { r.status="failed";r.finished_at=time.time(); } }
        for config in (only if only is not None else _configured()) {
            s=_register(config);
            # The reviewed file (or the operator's override) is the source of truth for these sources.
            if s.config!=config { s.config=config; }
            if s.status=="review" and config.get("approved") { s.status="pending"; }
        }
        run=root.shared ++> SweepRun(key=str(uuid4()),started_at=time.time());
        chosen=[_source(c["id"]) for c in only] if only is not None else _swept_sources();
        sources=sorted([x for x in chosen if x is not None and x.status!="disabled"],key=lambda (s: JobSource) { (0 if s.config["adapter"] in ["github","github_search"] else 1, s.key); });
        planned={s.key:{"status":"queued","seen":0,"invalid":0} for s in sources};
        run.sources=planned;
        commit();
        return {"run":run.key,"sources":[{"config":s.config,"checkpoint":s.checkpoint if s.config["adapter"] in ["github","github_search"] else {}} for s in sources]};
    }
}
def _upsert(data: dict[str, any], source: JobSource, run: str) -> bool {
    data=dict(data);data.pop("timeline",None);data.pop("timeline_analysis",None);
    wanted_key=data["id"]; existing=_job(wanted_key);
    alias_key=source.key+":"+str(data["source_job_id"]);
    alias_items=[root.shared --> [?:JobAlias, key==alias_key]];
    if alias_items { by_alias=_job(alias_items[0].target); if by_alias is not None { existing=by_alias; } }
    if existing is None {
        wanted_url=str(data["canonical_url"]);
        for j in [root.shared --> [?:CatalogJob, canonical_url==wanted_url]] { existing=j;break; }
    }
    wanted_bucket=dedupe_bucket(data);
    if existing is None {
        for candidate in [root.shared --> [?:CatalogJob, bucket==wanted_bucket]] {
            if same_opening(candidate.data,data) { existing=candidate;break; }
        }
    }
    if existing is not None { data["timeline_analysis"]=existing.data.get("timeline_analysis",{}); }
    data["timeline_analysis"]=analyze(data);data["facts"]=facts(data);
    added=existing is None;
    now=time.time();
    if existing is None {
        existing=root.shared ++> CatalogJob(key=wanted_key,canonical_url=data["canonical_url"],identity=data["identity"],data=data,checked_at=now,discovered_at=now,bucket=wanted_bucket);grant(existing,level=AccessLevel.READ);
    }
    j=existing;j.bucket=wanted_bucket;
    if alias_items { alias_items[0].target=j.key; }
    else { root.shared ++> JobAlias(key=alias_key,target=j.key); }
    observations=dict(j.observations);
    observations[source.key]={"source_id":source.key,"name":source.config["name"],"adapter":source.config["adapter"],"source_job_id":data["source_job_id"],"url":data["url"],"last_seen":now,"run":run,"active":True,"attribution":data.get("attribution",{})};
    j.observations=observations;
    if added or data["source"] in ATS or j.data["source"] not in ATS { j.data=data; }
    j.checked_at=now;j.active=True;
    return added;
}
"""Records one collected page (or failure) of a source. The final page marks the source complete for this run.
Job boards a GitHub list points to are added to the run and returned, for the sweep to collect next."""
def:pub jobs_sweep_source(token: str, run: str, id: str, jobs: list[dict[str, any]] = [], candidates: list[dict[str, any]] = [], complete: bool = False, invalid: int = 0, error: str = "", checkpoint: dict[str, any] = {}) -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    # Jac's HTTP binder can deliver omitted defaults in serialized form.
    jobs=jobs if isinstance(jobs,list) else [];candidates=candidates if isinstance(candidates,list) else [];
    checkpoint=checkpoint if isinstance(checkpoint,dict) else {};complete=complete is True or complete=="True";
    invalid=int(invalid) if str(invalid).isdigit() else 0;error="" if error in [None,"None"] else str(error);
    with _catalog_lock {
        _fresh();r=_sweep_run(run);s=_source(id);
        if r is None or r.status!="collecting" { return {"error":"This sweep is no longer collecting."}; }
        if s is None or id not in r.sources { return {"error":"Source is not part of this sweep."}; }
        planned=dict(r.sources);outcome=dict(planned[id]);now=time.time();
        if error {
            s.failures+=1;s.status="error";s.message=error[:300]+" Previous listings are kept.";
            outcome["status"]="error";planned[id]=outcome;r.sources=planned;commit();return {"saved":True,"added":[]};
        }
        for data in jobs {
            if _upsert(data,s,run) { s.unique_added+=1; }
            s.imported+=1;
        }
        outcome["seen"]=outcome["seen"]+len(jobs);outcome["invalid"]=outcome["invalid"]+invalid;
        added: list[dict[str, any]]=[];
        boards=[c for c in candidates if c.get("adapter") in ATS and c.get("approved")];
        found=len([x for x in [root.shared -->][?:JobSource] if x.config.get("found_by","")]) if boards else 0;
        for config in boards {
            board=_source(config["id"]);
            if board is None {
                if found>=DISCOVERED_LIMIT { continue; }
                board=_register({**config,"found_by":id});found+=1;
            } elif not board.config.get("found_by") {
                # A board registered before the daily sweep, now confirmed by a configured list.
                board.config={**board.config,"found_by":id};
            }
            if board.status!="disabled" and board.key not in planned { planned[board.key]={"status":"queued","seen":0,"invalid":0};added.append(board.config); }
        }
        if complete {
            s.checkpoint=checkpoint;s.failures=0;
            if outcome["invalid"] { s.status="partial";s.message="Some listings could not be read; listings missing from this source were kept."; }
            elif s.config["adapter"] in ATS and outcome["seen"]==0 and s.imported>0 { s.status="error";s.message="The board returned no listings. Previous listings are kept."; }
            else { s.status="ready";s.message="";s.last_success=now; }
            outcome["status"]="ready" if s.status=="ready" else s.status;
        }
        planned[id]=outcome;r.sources=planned;
        commit();return {"saved":True,"added":added};
    }
}

"""A listing stays active while any clean source still lists it. Sources that failed keep what they had."""
def _deactivate_missing(r: SweepRun) -> int {
    clean={k for (k,v) in r.sources.items() if v["status"]=="ready"};count=0;
    for j in [root.shared --> [?:CatalogJob, active==True]] {
        observations=dict(j.observations);changed=False;
        for sid in clean {
            if sid in observations and observations[sid].get("run")!=r.key and observations[sid].get("active",True) {
                observations[sid]={**observations[sid],"active":False};changed=True;
            }
        }
        if changed {
            j.observations=observations;j.active=any([v.get("active",True) for v in observations.values()]);
            if not j.active { count+=1; }
        }
    }
    return count;
}
def _retire_shared {
    for x in [root.shared -->][?:DiscoveryRequest] { del x; }
    for x in [root.shared -->][?:DailyJobsRefresh] { del x; }
    for x in [root.shared -->][?:TimelineMigration] { del x; }
    for x in [root.shared -->][?:Usage] { del x; }
}
def _retire_account {
    for x in [root -->][?:DiscoveryRequest] { del x; }
    for x in [root -->][?:PreparedJobFeed] { del x; }
}

def:pub discovery_manage(token: str, id: str, action: str) -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _fresh(); s=_source(id);
        if s is None { return {"error":"Source not found."}; }
        if action=="enable" { s.status="pending";s.message=""; }
        elif action=="disable" or action=="purge" {
            s.status="disabled";s.message="Disabled by the operator.";
            if action=="purge" {
                for j in [root.shared -->][?:CatalogJob] {
                    if id in j.observations {
                        observations=dict(j.observations);del observations[id];j.observations=observations;
                        # Remove the material supplied by the revoked source. Independently listed copies are collected again.
                        if not observations or j.data.get("source_id")==id { del j; }
                    }
                }
            }
        } else { return {"error":"Use enable, disable, or purge."}; }
        commit();return {"saved":True};
    }
}

def:pub discovery_report(token: str) -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    jobs=[];
    for j in [root.shared -->][?:CatalogJob] {
        view=_job_view(j);
        for field in ["description","qualifications","requirements","facts"] { view.pop(field,None); }
        jobs.append(view);
    }
    return {"generated_at":time.time(),"sources":_source_views(),"sweep":_last_sweep(),"jobs":jobs};
}

def _retained_snapshot(snapshot: dict[str, any]) -> dict[str, any] {
    source=_source(snapshot.get("source_id",""));
    if source is not None and source.status=="disabled" {
        return {"id":snapshot.get("id",""),"title":"Listing no longer available","company":"Source removed","url":"","color":"#EDF2FF","initial":"S","active":False,"demo":False};
    }
    result=dict(snapshot);result["timeline"]=assess(result,_timeline_preferences());return result;
}
