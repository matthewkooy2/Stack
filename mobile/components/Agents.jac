import from "@jac/mobui" { View, Text, Switch, Pressable }
import from "../device.js" { rpc, errorText, openJobLink, dateTime, isoTime, Icon, Lifecycle, previewDocument, PDFView, AgentBrowser }
import from ..theme { s }
import from .UI { Button, Field, Chip }
import from .ResumeReview { ResumeReview }

"""Unsent answers and email edits survive refreshes and closing a task (per session)."""
glob DRAFTS: dict[str, any] = {};
glob STATUS_LABELS: dict[str, str] = {"queued":"Queued","running":"Working","waiting":"Ready","needs_input":"Needs your answers","blocked":"Paused · setup","review":"Needs your review","uncertain":"Confirm what happened","failed":"Stopped","completed":"Done","cancelled":"Cancelled"};
glob STATE_LABELS: dict[str, str] = {"ready":"Ready","setup":"Needs setup","unavailable":"Unavailable"};
glob APPROVE_LABELS: dict[str, str] = {"fill":"Approve sharing these answers","submit":"Approve submission","send":"Approve and send","calendar":"Approve calendar change"};
glob TERMINAL: list[str] = ["completed","cancelled","failed"];
glob ATTENTION: list[str] = ["needs_input","blocked","review","uncertain","failed"];
glob ACTIVE: list[str] = ["queued","running","waiting"];

def:pub statusLabel(status: str) -> str { return STATUS_LABELS.get(status,status); }
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
def:pub StatusPill(status: str) -> JsxElement { <Pill label={statusLabel(status)} tone={toneFor(status)}/> }

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
    <Pressable accessibilityRole="button" accessibilityLabel={"Open task "+run["title"]+" · "+statusLabel(run["status"])} onPress={onOpen} style={s.taskCard}>
        <View style={s.between}><Text style={[s.strong,{flex:1}]}>{run["title"]}</Text><StatusPill status={run["status"]}/></View>
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

def TailoredResumeResult(value: dict[str, any], onPreview: any) -> JsxElement {
    has comparison: str = "Changes";
    pdf=value.get("pdf",{});
    <View style={{gap:14}}>
        <Text style={s.heading}>Your tailored resume</Text>
        {<Button label="Preview tailored resume" icon="resume" onPress={lambda { onPreview(pdf); }}/> if pdf.get("content") else <Text style={s.errorText}>No PDF was generated.</Text>}
        <Text style={s.small}>Your uploaded resume is unchanged.</Text>
        {<Text style={s.body}>{value["summary"]}</Text> if value.get("summary") else <View/>}
        <View style={s.wrap}>{[<Chip key={tab} label={tab} active={comparison==tab} onPress={lambda { comparison=tab; }}/> for tab in ["Changes","Original text","Tailored text"]]}</View>
        {<View style={{gap:12}}>
            <Text style={s.strong}>Applied to this PDF</Text>
            <Text style={s.body}>{"Your confirmed details were reordered for this role and rendered in a new single-column layout. Their wording is unchanged." if pdf.get("order_changed",True) else "Your confirmed details kept their order and were rendered in a new single-column layout. Their wording is unchanged."}</Text>
            {<Text style={s.strong}>Suggested edits · not applied</Text> if len(value.get("suggested_edits",[]))>0 else <View/>}
            {[<Text key={str(i)} style={s.body}>{"• "+edit}</Text> for (i,edit) in enumerate(value.get("suggested_edits",[]))]}
            {<View style={{gap:6}}><Text style={s.strong}>Text changes</Text><Text selectable={True} style={s.small}>{pdf["diff"]}</Text></View> if pdf.get("diff") else <View/>}
        </View> if comparison=="Changes" else <Text selectable={True} style={s.body}>{pdf.get("original_text","Original text is not included in this older result.") if comparison=="Original text" else pdf.get("text","")}</Text>}
        {<Button label="Preview cover letter" secondary={True} icon="resume" onPress={lambda { onPreview(value["cover_letter"]); }}/> if value.get("cover_letter",{}).get("content") else <View/>}
    </View>
}

