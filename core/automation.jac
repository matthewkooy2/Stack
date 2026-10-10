"""Durable private agent memory. One API writer owns all transitions and reservations."""
import os;
import time;
import json;
import agents.worker as browser_worker;
import secrets;
import from uuid { uuid4, UUID }
import from pathlib { Path }
import from jaclang.runtime.runtime { JacRuntime }
import from core.catalog { _catalog_lock }
import from agents.contracts { VERSION, STEPS, workflow_steps, PAID, EXTERNAL, TERMINAL, CLI_PROVIDERS, LOCAL_PROVIDERS, config, model_access, model_status, digest, default_policy, validate_policy, validate_facts, context_facts, authorize, reserve_cents, validate_contact }
import from agents.voice { voice_settings, voice_reservation, SECONDS }
import from agents.prep { catalog, problem, validate_session }
import from agents.stories { validate as validate_story, corrected as correct_story, missing as story_missing, TOPICS }
import from agents.security { seal, unseal }
import agents.notifications as push;
import from agents.contacts { parse_contacts }
import from agents.experience { REVIEWED, ATTENTION, ACTIVE, review_payload, review_summary, present }
import from agents.google { authorization_url, exchange, refreshed, SCOPES }
import from agents.tracing { capture_enabled, trace_data }
import from agents.browser_control { BROWSER_ERROR_MESSAGE, sanitize_browser_diagnostic }
import agents.interview as interview;
import from jaclang.server.identity.app_tokens { token_create, token_peek, token_consume }

node AgentMemory { has facts: list[dict[str, any]] = [], policy: dict[str, any] = {}, revision: int = 0, admitted: bool = False, deleted: bool = False, model_selection: str = ""; }
node AgentRun {
    has kind: str, target_id: str, context: dict[str, any], created_at: float,
        key: str, status: str = "queued", index: int = 0, updated_at: float = 0.0,
        message: str = "Queued", requests: list[dict[str, any]] = [], artifacts: dict[str, any] = {},
        cost_cents: int = 0, lease: str = "", lease_until: float = 0.0, attempts: int = 0,
        policy_revision: int = 0, next_at: float = 0.0, projected: bool = False, ticket_hash: str = "",
        provider: str = "", subscription_calls: int = 0,
        trace_attempt: str = "", requested_model: str = "", stage_started_at: float = 0.0,
        approvals: dict[str, any] = {}, review: dict[str, any] = {}, dismissed: bool = False;
    has workflow_version: int = 1, upgrade_pending: bool = False, model_selection: str = "";
}
node AgentTrace { has run_id: str, attempt: str, step: str, event: str, at: float, data: dict[str, any]; }
node AgentFeedback { has run_id: str, output_version: str, rating: str, note: str, at: float, snapshot: dict[str, any]; }
node AgentModelLog { has run_id: str, attempt_id: str, step: str, created_at: float, updated_at: float, data: dict[str, any]; }
node AgentTicket { has owner: str, run_id: str, state: str = "queued", due_at: float = 0.0; }
node AgentAction { has run_id: str, step: str, key: str, payload_hash: str, policy_revision: int, created_at: float, status: str = "intent", receipt: dict[str, any] = {}; }
node AgentUsage { has key: str, cents: int = 0, actions: int = 0; }
node AgentContact { has data: dict[str, any], created_at: float, followups: int = 0, next_at: float = 0.0, thread_id: str = ""; }
node AgentConnection { has provider: str, sealed: str, scopes: list[str], state: str = "connected", checkpoint: str = "", updated_at: float = 0.0, calendar_id: str = ""; }
node AgentInterview { has key: str, application_id: str, event: dict[str, any], updated_at: float, calendar_receipt: str = "", study_plan: list[dict[str, any]] = []; }
node AgentEvent { has key: str, data: dict[str, any], created_at: float; }
node PrepSession { has data: dict[str, any], created_at: float, updated_at: float, revision: int = 0, results: list[dict[str, any]] = [], feedback: list[dict[str, any]] = [], recordings: list[dict[str, any]] = []; }
node BehavioralStory { has title: str, source: dict[str, any], content: dict[str, any], created_at: float, updated_at: float, revision: int = 0, history: list[dict[str, any]] = []; }
node AgentPushDevice { has key: str, sealed: str; }
node AgentNotification {
    has key: str, run_id: str, state: str = "queued", receipt: str = "";
    has initialized: bool = False, deliveries: list[dict[str, any]] = [];
}
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
def _steps(r: AgentRun) -> list[str] { return workflow_steps(r.kind, r.workflow_version); }

