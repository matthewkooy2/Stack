"""Stack API. All personal data endpoints require Jac authentication."""
import time;
import from threading { RLock }
import from jaclang.runtime.runtime { JacRuntime }
import from core.catalog { _catalog_lock, _catalog_job, _saved_search, _retained_snapshot, _drop_overrides, search_jobs, get_job, save_search, reset_search, import_job_url, get_import_status, source_status, discovery_claim, discovery_complete, discovery_manage, discovery_report, discovery_analyze }
import from core.preferences { MatchPreferences, _match_preferences, _save_match_preferences }
import from core.timeline { _timeline_preferences, _save_timeline }
import from discovery.timeline { validate_month }
import from discovery.matching { validate_preferences }
glob _write_lock = _catalog_lock;
import base64;
import hashlib;
import from uuid { uuid4 }
import from pathlib { Path }
import from io { BytesIO }
import importlib;
import from core.fixtures { JOBS, PEOPLE }
import from core.agents { _demo_status }
import from core.automation {
    AgentMemory, AgentNotification, AgentPushDevice, AgentTicket, AgentRun, AgentContact, AgentConnection, AgentEvent, AgentAdmission, AgentInterview, PrepSession,
    _agent_access, _agent_memory, _agent_summary, _agent_start, _agent_fresh, _agent_system, _agent_owner, _owned_run,
    agent_settings, agent_report, agent_admission, agent_register_push, agent_remove_push, agent_notification_claim, agent_notification_finish, agent_save_facts, agent_save_policy, agent_activity, agent_run, agent_cancel, agent_respond, agent_reconcile,
    agent_contacts, agent_save_contact, agent_stop_contact, agent_import_contacts, agent_events, agent_claim, agent_authorize, _agent_complete, agent_worker_connection,
    agent_trace, agent_traces, agent_feedback,
    agent_invite, agent_accept_invite, agent_google_start, agent_google_finish, agent_disconnect, agent_export,
    prep_progress, prep_live, agent_live_claim, agent_live_check, agent_live_finish, prep_catalog, prep_sessions, prep_create, prep_get, prep_save
}
import from agents.contracts { authorize, config, digest, validate_facts }
import from agents.resume_parser { parse_pdf, sections as resume_sections, validate_values, confirmed_facts }
import from agents.prep { problem, validate_session }
import from agents.study { plan as study_plan }

node Profile {
    has name: str = "", role: str = "", location: str = "United States", mode: str = "Any", onboarded: bool = False, notifications: bool = True;
}
node Decision { has job_id: str, action: str; }
node Application { has job_id: str, created_at: float, status: str = "", notes: str = "", resume_id: str = "", demo: bool = True, snapshot: dict[str, any] = {}, status_at: float = 0.0, history: list[dict[str, any]] = []; }
node Contact { has person_id: str, saved: bool = False, draft: str = "", notes: str = ""; }
node Resume { has name: str, file_key: str, size: int, created_at: float, review: dict[str, any] = {}, review_revision: int = 0, review_confirmed: bool = False; }
node Reminder { has target_type: str, target_id: str, title: str, due_at: float, done: bool = False; }
node Settings { has selected_resume: str = ""; }

def:pub health() -> dict[str, str] { return {"status":"ok","app":"Stack"}; }

