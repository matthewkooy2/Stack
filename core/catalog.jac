"""Shared catalog. Only the token-gated local worker owns catalog writes."""
import time;
import json;
import os;
import secrets;
import from pathlib { Path }
import from uuid { UUID, uuid4 }
import core.locks as locks;
import from urllib.parse { urlsplit, urlunsplit, parse_qsl, urlencode }
import from jaclang.runtime.runtime { JacRuntime }
import from discovery.normalize { digest, canonical, matches, validate_filters, source_enabled, taxonomy, classify, dedupe_bucket, same_opening, plain }
import from discovery.card { card_view }
import from discovery.matching { facts, current_facts, criteria, evaluate, FACTS_VERSION }
import from core.preferences { _match_preferences }
import from discovery.ranking { rank, encode_cursor, decode_cursor, posting_label }
import from core.timeline { _timeline_preferences }
import from core.automation { _agent_owner, AgentMemory }
import from discovery.timeline { analyze, assess, timeline_includes, VERSION }
import from discovery.sources { identify }
import from discovery.transport { public_url }
# The processed catalog view (#107). Requests only read the current snapshot; background
# upkeep (discovery_maintain, discovery_daily, migrations) rebuilds it and swaps it in.
glob _catalog_cache: dict[str, any] = {"root":"","at":0.0,"rows":{},"building":False,"pending":{},"stale":False,"duration":0.0};
glob CATALOG_REPAIR_SECONDS: float = 1800.0;

node CatalogJob {
    has key: str, canonical_url: str, identity: str, data: dict[str, any], observations: dict[str, any] = {}, active: bool = True, checked_at: float = 0.0, discovered_at: float = 0.0, bucket: str = "";
}
node JobAlias { has key: str, target: str; }
node JobSource {
    has key: str, config: dict[str, any], status: str = "pending", message: str = "", checkpoint: dict[str, any] = {}, next_at: float = 0.0, lease: str = "", lease_until: float = 0.0, cycle: str = "", seen: list[str] = [], last_success: float = 0.0, failures: int = 0, imported: int = 0, unique_added: int = 0, cycle_invalid: int = 0;
}
node DiscoveryRequest {
    has key: str, kind: str, payload: dict[str, any], created_at: float, status: str = "queued", source_ids: list[str] = [], message: str = "";
}
node PreparedJobFeed { has key: str, result: dict[str, any]; }
"""One account waiting for its feed to be prepared in the background (#105)."""
node FeedRequest { has owner: str, requested_at: float, search: dict[str, any] = {}; }
node DailyJobsRefresh { has day: str = "", finished: bool = True, failed: bool = False, successes: int = 0; }
node SavedSearch { has query: str = "", filters: dict[str, any] = {}; }
node TimelineMigration { has version: int = 0, after_key: str = "", complete: bool = False; }
node Usage { has key: str, amount: int = 0; }

def _fresh() -> None {
    ctx=JacRuntime.get_context(); owner=str(ctx.user_root.id); ctx.mem.abort(); ctx.set_user_root(owner);
}
def _worker_allowed(token: str) -> bool {
    path=Path("storage/discovery/worker-token");
    return path.exists() and secrets.compare_digest(token,path.read_text().strip()) and jid(root)==jid(root.shared);
}
def _source(source_key: str) -> JobSource | None {
    items=[root.shared -->][?:JobSource][?key==source_key];
    # Use an explicit loop: the bound variable name must not shadow a stored field.
    for s in items { if s.key==source_key { return s; } }
    return None;
}
def _job(id: str) -> CatalogJob | None {
    for j in [root.shared -->][?:CatalogJob][?key==id] { return j; }
    return None;
}