# Only explicit continuation changes an old run's workflow. Receipts keep their original step names.
def _pause_legacy(r: AgentRun) -> bool {
    if r.status in TERMINAL { return False; }
    if r.kind=="application" {
        intents=[a for a in [root -->][?:AgentAction] if a.run_id==jid(r) and a.status=="intent"];
        status="uncertain" if intents else "cancelled";
        message="Application assistant retired. Reconcile the previously dispatched action." if intents else "Application assistant retired. Saved results remain available.";
        if r.status==status and r.message==message and not r.lease { return False; }
        r.status=status;r.message=message;r.lease="";r.lease_until=0.0;r.next_at=0.0;r.review={};r.approvals={};r.requests=[];r.upgrade_pending=False;r.updated_at=time.time();
        for t in [root.shared -->][?:AgentTicket] { if t.run_id==jid(r) { t.state=status;t.due_at=0.0; } }
        return True;
    }
    if r.workflow_version != 1 or r.kind!="resume" { return False; }
    intents=[a for a in [root -->][?:AgentAction] if a.run_id==jid(r) and a.status=="intent"];
    status="uncertain" if intents else "blocked";
    if r.upgrade_pending and r.status==status { return False; }
    r.upgrade_pending=True;r.status=status;r.lease="";r.lease_until=0.0;r.next_at=0.0;r.review={};r.approvals={};
    r.message="Reconcile the previously dispatched action before continuing after the update." if intents else "Stack was updated. Retry to prepare this task with the new resume review; nothing will be shared automatically.";
    r.updated_at=time.time();
    for t in [root.shared -->][?:AgentTicket] { if t.run_id==jid(r) { t.state=status;t.due_at=0.0; } }
    return True;
}
def _upgrade_legacy_runs() -> int {
    changed=0;
    with _catalog_lock {
        for r in [root -->][?:AgentRun] { if _pause_legacy(r) { changed+=1; } }
        if changed { commit(); }
    }
    return changed;
}
def _continue_legacy(r: AgentRun) -> None {
    if r.workflow_version != 1 or r.kind!="resume" { return; }
    actions=[a for a in [root -->][?:AgentAction] if a.run_id==jid(r)];
    if any(a.status=="intent" for a in actions) { raise ValueError("Reconcile the dispatched action first."); }
    r.workflow_version=2;r.upgrade_pending=False;r.index=0;r.artifacts={};r.review={};r.approvals={};
    # The normal tailor blocker refreshes the current resume/source from the saved application.
    r.context={**r.context,"resume_format":""};
}

