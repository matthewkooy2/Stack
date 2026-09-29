import from "@jac/mobui" { View, Text, Switch }
import from "../device.js" { rpc, errorText, openJobLink, dateTime }
import from ..theme { s }
import from .UI { Button, Field, Chip }
import from .Feedback { AgentFeedback }

def:pub AgentLaunch(target: str) -> JsxElement {
    has message: str = "", busy: bool = False;
    async def start(kind: str) -> None {
        busy=True;
        try { result=await rpc("agent_start",{"kind":kind,"target_id":target});message=result["message"]+" · Open Agent activity to follow progress."; }
        except Exception as e { message=errorText(e); }
        busy=False;
    }
    async def makePlan -> None {
        try { result=await rpc("prep_for_application",{"application_id":target});message="Your interview plan is ready in Prep: "+str(len(result["plan"]))+" exercises."; }
        except Exception as e { message=errorText(e); }
    }
    <View style={{gap:10}}><Text style={s.heading}>Let Stack help.</Text><View style={s.wrap}>
        <Button label="Prepare and apply" disabled={busy} onPress={lambda { start("application"); }}/>
        <Button label="Explain my fit" secondary={True} disabled={busy} onPress={lambda { start("jobs"); }}/>
        <Button label="Build interview plan" secondary={True} onPress={makePlan}/><Button label="Tailor my resume" secondary={True} disabled={busy} onPress={lambda { start("resume"); }}/>
    </View>{<Text style={s.small}>{message}</Text> if message else <View/>}</View>
}

