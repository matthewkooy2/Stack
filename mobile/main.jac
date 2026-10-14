import from .prototype.Views { templates }
import from "./prototype/app.js" { RootFrame, CombinedScreen, ReviewBridge, ReviewLegacyContent, ReviewModal }
import from "@jac/mobui" { View, Text, Pressable, ScrollView, Switch, KeyboardAvoidingView, ActivityIndicator }
import from "./device.js" { Icon, authenticate, restoreSession, rpc, signOut, errorText, isUnauthorized, shortDate, dateTime, tomorrow, later, pickResume, previewResume, reconcileNotifications, Lifecycle, SwipeSurface, DateField, PDFView, openSettings, confirmDelete, openJobLink, persistSwipe, uploadResumeFile, uploadProgressText, ResumeProcessing }
import from .theme { s }
import from .components.UI { Button, Field, Chip, Empty, Logo }
import from .components.Prep { Prep }
import from .components.Agents { AgentHub, AgentLaunch, AgentBadge, ResumeAgents, runsFor, runLabel }
import from .components.Network { NetworkAgent }
import from .components.Discovery { Discovery }
import from .components.MatchInputs { MatchInputs }
import from .components.ResumeRecords { ResumeRecords }
import from .components.BulletBank { BulletBank }
import from .components.ResumeFormat { ResumeFormat }
import from .components.TailoredResumes { TailoredResumes }
import from .components.Access { Welcome, StackAccess }
import from "./auth-marks.js" { authenticateSocial }
import from "./device.js" { realAuthEnabled, liveData, authenticateProvider, cancelGoogleSignIn, recoverGoogleAccount }
import from .components.AuthAccount { AuthAccount, InvitationGate }

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