def _leased_source(source_key: str, token_lease: str) -> JobSource | None {
    if not token_lease { return None; }
    # A source key can occur more than once in retained graph data. Complete
    # only the record actually leased by claim, and reject ambiguous leases.
    matches=[root.shared --> [?:JobSource, key==source_key, lease==token_lease]][:2];
    return matches[0] if len(matches)==1 else None;
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
    data["discovered_at"]=j.discovered_at; data["stale"]=j.checked_at<time.time()-604800; data["sources"]=[v for v in j.observations.values()];
    data["listing_url"]=_listing_url(data);
    # Derived once per cached view; tags come from the same facts matching uses.
    data["facts"]=current_facts(data); data["tags"]=[x for x in data["facts"]["employment"]+[data["facts"]["level"]] if x];
    return data;
}
"""Marks the view for a background rebuild. The current snapshot keeps serving meanwhile."""
def _cache_clear() -> None { with locks.cache() { _catalog_cache["stale"]=True; } }
def _cache_put(data: dict[str, any]) -> None {
    with locks.cache() {
        # Updates committed during a rebuild are re-applied on top of the new snapshot.
        if _catalog_cache["building"] { _catalog_cache["pending"][data["id"]]=data; }
        if _catalog_cache["at"] { _catalog_cache["rows"][data["id"]]=data; }
    }
}
def _cache_after_commit(j: CatalogJob) -> None {
    view=_job_view(j);JacRuntime.get_context().on_commit(lambda { _cache_put(view); });
}
"""The current snapshot of the view, possibly stale and empty before the first warm-up. Never builds."""
def _catalog_records() -> list[dict[str, any]] {
    with locks.cache() { return list(_catalog_cache["rows"].values()); }
}
def _catalog_row(key: str) -> dict[str, any] | None {
    with locks.cache() { return _catalog_cache["rows"].get(key); }
}
def _catalog_status() -> dict[str, any] {
    with locks.cache() {
        ready=bool(_catalog_cache["at"]) and _catalog_cache["root"]==jid(root.shared);
        return {"ready":ready,"age":time.time()-_catalog_cache["at"] if ready else None,"stale":_catalog_cache["stale"],
            "building":_catalog_cache["building"],"jobs":len(_catalog_cache["rows"]),"rebuild_seconds":_catalog_cache["duration"]};
    }
}
def _shared_jobs -> list[CatalogJob] { return [root.shared -->][?:CatalogJob]; }
"""Background only: processes every job outside the cache turn, then swaps the snapshot in.
A failed rebuild keeps the previous snapshot. Returns the job count, or -1 when one is already running."""
def _catalog_rebuild() -> int {
    with locks.cache() {
        if _catalog_cache["building"] { return -1; }
        _catalog_cache["building"]=True;_catalog_cache["pending"]={};
    }
    started=time.time();rows: dict[str, any]={};built=False;
    try {
        for j in _shared_jobs() { rows[j.key]=_job_view(j); }
        built=True;
    } finally {
        with locks.cache() {
            if built {
                rows.update(_catalog_cache["pending"]);
                _catalog_cache.update({"root":jid(root.shared),"at":time.time(),"rows":rows,"stale":False,"duration":time.time()-started});
            }
            _catalog_cache["building"]=False;_catalog_cache["pending"]={};
        }
    }
    return len(rows);
}
def _live(row: dict[str, any]) -> bool {
    return bool(row.get("active",True)) and (not row.get("expires_at") or row["expires_at"]>time.time());
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
def _enqueue(kind: str, payload: dict[str, any]) -> DiscoveryRequest {
    if kind=="search" {
        payload=dict(payload); payload["filters"]=dict(payload.get("filters",{}));
        payload["filters"].pop("sort",None);payload["filters"].pop("has_posting_date",None);payload["filters"].pop("timeline",None);
    }
    key=digest(kind+json.dumps(payload,sort_keys=True));
    for r in [root -->][?:DiscoveryRequest] {
        if r.key==key and (r.status=="queued" or r.created_at>time.time()-21600) { return r; }
    }
    r=root ++> DiscoveryRequest(key=key,kind=kind,payload=payload,created_at=time.time());
    root.shared ++> r;
    JacRuntime.allow_root(r,UUID(jid(root.shared)),AccessLevel.WRITE); # jac:ignore[E1053]
    return r;
}
def _prepared_job_feed() -> dict[str, any] {
    saved=_saved_search();search=validate_filters(saved.get("query",""),saved.get("filters",{}));
    fingerprint=digest(json.dumps([search,_match_preferences()],sort_keys=True));
    feeds=[root -->][?:PreparedJobFeed];
    if feeds and feeds[0].key==fingerprint { return search_jobs(query=search["query"],filters=search["filters"]); }
    return {};
}

def:priv search_jobs(query: str = "", filters: dict[str, any] | None = None, cursor: str = "", refresh: bool = False) -> dict[str, any] {
    # Jac's HTTP binder can deliver a serialized container default when omitted.
    if filters is None or filters in ["None","{}"] { filters={}; }
    try { search=validate_filters(query,filters); c=_criteria(search["query"],search["filters"]); } except Exception as e { return {"error":str(e)}; }
    fingerprint=digest(json.dumps([search,_match_preferences()],sort_keys=True));
    if refresh {
        with locks.account() { _fresh(); _enqueue_roles(c,search); commit(); }
    }
    # Never prepare here (#105): serve the last prepared feed and queue a background preparation.
    feeds=[root -->][?:PreparedJobFeed];
    feed=feeds[0] if feeds else None;
    result=dict(feed.result) if feed is not None else _empty_feed(search,c);
    updating=feed is None or feed.key!=fingerprint;
    # Cursors stay bound to the requested search, so paging survives the feed being replaced underneath.
    try { after=decode_cursor(cursor,fingerprint); } except Exception as e { return {"error":str(e)}; }
    order=search["filters"]["sort"];
    rows=_current_cards([j for j in result["jobs"] if after is None or rank(j,order)>after],26);
    next_cursor="";
    if len(rows)>25 { rows=rows[:25];next_cursor=encode_cursor(fingerprint,rank(rows[-1],order)); }
    if updating { _request_feed(search); }
    return {**result,"jobs":rows,"next_cursor":next_cursor,"refresh_requested":refresh,"updating":updating};
}

"""Shape of a feed that has not been prepared yet."""
def _empty_feed(search: dict[str, any], c: dict[str, any]) -> dict[str, any] {
    return {"jobs":[],"next_cursor":"","sources":[],"occupations":[x["name"] for x in taxonomy()],"checked_at":0.0,
        "timeline_preferences":_timeline_preferences(),"criteria":_criteria_view(c),"excluded":[],"total":0};
}

"""Up to `limit` saved cards, re-rendered from the live catalog view: closed, expired and removed
jobs are dropped and listing edits show at once. Ranking and match details stay as prepared."""
def _current_cards(cards: list[dict[str, any]], limit: int) -> list[dict[str, any]] {
    ready=_catalog_status()["ready"];out: list[dict[str, any]]=[];
    for card in cards {
        if len(out)>=limit { break; }
        row=_catalog_row(card["id"]) if ready else None;
        if row is None {
            # Before the first warm-up, the saved card is the best copy; it still must not be expired.
            if not ready and _live(card) { out.append(card); }
            continue;
        }
        if not _live(row) { continue; }
        view=dict(row);view["posted"]=posting_label(view.get("posted_at",0));
        view["timeline"]=card.get("timeline",{});view["match"]=card.get("match",{});
        out.append(card_view(view));
    }
    return out;
}

"""Queues this account's search for background preparation. One request per account: the latest search wins."""
def _request_feed(search: dict[str, any]) -> None {
    me=jid(root);
    pending=[root.shared --> [?:FeedRequest, owner==me]];
    if pending and pending[0].search==search { return; }
    with locks.account() {
        _fresh();
        pending=[root.shared --> [?:FeedRequest, owner==me]];
        if pending { pending[0].search=search;pending[0].requested_at=time.time(); }
        else {
            r=root.shared ++> FeedRequest(owner=me,requested_at=time.time(),search=search);
            JacRuntime.allow_root(r,UUID(jid(root.shared)),AccessLevel.WRITE); # jac:ignore[E1053]
        }
        commit();
    }
}

"""Background only (discovery_maintain, discovery_daily): matches and ranks the whole catalog for this account."""
def _prepare_job_feed(search: dict[str, any]) -> dict[str, any] {
    if not _catalog_status()["ready"] { _catalog_rebuild(); }
    c=_criteria(search["query"],search["filters"]);preferences=_timeline_preferences();
    fingerprint=digest(json.dumps([search,_match_preferences()],sort_keys=True));
    cutoff=time.time()-604800; order=search["filters"]["sort"];
    results: list[dict[str, any]]=[]; excluded: dict[str, int]={}; considered=0;
    for record in _catalog_records() {
        if record["active"] and record["checked_at"]>=cutoff and (not record.get("expires_at") or record["expires_at"]>time.time()) {
            view=dict(record);view["posted"]=posting_label(view.get("posted_at",0));view["timeline"]=assess(view,preferences);
            outcome=evaluate(view,c);
            if outcome["excluded"] {
                conflicts=[x["label"] for x in outcome["checks"] if x["required"] and x["status"]=="conflict"];
                if conflicts and conflicts[0]!="Role" { excluded[conflicts[0]]=excluded.get(conflicts[0],0)+1; }
                continue;
            }
            considered+=1;view["match"]=outcome;results.append(view);
        }
    }
    results=sorted(results,key=lambda (item: dict[str, any]) { rank(item,order); });
    result={"jobs":[card_view(j) for j in results],"next_cursor":"","sources":[],"occupations":[x["name"] for x in taxonomy()],"checked_at":time.time(),
        "timeline_preferences":preferences,"criteria":_criteria_view(c),"excluded":[{"reason":k,"count":v} for (k,v) in sorted(excluded.items(),key=lambda (kv: tuple[str, int]) { -kv[1]; })],"total":considered};
    # Prepared matches belong only to this account, never to the shared catalog.
    feeds=[root -->][?:PreparedJobFeed];
    feed=feeds[0] if feeds else root ++> PreparedJobFeed(key=fingerprint,result=result);
    feed.key=fingerprint;feed.result=result;commit();return result;
}

def _enqueue_roles(c: dict[str, any], search: dict[str, any]) -> None {
    # Provider searches use one keyword each; the catalog applies every other input.
    roles=[r["text"] for r in c["roles_parsed"]][:3] or [""];
    for role in roles { _enqueue("search",{"query":role,"filters":{**search["filters"],"location":c["location"]}}); }
}

def:priv get_job(id: str) -> dict[str, any] {
    result=_catalog_job(id); return result if result else {"error":"Job not found."};
}
def:priv save_search(query: str, filters: dict[str, any]) -> dict[str, any] {
    try { config=validate_filters(query,filters); c=_criteria(config["query"],config["filters"]); } except Exception as e { return {"error":str(e)}; }
    profile=_match_preferences();
    # Store only real overrides, so later profile edits still apply to everything else.
    stored={k:v for (k,v) in config["filters"].items() if not (k in PROFILE_KEYS and _same(v,profile.get(k)))};
    stored_query="" if _same(config["query"],profile.get("roles","")) else config["query"];
    with locks.account() {
        _fresh(); items=[root -->][?:SavedSearch];
        s=items[0] if items else root ++> SavedSearch(); s.query=stored_query; s.filters=stored;
        _enqueue_roles(c,config); commit(); return {"saved":True,"query":s.query,"filters":s.filters};
    }
}
glob PROFILE_KEYS: list[str] = ["location","modes","employment_types","salary_min","salary_period","exclude_companies","exclude_terms","soft"];
def _same(a: any, b: any) -> bool {
    if isinstance(a,str) and isinstance(b,str) { return a.strip().lower()==b.strip().lower(); }
    if isinstance(a,(int,float)) and isinstance(b,(int,float)) { return float(a)==float(b); }
    return a==b;
}
def:priv reset_search() -> dict[str, any] {
    with locks.account() {
        _fresh(); for s in [root -->][?:SavedSearch] { s.query="";s.filters={}; } commit();
    }
    return {"saved":True};
}
"""Profile edits win over older search overrides of the same inputs."""
def _drop_overrides(keys: list[str]) -> None {
    for s in [root -->][?:SavedSearch] {
        if "roles" in keys { s.query="";s.filters.pop("any_role",None); }
        s.filters={k:v for (k,v) in s.filters.items() if k not in keys and not (k=="salary_period" and "salary_min" in keys)};
    }
}
def:priv import_job_url(url: str) -> dict[str, any] {
    try { public_url(url); } except Exception as e { return {"error":str(e)}; }
    if len(url)>2048 { return {"error":"URL is too long."}; }
    with locks.account() { _fresh(); r=_enqueue("url",{"url":url}); commit(); return {"id":jid(r),"status":r.status}; }
}
def:priv get_import_status(id: str) -> dict[str, any] {
    for r in [root -->][?:DiscoveryRequest] {
        if jid(r)==id {
            sources=[s for s in [root.shared -->][?:JobSource] if s.key in r.source_ids];
            jobs=[_job_view(j) for j in [root.shared -->][?:CatalogJob] if j.data.get("canonical_url")==canonical(r.payload.get("url",""))];
            return {"id":id,"status":r.status,"message":r.message,"sources":[{"name":s.config["name"],"status":s.status,"message":s.message} for s in sources],"jobs":jobs};
        }
    }
    return {"error":"Import not found."};
}
def _source_views() -> list[dict[str, any]] {
    result=[{"id":s.key,"name":s.config["name"],"adapter":s.config["adapter"],"sector":s.config.get("sector","Uncategorized"),"status":s.status,"message":s.message,"last_success":s.last_success,"imported":s.imported,"unique_added":s.unique_added} for s in [root.shared -->][?:JobSource]];
    for adapter in ["adzuna","theirstack","usajobs"] {
        missing=source_enabled(adapter);
        result.append({"id":adapter,"name":adapter,"adapter":adapter,"status":"unavailable" if missing else "ready","message":"Configure "+missing if missing else "Configured; searches refresh in the background.","last_success":0});
    }
    result.append({"id":"brave","name":"Brave discovery","adapter":"brave","status":"disabled","message":"Storage rights not configured; no requests or charges.","last_success":0});
    return result;
}
def:priv source_status() -> dict[str, any] { return {"sources":_source_views()}; }
def _register(config: dict[str, any]) -> JobSource {
    s=_source(config["id"]);
    if s is not None { return s; }
    s=root.shared ++> JobSource(key=config["id"],config=config,status="pending" if config.get("approved") else "review",next_at=time.time()+600 if config["id"].startswith("employer:") else 0);
    grant(s,level=AccessLevel.READ); return s;
}
def _usage(key: str) -> Usage {
    for u in [root.shared -->][?:Usage] { if u.key==key { return u; } }
    return root.shared ++> Usage(key=key);
}
def _reserve(adapter: str) -> int {
    # Reserve before dispatch; ambiguous failures still spend their reservation.
    now=time.gmtime();month=time.strftime("%Y-%m",now);day=time.strftime("%Y-%m-%d",now);week=time.strftime("%G-%V",now);minute=str(int(time.time()/60));
    if adapter=="theirstack" {
        m=_usage(adapter+month);d=_usage(adapter+day);
        amount=min(25,1500-m.amount,50-d.amount);
        if amount<=0 { return 0; } m.amount+=amount;d.amount+=amount;return amount;
    }
    if adapter=="adzuna" {
        counts=[(_usage(adapter+month),2500),(_usage(adapter+day),250),(_usage(adapter+week),1000),(_usage(adapter+minute),25)];
        for (u,limit) in counts { if u.amount>=limit { return 0; } }
        for (u,limit) in counts { u.amount+=1; }
    }
    return 1;
}
def:pub discovery_claim(token: str, preferred_id: str = "") -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    with locks.collector() {
        _fresh();
        for filename in ["discovery/sources.json","discovery/employers.json"] {
            for config in json.loads(Path(filename).read_text()) { _register(config); }
        }
        for r in [root.shared -->][?:DiscoveryRequest][?status=="queued"] {
            if r.kind=="search" {
                for adapter in ["adzuna","usajobs","theirstack"] {
                    key=adapter+":"+r.key;
                    config={"id":key,"adapter":adapter,"name":adapter+" search","search":r.payload,"approved":True,"sector":"Search"};
                    s=_register(config); r.source_ids.append(s.key);
                }
                r.status="scheduled";
            } else {
                config=identify(r.payload["url"]);
                # Explicitly requested public page still must pass robots and DNS checks.
                config["approved"]=True; s=_register(config); r.source_ids=[s.key];r.status="scheduled";
            }
        }
        now=time.time(); selected: any=None;
        # Round-robin due ordering prevents a large employer feed starving other fields.
        for s in [root.shared --> [?:JobSource, next_at<=now, next_at]] {
            if s.status in ["review","disabled"] or s.lease_until>now or (preferred_id and s.key!=preferred_id) { continue; }
            missing=source_enabled(s.config["adapter"]);
            if missing { s.status="unavailable";s.message="Configure "+missing;s.next_at=now+300;continue; }
            if s.config["adapter"]=="theirstack" {
                found=0;search=s.config.get("search",{});cutoff=now-604800;
                for j in [root.shared --> [?:CatalogJob, active==True, checked_at>=cutoff]] {
                    if matches(_job_view(j),search.get("query",""),search.get("filters",{})) { found+=1; }
                    if found>=25 { break; }
                }
                if found>=25 { s.status="ready";s.message="Existing catalog covers this search; paid credits preserved.";s.next_at=now+21600;continue; }
            }
            amount=_reserve(s.config["adapter"]);
            if amount==0 { s.status="quota";s.message="Budget or provider quota reached; cached results remain available.";s.next_at=now+3600;continue; }
            selected=s;break;
        }
        if selected is None { commit();return {"idle":True}; }
        daily=[root.shared -->][?:DailyJobsRefresh];
        if daily and daily[0].finished {
            daily[0].finished=False;daily[0].failed=False;daily[0].successes=0;
        }
        s=selected;s.lease=str(uuid4());s.lease_until=now+600;s.status="collecting";
        if not s.cycle { s.cycle=str(uuid4());s.seen=[];s.cycle_invalid=0; }
        config=dict(s.config);config["allowance"]=amount;
        if config["adapter"]=="theirstack" {
            config["excluded_ids"]=[int(o["source_job_id"]) for j in [root.shared -->][?:CatalogJob] for o in j.observations.values() if o["adapter"]=="theirstack" and str(o["source_job_id"]).isdigit()];
        }
        commit();return {"id":s.key,"lease":s.lease,"config":config,"checkpoint":s.checkpoint};
    }
}
def _upsert(data: dict[str, any], source: JobSource) -> bool {
    data=dict(data);data.pop("timeline",None);data.pop("timeline_analysis",None);
    key=data["id"]; existing=_job(key);
    adapter=source.config["adapter"];
    alias_key=(adapter if adapter in ["adzuna","theirstack","usajobs"] else source.key)+":"+str(data["source_job_id"]);
    alias_items=[root.shared -->][?:JobAlias][?key==alias_key];
    if alias_items { by_alias=_job(alias_items[0].target); if by_alias is not None { existing=by_alias; } }
    if existing is None {
        wanted_url=str(data["canonical_url"]);
        for j in [root.shared -->][?:CatalogJob][?canonical_url==wanted_url] { existing=j;break; }
    }
    wanted_bucket=dedupe_bucket(data);
    if existing is None {
        for candidate in [root.shared -->][?:CatalogJob][?bucket==wanted_bucket] {
            if same_opening(candidate.data,data) { existing=candidate;break; }
        }
    }
    if existing is not None { data["timeline_analysis"]=existing.data.get("timeline_analysis",{}); }
    data["timeline_analysis"]=analyze(data);data["facts"]=facts(data);
    added=existing is None;
    if existing is None {
        existing=root.shared ++> CatalogJob(key=key,canonical_url=data["canonical_url"],identity=data["identity"],data=data,checked_at=time.time(),discovered_at=time.time(),bucket=wanted_bucket);grant(existing,level=AccessLevel.READ);
    }
    j=existing;j.bucket=wanted_bucket;
    if alias_items { alias_items[0].target=j.key; }
    else { root.shared ++> JobAlias(key=alias_key,target=j.key); }
    observation={"source_id":source.key,"name":source.config["name"],"adapter":source.config["adapter"],"source_job_id":data["source_job_id"],"url":data["url"],"last_seen":time.time(),"missing":0,"cycle":source.cycle,"active":True,"attribution":data.get("attribution",{})};
    j.observations[source.key]=observation;
    direct=["greenhouse","ashby","lever","smartrecruiters","career"];
    if added or data["source"] in direct or j.data["source"] not in direct { j.data=data; }
    j.checked_at=time.time();j.active=True;_cache_after_commit(j);
    source.seen.append(j.key);return added;
}
def:pub discovery_complete(token: str, id: str, lease: str, result: dict[str, any] = {}, error: str = "") -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    with locks.collector() {
        _fresh();s=_leased_source(id,lease);
        if s is None or s.lease!=lease or not lease { return {"error":"Lease expired or already completed."}; }
        s.lease="";s.lease_until=0;now=time.time();
        daily=[root.shared -->][?:DailyJobsRefresh];
        if daily and not daily[0].finished {
            if error or result.get("invalid",0) { daily[0].failed=True; }
            elif result.get("complete") { daily[0].successes+=1; }
        }
        if error {
            s.failures+=1;s.status="error";s.message=error[:300];s.next_at=now+min(21600.0,60.0*(2**min(s.failures,8)));
            for r in [root.shared -->][?:DiscoveryRequest] { if s.key in r.source_ids { r.status="error";r.message=s.message; } }
            commit();return {"saved":True};
        }
        for data in result.get("jobs",[]) {
            if _upsert(data,s) { s.unique_added+=1; }
            s.imported+=1;
        }
        for config in result.get("candidates",[]) { _register(config); }
        s.checkpoint=result.get("checkpoint",{});s.failures=0;s.message="";s.cycle_invalid+=int(result.get("invalid",0));
        if s.cycle_invalid>0 { s.status="partial";s.message="Some listings could not be parsed; no absence-based closures performed."; }
        else { s.status="ready" if result.get("complete") else "collecting"; }
        if result.get("complete") {
            if s.config["adapter"] in ["greenhouse","ashby","lever","smartrecruiters"] and not s.cycle_invalid {
                for j in [root.shared -->][?:CatalogJob] {
                    if s.key in j.observations and j.key not in s.seen {
                        o=j.observations[s.key];o["missing"]=o.get("missing",0)+1;
                        if o["missing"]>=2 and now-o["last_seen"]>=86400 { o["active"]=False; }
                        j.observations[s.key]=o;j.active=any([v.get("active",True) for v in j.observations.values()]);_cache_after_commit(j);
                    }
                }
            }
            s.last_success=now;s.cycle="";s.seen=[];s.next_at=now+(604800 if s.config["adapter"]=="github_search" else 86400);
            if s.config["adapter"]=="career" and not result.get("jobs") and not result.get("candidates") { s.status="review";s.message="No structured jobs or supported links found; needs a tested parser or approved browser renderer."; }
        } else { s.next_at=now+(60 if s.config["adapter"]=="github_search" else 10); }
        for r in [root.shared -->][?:DiscoveryRequest] {
            if s.key in r.source_ids { r.status=("review" if s.status=="review" else "complete") if result.get("complete") else "collecting"; r.message=s.message; }
        }
        commit();return {"saved":True};
    }
}

