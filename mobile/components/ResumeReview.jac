import from "@jac/mobui" { View, Text, TextInput, Pressable, ActivityIndicator }
import from "../device.js" { rpc, errorText, Icon, openJobLink, ResumeProcessing, ProcessingPoll }
import from ..theme { s }
import from .UI { Button }

def:pub ResumeField(label: str, value: str, onChange: any, disabled: bool) -> JsxElement {
    # In-flow text sizes the row even before iOS emits input content-size events.
    # The final zero-width space preserves empty trailing lines while editing.
    typography={fontSize:15,lineHeight:22,letterSpacing:0,padding:10,includeFontPadding:False};
    <View style={{flex:1,minWidth:0,minHeight:46,backgroundColor:"#FFFFFF",borderRadius:6}}>
        <Text accessible={False} accessibilityElementsHidden={True} importantForAccessibility="no-hide-descendants" pointerEvents="none" style={[typography,{opacity:0}]}>{(value or "Not found")+"\u200b"}</Text>
        <TextInput accessibilityLabel={label} editable={not disabled} value={value} onChangeText={onChange} multiline={True} scrollEnabled={False} maxLength={8000} placeholder="Not found" placeholderTextColor="#8290A4" style={[typography,{position:"absolute",top:0,left:0,width:"100%",height:"100%",margin:0,color:"#172337",textAlignVertical:"top",borderRadius:6}]}/>
    </View>
}

def:pub ResumeBulletField(label: str, value: str, onChange: any, disabled: bool) -> JsxElement {
    has editing: bool = False;
    # Newlines retain the item boundaries returned by OpenResume, including cached reviews.
    items=[line.strip() for line in value.split("\n") if line.strip()];
    <View style={{flex:1,minWidth:0}}>
        {<View style={{flexDirection:"row"}}><ResumeField label={label} value={value} onChange={onChange} disabled={disabled}/></View> if editing else
            <View style={{padding:10,gap:10,backgroundColor:"#FFFFFF",borderRadius:6}}>
                {[<View key={index} style={{flexDirection:"row",alignItems:"flex-start",gap:8}}>
                    <Text accessible={False} accessibilityElementsHidden={True} importantForAccessibility="no-hide-descendants" style={{fontSize:15,lineHeight:22,color:"#172337"}}>{"\u2022"}</Text>
                    <Text style={{flex:1,minWidth:0,fontSize:15,lineHeight:22,letterSpacing:0,color:"#172337"}}>{item[2:] if item.startswith("\u2022 ") else item}</Text>
                </View> for (index,item) in enumerate(items)]}
                {<Text style={{fontSize:15,lineHeight:22,color:"#8290A4"}}>Not found</Text> if len(items)==0 else None}
            </View>}
        <Pressable accessibilityRole="button" accessibilityLabel={("Finish editing " if editing else "Edit ")+label} disabled={disabled} onPress={lambda { editing=not editing; }} style={{alignSelf:"flex-end",width:44,height:44,alignItems:"center",justifyContent:"center",opacity:0.5 if disabled else 1}}>
            <Icon name={"check" if editing else "edit"} size={18} color="#3765E8"/>
        </Pressable>
    </View>
}

