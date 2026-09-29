import from "@jac/mobui" { View, Text }
import from "../device.js" { rpc, errorText }
import from ..theme { s }
import from .UI { Button, Field }
import from .Agents { FeatureCard, TaskRow, featureByKey, runsFor }

def:pub LinkedInProfile(runs: list[dict[str, any]], features: list[dict[str, any]], onOpenTask: any, onNavigate: any) -> JsxElement {
    has url: str = "", role: str = "", savedUrl: str = "", savedRole: str = "", busy: bool = False, loading: bool = True, error: str = "", notice: str = "";
    async can with entry {
        try { result=await rpc("agent_linkedin_profile",{});savedUrl=result["url"];url=result["url"];role=result.get("target_role","");savedRole=role; }
        except Exception as e { error=errorText(e); }
        loading=False;
    }
    async def save -> None {
        if busy { return; } busy=True;error="";notice="";
        try { result=await rpc("agent_linkedin_profile",{"url":url,"target_role":role});url=result["url"];savedUrl=result["url"];savedRole=role;notice="Saved to your Stack account."; }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    feature=featureByKey(features,"linkedin");
    async def start -> None {
        if busy { return; } busy=True;error="";
        try { result=await rpc("agent_linkedin_start",{"url":url,"target_role":role});onOpenTask(result["id"]); }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    <View style={s.taskCard}>
        <Text style={s.heading}>Strengthen your LinkedIn profile</Text>
        <Text style={s.body}>See what a recruiter can learn from your headline, About, experience, and skills. Get prioritized fixes and suggested rewrites grounded in your profile and confirmed facts.</Text>
        {<FeatureCard feature={feature} onNavigate={onNavigate} compact={True}/> if len(feature)>0 else <View/>}
        {<Field label="Your LinkedIn profile URL" value={url} placeholder="https://www.linkedin.com/in/your-name/" onChange={lambda (v: str) { url=v;notice=""; }}/> if not loading else <Text style={s.small}>Loading your saved profile…</Text>}
        <Text style={s.small}>Your profile URL and target role are saved to your Stack account for future reviews. You can change it here.</Text>
        <Button label="Save profile details" secondary={True} disabled={loading or busy or not url.strip() or (url==savedUrl and role==savedRole)} onPress={save}/>
        {<Text style={s.small}>{notice}</Text> if notice else <View/>}
        <Field label="Target role (optional)" value={role} placeholder="e.g. Product designer" onChange={lambda (v: str) { role=v; }}/>
        <Text style={s.small}>Sign in to LinkedIn inside the agent browser in this app, then confirm the profile is yours. You can watch the agent read it. Captured profile text goes to your configured model; login details stay in the temporary browser session. You choose which edits to apply.</Text>
        {<Text style={s.errorText}>{error}</Text> if error else <View/>}
        <Button label="Review my LinkedIn profile" disabled={loading or busy or not url.strip() or feature.get("state")=="unavailable"} onPress={start}/>
        {[<View key={r["id"]}><TaskRow run={r} onOpen={lambda { onOpenTask(r["id"]); }}/></View> for r in runsFor(runs,"self",["linkedin"])[0:3]]}
    </View>
}
