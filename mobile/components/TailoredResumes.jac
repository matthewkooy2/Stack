import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText, Icon, shortDate, previewDocument, PDFView }
import from ..theme { s }
import from .UI { Button, Chip }

"""Resumes Stack tailored for saved jobs, kept apart from uploads. Each is read back with the OpenResume parser."""
def:pub TailoredResumes(items: list[dict[str, any]], onChanged: any) -> JsxElement {
    <View style={{gap:12}}>
        <View style={{gap:4}}><Text style={s.label}>TAILORED RESUMES</Text>
            <Text style={s.small}>Made by resume tailoring, one per job. Your uploads above are never changed.</Text></View>
        {<Text style={s.body}>Resumes you tailor for a saved job appear here.</Text> if len(items)==0 else <View/>}
        {[<TailoredCard key={x["id"]} item={x} onChanged={onChanged}/> for x in items]}
    </View>
}

def:pub parseSummary(parse: dict[str, any]) -> str {
    if len(parse)==0 { return "Not checked with the parser yet"; }
    if parse.get("error") { return "Parser could not read it"; }
    counts=" · "+str(parse.get("passed",0))+" of "+str(parse.get("total",0))+" checks";
    if parse.get("ok") { return "Parses well"+counts; }
    # Every issue is also in the original upload: tailoring did not cause it.
    if parse.get("compared_to_original") and parse.get("new_issues",1)==0 { return "No new parser issues"+counts; }
    return "Parser found issues"+counts;
}

def:pub TailoredCard(item: dict[str, any], onChanged: any) -> JsxElement {
    has busy: bool = False, error: str = "", pdfUri: str = "", tex: str = "", showTex: bool = False, showChecks: bool = False, confirming: bool = False;
    parse=item.get("parse",{});
    async def open(showSource: bool) -> None {
        if busy { return; } busy=True;error="";
        try {
            result=await rpc("read_tailored_resume",{"id":item["id"]});tex=result["tex"];
            if showSource { showTex=True; } else { pdfUri=await previewDocument(result["pdf"]); }
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def recheck -> None {
        if busy { return; } busy=True;error="";
        try { onChanged(await rpc("check_tailored_resume",{"id":item["id"]}));showChecks=True; }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def remove -> None {
        if busy { return; } busy=True;error="";
        try { onChanged(await rpc("delete_tailored_resume",{"id":item["id"]})); }
        except Exception as e { error=errorText(e);busy=False; }
    }
    tone={"bg":"#E4F5EF","fg":"#167867"} if parse.get("ok") or (parse.get("compared_to_original") and parse.get("new_issues",1)==0) else ({"bg":"#EEF1F7","fg":"#66768D"} if len(parse)==0 else {"bg":"#FFF1E3","fg":"#A4540F"});
    <View style={[s.card,{gap:12}]}>
        <View style={s.row}><Icon name="resume" size={29} color="#167867"/><View style={s.grow}>
            <Text style={s.strong}>{item["job_title"] or item["name"]}</Text>
            <Text style={s.small}>{"Tailored for "+item["company"] if item["company"] else "Tailored resume"}</Text></View></View>
        <Text style={s.small}>{shortDate(item["created_at"])+" · "+str(item["pages"])+(" page" if item["pages"]==1 else " pages")+(" · from "+item["source_name"] if item["source_name"] else "")}</Text>
        <View style={[s.pill,{backgroundColor:tone["bg"]}]}><Text style={[s.pillText,{color:tone["fg"]}]}>{parseSummary(parse)}</Text></View>
        <Button label="Preview tailored PDF" secondary={True} icon="resume" disabled={busy} onPress={lambda { open(False); }}/>
        <View style={s.wrap}>
            {<Chip label={"Hide parser check" if showChecks else "Parser check"} active={showChecks} onPress={lambda { showChecks=not showChecks; }}/> if len(parse)>0 else <View/>}
            <Chip label={"Check with parser" if len(parse)==0 else "Check again"} onPress={recheck}/>
            <Chip label={"Hide LaTeX" if showTex else "Show LaTeX"} active={showTex} onPress={lambda { if showTex { showTex=False; } else { open(True); } }}/>
            <Chip label="Delete" onPress={lambda { confirming=True; }}/>
        </View>
        {<View style={[s.mutedBox,{gap:6}]}>
            <Text style={s.label}>WHAT THE OPENRESUME PARSER READ</Text>
            {<Text style={s.errorText}>{parse["error"]}</Text> if parse.get("error") else <View/>}
            {[<Text key={c["label"]} style={[s.small,{color:"#167867" if c["ok"] else "#A4540F"}]}>{("✓ " if c["ok"] else "✕ ")+c["label"]+" — "+c["detail"]+(" (also in your original upload)" if c.get("also_original") else "")}</Text> for c in parse.get("checks",[])]}
            {<Text style={s.small}>Tailoring did not cause these: the parser reads your original upload the same way. Changing the layout in Overleaf can fix them.</Text> if not parse.get("ok") and parse.get("compared_to_original") and parse.get("new_issues",1)==0 else <View/>}
            <Text style={s.small}>Stack compares what the parser reads from this PDF with what it wrote: contact details, each entry and bullet, and every skill line.</Text>
        </View> if showChecks and len(parse)>0 else <View/>}
        {<View style={s.wrap}><Text style={s.small}>Delete this tailored resume? Your upload stays.</Text><Chip label="Delete tailored resume" onPress={remove}/><Chip label="Keep" onPress={lambda { confirming=False; }}/></View> if confirming else <View/>}
        {<Text style={s.small}>Working…</Text> if busy else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
        {<View style={{gap:8}}><Chip label="Close preview" onPress={lambda { pdfUri=""; }}/><View style={{height:480}}><PDFView uri={pdfUri}/></View></View> if pdfUri else <View/>}
        {<Text selectable={True} style={[s.small,{fontFamily:"Menlo"}]}>{tex}</Text> if showTex and tex else <View/>}
    </View>
}
