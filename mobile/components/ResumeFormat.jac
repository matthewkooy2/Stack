import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText, pickLatexSource, previewDocument, PDFView, uploadResumeFile, uploadProgressText, ResumeProcessing, ProcessingPoll }
import from ..theme { s }
import from .UI { Button, Chip }

glob TEMPLATES: list[dict[str, str]] = [{"key":"jake","label":"Jake's Resume"},{"key":"classic","label":"Classic"}];

"""How tailored versions of one resume are formatted: the user's own LaTeX, or a built-in template."""
def:pub ResumeFormat(resume: dict[str, any], onChanged: any) -> JsxElement {
    has busy: bool = False, error: str = "", notice: str = "", pdfUri: str = "", tex: str = "", showTex: bool = False, progress: dict[str, any] = {};
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
            if file {
                busy=True;error="";notice="";
                onChanged(await uploadResumeFile("upload_resume_source",{"id":resume["id"],"name":file["name"],"content":file["content"]},lambda (value: dict[str, any]) { progress=value; }));
                notice="Source saved. Compilation continues if you close Stack.";
            }
        } except Exception as e { error=errorText(e); }
        busy=False;progress={};
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
        <ResumeProcessing resumeId={resume["id"]} kind="source" processing={resume.get("processing",{}).get("source",{})} onChanged={onChanged}/>
        {<Text style={s.small}>{uploadProgressText(progress)}</Text> if progress else <View/>}
        <Text style={s.strong}>{format.get("label","Not set")+(" · "+format["file"] if format.get("file") else "")}</Text>
        {<Text style={s.small}>{str(format.get("pages",0))+(" page" if format.get("pages",0)==1 else " pages")+" · "+str(summary.get("sections",0))+" sections · "+str(summary.get("entries",0))+" entries · "+str(summary.get("bullets",0))+" bullets"}</Text> if kind else <View/>}
        {<Text style={s.small}>{"Not used from your .zip: "+", ".join(format.get("skipped",[])[0:5])}</Text> if len(format.get("skipped",[]))>0 else <View/>}
        <Text style={s.small}>{"Stack edits only the content of your LaTeX (bullets, their order, skill lists) and keeps your layout. In Overleaf: Menu → Download → Source." if kind!="builtin" else "Built from your confirmed resume details. Upload your own LaTeX to keep your exact layout."}</Text>
        <Button label={"Replace LaTeX source" if kind=="upload" else "Upload LaTeX (.tex or Overleaf .zip)"} icon="upload" secondary={kind=="upload"} disabled={busy} onPress={upload}/>
        <View style={s.wrap}>
            {[<Chip key={t["key"]} label={t["label"]} active={kind=="builtin" and format.get("template")==t["key"]} onPress={lambda { change("use_resume_template",{"id":resume["id"],"template":t["key"]},"Template saved. Compilation continues if you close Stack."); }}/> for t in TEMPLATES]}
            {<Chip label="Remove format" onPress={lambda { change("use_resume_template",{"id":resume["id"],"template":""},"Removed. Upload LaTeX or choose a template to tailor this resume again."); }}/> if kind else <View/>}
        </View>
        {<View style={s.wrap}><Chip label="Preview format" onPress={lambda { open(False); }}/><Chip label={"Hide LaTeX" if showTex else "Show LaTeX"} active={showTex} onPress={lambda { if showTex { showTex=False; } else { open(True); } }}/></View> if kind or resume.get("details_status")=="Confirmed" else <View/>}
        {<Text style={s.small}>Working… The first LaTeX compile on this Mac can take a minute.</Text> if busy else <View/>}
        {<View style={s.noticeBox}><Text style={s.noticeText}>{notice}</Text></View> if notice else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
        {<View style={{gap:8}}><Chip label="Close preview" onPress={lambda { pdfUri=""; }}/><View style={{height:480}}><PDFView uri={pdfUri}/></View></View> if pdfUri else <View/>}
        {<Text selectable={True} style={[s.small,{fontFamily:"Menlo"}]}>{tex}</Text> if showTex and tex else <View/>}
    </View>
}

"""Tailoring edits LaTeX, so a resume that is only a PDF gets its LaTeX here, then onReady(resume id) continues.
Offers resumes that already have LaTeX, an upload, or Jake's template filled from confirmed details."""
def:pub LatexSetup(resume: dict[str, any], others: list[dict[str, any]], onChanged: any, onReady: any) -> JsxElement {
    has busy: bool = False, error: str = "", pending: bool = False, progress: dict[str, any] = {}, processing: dict[str, any] = {};
    async def check -> None {
        try {
            next=await rpc("bootstrap",{});onChanged(next);
            current=[r for r in next["resumes"] if r["id"]==resume["id"]];
            if not current { pending=False;error="Resume was deleted.";return; }
            processing=current[0].get("processing",{}).get("source",{});
            if processing.get("status")=="completed" { pending=False;await onReady(resume["id"]); }
            elif processing.get("status")=="failed" { pending=False; }
        } except Exception as e { error=errorText(e); }
    }
    async def upload -> None {
        if busy or pending { return; } error="";
        try {
            file=await pickLatexSource();
            if not file { return; }
            busy=True;
            next=await uploadResumeFile("upload_resume_source",{"id":resume["id"],"name":file["name"],"content":file["content"]},lambda (value: dict[str, any]) { progress=value; });
            onChanged(next);pending=True;await check();
        } except Exception as e { error=errorText(e); }
        busy=False;progress={};
    }
    <View style={[s.mutedBox,{gap:10}]}>
        <Text style={s.strong}>{"Add the LaTeX for "+resume["name"]}</Text>
        <ProcessingPoll active={pending or resume.get("processing",{}).get("source",{}).get("status") in ["queued","parsing","compiling"]} onRefresh={check}/>
        <ResumeProcessing resumeId={resume["id"]} kind="source" processing={processing or resume.get("processing",{}).get("source",{})} onChanged={lambda (next: dict[str, any]) { onChanged(next);pending=True;check(); }}/>
        {<Text style={s.small}>{uploadProgressText(progress)}</Text> if progress else <View/>}
        <Text style={s.small}>Tailoring rewrites and trims your LaTeX for this job, so your layout stays exactly the same. A PDF alone can't be tailored.</Text>
        {[<Button key={r["id"]} label={"Use "+r["name"]+" instead · has LaTeX"} icon="check" disabled={busy} onPress={lambda { onReady(r["id"]); }}/> for r in others]}
        <Button label="Upload LaTeX (.tex or Overleaf .zip)" icon="upload" secondary={len(others)>0} disabled={busy} onPress={upload}/>
        <Text style={s.small}>In Overleaf: Menu → Download → Source.</Text>
        <Text style={s.small}>Building a template from PDF details is temporarily unavailable. Upload your LaTeX source to continue.</Text>
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
    </View>
}
