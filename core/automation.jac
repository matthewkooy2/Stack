"""Durable private agent memory. One API writer owns all transitions and reservations."""
import os;
import time;
import json;
import secrets;
import from uuid { uuid4, UUID }
import from pathlib { Path }
import from jaclang.runtime.runtime { JacRuntime }
import from core.catalog { _catalog_lock }
import from agents.contracts { VERSION, STEPS, PAID, EXTERNAL, TERMINAL, CLI_PROVIDERS, config, model_access, model_status, digest, default_policy, validate_policy, validate_facts, context_facts, authorize, reserve_cents, validate_contact }
import from agents.voice { voice_settings, voice_reservation, SECONDS }
import from agents.prep { catalog, problem, validate_session }
import from agents.security { seal, unseal }
import from agents.contacts { parse_contacts }
import from agents.google { authorization_url, exchange, refreshed, SCOPES }
import from jaclang.server.identity.app_tokens { token_create, token_peek, token_consume }

node AgentMemory { has facts: list[dict[str, any]] = [], policy: dict[str, any] = {}, revision: int = 0, admitted: bool = False, deleted: bool = False; }
node AgentRun {
    has kind: str, target_id: str, context: dict[str, any], created_at: float,
        key: str, status: str = "queued", index: int = 0, updated_at: float = 0.0,
        message: str = "Queued", requests: list[dict[str, any]] = [], artifacts: dict[str, any] = {},
        cost_cents: int = 0, lease: str = "", lease_until: float = 0.0, attempts: int = 0,
        policy_revision: int = 0, next_at: float = 0.0, projected: bool = False, ticket_hash: str = "",
        provider: str = "", subscription_calls: int = 0;
}
node AgentTicket { has owner: str, run_id: str, state: str = "queued", due_at: float = 0.0; }
node AgentAction { has run_id: str, step: str, key: str, payload_hash: str, policy_revision: int, created_at: float, status: str = "intent", receipt: dict[str, any] = {}; }
node AgentUsage { has key: str, cents: int = 0, actions: int = 0; }
node AgentContact { has data: dict[str, any], created_at: float, followups: int = 0, next_at: float = 0.0, thread_id: str = ""; }
node AgentConnection { has provider: str, sealed: str, scopes: list[str], state: str = "connected", checkpoint: str = "", updated_at: float = 0.0, calendar_id: str = ""; }
node AgentInterview { has key: str, application_id: str, event: dict[str, any], updated_at: float, calendar_receipt: str = "", study_plan: list[dict[str, any]] = []; }
node AgentEvent { has key: str, data: dict[str, any], created_at: float; }
node PrepSession { has data: dict[str, any], created_at: float, updated_at: float, revision: int = 0, results: list[dict[str, any]] = [], feedback: list[dict[str, any]] = [], recordings: list[dict[str, any]] = []; }
node AgentPushDevice { has key: str, sealed: str; }
node AgentNotification { has key: str, run_id: str, state: str = "queued", receipt: str = ""; }
node AgentAdmission { has owner: str, created_at: float; }

