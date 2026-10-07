import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText, openJobLink }
import from ..theme { s }
import from .UI { Button, Field, Chip }
import from .Feedback { AgentFeedback }
import from .Agents { Pill, TaskRow, featureByKey, runsFor, stateTone, stateLabel, withKey }

def:pub Practice(runs: list[dict[str, any]] = [], features: list[dict[str, any]] = [], onOpenTask: any = None, onNavigate: any = None) -> JsxElement {
    has problems: list[dict[str, any]] = [], sessions: list[dict[str, any]] = [], current: dict[str, any] = {},
        data: dict[str, any] = {}, error: str = "", busy: bool = False, web: str = "", message: str = "", dirty: bool = False;
    async def reload -> None {
        try { result=await rpc("prep_catalog",{});problems=result["problems"];result=await rpc("prep_sessions",{});sessions=result["sessions"];settings=await rpc("agent_settings",{});web=settings.get("web_url",""); }
        except Exception as e { error=errorText(e); }
    }
    async can with entry { await reload(); }
    async def start(id: str, language: str) -> None {
        busy=True;error="";
        try { current=await rpc("prep_create",{"problem_id":id,"language":language});data=current["data"];dirty=False;await reload(); }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def resume(id: str) -> None {
        # Reloading replaces the editor; keep unsaved work unless it belongs to another session.
        if dirty and len(current)>0 and current["id"]==id { error="You have unsaved changes. Save practice first, then refresh.";return; }
        try { current=await rpc("prep_get",{"id":id});data=current["data"];dirty=False;error=""; }
        except Exception as e { error=errorText(e); }
    }
    async def save(kind: str = "") -> None {
        busy=True;error="";message="";
        try {
            current=await rpc("prep_save",{"id":current["id"],"revision":current["revision"],"data":data});data=current["data"];dirty=False;
            if kind { result=await rpc("agent_start",{"kind":kind,"target_id":current["id"]});message=result["title"]+" started. Status appears below; results are added to this session."; }
            else { message="Practice saved. Continue on either device."; }
            await reload();
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    def change(key: str, value: str) -> None { data=withKey(data,key,value);dirty=True; }
    coaching=featureByKey(features,"coaching");code=featureByKey(features,"code");live=featureByKey(features,"live");
    <View style={{gap:14}}>
        <Text style={s.heading}>Practice with your coach.</Text><Text style={s.body}>Save answers and code, run tests, and get focused feedback. Sessions continue on the web workspace.</Text>
        <View style={s.taskCard}>
            {[<View key={f["key"]} style={{gap:4}}><View style={s.between}><Text style={[s.strong,{flex:1}]}>{f["title"]}</Text><Pill label={stateLabel(str(f["state"]))} tone={stateTone(f["state"])}/></View><Text style={s.small}>{f["summary"]}</Text>{[<Text key={c["key"]} style={s.small}>{"✕ "+c["fix"]}</Text> for c in f["checks"] if not c["ok"] and not c["optional"]]}{<Text style={s.small}>{"Meanwhile: "+f["alternative"]}</Text> if f["state"]!="ready" else <View/>}</View> for f in [coaching,code,live] if len(f)>0]}
            {<Chip label="Set up agents" onPress={lambda { onNavigate("features"); }}/> if onNavigate and len([f for f in [coaching,code,live] if len(f)>0 and f["state"]!="ready"])>0 else <View/>}
        </View>
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}{<View style={s.noticeBox}><Text style={s.noticeText}>{message}</Text></View> if message else <View/>}
        {<Button label="Open web workspace (editor, timer, live interview)" secondary={True} onPress={lambda { openJobLink(web); }}/> if web else <Text style={s.small}>The laptop workspace and live interviews become available when hosting is configured.</Text>}
        {[<View key={p["id"]} style={s.card}><Text style={s.strong}>{p["title"]}</Text><Text style={s.small}>{p["topic"]+" · "+str(p["minutes"])+" min"}</Text><View style={s.wrap}>{[<Chip key={language} label={"Start "+("C++" if language=="cpp" else language.upper())} onPress={lambda { start(p["id"],language); }}/> for language in p["languages"]]}{<Chip label="Start practice" onPress={lambda { start(p["id"],""); }}/> if len(p["languages"])==0 else <View/>}</View></View> for p in problems if len(current)==0]}
        {<View style={s.card}>
            {[<Text key={p["id"]} style={s.body}>{p["prompt"]}</Text> for p in problems if p["id"]==data.get("problem_id")]}
            <Field label="Explain your approach" value={data.get("answer","")} onChange={lambda (v: str) { change("answer",v); }} multiline={True}/>
            {<Field label="Your code" value={data.get("code","")} onChange={lambda (v: str) { change("code",v); }} multiline={True}/> if data.get("language") else <View/>}
            <Field label="Practice notes" value={data.get("notes","")} onChange={lambda (v: str) { change("notes",v); }} multiline={True}/>
            {<Text style={s.small}>Unsaved changes</Text> if dirty else <View/>}
            <Button label="Save practice" onPress={lambda { save(); }} disabled={busy}/>
            {<Button label="Save and run tests" secondary={True} onPress={lambda { save("code"); }} disabled={busy or code.get("state","")=="unavailable"}/> if data.get("language") else <View/>}
            <Button label="Save and get coaching" onPress={lambda { save("prep"); }} disabled={busy or coaching.get("state","")=="unavailable"}/><Button label="Refresh results" secondary={True} onPress={lambda { resume(current["id"]); }}/>
            {[<View key={t["id"]}><TaskRow run={t} onOpen={lambda { onOpenTask(t["id"]); }}/></View> for t in runsFor(runs,current["id"],["prep","code","live"])[0:3]] if onOpenTask else []}
            {[<Text key={str(r["at"])} style={s.body}>{"Tests: "+str(r["data"].get("passed",0))+" / "+str(r["data"].get("total",0))+" "+r["data"].get("error","")}</Text> for r in current.get("results",[])]}
            {[<View key={str(f["at"])} style={s.hero}><Text style={s.strong}>Coaching</Text><Text style={s.body}>{f["data"].get("text",f["data"].get("summary",""))}</Text>{[<Text key={row["criterion"]} style={s.small}>{row["criterion"]+" · "+str(row["score"])+"/4 — "+row["feedback"]}</Text> for row in f["data"].get("rubric",[])]}{<AgentFeedback key={f["run_id"]+f["output_version"]} runId={f["run_id"]} outputVersion={f["output_version"]}/> if f.get("run_id") and f.get("output_version") else <View/>}</View> for f in current.get("feedback",[])]}
        </View> if len(current)>0 else <View/>}
        <Button label={"Save to switch exercises" if dirty else "Choose another exercise"} secondary={True} disabled={dirty} onPress={lambda { current={}; }}/><Text style={s.strong}>Continue a session</Text>{[<Button key={p["id"]} label={p["data"]["problem_id"]+(" · "+p["data"]["language"] if p["data"]["language"] else "")} secondary={True} onPress={lambda { resume(p["id"]); }}/> for p in sessions]}
    </View>
}
