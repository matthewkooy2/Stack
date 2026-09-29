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
    _agent_access, _agent_memory, _agent_summary, _agent_start, _agent_fresh, _agent_system, _agent_owner, _owned_run, _agent_leased,
    agent_settings, agent_report, agent_admission, agent_register_push, agent_remove_push, agent_notification_claim, agent_notification_finish, agent_save_facts, agent_save_policy, agent_activity, agent_run, agent_cancel, agent_respond, agent_reconcile,
    agent_contacts, agent_save_contact, agent_stop_contact, agent_import_contacts, agent_events, agent_claim, agent_authorize, _agent_complete, agent_worker_connection, agent_approve, agent_retry, agent_dismiss,
    agent_invite, agent_accept_invite, agent_google_start, agent_google_finish, agent_disconnect, agent_export,
    prep_progress, prep_live, agent_live_claim, agent_live_check, agent_live_finish, prep_catalog, prep_sessions, prep_create, prep_get, prep_save
}
import from agents.contracts { authorize, config, digest, model_status, validate_facts, STEPS }
import from agents.latex { load as latex_load, pack as latex_pack, unpack as latex_unpack, encode as latex_encode, compile as latex_compile, parse as latex_parse, summary as latex_summary, outline as latex_outline }
import from agents.parse_check { compare as parse_compare, expected_profile }
import from agents.resume_templates { TEMPLATES as LATEX_TEMPLATES, fill as fill_template }
import from agents.resume_parser { parse_pdf, sections as resume_sections, validate_values, confirmed_facts }
import from agents.voice { voice_settings }
import from agents.prep { problem, validate_session }
import from agents.study { plan as study_plan }
import from agents.experience { feature_status }
import from agents.google { SCOPES }
import os;