def _agent_fresh() -> None {
    ctx=JacRuntime.get_context(); owner=str(ctx.user_root.id);ctx.mem.abort();ctx.set_user_root(owner);
}
def _agent_memory() -> AgentMemory {
    with _catalog_lock {
        values=[root -->][?:AgentMemory];
        if values { return values[0]; }
        _agent_fresh();values=[root -->][?:AgentMemory];
        if values { return values[0]; }
        memory=root ++> AgentMemory(policy=default_policy());
        account=root.shared ++> AgentAdmission(owner=jid(root),created_at=time.time());
        JacRuntime.allow_root(account,UUID(jid(root.shared)),AccessLevel.READ); # jac:ignore[E1053]
        commit();return memory;
    }
}
def _agent_access() -> None {
    if _agent_memory().deleted { raise ValueError("This account has been deleted."); }
    if config()["invite_only"] and not _agent_memory().admitted { raise ValueError("An invitation is required for this beta."); }
}
def _agent_system(token: str) -> bool {
    expected=os.environ.get("STACK_AGENT_WORKER_TOKEN","");
    path=Path("storage/agents/worker-token");
    if not expected and path.exists() { expected=path.read_text().strip(); }
    return bool(expected) and secrets.compare_digest(expected,token) and jid(root)==jid(root.shared);
}
def _agent_owner(owner: str) -> None { JacRuntime.get_context().set_user_root(owner); }
def _owned_run(id: str) -> AgentRun | None {
    for r in [root -->][?:AgentRun] { if jid(r)==id { return r; } }
    return None;
}
def _run_view(r: AgentRun, detail: bool = False) -> dict[str, any] {
    steps=STEPS[r.kind];
    out={"id":jid(r),"kind":r.kind,"target_id":r.target_id,"status":r.status,"step":steps[min(r.index,len(steps)-1)],"message":r.message,"created_at":r.created_at,"updated_at":r.updated_at,"cost_cents":r.cost_cents,"provider":r.provider,"subscription_calls":r.subscription_calls};
    if detail { out.update({"requests":r.requests,"artifacts":r.artifacts}); }
    return out;
}
def _agent_summary() -> dict[str, any] {
    m=_agent_memory();
    runs=[_run_view(r) for r in [root --> [?:AgentRun, -created_at]][:30]];
    return {"enabled":m.policy.get("enabled",False),"needs_input":len([r for r in runs if r["status"] in ["needs_input","uncertain"]]),"runs":runs,"paid_configured":config()["monthly_cents"]>0,"model_provider":model_status(jid(root)),"admitted":m.admitted or not config()["invite_only"]};
}
def:priv agent_admission() -> dict[str, any] {
    try { _agent_access();return {"admitted":True}; } except ValueError { return {"admitted":False}; }
}
def:priv agent_settings() -> dict[str, any] {
    _agent_access();m=_agent_memory();
    return {"account_id":jid(root),"facts":m.facts,"policy":m.policy,"revision":m.revision,"connections":[{"id":jid(c),"provider":c.provider,"state":c.state,"scopes":c.scopes} for c in [root -->][?:AgentConnection]],"web_url":config()["web_url"],"activity":_agent_summary()};
}
def:priv agent_save_facts(facts: list[dict[str, any]]) -> dict[str, any] {
    _agent_access();
    try { validated=validate_facts(facts); } except ValueError as e { return {"error":str(e)}; }
    with _catalog_lock {
        _agent_fresh();m=_agent_memory();keys=[f["key"] for f in validated];
        m.facts=[f for f in m.facts if f["key"] not in keys]+validated;m.revision+=1;commit();
    }
    return agent_settings();
}
def:priv agent_save_policy(policy: dict[str, any]) -> dict[str, any] {
    _agent_access();
    try { validated=validate_policy(policy); } except ValueError as e { return {"error":str(e)}; }
    with _catalog_lock { _agent_fresh();m=_agent_memory();m.policy=validated;m.revision+=1;commit(); }
    return agent_settings();
}
def:priv agent_activity() -> dict[str, any] { _agent_access();return _agent_summary(); }
def:priv agent_events() -> dict[str, any] { _agent_access();return {"events":[{"id":jid(e),**e.data} for e in [root --> [?:AgentEvent, -created_at]][:100]],"interviews":[{"id":jid(i),"application_id":i.application_id,"study_plan":i.study_plan,**i.event} for i in [root -->][?:AgentInterview]]}; }
def:priv agent_run(id: str) -> dict[str, any] {
    _agent_access();r=_owned_run(id);return _run_view(r,True) if r is not None else {"error":"Run not found."};
}
def _agent_start(kind: str, target_id: str, context: dict[str, any], nonce: str = "", persist: bool = True) -> dict[str, any] {
    _agent_access();
    if kind not in STEPS { return {"error":"Unknown agent."}; }
    m=_agent_memory();context={**context,"facts":context_facts(m.facts,context),"prompt_version":VERSION};
    key=digest([kind,target_id,nonce or ("once" if kind in ["application","network"] else context)]);
    for old in [root -->][?:AgentRun] { if old.key==key { return _run_view(old,True); } }
    r=root ++> AgentRun(kind=kind,target_id=target_id,context=context,created_at=time.time(),updated_at=time.time(),key=key,policy_revision=m.revision);
    ticket=root.shared ++> AgentTicket(owner=jid(root),run_id=jid(r));
    JacRuntime.allow_root(ticket,UUID(jid(root.shared)),AccessLevel.WRITE); # jac:ignore[E1053]
    if persist { commit(); }
    return _run_view(r,True);
}
def:priv agent_cancel(id: str) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None { return {"error":"Run not found."}; }
        if r.status in TERMINAL { return _run_view(r,True); }
        # A dispatched side effect cannot be recalled; keep the uncertain receipt path.
        intents=[a for a in [root -->][?:AgentAction] if a.run_id==id and a.status=="intent"];
        r.status="uncertain" if intents else "cancelled";
        r.message="Cancellation requested; reconcile the dispatched action." if intents else "Cancelled";
        r.lease="";r.updated_at=time.time();commit();return _run_view(r,True);
    }
}
def:priv agent_respond(id: str, values: list[dict[str, any]] = [], reuse: bool = True) -> dict[str, any] {
    _agent_access();
    try { validated=validate_facts(values); } except ValueError as e { return {"error":str(e)}; }
    with _catalog_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None or r.status not in ["needs_input","blocked"] { return {"error":"This run is not waiting for input."}; }
        m=_agent_memory();keys=[f["key"] for f in validated];
        if reuse { m.facts=[f for f in m.facts if f["key"] not in keys]+validated;m.revision+=1; }
        r.context["facts"]=[f for f in m.facts if f["key"] not in keys]+validated;
        r.context["fact_overrides"]=[] if reuse else validated;
        if validated and r.kind in ["application","resume","jobs"] { r.index=0;r.artifacts={}; }
        r.status="queued";r.message="Ready to resume";r.requests=[];r.attempts=0;r.updated_at=time.time();
        for t in [root.shared -->][?:AgentTicket] { if t.run_id==id { t.state="queued";t.due_at=0; } }
        commit();return _run_view(r,True);
    }
}
def _usage(key: str) -> AgentUsage {
    # Global quotas are service-owned, never owned by the first consuming account.
    _agent_owner(jid(root.shared));
    for u in [root.shared -->][?:AgentUsage] { if u.key==key { return u; } }
    u=root.shared ++> AgentUsage(key=key);return u;
}
def:pub agent_claim(token: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();now=time.time();
        tickets=[t for t in [root.shared -->][?:AgentTicket] if t.state in ["queued","running"] and t.due_at<=now];
        for t in tickets {
            commit();_agent_owner(t.owner);r=_owned_run(t.run_id);
            if r is None { t.state="cancelled";continue; }
            if r.status in TERMINAL or r.status in ["needs_input","blocked","uncertain"] { t.state=r.status;continue; }
            if r.lease_until>now { continue; }
            step=STEPS[r.kind][r.index];
            if r.status=="running" {
                intents=[a for a in [root -->][?:AgentAction] if a.run_id==jid(r) and a.step==step and a.status=="intent"];
                if intents { r.status="uncertain";r.message="The action may have completed. Verify its receipt before continuing.";t.state="uncertain";continue; }
            }
            if r.attempts>=3 { r.status="failed";r.message="This step failed three times. Review the error before retrying.";t.state="failed";continue; }
            m=_agent_memory();overrides=r.context.get("fact_overrides",[]);override_keys=[f["key"] for f in overrides];
            current_facts=context_facts([f for f in m.facts if f["key"] not in override_keys]+overrides,r.context);
            if digest(r.context.get("facts",[]))!=digest(current_facts) and r.kind in ["application","resume","jobs"] {
                r.index=0;r.artifacts={};step=STEPS[r.kind][0];
                for a in [root -->][?:AgentAction] { if a.run_id==jid(r) and a.step=="fill" and a.status=="confirmed" { a.key=a.key+":"+jid(a); } }
            }
            r.context["facts"]=current_facts;
            reservation=0;c=config();
            try {
                _agent_access();
                if step in PAID {
                    authorize(m.policy,"model");model_access(c,t.owner);
                    if c["provider"] in CLI_PROVIDERS {
                        commit();day=time.strftime("%Y-%m-%d",time.gmtime());
                        usage=_usage("cli:"+day+":"+c["provider"]);
                        if usage.actions>=c["local_cli_daily_limit"] { raise ValueError("The local subscription daily request limit is reached."); }
                        usage.actions+=1;commit();_agent_owner(t.owner);r.subscription_calls+=1;
                    } else {
                        reservation=reserve_cents(r.context);
                        commit();month=time.strftime("%Y-%m",time.gmtime());
                        global_usage=_usage("cost:"+month);user_usage=_usage("cost:"+month+":"+t.owner);
                        if global_usage.cents+reservation>c["monthly_cents"] or user_usage.cents+reservation>c["user_monthly_cents"] { raise ValueError("The monthly agent budget is exhausted."); }
                        global_usage.cents+=reservation;user_usage.cents+=reservation;commit();
                        _agent_owner(t.owner);r.cost_cents+=reservation;
                    }
                    r.provider=c["provider"];
                }
            } except ValueError as e { _agent_owner(t.owner);r.status="blocked";r.message=str(e);t.state="blocked";continue; }
            r.status="running";r.lease=secrets.token_urlsafe(32);r.lease_until=now+180;r.attempts+=1;r.updated_at=now;r.message="Working on "+step;t.state="running";
            commit();return {"id":jid(r),"owner":t.owner,"lease":r.lease,"step":step,"context":r.context,"artifacts":r.artifacts,"reservation_cents":reservation,"provider_config_hash":digest(c)};
        }
        commit();return {"idle":True};
    }
}
def _agent_leased(id: str, owner: str, lease: str) -> AgentRun {
    _agent_owner(owner);r=_owned_run(id);
    if r is None or not lease or r.lease!=lease or r.lease_until<time.time() or r.status!="running" { raise ValueError("Run lease expired or cancelled."); }
    return r;
}
def:pub agent_authorize(token: str, id: str, owner: str, lease: str, payload_hash: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();
        try {
            r=_agent_leased(id,owner,lease);step=STEPS[r.kind][r.index];m=_agent_memory();
            if step not in EXTERNAL { return {"error":"This step has no external action."}; }
            action=EXTERNAL[step];destination=r.context.get("contact",{}).get("email","") if step=="send" else r.context.get("job",{}).get("url","");
            authorize(m.policy,action,destination);
            if step in ["send","calendar"] and not [c for c in [root -->][?:AgentConnection] if c.provider=="google" and c.state=="connected"] { raise ValueError("Google authorization was revoked or is unavailable."); }
            if step=="submit" {
                if r.artifacts.get("inspect",{}).get("adapter","") not in config()["certified_adapters"] { raise ValueError("This browser adapter is not certified for automatic submission."); }
            }
            if step=="send" {
                contacts=[c for c in [root -->][?:AgentContact] if jid(c)==r.target_id];
                if not contacts or contacts[0].data.get("email")!=r.context.get("contact",{}).get("email") or not contacts[0].data.get("selected") or contacts[0].data.get("stopped") { raise ValueError("This contact is not selected or outreach has stopped."); }
            }
            key=digest([id,step]);
            for old in [root -->][?:AgentAction] { if old.key==key { return {"error":"This action was already dispatched; reconcile its receipt."}; } }
            commit();day=time.strftime("%Y-%m-%d",time.gmtime());gu=_usage("action:"+day+":"+action);uu=_usage("action:"+day+":"+action+":"+owner);
            cap=config()["action_daily_limits"].get(action,0);
            if not cap or gu.actions>=cap or uu.actions>=m.policy["daily_limits"].get(action,0) { raise ValueError("Set an available operator and user daily limit for this action."); }
            gu.actions+=1;uu.actions+=1;commit();
            _agent_owner(owner);
            a=root ++> AgentAction(run_id=id,step=step,key=key,payload_hash=payload_hash,policy_revision=m.revision,created_at=time.time());
            r.policy_revision=m.revision;commit();return {"authorized":True,"action_id":jid(a),"policy_revision":m.revision};
        } except ValueError as e { return {"error":str(e)}; }
    }
}
def _agent_complete(token: str, id: str, owner: str, lease: str, result: dict[str, any]) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();
        try { r=_agent_leased(id,owner,lease); } except ValueError as e { return {"error":str(e)}; }
        step=STEPS[r.kind][r.index];r.lease="";r.lease_until=0;r.updated_at=time.time();
        intents=[a for a in [root -->][?:AgentAction] if a.run_id==id and a.step==step and a.status=="intent"];
        if result.get("error") {
            r.status="uncertain" if intents else "queued";r.message=str(result["error"])[:1000];r.next_at=time.time()+min(300.0,15.0*(2**r.attempts));
        } elif result.get("needs_input") {
            r.status="needs_input";r.requests=result.get("requests",[]);r.message=str(result.get("message","Your input is needed."))[:1000];
            # The browser can prove it stopped before sending/filling anything.
            if intents { r.status="uncertain";r.message="An action was dispatched; reconcile it before resuming."; }
        } else {
            artifact=result.get("artifact",{});
            if step in ["submit","send","calendar"] and not artifact.get("receipt") {
                r.status="uncertain";r.message="No confirmation receipt was returned.";
            } else {
                r.artifacts[step]=artifact;
                for a in intents { a.status="confirmed";a.receipt=artifact; }
                r.index+=1;r.attempts=0;r.status="completed" if r.index>=len(STEPS[r.kind]) else "queued";r.message="Completed" if r.status=="completed" else "Ready for next step";
                if step=="coach" {
                    for p in [root -->][?:PrepSession] { if jid(p)==r.target_id { p.feedback=p.feedback+[{"at":time.time(),"revision":r.context.get("session_revision",0),"data":artifact}]; } }
                }
                if step=="execute" {
                    for p in [root -->][?:PrepSession] { if jid(p)==r.target_id { p.results=p.results+[{"at":time.time(),"revision":r.context.get("session_revision",0),"data":artifact}]; } }
                }
            }
        }
        for t in [root.shared -->][?:AgentTicket] { if t.run_id==id { t.state=r.status;t.due_at=r.next_at; } }
        return _run_view(r,True);
    }
}
def:priv agent_reconcile(id: str, outcome: str, evidence: str) -> dict[str, any] {
    _agent_access();
    if outcome not in ["confirmed","not_sent"] or len(evidence.strip())<10 { return {"error":"Provide the confirmation or evidence that nothing was sent."}; }
    with _catalog_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None or r.status!="uncertain" { return {"error":"This run does not need reconciliation."}; }
        step=STEPS[r.kind][r.index];
        for a in [root -->][?:AgentAction] {
            if a.run_id==id and a.step==step and a.status=="intent" {
                a.status=outcome;a.receipt={"user_confirmed":True,"evidence":evidence};
                if outcome=="not_sent" { a.key=a.key+":"+jid(a); }
            }
        }
        if outcome=="not_sent" and step=="submit" {
            r.index=3;
            for a in [root -->][?:AgentAction] { if a.run_id==id and a.step=="fill" and a.status=="confirmed" { a.key=a.key+":"+jid(a); } }
        }
        if outcome=="confirmed" { r.artifacts[step]={"receipt":evidence,"user_confirmed":True};r.index+=1; }
        r.status="completed" if r.index>=len(STEPS[r.kind]) else "queued";r.message="Reconciled by you";r.attempts=0;
        for t in [root.shared -->][?:AgentTicket] { if t.run_id==id { t.state=r.status;t.due_at=0; } }
        commit();return _run_view(r,True);
    }
}
def:priv agent_contacts() -> dict[str, any] { _agent_access();return {"contacts":[{"id":jid(c),**c.data,"followups":c.followups,"next_at":c.next_at} for c in [root -->][?:AgentContact]]}; }
def:priv agent_save_contact(data: dict[str, any], id: str = "") -> dict[str, any] {
    _agent_access();
    try { validated=validate_contact(data); } except ValueError as e { return {"error":str(e)}; }
    with _catalog_lock {
        _agent_fresh();
        if id {
            items=[c for c in [root -->][?:AgentContact] if jid(c)==id];
            if not items { return {"error":"Contact not found."}; }
            validated["stopped"]=items[0].data.get("stopped",False);items[0].data=validated;saved_contact=items[0];
        } else { saved_contact=root ++> AgentContact(data=validated,created_at=time.time()); }
        m=_agent_memory();
        if validated.get("selected") and not validated.get("stopped") and m.policy.get("enabled") and "send_email" in m.policy.get("actions",[]) { _agent_start("network",jid(saved_contact),{"contact":validated,"thread_id":saved_contact.thread_id}); }
        commit();return agent_contacts();
    }
}
def:priv agent_stop_contact(id: str) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();
        for c in [root -->][?:AgentContact] { if jid(c)==id { c.data["stopped"]=True;c.next_at=0;commit();return agent_contacts(); } }
    }
    return {"error":"Contact not found."};
}
def:priv prep_catalog() -> dict[str, any] { _agent_access();return {"problems":catalog()}; }
def:priv prep_sessions() -> dict[str, any] { _agent_access();return {"sessions":[{"id":jid(p),"data":p.data,"revision":p.revision,"updated_at":p.updated_at} for p in [root --> [?:PrepSession, -updated_at]][:50]]}; }
def:priv prep_create(problem_id: str, language: str = "", application_id: str = "") -> dict[str, any] {
    _agent_access();
    try { spec=problem(problem_id);data=validate_session({"problem_id":problem_id,"language":language,"code":spec.get("starter",{}).get(language,"")}); }
    except ValueError as e { return {"error":str(e)}; }
    data["application_id"]=application_id;
    p=root ++> PrepSession(data=data,created_at=time.time(),updated_at=time.time());commit();return {"id":jid(p),"data":p.data,"revision":p.revision,"results":[],"feedback":[]};
}
def:priv prep_get(id: str) -> dict[str, any] {
    _agent_access();
    for p in [root -->][?:PrepSession] { if jid(p)==id { return {"id":jid(p),"data":p.data,"revision":p.revision,"results":p.results,"feedback":p.feedback,"recordings":p.recordings}; } }
    return {"error":"Practice session not found."};
}
def:priv prep_save(id: str, revision: int, data: dict[str, any]) -> dict[str, any] {
    _agent_access();
    try { validated=validate_session(data); } except ValueError as e { return {"error":str(e)}; }
    with _catalog_lock {
        _agent_fresh();
        for p in [root -->][?:PrepSession] {
            if jid(p)==id {
                if p.revision!=revision { return {"error":"This session changed on another device. Reload before saving."}; }
                validated["application_id"]=p.data.get("application_id","");p.data=validated;p.revision+=1;p.updated_at=time.time();commit();return prep_get(id);
            }
        }
    }
    return {"error":"Practice session not found."};
}

