import from "@jac/mobui" { View, Text }
import from "react" { useEffect, useRef }
import from "../device.js" { rpc, errorText, uploadResumeFile, confirmDelete }
import from "../audio-recording.js" { useRecording, localRecordings, saveLocalRecording, recordingContent, deleteLocalRecording, recordingClock }
import from ..theme { s }
import from .UI { Button, Field, Chip }

def:pub Transcription(owner: str) -> JsxElement {
    has recordings: list[dict[str, any]] = [], local: list[dict[str, any]] = [], current: dict[str, any] = {},
        text: str = "", dirty: bool = False, busy: bool = False, error: str = "", notice: str = "", progress: dict[str, any] = {}, runtime: dict[str, any] = {};
    capture=useRecording(owner);
    control=useRef({"busy":False,"refreshing":False,"dirty":False,"epoch":0,"edit_epoch":0});
    async def reload -> None {
        local=await localRecordings(owner);
        result=await rpc("transcription_list",{});recordings=result["recordings"];runtime=result.get("runtime",{});
    }
    async def refresh -> None {
        if control.current["refreshing"] { return; }
        control.current["refreshing"]=True;id=current.get("id","");epoch=control.current["epoch"];
        try {
            await reload();
            if id {
                result=await rpc("transcription_get",{"id":id});
                if epoch==control.current["epoch"] {
                    current=result;
                    if not control.current["dirty"] { text=result["transcript"]; }
                }
            }
        } except Exception as e { error=errorText(e); }
        control.current["refreshing"]=False;
    }
    async can with entry { await refresh(); }
    # Poll saved jobs without resubmitting audio. Keep edits independent of polling.
    useEffect(lambda {
        active=True;
        timer=setInterval(lambda { if active and not control.current["busy"] { refresh(); } },2500);
        return lambda { active=False;clearInterval(timer); };
    },[owner,current.get("id",""),dirty]);
    async def retrySetup -> None {
        try { runtime=await rpc("transcription_retry_setup",{});error=""; }
        except Exception as e { error=errorText(e); }
    }
    async def record -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";notice="";
        try { await capture.start(); }
        except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def upload(row: dict[str, any]) -> None {
        progress={};payload=await recordingContent(row);
        result=await uploadResumeFile("transcription_upload",payload,lambda (value: dict[str, any]) { progress=value; });
        await saveLocalRecording(owner,{**row,"server_id":result["id"],"status":"uploaded"});
        if not control.current["dirty"] { control.current["epoch"]+=1;current=result;text=result["transcript"]; }
        notice="Audio saved. Transcription continues if you close Stack.";
        await reload();
    }
    async def stop -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";
        try { row=await capture.stop();if row { await upload(row); } }
        except Exception as e { error=errorText(e);await localRecordings(owner).then(lambda (rows: any) { local=rows; }); }
        control.current["busy"]=False;busy=False;
    }
    async def retryUpload(row: dict[str, any]) -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";
        try { await upload(row); }
        except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def open(id: str) -> None {
        if dirty { error="Save your transcript changes before opening another recording.";return; }
        try { control.current["epoch"]+=1;current=await rpc("transcription_get",{"id":id});text=current["transcript"];error=""; }
        except Exception as e { error=errorText(e); }
    }
    async def change(action: str, id: str) -> None {
        if control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";control.current["epoch"]+=1;editEpoch=control.current["edit_epoch"];
        try {
            result=await rpc("transcription_action",{"id":id,"action":action,"text":text,"revision":current.get("revision",0)});
            if action=="delete" {
                for row in local { if row.get("server_id")==id { await deleteLocalRecording(owner,row); } }
                if current.get("id")==id { current={};text="";dirty=False;control.current["dirty"]=False; }
            } elif current.get("id")==id {
                current=result;
                if action=="save" {
                    if editEpoch==control.current["edit_epoch"] { text=result["transcript"];dirty=False;control.current["dirty"]=False;notice="Transcript saved. The original transcription is retained."; }
                    else { notice="The previous edit was saved. Save your latest changes when ready."; }
                }
            }
            await reload();
        } except Exception as e { error=errorText(e); }
        control.current["busy"]=False;busy=False;
    }
    async def removeLocal(row: dict[str, any]) -> None {
        try { await deleteLocalRecording(owner,row);await reload(); }
        except Exception as e { error=errorText(e); }
    }
    def edit(value: str) -> None { text=value;dirty=True;control.current["dirty"]=True;control.current["edit_epoch"]+=1; }
    <View style={s.card}>
        <Text style={s.heading}>Record an answer.</Text>
        <Text style={s.body}>Speak in English for up to five minutes. After you stop, Stack transcribes on your PC and saves the text for you to edit.</Text>
        <Text style={s.small}>{"Local transcription ready." if runtime.get("status")=="ready" else runtime.get("message","Checking local transcription…")}</Text>
        {<Button label="Retry local setup" secondary={True} onPress={retrySetup}/> if runtime.get("status")=="unavailable" else <View/>}
        <Text style={s.strong}>{recordingClock(capture.elapsed)}</Text>
        {<Button label="Stop and transcribe" onPress={stop} disabled={busy}/> if capture.recording else <Button label="Record" onPress={record} disabled={busy or dirty}/>}
        {<Text style={s.small}>Your recording stays on this phone until you delete it. Moving away from this screen or locking your phone stops recording.</Text>}
        {<Text style={s.errorText}>{error or capture.error}</Text> if error or capture.error else <View/>}
        {<Text style={s.small}>{"Uploading "+str(progress.get("percent","…"))+"%"}</Text> if progress.get("status")=="uploading" else <View/>}
        {<Text style={s.noticeText}>{notice}</Text> if notice else <View/>}
        {[<View key={row["client_id"]} style={s.hero}><Text style={s.small}>Saved on this phone · ready to upload</Text><Button label="Upload saved recording" secondary={True} disabled={busy or capture.recording} onPress={lambda { retryUpload(row); }}/><Chip label="Delete phone recording" onPress={lambda { confirmDelete("phone recording",lambda { removeLocal(row); }); }}/></View> for row in local if not row.get("server_id") and row["status"]!="recording"]}
        <Text style={s.strong}>Saved recordings</Text>
        {[<Button key={row["id"]} label={row["status"].capitalize()+" · "+str(round(row["duration_seconds"]))+" seconds"} secondary={True} disabled={busy or capture.recording} onPress={lambda { open(row["id"]); }}/> for row in recordings]}
        {<View style={{gap:10}}>
            <Text style={s.strong}>{current["status"].capitalize()+(" · "+str(round(current["percent"]))+"%" if current.get("percent") is not None else "")}</Text>
            <Text style={s.small}>{"Stage elapsed: "+recordingClock(Date.now()-current["stage_at"]*1000) if current["status"] in ["queued","decoding","loading","transcribing"] else ""}</Text>
            <Text style={s.small}>{"Upload: "+("pending" if current["timings"].get("transfer_ms") is None else str(round(current["timings"]["transfer_ms"]/1000,1))+"s")+" · Queue: "+str(round(current["timings"]["queue_ms"]/1000,1))+"s · Prepare: "+str(round(current["timings"]["decode_ms"]/1000,1))+"s · Load: "+str(round(current["timings"]["load_ms"]/1000,1))+"s · Transcribe: "+str(round(current["timings"]["transcribe_ms"]/1000,1))+"s"}</Text>
            {<Text style={s.errorText}>{current["error"]}</Text> if current.get("error") else <View/>}
            {<View style={{gap:10}}><Field label="Transcript" value={text} onChange={edit} multiline={True}/><Button label={"Save transcript" if dirty else "Transcript saved"} onPress={lambda { change("save",current["id"]); }} disabled={busy or not dirty}/><Text style={s.small}>{"Original: "+current["original_transcript"]}</Text></View> if current["status"]=="completed" else <View/>}
            {<Button label="Retry transcription" secondary={True} disabled={busy} onPress={lambda { change("retry",current["id"]); }}/> if current["status"] in ["failed","cancelled"] else <View/>}
            {<Button label="Cancel transcription" secondary={True} disabled={busy} onPress={lambda { change("cancel",current["id"]); }}/> if current["status"] in ["queued","decoding","loading","transcribing"] else <View/>}
            <Chip label="Delete recording and transcript" onPress={lambda { confirmDelete("recording and transcript",lambda { change("delete",current["id"]); }); }}/>
        </View> if len(current)>0 else <View/>}
    </View>
}