def:pub discovery_manage(token: str, id: str, action: str) -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    with locks.collector() {
        _fresh(); s=_source(id);
        if s is None { return {"error":"Source not found."}; }
        if action=="configure" {
            configs=json.loads(Path("discovery/sources.json").read_text())+json.loads(Path("discovery/employers.json").read_text());
            configured=False;
            for config in configs { if config["id"]==id { s.config=config;configured=True;break; } }
            if not configured { return {"error":"Add the reviewed configuration to discovery/sources.json first."}; }
            s.status="pending" if s.config.get("approved") else "review";s.next_at=0;s.checkpoint={};s.cycle="";s.seen=[];s.lease="";s.lease_until=0;
        } elif action=="retry" { s.next_at=0;s.lease="";s.lease_until=0;s.status="pending"; }
        elif action=="refresh" {
            s.next_at=0;s.checkpoint={};s.cycle="";s.seen=[];s.lease="";s.lease_until=0;s.status="pending";
        } elif action=="disable" or action=="purge" {
            s.status="disabled";s.next_at=time.time()+315360000;s.lease="";s.lease_until=0;
            if action=="purge" {
                for j in [root.shared -->][?:CatalogJob] {
                    if id in j.observations {
                        del j.observations[id];
                        # Remove the material supplied by the revoked source. Recollect independently available copies.
                        if not j.observations or j.data.get("source_id")==id { del j; }
                    }
                }
            }
        } else { return {"error":"Use configure, refresh, retry, disable, or purge."}; }
        JacRuntime.get_context().on_commit(_cache_clear);commit();return {"saved":True};
    }
}

