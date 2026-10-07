import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText }
import from ..theme { s }
import from .UI { Button, Field, Chip }

def:pub ResumeRecords(id: str, onChanged: any) -> JsxElement {
    has review: dict[str, any] = {}, records: list[dict[str, any]] = [], busy: bool = False, error: str = "", notice: str = "";
    async def load -> None {
        busy=True;error="";
        try { review=await rpc("agent_extract_resume",{"id":id});records=review.get("records",[]); }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    can with entry { load(); }
    def update(rid: str, key: str, value: any) -> None { records=[{**r,key:value} if r["id"]==rid else r for r in records]; }
    async def save(confirm: bool) -> None {
        busy=True;error="";notice="";
        try {
            review=await rpc("resume_save_records",{"id":id,"revision":review["revision"],"records":records,"confirm":confirm,"template":review.get("template","classic")});
            records=review["records"];onChanged(await rpc("bootstrap",{}));notice="Facts confirmed." if confirm else "Draft saved; confirm before reuse.";
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    <View style={{gap:12}}><Text style={s.heading}>Review resume facts</Text><Text style={s.body}>Check every extracted line, its kind, dates and claims. Original uploads stay unchanged. Saving a draft withdraws confirmation.</Text>
        {<Text style={s.error}>{error}</Text> if error else <View/>}{<Text style={s.small}>{notice}</Text> if notice else <View/>}
        {<Text style={s.small}>Import is processing or these details are unavailable. Reload when import completes.</Text> if not records else <View/>}
        <Button label="Reload resume details" secondary={True} disabled={busy} onPress={load}/>
        {[<View key={r["id"]} style={s.taskCard}><Field label={"Record "+r["id"]} value={r["text"]} onChange={lambda (v: str) { update(r["id"],"text",v); }} multiline={True}/>
            <View style={s.wrap}>{[<Chip key={kind} label={kind} active={r["kind"]==kind} onPress={lambda { update(r["id"],"kind",kind); }}/> for kind in ["title","heading","paragraph","bullet"]]}</View>
            {<Chip label="Allow model to propose omission" active={r.get("allow_omit",False)} onPress={lambda { update(r["id"],"allow_omit",not r.get("allow_omit",False)); }}/> if r["kind"]=="bullet" else <View/>}
        </View> for r in records]}
        <Button label="Save draft details" secondary={True} disabled={busy or not records} onPress={lambda { save(False); }}/><Button label="Save and confirm resume facts" disabled={busy or not records} onPress={lambda { save(True); }}/>
    </View>
}