def:pub agent_invite(token: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Operator authorization required."}; }
    return {"invite":token_create("stack-beta",subject="operator",ttl_seconds=604800,payload={"admitted":True})};
}
def:priv agent_accept_invite(invite: str) -> dict[str, any] {
    with _catalog_lock {
        _agent_fresh();if _agent_memory().deleted { return {"error":"This account was deleted."}; }
        accepted=token_consume("stack-beta",invite);
        if accepted is None { return {"error":"Invitation is invalid, expired, or already used."}; }
        _agent_memory().admitted=True;commit();return {"admitted":True};
    }
}
def:priv agent_google_start(capabilities: list[str]) -> dict[str, any] {
    _agent_access();verifier=secrets.token_urlsafe(48);
    try {
        encrypted=seal({"verifier":verifier});
        state=token_create("stack-google",subject=jid(root),ttl_seconds=600,payload={"owner":jid(root),"sealed":encrypted});
        return {"url":authorization_url(state,verifier,capabilities)};
    } except ValueError as e { return {"error":str(e)}; }
}
def:priv agent_google_finish(state: str, code: str) -> dict[str, any] {
    _agent_access();
    pending=token_peek("stack-google",state);
    if pending is None or pending["payload"]["owner"]!=jid(root) { return {"error":"Google connection belongs to another account or has expired."}; }
    consumed=token_consume("stack-google",state);
    if consumed is None { return {"error":"This authorization was already used."}; }
    try { tokens=exchange(code,str(unseal(str(consumed["payload"]["sealed"]))["verifier"]));encrypted=seal(tokens); }
    except Exception { return {"error":"Google authorization failed. Start a new connection."}; }
    with _catalog_lock {
        _agent_fresh();items=[root -->][?:AgentConnection];
        for old in items { if old.provider=="google" { old.sealed=encrypted;old.scopes=str(tokens.get("scope","")).split();old.state="connected";commit();return agent_settings(); } }
        root ++> AgentConnection(provider="google",sealed=encrypted,scopes=str(tokens.get("scope","")).split(),updated_at=time.time());commit();
    }
    return agent_settings();
}
def:priv agent_disconnect(id: str) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();
        for c in [root -->][?:AgentConnection] {
            if jid(c)==id { c.state="revoked";c.sealed="";c.checkpoint="";commit();return agent_settings(); }
        }
    }
    return {"error":"Connection not found."};
}
def:pub agent_worker_connection(token: str, id: str, owner: str, lease: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();
        try {
            r=_agent_leased(id,owner,lease);step=STEPS[r.kind][r.index];
            if step not in ["send","sync","calendar"] { return {"error":"This step cannot access Google."}; }
            authorize(_agent_memory().policy,"gmail_read" if step=="sync" else ("calendar_write" if step=="calendar" else "send_email"));
            for c in [root -->][?:AgentConnection] {
                scope=str(SCOPES["read" if step=="sync" else ("calendar" if step=="calendar" else "send")]);
                if c.provider=="google" and c.state=="connected" and scope in c.scopes {
                    tokens=refreshed(unseal(c.sealed));c.sealed=seal(tokens);c.updated_at=time.time();commit();
                    return {"tokens":{"access_token":tokens["access_token"],"expires_at":tokens.get("expires_at",0)},"checkpoint":json.loads(c.checkpoint) if c.checkpoint else {},"calendar_id":c.calendar_id};
                }
            }
            return {"error":"Connect Google with the required email permission."};
        } except ValueError as e { return {"error":str(e)}; }
    }
}
def:priv agent_export() -> dict[str, any] {
    _agent_access();return {"settings":agent_settings(),"runs":[_run_view(r,True) for r in [root -->][?:AgentRun]],"contacts":agent_contacts(),"sessions":[prep_get(jid(p)) for p in [root -->][?:PrepSession]],"events":[e.data for e in [root -->][?:AgentEvent]]};
}


