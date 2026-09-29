import from "@jac/mobui" { View, Text, Pressable, ScrollView, Modal, Switch, KeyboardAvoidingView, ActivityIndicator }
import from "./device.js" { Icon, authenticate, restoreSession, rpc, signOut, errorText, isUnauthorized, shortDate, dateTime, tomorrow, later, pickResume, previewResume, reconcileNotifications, Lifecycle, SwipeSurface, DateField, PDFView, openSettings, confirmDelete, openJobLink, persistSwipe }
import from .theme { s }
import from .components.UI { Button, Field, Chip, Empty, Logo }
import from .components.Prep { Prep }
import from .components.Agents { AgentHub, AgentLaunch, AgentBadge, ResumeAgents, runsFor, runLabel }
import from .components.Network { NetworkAgent }
import from .components.Discovery { Discovery }
import from .components.MatchInputs { MatchInputs }
import from .components.ResumeReview { ResumeReview }
import from .components.ResumeFormat { ResumeFormat }
import from .components.TailoredResumes { TailoredResumes }

def _find(items: list[dict[str, any]], id: str) -> dict[str, any] {
    for item in items { if item["id"]==id { return item; } }
    return {};
}

def _joined(items: list[str]) -> str {
    out="";
    for x in items { out=out+(", " if out else "")+x; }
    return out;
}
"""Form representation of saved matching preferences (text fields stay strings)."""
def _preferenceForm(p: dict[str, any]) -> dict[str, any] {
    x=p["preferences"];
    return {"stage":x["stage"],"years":"" if x["years"] is None else str(x["years"]),"education":x["education"],"modes":x["modes"],"employment_types":x["employment_types"],
        "salary_min":str(x["salary_min"]) if x["salary_min"] else "","salary_period":x["salary_period"],"exclude_companies":_joined(x["exclude_companies"]),"exclude_terms":_joined(x["exclude_terms"]),"soft":x["soft"]};
}