def _error(message: str) -> dict[str, any] { return {"error": message}; }
def _refresh_transaction() -> None {
    # A request can begin its snapshot before it acquires the process lock.
    # Discard that untouched snapshot before making an idempotency decision.
    ctx = JacRuntime.get_context();
    owner = str(ctx.user_root.id);
    ctx.mem.abort();
    ctx.set_user_root(owner);
}
def _profile() -> Profile {
    _agent_access();
    with _write_lock {
        items = [root -->][?:Profile];
        if items and [root -->][?:MatchPreferences] { return items[0]; }
        _refresh_transaction();
        items = [root -->][?:Profile];
        if items {
            # Accounts created before matching preferences existed start from their profile.
            if not [root -->][?:MatchPreferences] {
                p=items[0];root ++> MatchPreferences(roles=p.role,location=p.location,modes=[] if p.mode=="Any" else [p.mode]);commit();
            }
            return items[0];
        }
        p = root ++> Profile();
        root ++> MatchPreferences();
        root ++> Settings();
        for person in PEOPLE { root ++> Contact(person_id=person["id"], draft=person["draft"]); }
        commit();
        return p;
    }
}
def _settings() -> Settings { _profile(); return [root -->][?:Settings][0]; }
def _owned_resume(id: str) -> Resume | None {
    for r in [root -->][?:Resume] { if jid(r) == id { return r; } }
    return None;
}
def _file_path(key: str) -> Path {
    directory = Path("storage/resumes") / hashlib.sha256(jid(root).encode()).hexdigest();
    directory.mkdir(parents=True, exist_ok=True, mode=448);
    return directory / key;
}
def _app_view(a: Application) -> dict[str, any] {
    return {"id":jid(a), "job_id":a.job_id, "created_at":a.created_at, "status":a.status or _demo_status(a.created_at,time.time()), "notes":a.notes, "resume_id":a.resume_id, "demo":a.demo,"job":_application_job(a),"history":a.history};
}
def _application_job(a: Application) -> dict[str, any] {
    if a.demo {
        for j in JOBS { if j["id"]==a.job_id { return dict(j, demo=True); } }
    }
    live=_catalog_job(a.job_id);
    return live if live else _retained_snapshot(a.snapshot);
}
def:priv bootstrap() -> dict[str, any] {
    p = _profile();
    return {
      "user_id":jid(root),
      "profile":{"name":p.name,"role":p.role,"location":p.location,"mode":p.mode,"onboarded":p.onboarded,"notifications":p.notifications,**_timeline_preferences(),"preferences":_match_preferences()},
      "jobs":[_application_job(a) for a in [root -->][?:Application]],
      "saved_search":_saved_search(),
      "decisions":[{"job_id":d.job_id,"action":d.action} for d in [root -->][?:Decision]],
      "applications":[_app_view(a) for a in [root -->][?:Application]],
      "people":PEOPLE,
      "contacts":[{"id":jid(c),"person_id":c.person_id,"saved":c.saved,"draft":c.draft,"notes":c.notes} for c in [root -->][?:Contact]],
      "resumes":[{"id":jid(r),"name":r.name,"size":r.size,"created_at":r.created_at,"details_status":"Confirmed" if r.review_confirmed else "Needs review" if r.review else "Not parsed"} for r in [root -->][?:Resume]],
      "selected_resume":_settings().selected_resume,
      "agents":_agent_summary(),
      "reminders":[{"id":jid(r),"target_type":r.target_type,"target_id":r.target_id,"title":r.title,"due_at":r.due_at,"done":r.done} for r in [root -->][?:Reminder]]
    };
}
def:priv save_profile(name: str, role: str, location: str, mode: str, notifications: bool, graduation_month: str | None = None, available_from: str | None = None, preferences: dict[str, any] | None = None) -> dict[str, any] {
    if not name.strip() or len(name)>100 or len(role)>160 or len(location)>160 or mode not in ["Any","Remote","Hybrid","On-site"] { return _error("Enter a name and valid preferences."); }
    timeline=_timeline_preferences();
    graduation=timeline["graduation_month"] if graduation_month in [None,"None"] else str(graduation_month);
    availability=timeline["available_from"] if available_from in [None,"None"] else str(available_from);
    # Older clients send only the single work-arrangement chip.
    current=_match_preferences();
    chosen={k:current[k] for k in ["stage","years","education","modes","employment_types","salary_min","salary_period","exclude_companies","exclude_terms","soft"]};
    if preferences is None or preferences in ["None","{}"] { chosen["modes"]=[] if mode=="Any" else [mode]; }
    else { chosen={**chosen,**preferences}; }
    try { validate_month(graduation);validate_month(availability);validate_preferences(chosen); } except Exception as e { return _error(str(e)); }
    p = _profile();
    with _write_lock {
        _refresh_transaction(); p=[root -->][?:Profile][0];
        _save_timeline(graduation,availability);
        changed=_save_match_preferences(role,location,chosen);
        _drop_overrides(changed);
        modes=_match_preferences()["modes"];
        p.name=name.strip(); p.role=role.strip(); p.location=location.strip(); p.mode=modes[0] if len(modes)==1 else "Any"; p.notifications=notifications; p.onboarded=True;
        commit();
    }
    return bootstrap();
}
def:priv save_timeline(graduation_month: str, available_from: str = "") -> dict[str, any] {
    try { validate_month(graduation_month);validate_month(available_from); } except Exception as e { return _error(str(e)); }
    with _write_lock { _refresh_transaction(); _save_timeline(graduation_month,available_from); commit(); }
    return bootstrap();
}
def:priv swipe(job_id: str, action: str, start_agent: bool = False) -> dict[str, any] {
    with _write_lock {
        _refresh_transaction();
        _profile();
        job=_catalog_job(job_id); demo=job_id in [j["id"] for j in JOBS];
        if action not in ["pass","apply"] or (not job and not demo) { return _error("Invalid job or action."); }
        if not demo and (not job.get("active") or job.get("stale")) { return _error("This listing is no longer verified active. Refresh your search."); }
        for d in [root -->][?:Decision] { if d.job_id == job_id { return bootstrap(); } }
        root ++> Decision(job_id=job_id, action=action);
        if action == "apply" {
            a=root ++> Application(job_id=job_id,created_at=time.time(),resume_id=_settings().selected_resume,demo=demo,status="" if demo else "Ready to apply",snapshot=job);
            if start_agent and not demo and _agent_memory().policy.get("enabled") { _agent_start("application",jid(a),_application_agent_context(a)); }
        }
        commit();
        return bootstrap();
    }
}
def:priv save_application(id: str, notes: str) -> dict[str, any] {
    if len(notes)>5000 { return _error("Notes must be under 5,000 characters."); }
    for a in [root -->][?:Application] { if jid(a)==id { a.notes=notes; return bootstrap(); } }
    return _error("Application not found.");
}
def:priv mark_application_submitted(id: str) -> dict[str, any] {
    for a in [root -->][?:Application] {
        if jid(a)==id and not a.demo { a.status="Submitted";a.status_at=time.time();a.history=a.history+[{"status":"Submitted","at":a.status_at,"source":"User confirmed"}]; return bootstrap(); }
    }
    return _error("Real application not found.");
}
def:priv select_application_resume(id: str, resume_id: str) -> dict[str, any] {
    if resume_id and _owned_resume(resume_id) is None { return _error("Resume not found."); }
    for a in [root -->][?:Application] {
        if jid(a)==id {
            a.resume_id=resume_id;
            return bootstrap();
        }
    }
    return _error("Application not found.");
}
def:priv save_contact(id: str, saved: bool, draft: str, notes: str) -> dict[str, any] {
    if len(draft)>5000 or len(notes)>5000 { return _error("Keep notes and drafts under 5,000 characters."); }
    for c in [root -->][?:Contact] { if jid(c)==id { c.saved=saved; c.draft=draft; c.notes=notes; return bootstrap(); } }
    return _error("Contact not found.");
}
def:priv upload_resume(name: str, content: str) -> dict[str, any] {
    _profile();
    if len(content)>13981016 { return _error("PDF must be 10 MB or smaller."); }
    try { raw = base64.b64decode(content,validate=True); } except Exception { return _error("Invalid PDF encoding."); }
    if len(raw)>10485760 or not raw.startswith(b"%PDF-") { return _error("Choose a valid PDF, 10 MB or smaller."); }
    try {
        pdf = importlib.import_module("pypdf").PdfReader(BytesIO(raw));
        if pdf.is_encrypted or len(pdf.pages)==0 { return _error("Choose an unencrypted PDF with at least one page."); }
    } except Exception { return _error("This PDF could not be opened. Please export a new copy."); }
    if not name.strip() or len(name)>160 { return _error("Use a filename under 160 characters."); }
    key = str(uuid4()) + ".pdf";
    path = _file_path(key); path.write_bytes(raw); path.chmod(384);
    r = root ++> Resume(name=Path(name).name, file_key=key, size=len(raw), created_at=time.time());
    s = _settings(); if not s.selected_resume { s.selected_resume=jid(r); }
    return bootstrap();
}
def:priv read_resume(id: str) -> dict[str, any] {
    r = _owned_resume(id); if r is None { return _error("Resume not found."); }
    path = _file_path(r.file_key);
    if not path.exists() { return _error("This file is unavailable. Please upload it again."); }
    return {"name":r.name,"content":base64.b64encode(path.read_bytes()).decode(),"review":_resume_review(r) if r.review else {}};
}
def:priv change_resume(id: str, action: str, name: str = "") -> dict[str, any] {
    r = _owned_resume(id); if r is None { return _error("Resume not found."); }
    if action=="select" { _settings().selected_resume=id; }
    elif action=="rename" {
        if not name.strip() or len(name)>160 { return _error("Enter a name under 160 characters."); }
        r.name=name.strip();
    } elif action=="delete" {
        _file_path(r.file_key).unlink(missing_ok=True);
        if _settings().selected_resume==id { _settings().selected_resume=""; }
        for a in [root -->][?:Application] { if a.resume_id==id { a.resume_id=""; } }
        del r;
    } else { return _error("Invalid resume action."); }
    return bootstrap();
}
def:priv save_reminder(id: str, target_type: str, target_id: str, title: str, due_at: float) -> dict[str, any] {
    if not title.strip() or len(title)>160 or due_at<=time.time() { return _error("Choose a title and a future date."); }
    valid = False;
    if target_type=="application" { valid=target_id in [jid(a) for a in [root -->][?:Application]]; }
    elif target_type=="contact" { valid=target_id in [jid(c) for c in [root -->][?:Contact]]; }
    if not valid { return _error("Reminder target not found."); }
    if id {
        for r in [root -->][?:Reminder] {
            if jid(r)==id { r.title=title.strip(); r.due_at=due_at; r.done=False; return bootstrap(); }
        }
        return _error("Reminder not found.");
    }
    root ++> Reminder(target_type=target_type,target_id=target_id,title=title.strip(),due_at=due_at);
    return bootstrap();
}
def:priv change_reminder(id: str, action: str) -> dict[str, any] {
    for r in [root -->][?:Reminder] {
        if jid(r)==id {
            if action=="complete" { r.done=True; }
            elif action=="delete" { del r; }
            else { return _error("Invalid reminder action."); }
            return bootstrap();
        }
    }
    return _error("Reminder not found.");
}


