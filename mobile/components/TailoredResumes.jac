import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText, Icon, shortDate, previewDocument, PDFView }
import from ..theme { s }
import from .UI { Button, Chip }
import from .ScoreCard { ScoreCard }

"""Resumes Stack tailored for saved jobs, kept apart from uploads. PDF parser checks are temporarily unavailable."""
def:pub TailoredResumes(items: list[dict[str, any]], onChanged: any) -> JsxElement {
    <View style={{gap:12}}>
        <View style={{gap:4}}><Text style={s.label}>TAILORED RESUMES</Text>
            <Text style={s.small}>Made by resume tailoring, one per job. Your uploads above are never changed.</Text></View>
        {<Text style={s.body}>Resumes you tailor for a saved job appear here.</Text> if len(items)==0 else <View/>}
        {[<TailoredCard key={x["id"]} item={x} onChanged={onChanged}/> for x in items]}
    </View>
}

def:pub TailoredCard(item: dict[str, any], onChanged: any) -> JsxElement {
    has busy: bool = False, error: str = "", pdfUri: str = "", tex: str = "", showTex: bool = False, confirming: bool = False;
    async def open(showSource: bool) -> None {
        if busy { return; } busy=True;error="";
        try {
            result=await rpc("read_tailored_resume",{"id":item["id"]});tex=result["tex"];
            if showSource { showTex=True; } else { pdfUri=await previewDocument(result["pdf"]); }
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def remove -> None {
        if busy { return; } busy=True;error="";
        try { onChanged(await rpc("delete_tailored_resume",{"id":item["id"]})); }
        except Exception as e { error=errorText(e);busy=False; }
    }
    <View style={[s.card,{gap:12}]}>
        <View style={s.row}><Icon name="resume" size={29} color="#167867"/><View style={s.grow}>
            <Text style={s.strong}>{item["job_title"] or item["name"]}</Text>
            <Text style={s.small}>{"Tailored for "+item["company"] if item["company"] else "Tailored resume"}</Text></View></View>
        <Text style={s.small}>{shortDate(item["created_at"])+" · "+str(item["pages"])+(" page" if item["pages"]==1 else " pages")+(" · from "+item["source_name"] if item["source_name"] else "")}</Text>
        <Text style={s.small}>PDF parser checks are temporarily unavailable.</Text>
        {<ScoreCard after={item["score"]["after"]} before={item["score"].get("before") or {}} title="SCORE FOR THIS JOB"/> if item.get("score",{}).get("after") else <View/>}
        <Button label="Preview tailored PDF" secondary={True} icon="resume" disabled={busy} onPress={lambda { open(False); }}/>
        <View style={s.wrap}>
            <Chip label={"Hide LaTeX" if showTex else "Show LaTeX"} active={showTex} onPress={lambda { if showTex { showTex=False; } else { open(True); } }}/>
            <Chip label="Delete" onPress={lambda { confirming=True; }}/>
        </View>
        {<View style={s.wrap}><Text style={s.small}>Delete this tailored resume? Your upload stays.</Text><Chip label="Delete tailored resume" onPress={remove}/><Chip label="Keep" onPress={lambda { confirming=False; }}/></View> if confirming else <View/>}
        {<Text style={s.small}>Working…</Text> if busy else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
        {<View style={{gap:8}}><Chip label="Close preview" onPress={lambda { pdfUri=""; }}/><View style={{height:480}}><PDFView uri={pdfUri}/></View></View> if pdfUri else <View/>}
        {<Text selectable={True} style={[s.small,{fontFamily:"Menlo"}]}>{tex}</Text> if showTex and tex else <View/>}
    </View>
}
