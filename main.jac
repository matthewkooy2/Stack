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

node Profile {
    has name: str = "", role: str = "", location: str = "United States", mode: str = "Any", onboarded: bool = False, notifications: bool = True;
}
node Decision { has job_id: str, action: str; }
node Application { has job_id: str, created_at: float, status: str = "", notes: str = "", resume_id: str = "", demo: bool = True, snapshot: dict[str, any] = {}; }
node Contact { has person_id: str, saved: bool = False, draft: str = "", notes: str = ""; }
node Resume { has name: str, file_key: str, size: int, created_at: float; }
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
    return {"id":jid(a), "job_id":a.job_id, "created_at":a.created_at, "status":a.status or _demo_status(a.created_at,time.time()), "notes":a.notes, "resume_id":a.resume_id, "demo":a.demo,"job":_application_job(a)};
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
      "resumes":[{"id":jid(r),"name":r.name,"size":r.size,"created_at":r.created_at} for r in [root -->][?:Resume]],
      "selected_resume":_settings().selected_resume,
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
def:priv swipe(job_id: str, action: str) -> dict[str, any] {
    with _write_lock {
        _refresh_transaction();
        _profile();
        job=_catalog_job(job_id); demo=job_id in [j["id"] for j in JOBS];
        if action not in ["pass","apply"] or (not job and not demo) { return _error("Invalid job or action."); }
        if not demo and (not job.get("active") or job.get("stale")) { return _error("This listing is no longer verified active. Refresh your search."); }
        for d in [root -->][?:Decision] { if d.job_id == job_id { return bootstrap(); } }
        root ++> Decision(job_id=job_id, action=action);
        if action == "apply" { root ++> Application(job_id=job_id,created_at=time.time(),resume_id=_settings().selected_resume,demo=demo,status="" if demo else "Ready to apply",snapshot=job); }
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
        if jid(a)==id and not a.demo { a.status="Submitted"; return bootstrap(); }
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
    return {"name":r.name,"content":base64.b64encode(path.read_bytes()).decode()};
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