def ArtifactView(name: str, value: dict[str, any], onPreview: any) -> JsxElement {
    if name=="linkedin_review" {
        return <View style={s.hero}>
            <Text style={s.heading}>Your LinkedIn review</Text><Text style={s.body}>{value.get("summary","")}</Text>
            <Text style={s.small}>{value.get("profile_url","")+" · Captured "+dateTime(value.get("captured_at",0))}</Text>
            {[<Text key={str(i)} style={s.body}>{"✓ "+item}</Text> for (i,item) in enumerate(value.get("strengths",[]))]}
            {[<View key={str(i)} style={s.taskCard}><Text style={s.strong}>{item["priority"].title()+" priority · "+item["section"].title()}</Text>
                <Text style={s.strong}>{item["weakness"]}</Text><Text style={s.small}>{"“"+item["quote"]+"”"}</Text>
                <Text style={s.body}>{item["why_it_matters"]}</Text><Text style={s.body}>{item["recommendation"]}</Text>
            </View> for (i,item) in enumerate(value.get("findings",[]))]}
            {[<View key={str(i)} style={{gap:6}}><Text style={s.strong}>{"Suggested "+item["section"]}</Text><Text selectable={True} style={s.body}>{item["text"]}</Text></View> for (i,item) in enumerate(value.get("rewrites",[]))]}
            {[<Text key={str(i)} style={s.body}>{"To strengthen this: "+q}</Text> for (i,q) in enumerate(value.get("questions",[]))]}
            <Text style={s.small}>{value.get("limitations","")}</Text>
            <Text style={s.small}>{"Sections not read: "+", ".join(value.get("unread_sections",[]))}</Text>
            <Text style={s.small}>Suggested edits are yours to review and apply on LinkedIn.</Text>
        </View>;
    }
    if name=="linkedin_scan" { return <View style={s.mutedBox}><Text style={s.strong}>Profile captured</Text><Text style={s.body}>{value.get("summary","")}</Text><Text style={s.small}>{value.get("limitations","")}</Text></View>; }
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

"""One task: context, progress, what it needs from you, review, recovery, and results."""
def:pub TaskDetail(id: str, features: list[dict[str, any]], webUrl: str, onBack: any, onNavigate: any) -> JsxElement {
    has run: dict[str, any] = {}, values: dict[str, str] = {}, subject: str = "", body: str = "", evidence: str = "", editsFor: str = "",
        error: str = "", notice: str = "", busy: bool = False, pdfUri: str = "", reviewingResume: bool = False;
    def remember -> None { DRAFTS[id]={"values":values,"subject":subject,"body":body,"evidence":evidence,"editsFor":editsFor}; }
    async def load -> None {
        if busy { return; }
        try {
            latest=await rpc("agent_run",{"id":id});
            review=latest.get("review",{});
            if review.get("step")=="send" and review.get("hash")!=editsFor { subject=review.get("subject","");body=review.get("body","");editsFor=review["hash"];remember(); }
            if latest.get("kind")=="linkedin" and latest.get("status") in ["needs_input","blocked","completed","failed"] { notice=""; }
            run=latest;
        } except Exception as e { error=errorText(e); }
    }
    async can with entry {
        saved=DRAFTS.get(id,{});
        if len(saved)>0 { values=saved["values"];subject=saved["subject"];body=saved["body"];evidence=saved["evidence"];editsFor=saved["editsFor"]; }
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
        await perform("agent_respond",{"id":id,"values":answers,"reuse":True},"Reading your LinkedIn profile. Progress and any issues appear below." if run.get("kind")=="linkedin" else "Answers saved and confirmed. The task resumes automatically.");
        if not error { values={};remember(); }
    }
    async def approve -> None {
        review=run["review"];edits={};
        if review["step"]=="send" and (subject!=review.get("subject","") or body!=review.get("body","")) { edits={"subject":subject,"body":body}; }
        await perform("agent_approve",{"id":id,"step":review["step"],"review_hash":review["hash"],"edits":edits},"Approved. Stack continues with exactly what you reviewed.");
        if not error { editsFor="";remember(); }
    }
    async def reconcile(outcome: str) -> None {
        await perform("agent_reconcile",{"id":id,"outcome":outcome,"evidence":evidence},"Thanks. The task continues from what you confirmed.");
        if not error { evidence="";remember(); }
    }
    async def preview(pdf: dict[str, any]) -> None {
        try { pdfUri=await previewDocument(pdf); } except Exception as e { error=errorText(e); }
    }
    async def resumeReviewed -> None {
        await perform("agent_respond",{"id":id,"values":[],"reuse":False},"Resume confirmed. Tailoring is in progress.");
        if not error { reviewingResume=False; }
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
            <View style={{gap:6}}><View style={s.between}><Text style={[s.heading,{flex:1}]}>{run["title"]}</Text><StatusPill status={run["status"]}/></View>
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

            {<View style={{gap:12}}>
                <Text style={s.heading}>Review your resume first</Text>
                <Text style={s.body}>No tailored PDF has been generated. Confirm your resume details, then continue this task.</Text>
                {<ResumeReview resumeId={run["resume_id"]} onConfirmed={resumeReviewed}/> if reviewingResume and run.get("resume_id") else <Button label="Review resume details" icon="resume" disabled={busy} onPress={lambda { if run.get("resume_id") { reviewingResume=True; } else { onNavigate("resume"); } }}/>}
            </View> if run.get("needs_resume_review",False) else <View/>}

            {<View style={s.reviewBox}>
                <Text style={s.eyebrow}>{"ANALYSIS PAUSED" if run["kind"]=="linkedin" and run.get("step_number",1)==2 else "STACK NEEDS YOUR ANSWERS"}</Text>
                {<View style={{gap:8}}><Text style={s.body}>{run["message"]}</Text><Text style={s.small}>There is no question to answer. Your captured profile is saved; retry analysis without signing in again.</Text><Button label="Retry analysis" disabled={busy} onPress={respond}/></View> if run["kind"]=="linkedin" and run.get("step_number",1)==2 and len(run.get("requests",[]))==0 else <View/>}
                {[<Field key={q["key"]} label={q["label"]} value={values.get(q["key"],"")} onChange={lambda (v: str) { values=withKey(values,q["key"],v);remember(); }}/> for q in run.get("requests",[]) if q["key"]!="browser"]}
                {[<Text key={q["label"]} style={s.body}>{"In the browser: "+q["label"]}</Text> for q in run.get("requests",[]) if q["key"]=="browser"]}
                {<Text style={s.small}>Answers you save are confirmed facts and can be reused on later applications. Review them in Agents → Facts.</Text> if len([q for q in run.get("requests",[]) if q["key"]!="browser"])>0 else <View/>}
                {<Button label="Save answers and resume" disabled={busy} onPress={respond}/> if run["kind"]!="linkedin" else <View/>}
                {<Button label="Open web workspace for the browser" secondary={True} onPress={lambda { openJobLink(webUrl); }}/> if webUrl and run["kind"]!="linkedin" else <View/>}
            </View> if run["status"]=="needs_input" and not run.get("needs_resume_review",False) else <View/>}

            {<AgentBrowser key={id} id={id} requestBrowser={rpc} statusMessage={run.get("message","")} interactive={run["status"] in ["needs_input","blocked"] and not busy} canAnalyze={run["status"]=="needs_input" and not busy} onAnalyze={respond}/> if run["kind"]=="linkedin" and run.get("step_number",1)==1 and run["status"] not in TERMINAL else <View/>}

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
                <Button label={"Retry analysis" if run["kind"]=="linkedin" and run.get("step_number",1)==2 else "Retry now"} icon="retry" disabled={busy} onPress={lambda { perform("agent_retry",{"id":id},"Retrying. Progress updates here automatically."); }}/>
                {<Text style={s.small}>{"Meanwhile: "+feature["alternative"]}</Text> if len(feature)>0 else <View/>}
            </View> if run["status"] in ["blocked","failed"] else <View/>}

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
        {"kind":"resume","label":"Tailor my resume","text":"A reordered PDF built only from your confirmed facts. Your original PDF stays unchanged."},
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
        {[<View key={t["id"]}><TaskRow run={t} onOpen={lambda { onOpenTask(t["id"]); }}/></View> for t in started] if not compact else [<Chip key={t["id"]} label={"✦ "+t["title"]+" · "+statusLabel(t["status"])+" · Open"} active={True} onPress={lambda { onOpenTask(t["id"]); }}/> for t in started]}
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
def:pub ResumeAgents(applications: list[dict[str, any]], runs: list[dict[str, any]], features: list[dict[str, any]], onOpenTask: any, onNavigate: any) -> JsxElement {
    has error: str = "", message: str = "", busy: bool = False;
    real=[a for a in applications if not a["demo"]];
    async def start(kind: str, target: str) -> None {
        if busy { return; } busy=True;error="";message="";
        try { result=await rpc("agent_start",{"kind":kind,"target_id":target});if kind=="resume" { onOpenTask(result["id"]); } else { message=result["title"]+" started. Follow it here or in Agents."; } }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    tailoring=featureByKey(features,"tailoring");profile=featureByKey(features,"profile");
    <View style={{gap:14}}>
        <View style={s.row}><Icon name="sparkles" color="#3765E8"/><Text style={s.heading}>Resume agents</Text></View>
        {<View style={{gap:14}}><FeatureCard feature={tailoring} onNavigate={onNavigate} compact={True}/>
            <Button label="Review resume details" secondary={True} onPress={lambda { onNavigate("resume-details"); }}/>
            {[<View key={a["id"]} style={s.actionRow}><Text style={s.strong}>{a["job"]["title"]}</Text><Text style={s.small}>{a["job"]["company"]}</Text>
                {[<View key={t["id"]}><TaskRow run={t} onOpen={lambda { onOpenTask(t["id"]); }}/></View> for t in runsFor(runs,a["id"],["resume"])]}
                <Button label="Tailor for this job" secondary={True} disabled={busy or tailoring["state"]=="unavailable"} onPress={lambda { start("resume",a["id"]); }}/></View> for a in real[0:5]]}
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
