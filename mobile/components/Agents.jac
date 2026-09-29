import from "@jac/mobui" { View, Text, Switch, Pressable }
import from "../device.js" { rpc, errorText, openJobLink, dateTime, isoTime, Icon, Lifecycle, previewDocument, PDFView, pickLatexSource }
import from ..theme { s }
import from .UI { Button, Field, Chip }
import from .ResumeFormat { LatexSetup }

"""Unsent answers and email edits survive refreshes and closing a task (per session)."""
glob DRAFTS: dict[str, any] = {};
glob STATUS_LABELS: dict[str, str] = {"queued":"Queued","running":"Working","waiting":"Ready","needs_input":"Needs your answers","blocked":"Paused · setup","review":"Needs your review","uncertain":"Confirm what happened","failed":"Stopped","completed":"Done","cancelled":"Cancelled"};
glob STATE_LABELS: dict[str, str] = {"ready":"Ready","setup":"Needs setup","unavailable":"Unavailable"};
glob APPROVE_LABELS: dict[str, str] = {"approve_resume":"Apply the changes I kept","fill":"Approve sharing these answers","submit":"Approve submission","send":"Approve and send","calendar":"Approve calendar change"};
glob TERMINAL: list[str] = ["completed","cancelled","failed"];
glob CHANGE_LABELS: dict[str, str] = {"rewrite":"Reworded","omit":"Removed","reorder":"Reordered"};
glob ATTENTION: list[str] = ["needs_input","blocked","review","uncertain","failed"];
glob ACTIVE: list[str] = ["queued","running","waiting"];

def:pub statusLabel(status: str) -> str { return STATUS_LABELS.get(status,status); }
"""A task paused for its resume's LaTeX is not waiting for answers; say what it needs."""
def:pub runLabel(run: dict[str, any]) -> str {
    if run.get("needs_resume_review") { return "Needs your LaTeX"; }
    # Stopped with a message but nothing to answer: it needs a retry, not answers.
    if run["status"]=="needs_input" and not run.get("has_requests",True) { return "Stopped · try again"; }
    return statusLabel(run["status"]);
}
def:pub stateLabel(state: str) -> str { return STATE_LABELS.get(state,state); }
def:pub toneFor(status: str) -> dict[str, str] {
    if status in ATTENTION { return {"bg":"#FFF1E3","fg":"#A4540F"}; }
    if status in ACTIVE { return {"bg":"#E7EEFF","fg":"#3765E8"}; }
    if status=="completed" { return {"bg":"#E4F5EF","fg":"#167867"}; }
    return {"bg":"#EEF1F7","fg":"#66768D"};
}
def:pub stateTone(state: str) -> dict[str, str] {
    if state=="ready" { return {"bg":"#E4F5EF","fg":"#167867"}; }
    if state=="setup" { return {"bg":"#FFF1E3","fg":"#A4540F"}; }
    return {"bg":"#EEF1F7","fg":"#66768D"};
}
def:pub featureFor(features: list[dict[str, any]], kind: str) -> dict[str, any] {
    for f in features { if kind in f["kinds"] { return f; } }
    return {};
}
def:pub featureByKey(features: list[dict[str, any]], key: str) -> dict[str, any] {
    for f in features { if f["key"]==key { return f; } }
    return {};
}
def:pub runsFor(runs: list[dict[str, any]], target: str, kinds: list[str]) -> list[dict[str, any]] {
    return [r for r in runs if r["target_id"]==target and r["kind"] in kinds];
}
"""Copy of a dict with one key set. Computed keys inside dict literals do not compile to valid JS."""
def:pub withKey(d: dict[str, any], key: str, value: any) -> dict[str, any] {
    updated={**d};updated[key]=value;return updated;
}
def:pub missingChecks(feature: dict[str, any]) -> list[dict[str, any]] {
    return [c for c in feature.get("checks",[]) if not c["ok"]];
}

def:pub Pill(label: str, tone: dict[str, str]) -> JsxElement {
    <View style={[s.pill,{backgroundColor:tone["bg"]}]}><Text style={[s.pillText,{color:tone["fg"]}]}>{label}</Text></View>
}
def:pub StatusPill(status: str, label: str = "") -> JsxElement { <Pill label={label or statusLabel(status)} tone={toneFor(status)}/> }

"""Persistent header entry: running and needs-you counts from the polled bootstrap summary."""
def:pub AgentBadge(summary: dict[str, any], onPress: any) -> JsxElement {
    active=summary.get("active",0);attention=summary.get("attention",0);
    <Pressable accessibilityRole="button" accessibilityLabel={"Agents: "+str(active)+" active, "+str(attention)+" need you"} onPress={onPress} style={s.agentBadge}>
        <Icon name="sparkles" size={17} color="#3765E8"/><Text style={s.agentBadgeText}>Agents</Text>
        {<View style={[s.countPill,{backgroundColor:"#E7EEFF"}]}><Icon name="clock" size={12} color="#3765E8"/><Text style={[s.countText,{color:"#3765E8"}]}>{str(active)}</Text></View> if active>0 else <View/>}
        {<View style={[s.countPill,{backgroundColor:"#FFE7D1"}]}><Icon name="alert" size={12} color="#A4540F"/><Text style={[s.countText,{color:"#A4540F"}]}>{str(attention)}</Text></View> if attention>0 else <View/>}
    </Pressable>
}

def:pub TaskRow(run: dict[str, any], onOpen: any) -> JsxElement {
    <Pressable accessibilityRole="button" accessibilityLabel={"Open task "+run["title"]+" · "+runLabel(run)} onPress={onOpen} style={s.taskCard}>
        <View style={s.between}><Text style={[s.strong,{flex:1}]}>{run["title"]}</Text><StatusPill status={run["status"]} label={runLabel(run)}/></View>
        {<Text style={s.small}>{run["context_label"]}</Text> if run.get("context_label") else <View/>}
        <Text style={s.small}>{("Step "+str(run["step_number"])+" of "+str(run["step_total"])+" · " if run["step_total"]>1 else "")+run["step_label"]}</Text>
        <Text style={s.body}>{run["explanation"]}</Text>
        {<Text style={s.small}>{run["message"]}</Text> if run["attention"] and run["message"] else <View/>}
        <View style={s.between}><Text style={s.small}>{"Updated "+dateTime(run["updated_at"] or run["created_at"])}</Text><Text style={[s.small,{color:"#3765E8",fontWeight:"700"}]}>{"Review" if run["next_action"]=="review" else ("Respond" if run["attention"] else "Details")}</Text></View>
    </Pressable>
}

