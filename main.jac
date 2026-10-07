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
import importlib;
import logging;
import agents.worker as browser_worker;
import from core.fixtures { JOBS, PEOPLE }
import from core.agents { _demo_status }
import from core.automation {
    AgentMemory, AgentAction, AgentNotification, AgentPushDevice, AgentTicket, AgentRun, AgentContact, AgentConnection, AgentEvent, AgentAdmission, AgentInterview, PrepSession,
    _agent_access, _agent_memory, _agent_summary, _agent_start, _agent_fresh, _agent_system, _agent_owner, _owned_run, _agent_leased, _run_view, _steps, agent_upgrade_workflows,
    agent_settings, agent_report, agent_admission, agent_register_push, agent_remove_push, agent_notification_claim, agent_notification_begin, agent_notification_finish, agent_notification_status, agent_save_facts, agent_save_policy, agent_activity, agent_run, agent_cancel, agent_respond, agent_reconcile,
    agent_contacts, agent_save_contact, agent_stop_contact, agent_import_contacts, agent_events, agent_claim, agent_model_log, agent_model_logs, agent_authorize, _agent_complete, agent_worker_connection, agent_approve, agent_retry, agent_dismiss, agent_trace, agent_traces, agent_feedback,
    agent_invite, agent_accept_invite, agent_google_start, agent_google_finish, agent_disconnect, agent_export,
    prep_progress, prep_live, agent_live_claim, agent_live_check, agent_live_finish, prep_catalog, prep_sessions, prep_create, prep_get, prep_save
}
import from agents.contracts { authorize, config, digest, model_status, model_access, validate_facts, STEPS }
import from agents.latex { load as latex_load, pack as latex_pack, unpack as latex_unpack, encode as latex_encode, compile as latex_compile, parse as latex_parse, summary as latex_summary, outline as latex_outline }
import from agents.scoring { score as resume_score, summary as score_summary }
import from agents.tailoring { resume_text }
import from agents.pdf_safety { inspect_pdf, inspect_file }
import from agents.resume_templates { TEMPLATES as LATEX_TEMPLATES, fill as fill_template }
import from agents.record_resume { validate_upload, validate_records, check_documents }
import from agents.linkedin { profile_url }
import from agents.voice { voice_settings }
import from agents.prep { problem, validate_session }
import from agents.study { plan as study_plan }
import from agents.experience { feature_status }
import from agents.google { SCOPES }
import from core.transcription { transcription_upload, transcription_list, transcription_get, transcription_audio, transcription_action, transcription_transfer_complete, transcription_processing_claim, transcription_processing_progress, transcription_processing_finish, transcription_retry_setup, transcription_processing_runtime }
import from agents.transcription_store { Store as TranscriptionStore }
import os;