def _needs_attention(r: AgentRun) -> bool {
    return r.status in ATTENTION or r.status=="paused" or (r.status=="failed" and not r.dismissed);
}
"""Tailoring edits LaTeX: the user's upload or a built-in template they chose (resume_format is set by the app)."""
def _tailor_ready(context: dict[str, any]) -> bool {
    return context.get("resume_format","") in ["latex","builtin","records"];
}
def _run_view(r: AgentRun, detail: bool = False) -> dict[str, any] {
    steps=_steps(r);
    out={"id":jid(r),"kind":r.kind,"target_id":r.target_id,"status":r.status,"step":steps[min(r.index,len(steps)-1)],"message":r.message,"created_at":r.created_at,"updated_at":r.updated_at,"cost_cents":r.cost_cents,"provider":r.provider,"subscription_calls":r.subscription_calls,"dismissed":r.dismissed,"workflow_version":r.workflow_version,"upgrade_pending":r.upgrade_pending,
        **present(r.kind,r.status,r.index,steps,r.context,r.next_at)};
    out["attention"]=_needs_attention(r) or r.status=="paused";
    out["browser"]={"supported":r.kind=="linkedin","available":r.status not in TERMINAL and r.kind=="linkedin" and r.index==0};
    out["needs_resume_review"]=r.status=="needs_input" and out["step"]=="tailor" and not _tailor_ready(r.context);
    out["has_requests"]=len(r.requests)>0;
    out["retry_at"]=r.next_at if r.status=="queued" and r.attempts>0 else 0.0;
    if r.status=="review" { out["review"]=r.review; }
    if detail { out.update({"requests":r.requests,"artifacts":r.artifacts,"resume_id":r.context.get("resume_id",""),"resume_name":r.context.get("resume_name","")}); }
    if detail { out.update({"output_version":digest(r.artifacts),"feedback":[{"id":jid(f),"rating":f.rating,"note":f.note,"at":f.at,"output_version":f.output_version} for f in [root --> [?:AgentFeedback, run_id==jid(r), -at]][:50]]}); }
    return out;
}
def _agent_summary() -> dict[str, any] {
    m=_agent_memory();_upgrade_legacy_runs();
    ordered=[root --> [?:AgentRun, -created_at]];
    # Runs needing the user stay listed even when newer tasks push them past the recent window.
    shown=[r for r in ordered if _needs_attention(r)]+[r for r in ordered[:30] if not _needs_attention(r)];
    runs=[_run_view(r) for r in shown];
    attention=len([r for r in ordered if _needs_attention(r)]);
    return {"enabled":m.policy.get("enabled",False),"needs_input":attention,"attention":attention,"active":len([r for r in ordered if r.status in ACTIVE]),"runs":runs,"paid_configured":config()["monthly_cents"]>0,"model_provider":model_status(jid(root),m.model_selection),"admitted":m.admitted or not config()["invite_only"],"expires_at":m.policy.get("expires_at",0)};
}
def:priv agent_admission() -> dict[str, any] {
    try { _agent_access();return {"admitted":True}; } except ValueError { return {"admitted":False}; }
}
def:priv agent_settings() -> dict[str, any] {
    _agent_access();m=_agent_memory();
    return {"account_id":jid(root),"model_selection":m.model_selection or ("local" if config()["provider"] in LOCAL_PROVIDERS else "codex-cli" if config()["provider"]=="codex-cli" else ""),"model_options":[{"selection":choice,**model_status(jid(root),choice)} for choice in ["codex-cli","local"]],"facts":m.facts,"policy":m.policy,"revision":m.revision,"connections":[{"id":jid(c),"provider":c.provider,"state":c.state,"scopes":c.scopes} for c in [root -->][?:AgentConnection]],"web_url":config()["web_url"],"activity":_agent_summary()};
}
def:priv agent_save_model(selection: str) -> dict[str, any] {
    _agent_access();
    if selection not in ["codex-cli","local"] { return {"error":"Choose Codex CLI or Local model."}; }
    with _catalog_lock {
        _agent_fresh();m=_agent_memory();m.model_selection=selection;commit();
    }
    return agent_settings();
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
    _agent_access();_upgrade_legacy_runs();r=_owned_run(id);return _run_view(r,True) if r is not None else {"error":"Run not found."};
}
def _trace(r: AgentRun, event: str, data: dict[str, any]) -> None {
    root ++> AgentTrace(run_id=jid(r),attempt=r.trace_attempt,step=_steps(r)[min(r.index,len(_steps(r))-1)],event=event,at=time.time(),data=trace_data(data));
}
def:pub agent_trace(token: str, id: str, owner: str, lease: str, event: str, data: dict[str, any]) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    if event not in ["model_request","model_response","model_validation"] { return {"error":"Unsupported trace event."}; }
    with _catalog_lock {
        _agent_fresh();
        try { r=_agent_leased(id,owner,lease);_agent_access(); }
        except ValueError as e { return {"error":str(e)}; }
        if not capture_enabled() { data={k:v for (k,v) in data.items() if k in ["provider","requested_model","reported_models","exit_code","valid","model_attempt"]}; }
        _trace(r,event,data);commit();return {"saved":True};
    }
}
def:priv agent_traces(id: str) -> dict[str, any] {
    _agent_access();
    if _owned_run(id) is None { return {"error":"Run not found."}; }
    return {"events":[{"id":jid(t),"attempt":t.attempt,"step":t.step,"event":t.event,"at":t.at,"data":t.data} for t in [root --> [?:AgentTrace, run_id==id, at]]]};
}
def:priv agent_feedback(id: str, output_version: str, rating: str, note: str) -> dict[str, any] {
    _agent_access();note=note.strip();
    if rating not in ["good","mixed","bad"] or not note or len(note)>4000 { return {"error":"Choose a rating and enter feedback (1-4,000 characters)."}; }
    note=str(trace_data({"note":note})["note"]);
    with _catalog_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None { return {"error":"Run not found."}; }
        if not r.artifacts or digest(r.artifacts)!=output_version { return {"error":"The output changed. Refresh the task before leaving feedback."}; }
        existing=[f for f in [root -->][?:AgentFeedback] if f.run_id==id and f.output_version==output_version and f.rating==rating and f.note==note];
        if not existing {
            root ++> AgentFeedback(run_id=id,output_version=output_version,rating=rating,note=note,at=time.time(),snapshot=trace_data({"artifacts":r.artifacts,"provider":r.provider,"requested_model":r.requested_model,"attempt":r.trace_attempt}));
            commit();
        }
        return _run_view(r,True);
    }
}
def _agent_start(kind: str, target_id: str, context: dict[str, any], nonce: str = "", persist: bool = True) -> dict[str, any] {
    _agent_access();
    if kind not in STEPS { return {"error":"Unknown agent."}; }
    m=_agent_memory();context={**context,"facts":context_facts(m.facts,context),"prompt_version":VERSION};
    key=digest([kind,target_id,nonce or ("once" if kind=="network" else context)]);
    for old in [root -->][?:AgentRun] { if old.key==key { return _run_view(old,True); } }
    r=root ++> AgentRun(workflow_version=2,kind=kind,target_id=target_id,context=context,model_selection=m.model_selection,created_at=time.time(),updated_at=time.time(),key=key,policy_revision=m.revision);
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
        r.lease="";r.updated_at=time.time();commit();
        close_browser=r.kind=="linkedin";owner=jid(root);out=_run_view(r,True);
    }
    # Closing a remote browser must not hold up every account's database writer.
    if close_browser {
        try { browser_worker.browser_call("control",{"owner":owner,"id":id,"action":"stop"},2); }
        except Exception { out["message"]="Cancelled. The browser could not be reached; its session expires after one idle hour."; }
    }
    return out;
}
def:priv agent_respond(id: str, values: list[dict[str, any]] = [], reuse: bool = True) -> dict[str, any] {
    _agent_access();
    try { validated=validate_facts(values); } except ValueError as e { return {"error":str(e)}; }
    with _catalog_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None or r.status not in ["needs_input","blocked"] { return {"error":"This run is not waiting for input."}; }
        if r.kind=="application" { return {"error":"The application assistant has been retired."}; }
        if r.kind=="linkedin" and len(validated)>0 { return {"error":"Enter LinkedIn login details only in the browser handoff, never in task answers."}; }
        _continue_legacy(r);
        if r.status=="completed" { commit();return _run_view(r,True); }
        m=_agent_memory();keys=[f["key"] for f in validated];
        if reuse { m.facts=[f for f in m.facts if f["key"] not in keys]+validated;m.revision+=1; }
        r.context["facts"]=[f for f in m.facts if f["key"] not in keys]+validated;
        r.context["fact_overrides"]=[] if reuse else validated;
        if validated and r.kind in ["resume","jobs"] { r.index=0;r.artifacts={}; }
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
            if _pause_legacy(r) { commit();continue; }
            if r.status in TERMINAL or r.status in ["needs_input","blocked","uncertain","review","paused"] { t.state=r.status;continue; }
            if r.lease_until>now { continue; }
            step=_steps(r)[r.index];
            if r.status=="running" {
                intents=[a for a in [root -->][?:AgentAction] if a.run_id==jid(r) and a.step==step and a.status=="intent"];
                if intents { r.status="uncertain";r.message="The action may have completed. Verify its receipt before continuing.";t.state="uncertain";continue; }
            }
            if r.attempts>=3 { r.status="failed";r.message="This step failed three times. Review the error before retrying.";t.state="failed";continue; }
            m=_agent_memory();overrides=r.context.get("fact_overrides",[]);override_keys=[f["key"] for f in overrides];
            current_facts=context_facts([f for f in m.facts if f["key"] not in override_keys]+overrides,r.context);
            if digest(r.context.get("facts",[]))!=digest(current_facts) and r.kind in ["resume","jobs"] {
                r.index=0;r.artifacts={};step=_steps(r)[0];
            }
            r.context["facts"]=current_facts;
            reservation=0;c=config(r.model_selection);
            if step=="tailor" and not _tailor_ready(r.context) {
                r.status="needs_input";r.requests=[];r.updated_at=now;t.state="needs_input";
                r.message="Upload a resume before tailoring." if not r.context.get("resume_id") else "Review and confirm this resume's imported records or add its LaTeX before tailoring.";
                continue;
            }
            try {
                _agent_access();
                if step in REVIEWED {
                    # Surface missing permissions before asking for review; agent_authorize rechecks at dispatch.
                    if step in EXTERNAL { authorize(m.policy,EXTERNAL[step],r.context.get("contact",{}).get("email","") if step=="send" else ""); }
                    reviewed=digest(review_payload(step,r.context,r.artifacts));
                    if r.approvals.get(step)!=reviewed {
                        r.status="review";r.review={**review_summary(step,r.context,r.artifacts),"hash":reviewed};
                        missing=_google_missing(step);
                        if missing { r.review["notes"]=r.review["notes"]+[missing];r.review["blocked"]=missing; }
                        r.message="Review before Stack continues: "+r.review["title"];r.updated_at=now;t.state="review";continue;
                    }
                }
                if step=="linkedin_scan" { authorize(m.policy,"model");model_access(c,t.owner); }
                if step in PAID {
                    authorize(m.policy,"model");model_access(c,t.owner);
                    if c["provider"] in CLI_PROVIDERS {
                        commit();day=time.strftime("%Y-%m-%d",time.gmtime());
                        usage=_usage("cli:"+day+":"+c["provider"]);
                        if usage.actions>=c["local_cli_daily_limit"] { raise ValueError("The local subscription daily request limit is reached."); }
                        usage.actions+=1;commit();_agent_owner(t.owner);r.subscription_calls+=1;
                    } elif c["provider"] not in LOCAL_PROVIDERS {
                        reservation=reserve_cents({**r.context,"linkedin_profile":r.artifacts.get("linkedin_scan",{})} if step=="linkedin_review" else r.context);
                        commit();month=time.strftime("%Y-%m",time.gmtime());
                        global_usage=_usage("cost:"+month);user_usage=_usage("cost:"+month+":"+t.owner);
                        if global_usage.cents+reservation>c["monthly_cents"] or user_usage.cents+reservation>c["user_monthly_cents"] { raise ValueError("The monthly agent budget is exhausted."); }
                        global_usage.cents+=reservation;user_usage.cents+=reservation;commit();
                        _agent_owner(t.owner);r.cost_cents+=reservation;
                    }
                    r.provider=c["provider"];
                }
            } except ValueError as e { _agent_owner(t.owner);r.status="blocked";r.message=str(e);t.state="blocked";_trace(r,"blocked",{"message":str(e)});continue; }
            r.status="running";r.lease=secrets.token_urlsafe(32);r.lease_until=now+180;r.attempts+=1;r.updated_at=now;r.message="Working on "+step;t.state="running";
            r.trace_attempt=str(uuid4());r.requested_model=c["model"] or "provider default";r.stage_started_at=time.time();
            _trace(r,"stage_start",{"provider":c["provider"],"requested_model":r.requested_model,"attempt_number":r.attempts,"prompt_version":r.context.get("prompt_version"),"context":r.context if capture_enabled() else {"content_capture":False}});
            commit();return {"id":jid(r),"owner":t.owner,"lease":r.lease,"step":step,"context":r.context,"artifacts":r.artifacts,"reservation_cents":reservation,"provider_config_hash":digest(c),"model_selection":r.model_selection};
        }
        commit();return {"idle":True};
    }
}
def _agent_leased(id: str, owner: str, lease: str) -> AgentRun {
    _agent_owner(owner);r=_owned_run(id);
    if r is None or r.kind=="application" or not lease or r.lease!=lease or r.lease_until<time.time() or r.status!="running" { raise ValueError("Run lease expired or cancelled."); }
    return r;
}
def:pub agent_model_log(token: str, id: str, owner: str, lease: str, record: dict[str, any]) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();
        try { r=_agent_leased(id,owner,lease); } except ValueError as e { return {"error":str(e)}; }
        step=_steps(r)[r.index];
        if (step not in PAID and step!="interview") or record.get("status") not in ["started","received","accepted","rejected","error","completed"] { return {"error":"Invalid model log."}; }
        attempt=str(record.get("attempt_id",""));
        if not attempt or len(attempt)>64 { return {"error":"Invalid model attempt."}; }
        # Only response diagnostics belong here: never worker tokens or request input.
        data={k:record[k] for k in ["provider","model","status","raw_response","response_format","error"] if k in record};
        previous=[n for n in [root -->][?:AgentModelLog] if n.run_id==id and n.attempt_id==attempt];
        if previous {
            n=previous[0];
            if n.step!=step { return {"error":"Model attempt belongs to another step."}; }
            n.data=data;n.updated_at=time.time();
        } else {
            root ++> AgentModelLog(run_id=id,attempt_id=attempt,step=step,created_at=time.time(),updated_at=time.time(),data=data);
        }
        commit();return {"saved":True};
    }
}
def _model_log_view(n: AgentModelLog) -> dict[str, any] {
    return {"run_id":n.run_id,"attempt_id":n.attempt_id,"step":n.step,"created_at":n.created_at,"updated_at":n.updated_at,**n.data};
}
def:priv agent_model_logs(id: str) -> dict[str, any] {
    _agent_access();
    if _owned_run(id) is None { return {"error":"Task not found."}; }
    return {"attempts":[_model_log_view(n) for n in [root --> [?:AgentModelLog, created_at]] if n.run_id==id]};
}
def:pub agent_authorize(token: str, id: str, owner: str, lease: str, payload_hash: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();
        try {
            r=_agent_leased(id,owner,lease);step=_steps(r)[r.index];m=_agent_memory();
            if step not in EXTERNAL { return {"error":"This step has no external action."}; }
            if step in REVIEWED and (not r.approvals.get(step) or r.approvals.get(step)!=payload_hash) { raise ValueError("This action does not match what you approved. Review it again."); }
            action=EXTERNAL[step];destination=r.context.get("contact",{}).get("email","") if step=="send" else "";
            authorize(m.policy,action,destination);
            if step in ["send","calendar"] and not [c for c in [root -->][?:AgentConnection] if c.provider=="google" and c.state=="connected"] { raise ValueError("Google authorization was revoked or is unavailable."); }
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
        step=_steps(r)[r.index];
        if step=="story" and not result.get("error") and not result.get("needs_input") and not result.get("blocked") {
            stories=[s for s in [root -->][?:BehavioralStory] if jid(s)==r.target_id];
            if not stories or stories[0].revision!=r.context.get("story_revision") {
                result={"blocked":True,"message":"The story changed or was deleted. Your corrections are preserved; generate a new draft if needed."};
            } else {
                try { result={**result,"artifact":validate_story(result.get("artifact",{}),stories[0].source)}; }
                except ValueError as e { result={"blocked":True,"message":str(e)}; }
            }
        }
        traced_result=result if capture_enabled() else {"error":result.get("error",""),"message":result.get("message","")};
        diagnostic=sanitize_browser_diagnostic(result.get("browser_diagnostic"));
        if result.get("error") and "browser_diagnostic" in result {
            # Retain operational evidence even with content capture disabled.
            # Never retain raw exception text or extra adapter fields here.
            traced_result={"error":BROWSER_ERROR_MESSAGE};
            if diagnostic and diagnostic["operation"]==step { traced_result["browser_diagnostic"]=diagnostic; }
        }
        _trace(r,"stage_end",{"outcome":"error" if result.get("error") else "needs_input" if result.get("needs_input") else "result_received","duration_ms":max(0,int((time.time()-r.stage_started_at)*1000)) if r.stage_started_at else 0,"result":traced_result});
        r.lease="";r.lease_until=0;r.updated_at=time.time();
        intents=[a for a in [root -->][?:AgentAction] if a.run_id==id and a.step==step and a.status=="intent"];
        if result.get("interrupted") {
            r.status="uncertain" if intents else "cancelled" if result.get("control",{}).get("mode") in ["stopping","stopped"] else "paused";
            r.message="Browser activity paused." if r.status=="paused" else "Browser task stopped.";
        } elif result.get("error") {
            r.status="uncertain" if intents else "queued";r.message=str(result["error"])[:1000];r.next_at=time.time()+min(300.0,15.0*(2**r.attempts));
        } elif result.get("blocked") {
            r.status="uncertain" if intents else "blocked";r.requests=[];r.message=str(result.get("message","This step could not complete. Retry when ready."))[:1000];
        } elif result.get("needs_input") {
            r.status="needs_input";r.requests=result.get("requests",[]);r.message=str(result.get("message","Your input is needed."))[:1000];
            # A dispatched action still needs reconciliation.
            if intents { r.status="uncertain";r.message="An action was dispatched; reconcile it before resuming."; }
        } else {
            artifact=result.get("artifact",{});
            if step in ["send","calendar"] and not artifact.get("receipt") {
                r.status="uncertain";r.message="No confirmation receipt was returned.";
            } else {
                if step=="approve_resume" {
                    # The approved, rebuilt resume replaces the proposal wherever the tailored PDF is used.
                    r.artifacts["tailor"]={**r.artifacts.get("tailor",{}),**artifact.get("tailor",{})};
                    artifact={k:v for (k,v) in artifact.items() if k!="tailor"};
                }
                if step in interview.STEPS {
                    sessions=[p for p in [root -->][?:PrepSession] if jid(p)==r.target_id and p.data.get("mode")=="interview"];
                    try {
                        if not sessions { raise ValueError("Interview session not found."); }
                        p=sessions[0];p.data=interview.apply(p.data,p.revision,step,artifact,r.context);p.updated_at=time.time();
                    } except ValueError as exc { r.status="needs_input";r.message=str(exc);commit();return _run_view(r,True); }
                }
                if step=="coach" {
                    sessions=[p for p in [root -->][?:PrepSession] if jid(p)==r.target_id];
                    if not sessions or sessions[0].revision!=r.context.get("session_revision",0) { r.status="needs_input";r.message="Practice changed while coaching was running. Request coaching again for your saved answer.";commit();return _run_view(r,True); }
                }
                r.artifacts[step]=artifact;
                for a in intents { a.status="confirmed";a.receipt=artifact; }
                r.index+=1;r.attempts=0;r.status="completed" if r.index>=len(_steps(r)) else "queued";r.message="Completed" if r.status=="completed" else "Ready for next step";
                if step=="coach" {
                    for p in [root -->][?:PrepSession] { if jid(p)==r.target_id { p.feedback=p.feedback+[{"at":time.time(),"revision":r.context.get("session_revision",0),"run_id":jid(r),"output_version":digest(r.artifacts),"data":artifact}]; } }
                }
                if step=="story" {
                    s=stories[0];s.history=s.history+[{"revision":s.revision,"content":s.content,"at":time.time(),"kind":"generation","run_id":jid(r)}];
                    s.content=artifact;s.revision+=1;s.updated_at=time.time();
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
        step=_steps(r)[r.index];
        for a in [root -->][?:AgentAction] {
            if a.run_id==id and a.step==step and a.status=="intent" {
                a.status=outcome;a.receipt={"user_confirmed":True,"evidence":evidence};
                if outcome=="not_sent" { a.key=a.key+":"+jid(a); }
            }
        }
        if outcome=="confirmed" { r.artifacts[step]={"receipt":evidence,"user_confirmed":True};r.index+=1; }
        r.status="completed" if r.index>=len(_steps(r)) else "queued";r.message="Reconciled by you";r.attempts=0;
        _pause_legacy(r);
        for t in [root.shared -->][?:AgentTicket] { if t.run_id==id { t.state=r.status;t.due_at=0; } }
        commit();return _run_view(r,True);
    }
}
"""Why a Google step cannot be dispatched right now, or "" when it can."""
def _google_missing(step: str) -> str {
    if step not in ["send","calendar"] { return ""; }
    scope=str(SCOPES["send" if step=="send" else "calendar"]);
    if [c for c in [root -->][?:AgentConnection] if c.provider=="google" and c.state=="connected" and scope in c.scopes] { return ""; }
    if step=="send" { return "Gmail sending is not connected. Connect it in Agents → Rules to send from Stack, or copy this draft into your own email and cancel the task."; }
    return "Google Calendar is not connected. Connect it in Agents → Rules, or add the event yourself and cancel the task.";
}
def:priv agent_approve(id: str, step: str, review_hash: str, edits: dict[str, any] | None = None) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None or r.status!="review" { return {"error":"This task is not waiting for your review."}; }
        if r.kind=="application" { return {"error":"The application assistant has been retired."}; }
        # The approval covers exactly the version the user saw; a newer version needs a new look.
        if r.review.get("step")!=step or r.review.get("hash")!=review_hash or _steps(r)[r.index]!=step { return {"error":"This review changed. Look it over again before approving."}; }
        # Approving something Stack cannot deliver would only fail later; keep the review and say why.
        missing=_google_missing(step);
        if missing { return {"error":missing}; }
        # Omitted optional arguments can arrive as the text "None"; only a non-empty object is an edit.
        if isinstance(edits,dict) and len(edits)>0 and step=="approve_resume" {
            ids=[c["id"] for c in r.artifacts.get("tailor",{}).get("changes",[])];
            rejected=edits.get("rejected",[]);
            if not isinstance(rejected,list) or any(str(x) not in ids for x in rejected) { return {"error":"Choose changes from this review."}; }
            r.artifacts["tailor"]={**r.artifacts.get("tailor",{}),"rejected":sorted({str(x) for x in rejected})};
        } elif isinstance(edits,dict) and len(edits)>0 {
            if step!="send" { return {"error":"Only email subject and body can be edited here."}; }
            subject=str(edits.get("subject","")).strip();body=str(edits.get("body","")).strip();
            if not subject or not body or len(subject)>200 or len(body)>10000 or "\n" in subject or "\r" in subject { return {"error":"Enter a one-line subject under 200 characters and a message under 10,000 characters."}; }
            r.artifacts["draft"]={**r.artifacts.get("draft",{}),"subject":subject,"body":body,"edited_by_user":True};
        }
        r.approvals[step]=digest(review_payload(step,r.context,r.artifacts));
        r.review={};r.status="queued";r.message="Approved by you. Continuing.";r.attempts=0;r.next_at=0.0;r.updated_at=time.time();
        for t in [root.shared -->][?:AgentTicket] { if t.run_id==id { t.state="queued";t.due_at=0; } }
        commit();return _run_view(r,True);
    }
}
def:priv agent_retry(id: str) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None { return {"error":"Run not found."}; }
        if r.kind=="application" { return {"error":"The application assistant has been retired."}; }
        # Uncertain runs must be reconciled; completed or cancelled work is never replayed.
        if r.status not in ["failed","blocked"] or r.kind=="live" { return {"error":"Only a failed or paused task can be retried."}; }
        if [a for a in [root -->][?:AgentAction] if a.run_id==id and a.status=="intent"] { return {"error":"An action may have been dispatched. Reconcile it first."}; }
        _continue_legacy(r);
        if r.status=="completed" { commit();return _run_view(r,True); }
        r.status="queued";r.message="Retry requested";r.attempts=0;r.next_at=0.0;r.dismissed=False;r.lease="";r.updated_at=time.time();
        for t in [root.shared -->][?:AgentTicket] { if t.run_id==id { t.state="queued";t.due_at=0; } }
        commit();return _run_view(r,True);
    }
}
def:priv agent_dismiss(id: str) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None { return {"error":"Run not found."}; }
        if r.status not in TERMINAL { return {"error":"Cancel or finish this task before dismissing it."}; }
        r.dismissed=True;commit();return _run_view(r,True);
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
        # Saving or selecting a contact never contacts them; outreach starts only from an explicit request.
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
def:priv prep_sessions() -> dict[str, any] {
    _agent_access();
    sessions=[p for p in [root --> [?:PrepSession, -updated_at]] if p.data.get("mode")!="interview"];
    return {"sessions":[{"id":jid(p),"data":p.data,"revision":p.revision,"updated_at":p.updated_at} for p in sessions[:50]]};
}
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
                if p.data.get("mode")=="interview" { return {"error":"Use interview controls to preserve the conversation."}; }
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
            r=_agent_leased(id,owner,lease);step=_steps(r)[r.index];
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
    _agent_access();return {"settings":agent_settings(),"model_logs":[_model_log_view(n) for n in [root -->][?:AgentModelLog]],"runs":[{**_run_view(r,True),"trace":agent_traces(jid(r))["events"]} for r in [root -->][?:AgentRun]],"feedback":[{"run_id":f.run_id,"output_version":f.output_version,"rating":f.rating,"note":f.note,"at":f.at,"snapshot":f.snapshot} for f in [root -->][?:AgentFeedback]],"contacts":agent_contacts(),"sessions":[prep_get(jid(p)) for p in [root -->][?:PrepSession]],"events":[e.data for e in [root -->][?:AgentEvent]]};
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
def _notification_refresh(n: AgentNotification, now: float) -> None {
    if n.state=="cancelled" { return; }
    if not n.initialized {
        if n.state=="queued" {
            n.deliveries=[push.new_delivery(device_node.key) for device_node in [root -->][?:AgentPushDevice]];
        } elif n.state=="sent" and n.receipt {
            # Legacy send tickets had no durable device mapping. Poll them, but
            # never use their position to retire a current registered device.
            n.deliveries=[];
            for ticket in n.receipt.split(",") {
                d=push.new_delivery("legacy:"+str(len(n.deliveries)));
                d.update(state="accepted",ticket=ticket,accepted_at=now,due_at=now);
                n.deliveries.append(d);
            }
        } else {
            if n.state=="dispatched" or n.state=="sent" { n.state="uncertain"; }
            n.initialized=True;return;
        }
        n.initialized=True;
    }
    if n.deliveries {
        n.deliveries=push.recover(n.deliveries,now);n.state=push.status(n.deliveries);
    } elif n.state=="queued" { n.state="no_devices"; }
}