def:pub discovery_analyze(token: str) -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    with locks.collector() {
        _fresh();items=[root.shared -->][?:TimelineMigration];
        migration=items[0] if items else root.shared ++> TimelineMigration();
        # Timeline analysis and matching facts share one resumable migration.
        wanted=VERSION*1000+FACTS_VERSION;
        if migration.version!=wanted { migration.version=wanted;migration.after_key="";migration.complete=False; }
        if migration.complete { _catalog_rebuild();return {"complete":True,"updated":0}; }
        after_key=migration.after_key;
        batch=[root.shared --> [?:CatalogJob, key>after_key, key]][:50];
        for j in batch { data=dict(j.data);
            for field in ["description","qualifications","eligibility"] { data[field]=plain(data.get(field,"")); }
            data["timeline_analysis"]=analyze(data);data["facts"]=facts(data);j.data=data;_cache_after_commit(j);migration.after_key=j.key; }
        migration.complete=len(batch)<50;commit();return {"complete":migration.complete,"updated":len(batch)};
    }
}

"""Background catalog and feed upkeep, called by the collector loop and never on a user's request (#105, #107).
Warms or repairs the catalog view, then prepares queued account feeds until the time budget is spent."""
def:pub discovery_maintain(token: str, budget_seconds: float = 5.0) -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    started=time.time();system=jid(root);budget=max(0.5,min(float(budget_seconds),60.0));
    status=_catalog_status();rebuilt=False;
    if not status["ready"] or status["stale"] or status["age"]>CATALOG_REPAIR_SECONDS { rebuilt=_catalog_rebuild()>=0; }
    prepared=0;
    # Only each account's own turn is taken: agent and resume claims (sweep) never wait for feed preparation.
    _fresh();
    for request in [root.shared --> [?:FeedRequest, requested_at]] {
        if time.time()-started>budget { break; }
        owner=request.owner;wanted=dict(request.search);
        _agent_owner(owner);
        # The account turn keeps this request unchanged while its feed is prepared.
        with locks.account(owner) {
            memories=[root -->][?:AgentMemory];
            # Accounts that never opened the agent features have no memory yet; only deleted ones are skipped.
            if not (memories and memories[0].deleted) {
                if not wanted { saved=_saved_search();wanted=validate_filters(saved.get("query",""),saved.get("filters",{})); }
                _prepare_job_feed(wanted);prepared+=1;
            }
            _agent_owner(system);del request;commit();
        }
    }
    _agent_owner(system);
    return {"catalog":_catalog_status(),"rebuilt":rebuilt,"prepared":prepared,"pending":len([root.shared --> [?:FeedRequest]])};
}

def:pub discovery_report(token: str) -> dict[str, any] {
    if not _worker_allowed(token) { return {"error":"Worker authorization required."}; }
    sources=_source_views();jobs=[];
    for j in [root.shared -->][?:CatalogJob] {
        view=_job_view(j);view.pop("description",None);view.pop("qualifications",None);view.pop("requirements",None);jobs.append(view);
    }
    for j in jobs { j.pop("facts",None); }
    return {"generated_at":time.time(),"sources":sources,"jobs":jobs,"usage":[{"period":u.key,"reserved":u.amount} for u in [root.shared -->][?:Usage]]};
}

def _retained_snapshot(snapshot: dict[str, any]) -> dict[str, any] {
    source=_source(snapshot.get("source_id",""));
    if source is not None and source.status=="disabled" {
        return {"id":snapshot.get("id",""),"title":"Listing no longer available","company":"Source removed","url":"","color":"#EDF2FF","initial":"S","active":False,"demo":False};
    }
    result=dict(snapshot);result["timeline"]=assess(result,_timeline_preferences());return result;
}