node Profile {
    has linkedin_url: str = "", linkedin_target_role: str = "";
    has name: str = "", role: str = "", location: str = "United States", mode: str = "Any", onboarded: bool = False, notifications: bool = True;
}
node Decision { has job_id: str, action: str; }
node Application { has job_id: str, created_at: float, status: str = "", notes: str = "", resume_id: str = "", demo: bool = True, snapshot: dict[str, any] = {}, status_at: float = 0.0, history: list[dict[str, any]] = []; }
node Contact { has person_id: str, saved: bool = False, draft: str = "", notes: str = ""; }
node Resume { has name: str, file_key: str, size: int, created_at: float, review: dict[str, any] = {}, review_revision: int = 0, review_confirmed: bool = False, template: dict[str, any] = {}, processing: dict[str, any] = {}, upload_digest: str = ""; }
"""A final tailored resume: saved once per tailoring task, kept separate from the user's uploads."""
node TailoredResume {
    has name: str, run_id: str, application_id: str, job_title: str, company: str, source_resume_id: str, source_name: str,
        pdf_key: str, tex: str, created_at: float, outline: list[dict[str, any]] = [], pages: int = 1, format: str = "", parse: dict[str, any] = {},
        score: dict[str, any] = {}, docx_key: str = "", change_record: dict[str, any] = {}, records: list[dict[str, any]] = [];
}
node ResumeTicket {
    has owner: str, resume_id: str, kind: str, input_key: str, fingerprint: str,
        created_at: float, status: str = "queued", lease: str = "", lease_until: float = 0.0,
        attempts: int = 0, timings: dict[str, any] = {}, stage_at: float = 0.0, message: str = "";
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
      "profile":{"name":p.name,"role":p.role,"linkedin_url":p.linkedin_url,"linkedin_target_role":p.linkedin_target_role,"location":p.location,"mode":p.mode,"onboarded":p.onboarded,"notifications":p.notifications,**_timeline_preferences(),"preferences":_match_preferences()},
      "jobs":[_application_job(a) for a in [root -->][?:Application]],
      "saved_search":_saved_search(),
      "decisions":[{"job_id":d.job_id,"action":d.action} for d in [root -->][?:Decision]],
      "applications":[_app_view(a) for a in [root -->][?:Application]],
      "people":PEOPLE,
      "contacts":[{"id":jid(c),"person_id":c.person_id,"saved":c.saved,"draft":c.draft,"notes":c.notes} for c in [root -->][?:Contact]],
      "resumes":[{"id":jid(r),"name":r.name,"size":r.size,"created_at":r.created_at,"details_status":"Confirmed" if r.review_confirmed else "Review" if r.review.get("records") else "Processing","review_revision":r.review_revision,"processing":r.processing,"format":_resume_format(r)} for r in [root -->][?:Resume]],
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
def:priv upload_resume(name: str, content: str, transfer_ms: float = 0.0) -> dict[str, any] {
    _profile();
    if not name.strip() or len(name)>160 { return _error("Use a filename under 160 characters."); }
    if len(content)>13981016 { return _error("Resume must be 10 MB or smaller."); }
    try { raw = base64.b64decode(content,validate=True); } except Exception { return _error("Invalid resume encoding."); }
    try {
        suffix=validate_upload(name,raw);
    } except ValueError as e { return _error(str(e)); }
    except Exception { return _error("This resume could not be opened. Please export a new copy."); }
    fingerprint=hashlib.sha256(raw).hexdigest();
    with _write_lock {
        _agent_fresh();
        for existing in [root -->][?:Resume] {
            if existing.upload_digest==fingerprint and existing.name==Path(name).name { return bootstrap(); }
        }
        key = "upload-"+hashlib.sha256(Path(name).name.encode()+raw).hexdigest()+suffix;
        used_keys={existing.file_key for existing in [root -->][?:Resume]};
        while key in used_keys { key="upload-"+hashlib.sha256(key.encode()).hexdigest()+suffix; }
        _write_private(key,raw);
        r = root ++> Resume(name=Path(name).name, file_key=key, size=len(raw), created_at=time.time(),upload_digest=fingerprint);
        _queue_resume(r,"import",key,fingerprint,transfer_ms,Path(name).name);
        settings = _settings(); if not settings.selected_resume { settings.selected_resume=jid(r); }
        commit();
    }
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
    if r.review.get("records") {
        return {"kind":"records","template":r.review.get("template","classic"),"label":"Stack reviewed records","pages":0,"summary":{},"skipped":[]};
    }
    return {"kind":"","template":"","label":"Review imported content","pages":0,"summary":{},"skipped":[]};
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
        "source_name":x.source_name,"created_at":x.created_at,"pages":x.pages,"format":x.format,"parse":x.parse,"score":x.score,"has_docx":bool(x.docx_key)};
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
    docx_key="";
    if t.get("docx",{}).get("content") { docx_key=key.replace(".pdf",".docx");_write_private(docx_key,base64.b64decode(t["docx"]["content"])); }
    x=root ++> TailoredResume(name=(title+" at "+company if title and company else title or company or "Tailored resume")[:200],run_id=jid(r),application_id=r.context.get("application_id",""),
        job_title=title[:200],company=company[:200],source_resume_id=r.context.get("resume_id",""),source_name=r.context.get("resume_name",""),
        pdf_key=key,tex=str(t.get("tex",""))[:400000],created_at=time.time(),outline=t.get("outline",[]),pages=int(t["pdf"].get("pages",1)),format=str(t.get("format","")),
        score=t.get("score",{}),docx_key=docx_key,change_record=t.get("change_record",{}),records=t.get("records",[]));
    return jid(x);
}
"""Once per account: saves tasks that finished before tailored resumes were kept separately.
Later ones are saved when they finish, so a deleted tailored resume is not brought back."""
def _backfill_tailored() -> None {
    if _settings().tailored_backfilled { return; }
    saved=[x.run_id for x in [root -->][?:TailoredResume]];
    if not [r for r in [root -->][?:AgentRun] if r.artifacts.get("tailor",{}).get("final") and jid(r) not in saved] {
        _settings().tailored_backfilled=True;return;
    }
    # bootstrap() follows other writes (such as an upload); keep them before re-reading under the lock.
    commit();
    with _write_lock {
        _agent_fresh();settings=_settings();
        if settings.tailored_backfilled { return; }
        for r in [root -->][?:AgentRun] { _save_tailored(r); }
        settings.tailored_backfilled=True;commit();
    }
}
"""Independently check approved record documents; legacy checks remain unavailable."""
def _check_tailored(id: str) -> None {
    with _write_lock {
        _agent_fresh();x=_owned_tailored(id);
        if x is not None {
            if x.format=="records" and x.docx_key {
                try { x.parse={**check_documents(_file_path(x.pdf_key).read_bytes(),_file_path(x.docx_key).read_bytes(),x.records),"checked_at":time.time()};x.parse.pop("text",None); }
                except (ValueError, OSError) as e { x.parse={"available":True,"ok":False,"error":str(e),"checked_at":time.time()}; }
            } else { x.parse={"available":False,"ok":False,"error":"PDF parser checks are temporarily unavailable.","checks":[],"passed":0,"total":0,"checked_at":time.time()}; }
            commit();
        }
    }
}

