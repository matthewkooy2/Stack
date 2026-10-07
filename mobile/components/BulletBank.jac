import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText, confirmDelete }
import from ..theme { s }
import from .UI { Button, Field, Chip }

def:pub BulletBank(onChanged: any) -> JsxElement {
    has data: dict[str, any] = {}, busy: bool = False, error: str = "", notice: str = "",
        id: str = "", revision: int = 0, name: str = "", source: str = "", text: str = "",
        target: str = "", selection: list[dict[str, any]] = [], opened: bool = False;
    async def load -> None {
        try { data=await rpc("resume_bank",{});opened=True; } except Exception as e { error=errorText(e); }
    }
    def clear -> None { id="";revision=0;name="";source="";text=""; }
    def edit(item: dict[str, any]) -> None {
        id=item["id"];revision=item["revision"];name=item["name"];source=item["source"];
        text="\n".join(r["text"] for r in item["records"]);notice="";
    }
    async def save(confirm: bool) -> None {
        busy=True;error="";notice="";
        try {
            lines=[line.strip() for line in text.split("\n") if line.strip()];
            data=await rpc("resume_bank_save",{"id":id,"revision":revision,"name":name,"source":source,
                "records":[{"id":"r"+str(i),"kind":"bullet","text":line} for (i,line) in enumerate(lines)],"confirm":confirm});
            clear();notice="Experience confirmed for reuse." if confirm else "Draft saved. Confirm facts before reuse.";
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def remove(item: dict[str, any]) -> None {
        busy=True;error="";
        try { data=await rpc("resume_bank_delete",{"id":item["id"],"revision":item["revision"]});if id==item["id"] { clear(); } }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    def choose(item: dict[str, any]) -> None { target=item["id"];selection=item["selection"];notice=""; }
    def selected(sid: str, rid: str) -> bool { return any(x["id"]==sid and rid in x["record_ids"] for x in selection); }
    def toggle(item: dict[str, any], rid: str) -> None {
        current=[x for x in selection if x["id"]==item["id"]];ids=current[0]["record_ids"] if current else [];
        ids=[x for x in ids if x!=rid] if rid in ids else ids+[rid];
        selection=[x for x in selection if x["id"]!=item["id"]];
        if ids { selection=selection+[{"id":item["id"],"revision":item["revision"],"record_ids":ids}]; }
    }
    async def apply -> None {
        busy=True;error="";notice="";
        try {
            resumes=[r for r in data.get("resumes",[]) if r["id"]==target];
            if not resumes { error="Reload and choose a resume.";busy=False;return; }
            data=await rpc("resume_bank_select",{"id":target,"revision":resumes[0]["revision"],"selection":selection});
            onChanged(await rpc("bootstrap",{}));notice="Selected facts will be included in your next tailoring review.";
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    <View style={s.card}><Text style={s.heading}>Resume bullet bank</Text><Text style={s.body}>Keep experience beyond your current resume. Only facts you confirm can be reused.</Text>
        <Button label="Open or reload bullet bank" onPress={load} secondary={True} disabled={busy}/>
        {<Text style={s.error}>{error}</Text> if error else <View/>}{<Text style={s.small}>{notice}</Text> if notice else <View/>}
        {<View style={{gap:12}}>
            <Text style={s.strong}>{"Edit experience" if id else "Add experience"}</Text>
            <Field label="Experience name" value={name} onChange={lambda (v: str) { name=v; }} placeholder="Role, employer or project, dates"/>
            <Field label="Source of these facts" value={source} onChange={lambda (v: str) { source=v; }} placeholder="My project notes, 2024"/>
            <Field label="Facts, one bullet per line" value={text} onChange={lambda (v: str) { text=v; }} multiline={True}/>
            <Text style={s.small}>Include the role, employer and dates in the experience name. Confirm only accurate facts. Drafts withdraw confirmation; corrections keep sources and history.</Text>
            <Button label="Save draft" onPress={lambda { save(False); }} secondary={True} disabled={busy}/><Button label="Save and confirm facts" onPress={lambda { save(True); }} disabled={busy}/><Button label="New experience" onPress={clear} secondary={True} disabled={busy}/>
            <Text style={s.strong}>Choose experience for tailoring</Text><Text style={s.small}>Choose a confirmed PDF/DOCX resume, then select relevant facts. Review the complete generated resume before approving.</Text>
            {[<Chip key={r["id"]} label={r["name"]+(" · confirm details first" if not r["confirmed"] else "")} active={target==r["id"]} onPress={lambda { choose(r); }}/> for r in data.get("resumes",[]) if r["confirmed"]]}
            <Button label="Save selected experience" onPress={apply} disabled={busy or not target}/>
            <Button label="Clear selected experience" secondary={True} onPress={lambda { selection=[];notice="Selection cleared locally. Save selected experience to apply."; }} disabled={busy or not target}/>
            {[<View key={item["id"]}><Text style={s.small}>{"Selected source "+item["id"]+" ("+str(len(item["record_ids"]))+" facts)"}</Text><Button label="Remove selected source" secondary={True} disabled={busy} onPress={lambda { selection=[x for x in selection if x["id"]!=item["id"]]; }}/></View> for item in selection]}
            <Text style={s.small}>Imported headings and other context lines keep their original order to preserve roles, dates and credentials.</Text>
            {[<View key={item["id"]} style={s.taskCard}><Text style={s.strong}>{item["name"]}</Text><Text style={s.small}>{item["source"]+" · "+("Confirmed" if item["confirmed"] else "Draft")}</Text>
                {[<View key={r["id"]}><Text style={s.body}>{r["text"]}</Text>{<Chip label={"Selected" if selected(item["id"],r["id"]) else "Select fact"} active={selected(item["id"],r["id"])} onPress={lambda { toggle(item,r["id"]); }}/> if target and target!=item["id"] and item["confirmed"] else <View/>}</View> for r in item["records"]]}
                {<View style={{gap:8}}><Button label="Edit experience" onPress={lambda { edit(item); }} secondary={True} disabled={busy}/><Button label="Delete experience" onPress={lambda { confirmDelete("this experience and its correction history",lambda { remove(item); }); }} secondary={True} disabled={busy}/>
                    <Text style={s.small}>Sources and corrections</Text>{[<Text key={str(h["revision"])} style={s.small}>{"Revision "+str(h["revision"])+" · "+h["source"]+" · "+"; ".join(r["text"] for r in h["records"])}</Text> for h in item["history"]]}</View> if item["editable"] else <Text style={s.small}>Edit imported facts with Review details above.</Text>}
            </View> for item in data.get("sources",[])]}
        </View> if opened else <View/>}
    </View>;
}
