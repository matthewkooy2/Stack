import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText, pickLatexSource, previewDocument, PDFView }
import from ..theme { s }
import from .UI { Button, Chip }

glob TEMPLATES: list[dict[str, str]] = [{"key":"jake","label":"Jake's Resume"},{"key":"classic","label":"Classic"}];

"""How tailored versions of one resume are formatted: the user's own LaTeX, or a built-in template."""
def:pub ResumeFormat(resume: dict[str, any], onChanged: any) -> JsxElement {
    has busy: bool = False, error: str = "", notice: str = "", pdfUri: str = "", tex: str = "", showTex: bool = False;
    format=resume.get("format",{});summary=format.get("summary",{});kind=format.get("kind","");
    async def change(endpoint: str, args: dict[str, any], done: str) -> None {
        if busy { return; } busy=True;error="";notice="";pdfUri="";tex="";showTex=False;
        try { onChanged(await rpc(endpoint,args));notice=done; }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def upload -> None {
        if busy { return; }
        try {
            file=await pickLatexSource();
            if file { await change("upload_resume_source",{"id":resume["id"],"name":file["name"],"content":file["content"]},"Your LaTeX compiled. Tailored versions will keep this format."); }
        } except Exception as e { error=errorText(e); }
    }
    async def open(showSource: bool) -> None {
        if busy { return; } busy=True;error="";
        try {
            result=await rpc("read_resume_source",{"id":resume["id"]});
            tex=result["tex"];
            if showSource { showTex=True; } else { pdfUri=await previewDocument(result["preview"]); }
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    <View style={[s.mutedBox,{gap:10}]}>
        <Text style={s.label}>TAILORING FORMAT</Text>
        <Text style={s.strong}>{format.get("label","Not set")+(" · "+format["file"] if format.get("file") else "")}</Text>
        {<Text style={s.small}>{str(format.get("pages",0))+(" page" if format.get("pages",0)==1 else " pages")+" · "+str(summary.get("sections",0))+" sections · "+str(summary.get("entries",0))+" entries · "+str(summary.get("bullets",0))+" bullets"}</Text> if kind else <View/>}
        {<Text style={s.small}>{"Not used from your .zip: "+", ".join(format.get("skipped",[])[0:5])}</Text> if len(format.get("skipped",[]))>0 else <View/>}
        <Text style={s.small}>{"Stack edits only the content of your LaTeX (bullets, their order, skill lists) and keeps your layout. In Overleaf: Menu → Download → Source." if kind!="builtin" else "Built from your confirmed resume details. Upload your own LaTeX to keep your exact layout."}</Text>
        <Button label={"Replace LaTeX source" if kind=="upload" else "Upload LaTeX (.tex or Overleaf .zip)"} icon="upload" secondary={kind=="upload"} disabled={busy} onPress={upload}/>
        <View style={s.wrap}>
            {[<Chip key={t["key"]} label={t["label"]} active={kind=="builtin" and format.get("template")==t["key"]} onPress={lambda { change("use_resume_template",{"id":resume["id"],"template":t["key"]},t["label"]+" will be used for tailored versions."); }}/> for t in TEMPLATES]}
            {<Chip label="Remove format" onPress={lambda { change("use_resume_template",{"id":resume["id"],"template":""},"Removed. Stack uses Jake's Resume with your confirmed details."); }}/> if kind else <View/>}
        </View>
        {<View style={s.wrap}><Chip label="Preview format" onPress={lambda { open(False); }}/><Chip label={"Hide LaTeX" if showTex else "Show LaTeX"} active={showTex} onPress={lambda { if showTex { showTex=False; } else { open(True); } }}/></View> if kind or resume.get("details_status")=="Confirmed" else <View/>}
        {<Text style={s.small}>Working… The first LaTeX compile on this Mac can take a minute.</Text> if busy else <View/>}
        {<View style={s.noticeBox}><Text style={s.noticeText}>{notice}</Text></View> if notice else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
        {<View style={{gap:8}}><Chip label="Close preview" onPress={lambda { pdfUri=""; }}/><View style={{height:480}}><PDFView uri={pdfUri}/></View></View> if pdfUri else <View/>}
        {<Text selectable={True} style={[s.small,{fontFamily:"Menlo"}]}>{tex}</Text> if showTex and tex else <View/>}
    </View>
}