def:priv read_tailored_resume(id: str) -> dict[str, any] {
    x=_owned_tailored(id);
    if x is None { return _error("Tailored resume not found."); }
    path=_file_path(x.pdf_key);
    if not path.exists() { return _error("This file is unavailable."); }
    out={"id":id,"name":x.name,"pdf":{"name":_tailored_filename(x),"content":base64.b64encode(path.read_bytes()).decode()},"tex":x.tex,"change_record":x.change_record};
    if x.docx_key {
        docx=_file_path(x.docx_key);
        if not docx.exists() { return _error("The editable DOCX is unavailable."); }
        out["docx"]={"name":_tailored_filename(x).replace(".pdf",".docx"),"content":base64.b64encode(docx.read_bytes()).decode()};
    }
    return out;
}
def:priv check_tailored_resume(id: str) -> dict[str, any] {
    if _owned_tailored(id) is None { return _error("Tailored resume not found."); }
    _check_tailored(id);return bootstrap();
}
"""Score an owned LaTeX resume for a saved job. PDF-only scoring is temporarily unavailable."""
def:priv score_resume(application_id: str) -> dict[str, any] {
    apps=[a for a in [root -->][?:Application] if jid(a)==application_id and not a.demo];
    if not apps { return _error("Saved job not found."); }
    found=_application_resume(apps[0]);
    if found is None { return _error("Upload your resume on the Resume tab first."); }
    r: Resume = found;
    if not _tailor_source(r) { return _error("PDF-only scoring is temporarily unavailable. Upload your LaTeX source to score this resume."); }
    try {
        source=_resume_source(r);
        facts=[f for f in _agent_memory().facts if f.get("verified")];
        if source["format"]=="records" {
            import agents.record_resume as record_resume;
            prepared=record_resume.prepare(source);
            result=score_summary(resume_score(prepared["outline"],_application_job(apps[0]),facts,text="\n".join(record["text"] for record in prepared["records"])));
        } else {
            structure=latex_parse(source);
            result=score_summary(resume_score(latex_outline(structure),_application_job(apps[0]),facts,text=resume_text(structure["tex"])));
        }
    } except ValueError as e { return _error(str(e)); }
    return {"application_id":application_id,"resume_name":r.name,"source":source["format"],"score":result};
}

