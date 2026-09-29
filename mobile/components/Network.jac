import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText, dateTime, Icon }
import from ..theme { s }
import from .LinkedInProfile { LinkedInProfile }
import from .UI { Button, Field, Chip }
import from .Agents { FeatureCard, TaskRow, featureByKey, runsFor, withKey }

"""Contact form drafts survive leaving the tab or a failed save."""
glob FORM: dict[str, str] = {"name":"","email":"","company":"","relationship":"","source_url":"","import":""};

"""Your real contacts. Saving never sends; outreach starts only on request and waits for review."""
def:pub NetworkAgent(runs: list[dict[str, any]], features: list[dict[str, any]], onOpenTask: any, onNavigate: any) -> JsxElement {
    has contacts: list[dict[str, any]] = [], form: dict[str, str] = FORM, error: str = "", notice: str = "", busy: bool = False, adding: bool = False;
    def edit(key: str, value: str) -> None { form=withKey(form,key,value);FORM[key]=value; }
    def clear(keys: list[str]) -> None {
        updated={**form};
        for k in keys { updated[k]="";FORM[k]=""; }
        form=updated;
    }
    async def load -> None {
        try { result=await rpc("agent_contacts",{});contacts=result["contacts"]; } except Exception as e { error=errorText(e); }
    }
    async can with entry { await load(); }
    async def perform(endpoint: str, args: dict[str, any], done: str) -> bool {
        if busy { return False; } busy=True;error="";notice="";ok=False;
        try {
            result=await rpc(endpoint,args);notice=done;ok=True;
            if endpoint=="agent_start" { await load(); } else { contacts=result["contacts"]; }
        }
        except Exception as e { error=errorText(e); }
        busy=False;return ok;
    }
    async def save -> None {
        data={"name":form["name"],"email":form["email"],"company":form["company"],"relationship":form["relationship"],"source":"User supplied","source_url":form["source_url"],"selected":True};
        if await perform("agent_save_contact",{"data":data},"Contact saved. Nothing was sent. Tap Draft outreach when you are ready.") { clear(["name","email","company","relationship","source_url"]);adding=False; }
    }
    async def importContacts -> None {
        if await perform("agent_import_contacts",{"content":form["import"]},"Imported. Imported contacts stay unselected until you choose them.") { clear(["import"]); }
    }
    feature=featureByKey(features,"networking");
    <View style={{gap:14}}>
        <LinkedInProfile runs={runs} features={features} onOpenTask={onOpenTask} onNavigate={onNavigate}/>
        <View style={s.row}><Icon name="mail" color="#3765E8"/><Text style={s.heading}>Your contacts</Text></View>
        <Text style={s.body}>Add people you know or have researched. Saving a contact never contacts them. When you ask, Stack drafts a short email from your confirmed facts and waits for you to review, edit, and approve it.</Text>
        {<FeatureCard feature={feature} onNavigate={onNavigate} compact={True}/> if len(feature)>0 else <View/>}
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
        {<View style={s.noticeBox}><Text style={s.noticeText}>{notice}</Text></View> if notice else <View/>}
        {[<View key={c["id"]} style={s.taskCard}>
            <View style={s.between}><Text style={[s.strong,{flex:1}]}>{c["name"]}</Text><Chip label={"Outreach stopped" if c["stopped"] else ("Selected" if c["selected"] else "Not selected")} active={c["selected"] and not c["stopped"]}/></View>
            <Text style={s.small}>{c["email"]+(" · "+c["company"] if c.get("company") else "")}</Text>
            {<Text style={s.small}>{c["relationship"]}</Text> if c.get("relationship") else <View/>}
            {<Text style={s.small}>{"Follow-ups sent: "+str(c["followups"])+(" · next draft "+dateTime(c["next_at"]) if c["next_at"] else "")}</Text> if c["followups"]>0 or c["next_at"] else <View/>}
            {[<View key={t["id"]}><TaskRow run={t} onOpen={lambda { onOpenTask(t["id"]); }}/></View> for t in runsFor(runs,c["id"],["network"])[0:2]]}
            {<Button label="Select for outreach" secondary={True} disabled={busy} onPress={lambda { perform("agent_save_contact",{"id":c["id"],"data":{**c,"selected":True}},"Selected. Nothing was sent."); }}/> if not c["selected"] and not c["stopped"] else <View/>}
            {<Button label="Draft outreach for my review" disabled={busy or feature.get("state","")=="unavailable"} onPress={lambda { perform("agent_start",{"kind":"network","target_id":c["id"]},"Drafting. You will review the email before anything is sent."); }}/> if c["selected"] and not c["stopped"] else <View/>}
            {<Button label="Stop outreach and follow-ups" secondary={True} disabled={busy} onPress={lambda { perform("agent_stop_contact",{"id":c["id"]},"Outreach stopped for this contact."); }}/> if not c["stopped"] else <View/>}
        </View> for c in contacts]}
        {<Text style={s.small}>No contacts yet.</Text> if len(contacts)==0 else <View/>}
        {<View style={{gap:12}}>
            <Field label="Contact name" value={form["name"]} onChange={lambda (v: str) { edit("name",v); }}/>
            <Field label="Verified email" value={form["email"]} onChange={lambda (v: str) { edit("email",v); }}/>
            <Field label="Company" value={form["company"]} onChange={lambda (v: str) { edit("company",v); }}/>
            <Field label="How you know them" value={form["relationship"]} onChange={lambda (v: str) { edit("relationship",v); }} multiline={True}/>
            <Field label="Public research source (optional)" value={form["source_url"]} onChange={lambda (v: str) { edit("source_url",v); }} placeholder="https://company.com/team"/>
            <Button label="Save contact" icon="bookmark" disabled={busy or not form["name"].strip()} onPress={save}/>
            <Field label="Or paste CSV rows (name,email,relationship)" value={form["import"]} onChange={lambda (v: str) { edit("import",v); }} multiline={True}/>
            <Button label="Import contacts" secondary={True} disabled={busy or not form["import"].strip()} onPress={importContacts}/>
            <Button label="Close contact form" secondary={True} onPress={lambda { adding=False; }}/>
        </View> if adding else <Button label="Add a contact" icon="plus" secondary={True} onPress={lambda { adding=True; }}/>}
    </View>
}