def:pub FeatureCard(feature: dict[str, any], onNavigate: any, compact: bool = False) -> JsxElement {
    <View style={s.taskCard}>
        <View style={s.between}><Text style={[s.strong,{flex:1}]}>{feature["title"]}</Text><Pill label={stateLabel(str(feature["state"]))+(" · limited" if feature.get("limited") else "")} tone={stateTone(feature["state"])}/></View>
        <Text style={s.body}>{feature["summary"]}</Text>
        {<View style={{gap:6}}>
            <Text style={s.small}>{"Needs: "+feature["input"]}</Text>
            <Text style={s.small}>{"Your control: "+feature["review"]}</Text>
            <Text style={s.small}>{"Start from: "+feature["where"]}</Text>
        </View> if not compact else <View/>}
        {[<View key={c["key"]} style={{gap:4}}>
            <Text style={[s.small,{color:"#167867" if c["ok"] else ("#8290A4" if c["optional"] else "#A4540F")}]}>{("✓ " if c["ok"] else ("○ " if c["optional"] else "✕ "))+c["label"]+(" (optional)" if c["optional"] and not c["ok"] else "")}</Text>
            {<Text style={s.small}>{c["fix"]}</Text> if not c["ok"] else <View/>}
            {<Chip label={"Fix: "+c["label"]} onPress={lambda { onNavigate(c["action"]); }}/> if not c["ok"] and c["action"] else <View/>}
        </View> for c in feature["checks"] if not compact or not c["ok"]]}
        {<View style={s.mutedBox}><Text style={s.small}>{"Meanwhile: "+feature["alternative"]}</Text></View> if feature["state"]!="ready" else <View/>}
    </View>
}

def StepList(run: dict[str, any]) -> JsxElement {
    <View style={{gap:4}}>{[<Text key={str(i)} style={[s.small,{color:"#172337" if i==run["step_number"]-1 else "#8290A4",fontWeight:"700" if i==run["step_number"]-1 else "400"}]}>{("✓ " if i<run["step_number"]-1 or run["status"]=="completed" else ("● " if i==run["step_number"]-1 else "○ "))+label}</Text> for (i,label) in enumerate(run["steps"])]}</View>
}

"""One proposed resume change. onToggle is None outside the review, where the choice is only shown."""
def ChangeRow(change: dict[str, any], rejected: bool, onToggle: any = None) -> JsxElement {
    kind=change.get("kind","");
    <View style={[s.actionRow,{opacity:0.55 if rejected else 1}]}>
        <View style={s.between}>
            <Text style={[s.small,{flex:1,fontWeight:"700"}]}>{CHANGE_LABELS.get(kind,kind)+" · "+change.get("where","")}</Text>
            {<Chip label={"Keep this" if rejected else "Reject"} active={rejected} onPress={onToggle}/> if onToggle is not None else <View/>}
        </View>
        {<Text style={[s.small,{textDecorationLine:"line-through"}]}>{change["before"].replace("**","")}</Text> if kind!="reorder" and change.get("before") else <View/>}
        {<Text style={s.small}>{"Was: "+change["before"]}</Text> if kind=="reorder" and change.get("before") else <View/>}
        {<Text style={s.body}>{("Now: " if kind=="reorder" and change.get("before") else "")+change["after"].replace("**","")}</Text> if change.get("after") else <View/>}
        {<Text style={s.small}>{"Why: "+change["reason"]}</Text> if change.get("reason") else <View/>}
        {<Text style={[s.small,{color:"#A4540F"}]}>Rejected · your original stays</Text> if rejected and onToggle is None else <View/>}
    </View>
}

def DroppedList(dropped: list[dict[str, any]]) -> JsxElement {
    <View style={{gap:6}}>
        <Text style={s.label}>LEFT OUT TO FIT ONE PAGE · LEAST RELEVANT FIRST</Text>
        {[<Text key={d["id"]} style={s.small}>{"• "+d["where"]+": "+d["text"].replace("**","")}</Text> for d in dropped]}
    </View>
}

def TailoredResumeResult(value: dict[str, any], onPreview: any) -> JsxElement {
    has comparison: str = "Changes";
    pdf=value.get("pdf",{});changes=value.get("changes",[]);rejected=value.get("rejected",[]);legacy="changes" not in value;
    <View style={{gap:14}}>
        <Text style={s.heading}>{"Your tailored resume" if value.get("final") or legacy else "Proposed tailored resume"}</Text>
        {<Text style={s.small}>Waiting for your review: keep or reject each change, then Stack rebuilds the PDF.</Text> if not value.get("final") and not legacy else <View/>}
        {<Button label={"Preview tailored resume" if value.get("final") or legacy else "Preview proposed resume"} icon="resume" onPress={lambda { onPreview(pdf); }}/> if pdf.get("content") else <Text style={s.errorText}>No PDF was generated.</Text>}
        {<Text style={s.small}>{str(pdf.get("pages",0))+(" page" if pdf.get("pages",0)==1 else " pages")+" · "+("your LaTeX format" if value.get("format")=="latex" else "built-in LaTeX template")+" · your original is unchanged"}</Text> if not legacy else <Text style={s.small}>Your uploaded resume is unchanged.</Text>}
        {<Text style={s.body}>{value["summary"]}</Text> if value.get("summary") else <View/>}
        <View style={s.wrap}>{[<Chip key={tab} label={tab} active={comparison==tab} onPress={lambda { comparison=tab; }}/> for tab in ["Changes","Original text","Tailored text","LaTeX"] if tab!="LaTeX" or value.get("tex")]}</View>
        {<View style={{gap:12}}>
            {[<ChangeRow key={c["id"]} change={c} rejected={c["id"] in rejected}/> for c in changes]}
            {<Text style={s.body}>No wording or order changes were needed.</Text> if len(changes)==0 and not legacy else <View/>}
            {<DroppedList dropped={value["dropped"]}/> if len(value.get("dropped",[]))>0 else <View/>}
            {[<Text key={n} style={s.small}>{"• "+n}</Text> for n in value.get("notes",[])]}
            {<View style={{gap:6}}><Text style={s.strong}>Text changes</Text><Text selectable={True} style={s.small}>{pdf["diff"]}</Text></View> if legacy and pdf.get("diff") else <View/>}
        </View> if comparison=="Changes" else <View/>}
        {<Text selectable={True} style={s.body}>{pdf.get("original_text","Original text is not included in this older result.") if comparison=="Original text" else pdf.get("text","")}</Text> if comparison in ["Original text","Tailored text"] else <View/>}
        {<View style={{gap:6}}><Text style={s.small}>Select and copy this into Overleaf to keep editing it there.</Text><Text selectable={True} style={[s.small,{fontFamily:"Menlo"}]}>{value.get("tex","")}</Text></View> if comparison=="LaTeX" else <View/>}
        {<Button label="Preview cover letter" secondary={True} icon="resume" onPress={lambda { onPreview(value["cover_letter"]); }}/> if value.get("cover_letter",{}).get("content") else <View/>}
    </View>
}