def:priv delete_tailored_resume(id: str) -> dict[str, any] {
    with _write_lock {
        _agent_fresh();x=_owned_tailored(id);
        if x is None { return _error("Tailored resume not found."); }
        if x.docx_key { _file_path(x.docx_key).unlink(missing_ok=True); }
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
    if r.template.get("kind")!="builtin" {
        if not r.review_confirmed or not r.review.get("records") { raise ValueError("Review and confirm the imported records for "+r.name+" before tailoring."); }
        return {"format":"records","records":r.review["records"],"template":r.review.get("template","classic"),"revision":r.review_revision,"upload_digest":r.upload_digest};
    }
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
def:priv upload_resume_source(id: str, name: str, content: str, transfer_ms: float = 0.0) -> dict[str, any] {
    _agent_access();
    if not name.strip() or len(name)>160 or Path(name).suffix.lower() not in [".tex",".zip"] { return _error("Choose a .tex file or Overleaf source .zip."); }
    if len(content)>2796204 { return _error("Upload a LaTeX source of 2 MB or less."); }
    try { raw=base64.b64decode(content,validate=True); } except Exception { return _error("This file could not be read. Choose it again."); }
    if not raw or len(raw)>2097152 { return _error("Upload a LaTeX source of 2 MB or less."); }
    fingerprint=hashlib.sha256(name.encode()+raw).hexdigest();
    with _write_lock {
        _agent_fresh();r=_owned_resume(id);
        if r is None { return _error("Resume not found."); }
        current=r.processing.get("source",{});
        if current.get("fingerprint")==fingerprint { return bootstrap(); }
        key="source-"+id+"-"+fingerprint+Path(name).suffix.lower();_write_private(key,raw);
        _queue_resume(r,"source",key,fingerprint,transfer_ms,Path(name).name);
        commit();
    }
    return bootstrap();
}
def:priv use_resume_template(id: str, template: str) -> dict[str, any] {
    _agent_access();
    with _write_lock {
        _agent_fresh();r=_owned_resume(id);
        if r is None { return _error("Resume not found."); }
        if template=="" {
            _cancel_resume_work(r,"source");_remove_template_files(r);r.template={};commit();return bootstrap();
        }
        if template not in LATEX_TEMPLATES { return _error("Choose one of the built-in templates."); }
        if not r.review_confirmed { return _error("Confirm your resume details first, so Stack can fill the template."); }
        if r.review.get("records") {
            _cancel_resume_work(r,"source");_remove_template_files(r);r.template={};
            r.review={**r.review,"template":template};r.review_revision+=1;commit();return bootstrap();
        }
        data=__import__("json").dumps({"template":template,"values":r.review.get("values",{})}).encode();
        fingerprint=hashlib.sha256(data).hexdigest();
        if r.processing.get("source",{}).get("fingerprint")==fingerprint { return bootstrap(); }
        key="template-"+id+"-"+fingerprint+".json";_write_private(key,data);
        _queue_resume(r,"source",key,fingerprint,0.0,template);
        commit();
    }
    return bootstrap();
}
def:priv read_resume_source(id: str) -> dict[str, any] {
    r=_owned_resume(id);
    if r is None { return _error("Resume not found."); }
    name=r.name;view=_resume_format(r);key=str(r.template.get("preview_key",""));
    try { source=_resume_source(r); } except ValueError as e { return _error(str(e)); }
    if source["format"]=="records" { return {"id":id,"name":name,"format":view,"source":source}; }
    data: bytes = b"";
    if key and _file_path(key).exists() { data=_file_path(key).read_bytes(); }
    else {
        with _write_lock {
            _agent_fresh();current=_owned_resume(id);
            if current is None { return _error("Resume not found."); }
            t=_resume_ticket(str(current.processing.get("source",{}).get("id","")));
            if t is None { return _error("The saved preview is unavailable. Upload your source again to rebuild it."); }
            if t.status in ["completed","failed"] {
                t.status="queued";t.lease="";t.lease_until=0.0;t.attempts=0;t.created_at=time.time();t.stage_at=0.0;
                _resume_progress(t,current);commit();
            }
        }
        return _error("The preview is being rebuilt. Check its processing status, then reopen the preview.");
    }
    return {"id":id,"name":name,"format":view,"preview":{"name":"Resume preview.pdf","content":base64.b64encode(data).decode()},"tex":source["files"][source["main"]].decode("utf-8")[:200000]};
}
def:pub agent_worker_resume_source(token: str, id: str, owner: str, lease: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    with _write_lock {
        _agent_fresh();
        try {
            r=_agent_leased(id,owner,lease);
            if _steps(r)[r.index] not in ["tailor","approve_resume"] { return {"error":"This step cannot read resume sources."}; }
            resume=_owned_resume(r.context.get("resume_id",""));
            if resume is None or not _tailor_source(resume) {
                # The resume lost its LaTeX (or was deleted) after the task started. Record it so the task
                # pauses on the LaTeX step instead of asking a generic question.
                r.context={**r.context,"resume_format":""};commit();
                raise ValueError("Choose a resume for this application on the Resume tab, then try again." if resume is None else "Review and confirm the imported records for "+resume.name+" or upload its LaTeX.");
            }
            source=_resume_source(resume);
            return source if source["format"]=="records" else {**latex_encode(source),"format":source["format"]};
        } except ValueError as e { return {"error":str(e)}; }
    }
}
def:priv read_resume(id: str) -> dict[str, any] {
    r = _owned_resume(id); if r is None { return _error("Resume not found."); }
    path = _file_path(r.file_key);
    if not path.exists() { return _error("This file is unavailable. Please upload it again."); }
    return {"name":r.name,"content":base64.b64encode(path.read_bytes()).decode(),"review":{**r.review,"revision":r.review_revision,"confirmed":r.review_confirmed}};
}
def:priv change_resume(id: str, action: str, name: str = "") -> dict[str, any] {
    r = _owned_resume(id); if r is None { return _error("Resume not found."); }
    if action=="select" { _settings().selected_resume=id; }
    elif action=="rename" {
        if not name.strip() or len(name)>160 { return _error("Enter a name under 160 characters."); }
        r.name=name.strip();
    } elif action=="delete" {
        _cancel_resume_work(r);_file_path(r.file_key).unlink(missing_ok=True);_remove_template_files(r);
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
    if r.review_confirmed {
        if r.template.get("kind")=="builtin" { return "builtin"; }
        if r.review.get("records") { return "records"; }
    }
    return "";
}
def _application_agent_context(a: Application) -> dict[str, any] {
    job=_application_job(a);p=_profile();resume=_application_resume(a);
    context={"application_id":jid(a),"job":job,"profile":{"name":p.name,"role":p.role,"location":p.location,"preferences":_match_preferences()},"resume_id":jid(resume) if resume is not None else "","resume_format":_tailor_source(resume)};
    if resume is not None {
        context["resume_name"]=resume.name;
        try {
            if _tailor_source(resume)=="records" { context["resume_text"]="\n".join(record["text"] for record in resume.review["records"]); }
            else { context["resume_text"]=inspect_file(_file_path(resume.file_key),True)["text"]; }
        } except Exception { context["resume_text"]=""; }
    }
    return context;
}
def:priv agent_start(kind: str, target_id: str) -> dict[str, any] {
    _agent_access();
    if kind=="application" { return _error("The application assistant has been retired. Apply on the employer site yourself."); }
    with _write_lock {
        _agent_fresh();
        if kind in ["jobs","resume"] {
            for a in [root -->][?:Application] {
                if jid(a)==target_id and not a.demo {
                    job=_application_job(a);
                    context=_application_agent_context(a);
                    # Refuse unconfirmed or unavailable sources before queueing tailoring.
                    if kind=="resume" and not context["resume_id"] { return _error("Upload your resume on the Resume tab first."); }
                    if kind=="resume" and not context["resume_format"] { return _error("Review and confirm the imported records for "+context["resume_name"]+" or upload its LaTeX."); }
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
        steps=_steps(r);
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
        if not context["resume_format"] { return _error("Review and confirm the imported records for "+context["resume_name"]+" or upload its LaTeX."); }
    }
    return agent_respond(id,[],False);
}

def:priv agent_linkedin_profile(url: str = "", target_role: str | None = None) -> dict[str, any] {
    _agent_access();
    if url {
        try { url=profile_url(url); } except ValueError as e { return _error(str(e)); }
    }
    if target_role is not None and len(target_role)>200 { return _error("Keep the target role under 200 characters."); }
    with _write_lock {
        _agent_fresh();p=_profile();
        if target_role is not None and target_role!="None" { p.linkedin_target_role=target_role.strip(); }
        if url { p.linkedin_url=url; }
        elif not p.linkedin_url {
            for r in [root --> [?:AgentRun, -created_at]] {
                if r.kind=="linkedin" and r.context.get("linkedin_url") {
                    p.linkedin_url=profile_url(r.context["linkedin_url"]);break;
                }
            }
        }
        commit();return {"url":p.linkedin_url,"target_role":p.linkedin_target_role};
    }
}

def:priv agent_linkedin_start(url: str = "", target_role: str = "") -> dict[str, any] {
    _agent_access();
    try {
        url=profile_url(url or agent_linkedin_profile()["url"]);target_role=target_role.strip() or _profile().linkedin_target_role or _profile().role;
        if len(target_role)>200 { return _error("Keep the target role under 200 characters."); }
        authorize(_agent_memory().policy,"model");model_access(config(),jid(root));
        if not os.environ.get("STACK_BROWSER_URL","") or not os.environ.get("STACK_BROWSER_TOKEN","") { return _error("LinkedIn review needs the isolated browser worker. Configure it before starting."); }
    } except ValueError as e { return _error(str(e)); }
    with _write_lock {
        _agent_fresh();
        p=_profile();p.linkedin_url=url;p.linkedin_target_role=target_role;commit();
        for r in [root -->][?:AgentRun] {
            if r.kind=="linkedin" and r.status not in ["completed","cancelled","failed"] and r.context.get("linkedin_url")==url and r.context.get("target_role")==target_role { return _run_view(r,True); }
        }
        p=_profile();
        return _agent_start("linkedin","self",{"linkedin_url":url,"target_role":target_role or p.role,"profile":{"name":p.name}},str(uuid4()));
    }
}
def:priv agent_extract_resume(id: str) -> dict[str, any] {
    _agent_access();
    with _write_lock {
        _agent_fresh();r=_owned_resume(id);
        if r is None { return _error("Resume not found."); }
        if r.review.get("records") { return {**r.review,"revision":r.review_revision,"confirmed":r.review_confirmed}; }
        if not r.processing.get("import") { _queue_resume(r,"import",r.file_key,r.upload_digest,0.0,r.name);commit(); }
        return {"processing":r.processing.get("import",{}),"revision":r.review_revision,"confirmed":False};
    }
}

"""Save edited imported records with optimistic revision checks and explicit confirmation."""
def:priv resume_save_records(id: str, revision: int, records: list[dict[str, any]], confirm: bool = False, template: str = "classic") -> dict[str, any] {
    _agent_access();
    if template not in ["classic","jake"] { return _error("Choose the Classic or Jake template."); }
    try { checked=validate_records(records); } except ValueError as e { return _error(str(e)); }
    with _write_lock {
        _agent_fresh();r=_owned_resume(id);
        if r is None { return _error("Resume not found."); }
        if r.review_revision!=revision { return _error("Resume review changed. Reload it before saving."); }
        if not r.review.get("imported_records") { return _error("Wait for resume import before reviewing its records."); }
        _cancel_resume_work(r,"import");
        r.review={**r.review,"records":checked,"template":template,"confirmed_at":time.time() if confirm else 0.0};
        r.review_revision+=1;r.review_confirmed=confirm;commit();
        return {**r.review,"revision":r.review_revision,"confirmed":r.review_confirmed};
    }
}

def:priv resume_save_details(id: str, revision: int, values: dict[str, any], confirm: bool = False) -> dict[str, any] {
    _agent_access();
    if _owned_resume(id) is None { return _error("Resume not found."); }
    return _error("PDF detail editing is temporarily unavailable. Existing confirmed facts are preserved.");
}

def _browser_run(id: str) -> AgentRun | None {
    _agent_access();r=_owned_run(id);
    if r is None or r.kind!="linkedin" or r.status in ["completed","cancelled","failed"] { return None; }
    if r.kind=="linkedin" and r.index!=0 { return None; }
    return r;
}
def:priv agent_browser_subscribe(id: str) -> dict[str, any] {
    if _browser_run(id) is None { return {"error":"This task has no active browser."}; }
    try {
        grant=browser_worker.browser_call("subscribe",{"owner":jid(root),"id":id},5);
        return {"ticket":grant["ticket"],"url":os.environ["STACK_BROWSER_URL"].rstrip("/")+"/stream"};
    } except Exception { return {"error":"The browser stream is unavailable. Reconnect to try again."}; }
}
def:priv agent_browser_control(id: str, action: str, generation: int = -1, controller: str = "", instance: str = "") -> dict[str, any] {
    _agent_access();r=_owned_run(id);
    if r is None or r.kind!="linkedin" { return {"error":"This task has no browser."}; }
    if action=="stop" {
        result=agent_cancel(id);
        try { result["control"]=browser_worker.browser_call("control",{"owner":jid(root),"id":id,"action":"status"},2); }
        except Exception { result["control"]={"mode":"stopping","generation":generation}; }
        return result;
    }
    if _browser_run(id) is None { return {"error":"This browser task has ended."}; }
    if action not in ["take","resume","status"] { return {"error":"Unknown browser control."}; }
    if action=="take" and [a for a in [root -->][?:AgentAction] if a.run_id==id and a.status=="intent"] { return {"error":"An approved action is already being sent. Wait for its receipt before taking control."}; }
    previous=r.context.get("browser_return",r.status);
    if action=="take" {
        with _write_lock {
            _agent_fresh();r=_browser_run(id);
            if r is None { return {"error":"This browser step has ended."}; }
            if [a for a in [root -->][?:AgentAction] if a.run_id==id and a.status=="intent"] { return {"error":"Wait for the approved action's receipt before taking control."}; }
            previous=r.context.get("browser_return",r.status);r.context["browser_return"]=previous;
            r.status="paused";r.lease="";r.lease_until=0.0;commit();
        }
    }
    try { state=browser_worker.browser_call("control",{"owner":jid(root),"id":id,"action":action,"generation":generation,"controller":controller,"instance":instance},5); }
    except ValueError as e { return {"error":str(e)}; }
    except Exception { return {"error":"Control could not be confirmed. Reconnect before sending input."}; }
    with _write_lock {
        _agent_fresh();r=_owned_run(id);
        if r is None or r.status in ["completed","cancelled","failed"] or (r.kind=="linkedin" and r.index!=0) { return {"error":"The browser step ended while control was changing."}; }
        if action in ["take","resume"] and r.context.get("browser_instance","")==state["instance"] and r.context.get("browser_generation",0)>state["generation"] { return {"error":"Browser control changed while this request was finishing. Reconnect before continuing."}; }
        if action in ["take","resume"] { r.context["browser_generation"]=state["generation"];r.context["browser_instance"]=state["instance"]; }
        if action=="take" {
            r.context["browser_return"]=previous;r.status="paused";r.lease="";r.lease_until=0.0;
            r.message="Pausing browser activity. Your controls unlock when the browser confirms.";
        } elif action=="resume" {
            if r.status!="paused" { return {"error":"This task is not paused for browser control."}; }
            r.status=previous if previous in ["review","uncertain"] else "needs_input" if any(q["key"]!="browser" for q in r.requests) else "queued";
            if r.status=="queued" { r.requests=[];r.attempts=0;r.next_at=0.0; }
            r.context.pop("browser_return",None);r.message="Browser returned to the agent.";
        }
        for t in [root.shared -->][?:AgentTicket] { if t.run_id==id { t.state=r.status;t.due_at=0.0; } }
        commit();return {**_run_view(r,True),"control":state};
    }
}
def:priv agent_browser(id: str, event: dict[str, any]) -> dict[str, any] {
    r=_browser_run(id);
    if r is None { return {"error":"This task has no active browser session."}; }
    kind=event.get("type","snapshot");
    if kind in ["take","resume","stop"] { return agent_browser_control(id,kind,event.get("generation",-1),event.get("controller",""),event.get("instance","")); }
    if kind!="snapshot" and r.status!="paused" { return {"error":"Take control before using the browser."}; }
    try {
        identity={"owner":jid(root),"id":id};
        result=browser_worker.browser_call("frame" if kind=="snapshot" else "handoff",{**identity,"event":event},10);
        result["control"]=browser_worker.browser_call("control",{**identity,"action":"status"},2);
        return result;
    } except ValueError as e { return {"error":str(e)}; }
    except Exception { return {"error":"Stack could not confirm browser input. Reconnect before continuing."}; }
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
        "operator_limits":c["action_daily_limits"],
        "resumes":len([root -->][?:Resume]),"applications":len(real),
        "tailor_source":_tailor_source(default_resume),"tailor_resume":default_resume.name if default_resume is not None else "",
        "resume_facts":len([f for f in facts if f.get("verified") and str(f["key"]).startswith("resume.")]),
        "verified_facts":len([f for f in facts if f.get("verified")]),
        "contacts_selected":len([x for x in [root -->][?:AgentContact] if x.data.get("selected") and not x.data.get("stopped")])
    });
}
def:priv agent_features() -> dict[str, any] { _agent_access();return {"features":_features()}; }

def _export_resume(r: Resume) -> dict[str, any] {
    out={"id":jid(r),**read_resume(jid(r)),"format":_resume_format(r)};
    if r.template {
        try { out["source"]=latex_encode(_resume_source(r)); }
        except ValueError as e { out["source_error"]=str(e); }
    }
    return out;
}
def:priv account_export() -> dict[str, any] {
    _agent_access();return {"account":bootstrap(),"agents":agent_export(),"recordings":TranscriptionStore().list(jid(root)),"resumes":[_export_resume(r) for r in [root -->][?:Resume]],"tailored_resumes":[read_tailored_resume(jid(x)) for x in [root -->][?:TailoredResume]]};
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
        for r in [root -->][?:Resume] { _cancel_resume_work(r);_file_path(r.file_key).unlink(missing_ok=True);_remove_template_files(r); }
        for x in [root -->][?:TailoredResume] {
            _file_path(x.pdf_key).unlink(missing_ok=True);
            if x.docx_key { _file_path(x.docx_key).unlink(missing_ok=True); }
        }
        for n in [root -->] { if jid(n)!=jid(m) { del n; } }
        TranscriptionStore().delete_owner(owner);
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

"""Durable resume work. The shared ticket contains identifiers only; files stay account-owned."""
def _resume_ticket(id: str) -> ResumeTicket | None {
    for t in [root.shared -->][?:ResumeTicket] { if jid(t)==id { return t; } }
    return None;
}
def _resume_progress(t: ResumeTicket, r: Resume) -> None {
    r.processing={**r.processing,t.kind:{"id":jid(t),"status":t.status,"message":t.message,
        "fingerprint":t.fingerprint,"attempt":t.attempts,"queued_at":t.created_at,"stage_at":t.stage_at,"timings":t.timings}};
}
def _resume_log(t: ResumeTicket, stage: str, elapsed_ms: float) -> None {
    logging.getLogger("stack.resume").info(__import__("json").dumps({"event":"resume_processing","job_id":jid(t),"kind":t.kind,"attempt":t.attempts,"stage":stage,"elapsed_ms":round(elapsed_ms,2)}));
}
def _cancel_resume_work(r: Resume, kind: str = "", keep_key: str = "") -> None {
    for t in [root.shared -->][?:ResumeTicket] {
        if t.owner==jid(root) and t.resume_id==jid(r) and (not kind or t.kind==kind) {
            t.status="cancelled";t.lease="";
            if t.kind=="source" and t.input_key!=keep_key { _file_path(t.input_key).unlink(missing_ok=True); }
        }
    }
    r.processing={k:v for (k,v) in r.processing.items() if kind and k!=kind};
}
def _queue_resume(r: Resume, kind: str, key: str, fingerprint: str, transfer_ms: float, name: str = "") -> None {
    _cancel_resume_work(r,kind,key);
    elapsed=max(0.0,min(float(transfer_ms),86400000.0));
    t=root.shared ++> ResumeTicket(owner=jid(root),resume_id=jid(r),kind=kind,input_key=key,fingerprint=fingerprint,created_at=time.time(),timings={"transfer_ms":elapsed if elapsed else None,"queue_ms":0.0,"parse_ms":0.0,"compile_ms":0.0},message=name);
    JacRuntime.allow_root(t,__import__("uuid").UUID(jid(root.shared)),AccessLevel.WRITE); # jac:ignore[E1053]
    _resume_progress(t,r);
    if elapsed { _resume_log(t,"transfer",elapsed); }
}
def:priv retry_resume_processing(id: str, kind: str) -> dict[str, any] {
    _agent_access();
    with _write_lock {
        _agent_fresh();r=_owned_resume(id);
        if r is None or kind not in ["pdf","source","import"] { return _error("Resume processing not found."); }
        if kind=="pdf" { return _error("PDF detail extraction is temporarily unavailable."); }
        t=_resume_ticket(str(r.processing.get(kind,{}).get("id","")));
        if t is None or t.owner!=jid(root) { return _error("Resume processing not found."); }
        if t.status=="failed" {
            t.status="queued";t.created_at=time.time();t.attempts=0;t.lease="";t.lease_until=0.0;t.stage_at=0.0;
            t.timings={**t.timings,"queue_ms":0.0,"parse_ms":0.0,"compile_ms":0.0};
            _resume_progress(t,r);commit();
        }
    }
    return bootstrap();
}
def _resume_leased(id: str, owner: str, lease: str) -> ResumeTicket {
    t=_resume_ticket(id);
    if t is None or t.owner!=owner or not lease or t.lease!=lease or t.lease_until<time.time() or t.status not in ["parsing","compiling"] { raise ValueError("Resume processing lease expired or cancelled."); }
    _agent_owner(owner);r=_owned_resume(t.resume_id);
    if r is None or r.processing.get(t.kind,{}).get("id")!=id { raise ValueError("Resume processing was replaced or deleted."); }
    return t;
}
def:pub resume_processing_claim(token: str) -> dict[str, any] {
    if not _agent_system(token) { return _error("Worker authorization required."); }
    with _write_lock {
        _agent_fresh();now=time.time();
        tickets=[t for t in [root.shared --> [?:ResumeTicket, created_at]] if t.status in ["queued","parsing","compiling"] and t.lease_until<=now];
        for t in tickets {
            commit();_agent_owner(t.owner);r=_owned_resume(t.resume_id);
            if r is None or _agent_memory().deleted or r.processing.get(t.kind,{}).get("id")!=jid(t) { t.status="cancelled";commit();continue; }
            if t.kind=="pdf" {
                t.status="cancelled";_resume_progress(t,r);commit();continue;
            }
            if t.attempts>=3 {
                t.status="failed";_resume_progress(t,r);r.processing[t.kind]["error"]="Processing was interrupted three times. Retry when the worker is available.";commit();continue;
            }
            waiting_since=max(t.created_at,t.lease_until);
            t.attempts+=1;t.lease=str(uuid4());t.lease_until=now+180;t.status="parsing";t.stage_at=now;
            t.timings={**t.timings,"queue_ms":max(0.0,now-waiting_since)*1000.0,"parse_ms":0.0,"compile_ms":0.0};
            _resume_progress(t,r);_resume_log(t,"queue",t.timings["queue_ms"]);commit();
            try { content=base64.b64encode(_file_path(t.input_key).read_bytes()).decode(); }
            except OSError {
                t.status="failed";_resume_progress(t,r);r.processing[t.kind]["error"]="The uploaded file is unavailable. Upload it again.";commit();continue;
            }
            return {"id":jid(t),"owner":t.owner,"lease":t.lease,"kind":t.kind,"name":t.message,"input_key":t.input_key,"content":content};
        }
        commit();return {"idle":True};
    }
}
def:pub resume_processing_stage(token: str, id: str, owner: str, lease: str, parse_ms: float) -> dict[str, any] {
    if not _agent_system(token) { return _error("Worker authorization required."); }
    with _write_lock {
        _agent_fresh();
        try { t=_resume_leased(id,owner,lease); } except ValueError as e { return _error(str(e)); }
        if t.kind!="source" or t.status!="parsing" { return _error("Invalid processing stage."); }
        t.timings={**t.timings,"parse_ms":max(0.0,parse_ms)};_resume_log(t,"parse",t.timings["parse_ms"]);
        t.status="compiling";t.stage_at=time.time();r=_owned_resume(t.resume_id);
        if r is None { return _error("Resume not found."); }
        _resume_progress(t,r);commit();return {"saved":True};
    }
}
def:pub resume_processing_finish(token: str, id: str, owner: str, lease: str, result: dict[str, any]) -> dict[str, any] {
    if not _agent_system(token) { return _error("Worker authorization required."); }
    with _write_lock {
        _agent_fresh();
        try { t=_resume_leased(id,owner,lease); } except ValueError as e { return _error(str(e)); }
        r=_owned_resume(t.resume_id);
        if r is None { return _error("Resume not found."); }
        t.timings={**t.timings,**{k:max(0.0,float(str(result.get(k,t.timings.get(k,0.0))))) for k in ["parse_ms","compile_ms"]}};
        if t.kind=="pdf" or t.status=="parsing" { _resume_log(t,"parse",t.timings["parse_ms"]); }
        if t.kind=="source" and t.status=="compiling" { _resume_log(t,"compile",t.timings["compile_ms"]); }
        if t.kind=="pdf" {
            t.status="cancelled";t.lease="";t.lease_until=0.0;_resume_progress(t,r);commit();return {"saved":True};
        }
        if result.get("error") {
            t.status="failed";_resume_progress(t,r);r.processing[t.kind]["error"]=str(result["error"])[:500];
        } elif t.kind=="import" {
            try { records=validate_records(result.get("records",[])); } except ValueError as e { return _error(str(e)); }
            r.review={**r.review,"records":records,"imported_records":records,"template":"classic","upload_digest":r.upload_digest};
            r.review_revision+=1;r.review_confirmed=False;t.status="completed";_resume_progress(t,r);
        } else {
            files={suffix:base64.b64decode(data,validate=True) for (suffix,data) in result["files"].items()};
            if set(files)-{".zip",".pdf"} or ".pdf" not in files { return _error("Invalid compiler output."); }
            key="compiled-"+jid(t);stored={};
            for (suffix,data) in files.items() { _write_private(key+suffix,data);stored[suffix]=key+suffix; }
            for old in [r.template.get("files_key",""),r.template.get("preview_key","")] {
                if old and old not in stored.values() { _file_path(old).unlink(missing_ok=True); }
            }
            r.template={**result["template"],"files_key":stored.get(".zip",""),"preview_key":stored[".pdf"],"checked_at":time.time()};
            t.status="completed";_resume_progress(t,r);
        }
        t.lease="";t.lease_until=0.0;commit();return {"saved":True};
    }
}
def:priv resume_transfer_complete(id: str, job_id: str, elapsed_ms: float) -> dict[str, any] {
    _agent_access();
    with _write_lock {
        _agent_fresh();r=_owned_resume(id);t=_resume_ticket(job_id);
        if r is None or t is None or t.owner!=jid(root) or t.resume_id!=id { return _error("Resume processing not found."); }
        if r.processing.get(t.kind,{}).get("id")!=job_id { return _error("Upload was replaced."); }
        t.timings={**t.timings,"transfer_ms":max(0.0,min(elapsed_ms,86400000.0))};
        r.processing={**r.processing,t.kind:{**r.processing[t.kind],"timings":t.timings}};
        _resume_log(t,"transfer",t.timings["transfer_ms"]);commit();return {"saved":True};
    }
}
