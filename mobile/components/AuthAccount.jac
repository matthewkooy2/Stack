import from "@jac/mobui" { View, Text, ScrollView }
import from .UI { Button, Field }
import from "../device.js" { liveData }
import from ..theme { s }

def:pub InvitationGate(value: str, onChange: any, onSubmit: any, onSignOut: any, busy: bool, error: str, info: dict[str, any], onRecover: any) -> JsxElement {
    return <ScrollView contentContainerStyle={s.content} keyboardShouldPersistTaps="handled">
        <Text style={s.heading}>Finish signing in</Text>
        <Text style={s.body}>Your account is authenticated. A beta invitation is required to enter Stack.</Text>
        <Field label="Beta invitation" value={value} onChange={onChange}/>
        {<Text accessibilityLiveRegion="polite" style={s.errorText}>{error}</Text> if error else <View/>}
        <Button label="Continue" onPress={onSubmit} disabled={busy}/>
        {<AuthAccount info={info} busy={busy} pending={False} onLink={onSubmit} onCancel={onSignOut} onRecover={onRecover}/> if info.get("can_recover") else <View/>}
        <Button label="Sign out" onPress={onSignOut} secondary={True} disabled={busy}/>
    </ScrollView>;
}

def:pub AuthAccount(info: dict[str, any], busy: bool, pending: bool, onLink: any, onCancel: any, onRecover: any) -> JsxElement {
    has username: str = "", password: str = "";
    async def recover -> None {
        try { await onRecover(username,password); } finally { password=""; }
    }
    return <View style={[s.card,{gap:12}]}>
        <Text style={s.heading}>Your sign-in</Text>
        <Text style={s.body}>{"Signed in as " + info.get("username","")}</Text>
        <Text style={s.small}>{"Your resumes, applications, contacts and practice are saved to this account." if liveData else "Authentication is real. Feature screens show demo data; your saved account content is unchanged."}</Text>
        {<Text style={s.strong}>Google sign-in linked</Text> if info.get("google") else <Button label="Link Google sign-in" onPress={onLink} disabled={busy} secondary={True}/>}
        {<Button label="Cancel Google sign-in" onPress={onCancel} secondary={True}/> if pending else <View/>}
        {(<View style={{gap:12}}><Text style={s.strong}>Use your existing Stack account</Text><Text style={s.small}>Confirm your original Stack credentials to preserve its account and saved data.</Text><Field label="Existing Stack username" value={username} onChange={lambda (v: str) { username=v; }}/><Field label="Existing Stack password" value={password} secret={True} onChange={lambda (v: str) { password=v; }}/><Button label="Use my existing Stack account" onPress={recover} disabled={busy}/></View>) if info.get("can_recover") else <View/>}
    </View>;
}