def ArtifactView(name: str, value: dict[str, any], onPreview: any) -> JsxElement {
    if name=="tailor" { return <TailoredResumeResult value={value} onPreview={onPreview}/>; }
    <View style={s.hero}>
        <Text style={s.eyebrow}>{{"inspect":"APPLICATION FORM","fit":"JOB FIT","tailor":"TAILORED RESUME","fill":"FORM FILLED","submit":"SUBMISSION RECEIPT","research":"CONTACT SOURCE","draft":"EMAIL DRAFT","send":"EMAIL SENT","profile":"PROFILE SUGGESTIONS","coach":"COACHING","execute":"TEST RESULTS","sync":"GMAIL CHECK","calendar":"CALENDAR","interview":"TRANSCRIPT"}.get(name,name.upper())}</Text>
        {<Text style={s.body}>{value["summary"]}</Text> if value.get("summary") else <View/>}
        {<Text style={s.body}>{str(len(value.get("fields",[])))+" form fields found on "+value.get("adapter","the employer site")+"."}</Text> if name=="inspect" else <View/>}
        {[<Text key={"s"+t} style={s.body}>{"✓ "+t}</Text> for t in value.get("strengths",[])]}
        {[<Text key={"g"+t} style={s.body}>{"~ "+t}</Text> for t in value.get("gaps",[])]}
        {[<Text key={"u"+t} style={s.body}>{"? "+t}</Text> for t in value.get("unknowns",[])]}
        {[<Text key={"e"+t} style={s.body}>{"• "+t}</Text> for t in value.get("suggested_edits",[])]}
        {[<Text key={"p"+t} style={s.body}>{"• "+t}</Text> for t in value.get("edits",[])]}
        {<Text style={s.strong}>{value["suggested_headline"]}</Text> if value.get("suggested_headline") else <View/>}
        {<Text style={s.body}>{value["suggested_about"]}</Text> if value.get("suggested_about") else <View/>}
        {<View style={{gap:4}}><Text style={s.strong}>{value.get("subject","")}</Text><Text style={s.body}>{value.get("body","")}</Text></View> if name=="draft" else <View/>}
        {[<Text key={row["criterion"]} style={s.body}>{row["criterion"]+" · "+str(row["score"])+"/4 — "+row["feedback"]}</Text> for row in value.get("rubric",[])]}
        {[<Text key={"f"+q} style={s.body}>{"Follow-up question: "+q}</Text> for q in value.get("followup_questions",[])]}
        {[<Text key={"n"+q} style={s.body}>{"Practice next: "+q}</Text> for q in value.get("next_exercises",[])]}
        {<Text style={s.body}>{"Tests passed: "+str(value.get("passed",0))+" of "+str(value.get("total",0))+(" · "+value["error"] if value.get("error") else "")}</Text> if name=="execute" else <View/>}
        {<Text style={s.body}>{str(len(value.get("events",[])))+" relevant messages found."}</Text> if name=="sync" else <View/>}
        {<Text style={s.small}>{"Receipt: "+str(value["receipt"])[0:300]}</Text> if value.get("receipt") else <View/>}
        {<Text style={s.small}>{str(value["transcript"])[0:600]}</Text> if value.get("transcript") else <View/>}
        {[<Text key={"q"+e["quote"]} style={s.small}>{"“"+e["quote"]+"”"}</Text> for e in value.get("evidence",[])]}
        {<Button label="Preview tailored resume" secondary={True} icon="resume" onPress={lambda { onPreview(value["pdf"]); }}/> if value.get("pdf") and value["pdf"].get("content") else <View/>}
        {<Button label="Preview cover letter" secondary={True} icon="resume" onPress={lambda { onPreview(value["cover_letter"]); }}/> if value.get("cover_letter") and value["cover_letter"].get("content") else <View/>}
        {<Text style={s.small}>{str(value["pdf"].get("diff",""))[0:1500]}</Text> if value.get("pdf") and value["pdf"].get("diff") else <View/>}
    </View>
}

def:pub hasLatex(resume: dict[str, any]) -> bool { return resume.get("format",{}).get("kind","") in ["upload","builtin"]; }