def _notification_owned(id: str) -> AgentNotification | None {
    for n in [root -->][?:AgentNotification] { if jid(n)==id { return n; } }
    return None;
}

def _notification_view(n: AgentNotification) -> dict[str, any] {
    return {"id":jid(n),"run_id":n.run_id,"state":n.state,
        "devices":[{k:d[k] for k in ["state","attempts","receipt_attempts","ticket","error"]} for d in n.deliveries]};
}

def:priv agent_notification_status(id: str = "") -> dict[str, any] {
    _agent_access();
    if not id { return {"notifications":[_notification_view(n) for n in [root -->][?:AgentNotification]]}; }
    n=_notification_owned(id);
    if n is None { return {"error":"Notification not found."}; }
    return _notification_view(n);
}

def:pub agent_notification_claim(token: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();owners=[a.owner for a in [root.shared -->][?:AgentAdmission]];now=time.time();
        for owner in owners {
            _agent_owner(owner);
            for n in [root -->][?:AgentNotification] {
                _notification_refresh(n,now);
                if n.state=="cancelled" { continue; }
                for index in range(len(n.deliveries)) {
                    d=dict(n.deliveries[index]);
                    if d["state"] not in ["queued","accepted"] or d["lease"] or d["due_at"]>now { continue; }
                    phase="receipt" if d["state"]=="accepted" else "send";device="";
                    if phase=="send" {
                        devices=[v for v in [root -->][?:AgentPushDevice] if v.key==d["key"]];
                        if not devices { d.update(state="failed",error="DeviceRemoved");n.deliveries[index]=d;continue; }
                        try { device=unseal(devices[0].sealed)["token"]; }
                        except ValueError { d.update(state="failed",error="DeviceLocked");n.deliveries[index]=d;continue; }
                        d["state"]="claimed";
                    } else { d["receipt_attempts"]+=1; }
                    d.update(lease=secrets.token_urlsafe(24),lease_until=now+push.LEASE_SECONDS);
                    n.deliveries[index]=d;n.state=push.status(n.deliveries);commit();
                    return {"owner":owner,"id":jid(n),"run_id":n.run_id,"key":d["key"],
                        "lease":d["lease"],"phase":phase,"device":device,"ticket":d["ticket"]};
                }
                if n.deliveries { n.state=push.status(n.deliveries); }
            }
            commit();
        }
        return {"idle":True};
    }
}