def StackApp -> JsxElement {
    has logged: bool = False, starting: bool = True, busy: bool = False, refreshing: bool = False,
        pendingSwipes: int = 0, revision: int = 0, signup: bool = True, username: str = "", password: str = "", invite: str = "", error: str = "", notice: str = "",
        state: dict[str, any] = {}, tab: str = "Jobs", modal: str = "", selected: str = "", applicationFilter: str = "All", networkFilter: str = "Discover",
        name: str = "", role: str = "", location: str = "United States", mode: str = "Any", notifications: bool = True, graduation: str = "", availableFrom: str = "", prefs: dict[str, any] = {}, profileRevision: int = 0,
        notes: str = "", draft: str = "", rename: str = "", pdfUri: str = "", reminderId: str = "", reminderTitle: str = "", reminderDue: float = 0.0, targetType: str = "", targetId: str = "", returnModal: str = "", pendingOpen: dict[str, any] = {},
        uploadProgress: dict[str, any] = {}, hubPage: str = "Needs you", hubTask: str = "", hubOpenings: int = 0, savedJob: str = "", accessPage: str = "welcome",
        sessionReady: bool = False, googlePending: bool = False, googleInfo: dict[str, any] = {};

    def profileFields(source: dict[str, any] = {}) -> None {
        p=(source if source else state)["profile"]; name=p["name"]; role=p["role"]; location=p["location"]; mode=p["mode"]; notifications=p["notifications"];graduation=p.get("graduation_month","");availableFrom=p.get("available_from","");prefs=_preferenceForm(p);
    }
    async def logout -> None {
        busy=True;
        try { await signOut(); } except Exception as e { error=errorText(e); busy=False; return; }
        logged=False; sessionReady=False; googleInfo={}; state={}; modal=""; password=""; username=""; tab="Jobs"; pdfUri=""; notice=""; error=""; pendingOpen={}; busy=False;accessPage="welcome";
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
        # Refresh on arrival, so a result just produced in Agents (such as a tailored resume) is already listed.
        if destinations.get(action,"") { modal="";tab=destinations[action];refresh();return; }
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
            restored=await restoreSession();sessionReady=restored;
            if restored { await completeLogin(); }
        } except Exception as e { error=errorText(e); if isUnauthorized(e) { await logout(); } }
        starting=False;
    }
    async def login -> None {
        if busy { return; }
        if len(username.strip())<3 or len(password)<8 { error="Use a username of at least 3 characters and a password of at least 8."; return; }
        busy=True; error="";
        try {
            await authenticate(username,password,signup); password="";sessionReady=True;
            await completeLogin();
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def completeLogin -> None {
        googleInfo=await rpc("auth_google_status",{});
        if invite { await rpc("agent_accept_invite",{"invite":invite});invite=""; }
        admission=await rpc("agent_admission",{});
        if not admission.get("admitted") { error="Enter your beta invitation to continue.";return; }
        latest=await rpc("bootstrap",{});state=latest;logged=True;profileFields(latest);await reconcileNotifications(latest,False);
        if len(pendingOpen)>0 { notificationOpen(pendingOpen); }
    }
    async def acceptInvitation -> None {
        if busy { return; } busy=True;error="";
        try { await completeLogin(); } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def socialLogin(provider: str, link: bool = False) -> None {
        if busy { return; } busy=True;error="";googlePending=realAuthEnabled and provider=="google";
        try {
            result=await authenticateProvider(provider,link);
            if result {
                password="";
                sessionReady=True;await completeLogin();
                if link { notice="Google sign-in is linked to this Stack account."; }
            }
        } except Exception as e { error=errorText(e); }
        busy=False;googlePending=False;
    }
    async def recoverAccount(oldUsername: str, oldPassword: str) -> None {
        if busy { return; } busy=True;error="";
        try {
            await recoverGoogleAccount(oldUsername,oldPassword);revision+=1;logged=False;state={};modal="";sessionReady=True;
            await completeLogin();notice="Google is linked to your original account." if liveData else "Google is linked to your original account. This UI still uses demo feature data.";
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
            if file { state=await uploadResumeFile("upload_resume",file,lambda (value: dict[str, any]) { uploadProgress=value; }); notice="Your resume is saved privately."; }
        } except Exception as e { error=errorText(e); }
        busy=False;uploadProgress={};
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

    # Additional destinations used by Prep; existing tab navigation stays the same.
    def prepAwareNavigate(next: str) -> None {
        if next=="Agents" { openAgents("Activity"); }
        elif next=="features" { openAgents("Features"); }
        elif next=="resume-bank" { modal="Experience bank"; }
        elif next[0:5]=="task:" { openTask(next[5:]); }
        else { tab=next; }
    }

    async def reviewNavigate(screen: str) -> None {
        if screen in ["welcome","signup","signin"] {
            if logged { await logout(); }
            accessPage="welcome" if screen=="welcome" else "stack"; signup=screen!="signin"; error="";
        } else {
            if realAuthEnabled and not logged { error="Sign in before reviewing demo screens.";return; }
            if not logged { await socialLogin("google"); }
            modal="";
            if screen in ["Jobs","Applications","Network","Resume","Prep"] { tab=screen; }
            elif screen=="Edit profile" { editProfile(); }
            elif screen[0:7]=="Agents:" { openAgents(screen[7:]); }
            else { modal=screen; }
        }
    }

    <View style={s.screen if logged and len(state)>0 else s.accessScreen}>
        <ReviewBridge screen={modal or tab if logged else ("welcome" if accessPage=="welcome" else ("signup" if signup else "signin"))} onNavigate={reviewNavigate}/>
        <Lifecycle onRefresh={refresh} onOpen={notificationOpen}/>
        {<View style={{padding:8,backgroundColor:"#EEF2FC"}}><Text style={s.small}>Real account sign-in · Demo feature data</Text></View> if realAuthEnabled and not liveData else <View/>}
        {<Button label="Cancel Google sign-in" secondary={True} onPress={cancelGoogleSignIn}/> if googlePending or (starting and realAuthEnabled) else <View/>}
        {<View style={[s.empty,{flex:1,justifyContent:"center"}]}><Text style={s.brand}>stack</Text><ActivityIndicator color="#3765E8"/></View> if starting else (
        (<InvitationGate value={invite} onChange={lambda (v: str) { invite=v; }} onSubmit={acceptInvitation} onSignOut={logout} busy={busy} error={error} info={googleInfo} onRecover={recoverAccount}/> if sessionReady else (<Welcome onStack={lambda { accessPage="stack";error=""; }} onProvider={socialLogin} busy={busy} error={error}/> if accessPage=="welcome" else <StackAccess username={username} password={password} invite={invite} signup={signup} busy={busy} error={error} onUsername={lambda (v: str) { username=v; }} onPassword={lambda (v: str) { password=v; }} onInvite={lambda (v: str) { invite=v; }} onSubmit={login} onToggle={lambda { signup=not signup;error=""; }} onBack={lambda { accessPage="welcome";password="";error=""; }}/>)) if not logged else (
        <CombinedScreen screen={tab} templates={templates} onNavigate={prepAwareNavigate} onProfile={lambda { modal="Profile"; }}/>
        ))}
        <ReviewModal visible={bool(modal)} animationType="slide" presentationStyle="pageSheet" onRequestClose={lambda { if not busy { modal=""; } }}>
            <KeyboardAvoidingView style={s.screen} behavior="padding">
                <View style={s.modalHeader}><Pressable accessibilityLabel="Close details" style={s.iconButton} disabled={busy} onPress={lambda { modal=returnModal if modal=="Reminder" else ""; error=""; }}><Icon name="back"/></Pressable><Text style={[s.heading,{flex:1}]}>{modal}</Text>{<ActivityIndicator color="#3765E8"/> if busy else <View/>}</View>
                {<View style={s.error}><Text style={s.errorText}>{error}</Text></View> if error else <View/>}
                {<View style={s.notice}><Text style={s.noticeText}>{notice}</Text></View> if notice else <View/>}
                {<PDFView uri={pdfUri}/> if modal=="PDF preview" else (
                <ScrollView contentContainerStyle={s.content} keyboardShouldPersistTaps="handled">
                    <ReviewLegacyContent>
                    {<Button label="Your experience bank" secondary={True} icon="resume" onPress={lambda { modal="Experience bank"; }}/> if modal=="Profile" else <View/>}
                    {<AuthAccount info={googleInfo} busy={busy} pending={googlePending} onLink={lambda { socialLogin("google",True); }} onCancel={cancelGoogleSignIn} onRecover={recoverAccount}/> if realAuthEnabled and modal=="Profile" else <View/>}
                    {<AgentHub key={"hub-"+str(hubOpenings)} summary={state.get("agents",{})} features={state.get("agents",{}).get("features",[])} applications={state.get("applications",[])} initialPage={hubPage} initialTask={hubTask} onNavigate={navigate}/> if modal=="Agents" and len(state)>0 else <View/>}
                    {<BulletBank onChanged={lambda (next: dict[str, any]) { state=next; }}/> if modal=="Experience bank" else <View/>}
                    {<ResumeRecords id={selected} onChanged={lambda (next: dict[str, any]) { state=next; }}/> if modal=="Resume details" else <View/>}
                    {(
                        <View style={{gap:20}}><View style={s.card}><View style={s.row}><View style={[s.avatar,{backgroundColor:"#E8EFFE",width:65,height:65}]}><Text style={[s.avatarText,{fontSize:25}]}>{state["profile"]["name"][0:1].upper()}</Text></View><View style={s.grow}><Text style={s.heading}>{state["profile"]["name"]}</Text><Text style={s.body}>{state["profile"]["role"]}</Text></View></View><Text style={s.body}>{state["profile"]["location"]} · {state["profile"]["mode"]}</Text><Button label="Edit profile & preferences" onPress={editProfile} secondary={True}/></View>
                            <Text style={s.heading}>Your agent connection.</Text><Text style={s.strong}>{state.get("agents",{}).get("model_provider",{}).get("provider","Not configured")}</Text><Text style={s.small}>{state.get("agents",{}).get("model_provider",{}).get("message","")}</Text><Button label="Agents: features, rules and activity" secondary={True} onPress={lambda { openAgents("Features"); }}/>
                            <View style={s.mutedBox}><View style={s.row}><Icon name="shield" size={19}/><Text style={s.strong}>Your space stays yours.</Text></View><Text style={s.small}>{"Your resumes, applications, contacts and practice are saved to your Stack account. Nothing is sent to an employer, a contact or a model provider unless you approve it." if liveData else "This prototype stores mock data on this device. Agent actions are simulated; no employer, email service, or model provider is contacted."}</Text></View>
                            <Button label="iPhone notification settings" onPress={openSettings} secondary={True} icon="bell"/><Button label="Sign out" onPress={logout} secondary={True} disabled={busy} icon="logout"/><Text style={[s.small,{textAlign:"center"}]}>Stack 0.1 · Built for your next chapter</Text>
                        </View>
                    ) if modal=="Profile" and len(state)>0 else <View/>}
                    {<View style={{gap:19}}><Field label="Your name" value={name} onChange={lambda (v: str) { name=v; }}/><Field label="Target role" value={role} onChange={lambda (v: str) { role=v; }} placeholder="Separate several roles with commas"/><Field label="Expected graduation (YYYY-MM)" value={graduation} onChange={lambda (v: str) { graduation=v; }} placeholder="2027-05"/><Field label="Available full-time from (YYYY-MM)" value={availableFrom} onChange={lambda (v: str) { availableFrom=v; }} placeholder="Optional"/><Field label="Location" value={location} onChange={lambda (v: str) { location=v; }} placeholder="City and state, a state, or United States"/><MatchInputs value={prefs} onChange={lambda (v: dict[str, any]) { prefs=v; }}/><View style={s.between}><Text style={s.strong}>Reminder notifications</Text><Switch value={notifications} onValueChange={lambda (v: bool) { notifications=v; }}/></View><Button label="Save preferences" onPress={saveProfile} disabled={busy}/></View> if modal=="Edit profile" else <View/>}
                    {<View style={{gap:20}}><Field label="Reminder title" value={reminderTitle} onChange={lambda (v: str) { reminderTitle=v; }}/><Text style={s.label}>When should we remind you?</Text><DateField value={reminderDue} onChange={lambda (v: float) { reminderDue=v; }}/><View style={s.wrap}><Chip label="In 1 minute" onPress={lambda { reminderDue=later(1); }}/><Chip label="Tomorrow" onPress={lambda { reminderDue=tomorrow(); }}/></View><Text style={s.small}>Once scheduled, your iPhone can deliver this reminder even when Stack and your Mac are closed.</Text><Button label="Save reminder" onPress={saveReminder} disabled={busy} icon="bell"/></View> if modal=="Reminder" else <View/>}
                    {<View style={{gap:18}}><Field label="Resume name" value={rename} onChange={lambda (v: str) { rename=v; }}/><Button label="Rename" onPress={lambda { mutate("change_resume",{"id":selected,"action":"rename","name":rename}); }} disabled={busy}/><Button label="Use as default resume" onPress={lambda { mutate("change_resume",{"id":selected,"action":"select"}); }} secondary={True} disabled={busy}/><Button label="Delete resume" onPress={lambda { confirmDelete("this resume",lambda { mutate("change_resume",{"id":selected,"action":"delete"}); }); }} secondary={True} disabled={busy}/></View> if modal=="Manage resume" else <View/>}
                    {<View style={{gap:18}}><Chip label="Sample tailoring · No AI run" active={True}/><Text style={s.title}>Same story. A sharper focus.</Text><View style={s.card}><Text style={s.eyebrow}>BASE RESUME · FICTIONAL EXAMPLE</Text><Text style={s.heading}>Jamie Chen</Text><Text style={s.body}>Computer Science Graduate{"\n\n"}Built a full-stack class project using React, Node.js, and PostgreSQL. Collaborated with three classmates.</Text></View><View style={[s.card,{borderColor:"#BACCF9"}]}><Text style={s.eyebrow}>TAILORED FOR SOFTWARE ENGINEER I</Text><Text style={s.heading}>Jamie Chen</Text><Text style={s.body}>Early-career engineer with hands-on React and TypeScript experience. Built accessible interfaces and REST APIs for a collaborative four-person project.</Text><View style={s.line}/><Text style={s.status}>Emphasizes relevant skills. Preserves the facts.</Text></View><Text style={s.small}>This illustrates the future workflow using fictional content. It is not derived from your uploaded resume.</Text></View> if modal=="Tailoring preview" else <View/>}
                    {[(
                        <View key={a["id"]} style={{gap:18}}><Logo job={a["job"]}/><Text style={s.title}>{a["job"]["title"]}</Text><Text style={s.body}>{a["job"]["company"]}</Text><Chip label={a["status"]+(" · Demo" if a["demo"] else "")} active={True}/>
                            {<View style={s.hero}><Text style={s.strong}>Your application activity</Text><Text style={s.body}>✓ Added to your Stack</Text><Text style={s.body}>{"◷ Preparing a sample application" if a["status"] in ["Queued","Preparing"] else "✓ Prepared a sample application"}</Text><Text style={s.body}>{"Submission pending · Demo" if a["status"] in ["Queued","Preparing"] else "✓ Simulated submission complete"}</Text><Text style={s.small}>No employer was contacted. This is a demonstration.</Text></View> if a["demo"] else <View style={s.hero}><Text style={s.strong}>Your next step</Text><Text style={s.body}>Open the application page to apply yourself, then mark it as submitted here.</Text><Button label="Open application page" disabled={not a["job"].get("url","")} onPress={lambda { openApplication(a["job"]["url"]); }}/><Button label="Mark as submitted" secondary={True} disabled={busy} onPress={lambda { mutate("mark_application_submitted",{"id":a["id"]},False); }}/></View>}
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
                </ReviewLegacyContent>
                </ScrollView>)}
            </KeyboardAvoidingView>
        </ReviewModal>
    </View>
}

def:pub app -> JsxElement { return <RootFrame><StackApp/></RootFrame>; }