"""A task paused before tailoring because its resume has no LaTeX. The fix happens here, then the task continues."""
def:pub TailorBlocker(run: dict[str, any], onContinued: any, onNavigate: any) -> JsxElement {
    has resumes: list[dict[str, any]] = [], loaded: bool = False, busy: bool = False, working: str = "", error: str = "";
    async can with entry {
        try { resumes=(await rpc("bootstrap",{}))["resumes"]; } except Exception { resumes=[]; }
        loaded=True;
    }
    async def continueWith(resumeId: str) -> None {
        busy=True;error="";working="Starting tailoring…";
        try { onContinued(await rpc("agent_continue_tailoring",{"id":run["id"],"resume_id":resumeId})); }
        except Exception as e {
            error=errorText(e);
            # Stack may have attached the default resume; show what that resume still needs.
            try { onContinued(await rpc("agent_run",{"id":run["id"]})); } except Exception { }
        }
        busy=False;working="";
    }
    current=[r for r in resumes if r["id"]==run.get("resume_id")];
    # Started before any resume existed, or its resume was deleted: continuing attaches the default resume.
    stale=len(current)==0 and len(resumes)>0;
    fixed=stale or (len(current)>0 and hasLatex(current[0]));
    <View style={s.reviewBox}>
        <Text style={s.eyebrow}>ONE STEP BEFORE TAILORING</Text>
        {<Text style={s.body}>Checking your resume…</Text> if not loaded else (<View style={{gap:10}}>
            <Text style={s.heading}>Upload a resume first</Text>
            <Text style={s.body}>Stack tailors a resume you have uploaded, and you have none yet. Nothing has been generated.</Text>
            <Button label="Go to the Resume tab" icon="resume" disabled={busy} onPress={lambda { onNavigate("resume"); }}/>
        </View> if len(resumes)==0 else (<View style={{gap:10}}>
            <Text style={s.heading}>{"Your resume is uploaded" if stale else current[0]["name"]+" has its LaTeX"}</Text>
            <Text style={s.body}>{"This task started before you uploaded it. Continue, and Stack uses your default resume." if stale else "Continue to generate your tailored resume."}</Text>
            <Button label="Continue tailoring" icon="check" disabled={busy} onPress={lambda { continueWith(""); }}/>
        </View> if fixed else <View style={{gap:10}}>
            <Text style={s.body}>Nothing has been generated yet.</Text>
            <LatexSetup resume={current[0]} others={[r for r in resumes if hasLatex(r) and r["id"]!=current[0]["id"]]} onChanged={lambda (next: dict[str, any]) { resumes=next["resumes"]; }} onReady={continueWith}/>
        </View>))}
        {<Text style={s.small}>{working}</Text> if working else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
    </View>
}

"""One task: context, progress, what it needs from you, review, recovery, and results."""
def:pub TaskDetail(id: str, features: list[dict[str, any]], webUrl: str, onBack: any, onNavigate: any) -> JsxElement {
    has run: dict[str, any] = {}, values: dict[str, str] = {}, subject: str = "", body: str = "", evidence: str = "", editsFor: str = "",
        error: str = "", notice: str = "", busy: bool = False, pdfUri: str = "",
        rejected: list[str] = [], rejectFor: str = "";
    def remember -> None { DRAFTS[id]={"values":values,"subject":subject,"body":body,"evidence":evidence,"editsFor":editsFor,"rejected":rejected,"rejectFor":rejectFor}; }
    async def load -> None {
        if busy { return; }
        try {
            latest=await rpc("agent_run",{"id":id});
            review=latest.get("review",{});
            if review.get("step")=="send" and review.get("hash")!=editsFor { subject=review.get("subject","");body=review.get("body","");editsFor=review["hash"];remember(); }
            if review.get("step")=="approve_resume" and review.get("hash")!=rejectFor { rejected=review.get("rejected",[]);rejectFor=review["hash"];remember(); }
            run=latest;
        } except Exception as e { error=errorText(e); }
    }
    async can with entry {
        saved=DRAFTS.get(id,{});
        if len(saved)>0 { values=saved["values"];subject=saved["subject"];body=saved["body"];evidence=saved["evidence"];editsFor=saved["editsFor"];rejected=saved.get("rejected",[]);rejectFor=saved.get("rejectFor",""); }
        await load();
    }
    async def perform(endpoint: str, args: dict[str, any], done: str) -> None {
        if busy { return; } busy=True;error="";notice="";
        try { run=await rpc(endpoint,args);notice=done; }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def respond -> None {
        answers=[{"key":k,"value":v,"verified":True,"source":"User confirmed application answer"} for (k,v) in values.items() if v.strip()];
        await perform("agent_respond",{"id":id,"values":answers,"reuse":True},"Answers saved and confirmed. The task resumes automatically." if len(answers)>0 else "Trying again. Progress updates here automatically.");
        if not error { values={};remember(); }
    }
    async def approve -> None {
        review=run["review"];edits={};
        if review["step"]=="send" and (subject!=review.get("subject","") or body!=review.get("body","")) { edits={"subject":subject,"body":body}; }
        if review["step"]=="approve_resume" { edits={"rejected":rejected}; }
        await perform("agent_approve",{"id":id,"step":review["step"],"review_hash":review["hash"],"edits":edits},"Approved. Stack continues with exactly what you reviewed.");
        if not error { editsFor="";remember(); }
    }
    def toggle(change: str) -> None {
        if change in rejected { rejected=[x for x in rejected if x!=change]; }
        else { updated=[x for x in rejected];updated.append(change);rejected=updated; }
        remember();
    }
    async def reconcile(outcome: str) -> None {
        await perform("agent_reconcile",{"id":id,"outcome":outcome,"evidence":evidence},"Thanks. The task continues from what you confirmed.");
        if not error { evidence="";remember(); }
    }
    async def preview(pdf: dict[str, any]) -> None {
        try { pdfUri=await previewDocument(pdf); } except Exception as e { error=errorText(e); }
    }
    feature=featureFor(features,run.get("kind",""));review=run.get("review",{});
    <View style={{gap:16}}>
        <Lifecycle onRefresh={lambda { if len(run)==0 or run["status"] not in TERMINAL { load(); } }} onOpen={lambda (data: any) { }}/>
        <Button label="Back to tasks" secondary={True} icon="back" onPress={onBack}/>
        {<Text style={s.body}>Loading task…</Text> if len(run)==0 and not error else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
        {<View style={s.noticeBox}><Text style={s.noticeText}>{notice}</Text></View> if notice else <View/>}
        {<View style={{gap:12}}><Button label="Close preview" secondary={True} icon="back" onPress={lambda { pdfUri=""; }}/><View style={{height:480}}><PDFView uri={pdfUri}/></View></View> if pdfUri else <View/>}
        {<View style={{gap:14}}>
            <View style={{gap:6}}><View style={s.between}><Text style={[s.heading,{flex:1}]}>{run["title"]}</Text><StatusPill status={run["status"]} label={runLabel(run)}/></View>
                {<Text style={s.body}>{run["context_label"]}</Text> if run.get("context_label") else <View/>}
                <Text style={s.small}>{"Started "+dateTime(run["created_at"])+" · Updated "+dateTime(run["updated_at"] or run["created_at"])}</Text></View>
            <View style={s.mutedBox}><Text style={s.strong}>{"What’s happening"}</Text>{<Text style={s.small}>{"Step "+str(run["step_number"])+" of "+str(run["step_total"])+" · "+run["step_label"]}</Text> if run["step_total"]>1 else <View/>}<Text style={s.body}>{run["explanation"]}</Text>{<Text style={s.small}>{run["message"]}</Text> if run["message"] and run["message"]!=run["explanation"] else <View/>}{<StepList run={run}/> if run["step_total"]>1 else <View/>}</View>

            {<View style={s.reviewBox}>
                <Text style={s.eyebrow}>NOTHING IS SHARED UNTIL YOU APPROVE</Text>
                <Text style={s.heading}>{review.get("title","")}</Text>
                {<Text style={s.small}>{"Destination: "+review["destination"]}</Text> if review.get("destination") else <View/>}
                {<View style={{gap:6}}><Text style={s.label}>ANSWERS STACK WILL ENTER</Text>{[<Text key={a["label"]} style={s.body}>{a["label"]+": "+a["value"]}</Text> for a in review.get("answers",[])]}</View> if len(review.get("answers",[]))>0 else <View/>}
                {<View style={{gap:6}}><Text style={s.label}>DOCUMENTS STACK WILL UPLOAD</Text>{[<Text key={d["name"]} style={s.body}>{d["label"]+": "+d["name"]}</Text> for d in review.get("documents",[])]}</View> if len(review.get("documents",[]))>0 else <View/>}
                {<Button label="Preview the resume that will be uploaded" secondary={True} icon="resume" onPress={lambda { preview(run["artifacts"]["tailor"]["pdf"]); }}/> if review.get("step")=="fill" and run.get("artifacts",{}).get("tailor",{}).get("pdf",{}).get("content") else <View/>}
                {<Text style={s.small}>{"What changed in your resume:\n"+review["diff"]}</Text> if review.get("diff") else <View/>}
                {<View style={{gap:10}}>
                    {<Text style={s.body}>{review["summary"]}</Text> if review.get("summary") else <View/>}
                    {<Button label="Preview proposed resume" secondary={True} icon="resume" onPress={lambda { preview(run["artifacts"]["tailor"]["pdf"]); }}/> if run.get("artifacts",{}).get("tailor",{}).get("pdf",{}).get("content") else <View/>}
                    <Text style={s.small}>{"The preview includes every change. Rejected changes go back to your original wording when Stack rebuilds · "+str(review.get("pages",0))+" page"}</Text>
                    <Text style={s.label}>{"CHANGES · "+str(len(review.get("changes",[]))-len([c for c in review.get("changes",[]) if c["id"] in rejected]))+" OF "+str(len(review.get("changes",[])))+" KEPT"}</Text>
                    {[<ChangeRow key={c["id"]} change={c} rejected={c["id"] in rejected} onToggle={lambda { toggle(c["id"]); }}/> for c in review.get("changes",[])]}
                    {<Text style={s.body}>No wording or order changes were suggested.</Text> if len(review.get("changes",[]))==0 else <View/>}
                    {<DroppedList dropped={review["dropped"]}/> if len(review.get("dropped",[]))>0 else <View/>}
                </View> if review.get("step")=="approve_resume" else <View/>}
                {<View style={{gap:12}}><Text style={s.body}>{"To: "+review.get("to","")}</Text>
                    <Field label="Email subject" value={subject} onChange={lambda (v: str) { subject=v;remember(); }}/>
                    <Field label="Email message" value={body} onChange={lambda (v: str) { body=v;remember(); }} multiline={True}/>
                    <Text style={s.small}>Edits are yours. Stack sends exactly this text.</Text></View> if review.get("step")=="send" else <View/>}
                {<View style={{gap:4}}><Text style={s.body}>{review["event"].get("summary","")}</Text><Text style={s.small}>{isoTime(review["event"].get("start",""))+" – "+isoTime(review["event"].get("end",""))}</Text>{<Text style={s.small}>{review["event"]["location"]}</Text> if review["event"].get("location") else <View/>}</View> if review.get("step")=="calendar" else <View/>}
                {[<Text key={n} style={s.small}>{"• "+n}</Text> for n in review.get("notes",[]) if n!=review.get("blocked","")]}
                <Text style={s.strong}>{review.get("consequence","")}</Text>
                {<View style={[s.mutedBox,{backgroundColor:"#FFF1E3"}]}><Text style={[s.small,{color:"#A4540F"}]}>{review["blocked"]}</Text><Chip label={"Connect Gmail sending" if review.get("step")=="send" else "Connect Google Calendar"} onPress={lambda { onNavigate("connect:send" if review.get("step")=="send" else "connect:calendar"); }}/></View> if review.get("blocked") else <View/>}
                <Button label={APPROVE_LABELS.get(review.get("step",""),"Approve")} icon="check" disabled={busy or bool(review.get("blocked"))} onPress={approve}/>
                <Button label="Don’t do this · cancel task" secondary={True} disabled={busy} onPress={lambda { perform("agent_cancel",{"id":id},"Cancelled. Nothing was shared."); }}/>
                {<Text style={s.small}>{"Prefer to do it yourself? "+feature["alternative"]}</Text> if len(feature)>0 else <View/>}
            </View> if run["status"]=="review" else <View/>}

            {<TailorBlocker run={run} onNavigate={onNavigate} onContinued={lambda (next: dict[str, any]) { run=next;notice="Tailoring started. Stack will show you every change to keep or reject." if next["status"]=="queued" else ""; }}/> if run.get("needs_resume_review",False) else <View/>}

            {<View style={s.reviewBox}>
                <Text style={s.eyebrow}>{"STACK NEEDS YOUR ANSWERS" if len(run.get("requests",[]))>0 else "WHAT STOPPED THIS TASK"}</Text>
                {<Text style={s.body}>{run["message"]}</Text> if len(run.get("requests",[]))==0 and run["message"] else <View/>}
                {[<Field key={q["key"]} label={q["label"]} value={values.get(q["key"],"")} onChange={lambda (v: str) { values=withKey(values,q["key"],v);remember(); }}/> for q in run.get("requests",[]) if q["key"]!="browser"]}
                {[<Text key={q["label"]} style={s.body}>{"In the browser: "+q["label"]}</Text> for q in run.get("requests",[]) if q["key"]=="browser"]}
                {<Text style={s.small}>Answers you save are confirmed facts and can be reused on later applications. Review them in Agents → Facts.</Text> if len([q for q in run.get("requests",[]) if q["key"]!="browser"])>0 else <View/>}
                <Button label={"Save answers and resume" if len(run.get("requests",[]))>0 else "Try again"} icon={"" if len(run.get("requests",[]))>0 else "retry"} disabled={busy} onPress={respond}/>
                {<Button label="Open web workspace for the browser" secondary={True} onPress={lambda { openJobLink(webUrl); }}/> if webUrl else <Text style={s.small}>Browser handoff opens in the web workspace once it is hosted. Until then, complete the form on the employer site.</Text>}
            </View> if run["status"]=="needs_input" and not run.get("needs_resume_review",False) else <View/>}

            {<View style={s.reviewBox}>
                <Text style={s.eyebrow}>CONFIRM WHAT HAPPENED</Text>
                <Text style={s.body}>Stack cannot tell whether the last outbound action completed. Check your email, calendar, or the employer site, then tell Stack. It will not retry on its own.</Text>
                <Field label="What you checked (at least 10 characters)" value={evidence} onChange={lambda (v: str) { evidence=v;remember(); }} multiline={True}/>
                <Button label="It completed" disabled={busy or len(evidence.strip())<10} onPress={lambda { reconcile("confirmed"); }}/>
                <Button label="Nothing was sent" secondary={True} disabled={busy or len(evidence.strip())<10} onPress={lambda { reconcile("not_sent"); }}/>
            </View> if run["status"]=="uncertain" else <View/>}

            {<View style={s.reviewBox}>
                <Text style={s.eyebrow}>{"HOW TO CONTINUE" if run["status"]=="blocked" else "WHAT WENT WRONG"}</Text>
                <Text style={s.body}>{run["message"]}</Text>
                {[<View key={c["key"]} style={{gap:4}}><Text style={s.small}>{"✕ "+c["label"]+" — "+c["fix"]}</Text>{<Chip label={"Fix: "+c["label"]} onPress={lambda { onNavigate(c["action"]); }}/> if c["action"] else <View/>}</View> for c in missingChecks(feature) if not c["optional"]]}
                <Button label="Retry now" icon="retry" disabled={busy} onPress={lambda { perform("agent_retry",{"id":id},"Retrying. Progress updates here automatically."); }}/>
                {<Text style={s.small}>{"Meanwhile: "+feature["alternative"]}</Text> if len(feature)>0 else <View/>}
            </View> if run["status"] in ["blocked","failed"] else <View/>}

            {<View style={s.noticeBox}><Text style={s.noticeText}>Saved to Resume → Tailored resumes, labelled with this job and checked with the resume parser.</Text><Chip label="Open Tailored resumes" onPress={lambda { onNavigate("resume"); }}/></View> if run.get("artifacts",{}).get("tailor",{}).get("final") else <View/>}
            {<View style={{gap:10}}><Text style={s.heading}>Results</Text>{[<ArtifactView key={k} name={k} value={v} onPreview={preview}/> for (k,v) in run.get("artifacts",{}).items()]}</View> if len(run.get("artifacts",{}))>0 else <View/>}
            <Text style={s.small}>{"Where results appear: "+run["results_where"]}</Text>
            {<Text style={s.small}>{"Reserved API spend: $"+str(run["cost_cents"]/100)}</Text> if run["cost_cents"]>0 else <View/>}
            {<Text style={s.small}>{"Subscription requests: "+str(run["subscription_calls"])+" · provider limits apply"}</Text> if run.get("subscription_calls",0)>0 else <View/>}
            {<Button label="Cancel task" secondary={True} disabled={busy} onPress={lambda { perform("agent_cancel",{"id":id},"Cancelled."); }}/> if run["status"] not in TERMINAL and run["status"]!="review" else <View/>}
            {<Button label="Dismiss from Needs you" secondary={True} disabled={busy} onPress={lambda { perform("agent_dismiss",{"id":id},"Dismissed."); }}/> if run["status"]=="failed" and not run.get("dismissed") else <View/>}
        </View> if len(run)>0 and not pdfUri else <View/>}
    </View>
}

"""Contextual agent help for one saved application, with live task status."""
def:pub AgentLaunch(application: dict[str, any], runs: list[dict[str, any]], features: list[dict[str, any]], onOpenTask: any, onNavigate: any, compact: bool = False) -> JsxElement {
    has message: str = "", error: str = "", busy: bool = False;
    target=application["id"];
    actions=[
        {"kind":"jobs","label":"Explain my fit","text":"Strengths, gaps, and unknowns, quoted from the listing and your confirmed facts. Nothing leaves Stack."},
        {"kind":"resume","label":"Tailor my resume","text":"Rewords, reorders, and trims your LaTeX resume to one page for this job, in your format. You keep or reject every change."},
        {"kind":"application","label":"Prepare & apply","text":"Reads the form, explains fit, tailors, and fills it. You approve the answers and documents, then approve submission separately."},
        {"kind":"plan","label":"Build interview plan","text":"Adds practice sessions to Prep based on this job. No model needed."}
    ];
    async def start(kind: str) -> None {
        if busy { return; } busy=True;error="";message="";
        try {
            if kind=="plan" { result=await rpc("prep_for_application",{"application_id":target});message="Added "+str(len(result["plan"]))+" practice sessions to Prep."; }
            else { result=await rpc("agent_start",{"kind":kind,"target_id":target});if kind=="resume" { onOpenTask(result["id"]); } else { message=result["title"]+" started. Progress appears below and in Agents."; } }
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    started=runsFor(runs,target,["application","jobs","resume"]);
    <View style={{gap:12}}>
        {<View style={{gap:8}}><View style={s.row}><Icon name="sparkles" color="#3765E8"/><Text style={s.heading}>Agent help</Text></View>
            <Text style={s.body}>Optional. Nothing starts until you choose it, and nothing is sent without your approval.</Text></View> if not compact else <View/>}
        {[<View key={t["id"]}><TaskRow run={t} onOpen={lambda { onOpenTask(t["id"]); }}/></View> for t in started] if not compact else [<Chip key={t["id"]} label={"✦ "+t["title"]+" · "+runLabel(t)+" · Open"} active={True} onPress={lambda { onOpenTask(t["id"]); }}/> for t in started]}
        {<View style={s.wrap}>{[<Chip key={a["kind"]} label={a["label"]+({"setup":" · setup needed","unavailable":" · see requirements"}.get(featureFor(features,a["kind"]).get("state",""),"") if a["kind"]!="plan" else "")} onPress={lambda { if a["kind"]!="plan" and featureFor(features,a["kind"]).get("state","")=="unavailable" { onNavigate("features"); } else { start(a["kind"]); } }}/> for a in actions]}</View> if compact else <View/>}
        {[<View key={a["kind"]} style={s.actionRow}>
            <View style={s.between}><Text style={[s.strong,{flex:1}]}>{a["label"]}</Text>{<Pill label={stateLabel(str(featureFor(features,a["kind"]).get("state","")))} tone={stateTone(featureFor(features,a["kind"]).get("state",""))}/> if a["kind"]!="plan" and len(featureFor(features,a["kind"]))>0 else <View/>}</View>
            {<Text style={s.small}>{a["text"]}</Text> if not compact else <View/>}
            {[<Text key={c["key"]} style={s.small}>{"✕ "+c["fix"]}</Text> for c in missingChecks(featureFor(features,a["kind"])) if not c["optional"]] if a["kind"]!="plan" and not compact else []}
            {<Text style={s.small}>{"Meanwhile: "+featureFor(features,a["kind"])["alternative"]}</Text> if a["kind"]!="plan" and featureFor(features,a["kind"]).get("state","")=="unavailable" and not compact else <View/>}
            <Button label={a["label"]} secondary={a["kind"]!="application"} disabled={busy or (a["kind"]!="plan" and featureFor(features,a["kind"]).get("state","")=="unavailable")} onPress={lambda { start(a["kind"]); }}/>
        </View> for a in actions] if not compact else []}
        {<View style={s.noticeBox}><Text style={s.noticeText}>{message}</Text>{<Chip label="Open Prep" onPress={lambda { onNavigate("prep"); }}/> if message[0:5]=="Added" else <View/>}</View> if message else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
    </View>
}

"""Resume-side agents: fact confirmation, tailoring for a saved job, profile suggestions."""
def:pub ResumeAgents(applications: list[dict[str, any]], runs: list[dict[str, any]], features: list[dict[str, any]], onOpenTask: any, onNavigate: any, resumes: list[dict[str, any]] = [], onChanged: any = None) -> JsxElement {
    has error: str = "", message: str = "", busy: bool = False, setupFor: str = "";
    real=[a for a in applications if not a["demo"]];
    async def start(kind: str, target: str) -> None {
        if busy { return; } busy=True;error="";message="";
        try { result=await rpc("agent_start",{"kind":kind,"target_id":target});if kind=="resume" { onOpenTask(result["id"]); } else { message=result["title"]+" started. Follow it here or in Agents."; } }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    """Tailor with this resume, attaching it to the job first when the user picked a different one."""
    async def tailorWith(app: dict[str, any], resumeId: str) -> None {
        error="";
        if resumeId!=app["tailor"]["resume_id"] {
            try { next=await rpc("select_application_resume",{"id":app["id"],"resume_id":resumeId});if onChanged { onChanged(next); } }
            except Exception as e { error=errorText(e);return; }
        }
        setupFor="";await start("resume",app["id"]);
    }
    tailoring=featureByKey(features,"tailoring");profile=featureByKey(features,"profile");
    <View style={{gap:14}}>
        <View style={s.row}><Icon name="sparkles" color="#3765E8"/><Text style={s.heading}>Resume agents</Text></View>
        {<View style={{gap:14}}><FeatureCard feature={tailoring} onNavigate={onNavigate} compact={True}/>
            <Button label="Review resume details" secondary={True} onPress={lambda { onNavigate("resume-details"); }}/>
            {[<View key={a["id"]} style={s.actionRow}><Text style={s.strong}>{a["job"]["title"]}</Text><Text style={s.small}>{a["job"]["company"]}</Text>
                {<Text style={s.small}>{"Resume: "+a["tailor"]["resume_name"]+(" · LaTeX ready" if a["tailor"]["ready"] else " · needs its LaTeX")}</Text> if a.get("tailor",{}).get("resume_id") else <Text style={s.small}>Upload your resume above to tailor for this job.</Text>}
                {[<View key={t["id"]}><TaskRow run={t} onOpen={lambda { onOpenTask(t["id"]); }}/></View> for t in runsFor(runs,a["id"],["resume"])]}
                {<LatexSetup resume={[r for r in resumes if r["id"]==a["tailor"]["resume_id"]][0]} others={[r for r in resumes if hasLatex(r) and r["id"]!=a["tailor"]["resume_id"]]} onChanged={lambda (next: dict[str, any]) { if onChanged { onChanged(next); } }} onReady={lambda (resumeId: str) { tailorWith(a,resumeId); }}/> if setupFor==a["id"] and len([r for r in resumes if r["id"]==a.get("tailor",{}).get("resume_id","")])>0 else
                    <Button label="Tailor for this job" secondary={True} disabled={busy or tailoring["state"]=="unavailable" or not a.get("tailor",{}).get("resume_id")} onPress={lambda { if a["tailor"]["ready"] { start("resume",a["id"]); } else { setupFor=a["id"]; } }}/>}</View> for a in real[0:5]]}
            {<Text style={s.small}>Save a real job from Jobs to tailor for it.</Text> if len(real)==0 else <View/>}
        </View> if len(tailoring)>0 else <View/>}
        {<View style={{gap:12}}><FeatureCard feature={profile} onNavigate={onNavigate} compact={True}/>
            {[<View key={t["id"]}><TaskRow run={t} onOpen={lambda { onOpenTask(t["id"]); }}/></View> for t in runsFor(runs,"self",["profile"])[0:1]]}
            <Button label="Suggest headline & about" secondary={True} disabled={busy or profile["state"]=="unavailable"} onPress={lambda { start("profile","self"); }}/>
        </View> if len(profile)>0 else <View/>}
        {<View style={s.noticeBox}><Text style={s.noticeText}>{message}</Text></View> if message else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
    </View>
}

"""Agents center: attention, activity, feature guide, email & calendar, rules and facts."""
def:pub AgentHub(summary: dict[str, any], features: list[dict[str, any]], applications: list[dict[str, any]], initialPage: str = "Needs you", initialTask: str = "", onNavigate: any = None) -> JsxElement {
    has page: str = initialPage, taskId: str = initialTask, settings: dict[str, any] = {}, events: list[dict[str, any]] = [], interviews: list[dict[str, any]] = [],
        error: str = "", notice: str = "", busy: bool = False, rulesDirty: bool = False,
        enabled: bool = False, actions: list[str] = [], domains: str = "", daily: str = "5", followups: str = "0", analyzeTop: bool = False,
        factKey: str = "", factValue: str = "", eventApp: dict[str, str] = {}, eventStatus: dict[str, str] = {};
    def fillRules(policy: dict[str, any]) -> None {
        enabled=policy["enabled"];actions=policy["actions"];domains=", ".join(policy["domains"]);followups=str(policy["followup_limit"]);analyzeTop=policy.get("analyze_top_matches",False);
        limits=[v for (k,v) in policy.get("daily_limits",{}).items()];
        if len(limits)>0 { daily=str(limits[0]); }
        rulesDirty=False;
    }
    async def loadSettings(resetRules: bool = False) -> None {
        try {
            settings=await rpc("agent_settings",{});
            # Refreshes never overwrite rules you are still editing.
            if resetRules or not rulesDirty { fillRules(settings["policy"]); }
        } except Exception as e { error=errorText(e); }
    }
    async def loadEvents -> None {
        try { result=await rpc("agent_events",{});events=result["events"];interviews=result["interviews"]; }
        except Exception as e { error=errorText(e); }
    }
    async can with entry { await loadSettings(True);await loadEvents(); }
    async def poll -> None {
        if busy or len(taskId)>0 { return; }
        if page in ["Needs you","Email & calendar"] { await loadEvents(); }
        if page=="Facts" { await loadSettings(); }
    }
    async def perform(endpoint: str, args: dict[str, any], done: str) -> None {
        if busy { return; } busy=True;error="";notice="";
        try { await rpc(endpoint,args);notice=done;await loadSettings(endpoint=="agent_save_policy");await loadEvents(); }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def connect(capabilities: list[str]) -> None {
        error="";
        try { result=await rpc("agent_google_start",{"capabilities":capabilities});await openJobLink(result["url"]);notice="Finish connecting Google in your browser, then return to Stack."; }
        except Exception as e { error=errorText(e); }
    }
    async def savePolicy -> None {
        limit=0;count=0;
        try { limit=int(daily);count=int(followups); } except Exception { error="Enter whole numbers for daily and follow-up limits.";return; }
        await perform("agent_save_policy",{"policy":{"enabled":enabled,"actions":actions,"domains":[d.strip().lower() for d in domains.split(",") if d.strip()],"daily_limits":{"browser_fill":limit,"submit_application":limit,"send_email":limit,"calendar_write":limit},"expires_at":Date.now()/1000+30*86400,"followup_limit":count,"followup_days":7,"analyze_top_matches":analyzeTop}},"Standing permissions saved for 30 days.");
    }
    def go(action: str) -> None {
        if action=="rules" { page="Rules";taskId=""; }
        elif action=="facts" { page="Facts";taskId=""; }
        elif action[0:8]=="connect:" { page="Rules";taskId="";connect([action[8:]]); }
        elif action=="web" { openJobLink(settings.get("web_url","")); }
        elif onNavigate { onNavigate(action); }
    }
    runs=summary.get("runs",[]);
    attention=[r for r in runs if r["attention"]];
    active=[r for r in runs if r["status"] in ACTIVE];
    recent=[r for r in runs if not r["attention"] and r["status"] not in ACTIVE];
    unresolved=[e for e in events if e.get("ambiguous") and not e.get("resolved")];
    real=[a for a in applications if not a["demo"]];
    <View style={{gap:16}}>
        <Lifecycle onRefresh={poll} onOpen={lambda (data: any) { }}/>
        {<TaskDetail key={taskId} id={taskId} features={features} webUrl={settings.get("web_url","")} onBack={lambda { taskId=""; }} onNavigate={go}/> if len(taskId)>0 else (
        <View style={{gap:16}}>
            <View style={{gap:6}}><Text style={s.title}>Your agents.</Text><Text style={s.body}>{str(summary.get("active",0))+" in progress · "+str(summary.get("attention",0))+" need you. Updates every few seconds."}</Text></View>
            <View style={s.wrap}>{[<Chip key={p} label={p+(" ("+str(len(attention)+len(unresolved))+")" if p=="Needs you" and len(attention)+len(unresolved)>0 else "")} active={page==p} onPress={lambda { page=p;error="";notice=""; }}/> for p in ["Needs you","Activity","Features","Email & calendar","Rules","Facts"]]}</View>
            {<Text style={s.errorText}>{error}</Text> if error else <View/>}
            {<View style={s.noticeBox}><Text style={s.noticeText}>{notice}</Text></View> if notice else <View/>}

            {<View style={{gap:12}}>
                {[<View key={r["id"]}><TaskRow run={r} onOpen={lambda { taskId=r["id"]; }}/></View> for r in attention]}
                {<View style={{gap:8}}><Text style={s.strong}>Messages to confirm</Text><Text style={s.small}>Email tracking could not tell which application these belong to.</Text><Chip label="Open Email & calendar" onPress={lambda { page="Email & calendar"; }}/></View> if len(unresolved)>0 else <View/>}
                {<View style={s.empty}><Icon name="done" size={34} color="#167867"/><Text style={s.heading}>Nothing needs you right now.</Text><Text style={[s.body,{textAlign:"center"}]}>Reviews, questions, and paused tasks will appear here. The Agents button shows the count from any tab.</Text></View> if len(attention)==0 and len(unresolved)==0 else <View/>}
            </View> if page=="Needs you" else <View/>}

            {<View style={{gap:12}}>
                {<Text style={s.label}>NEEDS YOU</Text> if len(attention)>0 else <View/>}
                {[<View key={r["id"]}><TaskRow run={r} onOpen={lambda { taskId=r["id"]; }}/></View> for r in attention]}
                <Text style={s.label}>IN PROGRESS</Text>
                {[<View key={r["id"]}><TaskRow run={r} onOpen={lambda { taskId=r["id"]; }}/></View> for r in active]}
                {<Text style={s.small}>No tasks are running. Start one from Applications, Network, Resume, or Prep.</Text> if len(active)==0 else <View/>}
                <Text style={s.label}>RECENT</Text>
                {[<View key={r["id"]}><TaskRow run={r} onOpen={lambda { taskId=r["id"]; }}/></View> for r in recent]}
                <View style={s.mutedBox}><Text style={s.strong}>{"Model provider: "+summary.get("model_provider",{}).get("provider","Not configured")}</Text><Text style={s.small}>{summary.get("model_provider",{}).get("message","")}</Text></View>
            </View> if page=="Activity" else <View/>}

            {<View style={{gap:12}}><Text style={s.body}>Every agent, what it needs, and where to start it. Stack never sends, submits, or changes your calendar without your approval.</Text>{[<View key={f["key"]}><FeatureCard feature={f} onNavigate={go}/></View> for f in features]}</View> if page=="Features" else <View/>}

            {<View style={{gap:12}}>
                <FeatureCard feature={featureByKey(features,"email")} onNavigate={go} compact={True}/>
                <FeatureCard feature={featureByKey(features,"calendar")} onNavigate={go} compact={True}/>
                <Text style={s.label}>MESSAGES TO CONFIRM</Text>
                {[<View key={e["id"]} style={s.taskCard}><Text style={s.strong}>{e.get("subject","Message")}</Text><Text style={s.small}>{str(e.get("excerpt",""))[0:280]}</Text>
                    <Text style={s.label}>Which application?</Text><View style={s.wrap}>{[<Chip key={a["id"]} label={a["job"]["company"]+" · "+a["job"]["title"]} active={eventApp.get(e["id"],"")==a["id"]} onPress={lambda { eventApp=withKey(eventApp,e["id"],a["id"]); }}/> for a in real]}</View>
                    <Text style={s.label}>What does it confirm?</Text><View style={s.wrap}>{[<Chip key={st} label={st} active={eventStatus.get(e["id"],"")==st} onPress={lambda { eventStatus=withKey(eventStatus,e["id"],st); }}/> for st in ["Submitted","Assessment","Interview","Rejected"]]}</View>
                    <Button label="Save to application" disabled={busy or not eventApp.get(e["id"],"") or not eventStatus.get(e["id"],"")} onPress={lambda { perform("agent_resolve_event",{"id":e["id"],"application_id":eventApp[e["id"]],"status":eventStatus[e["id"]]},"Application status updated from this message."); }}/></View> for e in unresolved]}
                {<Text style={s.small}>No messages need confirmation.</Text> if len(unresolved)==0 else <View/>}
                <Text style={s.label}>RECENT UPDATES FROM EMAIL</Text>
                {[<View key={e["id"]} style={s.taskCard}><Text style={s.strong}>{e.get("status","Update")+" · "+e.get("subject","")}</Text><Text style={s.small}>{"“"+str(e.get("quote",""))[0:200]+"”"}</Text></View> for e in events if not e.get("ambiguous") or e.get("resolved")][0:10]}
                {<Text style={s.small}>Tracked updates appear here and in each application’s status history.</Text> if len(events)==0 else <View/>}
                <Text style={s.label}>INTERVIEWS</Text>
                {[<View key={i["id"]} style={s.taskCard}><Text style={s.strong}>{i.get("summary","Interview")}</Text><Text style={s.small}>{isoTime(i.get("start",{}).get("dateTime",""))}</Text>
                    {[<View key={t["id"]}><TaskRow run={t} onOpen={lambda { taskId=t["id"]; }}/></View> for t in runsFor(runs,i["id"],["calendar"])]}
                    {<Chip label={str(len(i.get("study_plan",[])))+" practice sessions in Prep"} onPress={lambda { go("prep"); }}/> if len(i.get("study_plan",[]))>0 else <View/>}</View> for i in interviews]}
                {<Text style={s.small}>Interview invitations found by email tracking appear here, each with a calendar change for you to review.</Text> if len(interviews)==0 else <View/>}
            </View> if page=="Email & calendar" else <View/>}

            {<View style={{gap:14}}>
                <Text style={s.body}>Standing permissions let agents work toward your goals. They never replace per-action review: you approve every application answer, submission, email, and calendar change.</Text>
                <View style={s.between}><Text style={s.strong}>Enable standing permissions</Text><Switch value={enabled} onValueChange={lambda (v: bool) { enabled=v;rulesDirty=True; }}/></View>
                {<Text style={s.small}>{"Current permissions expire "+dateTime(settings["policy"]["expires_at"])+"."}</Text> if settings.get("policy",{}).get("enabled") and settings["policy"].get("expires_at",0)>0 else <View/>}
                <View style={s.wrap}>{[<Chip key={a} label={a.replace("_"," ").title()} active={a in actions} onPress={lambda { actions=[x for x in actions if x!=a] if a in actions else actions+[a];rulesDirty=True; }}/> for a in ["model","browser_fill","submit_application","gmail_read","send_email","calendar_write"]]}</View>
                <View style={s.between}><Text style={[s.strong,{flex:1}]}>Analyze up to three top matches daily</Text><Switch value={analyzeTop} onValueChange={lambda (v: bool) { analyzeTop=v;rulesDirty=True; }}/></View>
                <Field label="Allowed destination domains" value={domains} onChange={lambda (v: str) { domains=v;rulesDirty=True; }} placeholder="jobs.lever.co, job-boards.greenhouse.io, company.com" multiline={True}/>
                <Text style={s.small}>Application sites and email recipients must be on this list. Use exact domains.</Text>
                <Field label="Daily limit per action" value={daily} onChange={lambda (v: str) { daily=v;rulesDirty=True; }}/><Field label="Follow-ups per contact (0–3)" value={followups} onChange={lambda (v: str) { followups=v;rulesDirty=True; }}/>
                <Text style={s.small}>Permissions expire after 30 days. Follow-ups are drafted seven days apart, wait for your approval, and stop when a reply arrives.</Text>
                <Button label={"Save standing permissions"+(" · unsaved changes" if rulesDirty else "")} onPress={savePolicy} disabled={busy}/>
                {<Button label="Discard changes" secondary={True} onPress={lambda { fillRules(settings["policy"]); }}/> if rulesDirty and len(settings)>0 else <View/>}
                <Text style={s.heading}>Google</Text>
                <Button label="Connect Gmail tracking" onPress={lambda { connect(["read"]); }} secondary={True}/><Button label="Allow Gmail sending" onPress={lambda { connect(["send"]); }} secondary={True}/><Button label="Connect Google Calendar" onPress={lambda { connect(["calendar","availability"]); }} secondary={True}/>
                <Text style={s.small}>Gmail read access covers your whole mailbox. Stack only processes messages related to your applications and selected contacts.</Text>
                {[<View key={c["id"]} style={s.taskCard}><Text style={s.strong}>{c["provider"].title()+" · "+c["state"]}</Text><Button label="Disconnect" onPress={lambda { perform("agent_disconnect",{"id":c["id"]},"Disconnected."); }} secondary={True}/></View> for c in settings.get("connections",[])]}
                <Text style={s.small}>{"Account ID (for local subscription setup): "+settings.get("account_id","")}</Text>
            </View> if page=="Rules" else <View/>}

            {<View style={{gap:12}}><Text style={s.body}>Agents reuse only confirmed facts. Extract text from a resume on the Resume tab, then confirm what is accurate.</Text>
                {[<View key={f["key"]} style={s.taskCard}><Text style={s.strong}>{f["key"]}</Text><Text style={s.body}>{f["value"]}</Text><Text style={s.small}>{f["source"]}</Text>{<Button label="Confirm this fact" secondary={True} disabled={busy} onPress={lambda { perform("agent_save_facts",{"facts":[{**f,"verified":True}]},"Fact confirmed."); }}/> if not f["verified"] else <Chip label="Confirmed" active={True}/>}</View> for f in settings.get("facts",[])]}
                {<Text style={s.small}>No facts yet.</Text> if len(settings.get("facts",[]))==0 else <View/>}
                <Field label="Fact name" value={factKey} onChange={lambda (v: str) { factKey=v; }} placeholder="email, phone, name, work_authorization"/>
                <Field label="Your answer" value={factValue} onChange={lambda (v: str) { factValue=v; }} multiline={True}/>
                <Button label="Save confirmed fact" disabled={busy or not factKey.strip() or not factValue.strip()} onPress={lambda { perform("agent_save_facts",{"facts":[{"key":factKey,"value":factValue,"verified":True,"source":"User confirmed"}]},"Fact saved."); }}/>
            </View> if page=="Facts" else <View/>}
        </View>)}
    </View>
}