def:pub AgentHub(initial: str = "Activity", resumes: list[dict[str, any]] = [], onReviewResume: any = None) -> JsxElement {
    has page: str = initial, settings: dict[str, any] = {}, activity: dict[str, any] = {},
        selected: dict[str, any] = {}, contacts: list[dict[str, any]] = [], values: dict[str, str] = {},
        error: str = "", busy: bool = False, enabled: bool = False, actions: list[str] = [], domains: str = "",
        daily: str = "5", followups: str = "0", name: str = "", email: str = "", company: str = "", relationship: str = "",
        factKey: str = "", factValue: str = "", sourceURL: str = "", contactImport: str = "", analyzeTop: bool = False;
    async def reload -> None {
        busy=True;error="";
        try {
            settings=await rpc("agent_settings",{});activity=settings["activity"];
            policy=settings["policy"];enabled=policy["enabled"];actions=policy["actions"];domains=", ".join(policy["domains"]);followups=str(policy["followup_limit"]);analyzeTop=policy.get("analyze_top_matches",False);
            data=await rpc("agent_contacts",{});contacts=data["contacts"];
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async can with entry { await reload(); }
    async def perform(endpoint: str, args: dict[str, any]) -> None {
        busy=True;error="";
        try { result=await rpc(endpoint,args);await reload(); }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def openRun(id: str) -> None {
        busy=True;error="";
        try { selected=await rpc("agent_run",{"id":id});values={}; }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def respond -> None {
        await perform("agent_respond",{"id":selected["id"],"values":[{"key":k,"value":v,"verified":True,"source":"User confirmed application answer"} for (k,v) in values.items() if v.strip()],"reuse":True});
        await openRun(selected["id"]);
    }
    async def connect(capabilities: list[str]) -> None {
        try { result=await rpc("agent_google_start",{"capabilities":capabilities});await openJobLink(result["url"]); }
        except Exception as e { error=errorText(e); }
    }
    async def savePolicy -> None {
        try {
            limit=int(daily);count=int(followups);
            await perform("agent_save_policy",{"policy":{"enabled":enabled,"actions":actions,"domains":[d.strip().lower() for d in domains.split(",") if d.strip()],"daily_limits":{"browser_fill":limit,"submit_application":limit,"send_email":limit,"calendar_write":limit},"expires_at":Date.now()/1000+30*86400,"followup_limit":count,"followup_days":7,"analyze_top_matches":analyzeTop}});
        } except Exception { error="Enter valid daily and follow-up limits."; }
    }
    <View style={{gap:16}}>
        <Text style={s.title}>Your agents.</Text><Text style={s.body}>Set your rules once. Keep the work moving.</Text>
        <View style={s.wrap}>{[<Chip key={p} label={p} active={page==p} onPress={lambda { page=p;selected={}; }}/> for p in ["Activity","Rules","Facts","Contacts"]]}</View>
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
        <Button label="Refresh agents" onPress={reload} secondary={True} disabled={busy}/>
        <View style={s.mutedBox}><Text style={s.strong}>{"Model provider: "+activity.get("model_provider",{}).get("provider","Not configured")}</Text><Text style={s.small}>{activity.get("model_provider",{}).get("message","Model provider configuration is unavailable.")}</Text></View>
        {<View style={{gap:12}}>
            {[<View key={r["id"]} style={s.card}><Text style={s.heading}>{r["kind"].title()+" · "+r["status"].replace("_"," ")}</Text><Text style={s.body}>{r["message"]}</Text><Text style={s.small}>{"Reserved API spend: $"+str(r["cost_cents"]/100)}</Text>{<Text style={s.small}>{"Subscription requests: "+str(r["subscription_calls"])+" · Provider limits apply"}</Text> if r.get("subscription_calls",0)>0 else <View/>}<Button label="View agent task" secondary={True} onPress={lambda { openRun(r["id"]); }}/></View> for r in activity.get("runs",[])]}
            {<View style={s.card}><Text style={s.heading}>{selected["message"]}</Text>
                {[<Field key={q["key"]} label={q["label"]} value={values.get(q["key"],"")} onChange={lambda (v: str) { updated={**values};updated[q["key"]]=v;values=updated; }}/> for q in selected.get("requests",[]) if q["key"]!="browser"]}
                {<Button label="Save answers and resume" disabled={busy} onPress={respond}/> if selected["status"] in ["needs_input","blocked"] else <View/>}
                {<Button label="Open workspace for browser handoff" secondary={True} onPress={lambda { openJobLink(settings["web_url"]); }}/> if settings.get("web_url") else <Text style={s.small}>Browser handoff appears in the web workspace when hosting is configured.</Text>}
                {[<View key={k} style={s.hero}><Text style={s.strong}>{k.title()}</Text><Text style={s.body}>{v.get("summary",v.get("body",v.get("receipt","Saved artifact")))}</Text>{[<Text key={text} style={s.body}>{text}</Text> for text in v.get("strengths",[])+v.get("gaps",[])+v.get("unknowns",[])+v.get("edits",[])]}<Text style={s.body}>{v.get("suggested_headline","")}</Text><Text style={s.body}>{v.get("suggested_about","")}</Text>{[<Text key={e["quote"]} style={s.small}>{"“"+e["quote"]+"”"}</Text> for e in v.get("evidence",[])]}</View> for (k,v) in selected.get("artifacts",{}).items()]}
                {<AgentFeedback key={selected["id"]+selected["output_version"]} runId={selected["id"]} outputVersion={selected["output_version"]}/> if selected.get("artifacts") and selected.get("output_version") else <View/>}
                {[<View key={f["id"]}><Text style={s.strong}>{"Your feedback · "+f["rating"].title()}</Text><Text style={s.body}>{f["note"]}</Text></View> for f in selected.get("feedback",[])]}
                <Button label="Cancel agent task" secondary={True} disabled={busy} onPress={lambda { perform("agent_cancel",{"id":selected["id"]}); }}/>
            </View> if len(selected)>0 else <View/>}
        </View> if page=="Activity" else <View/>}
        {<View style={{gap:14}}>
            <Text style={s.small}>{"Account ID: "+settings.get("account_id","")}</Text>
            <View style={s.between}><Text style={s.strong}>Enable standing permissions</Text><Switch value={enabled} onValueChange={lambda (v: bool) { enabled=v; }}/></View>
            <Text style={s.body}>A right swipe may start an application when these rules are enabled. Stack may share your confirmed answers and resume with the selected employer. Missing answers still come back to you.</Text>
            {[<Chip key={a} label={a.replace("_"," ").title()} active={a in actions} onPress={lambda { actions=[x for x in actions if x!=a] if a in actions else actions+[a]; }}/> for a in ["model","browser_fill","submit_application","gmail_read","send_email","calendar_write"]]}
            <View style={s.between}><Text style={s.strong}>Analyze up to three top matches daily</Text><Switch value={analyzeTop} onValueChange={lambda (v: bool) { analyzeTop=v; }}/></View><Field label="Allowed destination domains" value={domains} onChange={lambda (v: str) { domains=v; }} placeholder="jobs.lever.co, job-boards.greenhouse.io" multiline={True}/>
            <Field label="Daily limit per action" value={daily} onChange={lambda (v: str) { daily=v; }}/><Field label="Follow-ups per contact (0–3)" value={followups} onChange={lambda (v: str) { followups=v; }}/>
            <Text style={s.small}>Permissions expire after 30 days. Follow-ups are spaced seven days apart and stop when a reply arrives.</Text>
            <Button label="Save standing permissions" onPress={savePolicy} disabled={busy}/>
            <Button label="Connect Gmail tracking" onPress={lambda { connect(["read"]); }} secondary={True}/><Button label="Enable Gmail outreach" onPress={lambda { connect(["send"]); }} secondary={True}/><Button label="Connect Google Calendar" onPress={lambda { connect(["calendar","availability"]); }} secondary={True}/><Text style={s.small}>Gmail access can read your mailbox. Stack processes messages related to your applications and selected contacts.</Text>
            {[<View key={c["id"]} style={s.card}><Text style={s.strong}>{c["provider"].title()+" · "+c["state"]}</Text><Button label="Disconnect" onPress={lambda { perform("agent_disconnect",{"id":c["id"]}); }} secondary={True}/></View> for c in settings.get("connections",[])]}
        </View> if page=="Rules" else <View/>}
        {<View style={{gap:12}}><Text style={s.body}>Only confirmed facts are reused. Review extracted resume text before confirming it.</Text>
            {[<View key={r["id"]} style={s.card}><Text style={s.strong}>{r["name"]}</Text><Button label="Review resume details" secondary={True} disabled={onReviewResume is None} onPress={lambda { onReviewResume(r["id"]); }}/></View> for r in resumes]}
            {[<View key={f["key"]} style={s.card}><Text style={s.strong}>{f["key"].replace("_"," ").title()}</Text><Text style={s.body}>{f["value"]}</Text><Text style={s.small}>{f["source"]}</Text>{<Button label="Confirm this fact" secondary={True} onPress={lambda { perform("agent_save_facts",{"facts":[{**f,"verified":True}]}); }}/> if not f["verified"] else <Chip label="Confirmed" active={True}/>}</View> for f in settings.get("facts",[]) if not f.get("resume_id")]}
            <Button label="Review my professional profile" secondary={True} onPress={lambda { perform("agent_start",{"kind":"profile","target_id":"self"}); }}/><Field label="Fact name" value={factKey} onChange={lambda (v: str) { factKey=v; }} placeholder="email, phone, name, resume.project"/>
            <Field label="Your answer" value={factValue} onChange={lambda (v: str) { factValue=v; }} multiline={True}/>
            <Button label="Save confirmed fact" disabled={busy} onPress={lambda { perform("agent_save_facts",{"facts":[{"key":factKey,"value":factValue,"verified":True,"source":"User confirmed"}]}); }}/>
        </View> if page=="Facts" else <View/>}
        {<View style={{gap:12}}><Field label="Import contacts or pasted profile text" value={contactImport} onChange={lambda (v: str) { contactImport=v; }} multiline={True}/><Button label="Import contact suggestions" secondary={True} onPress={lambda { perform("agent_import_contacts",{"content":contactImport}); }}/><Text style={s.body}>Add people you know or have researched. Selecting a contact allows outreach within your standing rules.</Text>
            <Field label="Contact name" value={name} onChange={lambda (v: str) { name=v; }}/><Field label="Verified email" value={email} onChange={lambda (v: str) { email=v; }}/><Field label="Company" value={company} onChange={lambda (v: str) { company=v; }}/><Field label="Relationship or source" value={relationship} onChange={lambda (v: str) { relationship=v; }} multiline={True}/>
            <Field label="Public research source (optional)" value={sourceURL} onChange={lambda (v: str) { sourceURL=v; }} placeholder="https://company.com/team"/><Button label="Save selected contact" disabled={busy} onPress={lambda { perform("agent_save_contact",{"data":{"name":name,"email":email,"company":company,"relationship":relationship,"source":"User supplied","source_url":sourceURL,"selected":True}}); }}/>
            {[<View key={c["id"]} style={s.card}><Text style={s.heading}>{c["name"]}</Text><Text style={s.body}>{c["email"]}</Text><Text style={s.small}>{c["relationship"]}</Text>{<Button label="Select this contact" secondary={True} onPress={lambda { perform("agent_save_contact",{"id":c["id"],"data":{**c,"selected":True}}); }}/> if not c["selected"] else <View/>}<Button label="Start outreach" disabled={busy or c["stopped"] or not c["selected"]} onPress={lambda { perform("agent_start",{"kind":"network","target_id":c["id"]}); }}/><Button label="Stop outreach" secondary={True} onPress={lambda { perform("agent_stop_contact",{"id":c["id"]}); }}/></View> for c in contacts]}
        </View> if page=="Contacts" else <View/>}
    </View>
}
