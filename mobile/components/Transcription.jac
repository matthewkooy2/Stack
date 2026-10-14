import from "@jac/mobui" { View, Text, Switch }
import from "react" { useEffect, useRef }
import from "../device.js" { rpc, errorText, uploadResumeFile, confirmDelete }
import from "../audio-recording.js" { useRecording, localRecordings, saveLocalRecording, recordingContent, deleteLocalRecording, recordingClock, savePhoneTranscript }
import from ..theme { s }
import from .UI { Button, Field, Chip }

def:pub Transcription(owner: str) -> JsxElement {
    has recordings: list[dict[str, any]] = [], local: list[dict[str, any]] = [], current: dict[str, any] = {},
        text: str = "", dirty: bool = False, busy: bool = False, syncing: bool = False, error: str = "", notice: str = "", progress: dict[str, any] = {}, runtime: dict[str, any] = {}, showLive: bool = False, clientTranscripts: bool = False;
    capture=useRecording(owner);
    control=useRef({"busy":False,"refreshing":False,"dirty":False,"syncing":False,"mounted":True,"epoch":0,"edit_epoch":0});
    # Prep keys this component by owner. Old async handlers must stop at unmount.
    useEffect(lambda {
        control.current["mounted"]=True;
        return lambda { control.current["mounted"]=False;control.current["epoch"]+=1; };
    },[]);
    async def reload -> None {
        if not control.current["mounted"] { return; }
        rows=await localRecordings(owner);
        if not control.current["mounted"] { return; }
        local=rows;
        result=await rpc("transcription_list",{});
        if not control.current["mounted"] { return; }
        recordings=result["recordings"];runtime=result.get("runtime",{});clientTranscripts=result.get("client_transcripts",False);
    }
    async def refresh -> None {
        if not control.current["mounted"] or control.current["refreshing"] { return; }
        control.current["refreshing"]=True;id=current.get("id","");epoch=control.current["epoch"];
        try {
            await reload();
            if not control.current["mounted"] { return; }
            if id and not current.get("phone_only") {
                result=await rpc("transcription_get",{"id":id});
                if control.current["mounted"] and epoch==control.current["epoch"] {
                    current=result;
                    if not control.current["dirty"] { text=result["transcript"]; }
                }
            }
        } except Exception as e { if control.current["mounted"] { error=errorText(e); } }
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
        if not control.current["mounted"] { return; }
        try { result=await rpc("transcription_retry_setup",{});if control.current["mounted"] { runtime=result;error=""; } }
        except Exception as e { if control.current["mounted"] { error=errorText(e); } }
    }
    async def record -> None {
        if not control.current["mounted"] or control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";notice="";
        try { await capture.start(); }
        except Exception as e { if control.current["mounted"] { error=errorText(e); } }
        control.current["busy"]=False;if control.current["mounted"] { busy=False; }
    }
    async def upload(row: dict[str, any]) -> None {
        if not control.current["mounted"] or row.get("owner")!=owner { return; }
        if control.current["dirty"] { error="Save your transcript changes before syncing a recording.";return; }
        if row.get("status")=="completed" and not clientTranscripts {
            if not control.current["dirty"] { openPhone(row); }
            notice="On-device transcript saved on this phone. Server sync will be available after the backend update.";
            await reload();return;
        }
        control.current["syncing"]=True;syncing=True;
        try {
            progress={};payload=await recordingContent(row);
            if not control.current["mounted"] { return; }
            if row.get("status")=="completed" { payload={**payload,"local_transcript":row["original_transcript"]}; }
            result=await uploadResumeFile("transcription_upload",payload,lambda (value: dict[str, any]) { if control.current["mounted"] { progress=value; } });
            if not control.current["mounted"] { return; }
            if row.get("status")=="completed" and result["status"]!="completed" { openPhone(row);notice="Your on-device transcript is saved on this phone. A previous PC job already exists for this audio.";return; }
            if row.get("status")=="completed" and row["transcript"]!=row["original_transcript"] {
                result=await rpc("transcription_action",{"id":result["id"],"action":"save","text":row["transcript"],"revision":result["revision"]});
                if not control.current["mounted"] { return; }
            }
            await saveLocalRecording(owner,{**row,"server_id":result["id"],"status":"uploaded"});
            if not control.current["mounted"] { return; }
            if not control.current["dirty"] { control.current["epoch"]+=1;current=result;text=result["transcript"]; }
            notice="Audio and on-device transcript saved." if result["status"]=="completed" else "Audio saved. PC transcription continues if you close Stack.";
            await reload();
        } finally {
            control.current["syncing"]=False;if control.current["mounted"] { syncing=False; }
        }
    }
    async def stop(cancelled: bool = False) -> None {
        if not control.current["mounted"] or control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";
        try { row=await capture.stop(cancelled);if not control.current["mounted"] { return; }if row and row["status"]=="completed" { openPhone(row); }if row and not cancelled { await upload(row); } else { await reload();if control.current["mounted"] { notice="Recording cancelled. The partial audio stays on this phone."; } } }
        except Exception as e { if control.current["mounted"] { error=errorText(e);await localRecordings(owner).then(lambda (rows: any) { if control.current["mounted"] { local=rows; } }); } }
        control.current["busy"]=False;if control.current["mounted"] { busy=False; }
    }
    async def retryUpload(row: dict[str, any]) -> None {
        if not control.current["mounted"] or control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";
        try { await upload(row); }
        except Exception as e { if control.current["mounted"] { error=errorText(e); } }
        control.current["busy"]=False;if control.current["mounted"] { busy=False; }
    }
    def openPhone(row: dict[str, any]) -> None {
        if not control.current["mounted"] { return; }
        if dirty { error="Save your transcript changes before opening another recording.";return; }
        control.current["epoch"]+=1;
        current={**row,"id":row["client_id"],"phone_only":True,"duration_seconds":row["duration_ms"]/1000,"stage_at":row["created_at"],"percent":100,"error":"","timings":{"transfer_ms":None,"queue_ms":0,"decode_ms":0,"load_ms":0,"transcribe_ms":0}};
        text=row.get("transcript","");error="";
    }
    async def open(id: str) -> None {
        if not control.current["mounted"] { return; }
        if dirty { error="Save your transcript changes before opening another recording.";return; }
        try { control.current["epoch"]+=1;result=await rpc("transcription_get",{"id":id});if not control.current["mounted"] { return; }current=result;text=current["transcript"];error=""; }
        except Exception as e { if control.current["mounted"] { error=errorText(e); } }
    }
    async def change(action: str, id: str) -> None {
        if not control.current["mounted"] or control.current["busy"] { return; }
        control.current["busy"]=True;busy=True;error="";control.current["epoch"]+=1;editEpoch=control.current["edit_epoch"];
        try {
            if current.get("phone_only") and current["id"]==id {
                if action=="save" {
                    saved=await savePhoneTranscript(owner,current,text,current["revision"]);
                    if not control.current["mounted"] { return; }
                    current={**current,**saved};
                    if editEpoch==control.current["edit_epoch"] { dirty=False;control.current["dirty"]=False;notice="Transcript saved on this phone. The original is retained."; }
                    await reload();
                }
                control.current["busy"]=False;if control.current["mounted"] { busy=False; }return;
            }
            result=await rpc("transcription_action",{"id":id,"action":action,"text":text,"revision":current.get("revision",0)});
            if not control.current["mounted"] { return; }
            if action=="delete" {
                for row in local { if row.get("server_id")==id { await deleteLocalRecording(owner,row); } }
                if not control.current["mounted"] { return; }
                if current.get("id")==id { current={};text="";dirty=False;control.current["dirty"]=False; }
            } elif current.get("id")==id {
                current=result;
                if action=="save" {
                    if editEpoch==control.current["edit_epoch"] { text=result["transcript"];dirty=False;control.current["dirty"]=False;notice="Transcript saved. The original transcription is retained."; }
                    else { notice="The previous edit was saved. Save your latest changes when ready."; }
                }
            }
            await reload();
        } except Exception as e { if control.current["mounted"] { error=errorText(e); } }
        control.current["busy"]=False;if control.current["mounted"] { busy=False; }
    }
    async def removeLocal(row: dict[str, any]) -> None {
        if not control.current["mounted"] or control.current["busy"] { return; }
        try { await deleteLocalRecording(owner,row);if not control.current["mounted"] { return; }if current.get("phone_only") and current.get("id")==row["client_id"] { current={};text="";dirty=False;control.current["dirty"]=False; }await reload(); }
        except Exception as e { if control.current["mounted"] { error=errorText(e); } }
    }
    useEffect(lambda {
        if capture.current and capture.current.get("owner")==owner and capture.current["status"]=="completed" and not capture.recording and not control.current["busy"] and not dirty {
            openPhone(capture.current);
        }
    },[capture.current]);
    def edit(value: str) -> None { if not control.current["mounted"] or control.current["syncing"] { return; }text=value;dirty=True;control.current["dirty"]=True;control.current["edit_epoch"]+=1; }
    <View style={s.card}>
        <Text style={s.heading}>Record an answer.</Text>
        <Text style={s.body}>Speak in English for up to five minutes. Supported iPhones transcribe on this device while you speak. The PC is used when on-device speech is unavailable.</Text>
        <View style={{flexDirection:"row",alignItems:"center",gap:12}}><Text style={s.body}>Show live transcript</Text><Switch accessibilityLabel="Show live transcript" value={showLive} onValueChange={lambda (value: bool) { showLive=value; }}/></View>
        {<Text style={s.small}>{capture.engineMessage}</Text> if capture.engineMessage else <View/>}
        {<Text accessibilityLabel="Live transcript" style={s.body}>{capture.liveText}</Text> if capture.recording and showLive else <View/>}
        <Text style={s.small}>{"Local transcription ready." if runtime.get("status")=="ready" else runtime.get("message","Checking local transcription…")}</Text>
        {<Button label="Retry local setup" secondary={True} onPress={retrySetup}/> if runtime.get("status")=="unavailable" else <View/>}
        <Text style={s.strong}>{recordingClock(capture.elapsed)}</Text>
        {<Button label="Stop and transcribe" onPress={lambda { stop(); }} disabled={busy}/> if capture.recording else <Button label="Record" onPress={record} disabled={busy or dirty}/>}
        {<Button label="Cancel recording" secondary={True} onPress={lambda { stop(True); }} disabled={busy}/> if capture.recording else <View/>}
        {<Text style={s.small}>Your recording stays on this phone until you delete it. Moving away from this screen or locking your phone stops recording.</Text>}
        {<Text style={s.errorText}>{error or capture.error}</Text> if error or capture.error else <View/>}
        {<Text style={s.small}>{"Uploading "+str(progress.get("percent","…"))+"%"}</Text> if progress.get("status")=="uploading" else <View/>}
        {<Text style={s.noticeText}>{notice}</Text> if notice else <View/>}
        {[<View key={row["client_id"]} style={s.hero}><Text style={s.small}>{"On-device transcript saved on this phone" if row["status"]=="completed" else "Saved on this phone · ready for PC transcription"}</Text>{<Button label="Open phone transcript" secondary={True} disabled={busy or dirty or capture.recording} onPress={lambda { openPhone(row); }}/> if row["status"]=="completed" else <View/>}<Button label={"Sync phone transcript" if row["status"]=="completed" else "Upload saved recording"} secondary={True} disabled={busy or dirty or capture.recording or (row["status"]=="completed" and not clientTranscripts)} onPress={lambda { retryUpload(row); }}/><Chip label="Delete phone recording" onPress={lambda { confirmDelete("phone recording",lambda { removeLocal(row); }); }}/></View> for row in local if not row.get("server_id") and row["status"]!="recording"]}
        <Text style={s.strong}>Saved recordings</Text>
        {[<Button key={row["id"]} label={row["status"].capitalize()+" · "+str(round(row["duration_seconds"]))+" seconds"} secondary={True} disabled={busy or capture.recording} onPress={lambda { open(row["id"]); }}/> for row in recordings]}
        {<View style={{gap:10}}>
            <Text style={s.strong}>{current["status"].capitalize()+(" · "+str(round(current["percent"]))+"%" if current.get("percent") is not None else "")}</Text>
            <Text style={s.small}>{"Stage elapsed: "+recordingClock(Date.now()-current["stage_at"]*1000) if current["status"] in ["queued","decoding","loading","transcribing"] else ""}</Text>
            <Text style={s.small}>{"Upload: "+("pending" if current["timings"].get("transfer_ms") is None else str(round(current["timings"]["transfer_ms"]/1000,1))+"s")+" · Queue: "+str(round(current["timings"]["queue_ms"]/1000,1))+"s · Prepare: "+str(round(current["timings"]["decode_ms"]/1000,1))+"s · Load: "+str(round(current["timings"]["load_ms"]/1000,1))+"s · Transcribe: "+str(round(current["timings"]["transcribe_ms"]/1000,1))+"s"}</Text>
            {<Text style={s.errorText}>{current["error"]}</Text> if current.get("error") else <View/>}
            {<View style={{gap:10}}>{<View><Text style={s.label}>Transcript</Text><Text style={s.body}>{text}</Text></View> if syncing else <Field label="Transcript" value={text} onChange={edit} multiline={True}/>}<Button label={"Save transcript" if dirty else "Transcript saved"} onPress={lambda { change("save",current["id"]); }} disabled={busy or not dirty}/><Text style={s.small}>{"Original: "+current["original_transcript"]}</Text></View> if current["status"]=="completed" else <View/>}
            {<Button label="Retry transcription" secondary={True} disabled={busy} onPress={lambda { change("retry",current["id"]); }}/> if current["status"] in ["failed","cancelled"] else <View/>}
            {<Button label="Cancel transcription" secondary={True} disabled={busy} onPress={lambda { change("cancel",current["id"]); }}/> if current["status"] in ["queued","decoding","loading","transcribing"] else <View/>}
            {<Chip label="Delete recording and transcript" onPress={lambda { confirmDelete("recording and transcript",lambda { change("delete",current["id"]); }); }}/> if not current.get("phone_only") else <View/>}
        </View> if len(current)>0 else <View/>}
    </View>
}
