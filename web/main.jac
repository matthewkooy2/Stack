import from "./transport.js" { rpc, login, logout, errorText, oauthResult, downloadJSON, downloadPDF, Timer, Diagram, BrowserView, Recorder, LiveInterview, confirmAccountDelete, Poll, isoTime }
import "./style.css";
import from "./model-permission.js" { updateModelPermission }
import from .Feedback { AgentFeedback }
import from .BulletBank { BulletBank }
import from "./Interview.js" { Interview }

def:pub app -> JsxElement {
    has logged: bool = False, username: str = "", password: str = "", invite: str = "", error: str = "", notice: str = "",
        signup: bool = False, busy: bool = False, page: str = "Practice", problems: list[dict[str, any]] = [], sessions: list[dict[str, any]] = [],
        current: dict[str, any] = {}, data: dict[str, any] = {}, activity: dict[str, any] = {}, selected: dict[str, any] = {}, browser: dict[str, any] = {},
        values: dict[str, str] = {}, oauth: dict[str, any] = {}, settings: dict[str, any] = {}, mail: list[dict[str, any]] = [], interviews: list[dict[str, any]] = [], applications: list[dict[str, any]] = [], mailSelected: dict[str, any] = {}, eventApplication: str = "", eventStatus: str = "", deletePassword: str = "",
        linkedinUrl: str = "", targetRole: str = "", features: list[dict[str, any]] = [], subject: str = "", body: str = "", editsFor: str = "";
    can with entry { oauth=oauthResult(); }
    async def refresh -> None {
        settings=await rpc("agent_settings",{});activity=settings["activity"];
        result=await rpc("prep_catalog",{});problems=result["problems"];
        result=await rpc("prep_sessions",{});sessions=result["sessions"];
        result=await rpc("agent_events",{});mail=result["events"];interviews=result["interviews"];
        result=await rpc("bootstrap",{});applications=[a for a in result["applications"] if not a["demo"]];features=result["agents"].get("features",[]);
    }
    """Keep progress current without replacing answers or email edits being typed."""
    async def poll -> None {
        if not logged or busy { return; }
        try {
            if page=="Activity" { settings=await rpc("agent_settings",{});activity=settings["activity"]; }
            if len(selected)>0 and selected["status"] not in ["completed","cancelled","failed"] { showRun(await rpc("agent_run",{"id":selected["id"]})); }
        } except Exception as e { error=errorText(e); }
    }
    def showRun(run: dict[str, any]) -> None {
        review=run.get("review",{});
        if review.get("step")=="send" and review.get("hash")!=editsFor { subject=review.get("subject","");body=review.get("body","");editsFor=review["hash"]; }
        selected=run;
    }
    async def act(endpoint: str, args: dict[str, any], done: str) -> None {
        busy=True;error="";notice="";
        try { showRun(await rpc(endpoint,args));notice=done;await refresh(); }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def approve -> None {
        review=selected["review"];edits={};
        if review["step"]=="send" and (subject!=review.get("subject","") or body!=review.get("body","")) { edits={"subject":subject,"body":body}; }
        await act("agent_approve",{"id":selected["id"],"step":review["step"],"review_hash":review["hash"],"edits":edits},"Approved. Stack continues with exactly what you reviewed.");
    }
    async def signin -> None {
        busy=True;error="";
        try {
            await login(username,password,signup);password="";
            if invite { await rpc("agent_accept_invite",{"invite":invite}); }
            if oauth.get("code") { await rpc("agent_google_finish",oauth);oauth={};notice="Google connected."; }
            saved=await rpc("agent_linkedin_profile",{});linkedinUrl=saved["url"];targetRole=saved.get("target_role","");
            await refresh();logged=True;
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def openSession(id: str) -> None {
        try { current=await rpc("prep_get",{"id":id});data=current["data"];page="Practice"; }
        except Exception as e { error=errorText(e); }
    }
    async def create(id: str, language: str) -> None {
        try { current=await rpc("prep_create",{"problem_id":id,"language":language});data=current["data"];await refresh(); }
        except Exception as e { error=errorText(e); }
    }
    async def save(kind: str = "") -> None {
        busy=True;error="";
        try {
            current=await rpc("prep_save",{"id":current["id"],"revision":current["revision"],"data":data});data=current["data"];
            if kind { await rpc("agent_start",{"kind":kind,"target_id":current["id"]});notice="Queued. Refresh the session to see results."; }
            else { notice="Saved. Continue on either device."; }
            await refresh();
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def openRun(id: str) -> None {
        try { showRun(await rpc("agent_run",{"id":id}));values={};browser={}; }
        except Exception as e { error=errorText(e); }
    }
    async def exportTrace -> None {
        try { downloadJSON(await rpc("agent_traces",{"id":selected["id"]})); }
        except Exception as e { error=errorText(e); }
    }
    async def handoff(event: dict[str, any]) -> dict[str, any] {
        try { result=await rpc("agent_browser",{"id":selected["id"],"event":event});browser={**browser,**result};return result; }
        except Exception as e { error=errorText(e);return {"error":error}; }
    }
    async def startLinkedIn -> None {
        busy=True;error="";
        try { showRun(await rpc("agent_linkedin_start",{"url":linkedinUrl,"target_role":targetRole}));browser={};values={};page="Activity";await refresh(); }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def respond -> None {
        try { showRun(await rpc("agent_respond",{"id":selected["id"],"values":[{"key":k,"value":v,"verified":True,"source":"User confirmed"} for (k,v) in values.items() if v.strip()],"reuse":True}));await refresh(); }
        except Exception as e { error=errorText(e); }
    }
    async def reconcile(outcome: str) -> None {
        try { showRun(await rpc("agent_reconcile",{"id":selected["id"],"outcome":outcome,"evidence":values.get("evidence","")}));await refresh(); }
        except Exception as e { error=errorText(e); }
    }
    async def exportData -> None {
        try { result=await rpc("account_export",{});downloadJSON(result); }
        except Exception as e { error=errorText(e); }
    }
    async def resolveMail -> None {
        try { result=await rpc("agent_resolve_event",{"id":mailSelected["id"],"application_id":eventApplication,"status":eventStatus});mail=result["events"];mailSelected={};await refresh(); }
        except Exception as e { error=errorText(e); }
    }
    async def modelPermission(enabled: bool) -> None {
        busy=True;error="";notice="";
        try {
            latest=await rpc("agent_settings",{});
            policy=updateModelPermission(latest["policy"],enabled);
            settings=await rpc("agent_save_policy",{"policy":policy});activity=settings["activity"];
            notice="Model permission enabled until "+isoTime(settings["policy"]["expires_at"])+"." if enabled else "Model permission revoked.";
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def deleteAccount -> None {
        if not confirmAccountDelete() { return; }
        try { await rpc("account_delete",{"username":username,"password":deletePassword});logout();logged=False;deletePassword="";notice="Your account and active data were deleted."; }
        except Exception as e { error=errorText(e); }
    }
    <main>
        <Poll onTick={poll}/>
        <header><div><span className="brand">stack</span><h1>Your next chapter, in motion.</h1><p>Practice deeply. Let your agents handle the follow-through.</p></div>{<button onClick={lambda { logout();logged=False;linkedinUrl="";targetRole="";current={};selected={};settings={};data={}; }}>Sign out</button> if logged else <span>Private beta</span>}</header>
        {<p className="error" role="alert">{error}</p> if error else <div/>}{<p className="notice">{notice}</p> if notice else <div/>}
        {<section className="login"><h2>{"Join Stack" if signup else "Welcome back"}</h2><label>Username<input value={username} onChange={lambda (e: any) { username=e.target.value; }}/></label><label>Password<input type="password" value={password} onChange={lambda (e: any) { password=e.target.value; }}/></label><label>Invitation (first visit)<input value={invite} onChange={lambda (e: any) { invite=e.target.value; }}/></label><button className="primary" disabled={busy} onClick={signin}>Continue</button><button onClick={lambda { signup=not signup; }}>{"I already have an account" if signup else "Create an account"}</button></section> if not logged else <div/>}
        {<div>
            {<section><h2>Strengthen your LinkedIn profile</h2><p>Get prioritized recruiter-focused weaknesses and suggested rewrites based on your visible profile and confirmed facts.</p>
                <p>Your profile URL is saved to your Stack account when you start a review.</p><label>Your LinkedIn profile URL<input value={linkedinUrl} placeholder="https://www.linkedin.com/in/your-name/" onChange={lambda (e: any) { linkedinUrl=e.target.value; }}/></label>
                <label>Target role (optional)<input value={targetRole} onChange={lambda (e: any) { targetRole=e.target.value; }}/></label>
                <p>Sign in through the browser handoff, confirm the profile is yours, then start analysis. Captured profile text goes to your configured model. Login details stay in a temporary browser session. You apply suggested edits yourself.</p>
                <button className="primary" disabled={busy or not linkedinUrl.strip()} onClick={startLinkedIn}>Review my LinkedIn profile</button>
            </section> if page=="Network" else <div/>}
            <nav>{[<button key={p} className={"active" if page==p else ""} onClick={lambda { page=p; }}>{p}</button> for p in ["Practice","Interview","Network","Bullet bank","Activity","Features","Account"]]}<button onClick={refresh}>Refresh</button></nav>
            {<BulletBank/> if page=="Bullet bank" else <div/>}
            {<Interview applications={applications}/> if page=="Interview" else <div/>}
            {<div className="workspace"><aside><h2>Practice library</h2>{[<article key={p["id"]}><strong>{p["title"]}</strong><p>{p["topic"]+" · "+str(p["minutes"])+" minutes"}</p>{[<button key={lang} onClick={lambda { create(p["id"],lang); }}>{"C++" if lang=="cpp" else lang.upper()}</button> for lang in p["languages"]]}{<button onClick={lambda { create(p["id"],""); }}>Start</button> if len(p["languages"])==0 else <span/>}</article> for p in problems]}<h2>Continue</h2>{[<button key={p["id"]} onClick={lambda { openSession(p["id"]); }}>{p["data"]["problem_id"]}</button> for p in sessions]}</aside>
                <section>{<div><div className="toolbar"><Timer key={current["id"]} seconds={data.get("elapsed_seconds",0)} onChange={lambda (v: int) { data={**data,"elapsed_seconds":v}; }}/><button disabled={busy} onClick={lambda { save(); }}>Save</button><button onClick={lambda { openSession(current["id"]); }}>Refresh results</button></div>
                    {[<article key={p["id"]}><h2>{p["title"]}</h2><p>{p["prompt"]}</p><details><summary>Hints</summary>{[<p key={hint}>{hint}</p> for hint in p["hints"]]}</details></article> for p in problems if p["id"]==data["problem_id"]]}
                    <label>Your reasoning<textarea value={data["answer"]} onChange={lambda (e: any) { data={**data,"answer":e.target.value}; }}/></label>
                    {<label>{data["language"].upper()+" editor"}<textarea className="code" spellCheck={False} value={data["code"]} onChange={lambda (e: any) { data={**data,"code":e.target.value}; }}/></label> if data["language"] else <Diagram value={data["canvas"]} onChange={lambda (v: dict[str, any]) { data={**data,"canvas":v}; }}/>}
                    <div className="toolbar">{<button disabled={busy} onClick={lambda { save("code"); }}>Run tests</button> if data["language"] else <span/>}<button className="primary" disabled={busy} onClick={lambda { save("prep"); }}>Get coaching</button></div>
                    <Recorder onTranscript={lambda (text: str) { data={**data,"transcript":text}; }}/><label>Review your transcript<textarea value={data["transcript"]} onChange={lambda (e: any) { data={**data,"transcript":e.target.value}; }}/></label><LiveInterview sessionId={current["id"]} onTranscript={lambda (text: str) { data={**data,"transcript":text}; }}/>
                    {[<article key={str(r["at"])}><h3>{"Tests: "+str(r["data"].get("passed",0))+" / "+str(r["data"].get("total",0))}</h3><pre>{r["data"].get("error","")}</pre><p>{"Attempt revision "+str(r["revision"])}</p></article> for r in current["results"]]}
                    {[<article key={str(f["at"])}><h3>Coaching</h3><p>{f["data"]["summary"]}</p>{[<p key={row["criterion"]}><strong>{row["criterion"]+" · "+str(row["score"])+"/4"}</strong>{" — "+row["feedback"]}</p> for row in f["data"].get("rubric",[])]}{[<p key={q}>{q}</p> for q in f["data"].get("followup_questions",[])]}{<AgentFeedback key={f["run_id"]+f["output_version"]} runId={f["run_id"]} outputVersion={f["output_version"]}/> if f.get("run_id") and f.get("output_version") else <span/>}</article> for f in current["feedback"]]}
                </div> if len(current)>0 else <article><h2>Choose a session.</h2><p>Start on your phone or here. Your answers, code, and feedback stay together.</p></article>}</section>
            </div> if page=="Practice" else <div/>}
            {<section><h2>Messages needing review</h2>{[<article key={e["id"]}><strong>{e["subject"]}</strong><p>{e["excerpt"]}</p><button onClick={lambda { mailSelected=e;eventApplication=e.get("application_id","");eventStatus=e.get("status",""); }}>Associate this message</button></article> for e in mail if e.get("ambiguous")]}
                {<article><h3>Confirm the message outcome</h3><label>Application<select value={eventApplication} onChange={lambda (e: any) { eventApplication=e.target.value; }}><option value="">Choose an application</option>{[<option key={a["id"]} value={a["id"]}>{a["job"]["company"]+" · "+a["job"]["title"]}</option> for a in applications]}</select></label><label>Confirmed status<select value={eventStatus} onChange={lambda (e: any) { eventStatus=e.target.value; }}><option value="">Choose a status</option>{[<option key={s} value={s}>{s}</option> for s in ["Submitted","Assessment","Interview","Rejected"]]}</select></label><button onClick={resolveMail}>Save association</button></article> if len(mailSelected)>0 else <span/>}
                <h2>Upcoming interviews and practice</h2>{[<article key={i["id"]}><h3>{i.get("summary","Interview")}</h3><p>{i.get("start",{}).get("dateTime","")}</p>{[<button key={q["session_id"]} onClick={lambda { openSession(q["session_id"]); }}>{q["problem_id"]+" · "+q["reason"]}</button> for q in i.get("study_plan",[])]}</article> for i in interviews]}
                <h2>{"Agent activity · "+str(activity.get("active",0))+" in progress · "+str(activity.get("attention",0))+" need you"}</h2><p>Updates every few seconds. Stack never sends email or changes your calendar without your approval.</p>
                {[<article key={r["id"]} className={"attention" if r["attention"] else ""}><strong>{r["title"]+" · "+r["status"].replace("_"," ")}</strong><p>{r["context_label"]}</p><p>{("Step "+str(r["step_number"])+" of "+str(r["step_total"])+" · " if r["step_total"]>1 else "")+r["step_label"]+" — "+r["explanation"]}</p><button onClick={lambda { openRun(r["id"]); }}>{"Review" if r["next_action"]=="review" else "Open task"}</button></article> for r in activity.get("runs",[])]}
                {<article><h2>{selected["title"]+(" · "+selected["context_label"] if selected.get("context_label") else "")}</h2><p>{selected["explanation"]}</p><p>{selected["message"]}</p><ol>{[<li key={label}>{label}</li> for label in selected.get("steps",[])]}</ol>
                    {<section className="review"><h3>{selected["review"]["title"]}</h3>
                        {<p>{"Destination: "+selected["review"]["destination"]}</p> if selected["review"].get("destination") else <span/>}
                        {[<p key={a["label"]}><strong>{a["label"]+": "}</strong>{a["value"]}</p> for a in selected["review"].get("answers",[])]}
                        {[<p key={d["name"]}><strong>{d["label"]+": "}</strong>{d["name"]}</p> for d in selected["review"].get("documents",[])]}
                        {<pre>{selected["review"]["diff"]}</pre> if selected["review"].get("diff") else <span/>}
                        {[<p key={c["id"]}><strong>{{"rewrite":"Reworded","omit":"Removed","reorder":"Reordered"}.get(c["kind"],c["kind"])+" · "+c["where"]+": "}</strong>{(c.get("before","")+" → " if c["kind"]!="omit" and c.get("before") else "")+(c.get("after","") or c.get("before",""))}</p> for c in selected["review"].get("changes",[])]}
                        {<p>{"Left out to fit one page: "+", ".join([d["text"] for d in selected["review"]["dropped"]])}</p> if selected["review"].get("dropped") else <span/>}
                        {<div><p>{"To: "+selected["review"].get("to","")}</p><label>Subject<input value={subject} onChange={lambda (e: any) { subject=e.target.value; }}/></label><label>Message<textarea value={body} onChange={lambda (e: any) { body=e.target.value; }}/></label></div> if selected["review"]["step"]=="send" else <span/>}
                        {<p>{selected["review"]["event"].get("summary","")+" · "+isoTime(selected["review"]["event"].get("start",""))+" – "+isoTime(selected["review"]["event"].get("end",""))}</p> if selected["review"]["step"]=="calendar" else <span/>}
                        {[<p key={n}>{n}</p> for n in selected["review"].get("notes",[])]}
                        <p><strong>{selected["review"]["consequence"]}</strong></p>
                        <button className="primary" disabled={busy or bool(selected["review"].get("blocked"))} onClick={approve}>Approve</button><button disabled={busy} onClick={lambda { act("agent_cancel",{"id":selected["id"]},"Cancelled. Nothing was shared."); }}>Cancel task</button>
                    </section> if selected["status"]=="review" else <span/>}
                    {<button disabled={busy} onClick={lambda { act("agent_retry",{"id":selected["id"]},"Retrying."); }}>Retry</button> if selected["status"] in ["blocked","failed"] else <span/>}
                    {<button disabled={busy} onClick={lambda { act("agent_dismiss",{"id":selected["id"]},"Dismissed."); }}>Dismiss</button> if selected["status"]=="failed" and not selected.get("dismissed") else <span/>}
                    <p>{"Where results appear: "+selected.get("results_where","")}</p>{[<label key={q["key"]}>{q["label"]}<input value={values.get(q["key"],"")} onChange={lambda (e: any) { updated={**values};updated[q["key"]]=e.target.value;values=updated; }}/></label> for q in selected.get("requests",[]) if q["key"]!="browser"]}
                    {<button onClick={respond}>{("Retry analysis" if selected.get("step")=="linkedin_review" else "Analyze my profile") if selected["kind"]=="linkedin" else "Save answers and resume"}</button> if selected["status"] in ["needs_input","blocked"] else <span/>}
                    {<div><button onClick={lambda { handoff({"type":"snapshot"}); }}>Open same browser session</button><BrowserView image={browser} onEvent={handoff} sessionId={selected["id"]} onFrame={lambda (value: any) { browser={**browser,**value}; }}/></div> if selected.get("browser",{}).get("available",False) else <span/>}
                    {<button disabled={busy} onClick={lambda { browser={};act("agent_cancel",{"id":selected["id"]},"Task cancelled."); }}>Cancel profile review</button> if selected["kind"]=="linkedin" and selected["status"] not in ["completed","cancelled","failed"] else <span/>}
                    {<div><label>Reconciliation evidence<textarea value={values.get("evidence","")} onChange={lambda (e: any) { values={**values,"evidence":e.target.value}; }}/></label><button onClick={lambda { reconcile("confirmed"); }}>I verified it completed</button><button onClick={lambda { reconcile("not_sent"); }}>I verified nothing was sent</button></div> if selected["status"]=="uncertain" else <span/>}
                    {[<article key={k}><h3>{k.title()}</h3><p>{v.get("summary",v.get("body",v.get("receipt","Artifact saved")))}</p>{[<p key={"s"+t}>{"✓ "+t}</p> for t in v.get("strengths",[])]}{[<p key={"g"+t}>{"~ "+t}</p> for t in v.get("gaps",[])]}{[<p key={"u"+t}>{"? "+t}</p> for t in v.get("unknowns",[])]}{[<p key={"e"+t}>{"• "+t}</p> for t in v.get("edits",[])]}{[<p key={"x"+t}>{"• "+t}</p> for t in v.get("suggested_edits",[])]}{[<section key={str(i)}><h4>{f["priority"].title()+" priority · "+f["section"].title()+": "+f["weakness"]}</h4><blockquote>{f["quote"]}</blockquote><p>{f["why_it_matters"]}</p><p>{f["recommendation"]}</p></section> for (i,f) in enumerate(v.get("findings",[]))]}
                        {[<section key={str(i)}><h4>{"Suggested "+r["section"]}</h4><p style={{whiteSpace:"pre-wrap"}}>{r["text"]}</p></section> for (i,r) in enumerate(v.get("rewrites",[]))]}
                        {[<p key={str(i)}>{"To strengthen this: "+q}</p> for (i,q) in enumerate(v.get("questions",[]))]}
                        {<p>{v["limitations"]+" Sections not read: "+", ".join(v.get("unread_sections",[]))}</p> if v.get("limitations") else <span/>}
                        <p>{v.get("suggested_headline","")}</p><p>{v.get("suggested_about","")}</p>{<button onClick={lambda { downloadPDF(v["pdf"]); }}>Download tailored PDF</button> if v.get("pdf") else <span/>}{<pre>{v["pdf"]["diff"]}</pre> if v.get("pdf") else <span/>}</article> for (k,v) in selected.get("artifacts",{}).items()]}
                    <button onClick={exportTrace}>Download execution trace</button>
                    {<AgentFeedback key={selected["id"]+selected["output_version"]} runId={selected["id"]} outputVersion={selected["output_version"]}/> if selected.get("artifacts") and selected.get("output_version") else <span/>}
                    {[<p key={f["id"]}><strong>{"Your feedback · "+f["rating"].title()+": "}</strong>{f["note"]}</p> for f in selected.get("feedback",[])]}
                </article> if len(selected)>0 else <div/>}
            </section> if page=="Activity" else <div/>}
            {<section><h2>Agent features</h2>{[<article key={f["key"]}><strong>{f["title"]+" · "+{"ready":"Ready","setup":"Needs setup","unavailable":"Unavailable"}.get(f["state"],f["state"])}</strong><p>{f["summary"]}</p><p>{"Your control: "+f["review"]}</p>{[<p key={c["key"]}>{"✕ "+c["label"]+" — "+c["fix"]}</p> for c in f["checks"] if not c["ok"] and not c["optional"]]}{<p>{"Meanwhile: "+f["alternative"]}</p> if f["state"]!="ready" else <span/>}</article> for f in features]}</section> if page=="Features" else <div/>}
            {<section><h2>Your account</h2><p>{"Account ID: "+settings.get("account_id","")}</p><p>Use this ID when binding your own local Codex or Claude login.</p><p>{"Model provider: "+activity.get("model_provider",{}).get("provider","Not configured")}</p><p>{activity.get("model_provider",{}).get("message","")}</p><p>CLI providers use your subscription request cap; they never fall back to a paid API.</p><p>{"Model permission: "+("enabled until "+isoTime(settings["policy"]["expires_at"]) if settings.get("policy",{}).get("enabled",False) and "model" in settings.get("policy",{}).get("actions",[]) and settings.get("policy",{}).get("expires_at",0)>Date.now()/1000 else "disabled or expired")}</p><button disabled={busy} onClick={lambda { modelPermission(True); }}>Enable Model for up to 24 hours</button><button disabled={busy} onClick={lambda { modelPermission(False); }}>Revoke Model</button><p>Existing active permissions keep their earlier expiry. If other permissions are disabled, expired, or last longer than 24 hours, manage them in the iPhone app first. Model requests still require your explicit action; email and calendar actions keep their own approval controls.</p><p>Manage other standing permissions and confirmed facts in the iPhone app.</p><button onClick={exportData}>Export account data</button><label>Confirm password to delete account<input type="password" value={deletePassword} onChange={lambda (e: any) { deletePassword=e.target.value; }}/></label><button onClick={deleteAccount}>Delete my account and data</button><p>API providers require separately configured credentials and budgets. Local subscription providers require the account binding, CLI login, and Model permission.</p></section> if page=="Account" else <div/>}
        </div> if logged else <div/>}
    </main>
}