def:priv agent_import_contacts(content: str) -> dict[str, any] {
    _agent_access();
    try { values=parse_contacts(content); } except ValueError as e { return {"error":str(e)}; }
    with _catalog_lock {
        _agent_fresh();known=[c.data.get("email") for c in [root -->][?:AgentContact]];
        for data in values {
            if data.get("email") and data["email"] in known { continue; }
            root ++> AgentContact(data=data,created_at=time.time());known.append(data.get("email"));
        }
        commit();return agent_contacts();
    }
}


def:priv agent_register_push(device_token: str) -> dict[str, any] {
    _agent_access();
    if not device_token.startswith("ExponentPushToken[") and not device_token.startswith("ExpoPushToken[") { return {"error":"Unsupported push token."}; }
    if len(device_token)>200 { return {"error":"Invalid push token."}; }
    try { encrypted=seal({"token":device_token}); } except ValueError as e { return {"error":str(e)}; }
    with _catalog_lock {
        _agent_fresh();key=digest(device_token);
        for d in [root -->][?:AgentPushDevice] { if d.key==key { return {"registered":True}; } }
        root ++> AgentPushDevice(key=key,sealed=encrypted);commit();return {"registered":True};
    }
}
def:priv agent_remove_push(device_token: str) -> dict[str, any] {
    with _catalog_lock {
        _agent_fresh();key=digest(device_token);
        for d in [root -->][?:AgentPushDevice] { if d.key==key { del d; } }
        commit();return {"removed":True};
    }
}
def:pub agent_notification_claim(token: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();owners=[a.owner for a in [root.shared -->][?:AgentAdmission]];
        for owner in owners {
            _agent_owner(owner);
            for n in [root -->][?:AgentNotification] {
                if n.state!="queued" { continue; }
                n.state="dispatched";devices=[unseal(d.sealed)["token"] for d in [root -->][?:AgentPushDevice]];commit();
                return {"owner":owner,"id":jid(n),"run_id":n.run_id,"devices":devices};
            }
        }
        return {"idle":True};
    }
}
def:pub agent_notification_finish(token: str, owner: str, id: str, receipt: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();_agent_owner(owner);
        for n in [root -->][?:AgentNotification] {
            if jid(n)==id and n.state=="dispatched" { n.state="sent" if receipt else "failed";n.receipt=receipt;commit();return {"saved":True}; }
        }
        return {"error":"Notification not found."};
    }
}