def:pub ResumeReview(resumeId: str, onConfirmed: any = None) -> JsxElement {
    has document: dict[str, any] = {}, values: dict[str, str] = {}, expanded: list[str] = ["profile"],
        busy: bool = True, error: str = "", message: str = "", dirty: bool = False, showSource: bool = False;
    def populate(result: dict[str, any]) -> None {
        if document.get("revision")==result.get("revision") and dirty { return; }
        document=result;
        values={field["key"]:field["value"] for section in result["sections"] for field in section["fields"]};
        dirty=False;
    }
    async def load(retry: bool = False) -> None {
        busy=True;error="";
        try {
            if retry { await rpc("retry_resume_processing",{"id":resumeId,"kind":"pdf"}); }
            populate(await rpc("agent_extract_resume",{"id":resumeId}));
        }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    async can with entry { await load(); }
    async def save(confirm: bool) -> None {
        if busy { return; }
        busy=True;error="";message="";
        try {
            if dirty or not document["confirmed"] or not confirm { populate(await rpc("resume_save_details",{"id":resumeId,"revision":document["revision"],"values":values,"confirm":confirm})); }
            message="Resume details confirmed." if confirm else "Draft saved.";
            if confirm and onConfirmed { await onConfirmed(); }
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    def edit(key: str, value: str) -> None { updated={**values};updated[key]=value;values=updated;dirty=True;message=""; }
    def addEntry(kind: str) -> None {
        current=[section for section in document["sections"] if section["key"].startswith(kind+".")];
        index=len(current);
        if index>=20 { error="Up to 20 entries per section.";return; }
        prefix=kind+"."+str(index);template=current[0];
        added={"key":prefix,"label":template["label"].split(" 1")[0]+" "+str(index+1),"summary":"New entry","fields":[{"key":prefix+"."+field["key"].split(".")[-1],"label":field["label"],"value":""} for field in template["fields"]]};
        document={**document,"sections":document["sections"]+[added]};
        values={**values,**{field["key"]:"" for field in added["fields"]}};expanded=expanded+[prefix];dirty=True;
    }
    <View style={{gap:16}}>
        <ProcessingPoll active={document.get("processing",{}).get("status") in ["queued","parsing"]} onRefresh={load}/>
        <ResumeProcessing resumeId={resumeId} processing={document.get("processing",{})} onChanged={lambda (next: dict[str, any]) { load(); }}/>
        {<ActivityIndicator accessibilityLabel="Reading resume" color="#3765E8"/> if busy else None}
        {<Text style={s.errorText}>{error}</Text> if error else None}
        {<Button label="Retry parsing" icon="retry" secondary={True} disabled={busy} onPress={lambda { load(True); }}/> if error and not document else None}
        {<View style={{gap:16}}>
            <View style={s.between}><Text style={[s.strong,{flex:1}]}>{document["name"]}</Text><Text style={s.status}>{"Unsaved changes" if dirty else "Confirmed" if document["confirmed"] else "Needs review"}</Text></View>
            {[<Text key={warning} style={s.small}>{warning}</Text> for warning in document.get("warnings",[])]}
            {[<View key={section["key"]}>
                <Pressable accessibilityRole="button" accessibilityLabel={section["label"]} accessibilityState={{"expanded":section["key"] in expanded}} onPress={lambda { expanded=[key for key in expanded if key!=section["key"]] if section["key"] in expanded else expanded+[section["key"]]; }} style={{flexDirection:"row",alignItems:"center",gap:10,paddingVertical:16,borderBottomWidth:1,borderBottomColor:"#DDE4EF"}}>
                    <View style={{transform:[{rotate:"90deg" if section["key"] in expanded else "0deg"}]}}><Icon name="chevron" size={18}/></View>
                    <View style={s.grow}><Text style={[s.strong,{fontSize:17,letterSpacing:0}]}>{section["label"]}</Text><Text style={s.small}>{section["summary"]}</Text></View>
                </Pressable>
                {<View>{[<View key={field["key"]} style={{flexDirection:"row",alignItems:"flex-start",borderBottomWidth:1,borderBottomColor:"#E8ECF3",paddingVertical:8}}>
                    <Text style={{width:"30%",paddingTop:12,paddingRight:8,fontSize:13,fontWeight:"600",lineHeight:19,color:"#59677D",letterSpacing:0}}>{"Details" if field["label"]=="Descriptions" else field["label"]}</Text>
                    {<ResumeBulletField label={section["label"]+" "+field["label"]} disabled={busy} value={values.get(field["key"],"")} onChange={lambda (value: str) { edit(field["key"],value); }}/> if field["key"].endswith(".descriptions") and not field["key"].startswith("additional.") else
                        <ResumeField label={section["label"]+" "+field["label"]} disabled={busy} value={values.get(field["key"],"")} onChange={lambda (value: str) { edit(field["key"],value); }}/>
                    }
                </View> for field in section["fields"]]}</View> if section["key"] in expanded else <View/>}
            </View> for section in document["sections"]]}
            <View style={s.wrap}>{[<Button key={kind} label={label} icon="plus" secondary={True} disabled={busy} onPress={lambda { addEntry(kind); }}/> for (kind,label) in [["educations","Add education"],["workExperiences","Add experience"],["projects","Add project"]]]}</View>
            <Button label={"Hide extracted text" if showSource else "View extracted text"} secondary={True} onPress={lambda { showSource=not showSource; }}/>
            {<Text selectable={True} style={s.body}>{document.get("text","")}</Text> if showSource else None}
            <Button label={"Confirm and continue tailoring" if onConfirmed else "Confirm resume details"} icon="check" disabled={busy or (document["confirmed"] and not dirty and not onConfirmed)} onPress={lambda { save(True); }}/>
            <Button label="Save draft" secondary={True} disabled={busy or not dirty} onPress={lambda { save(False); }}/>
            {<Text style={s.status}>{message}</Text> if message else None}
            <Pressable accessibilityRole="link" accessibilityLabel="OpenResume source and license" onPress={lambda { openJobLink("https://github.com/xitanggg/open-resume"); }}><Text style={s.small}>OpenResume · AGPL-3.0 · Source and license · No warranty</Text></Pressable>
        </View> if document.get("sections") else <View/>}
    </View>
}