def:pub app -> JsxElement {
    has logged: bool = False, starting: bool = True, busy: bool = False, refreshing: bool = False,
        pendingSwipes: int = 0, revision: int = 0, signup: bool = True, username: str = "", password: str = "", invite: str = "", error: str = "", notice: str = "",
        state: dict[str, any] = {}, tab: str = "Jobs", modal: str = "", selected: str = "", applicationFilter: str = "All", networkFilter: str = "Discover",
        name: str = "", role: str = "", location: str = "United States", mode: str = "Any", notifications: bool = True, graduation: str = "", availableFrom: str = "", prefs: dict[str, any] = {}, profileRevision: int = 0,
        notes: str = "", draft: str = "", rename: str = "", pdfUri: str = "", reminderId: str = "", reminderTitle: str = "", reminderDue: float = 0.0, targetType: str = "", targetId: str = "", returnModal: str = "", pendingOpen: dict[str, any] = {},
        hubPage: str = "Needs you", hubTask: str = "", hubOpenings: int = 0, savedJob: str = "";

    def profileFields -> None {
        p=state["profile"]; name=p["name"]; role=p["role"]; location=p["location"]; mode=p["mode"]; notifications=p["notifications"];graduation=p.get("graduation_month","");availableFrom=p.get("available_from","");prefs=_preferenceForm(p);
    }
    async def logout -> None {
        busy=True;
        try { await signOut(); } except Exception as e { error=errorText(e); busy=False; return; }
        logged=False; state={}; modal=""; password=""; username=""; tab="Jobs"; pdfUri=""; notice=""; error=""; pendingOpen={}; busy=False;
    }
    def openRecord(kind: str, id: str) -> None {
        selected=id; error=""; notice="";
        if kind=="application" {
            a=_find(state["applications"],id);
            if len(a)==0 { return; }
            notes=a["notes"]; tab="Applications"; modal="Application";
        } else {
            c=_find(state["contacts"],id);
            if len(c)==0 { return; }
            notes=c["notes"]; draft=c["draft"]; tab="Network"; modal="Contact";
        }
    }
    def openAgents(page: str, task: str = "") -> None {
        hubPage=page;hubTask=task;hubOpenings+=1;returnModal="";modal="Agents";error="";notice="";
    }
    def openTask(id: str) -> None { openAgents("Activity",id); }
    """Route a setup or result action to the tab or Agents page that handles it."""
    def navigate(action: str) -> None {
        if action=="resume-details" and len(state["resumes"])>0 { selected=state["selected_resume"] or state["resumes"][0]["id"];modal="Resume details";return; }
        destinations={"resume":"Resume","jobs":"Jobs","applications":"Applications","contacts":"Network","prep":"Prep"};
        if destinations.get(action,"") { modal="";tab=destinations[action];return; }
        if action=="facts" { openAgents("Facts");return; }
        if action=="features" { openAgents("Features");return; }
        openAgents("Rules");
    }
    def notificationOpen(data: dict[str, any]) -> None {
        if logged and data.get("user_id")==state.get("user_id") and data.get("target_type")=="agent" { openAgents("Needs you",data.get("target_id","") or "");return; }
        if not logged or len(state)==0 { pendingOpen=data; return; }
        if data["user_id"]==state["user_id"] { openRecord(data["target_type"],data["target_id"]); }
        pendingOpen={};
    }
    async def refresh -> None {
        if not logged or busy or refreshing or pendingSwipes>0 { return; }
        refreshing=True;
        observed=revision;
        try {
            latest=await rpc("bootstrap",{});
            if observed==revision and not busy {
                state=latest;
                await reconcileNotifications(state,False);
                if len(pendingOpen)>0 { notificationOpen(pendingOpen); }
            }
        } except Exception as e {
            if isUnauthorized(e) { await logout(); error="Your session expired. Please sign in again."; }
            else { error=errorText(e); }
        }
        refreshing=False;
    }
    async can with entry {
        try {
            logged=await restoreSession();
            if logged { state=await rpc("bootstrap",{}); profileFields(); await reconcileNotifications(state,False); }
        } except Exception as e { error=errorText(e); if isUnauthorized(e) { await logout(); } }
        starting=False;
    }
    async def login -> None {
        if busy { return; }
        if len(username.strip())<3 or len(password)<8 { error="Use a username of at least 3 characters and a password of at least 8."; return; }
        busy=True; error="";
        try {
            await authenticate(username,password,signup); password="";
            if invite { await rpc("agent_accept_invite",{"invite":invite});invite=""; }
            state=await rpc("bootstrap",{}); logged=True;profileFields(); await reconcileNotifications(state,False);
            if len(pendingOpen)>0 { notificationOpen(pendingOpen); }
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def mutate(endpoint: str, args: dict[str, any], close: bool = True, ask: bool = False) -> None {
        if busy { return; } revision=revision+1; busy=True; error=""; notice="";
        try {
            state=await rpc(endpoint,args);
            if close { modal=""; }
            try { notice=await reconcileNotifications(state,ask); } except Exception { notice="Saved. Notifications could not be scheduled; reopen Stack to retry."; }
            if not notice { notice="Saved to your Stack."; }
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def trackJob(job_id: str, action: str) -> None {
        revision+=1;pendingSwipes+=1;
        # A right swipe only saves. Agent help is offered on the confirmation card and starts on request.
        try { state=await persistSwipe(job_id,action,False);if action=="apply" { savedJob=job_id; } }
        finally { pendingSwipes-=1; }
    }
    async def openApplication(url: str) -> None {
        try { await openJobLink(url); } except Exception as e { error=errorText(e); }
    }
    async def extractFacts(id: str) -> None {
        selected=id;modal="Resume details";error="";notice="";
    }
    async def upload -> None {
        if busy { return; } revision=revision+1; busy=True; error="";
        try {
            file=await pickResume();
            if file { state=await rpc("upload_resume",file); notice="Your resume is saved privately."; }
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def preview(id: str) -> None {
        if busy { return; } busy=True; error="";
        try { pdfUri=await previewResume(id); modal="PDF preview"; } except Exception as e { error=errorText(e); }
        busy=False;
    }
    def beginReminder(kind: str, id: str) -> None {
        returnModal=modal; targetType=kind; targetId=id; reminderId=""; reminderTitle="Follow up"; reminderDue=tomorrow(); modal="Reminder";
    }
    def editReminder(r: dict[str, any]) -> None {
        returnModal=modal; targetType=r["target_type"]; targetId=r["target_id"]; reminderId=r["id"]; reminderTitle=r["title"]; reminderDue=r["due_at"]; modal="Reminder";
    }
    async def saveReminder -> None {
        await mutate("save_reminder",{"id":reminderId,"target_type":targetType,"target_id":targetId,"title":reminderTitle,"due_at":reminderDue},False,True);
        if not error { modal=returnModal; }
    }
    def editProfile -> None { profileFields(); modal="Edit profile"; error=""; }
    async def saveProfile -> None {
        # The job deck remounts so saved defaults and search overrides are re-read from the server.
        chosen=prefs["modes"];
        await mutate("save_profile",{"name":name,"role":role,"location":location,"mode":chosen[0] if len(chosen)==1 else "Any","notifications":notifications,"graduation_month":graduation,"available_from":availableFrom,"preferences":prefs});
        if not error { profileRevision=profileRevision+1; }
    }

    <KeyboardAvoidingView style={s.screen} behavior="padding">
        <Lifecycle onRefresh={refresh} onOpen={notificationOpen}/>
        {<View style={[s.empty,{flex:1,justifyContent:"center"}]}><Text style={s.brand}>stack</Text><ActivityIndicator color="#3765E8"/></View> if starting else (
        <ScrollView contentContainerStyle={s.auth} keyboardShouldPersistTaps="handled">
            <View style={s.authLogo}><Icon name="layers" color="white" size={35}/></View>
            <View style={{gap:13}}><Text style={s.eyebrow}>A LITTLE MOMENTUM. A BIG NEXT STEP.</Text><Text style={s.authTitle}>Your next chapter{"\n"}starts here.</Text><Text style={s.body}>Find your people. Find your fit. Make your move.</Text></View>
            <View style={{gap:15}}><Text style={s.heading}>{"Create your Stack" if signup else "Welcome back"}</Text><Field label="Username" value={username} onChange={lambda (v: str) { username=v; }}/><Field label="Password" value={password} onChange={lambda (v: str) { password=v; }} secret={True}/><Field label="Beta invitation (first visit)" value={invite} onChange={lambda (v: str) { invite=v; }}/>
                {<Text style={s.errorText}>{error}</Text> if error else <View/>}
                <Button label={"Just a moment…" if busy else ("Get started" if signup else "Sign in")} onPress={login} disabled={busy} icon="next"/>
                <Pressable onPress={lambda { signup=not signup; error=""; }} accessibilityRole="button"><Text style={[s.body,{textAlign:"center",color:"#3765E8"}]}>{"Already have an account? Sign in" if signup else "New here? Create an account"}</Text></Pressable>
            </View>
            <Text style={[s.small,{textAlign:"center"}]}>Development preview · Real job discovery{"\n"}Real accounts. Your resume stays private.\nJob data is for your personal search; do not redistribute provider datasets.</Text>
        </ScrollView> if not logged else (
        <View style={{flex:1}}>
            {<View style={s.error}><Text style={s.errorText}>{error}</Text><Pressable onPress={lambda { error=""; refresh(); }}><Text style={[s.errorText,{fontWeight:"700",marginTop:5}]}>Retry</Text></Pressable></View> if error else <View/>}
            {<Pressable style={s.notice} onPress={lambda { notice=""; }}><Text style={s.noticeText}>{notice}</Text></Pressable> if notice else <View/>}
            {<View style={s.empty}><ActivityIndicator/><Text style={s.body}>Connecting to your Stack…</Text><Button label="Retry connection" onPress={refresh}/><Button label="Sign out" onPress={logout} secondary={True}/></View> if len(state)==0 else (
            <ScrollView contentContainerStyle={s.content} keyboardShouldPersistTaps="handled">
                <Text style={s.eyebrow}>LET’S MAKE THIS YOUR YEAR</Text><Text style={s.title}>A little about you.</Text><Text style={s.body}>We’ll use this to shape your job search. You can change it anytime.</Text>
                <Field label="Your name" value={name} onChange={lambda (v: str) { name=v; }}/><Field label="Target role" value={role} onChange={lambda (v: str) { role=v; }} placeholder="Separate several roles with commas"/><Field label="Expected graduation (YYYY-MM)" value={graduation} onChange={lambda (v: str) { graduation=v; }} placeholder="2027-05"/><Field label="Available full-time from (YYYY-MM)" value={availableFrom} onChange={lambda (v: str) { availableFrom=v; }} placeholder="Optional"/><Field label="Location" value={location} onChange={lambda (v: str) { location=v; }} placeholder="City and state, a state, or United States"/>
                <MatchInputs value={prefs} onChange={lambda (v: dict[str, any]) { prefs=v; }}/>
                <Button label="Find my next chapter" onPress={saveProfile} disabled={busy} icon="next"/>
            </ScrollView> if not state["profile"]["onboarded"] else (
            <View style={{flex:1}}>
                <View style={[s.between,{paddingHorizontal:24,paddingTop:13,paddingBottom:12}]}><View style={s.row}><Icon name="layers" size={26} color="#3765E8"/><Text style={s.brand}>stack</Text></View><View style={s.row}><AgentBadge summary={state.get("agents",{})} onPress={lambda { openAgents("Needs you" if state.get("agents",{}).get("attention",0)>0 else "Activity"); }}/><Pressable accessibilityLabel="Open profile" style={[s.avatar,{width:38,height:38,borderRadius:13,backgroundColor:"#E9EFFC"}]} onPress={lambda { modal="Profile"; error=""; }}><Text style={[s.avatarText,{fontSize:14}]}>{state["profile"]["name"][0:1].upper()}</Text></Pressable></View></View>
                <ScrollView style={s.grow} contentContainerStyle={s.content} keyboardShouldPersistTaps="handled">
                    {[<View key={"saved-"+a["id"]} style={s.savedCard} accessibilityLiveRegion="polite">
                        <View style={s.row}><Icon name="done" color="#167867"/><Text style={[s.heading,{flex:1}]}>Saved to Applications</Text></View>
                        <Text style={s.body}>{a["job"]["title"]+" · "+a["job"]["company"]}</Text>
                        <Text style={s.small}>{"Sample job. Agents work on real saved jobs." if a["demo"] else "Nothing was sent to the employer. Want agent help? It is optional, and anything outbound waits for your approval."}</Text>
                        {<AgentLaunch application={a} runs={state.get("agents",{}).get("runs",[])} features={state.get("agents",{}).get("features",[])} onOpenTask={openTask} onNavigate={navigate} compact={True}/> if not a["demo"] else <View/>}
                        <View style={s.wrap}><Chip label="View application" onPress={lambda { openRecord("application",a["id"]); }}/><Chip label="Done" onPress={lambda { savedJob=""; }}/></View>
                    </View> for a in state["applications"] if tab=="Jobs" and a["job_id"]==savedJob]}
                    {<View key={"jobs-"+str(profileRevision)}><Discovery decisions={state["decisions"]} saved={state.get("saved_search",{})} profile={state["profile"]} onSwipe={trackJob} disabled={busy}/></View> if tab=="Jobs" else <View/>}
                    {(
                        <View style={{gap:20}}><View style={{gap:7}}><Text style={s.eyebrow}>ONE STEP CLOSER</Text><Text style={s.title}>Your momentum.</Text><Text style={s.body}>Every opportunity, in one place.</Text></View>
                            <View style={s.row}><View style={s.stat}><Text style={s.statValue}>{str(len(state["applications"]))}</Text><Text style={s.small}>Applications</Text></View><View style={s.stat}><Text style={s.statValue}>{str(len([a for a in state["applications"] if a["status"]=="Interview"]))}</Text><Text style={s.small}>Interviews</Text></View><View style={s.stat}><Text style={s.statValue}>{str(len([r for r in state["reminders"] if not r["done"]]))}</Text><Text style={s.small}>Follow-ups</Text></View></View>
                            <ScrollView horizontal={True} showsHorizontalScrollIndicator={False} contentContainerStyle={{gap:8}}>{[<Chip key={f} label={f} active={applicationFilter==f} onPress={lambda { applicationFilter=f; }}/> for f in ["All","Ready to apply","Queued","Preparing","Submitted","Interview","Rejected"]]}</ScrollView>
                            {[<Pressable key={a["id"]} onPress={lambda { openRecord("application",a["id"]); }} style={s.card} accessibilityRole="button">
                                <View style={s.between}><View style={s.row}><Logo job={a["job"]}/><View style={s.grow}><Text style={s.strong}>{a["job"]["company"]}</Text><Text style={s.small}>{shortDate(a["created_at"])}</Text></View></View><Icon name="chevron" size={18}/></View>
                                <Text style={s.heading}>{a["job"]["title"]}</Text><View style={s.between}><Chip label={a["status"]+(" · Demo" if a["demo"] else "")} active={True}/><Text style={s.small}>View activity</Text></View>
                                {[<Text key={t["id"]} style={[s.small,{color:"#A4540F" if t["attention"] else "#3765E8",fontWeight:"700"}]}>{"✦ "+t["title"]+" · "+runLabel(t)}</Text> for t in runsFor(state.get("agents",{}).get("runs",[]),a["id"],["application","jobs","resume"])[0:1]]}
                            </Pressable> for a in state["applications"] if applicationFilter=="All" or a["status"]==applicationFilter]}
                            {<Empty title="Room for your next move." text="Swipe right on a job to save it here." icon="applications"/> if len([a for a in state["applications"] if applicationFilter=="All" or a["status"]==applicationFilter])==0 else <View/>}
                        </View>
                    ) if tab=="Applications" else <View/>}
                    {(
                        <View style={{gap:20}}><View style={{gap:7}}><Text style={s.eyebrow}>PEOPLE OPEN DOORS</Text><Text style={s.title}>Start a conversation.</Text><Text style={s.body}>A few thoughtful connections can go a long way.</Text></View>
                            <View style={s.row}>{[<Chip key={f} label={f} active={networkFilter==f} onPress={lambda { networkFilter=f; }}/> for f in ["Discover","Saved"]]}</View>
                            <NetworkAgent runs={state.get("agents",{}).get("runs",[])} features={state.get("agents",{}).get("features",[])} onOpenTask={openTask} onNavigate={navigate}/><View style={s.mutedBox}><Text style={s.small}>Sample people below are fictional examples, separate from your real contacts. Stack never messages them.</Text></View>
                            {[<Pressable key={c["id"]} style={s.card} accessibilityRole="button" onPress={lambda { openRecord("contact",c["id"]); }}>
                                <View style={s.row}><View style={[s.avatar,{backgroundColor:_find(state["people"],c["person_id"])["color"]}]}><Text style={s.avatarText}>{_find(state["people"],c["person_id"])["initials"]}</Text></View><View style={s.grow}><Text style={s.heading}>{_find(state["people"],c["person_id"])["name"]}</Text><Text style={s.small}>{_find(state["people"],c["person_id"])["role"]}</Text><Text style={s.small}>{_find(state["people"],c["person_id"])["company"]}</Text></View><Icon name={"bookmark" if c["saved"] else "arrow"} color="#3765E8" size={20}/></View>
                                <Text style={s.body}>{_find(state["people"],c["person_id"])["reason"]}</Text><Chip label={_find(state["people"],c["person_id"])["signal"]} active={True}/>
                            </Pressable> for c in state["contacts"] if networkFilter=="Discover" or c["saved"]]}
                            {<Empty title="Your circle starts here." text="Save someone from Discover to keep them close." icon="network"/> if networkFilter=="Saved" and len([c for c in state["contacts"] if c["saved"]])==0 else <View/>}
                        </View>
                    ) if tab=="Network" else <View/>}
                    {(
                        <View style={{gap:20}}><View style={{gap:7}}><Text style={s.eyebrow}>PUT YOUR BEST SELF FORWARD</Text><Text style={s.title}>Your story, on paper.</Text><Text style={s.body}>One home for your experience and potential.</Text></View>
                            <View style={{gap:4}}><Text style={s.label}>YOUR UPLOADS</Text><Text style={s.small}>Resumes you uploaded. Stack reads them and never changes them.</Text></View>
                            <Pressable style={[s.card,{borderStyle:"dashed",borderColor:"#B9CAEE",alignItems:"center",paddingVertical:27}]} onPress={upload} disabled={busy} accessibilityRole="button" accessibilityLabel="Upload PDF resume"><View style={[s.avatar,{backgroundColor:"#EDF2FF"}]}><Icon name="upload" color="#3765E8"/></View><Text style={s.heading}>Add your resume</Text><Text style={s.small}>Choose a PDF from Files · up to 10 MB</Text></Pressable>
                            {[<View key={r["id"]} style={s.card}><View style={s.row}><Icon name="resume" size={29} color="#3765E8"/><View style={s.grow}><Text style={s.strong}>{r["name"]}</Text><Text style={s.small}>{shortDate(r["created_at"])} · Private PDF</Text></View><Pressable accessibilityLabel="Manage resume" style={s.iconButton} onPress={lambda { selected=r["id"]; rename=r["name"]; modal="Manage resume"; }}><Icon name="more"/></Pressable></View>{<Chip label="Default resume" active={True}/> if state["selected_resume"]==r["id"] else <View/>}<Button label="Preview resume" onPress={lambda { preview(r["id"]); }} secondary={True} disabled={busy}/><Button label="Review details" secondary={True} onPress={lambda { extractFacts(r["id"]); }}/><ResumeFormat resume={r} onChanged={lambda (next: dict[str, any]) { state=next; }}/></View> for r in state["resumes"]]}
                            <TailoredResumes items={state.get("tailored_resumes",[])} onChanged={lambda (next: dict[str, any]) { state=next; }}/>
                            <ResumeAgents applications={state["applications"]} runs={state.get("agents",{}).get("runs",[])} features={state.get("agents",{}).get("features",[])} onOpenTask={openTask} onNavigate={navigate} resumes={state["resumes"]} onChanged={lambda (next: dict[str, any]) { state=next; }}/>
                            <View style={s.hero}><View style={s.row}><Icon name="sparkles" color="#3765E8"/><Text style={s.heading}>A resume for the role.</Text></View><Text style={s.body}>See how a tailored version could highlight the right experience.</Text><Button label="Explore a sample" secondary={True} onPress={lambda { modal="Tailoring preview"; }}/><Text style={s.small}>Demo preview. Your uploaded PDF is never modified.</Text></View>
                        </View>
                    ) if tab=="Resume" else <View/>}
                    {<Prep runs={state.get("agents",{}).get("runs",[])} features={state.get("agents",{}).get("features",[])} onOpenTask={openTask} onNavigate={navigate}/> if tab=="Prep" else <View/>}
                </ScrollView>
                <View style={s.tabBar}>{[<Pressable key={t} accessibilityRole="tab" accessibilityLabel={t} accessibilityState={{"selected":tab==t}} style={s.tab} onPress={lambda { tab=t; notice=""; }}><Icon name={t.lower()} size={23} color={"#3765E8" if tab==t else "#8E9BB0"}/><Text style={[s.tabText,s.tabActive if tab==t else {}]}>{t}</Text></Pressable> for t in ["Network","Applications","Jobs","Resume","Prep"]]}</View>
            </View>
            ))}
        </View>
        ))}
        <Modal visible={bool(modal)} animationType="slide" presentationStyle="pageSheet" onRequestClose={lambda { if not busy { modal=""; } }}>
            <KeyboardAvoidingView style={s.screen} behavior="padding">
                <View style={s.modalHeader}><Pressable accessibilityLabel="Close details" style={s.iconButton} disabled={busy} onPress={lambda { modal=returnModal if modal=="Reminder" else ""; error=""; }}><Icon name="back"/></Pressable><Text style={[s.heading,{flex:1}]}>{modal}</Text>{<ActivityIndicator color="#3765E8"/> if busy else <View/>}</View>
                {<View style={s.error}><Text style={s.errorText}>{error}</Text></View> if error else <View/>}
                {<View style={s.notice}><Text style={s.noticeText}>{notice}</Text></View> if notice else <View/>}
                {<PDFView uri={pdfUri}/> if modal=="PDF preview" else (
                <ScrollView contentContainerStyle={s.content} keyboardShouldPersistTaps="handled">
                    {<AgentHub key={"hub-"+str(hubOpenings)} summary={state.get("agents",{})} features={state.get("agents",{}).get("features",[])} applications={state.get("applications",[])} initialPage={hubPage} initialTask={hubTask} onNavigate={navigate}/> if modal=="Agents" and len(state)>0 else <View/>}
                    {<ResumeReview key={selected} resumeId={selected}/> if modal=="Resume details" else <View/>}
                    {(
                        <View style={{gap:20}}><View style={s.card}><View style={s.row}><View style={[s.avatar,{backgroundColor:"#E8EFFE",width:65,height:65}]}><Text style={[s.avatarText,{fontSize:25}]}>{state["profile"]["name"][0:1].upper()}</Text></View><View style={s.grow}><Text style={s.heading}>{state["profile"]["name"]}</Text><Text style={s.body}>{state["profile"]["role"]}</Text></View></View><Text style={s.body}>{state["profile"]["location"]} · {state["profile"]["mode"]}</Text><Button label="Edit profile & preferences" onPress={editProfile} secondary={True}/></View>
                            <Text style={s.heading}>Your agent connection.</Text><Text style={s.strong}>{state.get("agents",{}).get("model_provider",{}).get("provider","Not configured")}</Text><Text style={s.small}>{state.get("agents",{}).get("model_provider",{}).get("message","")}</Text><Button label="Agents: features, rules and activity" secondary={True} onPress={lambda { openAgents("Features"); }}/>
                            <View style={s.mutedBox}><View style={s.row}><Icon name="shield" size={19}/><Text style={s.strong}>Your space stays yours.</Text></View><Text style={s.small}>Account data and PDFs are stored on your Mac during development. Model requests share the selected task context with your configured provider.</Text></View>
                            <Button label="iPhone notification settings" onPress={openSettings} secondary={True} icon="bell"/><Button label="Sign out" onPress={logout} secondary={True} disabled={busy} icon="logout"/><Text style={[s.small,{textAlign:"center"}]}>Stack 0.1 · Built for your next chapter</Text>
                        </View>
                    ) if modal=="Profile" and len(state)>0 else <View/>}
                    {<View style={{gap:19}}><Field label="Your name" value={name} onChange={lambda (v: str) { name=v; }}/><Field label="Target role" value={role} onChange={lambda (v: str) { role=v; }} placeholder="Separate several roles with commas"/><Field label="Expected graduation (YYYY-MM)" value={graduation} onChange={lambda (v: str) { graduation=v; }} placeholder="2027-05"/><Field label="Available full-time from (YYYY-MM)" value={availableFrom} onChange={lambda (v: str) { availableFrom=v; }} placeholder="Optional"/><Field label="Location" value={location} onChange={lambda (v: str) { location=v; }} placeholder="City and state, a state, or United States"/><MatchInputs value={prefs} onChange={lambda (v: dict[str, any]) { prefs=v; }}/><View style={s.between}><Text style={s.strong}>Reminder notifications</Text><Switch value={notifications} onValueChange={lambda (v: bool) { notifications=v; }}/></View><Button label="Save preferences" onPress={saveProfile} disabled={busy}/></View> if modal=="Edit profile" else <View/>}
                    {<View style={{gap:20}}><Field label="Reminder title" value={reminderTitle} onChange={lambda (v: str) { reminderTitle=v; }}/><Text style={s.label}>When should we remind you?</Text><DateField value={reminderDue} onChange={lambda (v: float) { reminderDue=v; }}/><View style={s.wrap}><Chip label="In 1 minute" onPress={lambda { reminderDue=later(1); }}/><Chip label="Tomorrow" onPress={lambda { reminderDue=tomorrow(); }}/></View><Text style={s.small}>Once scheduled, your iPhone can deliver this reminder even when Stack and your Mac are closed.</Text><Button label="Save reminder" onPress={saveReminder} disabled={busy} icon="bell"/></View> if modal=="Reminder" else <View/>}
                    {<View style={{gap:18}}><Field label="Resume name" value={rename} onChange={lambda (v: str) { rename=v; }}/><Button label="Rename" onPress={lambda { mutate("change_resume",{"id":selected,"action":"rename","name":rename}); }} disabled={busy}/><Button label="Use as default resume" onPress={lambda { mutate("change_resume",{"id":selected,"action":"select"}); }} secondary={True} disabled={busy}/><Button label="Delete resume" onPress={lambda { confirmDelete("this resume",lambda { mutate("change_resume",{"id":selected,"action":"delete"}); }); }} secondary={True} disabled={busy}/></View> if modal=="Manage resume" else <View/>}
                    {<View style={{gap:18}}><Chip label="Sample tailoring · No AI run" active={True}/><Text style={s.title}>Same story. A sharper focus.</Text><View style={s.card}><Text style={s.eyebrow}>BASE RESUME · FICTIONAL EXAMPLE</Text><Text style={s.heading}>Jamie Chen</Text><Text style={s.body}>Computer Science Graduate{"\n\n"}Built a full-stack class project using React, Node.js, and PostgreSQL. Collaborated with three classmates.</Text></View><View style={[s.card,{borderColor:"#BACCF9"}]}><Text style={s.eyebrow}>TAILORED FOR SOFTWARE ENGINEER I</Text><Text style={s.heading}>Jamie Chen</Text><Text style={s.body}>Early-career engineer with hands-on React and TypeScript experience. Built accessible interfaces and REST APIs for a collaborative four-person project.</Text><View style={s.line}/><Text style={s.status}>Emphasizes relevant skills. Preserves the facts.</Text></View><Text style={s.small}>This illustrates the future workflow using fictional content. It is not derived from your uploaded resume.</Text></View> if modal=="Tailoring preview" else <View/>}
                    {[(
                        <View key={a["id"]} style={{gap:18}}><Logo job={a["job"]}/><Text style={s.title}>{a["job"]["title"]}</Text><Text style={s.body}>{a["job"]["company"]}</Text><Chip label={a["status"]+(" · Demo" if a["demo"] else "")} active={True}/>
                            {<View style={s.hero}><Text style={s.strong}>Your application activity</Text><Text style={s.body}>✓ Added to your Stack</Text><Text style={s.body}>{"◷ Preparing a sample application" if a["status"] in ["Queued","Preparing"] else "✓ Prepared a sample application"}</Text><Text style={s.body}>{"Submission pending · Demo" if a["status"] in ["Queued","Preparing"] else "✓ Simulated submission complete"}</Text><Text style={s.small}>No employer was contacted. This is a demonstration.</Text></View> if a["demo"] else <View style={s.hero}><Text style={s.strong}>Your next step</Text><Text style={s.body}>Apply at the source yourself, or use Prepare & apply below. Stack never submits without your approval.</Text><Button label="Open application page" disabled={not a["job"].get("url","")} onPress={lambda { openApplication(a["job"]["url"]); }}/><Button label="Mark as submitted" secondary={True} disabled={busy} onPress={lambda { mutate("mark_application_submitted",{"id":a["id"]},False); }}/></View>}
                            {<AgentLaunch application={a} runs={state.get("agents",{}).get("runs",[])} features={state.get("agents",{}).get("features",[])} onOpenTask={openTask} onNavigate={navigate}/> if not a["demo"] else <View/>}
                            {<View style={{gap:6}}><Text style={s.label}>STATUS HISTORY</Text>{[<Text key={str(h["at"])} style={s.small}>{h["status"]+" · "+dateTime(h["at"])+" · "+h["source"]}</Text> for h in a["history"]]}</View> if len(a["history"])>0 else <View/>}
                            <Text style={s.small}>{"Resume: "+_find(state["resumes"],a["resume_id"])["name"] if len(_find(state["resumes"],a["resume_id"]))>0 else "Resume: no personal PDF attached"}</Text>
                            <View style={s.wrap}><Chip label="No resume selected" active={a["resume_id"]==""} onPress={lambda { mutate("select_application_resume",{"id":selected,"resume_id":""},False); }}/>{[<Chip key={r["id"]} label={r["name"]} active={a["resume_id"]==r["id"]} onPress={lambda { mutate("select_application_resume",{"id":selected,"resume_id":r["id"]},False); }}/> for r in state["resumes"]]}</View>
                            <Field label="Your notes" value={notes} onChange={lambda (v: str) { notes=v; }} multiline={True}/><Button label="Save notes" onPress={lambda { mutate("save_application",{"id":selected,"notes":notes},False); }} disabled={busy}/><Button label="Add follow-up reminder" onPress={lambda { beginReminder("application",selected); }} secondary={True} icon="bell"/>
                        </View>
                    ) for a in state.get("applications",[]) if modal=="Application" and a["id"]==selected]}
                    {[(
                        <View key={c["id"]} style={{gap:18}}><View style={[s.avatar,{backgroundColor:_find(state["people"],c["person_id"])["color"],width:74,height:74}]}><Text style={[s.avatarText,{fontSize:24}]}>{_find(state["people"],c["person_id"])["initials"]}</Text></View><Text style={s.title}>{_find(state["people"],c["person_id"])["name"]}</Text><Text style={s.body}>{_find(state["people"],c["person_id"])["role"]} at {_find(state["people"],c["person_id"])["company"]}</Text><Chip label="Fictional person · Example only"/><Text style={s.body}>{_find(state["people"],c["person_id"])["bio"]}</Text>
                            <View style={s.hero}><Text style={s.strong}>Why connect?</Text><Text style={s.body}>{_find(state["people"],c["person_id"])["reason"]}</Text></View><Field label="Outreach draft" value={draft} onChange={lambda (v: str) { draft=v; }} multiline={True}/><Text style={s.small}>Edit and save your draft. Sending is not enabled.</Text><Field label="Private notes" value={notes} onChange={lambda (v: str) { notes=v; }} multiline={True}/>
                            <Button label="Save draft & notes" onPress={lambda { mutate("save_contact",{"id":selected,"saved":c["saved"],"draft":draft,"notes":notes},False); }} disabled={busy}/><Button label={"Remove from saved" if c["saved"] else "Save contact"} onPress={lambda { mutate("save_contact",{"id":selected,"saved":not c["saved"],"draft":draft,"notes":notes},False); }} disabled={busy} secondary={True} icon="bookmark"/><Button label="Add follow-up reminder" onPress={lambda { beginReminder("contact",selected); }} secondary={True} icon="bell"/>
                        </View>
                    ) for c in state.get("contacts",[]) if modal=="Contact" and c["id"]==selected]}
                    {<View style={{gap:13}}><Text style={s.heading}>Follow-ups</Text>{[<View key={r["id"]} style={s.card}><Text style={s.strong}>{r["title"]}</Text><Text style={s.body}>{"Completed" if r["done"] else dateTime(r["due_at"])}</Text><View style={s.wrap}>{<Chip label="Complete" onPress={lambda { mutate("change_reminder",{"id":r["id"],"action":"complete"},False); }}/> if not r["done"] else <View/>}<Chip label="Reschedule" onPress={lambda { editReminder(r); }}/><Chip label="Delete" onPress={lambda { mutate("change_reminder",{"id":r["id"],"action":"delete"},False); }}/></View></View> for r in state.get("reminders",[]) if r["target_id"]==selected]}</View> if modal in ["Application","Contact"] else <View/>}
                </ScrollView>)}
            </KeyboardAvoidingView>
        </Modal>
    </KeyboardAvoidingView>
}