def:pub agent_report(token: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Operator authorization required."}; }
    with _catalog_lock {
        _agent_fresh();return {"usage":[{"key":u.key,"cents":u.cents,"actions":u.actions} for u in [root.shared -->][?:AgentUsage]],"queue":[{"state":t.state,"due_at":t.due_at} for t in [root.shared -->][?:AgentTicket]]};
    }
}


def:priv prep_live(id: str) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();owner=jid(root);m=_agent_memory();
        sessions=[p for p in [root -->][?:PrepSession] if jid(p)==id];
        if not sessions { return {"error":"Practice session not found."}; }
        p=sessions[0];context={"session":p.data,"problem":problem(str(p.data["problem_id"])),"results":p.results[-3:]};
        for old in [root -->][?:AgentRun] {
            if old.kind=="live" and old.target_id==id and old.status in ["waiting","running"] {
                if old.lease_until>time.time() { return {"error":"A live interview is already open. End or cancel it first."}; }
                old.status="failed";old.message="Live session expired; its reserved budget is retained.";
            }
        }
        try {
            authorize(m.policy,"model");settings=voice_settings();reservation=voice_reservation(context);commit();
            month=time.strftime("%Y-%m",time.gmtime());c=config();g=_usage("cost:"+month);u=_usage("cost:"+month+":"+owner);
            if g.cents+reservation>c["monthly_cents"] or u.cents+reservation>c["user_monthly_cents"] { _agent_owner(owner);return {"error":"The live interview exceeds the available budget."}; }
            g.cents+=reservation;u.cents+=reservation;commit();_agent_owner(owner);
            context["voice_settings"]=settings;
            ticket=secrets.token_urlsafe(32);r=root ++> AgentRun(kind="live",target_id=id,context=context,created_at=time.time(),updated_at=time.time(),key=digest(ticket),ticket_hash=digest(ticket),status="waiting",message="Ready to start live interview",lease_until=time.time()+60,cost_cents=reservation);
            commit();return {"id":jid(r),"owner":owner,"ticket":ticket,"url":settings["url"],"reserved_cents":reservation};
        } except ValueError as e { _agent_owner(owner);return {"error":str(e)}; }
    }
}
def:pub agent_live_claim(token: str, owner: str, id: str, ticket: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Voice service authorization required."}; }
    with _catalog_lock {
        _agent_fresh();_agent_owner(owner);_agent_access();r=_owned_run(id);
        if r is None or r.kind!="live" or r.status!="waiting" or r.lease_until<time.time() or not secrets.compare_digest(r.ticket_hash,digest(ticket)) { return {"error":"This live ticket expired or was already used."}; }
        try {
            authorize(_agent_memory().policy,"model");
            if r.context.get("voice_settings")!=voice_settings() { return {"error":"Voice pricing or configuration changed. Start a new interview."}; }
        } except ValueError as e { return {"error":str(e)}; }
        r.ticket_hash="";r.status="running";r.message="Live practice interview";r.lease=secrets.token_urlsafe(32);r.lease_until=time.time()+SECONDS+20;commit();
        return {"id":id,"owner":owner,"lease":r.lease,"context":r.context};
    }
}
def:pub agent_live_check(token: str, owner: str, id: str, lease: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Voice service authorization required."}; }
    try {
        r=_agent_leased(id,owner,lease);_agent_access();authorize(_agent_memory().policy,"model");
        return {"active":True,"practice":prep_get(r.target_id)};
    } except ValueError as e { return {"error":str(e)}; }
}
def:pub agent_live_finish(token: str, owner: str, id: str, lease: str, transcript: str, usage: list[dict[str, any]]) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Voice service authorization required."}; }
    with _catalog_lock {
        _agent_fresh();_agent_owner(owner);r=_owned_run(id);
        if r is None or r.kind!="live" or r.status!="running" or r.lease!=lease { return {"error":"Live session ended or was cancelled."}; }
        r.status="completed";r.lease="";r.message="Interview saved. Review your transcript before coaching.";r.artifacts={"interview":{"transcript":transcript[:30000],"usage":usage[:8]}};
        for p in [root -->][?:PrepSession] { if jid(p)==r.target_id { p.recordings=p.recordings+[{"run_id":id,"transcript":transcript[:30000],"at":time.time()}]; } }
        commit();return _run_view(r,True);
    }
}


def:priv prep_progress() -> dict[str, any] {
    _agent_access();return {"attempts":[{"id":jid(p),"problem_id":p.data["problem_id"],"revision":p.revision,"test_results":p.results,"feedback":p.feedback,"updated_at":p.updated_at} for p in [root -->][?:PrepSession]]};
}