def _application_agent_context(a: Application) -> dict[str, any] {
    job=_application_job(a);p=_profile();
    context={"application_id":jid(a),"job":job,"profile":{"name":p.name,"role":p.role,"location":p.location,"preferences":_match_preferences()},"resume_id":a.resume_id};
    resume=_owned_resume(a.resume_id);
    if resume is not None {
        try {
            reader=importlib.import_module("pypdf").PdfReader(_file_path(resume.file_key));
            context["resume_text"]="\n".join([page.extract_text() or "" for page in reader.pages])[:200000];
        } except Exception { context["resume_text"]=""; }
    }
    return context;
}
def:priv agent_start(kind: str, target_id: str) -> dict[str, any] {
    _agent_access();
    with _write_lock {
        _agent_fresh();
        if kind in ["application","jobs","resume"] {
            for a in [root -->][?:Application] {
                if jid(a)==target_id and not a.demo {
                    job=_application_job(a);
                    if kind=="application" and (a.status!="Ready to apply" or not job.get("active") or job.get("stale")) { return {"error":"Only an active, unsubmitted application can be started."}; }
                    return _agent_start(kind,target_id,_application_agent_context(a));
                }
            }
        } elif kind=="profile" {
            p=_profile();return _agent_start("profile","self",{"profile":{"name":p.name,"role":p.role,"location":p.location}});
        } elif kind=="network" {
            for c in [root -->][?:AgentContact] {
                if jid(c)==target_id and c.data.get("selected") and not c.data.get("stopped") { return _agent_start(kind,target_id,{"contact":c.data,"profile":{"name":_profile().name},"thread_id":c.thread_id}); }
            }
        } elif kind in ["prep","code"] {
            for p in [root -->][?:PrepSession] {
                if jid(p)==target_id {
                    context={"session":p.data,"session_revision":p.revision,"problem":problem(str(p.data["problem_id"])),"test_results":[r for r in p.results if r["revision"]==p.revision]};
                    for a in [root -->][?:Application] { if jid(a)==p.data.get("application_id") { context["job"]=_application_job(a); } }
                    return _agent_start(kind,target_id,context,str(p.revision));
                }
            }
        }
    }
    return {"error":"This agent target was not found or is unavailable."};
}
def:priv agent_extract_resume(id: str) -> dict[str, any] {
    _agent_access();r=_owned_resume(id);
    if r is None { return {"error":"Resume not found."}; }
    if r.review { return _resume_review(r); }
    try {
        parsed=parse_pdf(_file_path(r.file_key));
    } except ValueError as e { return _error(str(e)); }
    with _write_lock {
        _agent_fresh();r=_owned_resume(id);
        if r is None { return _error("Resume not found."); }
        if not r.review { r.review=parsed;r.review_revision+=1;commit(); }
        return _resume_review(r);
    }
}
def _resume_review(r: Resume) -> dict[str, any] {
    return {"id":jid(r),"name":r.name,"revision":r.review_revision,"confirmed":r.review_confirmed,"sections":resume_sections(r.review.get("values",{})),"text":r.review.get("text",""),"parser":r.review.get("parser",""),"warnings":["OpenResume works best with single-column English resumes. Missing or misclassified details need review."]};
}
def:priv resume_save_details(id: str, revision: int, values: dict[str, any], confirm: bool = False) -> dict[str, any] {
    _agent_access();confirm=confirm is True;
    try {
        clean=validate_values(values);
        if confirm and not any(v for v in clean.values()) { return _error("Enter at least one resume detail before confirming."); }
    } except ValueError as e { return _error(str(e)); }
    with _write_lock {
        _agent_fresh();r=_owned_resume(id);
        if r is None { return _error("Resume not found."); }
        if revision!=r.review_revision or not r.review { return _error("Resume details changed. Close and reopen the review before saving."); }
        try { facts=validate_facts([{**f,"verified":confirm} for f in confirmed_facts(id,r.name,clean)]); }
        except ValueError as e { return _error(str(e)); }
        memory=_agent_memory();memory.facts=[f for f in memory.facts if f.get("resume_id")!=id]+facts;memory.revision+=1;
        r.review={**r.review,"values":clean};r.review_confirmed=confirm;r.review_revision+=1;commit();
        return _resume_review(r);
    }
}
def:priv agent_browser(id: str, event: dict[str, any]) -> dict[str, any] {
    _agent_access();r=_owned_run(id);
    if r is None or r.kind!="application" or r.status not in ["needs_input","blocked","uncertain"] { return {"error":"This application is not awaiting browser handoff."}; }
    try { return importlib.import_module("agents.worker").browser_call("handoff",{"owner":jid(root),"id":id,"event":event}); }
    except Exception { return {"error":"The browser worker is unavailable or this session expired."}; }
}
def:pub agent_finish(token: str, id: str, owner: str, lease: str, result: dict[str, any]) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _write_lock {
        output=_agent_complete(token,id,owner,lease,result);
        if output.get("error") { return output; }
        _agent_owner(owner);r=_owned_run(id);
        if r is None { return output; }
        _project_agent(r);_notify_agent(r);
        commit();return output;
    }
}
def _notify_agent(r: AgentRun) -> None {
    if r.status not in ["needs_input","failed","uncertain"] and not (r.kind=="calendar" and r.status=="completed") { return; }
    # Read the preference without profile initialization aborting the pending completion.
    profiles=[root -->][?:Profile];
    if profiles and not profiles[0].notifications { return; }
    key=digest([jid(r),r.status,r.index]);
    if not [n for n in [root -->][?:AgentNotification] if n.key==key] { root ++> AgentNotification(key=key,run_id=jid(r)); }
}
def _create_study_plan(application_id: str) -> list[dict[str, any]] {
    applications=[a for a in [root -->][?:Application] if jid(a)==application_id and not a.demo];
    if not applications { return []; }
    feedback=[f["data"] for p in [root -->][?:PrepSession] for f in p.feedback[-1:]];
    recommendations=study_plan(_application_job(applications[0]),feedback);out=[];
    for item in recommendations {
        existing=[p for p in [root -->][?:PrepSession] if p.data.get("application_id")==application_id and p.data["problem_id"]==item["problem_id"]];
        if existing { session=existing[0]; }
        else {
            spec=problem(str(item["problem_id"]));data=validate_session({"problem_id":item["problem_id"],"language":item["language"],"code":spec.get("starter",{}).get(item["language"],"")});data["application_id"]=application_id;
            session=root ++> PrepSession(data=data,created_at=time.time(),updated_at=time.time());
        }
        out.append({**item,"session_id":jid(session)});
    }
    return out;
}
def:priv prep_for_application(application_id: str) -> dict[str, any] {
    _agent_access();
    with _write_lock { _agent_fresh();result=_create_study_plan(application_id);commit();return {"plan":result}; }
}
def _apply_confirmed_mail(event: dict[str, any]) -> None {
    if not event.get("ambiguous") {
        if event.get("calendar") {
            calendar_event=event["calendar"];existing=[i for i in [root -->][?:AgentInterview] if i.key==calendar_event["uid"]];
            if existing { interview=existing[0];if float(event["at"])>interview.updated_at { interview.event=calendar_event;interview.updated_at=float(event["at"]); } }
            else { interview=root ++> AgentInterview(key=str(calendar_event["uid"]),application_id=str(event["application_id"]),event=calendar_event,updated_at=float(event["at"])); }
            interview.study_plan=_create_study_plan(str(event["application_id"]));
            _agent_start("calendar",jid(interview),{"event":interview.event},str(interview.updated_at),False);
        }
        for a in [root -->][?:Application] {
            if jid(a)==event.get("application_id") and event["at"]>a.status_at and not a.demo {
                status=str(event["status"]);
                if status in ["Submitted","Assessment","Interview","Rejected"] and not (status=="Submitted" and a.status in ["Assessment","Interview","Rejected"]) and a.status!="Rejected" and not (a.status=="Interview" and status=="Assessment") {
                    a.status=status;a.status_at=float(event["at"]);a.history=a.history+[{"status":status,"at":a.status_at,"source":"Gmail","evidence":event["quote"]}];
                }
            }
        }
    }
}
def _project_agent(r: AgentRun) -> None {
    if r.projected or r.status!="completed" { return; }
    if r.status=="completed" and r.kind=="application" {
        for a in [root -->][?:Application] {
            if jid(a)==r.target_id and not a.demo and a.status=="Ready to apply" {
                a.status="Submitted";a.status_at=time.time();a.history=a.history+[{"status":"Submitted","at":a.status_at,"source":"Browser receipt","evidence":r.artifacts.get("submit",{})}];
            }
        }
    }
    if r.status=="completed" and r.kind=="network" {
        for c in [root -->][?:AgentContact] {
            if jid(c)==r.target_id {
                c.thread_id=str(r.artifacts.get("send",{}).get("thread_id",""));
                if r.context.get("followup") { c.followups+=1; }
                c.next_at=time.time()+int(_agent_memory().policy.get("followup_days",7))*86400 if c.thread_id else 0.0;
            }
        }
    }
    if r.status=="completed" and r.kind=="calendar" {
        for c in [root -->][?:AgentConnection] { if c.provider=="google" and r.artifacts["calendar"].get("calendar_id") { c.calendar_id=str(r.artifacts["calendar"]["calendar_id"]); } }
        for i in [root -->][?:AgentInterview] { if jid(i)==r.target_id { i.calendar_receipt=str(r.artifacts["calendar"]["receipt"]); } }
    }
    if r.status=="completed" and r.kind=="sync" {
        artifact=r.artifacts.get("sync",{});
        for c in [root -->][?:AgentConnection] { if c.provider=="google" { c.checkpoint=__import__("json").dumps(artifact.get("checkpoint",{})); } }
        for event in artifact.get("events",[]) {
            if [e for e in [root -->][?:AgentEvent] if e.key==event["key"]] { continue; }
            root ++> AgentEvent(key=str(event["key"]),data=event,created_at=time.time());
            for c in [root -->][?:AgentContact] { if c.data.get("email")==event.get("sender") { c.data["stopped"]=True;c.next_at=0; } }
            _apply_confirmed_mail(event);
        }
    }
    r.projected=True;
}
def:pub agent_schedule(token: str, wake_key: str = "") -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _write_lock {
        _agent_fresh();accounts=[a.owner for a in [root.shared -->][?:AgentAdmission]];count=0;
        for owner in accounts {
            commit();_agent_owner(owner);m=_agent_memory();
            if m.deleted { continue; }
            for r in [root -->][?:AgentRun] {
                if r.kind=="live" and r.status in ["waiting","running"] and r.lease_until<time.time() { r.status="failed";r.lease="";r.message="Live interview expired. Its reserved budget is retained."; }
                _project_agent(r);_notify_agent(r);
            }
            if not m.policy.get("enabled") or m.policy.get("expires_at",0)<time.time() { continue; }
            if m.policy.get("analyze_top_matches") and "model" in m.policy.get("actions",[]) {
                today=time.time()-86400;recent=[r for r in [root -->][?:AgentRun] if r.kind=="jobs" and r.created_at>today];
                if len(recent)<3 {
                    saved=_saved_search();matches=search_jobs(str(saved.get("query","")),saved.get("filters",{}));
                    for candidate in matches.get("jobs",[])[:max(0,3-len(recent))] {
                        job=_catalog_job(str(candidate["id"]));p=_profile();
                        if job is not None { _agent_start("jobs","job:"+str(candidate["id"]),{"job":job,"profile":{"name":p.name,"role":p.role,"preferences":_match_preferences()},"resume_id":_settings().selected_resume}); }
                    }
                }
            }
            connections=[c for c in [root -->][?:AgentConnection] if c.state=="connected"];
            if connections and "gmail_read" in m.policy.get("actions",[]) {
                context={"applications":[_app_view(a) for a in [root -->][?:Application] if not a.demo],"contacts":[c.data for c in [root -->][?:AgentContact]],"interviews":[{"key":i.key,"application_id":i.application_id} for i in [root -->][?:AgentInterview]]};
                _agent_start("sync","google",context,"push:"+wake_key if wake_key else str(int(time.time()/300)));count+=1;
            }
            for c in [root -->][?:AgentContact] {
                if c.next_at and c.next_at<=time.time() and c.data.get("selected") and not c.data.get("stopped") and c.followups<int(m.policy.get("followup_limit",0)) {
                    _agent_start("network",jid(c),{"contact":c.data,"thread_id":c.thread_id,"followup":True,"profile":{"name":_profile().name}},"followup-"+str(c.followups));
                }
            }
        }
        commit();return {"scheduled":count};
    }
}


