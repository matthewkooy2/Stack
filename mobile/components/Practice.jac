import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText, openJobLink }
import from ..theme { s }
import from .UI { Button, Field, Chip }

def:pub Practice -> JsxElement {
    has problems: list[dict[str, any]] = [], sessions: list[dict[str, any]] = [], current: dict[str, any] = {},
        data: dict[str, any] = {}, error: str = "", busy: bool = False, web: str = "", message: str = "";
    async def reload -> None {
        try { result=await rpc("prep_catalog",{});problems=result["problems"];result=await rpc("prep_sessions",{});sessions=result["sessions"];settings=await rpc("agent_settings",{});web=settings.get("web_url",""); }
        except Exception as e { error=errorText(e); }
    }
    async can with entry { await reload(); }
    async def start(id: str, language: str) -> None {
        busy=True;error="";
        try { current=await rpc("prep_create",{"problem_id":id,"language":language});data=current["data"];await reload(); }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def resume(id: str) -> None {
        try { current=await rpc("prep_get",{"id":id});data=current["data"]; }
        except Exception as e { error=errorText(e); }
    }
    async def save(kind: str = "") -> None {
        busy=True;error="";
        try {
            current=await rpc("prep_save",{"id":current["id"],"revision":current["revision"],"data":data});data=current["data"];
            if kind { result=await rpc("agent_start",{"kind":kind,"target_id":current["id"]});message=result["message"]+" · Check Agent activity for progress."; }
            else { message="Practice saved. Continue on either device."; }
            await reload();
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    <View style={{gap:14}}>
        <Text style={s.heading}>Practice with your coach.</Text><Text style={s.body}>Save answers, run C++ / Python / SQL, and get focused feedback.</Text>
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}{<Text style={s.small}>{message}</Text> if message else <View/>}
        {<Button label="Open coding workspace" secondary={True} onPress={lambda { openJobLink(web); }}/> if web else <Text style={s.small}>The laptop workspace becomes available when hosting is configured.</Text>}
        {[<View key={p["id"]} style={s.card}><Text style={s.strong}>{p["title"]}</Text><Text style={s.small}>{p["topic"]+" · "+str(p["minutes"])+" min"}</Text><View style={s.wrap}>{[<Chip key={language} label={"Start "+("C++" if language=="cpp" else language.upper())} onPress={lambda { start(p["id"],language); }}/> for language in p["languages"]]}{<Chip label="Start practice" onPress={lambda { start(p["id"],""); }}/> if len(p["languages"])==0 else <View/>}</View></View> for p in problems if len(current)==0]}
        {<View style={s.card}>
            {[<Text key={p["id"]} style={s.body}>{p["prompt"]}</Text> for p in problems if p["id"]==data.get("problem_id")]}
            <Field label="Explain your approach" value={data.get("answer","")} onChange={lambda (v: str) { data={**data,"answer":v}; }} multiline={True}/>
            {<Field label="Your code" value={data.get("code","")} onChange={lambda (v: str) { data={**data,"code":v}; }} multiline={True}/> if data.get("language") else <View/>}
            <Field label="Practice notes" value={data.get("notes","")} onChange={lambda (v: str) { data={**data,"notes":v}; }} multiline={True}/>
            <Button label="Save practice" onPress={lambda { save(); }} disabled={busy}/>
            {<Button label="Run code" secondary={True} onPress={lambda { save("code"); }} disabled={busy}/> if data.get("language") else <View/>}
            <Button label="Get coaching" onPress={lambda { save("prep"); }} disabled={busy}/><Button label="Refresh this session" secondary={True} onPress={lambda { resume(current["id"]); }}/>
            {[<Text key={str(r["at"])} style={s.body}>{"Tests: "+str(r["data"].get("passed",0))+" / "+str(r["data"].get("total",0))+" "+r["data"].get("error","")}</Text> for r in current.get("results",[])]}
            {[<Text key={str(f["at"])} style={s.body}>{f["data"]["summary"]}</Text> for f in current.get("feedback",[])]}
        </View> if len(current)>0 else <View/>}
        <Button label="Choose another exercise" secondary={True} onPress={lambda { current={}; }}/><Text style={s.strong}>Continue a session</Text>{[<Button key={p["id"]} label={p["data"]["problem_id"]+" · "+p["data"]["language"]} secondary={True} onPress={lambda { resume(p["id"]); }}/> for p in sessions]}
    </View>
}
