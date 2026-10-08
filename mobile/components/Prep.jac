import from "react" { useEffect, useRef }
import from "../audio-recording.js" { useRecording, localRecordings, saveLocalRecording, recordingContent, recordingClock, AnswerPlayback, cacheAnswerAudio }
import from "@jac/mobui" { View, Text, Pressable, TextInput, StyleSheet, useWindowDimensions }
import from "../device.js" { Icon, errorText, uploadResumeFile }
import from "../prep-session.js" { prepRpc as rpc }
import from "../prep-motion.js" { PrepStage, Reveal, Tap, Pop, Halo, Breathe, FadeSwitch }

glob cream = StyleSheet.create({
    page:{flex:1,gap:24,paddingTop:8,paddingBottom:16},
    title:{fontSize:34,lineHeight:41,fontWeight:"700",letterSpacing:-1,color:"#2C1D10"},
    body:{fontSize:18,lineHeight:27,color:"#3F3022"},
    muted:{fontSize:15,lineHeight:23,color:"#927E69"},
    back:{width:44,height:44,borderRadius:22,backgroundColor:"#FFF3D3",alignItems:"center",justifyContent:"center"},
    option:{minHeight:72,paddingHorizontal:22,paddingVertical:20,borderRadius:20,backgroundColor:"#FFF8D5",flexDirection:"row",alignItems:"center",gap:22},
    optionText:{fontSize:21,lineHeight:27,color:"#302013",flex:1},
    button:{minHeight:58,padding:17,borderRadius:20,backgroundColor:"#FFF5CB",alignItems:"center",justifyContent:"center",flexDirection:"row",gap:14},
    buttonText:{fontSize:19,color:"#302013",textAlign:"center"},
    card:{padding:22,borderRadius:22,backgroundColor:"#FFF8D5",gap:16},
    input:{fontSize:18,lineHeight:27,color:"#3F3022",padding:20,minHeight:180,borderRadius:20,backgroundColor:"#FFF6DC",textAlignVertical:"top"},
    row:{flexDirection:"row",alignItems:"center",gap:14},
    link:{padding:14,alignItems:"center",minHeight:48},
    homeRow:{flexDirection:"row",alignItems:"center",gap:24,paddingVertical:22,borderBottomWidth:1,borderBottomColor:"#E8D6AF"},
    circle:{width:30,height:30,borderRadius:15,borderWidth:1,borderColor:"#D7CCB5",alignItems:"center",justifyContent:"center"}
});
def:pub PrepButton(label: str, onPress: any, disabled: bool = False, icon: str = "", secondary: bool = False, dark: bool = False) -> JsxElement {
    <Tap accessibilityRole="button" accessibilityLabel={label} disabled={disabled} onPress={onPress} pressedScale={0.985 if secondary else 0.97} style={[cream.link if secondary else cream.button,{backgroundColor:"#5A4729",borderRadius:32,alignSelf:"flex-start",paddingHorizontal:26} if dark else {}]}>
        {<Icon name={icon} color="#39281A" size={25}/> if icon else None}
        <Text style={[cream.muted if secondary else cream.buttonText,{color:"#FFFDE7"} if dark else {}]}>{label}</Text>
    </Tap>
}
def:pub PrepOption(label: str, icon: str, onPress: any, disabled: bool = False, oat: bool = False, index: int = 0) -> JsxElement {
    <Reveal index={index}>
        <Tap accessibilityRole="button" accessibilityLabel={label} disabled={disabled} onPress={onPress} pressedScale={0.98} style={[cream.option,{backgroundColor:"#FFF1D8" if oat else "#FFF8D5"}]}>
            <Icon name={icon} size={32} color="#342416"/><Text style={cream.optionText}>{label}</Text><Icon name="chevron" color="#927E69" size={23}/>
        </Tap>
    </Reveal>
}
def:pub Prep(owner: str = "", runs: list[dict[str, any]] = [], features: list[dict[str, any]] = [], onOpenTask: any = None, onNavigate: any = None, onStage: any = None, availableHeight: float = 0.0, legacyContent: any = None) -> JsxElement {
    has idea: bool = False, loaded: bool = False, page: str = "home", focus: str = "Mixed questions", sessions: list[dict[str, any]] = [],
        catalog: list[dict[str, any]] = [], current: dict[str, any] = {}, draft: str = "", error: str = "", busy: bool = False, saving: bool = False,
        clientTranscripts: bool = False, runtime: dict[str, any] = {}, archived: dict[str, any] = {}, local: dict[str, any] = {}, recording: dict[str, any] = {}, run: dict[str, any] = {}, feedback: dict[str, any] = {};
    capture=useRecording(owner);dimensions=useWindowDimensions();
    useEffect(lambda { if onStage { onStage(page); } },[page]);
    control=useRef({"busy":False,"epoch":0,"polling":False,"dirty":False,"autosaveError":False});
    async def reload -> None {
        result=await rpc("prep_sessions",{});sessions=[row for row in result["sessions"] if row["data"].get("behavioral")];
        result=await rpc("transcription_list",{});runtime=result.get("runtime",{});clientTranscripts=result.get("client_transcripts",False);
    }
    async can with entry {
        try { result=await rpc("prep_catalog",{});catalog=result["problems"];await reload(); }
        except Exception as e { error=errorText(e); }
        loaded=True;
    }
    useEffect(lambda { return lambda { control.current["epoch"]+=1; }; },[]);
    async def save(value: dict[str, any]) -> None {
        current=await rpc("prep_save",{"id":current["id"],"revision":current["revision"],"data":value});
        await reload();
    }
    async def begin(count: int) -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";
        try {
            bases=["project","disagreement","setback"] if focus=="Mixed questions" else ["project" if focus=="Projects and ownership" else ("disagreement" if focus=="Teamwork and disagreement" else "setback")];
            plan=[bases[i % len(bases)]+("-"+str(Math.floor(i/len(bases))+1) if i>=len(bases) else "") for i in range(count)];
            if idea { plan=["disagreement-2"]+[id for id in plan if id!="disagreement-2"];plan=plan[0:count]; }
            current=await rpc("prep_create",{"problem_id":plan[0]});
            await save({**current["data"],"behavioral":{"focus":focus,"plan":plan,"index":0,"history":[],"complete":False}});
            draft="";control.current["dirty"]=False;feedback={};run={};local={};recording={};page="question";
        } except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def openSession(id: str) -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";
        try {
            control.current["epoch"]+=1;current=await rpc("prep_get",{"id":id});draft=current["data"].get("answer","");control.current["dirty"]=bool(draft);
            matches=[f for f in current.get("feedback",[]) if f["revision"]==current["revision"]];feedback=matches[-1]["data"] if len(matches)>0 else {};
            if len(feedback)==0 and current["data"]["behavioral"].get("complete") { history=current["data"]["behavioral"].get("history",[]);feedback=history[-1].get("feedback",{}) if len(history)>0 else {}; }
            rows=await localRecordings(owner);matches=[r for r in rows if r["client_id"]==current["data"]["behavioral"].get("local_id","") or (not current["data"]["behavioral"].get("local_id") and r.get("prep_session")==id and r.get("question_index")==current["data"]["behavioral"]["index"])];local=matches[0] if len(matches)>0 else {};
            recording={};rid=current["data"]["behavioral"].get("recording_id","");
            if rid { recording=await rpc("transcription_get",{"id":rid});if len(local)==0 { audio=await rpc("transcription_audio",{"id":rid});local=await cacheAnswerAudio(owner,rid,audio["content"]); } }
            result=await rpc("agent_activity",{});matches=[r for r in result.get("runs",[]) if r.get("target_id")==id and r.get("kind")=="prep" and r.get("session_revision")==current["revision"]];run=matches[0] if len(matches)>0 else {};
            page="coaching" if len(feedback)>0 else ("processing" if run.get("status") in ["queued","running","needs_input","blocked","failed","cancelled"] else ("review" if draft or len(local)>0 or len(recording)>0 else "question"));
        } except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def persistAnswer -> None {
        value={**current["data"],"answer":draft,"transcript":draft if len(recording)>0 else "", "behavioral":{**current["data"]["behavioral"],"local_id":local.get("client_id",""),"recording_id":recording.get("id","")}};
        if JSON.stringify(value)!=JSON.stringify(current["data"]) { await save(value); }
    }
    async def autoSave -> None {
        if control.current["busy"] or control.current["autosaveError"] or not current.get("id") or current["data"].get("answer","")==draft { return; }
        control.current["busy"]=True;saving=True;
        try { await persistAnswer(); }
        except Exception as e { error="Your answer is kept on screen. Save again when connected. "+errorText(e);control.current["autosaveError"]=True; }
        control.current["busy"]=False;saving=False;
    }
    useEffect(lambda {
        if page in ["answer","review"] and not busy and not saving {
            timer=setTimeout(autoSave,900);return lambda { clearTimeout(timer); };
        }
    },[draft,page,current.get("id",""),busy,saving]);
    async def viewSaved(answer: dict[str, any]) -> None {
        error="";
        try {
            rows=await localRecordings(owner);matches=[r for r in rows if r["client_id"]==answer.get("local_id")];
            saved=matches[0] if len(matches)>0 else {};
            if len(saved)==0 and answer.get("recording_id") { audio=await rpc("transcription_audio",{"id":answer["recording_id"]});saved=await cacheAnswerAudio(owner,answer["recording_id"],audio["content"]); }
            archived={**answer,"uri":saved.get("uri","")};page="saved-answer";
        } except Exception as e { error=errorText(e); }
    }
    async def back -> None {
        if busy or saving or capture.recording or capture.paused { return; }
        error="";
        control.current["epoch"]+=1;
        if page=="type" { page="home";return; }
        if page=="focus" { page="type";return; }
        if page=="length" { page="home" if idea else "focus";return; }
        if page=="history" { page="coaching";return; }
        if page=="saved-answer" { page="history";return; }
        if page in ["answer","review"] {
            control.current["busy"]=True;busy=True;
            try { await persistAnswer();page="home"; }
            except Exception as e { error=errorText(e); }
            control.current["busy"]=False;busy=False;return;
        }
        page="home";await reload();
    }
    async def recordAnswer -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";
        try { saved=await capture.start({"sessionId":current["id"],"questionIndex":current["data"]["behavioral"]["index"]});local=saved;recording={};draft=saved.get("transcript","");feedback={};control.current["dirty"]=False;page="recording";await persistAnswer(); }
        except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def uploadAnswer -> None {
        payload=await recordingContent(local);
        if clientTranscripts and local.get("original_transcript") { payload={**payload,"local_transcript":local["original_transcript"]}; }
        recording=await uploadResumeFile("transcription_upload",payload,lambda (value: any) {});
        local=await saveLocalRecording(owner,{**local,"server_id":recording["id"],"status":"uploaded"});await persistAnswer();
    }
    async def togglePause -> None {
        if busy { return; }
        error="";
        try { if capture.paused { await capture.resume(); } else { await capture.pause(); } }
        except Exception as e { error=errorText(e); }
    }
    async def finishAnswer -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";
        try {
            saved=await capture.stop();
            if not saved { saved=capture.current; }
            if not saved { error="No audio was saved. Record your answer again."; }
            else { local=saved;draft=saved.get("transcript","");control.current["dirty"]=bool(draft);recording={};await persistAnswer();page="review";await uploadAnswer(); }
        } except Exception as e { error=errorText(e);page="review"; }
        control.current["busy"]=False;busy=False;
    }
    async def retryUpload -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";
        try { await uploadAnswer(); } except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def coach -> None {
        if control.current["busy"] or not draft.strip() { return; }
        control.current["busy"]=True;busy=True;error="";
        try { await persistAnswer();feedback={};run=await rpc("agent_start",{"kind":"prep","target_id":current["id"]});page="processing"; }
        except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def poll -> None {
        if control.current["busy"] or control.current["polling"] { return; }
        control.current["polling"]=True;epoch=control.current["epoch"];
        try {
            if recording.get("id") and recording.get("status")!="completed" {
                result=await rpc("transcription_get",{"id":recording["id"]});
                readiness=await rpc("transcription_list",{});if epoch==control.current["epoch"] { runtime=readiness.get("runtime",{}); }
                if epoch==control.current["epoch"] { recording=result;if result["status"]=="completed" and not control.current["dirty"] { draft=result["transcript"];control.current["dirty"]=True; } }
            }
            if page=="processing" {
                result=await rpc("prep_get",{"id":current["id"]});matches=[f for f in result.get("feedback",[]) if f["revision"]==current["revision"]];
                if epoch==control.current["epoch"] {
                    if len(matches)>0 { current=result;feedback=matches[-1]["data"];page="coaching";await reload(); }
                    elif run.get("id") { result=await rpc("agent_run",{"id":run["id"]});if epoch==control.current["epoch"] { run=result; } }
                }
            }
        } except Exception as e { if epoch==control.current["epoch"] { error=errorText(e); } }
        control.current["polling"]=False;
    }
    useEffect(lambda { timer=setInterval(poll,2000);return lambda { clearInterval(timer); }; },[page,current.get("id",""),recording.get("id",""),recording.get("status","")]);
    async def retryCoach -> None {
        if control.current["busy"] { return; }control.current["busy"]=True;busy=True;error="";
        try {
            if run.get("status")=="needs_input" { await rpc("agent_respond",{"id":run["id"],"values":[],"reuse":True}); }
            else { await rpc("agent_retry",{"id":run["id"]}); }
        } except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def nextAnswer -> None {
        if control.current["busy"] { return; }control.current["busy"]=True;busy=True;error="";
        try {
            w=current["data"]["behavioral"];last=w["index"]+1==len(w["plan"]);
            history=[h for h in w["history"] if h.get("index")!=w["index"]]+[{"index":w["index"],"problem_id":current["data"]["problem_id"],"answer":draft,"feedback":feedback,"local_id":local.get("client_id",""),"recording_id":recording.get("id","")}];
            index=w["index"] if last else w["index"]+1;
            await save({**current["data"],"problem_id":w["plan"][index],"answer":draft if last else "","transcript":"","behavioral":{**w,"index":index,"history":history,"complete":last,"local_id":local.get("client_id","") if last else "","recording_id":recording.get("id","") if last else ""}});
            if last { page="complete"; }
            else { draft="";control.current["dirty"]=False;local={};recording={};feedback={};run={};page="question"; }
        } except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    w=current.get("data",{}).get("behavioral",{});index=w.get("index",0);plan=w.get("plan",[]);
    questions=[q for q in catalog if q["id"]==current.get("data",{}).get("problem_id")];question=questions[0] if len(questions)>0 else {};
    activeSessions=[r for r in sessions if not r["data"]["behavioral"].get("complete")];
    practiced=[new(Date,r["updated_at"]*1000).toDateString() for r in sessions if r["data"]["behavioral"].get("complete") or len(r["data"]["behavioral"].get("history",[]))>0];
    today: any=new(Date);week=[new(Date,Date.now()-( (today.getDay()+6)%7-i)*86400000).toDateString() for i in range(7)];practiceCount=len([d for d in week if d in practiced]);
    rubric=feedback.get("rubric",[]);strengths=[r for r in rubric if r.get("score",0)>=3];improvements=[r for r in rubric if r.get("score",0)<3];
    statusLabels={"queued":"Waiting to start","running":"Writing your coaching","needs_input":"Needs your input","blocked":"Blocked","failed":"Couldn’t finish","cancelled":"Cancelled"};
    <View style={[cream.page,{minHeight:Math.max(520,availableHeight-42 if availableHeight>0 else dimensions.height-(215 if page=="home" else 140))}]}>
        <PrepStage pageKey={page} step={index}>
        {<Tap accessibilityRole="button" accessibilityLabel="Back to Prep" disabled={busy or saving or capture.recording or capture.paused} dim={1.0} pressedScale={0.92} onPress={back} style={cream.back}><Icon name="return" color="#8B745F" size={24}/></Tap> if page!="home" else None}
        {<Text style={cream.muted}>{"Question "+str(index+1)+" of "+str(len(plan))}</Text> if page in ["question","answer","recording","review","processing","coaching"] else None}
        {<Text style={[cream.title,{fontSize:40,lineHeight:48}]}>Prep</Text> if page=="home" else None}
        {<View style={{gap:0}}>
            {[<Reveal key={item[0]} index={i}><Tap accessibilityRole="button" accessibilityLabel={item[0]} disabled={busy} dim={1.0} pressedScale={0.985} onPress={lambda { error="";idea=False;page="type" if item[0]=="New session" else ("continue" if item[0]=="Continue session" else "past"); }} style={cream.homeRow}><Icon name={item[1]} size={31} color="#342416"/><Text style={cream.optionText}>{item[0]}</Text><Icon name="chevron" color="#927E69"/></Tap></Reveal> for (i,item) in enumerate([("New session","add-session"),("Continue session","continue-session"),("Past sessions","clock")])]}
            <Reveal index={3}><View style={[cream.card,{marginTop:28,backgroundColor:"#FFFBCB"}]}><Text style={cream.muted}>Session idea</Text><Text style={[cream.body,{fontSize:23,lineHeight:31}]}>Tell me about a time you changed your mind.</Text><PrepButton label="Start session" dark={True} onPress={lambda { focus="Teamwork and disagreement";idea=True;page="length"; }}/></View></Reveal>
            <Reveal index={4}><FadeSwitch show={loaded} keep={True}><View style={{gap:16,marginTop:28}}><View style={cream.row}><Icon name="sparkles" color="#927E69"/><Text style={cream.body}>{str(practiceCount)+(" practice day this week" if practiceCount==1 else " practice days this week")}</Text></View><View style={{flexDirection:"row",justifyContent:"space-between"}}>{[<View key={str(i)} style={{alignItems:"center",gap:10}}><Text style={cream.muted}>{["M","T","W","T","F","S","S"][i]}</Text><View style={[cream.circle,{backgroundColor:"#E6D1A0" if day in practiced else "transparent"}]}>{<Pop delay={250+i*70}><Icon name="check" size={19} color="#342416"/></Pop> if day in practiced else None}</View></View> for (i,day) in enumerate(week)]}</View></View></FadeSwitch></Reveal>
            <Reveal index={5}><PrepButton label="More practice tools" secondary={True} onPress={lambda { page="legacy"; }}/></Reveal>
        </View> if page=="home" else None}
        {<Text style={cream.title}>{"Choose your session type" if page=="type" else ("Choose your focus" if page=="focus" else "Choose your session length")}</Text> if page in ["type","focus","length"] else None}
        {<View style={{flex:1,minHeight:110}}/> if page in ["type","focus","length"] else None}
        {<View style={{gap:12}}><PrepOption label="Behavioral" icon="chat" index={0} onPress={lambda { page="focus"; }}/><PrepOption label="Technical" icon="code" oat={True} index={1} onPress={lambda { page="legacy"; }}/></View> if page=="type" else None}
        {<View style={{gap:12}}>{[<PrepOption key={choice[0]} label={choice[0]} icon={choice[1]} oat={i%2==1} index={i} onPress={lambda { focus=choice[0];page="length"; }}/> for (i,choice) in enumerate([("Mixed questions","shuffle"),("Projects and ownership","applications"),("Teamwork and disagreement","network"),("Setbacks and learning","sprout")])]}</View> if page=="focus" else None}
        {<View style={{gap:12}}>{[<PrepOption key={str(count)} label={str(count)+(" question" if count==1 else " questions")} icon="question-file" oat={count==3} index={i} disabled={busy or len(catalog)==0} onPress={lambda { begin(count); }}/> for (i,count) in enumerate([1,3,5])]}</View> if page=="length" else None}
        {<Reveal index={0}><View style={{gap:14}}><Text style={cream.title}>{question.get("prompt","")}</Text></View></Reveal> if page in ["question","answer"] else None}
        {<View style={{flex:1,minHeight:100}}/> if page=="question" else None}
        {<Reveal index={2}><View style={{gap:12}}><PrepButton label="Record answer" icon="mic" disabled={busy} onPress={recordAnswer}/><PrepButton label="Type instead" secondary={True} onPress={lambda { page="answer"; }}/></View></Reveal> if page=="question" else None}
        {<View style={{gap:18}}><TextInput accessibilityLabel="Your answer" editable={not busy} style={cream.input} value={draft} onChangeText={lambda (v: str) { draft=v;control.current["dirty"]=True;control.current["autosaveError"]=False; }} multiline={True} placeholder="Your answer…" placeholderTextColor="#927E69"/><PrepButton label="Review your answer" disabled={busy or saving or not draft.strip()} onPress={lambda { page="review"; }}/></View> if page=="answer" else None}
        {<View style={{gap:24,flex:1}}><Text style={cream.title}>Record your answer</Text><Text style={cream.body}>{question.get("prompt","")}</Text><View style={[cream.card,{minHeight:180,justifyContent:"center",alignItems:"center"}]}><Halo active={capture.recording and not capture.paused} size={76}><Icon name="mic" size={50} color="#342416"/></Halo><Text style={cream.body}>{"Paused" if capture.paused else ("Recording" if capture.recording else "Recording stopped")}</Text><Text style={[cream.title,{fontVariant:["tabular-nums"]}]}>{recordingClock(capture.elapsed)}</Text></View><Text style={cream.muted}>Up to five minutes. Locking your phone stops and keeps the recording.</Text><View style={{flex:1}}/><PrepButton label="Finish answer" onPress={finishAnswer} disabled={busy}/><PrepButton label={"Resume" if capture.paused else "Pause"} onPress={togglePause} disabled={busy or (not capture.recording and not capture.paused)} secondary={True}/></View> if page=="recording" else None}
        {<View style={{gap:20}}><Text style={cream.title}>Review your answer</Text><Text style={cream.muted}>{question.get("title","")}</Text>{<AnswerPlayback uri={local["uri"]}/> if local.get("uri") else None}
            {<Reveal><View style={cream.card}><Breathe active={recording.get("status") not in ["failed","cancelled"] and runtime.get("status")!="unavailable"}><Text style={cream.body}>{"Transcription unavailable" if runtime.get("status")=="unavailable" else "Transcribing your answer…"}</Text></Breathe><Text style={cream.muted}>{recording.get("error","") or runtime.get("message","Your audio is saved. Waiting for the PC worker. You can type your answer below.")}</Text>{<PrepButton label="Retry transcription" onPress={lambda { rpc("transcription_action",{"id":recording["id"],"action":"retry"}).then(lambda (value: any) { recording=value; }).catch(lambda (e: any) { error=errorText(e); }); }}/> if recording.get("status") in ["failed","cancelled"] else None}</View></Reveal> if len(recording)>0 and recording.get("status")!="completed" else None}
            {<Reveal><PrepButton label="Upload saved answer" onPress={retryUpload} disabled={busy}/></Reveal> if len(local)>0 and len(recording)==0 else None}
            <TextInput accessibilityLabel="Review transcript" editable={not busy} style={cream.input} value={draft} onChangeText={lambda (v: str) { draft=v;control.current["dirty"]=True;control.current["autosaveError"]=False; }} multiline={True} placeholder="Type or review your answer before coaching" placeholderTextColor="#927E69"/>
            <PrepButton label="Get coaching" disabled={busy or saving or not draft.strip()} onPress={coach}/><PrepButton label="Record again" secondary={True} disabled={busy} onPress={recordAnswer}/>
            {<PrepButton label="Return to coaching" secondary={True} onPress={lambda { page="coaching"; }}/> if len(feedback)>0 else None}
        </View> if page=="review" else None}
        {<View style={{gap:22}}><Text style={cream.title}>Preparing your coaching</Text><Halo active={run.get("status","") not in ["needs_input","blocked","failed","cancelled"]} size={76}><Icon name="sparkles" size={34} color="#342416"/></Halo><Text style={cream.body}>{run.get("message","Your answer is saved. Coaching will appear here when ready.")}</Text><Text style={cream.muted}>{statusLabels.get(run.get("status",""),run.get("status","").replace("_"," "))}</Text>{<PrepButton label="Retry coaching" onPress={retryCoach} disabled={busy}/> if run.get("status") in ["needs_input","blocked","failed","cancelled"] else None}{<PrepButton label="Set up coaching" onPress={lambda { onNavigate("features"); }}/> if onNavigate and run.get("status") in ["needs_input","blocked","failed"] else None}<PrepButton label="View your answer" secondary={True} onPress={lambda { page="review"; }}/></View> if page=="processing" else None}
        {<View style={{gap:16}}><Text style={cream.title}>Your coaching</Text><Text style={cream.muted}>{question.get("title","")}</Text><PrepButton label="View your answer" secondary={True} onPress={lambda { page="review"; }}/>
            <Reveal index={1}><View style={{gap:12}}><View style={cream.row}><Icon name="done" color="#342416" size={29}/><Text style={[cream.title,{fontSize:24,lineHeight:30}]}>What worked</Text></View><Text style={cream.body}>{strengths[0]["feedback"] if len(strengths)>0 else feedback.get("summary","")}</Text>{[<Text key={str(i)} style={[cream.muted,{borderLeftWidth:3,borderLeftColor:"#F6E3BA",paddingLeft:15}]}>{"“"+e.get("quote","")+"”"}</Text> for (i,e) in enumerate(feedback.get("evidence",[])[0:1])]}</View></Reveal>
            <Reveal index={2}><View style={{gap:12}}><View style={cream.row}><Icon name="sprout" color="#342416" size={29}/><Text style={[cream.title,{fontSize:24,lineHeight:30}]}>Try next</Text></View>{[<Text key={str(i)} style={cream.body}>{value}</Text> for (i,value) in enumerate(feedback.get("next_exercises",[]))]}{<Text style={cream.body}>{improvements[0]["feedback"]}</Text> if len(improvements)>0 else None}</View></Reveal>
            <Reveal index={3}><View style={cream.card}><Text style={cream.muted}>A stronger ending</Text><Text style={cream.body}>The result was… and next time I would…</Text></View></Reveal>
            <Reveal index={4}><View style={{gap:16}}>{<PrepButton label="Saved answers" secondary={True} onPress={lambda { page="history"; }}/> if len(w.get("history",[]))>0 else None}<PrepButton label={"Finish session" if index+1==len(plan) else "Next question"} icon="next" onPress={nextAnswer} disabled={busy or w.get("complete",False)}/><PrepButton label="Try this answer again" secondary={True} onPress={lambda { page="question";feedback={};current={**current,"data":{**current["data"],"behavioral":{**w,"complete":False}}}; }}/></View></Reveal></View> if page=="coaching" else None}
        {<View style={{gap:22}}><Pop><Halo size={76}><Icon name="done" size={34} color="#342416"/></Halo></Pop><Text style={cream.title}>Session complete</Text><Text style={cream.body}>{str(len(plan))+" questions practiced. Your answers and coaching are saved."}</Text><PrepButton label="Back to Prep" onPress={lambda { page="home"; }}/><PrepButton label="New session" secondary={True} onPress={lambda { page="type"; }}/></View> if page=="complete" else None}
        {<View style={{gap:16}}><Text style={cream.title}>{"Continue session" if page=="continue" else "Past sessions"}</Text>{[<PrepOption key={row["id"]} label={row["data"]["behavioral"]["focus"]+" · "+str(row["data"]["behavioral"]["index"]+1)+" of "+str(len(row["data"]["behavioral"]["plan"]))} icon="chat" index={i} disabled={busy} onPress={lambda { openSession(row["id"]); }}/> for (i,row) in enumerate(activeSessions if page=="continue" else sessions)]}{<Text style={cream.muted}>No sessions yet. Start with New session.</Text> if len(activeSessions if page=="continue" else sessions)==0 else None}</View> if page in ["continue","past"] else None}
        {<View style={{gap:16}}><Text style={cream.title}>Saved answers</Text>{[<PrepOption key={str(h["index"])} label={"Question "+str(h["index"]+1)} icon="play" index={i} onPress={lambda { viewSaved(h); }}/> for (i,h) in enumerate(w.get("history",[]))]}<PrepButton label="Return to session" secondary={True} onPress={lambda { page="coaching"; }}/></View> if page=="history" else None}
        {<View style={{gap:18}}><Text style={cream.title}>{"Answer "+str(archived.get("index",0)+1)}</Text>{[<Text key={q["id"]} style={cream.muted}>{q["prompt"]}</Text> for q in catalog if q["id"]==archived.get("problem_id")]}{<AnswerPlayback uri={archived["uri"]}/> if archived.get("uri") else None}<Text style={cream.body}>{archived.get("answer","")}</Text><Text style={[cream.title,{fontSize:24,lineHeight:30}]}>Your coaching</Text><Text style={cream.body}>{archived.get("feedback",{}).get("summary","")}</Text><PrepButton label="Saved answers" secondary={True} onPress={lambda { page="history"; }}/></View> if page=="saved-answer" else None}
        {legacyContent if page=="legacy" else None}
        {<Reveal><PrepButton label="Coaching settings" secondary={True} onPress={lambda { onNavigate("features"); }}/></Reveal> if error and onNavigate and page in ["review","processing"] else None}
        <FadeSwitch show={bool(error or capture.error)}><Text accessibilityLiveRegion="polite" style={[cream.muted,{color:"#9C4638"}]}>{error or capture.error}</Text></FadeSwitch>
        <FadeSwitch show={busy or saving}><Text accessibilityLiveRegion="polite" style={cream.muted}>Saving…</Text></FadeSwitch>
        </PrepStage>
    </View>
}