def:priv account_export() -> dict[str, any] {
    _agent_access();return {"account":bootstrap(),"agents":agent_export(),"resumes":[read_resume(jid(r)) for r in [root -->][?:Resume]]};
}
def:priv account_delete(username: str, password: str) -> dict[str, any] {
    _agent_access();
    manager=__import__("jaclang.server.identity.user_manager",fromlist=["UserManager"]).UserManager();
    user=manager.authenticate(username,password);
    if not user or manager.get_root_id(user["user_id"])!=jid(root) { return {"error":"Confirm this account's username and password."}; }
    with _write_lock {
        _agent_fresh();owner=jid(root);m=_agent_memory();m.deleted=True;m.policy={"enabled":False};m.facts=[];m.admitted=False;
        for r in [root -->][?:AgentRun] { r.lease="";r.status="cancelled"; }
        for t in [root.shared -->][?:AgentTicket] { if t.owner==owner { del t; } }
        commit();
        for c in [root -->][?:AgentConnection] {
            if c.sealed {
                try { __import__("agents.google",fromlist=["revoke"]).revoke(__import__("agents.security",fromlist=["unseal"]).unseal(c.sealed)); } except Exception { cleanup_failed=True; }
            }
        }
        try { importlib.import_module("agents.worker").browser_call("purge",{"owner":owner}); } except Exception { cleanup_failed=True; }
        for r in [root -->][?:Resume] { _file_path(r.file_key).unlink(missing_ok=True); }
        for n in [root -->] { if jid(n)!=jid(m) { del n; } }
        commit();manager.delete_user(user["user_id"]);return {"deleted":True};
    }
}


def:priv agent_resolve_event(id: str, application_id: str, status: str) -> dict[str, any] {
    _agent_access();
    if status not in ["Submitted","Assessment","Interview","Rejected"] { return {"error":"Choose the status confirmed by this message."}; }
    with _write_lock {
        _agent_fresh();events=[e for e in [root -->][?:AgentEvent] if jid(e)==id];
        applications=[a for a in [root -->][?:Application] if jid(a)==application_id and not a.demo];
        if not events or not applications { return {"error":"This event or application was not found."}; }
        e=events[0];e.data={**e.data,"application_id":application_id,"status":status,"ambiguous":False,"resolved":True};
        _apply_confirmed_mail(e.data);commit();return agent_events();
    }
}