def:pub agent_notification_begin(token: str, owner: str, id: str, key: str, lease: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();_agent_owner(owner);n=_notification_owned(id);now=time.time();
        if n is None or n.state=="cancelled" { return {"error":"Notification not found."}; }
        for index in range(len(n.deliveries)) {
            d=dict(n.deliveries[index]);
            if d["key"]==key and lease and d["lease"]==lease and d["lease_until"]>now and d["state"]=="claimed" {
                if not [v for v in [root -->][?:AgentPushDevice] if v.key==key] {
                    d.update(state="failed",error="DeviceRemoved",lease="",lease_until=0.0);
                    n.deliveries[index]=d;n.state=push.status(n.deliveries);commit();
                    return {"error":"Notification device was removed."};
                }
                # Commit the uncertainty boundary before contacting Expo.
                d.update(state="dispatching",attempts=d["attempts"]+1);n.deliveries[index]=d;commit();
                return {"started":True};
            }
        }
        return {"error":"Notification lease is no longer active."};
    }
}

def:pub agent_notification_finish(token: str, owner: str, id: str, key: str, lease: str, result: dict[str, any]) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _catalog_lock {
        _agent_fresh();_agent_owner(owner);n=_notification_owned(id);now=time.time();
        if n is None or n.state=="cancelled" { return {"error":"Notification not found."}; }
        if set(result)-{"state","error","ticket"} { return {"error":"Invalid notification result."}; }
        for index in range(len(n.deliveries)) {
            d=n.deliveries[index];
            if d["key"]!=key { continue; }
            if lease and d["last_lease"]==lease and d["last_result"]==result { return {"saved":True}; }
            if not lease or d["lease"]!=lease or d["lease_until"]<=now or d["state"] not in ["dispatching","accepted"] {
                return {"error":"Notification lease is no longer active."};
            }
            try { updated=push.complete(d,result,now); }
            except ValueError as e { return {"error":str(e)}; }
            n.deliveries[index]=updated;n.state=push.status(n.deliveries);
            if updated["error"]=="DeviceNotRegistered" {
                for device in [root -->][?:AgentPushDevice] { if device.key==key { del device; } }
            }
            commit();return {"saved":True};
        }
        return {"error":"Notification device not found."};
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
        p=sessions[0];
        if p.data.get("mode")=="interview" { return {"error":"This interview uses recorded answers and agent coaching. Live voice is not enabled."}; }
        context={"session":p.data,"problem":problem(str(p.data["problem_id"])),"results":p.results[-3:]};
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
            ticket=secrets.token_urlsafe(32);r=root ++> AgentRun(workflow_version=2,kind="live",target_id=id,context=context,model_selection=m.model_selection,created_at=time.time(),updated_at=time.time(),key=digest(ticket),ticket_hash=digest(ticket),status="waiting",message="Ready to start live interview",lease_until=time.time()+60,cost_cents=reservation);
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

def:pub agent_upgrade_workflows(token: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    owners=[a.owner for a in [root.shared -->][?:AgentAdmission]];changed=0;
    for owner in owners { _agent_owner(owner);changed+=_upgrade_legacy_runs(); }
    return {"paused":changed};
}
