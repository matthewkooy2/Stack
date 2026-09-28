import from "./transport.js" { rpc, login, logout, errorText, oauthResult, downloadJSON, downloadPDF, Timer, Diagram, BrowserView, Recorder, LiveInterview, confirmAccountDelete }
import "./style.css";

def:pub app -> JsxElement {
    has logged: bool = False, username: str = "", password: str = "", invite: str = "", error: str = "", notice: str = "",
        signup: bool = False, busy: bool = False, page: str = "Practice", problems: list[dict[str, any]] = [], sessions: list[dict[str, any]] = [],
        current: dict[str, any] = {}, data: dict[str, any] = {}, activity: dict[str, any] = {}, selected: dict[str, any] = {}, browser: dict[str, any] = {},
        values: dict[str, str] = {}, oauth: dict[str, any] = {}, settings: dict[str, any] = {}, mail: list[dict[str, any]] = [], interviews: list[dict[str, any]] = [], applications: list[dict[str, any]] = [], mailSelected: dict[str, any] = {}, eventApplication: str = "", eventStatus: str = "", deletePassword: str = "";
    can with entry { oauth=oauthResult(); }
    async def refresh -> None {
        settings=await rpc("agent_settings",{});activity=settings["activity"];
        result=await rpc("prep_catalog",{});problems=result["problems"];
        result=await rpc("prep_sessions",{});sessions=result["sessions"];
        result=await rpc("agent_events",{});mail=result["events"];interviews=result["interviews"];
        result=await rpc("bootstrap",{});applications=[a for a in result["applications"] if not a["demo"]];
    }
    async def signin -> None {
        busy=True;error="";
        try {
            await login(username,password,signup);password="";
            if invite { await rpc("agent_accept_invite",{"invite":invite}); }
            if oauth.get("code") { await rpc("agent_google_finish",oauth);oauth={};notice="Google connected."; }
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
        try { selected=await rpc("agent_run",{"id":id});values={};browser={}; }
        except Exception as e { error=errorText(e); }
    }
    async def handoff(event: dict[str, any]) -> None {
        try { browser=await rpc("agent_browser",{"id":selected["id"],"event":event}); }
        except Exception as e { error=errorText(e); }
    }
    async def respond -> None {
        try { selected=await rpc("agent_respond",{"id":selected["id"],"values":[{"key":k,"value":v,"verified":True,"source":"User confirmed"} for (k,v) in values.items() if v.strip()],"reuse":True});await refresh(); }
        except Exception as e { error=errorText(e); }
    }
    async def reconcile(outcome: str) -> None {
        try { selected=await rpc("agent_reconcile",{"id":selected["id"],"outcome":outcome,"evidence":values.get("evidence","")});await refresh(); }
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
    async def deleteAccount -> None {
        if not confirmAccountDelete() { return; }
        try { await rpc("account_delete",{"username":username,"password":deletePassword});logout();logged=False;deletePassword="";notice="Your account and active data were deleted."; }
        except Exception as e { error=errorText(e); }
    }
    <main>
        <header><div><span className="brand">stack</span><h1>Your next chapter, in motion.</h1><p>Practice deeply. Let your agents handle the follow-through.</p></div>{<button onClick={lambda { logout();logged=False;current={};selected={};settings={};data={}; }}>Sign out</button> if logged else <span>Private beta</span>}</header>
        {<p className="error" role="alert">{error}</p> if error else <div/>}{<p className="notice">{notice}</p> if notice else <div/>}
        {<section className="login"><h2>{"Join Stack" if signup else "Welcome back"}</h2><label>Username<input value={username} onChange={lambda (e: any) { username=e.target.value; }}/></label><label>Password<input type="password" value={password} onChange={lambda (e: any) { password=e.target.value; }}/></label><label>Invitation (first visit)<input value={invite} onChange={lambda (e: any) { invite=e.target.value; }}/></label><button className="primary" disabled={busy} onClick={signin}>Continue</button><button onClick={lambda { signup=not signup; }}>{"I already have an account" if signup else "Create an account"}</button></section> if not logged else <div/>}
        {<div>
            <nav>{[<button key={p} className={"active" if page==p else ""} onClick={lambda { page=p; }}>{p}</button> for p in ["Practice","Activity","Account"]]}<button onClick={refresh}>Refresh</button></nav>
            {<div className="workspace"><aside><h2>Practice library</h2>{[<article key={p["id"]}><strong>{p["title"]}</strong><p>{p["topic"]+" · "+str(p["minutes"])+" minutes"}</p>{[<button key={lang} onClick={lambda { create(p["id"],lang); }}>{"C++" if lang=="cpp" else lang.upper()}</button> for lang in p["languages"]]}{<button onClick={lambda { create(p["id"],""); }}>Start</button> if len(p["languages"])==0 else <span/>}</article> for p in problems]}<h2>Continue</h2>{[<button key={p["id"]} onClick={lambda { openSession(p["id"]); }}>{p["data"]["problem_id"]}</button> for p in sessions]}</aside>
                <section>{<div><div className="toolbar"><Timer key={current["id"]} seconds={data.get("elapsed_seconds",0)} onChange={lambda (v: int) { data={**data,"elapsed_seconds":v}; }}/><button disabled={busy} onClick={lambda { save(); }}>Save</button><button onClick={lambda { openSession(current["id"]); }}>Refresh results</button></div>
                    {[<article key={p["id"]}><h2>{p["title"]}</h2><p>{p["prompt"]}</p><details><summary>Hints</summary>{[<p key={hint}>{hint}</p> for hint in p["hints"]]}</details></article> for p in problems if p["id"]==data["problem_id"]]}
                    <label>Your reasoning<textarea value={data["answer"]} onChange={lambda (e: any) { data={**data,"answer":e.target.value}; }}/></label>
                    {<label>{data["language"].upper()+" editor"}<textarea className="code" spellCheck={False} value={data["code"]} onChange={lambda (e: any) { data={**data,"code":e.target.value}; }}/></label> if data["language"] else <Diagram value={data["canvas"]} onChange={lambda (v: dict[str, any]) { data={**data,"canvas":v}; }}/>}
                    <div className="toolbar">{<button disabled={busy} onClick={lambda { save("code"); }}>Run tests</button> if data["language"] else <span/>}<button className="primary" disabled={busy} onClick={lambda { save("prep"); }}>Get coaching</button></div>
                    <Recorder onTranscript={lambda (text: str) { data={**data,"transcript":text}; }}/><label>Review your transcript<textarea value={data["transcript"]} onChange={lambda (e: any) { data={**data,"transcript":e.target.value}; }}/></label><LiveInterview sessionId={current["id"]} onTranscript={lambda (text: str) { data={**data,"transcript":text}; }}/>
                    {[<article key={str(r["at"])}><h3>{"Tests: "+str(r["data"].get("passed",0))+" / "+str(r["data"].get("total",0))}</h3><pre>{r["data"].get("error","")}</pre><p>{"Attempt revision "+str(r["revision"])}</p></article> for r in current["results"]]}
                    {[<article key={str(f["at"])}><h3>Coaching</h3><p>{f["data"]["summary"]}</p>{[<p key={row["criterion"]}><strong>{row["criterion"]+" · "+str(row["score"])+"/4"}</strong>{" — "+row["feedback"]}</p> for row in f["data"].get("rubric",[])]}{[<p key={q}>{q}</p> for q in f["data"].get("followup_questions",[])]}</article> for f in current["feedback"]]}
                </div> if len(current)>0 else <article><h2>Choose a session.</h2><p>Start on your phone or here. Your answers, code, and feedback stay together.</p></article>}</section>
            </div> if page=="Practice" else <div/>}
            {<section><h2>Messages needing review</h2>{[<article key={e["id"]}><strong>{e["subject"]}</strong><p>{e["excerpt"]}</p><button onClick={lambda { mailSelected=e;eventApplication=e.get("application_id","");eventStatus=e.get("status",""); }}>Associate this message</button></article> for e in mail if e.get("ambiguous")]}
                {<article><h3>Confirm the message outcome</h3><label>Application<select value={eventApplication} onChange={lambda (e: any) { eventApplication=e.target.value; }}><option value="">Choose an application</option>{[<option key={a["id"]} value={a["id"]}>{a["job"]["company"]+" · "+a["job"]["title"]}</option> for a in applications]}</select></label><label>Confirmed status<select value={eventStatus} onChange={lambda (e: any) { eventStatus=e.target.value; }}><option value="">Choose a status</option>{[<option key={s} value={s}>{s}</option> for s in ["Submitted","Assessment","Interview","Rejected"]]}</select></label><button onClick={resolveMail}>Save association</button></article> if len(mailSelected)>0 else <span/>}
                <h2>Upcoming interviews and practice</h2>{[<article key={i["id"]}><h3>{i.get("summary","Interview")}</h3><p>{i.get("start",{}).get("dateTime","")}</p>{[<button key={q["session_id"]} onClick={lambda { openSession(q["session_id"]); }}>{q["problem_id"]+" · "+q["reason"]}</button> for q in i.get("study_plan",[])]}</article> for i in interviews]}
                <h2>Agent activity</h2>{[<article key={r["id"]}><strong>{r["kind"].title()+" · "+r["status"].replace("_"," ")}</strong><p>{r["message"]}</p><button onClick={lambda { openRun(r["id"]); }}>Open task</button></article> for r in activity.get("runs",[])]}
                {<article><h2>{selected["message"]}</h2>{[<label key={q["key"]}>{q["label"]}<input value={values.get(q["key"],"")} onChange={lambda (e: any) { updated={**values};updated[q["key"]]=e.target.value;values=updated; }}/></label> for q in selected.get("requests",[]) if q["key"]!="browser"]}
                    {<button onClick={respond}>Save answers and resume</button> if selected["status"] in ["needs_input","blocked"] else <span/>}
                    <button onClick={lambda { handoff({"type":"snapshot"}); }}>Open same browser session</button><BrowserView image={browser} onEvent={handoff}/>
                    {<div><label>Reconciliation evidence<textarea value={values.get("evidence","")} onChange={lambda (e: any) { values={**values,"evidence":e.target.value}; }}/></label><button onClick={lambda { reconcile("confirmed"); }}>I verified it completed</button><button onClick={lambda { reconcile("not_sent"); }}>I verified nothing was sent</button></div> if selected["status"]=="uncertain" else <span/>}
                    {[<article key={k}><h3>{k.title()}</h3><p>{v.get("summary",v.get("body",v.get("receipt","Artifact saved")))}</p>{[<p key={t}>{t}</p> for t in v.get("strengths",[])+v.get("gaps",[])+v.get("unknowns",[])+v.get("edits",[])]}<p>{v.get("suggested_headline","")}</p><p>{v.get("suggested_about","")}</p>{<button onClick={lambda { downloadPDF(v["pdf"]); }}>Download tailored PDF</button> if v.get("pdf") else <span/>}{<pre>{v["pdf"]["diff"]}</pre> if v.get("pdf") else <span/>}</article> for (k,v) in selected.get("artifacts",{}).items()]}
                </article> if len(selected)>0 else <div/>}
            </section> if page=="Activity" else <div/>}
            {<section><h2>Your account</h2><p>Manage standing permissions and confirmed facts in the iPhone app.</p><button onClick={exportData}>Export account data</button><label>Confirm password to delete account<input type="password" value={deletePassword} onChange={lambda (e: any) { deletePassword=e.target.value; }}/></label><button onClick={deleteAccount}>Delete my account and data</button><p>Paid execution remains disabled until the operator configures a shared budget.</p></section> if page=="Account" else <div/>}
        </div> if logged else <div/>}
    </main>
}
