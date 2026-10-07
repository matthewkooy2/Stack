import from "@jac/mobui" { View, Text }
import from "react" { useEffect, useRef }
import from "../device.js" { rpc, errorText }
import from ..theme { s }
import from .UI { Button, Field, Chip }
import from .Transcription { Transcription }

def requestId -> str { return str(Date.now())+"-"+str(Math.random()); }
def savedLabel(row: any) -> str { return str(row["data"]["job"]["title"])+" · "+str(len(row["data"]["turns"]))+" answers · "+str(row["data"]["status"]); }

def:pub Interview(owner: str) -> JsxElement {
    has applications: list[dict[str, any]] = [], sessions: list[dict[str, any]] = [], current: dict[str, any] = {},
        role: str = "", draft: str = "", recording: str = "", offered: dict[str, any] = {}, error: str = "",
        busy: bool = False, correction: int = -1, edited: str = "";
    control=useRef({"busy":False,"epoch":0,"create":requestId(),"answer":requestId()});
    async def reloadSessions -> None { result=await rpc("interview_sessions",{});sessions=result["sessions"]; }
    async can with entry {
        try { state=await rpc("bootstrap",{});applications=state["applications"];await reloadSessions(); }
        except Exception as e { error=errorText(e); }
    }
    async def refresh -> None {
        id=current.get("id","");epoch=control.current["epoch"];
        if not id or control.current["busy"] { return; }
        try { result=await rpc("interview_get",{"id":id});if epoch==control.current["epoch"] { current=result; } }
        except Exception as e { if epoch==control.current["epoch"] { error="Connection failed. Your answer is retained. "+errorText(e); } }
    }
    useEffect(lambda {
        active=True;timer=setInterval(lambda { if active { refresh(); } },1500);
        return lambda { active=False;clearInterval(timer);control.current["epoch"]+=1; };
    },[current.get("id","")]);
    async def open(id: str) -> None {
        if control.current["busy"] { return; }
        if draft.strip() or correction>=0 { error="Save or clear your answer and correction before opening another interview.";return; }
        control.current["busy"]=True;busy=True;
        control.current["epoch"]+=1;epoch=control.current["epoch"];
        try { result=await rpc("interview_get",{"id":id});if epoch==control.current["epoch"] { current=result;recording="";offered={};error="";control.current["answer"]=requestId(); } }
        except Exception as e { error=errorText(e); }
        finally { control.current["busy"]=False;busy=False; }
    }
    async def act(name: str, args: dict[str, any], clear: bool = False) -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";control.current["epoch"]+=1;
        try {
            current=await rpc(name,args);
            if clear { draft="";recording="";offered={};correction=-1;control.current["answer"]=requestId(); }
            if name=="interview_correct" { correction=-1;edited=""; }
            await reloadSessions();
        } except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def action(value: str) -> None { await act("interview_continue",{"id":current["id"],"revision":current["revision"],"action":value}); }
    async def start -> None {
        if draft.strip() or correction>=0 { error="Save or clear your answer and correction before starting another interview.";return; }
        await act("interview_create",{"application_id":role,"client_id":control.current["create"]},True);
        if not error { control.current["create"]=requestId(); }
    }
    def receive(text: str, id: str) -> None {
        if draft.strip() { offered={"text":text,"id":id}; }
        else { draft=text;recording=id; }
    }
    async def retry -> None {
        run=current.get("run",{});control.current["busy"]=True;busy=True;
        try {
            if run["status"]=="needs_input" { await rpc("agent_respond",{"id":run["id"],"values":[],"reuse":False}); }
            else { await rpc("agent_retry",{"id":run["id"]}); }
            current=await rpc("interview_get",{"id":current["id"]});error="";
        } except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    data=current.get("data",{});turns=data.get("turns",[]);questions=data.get("questions",[]);
    run=current.get("run",{});analysis=data.get("analysis",{}).get(str(len(turns)),{});coaching=data.get("coaching",{});
    <View style={s.card}>
        <Text style={s.heading}>Job-specific mock interview</Text><Text style={s.body}>Choose a saved role, review each answer, and get local coaching. You can record or type.</Text>
        <Text style={s.label}>Saved role</Text>
        {[<Chip key={a["id"]} label={str(a["job"]["title"])+" · "+str(a["job"].get("company",""))} active={role==a["id"]} onPress={lambda { if not busy { role=str(a["id"]);control.current["create"]=requestId(); } }}/> for a in applications]}
        <Button label="Start job interview" disabled={busy or not role} onPress={start}/>
        <Text style={s.label}>Saved interviews</Text>{[<Button key={row["id"]} label={savedLabel(row)} secondary={True} disabled={busy} onPress={lambda { open(str(row["id"])); }}/> for row in sessions]}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
        {<View style={{gap:12}}>
            <Text style={s.strong}>{data["job"]["title"]+" · "+data["status"]}</Text>
            {<View><Text style={s.small}>{run.get("message","")}</Text>{<Button label="Retry local Qwen" disabled={busy} onPress={retry}/> if run.get("status","") in ["needs_input","blocked","failed"] else <View/>}</View> if run.get("id","") else <View/>}
            {<View><Text style={s.strong}>Answer coaching</Text><Text style={s.body}>{analysis["strength"]+": "+analysis["improvement"]}</Text><Text style={s.small}>{analysis["focus_quote"]}</Text><Button label="Ask answer follow-up" disabled={busy or len(turns)>=6 or data["status"]!="active"} onPress={lambda { action("followup"); }}/></View> if len(analysis)>0 else <View/>}
            {<View style={{gap:10}}><Text style={s.strong}>Current question</Text><Text style={s.body}>{questions[len(turns)]["question"]}</Text>
                <Field label="Review your answer" value={draft} disabled={busy} onChange={lambda (value: str) { draft=value; }} multiline={True}/>
                <Transcription key={current["id"]+":"+str(len(turns))} owner={owner} onUseTranscript={receive} disabled={busy}/>
                {<View><Text style={s.small}>Your typed answer is preserved. A reviewed recorded transcript is ready.</Text><Text>{offered["text"]}</Text><Button label="Use recorded transcript" disabled={busy} onPress={lambda { draft=offered["text"];recording=offered["id"];offered={}; }}/></View> if len(offered)>0 else <View/>}
                {<Button label="Continue with typed role question" disabled={busy} onPress={lambda { action("next"); }}/> if data.get("pending","") else <Button label="Save reviewed answer and analyze" disabled={busy or not draft.strip()} onPress={lambda { act("interview_answer",{"id":current["id"],"revision":current["revision"],"answer":draft,"client_id":control.current["answer"],"recording_id":recording},True); }}/>}
            </View> if data["status"]=="active" and len(turns)<len(questions) and len(turns)<6 else <View/>}
            <Text style={s.strong}>Reviewed transcript</Text>{[<View key={str(i)}><Text style={s.label}>{"Answer "+str(i+1)}</Text><Text style={s.small}>{turn["question"]["question"]}</Text><Text style={s.body}>{turn["answer"]}</Text>{<Text style={s.small}>{"Original transcript: "+turn["original"]}</Text> if turn["original"]!=turn["answer"] else <View/>}<Button label={"Correct answer "+str(i+1)} secondary={True} disabled={busy} onPress={lambda { correction=i;edited=turn["answer"]; }}/></View> for (i,turn) in enumerate(turns)]}
            {<View><Field label="Corrected answer" value={edited} disabled={busy} onChange={lambda (value: str) { edited=value; }} multiline={True}/><Button label="Save transcript correction" disabled={busy or not edited.strip()} onPress={lambda { act("interview_correct",{"id":current["id"],"revision":current["revision"],"index":correction,"answer":edited}); }}/></View> if correction>=0 else <View/>}
            {<Button label="Finish interview" disabled={busy or len(turns)<2} onPress={lambda { action("finish"); }}/> if data["status"]=="active" else <View/>}
            {<Button label={"Get final coaching" if data["status"]=="finished" else "Analyze reviewed answer"} disabled={busy} onPress={lambda { action("analyze"); }}/> if len(turns)>0 and not data.get("pending","") and len(analysis)==0 else <View/>}
            {<View style={{gap:8}}><Text style={s.strong}>Final coaching</Text><Text style={s.small}>{coaching["summary"]}</Text>{[<View key={str(i)}><Text style={s.body}>{"Model-selected strength: "+value["criterion"]}</Text><Text style={s.small}>{value["source"]+": "+value["quote"]}</Text></View> for (i,value) in enumerate(coaching["strengths"])]}{[<Text key={criterion} style={s.body}>{criterion+" "+str(value["score"])+"/4: "+value["feedback"]}</Text> for (criterion,value) in coaching["rubric"].items()]}{[<Text key={str(i)}>{value}</Text> for (i,value) in enumerate(coaching["next_exercises"])]}<Text style={s.label}>Practice questions</Text>{[<Text key={str(i)}>{value}</Text> for (i,value) in enumerate(coaching["followup_questions"])]}{[<Text key={str(i)} style={s.small}>{value["source"]+": "+value["quote"]}</Text> for (i,value) in enumerate(coaching["evidence"])]}</View> if len(coaching)>0 else <View/>}
        </View> if len(data)>0 else <View/>}
    </View>
}