node Profile {
    has name: str = "", role: str = "", location: str = "United States", mode: str = "Any", onboarded: bool = False, notifications: bool = True;
}
node Decision { has job_id: str, action: str; }
node Application { has job_id: str, created_at: float, status: str = "", notes: str = "", resume_id: str = "", demo: bool = True, snapshot: dict[str, any] = {}, status_at: float = 0.0, history: list[dict[str, any]] = []; }
node Contact { has person_id: str, saved: bool = False, draft: str = "", notes: str = ""; }
node Resume { has name: str, file_key: str, size: int, created_at: float, review: dict[str, any] = {}, review_revision: int = 0, review_confirmed: bool = False, template: dict[str, any] = {}; }
"""A final tailored resume: saved once per tailoring task, kept separate from the user's uploads."""
node TailoredResume {
    has name: str, run_id: str, application_id: str, job_title: str, company: str, source_resume_id: str, source_name: str,
        pdf_key: str, tex: str, created_at: float, outline: list[dict[str, any]] = [], pages: int = 1, format: str = "", parse: dict[str, any] = {};
}
node Reminder { has target_type: str, target_id: str, title: str, due_at: float, done: bool = False; }
node Settings { has selected_resume: str = "", tailored_backfilled: bool = False; }

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
    resume=_application_resume(a);
    return {"id":jid(a), "job_id":a.job_id, "created_at":a.created_at, "status":a.status or _demo_status(a.created_at,time.time()), "notes":a.notes, "resume_id":a.resume_id, "demo":a.demo,"job":_application_job(a),"history":a.history,
        "tailor":{"resume_id":jid(resume) if resume is not None else "","resume_name":resume.name if resume is not None else "","ready":bool(_tailor_source(resume))}};
}
def _application_job(a: Application) -> dict[str, any] {
    if a.demo {
        for j in JOBS { if j["id"]==a.job_id { return dict(j, demo=True); } }
    }
    live=_catalog_job(a.job_id);
    return live if live else _retained_snapshot(a.snapshot);
}
def:priv bootstrap() -> dict[str, any] {
    p = _profile();_backfill_tailored();
    return {
      "user_id":jid(root),
      "profile":{"name":p.name,"role":p.role,"location":p.location,"mode":p.mode,"onboarded":p.onboarded,"notifications":p.notifications,**_timeline_preferences(),"preferences":_match_preferences()},
      "jobs":[_application_job(a) for a in [root -->][?:Application]],
      "saved_search":_saved_search(),
      "decisions":[{"job_id":d.job_id,"action":d.action} for d in [root -->][?:Decision]],
      "applications":[_app_view(a) for a in [root -->][?:Application]],
      "people":PEOPLE,
      "contacts":[{"id":jid(c),"person_id":c.person_id,"saved":c.saved,"draft":c.draft,"notes":c.notes} for c in [root -->][?:Contact]],
      "resumes":[{"id":jid(r),"name":r.name,"size":r.size,"created_at":r.created_at,"details_status":"Confirmed" if r.review_confirmed else "Needs review" if r.review else "Not parsed","format":_resume_format(r)} for r in [root -->][?:Resume]],
      "selected_resume":_settings().selected_resume,
      "tailored_resumes":[_tailored_view(x) for x in [root --> [?:TailoredResume, -created_at]]],
      "agents":{**_agent_summary(),"features":_features()},
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
"""Save or pass a job. `start_agent` is accepted from older clients and ignored:
a right swipe only saves; agent help is offered afterwards and starts on request."""
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
            root ++> Application(job_id=job_id,created_at=time.time(),resume_id=_settings().selected_resume,demo=demo,status="" if demo else "Ready to apply",snapshot=job);
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
"""How Stack will format this resume: the user's own LaTeX, a chosen built-in template, or the default template."""
def _resume_format(r: Resume) -> dict[str, any] {
    t=r.template;
    if t.get("kind")=="upload" {
        return {"kind":"upload","label":"Your LaTeX","file":t.get("name",""),"pages":t.get("pages",0),"summary":t.get("summary",{}),"skipped":t.get("skipped",[])};
    }
    if t.get("kind")=="builtin" {
        return {"kind":"builtin","template":t["builtin"],"label":LATEX_TEMPLATES[t["builtin"]],"pages":t.get("pages",0),"summary":t.get("summary",{}),"skipped":[]};
    }
    return {"kind":"","template":"","label":"No LaTeX yet","pages":0,"summary":{},"skipped":[]};
}
def _remove_template_files(r: Resume) -> None {
    for key in ["files_key","preview_key"] {
        if r.template.get(key) { _file_path(r.template[key]).unlink(missing_ok=True); }
    }
}
def _write_private(key: str, data: bytes) -> None {
    path=_file_path(key);path.write_bytes(data);path.chmod(384);
}
def _owned_tailored(id: str) -> TailoredResume | None {
    for x in [root -->][?:TailoredResume] { if jid(x)==id { return x; } }
    return None;
}
def _tailored_view(x: TailoredResume) -> dict[str, any] {
    return {"id":jid(x),"name":x.name,"job_title":x.job_title,"company":x.company,"application_id":x.application_id,"run_id":x.run_id,
        "source_name":x.source_name,"created_at":x.created_at,"pages":x.pages,"format":x.format,"parse":x.parse};
}
def _tailored_filename(x: TailoredResume) -> str {
    return "Resume - "+" - ".join([p for p in [x.company,x.job_title] if p])[:120].replace("/","-")+".pdf";
}
"""Saves a task's final tailored resume under Resume → Tailored resumes. Returns its id, or "" when there is none or it exists."""
def _save_tailored(r: AgentRun) -> str {
    t=r.artifacts.get("tailor",{});
    if not t.get("final") or not t.get("pdf",{}).get("content") { return ""; }
    for x in [root -->][?:TailoredResume] { if x.run_id==jid(r) { return ""; } }
    job=r.context.get("job",{});title=str(job.get("title",""));company=str(job.get("company",""));key=str(uuid4())+".pdf";
    _write_private(key,base64.b64decode(t["pdf"]["content"]));
    x=root ++> TailoredResume(name=(title+" at "+company if title and company else title or company or "Tailored resume")[:200],run_id=jid(r),application_id=r.context.get("application_id",""),
        job_title=title[:200],company=company[:200],source_resume_id=r.context.get("resume_id",""),source_name=r.context.get("resume_name",""),
        pdf_key=key,tex=str(t.get("tex",""))[:400000],created_at=time.time(),outline=t.get("outline",[]),pages=int(t["pdf"].get("pages",1)),format=str(t.get("format","")));
    return jid(x);
}
"""Once per account: saves tasks that finished before tailored resumes were kept separately.
Later ones are saved when they finish, so a deleted tailored resume is not brought back."""
def _backfill_tailored() -> None {
    if _settings().tailored_backfilled { return; }
    with _write_lock {
        _agent_fresh();settings=_settings();
        if settings.tailored_backfilled { return; }
        for r in [root -->][?:AgentRun] { _save_tailored(r); }
        settings.tailored_backfilled=True;commit();
    }
}
"""The parser checks that fail on the user's original LaTeX PDF, so tailored results can say which issues are new.
None when the original cannot be checked."""
def _baseline_failures(resume_id: str) -> list[str] | None {
    r=_owned_resume(resume_id);
    if r is None or not r.template.get("preview_key") or not _file_path(r.template["preview_key"]).exists() { return None; }
    try {
        source=_resume_source(r);tex=source["files"][source["main"]].decode("utf-8");
        parsed=parse_pdf(_file_path(r.template["preview_key"]));
        original=parse_compare(parsed["values"],parsed["text"],latex_outline(latex_parse(source)),expected_profile(tex));
        return [c["label"] for c in original["checks"] if not c["ok"]];
    } except Exception { return None; }
}
"""Runs the OpenResume parser on a tailored PDF and compares what it reads with what Stack wrote,
marking issues the original upload already had."""
def _check_tailored(id: str) -> None {
    x=_owned_tailored(id);
    if x is None { return; }
    path=_file_path(x.pdf_key);outline: any = x.outline;result: dict[str, any] = {};
    try {
        parsed=parse_pdf(path);
        # Older records have no outline; the main file alone describes single-file Overleaf resumes.
        if not outline { outline=latex_outline(latex_parse({"main":"resume.tex","files":{"resume.tex":x.tex.encode()}})); }
        result={**parse_compare(parsed["values"],parsed["text"],outline,expected_profile(x.tex)),"parser":parsed["parser"],"checked_at":time.time()};
        baseline=_baseline_failures(x.source_resume_id);
        result["compared_to_original"]=baseline is not None;
        for c in result["checks"] { c["also_original"]=baseline is not None and not c["ok"] and c["label"] in baseline; }
        result["new_issues"]=len([c for c in result["checks"] if not c["ok"] and not c["also_original"]]);
    } except Exception as e { result={"ok":False,"error":str(e)[:500],"checks":[],"passed":0,"total":0,"checked_at":time.time()}; }
    with _write_lock {
        _agent_fresh();x=_owned_tailored(id);
        if x is not None { x.parse=result;commit(); }
    }
}
def:priv read_tailored_resume(id: str) -> dict[str, any] {
    x=_owned_tailored(id);
    if x is None { return _error("Tailored resume not found."); }
    path=_file_path(x.pdf_key);
    if not path.exists() { return _error("This file is unavailable."); }
    return {"id":id,"name":x.name,"pdf":{"name":_tailored_filename(x),"content":base64.b64encode(path.read_bytes()).decode()},"tex":x.tex};
}
def:priv check_tailored_resume(id: str) -> dict[str, any] {
    if _owned_tailored(id) is None { return _error("Tailored resume not found."); }
    _check_tailored(id);return bootstrap();
}
def:priv delete_tailored_resume(id: str) -> dict[str, any] {
    with _write_lock {
        _agent_fresh();x=_owned_tailored(id);
        if x is None { return _error("Tailored resume not found."); }
        _file_path(x.pdf_key).unlink(missing_ok=True);del x;commit();
    }
    return bootstrap();
}
"""The LaTeX source Stack edits: the user's upload, or the built-in template they chose, filled from confirmed details."""
def _resume_source(r: Resume) -> dict[str, any] {
    if r.template.get("kind")=="upload" {
        path=_file_path(r.template["files_key"]);
        if not path.exists() { raise ValueError("Your LaTeX source is unavailable. Upload it again on the Resume tab."); }
        return {**latex_unpack(path.read_bytes()),"format":"latex"};
    }
    if r.template.get("kind")!="builtin" { raise ValueError("Upload the LaTeX for "+r.name+" on the Resume tab before tailoring."); }
    if not r.review_confirmed { raise ValueError("Confirm the details for "+r.name+" to fill its built-in template."); }
    return {**fill_template(r.template["builtin"],r.review.get("values",{})),"format":"builtin"};
}
def _save_template(id: str, template: dict[str, any], files: dict[str, any]) -> dict[str, any] {
    key=str(uuid4());stored={};
    for (suffix,data) in files.items() { _write_private(key+suffix,data);stored[suffix]=key+suffix; }
    with _write_lock {
        _agent_fresh();r=_owned_resume(id);
        if r is None {
            for name in stored.values() { _file_path(name).unlink(missing_ok=True); }
            return _error("Resume not found.");
        }
        _remove_template_files(r);
        r.template={**template,"files_key":stored.get(".zip",""),"preview_key":stored.get(".pdf",""),"checked_at":time.time()};
        commit();
    }
    return bootstrap();
}
def:priv upload_resume_source(id: str, name: str, content: str) -> dict[str, any] {
    if _owned_resume(id) is None { return _error("Resume not found."); }
    if len(content)>2796204 { return _error("Upload a LaTeX source of 2 MB or less."); }
    try { raw=base64.b64decode(content,validate=True); } except Exception { return _error("This file could not be read. Choose it again."); }
    try {
        source=latex_load(name,raw);structure=latex_parse(source);
        if not structure["bullets"] { return _error("Stack could not find bullet points in this resume. Use \\item or \\resumeItem bullets, or choose a built-in template."); }
        # Compile the unchanged source first: if it fails here, tailoring would fail later.
        compiled=latex_compile(source);
    } except ValueError as e { return _error(str(e)); }
    return _save_template(id,{"kind":"upload","name":Path(name).name[:160],"main":source["main"],"pages":compiled["pages"],"summary":latex_summary(structure),"skipped":source["skipped"][:20]},{".zip":latex_pack(source),".pdf":compiled["pdf"]});
}
def:priv use_resume_template(id: str, template: str) -> dict[str, any] {
    if template=="" {
        with _write_lock {
            _agent_fresh();current=_owned_resume(id);
            if current is None { return _error("Resume not found."); }
            _remove_template_files(current);current.template={};commit();
        }
        return bootstrap();
    }
    r=_owned_resume(id);
    if r is None { return _error("Resume not found."); }
    if template not in LATEX_TEMPLATES { return _error("Choose one of the built-in templates."); }
    if not r.review_confirmed { return _error("Confirm your resume details first, so Stack can fill the template."); }
    values=r.review.get("values",{});
    try {
        source=fill_template(template,values);compiled=latex_compile(source);structure=latex_parse(source);
    } except ValueError as e { return _error(str(e)); }
    return _save_template(id,{"kind":"builtin","builtin":template,"pages":compiled["pages"],"summary":latex_summary(structure)},{".pdf":compiled["pdf"]});
}
def:priv read_resume_source(id: str) -> dict[str, any] {
    r=_owned_resume(id);
    if r is None { return _error("Resume not found."); }
    name=r.name;view=_resume_format(r);key=str(r.template.get("preview_key",""));
    try { source=_resume_source(r); } except ValueError as e { return _error(str(e)); }
    data: bytes = b"";
    if key and _file_path(key).exists() { data=_file_path(key).read_bytes(); }
    else {
        try { data=bytes(latex_compile(source)["pdf"]); } except ValueError as e { return _error(str(e)); }
    }
    return {"id":id,"name":name,"format":view,"preview":{"name":"Resume preview.pdf","content":base64.b64encode(data).decode()},"tex":source["files"][source["main"]].decode("utf-8")[:200000]};
}
def:pub agent_worker_resume_source(token: str, id: str, owner: str, lease: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _write_lock {
        _agent_fresh();
        try {
            r=_agent_leased(id,owner,lease);
            if STEPS[r.kind][r.index] not in ["tailor","approve_resume"] { return {"error":"This step cannot read resume sources."}; }
            resume=_owned_resume(r.context.get("resume_id",""));
            if resume is None or not _tailor_source(resume) {
                # The resume lost its LaTeX (or was deleted) after the task started. Record it so the task
                # pauses on the LaTeX step instead of asking a generic question.
                r.context={**r.context,"resume_format":""};commit();
                raise ValueError("Choose a resume for this application on the Resume tab, then try again." if resume is None else "Upload the LaTeX for "+resume.name+" to tailor it.");
            }
            source=_resume_source(resume);
            return {**latex_encode(source),"format":source["format"]};
        } except ValueError as e { return {"error":str(e)}; }
    }
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
        _file_path(r.file_key).unlink(missing_ok=True);_remove_template_files(r);
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


"""The resume an application uses: its own, else the default, else the only one uploaded.
Jobs saved before any resume was uploaded have no resume of their own."""
def _application_resume(a: Application) -> Resume | None {
    r=_owned_resume(a.resume_id);
    if r is None { r=_owned_resume(_settings().selected_resume); }
    resumes=[root -->][?:Resume];
    if r is None and len(resumes)==1 { r=resumes[0]; }
    return r;
}
"""The LaTeX Stack tailors for this resume: "latex" (uploaded), "builtin" (a chosen template), or "" when it has none.
A PDF alone is never tailored."""
def _tailor_source(r: Resume | None) -> str {
    if r is None { return ""; }
    if r.template.get("kind")=="upload" { return "latex"; }
    return "builtin" if r.template.get("kind")=="builtin" and r.review_confirmed else "";
}
def _application_agent_context(a: Application) -> dict[str, any] {
    job=_application_job(a);p=_profile();resume=_application_resume(a);
    context={"application_id":jid(a),"job":job,"profile":{"name":p.name,"role":p.role,"location":p.location,"preferences":_match_preferences()},"resume_id":jid(resume) if resume is not None else "","resume_format":_tailor_source(resume)};
    if resume is not None {
        context["resume_name"]=resume.name;
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
                    context=_application_agent_context(a);
                    # Tailoring edits LaTeX. Refuse up front rather than create a task that can only pause.
                    if kind=="resume" and not context["resume_id"] { return _error("Upload your resume on the Resume tab first."); }
                    if kind=="resume" and not context["resume_format"] { return _error("Upload the LaTeX for "+context["resume_name"]+" to tailor it."); }
                    # Attach the resolved resume so the job shows, and keeps, the resume it was tailored from.
                    if context["resume_id"] and a.resume_id!=context["resume_id"] { a.resume_id=context["resume_id"]; }
                    return _agent_start(kind,target_id,context);
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
"""Continues a task paused before tailoring, re-reading the job's resume after the user fixed it.
A chosen resume_id is attached to the job first."""
def:priv agent_continue_tailoring(id: str, resume_id: str = "") -> dict[str, any] {
    _agent_access();
    with _write_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None { return _error("Task not found."); }
        steps=STEPS[r.kind];
        if r.status!="needs_input" or steps[min(r.index,len(steps)-1)]!="tailor" { return _error("This task is not waiting for a resume."); }
        apps=[a for a in [root -->][?:Application] if jid(a)==r.context.get("application_id",r.target_id)];
        if not apps { return _error("This saved job was removed. Start tailoring from another job."); }
        a=apps[0];
        if resume_id {
            if _owned_resume(resume_id) is None { return _error("Resume not found."); }
            a.resume_id=resume_id;
        }
        context=_application_agent_context(a);
        if context["resume_id"] { a.resume_id=context["resume_id"]; }
        r.context={**r.context,**{k:v for (k,v) in context.items() if k.startswith("resume_")}};r.updated_at=time.time();
        commit();
        if not context["resume_id"] { return _error("Upload a resume on the Resume tab first."); }
        if not context["resume_format"] { return _error("Upload the LaTeX for "+context["resume_name"]+" to tailor it."); }
    }
    return agent_respond(id,[],False);
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
    if r is None or r.kind!="application" or r.status not in ["needs_input","blocked","uncertain","review"] { return {"error":"This application is not awaiting browser handoff."}; }
    try { return importlib.import_module("agents.worker").browser_call("handoff",{"owner":jid(root),"id":id,"event":event}); }
    except Exception { return {"error":"The browser worker is unavailable or this session expired."}; }
}
def:pub agent_finish(token: str, id: str, owner: str, lease: str, result: dict[str, any]) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    created="";
    with _write_lock {
        output=_agent_complete(token,id,owner,lease,result);
        if output.get("error") { return output; }
        _agent_owner(owner);r=_owned_run(id);
        if r is None { return output; }
        _project_agent(r);_notify_agent(r);created=_save_tailored(r);
        commit();
    }
    # Parsing takes a second or two, so it runs after the lock is released.
    if created { _check_tailored(created); }
    return output;
}
def _notify_agent(r: AgentRun) -> None {
    if r.status not in ["needs_input","failed","uncertain","review","blocked"] and not (r.kind=="calendar" and r.status=="completed") { return; }
    if not _profile().notifications { return; }
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


def _features() -> list[dict[str, any]] {
    m=_agent_memory();c=config();scopes=[];
    for connection in [root -->][?:AgentConnection] {
        if connection.provider=="google" and connection.state=="connected" { scopes=[k for (k,v) in SCOPES.items() if v in connection.scopes]; }
    }
    try { voice_settings();voice_error=""; } except ValueError as e { voice_error=str(e); }
    if not voice_error and not (c["monthly_cents"]>0 and c["user_monthly_cents"]>0) { voice_error="Live interviews need an API budget; subscription providers cannot run them."; }
    facts=m.facts;real=[a for a in [root -->][?:Application] if not a.demo];
    # The resume a newly tailored job uses; see _application_resume.
    default_resume=_owned_resume(_settings().selected_resume);resumes=[root -->][?:Resume];
    if default_resume is None and len(resumes)==1 { default_resume=resumes[0]; }
    return feature_status({
        "now":time.time(),"policy":m.policy,"model":model_status(jid(root)),"google_scopes":scopes,
        "google_client":bool(os.environ.get("GOOGLE_CLIENT_ID","")) and os.environ.get("GOOGLE_REDIRECT_URI","").startswith("https://"),
        "browser":bool(os.environ.get("STACK_BROWSER_URL","")) and bool(os.environ.get("STACK_BROWSER_TOKEN","")),
        "sandbox":bool(os.environ.get("STACK_SANDBOX_URL","")) or c["sandbox_available"],"voice_error":voice_error,"web_url":c["web_url"],
        "certified_adapters":c["certified_adapters"],"operator_limits":c["action_daily_limits"],
        "resumes":len([root -->][?:Resume]),"applications":len(real),
        "tailor_source":_tailor_source(default_resume),"tailor_resume":default_resume.name if default_resume is not None else "",
        "resume_facts":len([f for f in facts if f.get("verified") and str(f["key"]).startswith("resume.")]),
        "verified_facts":len([f for f in facts if f.get("verified")]),
        "contacts_selected":len([x for x in [root -->][?:AgentContact] if x.data.get("selected") and not x.data.get("stopped")])
    });
}
def:priv agent_features() -> dict[str, any] { _agent_access();return {"features":_features()}; }

def:priv account_export() -> dict[str, any] {
    _agent_access();return {"account":bootstrap(),"agents":agent_export(),"resumes":[read_resume(jid(r)) for r in [root -->][?:Resume]],"tailored_resumes":[read_tailored_resume(jid(x)) for x in [root -->][?:TailoredResume]]};
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
        for r in [root -->][?:Resume] { _file_path(r.file_key).unlink(missing_ok=True);_remove_template_files(r); }
        for x in [root -->][?:TailoredResume] { _file_path(x.pdf_key).unlink(missing_ok=True); }
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
