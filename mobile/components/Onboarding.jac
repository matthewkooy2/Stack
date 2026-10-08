import from "@jac/mobui" { View, Text, Pressable, ScrollView }
import from "../device.js" { Icon }
import from ..theme { s }
import from .Access { AccessBack, AccessButton, AccessField }
import from .UI { Chip }
import from .MatchInputs { MatchInputs, toggled }

def:pub Onboarding(name: str, role: str, location: str, graduation: str, availableFrom: str, prefs: dict[str, any], busy: bool, onName: any, onRole: any, onLocation: any, onGraduation: any, onAvailable: any, onPrefs: any, onSave: any, onSignOut: any) -> JsxElement {
    has step: int = 0, details: bool = False;
    def put(key: str, value: any) -> None {
        updated={**prefs};updated[key]=value;onPrefs(updated);
    }
    <ScrollView style={s.accessScreen} contentContainerStyle={s.accessPage} keyboardShouldPersistTaps="handled">
        <View style={s.onboardingHeader}><AccessBack onPress={lambda { if step>0 { step-=1; } else { onSignOut(); } }} disabled={busy} label={"Back" if step>0 else "Back to sign in"}/><Text style={s.onboardingCount}>{str(step+1)+" / 3"}</Text></View>
        <View style={s.onboardingProgress}>{[<View key={str(i)} style={[s.onboardingTrack,s.onboardingFilled if i<=step else {}]}/> for i in range(3)]}</View>
        <View style={s.accessIntro}><Text style={s.accessTitle}>{"First, your name." if step==0 else ("What’s next for you?" if step==1 else "Where are you in your career?")}</Text><Text style={s.accessBody}>{"Let’s make this feel like you." if step==0 else ("A starting point for your search. You can change it anytime." if step==1 else "We’ll help you find opportunities that fit. You can skip this for now.")}</Text></View>
        {<AccessField label="Your name" value={name} onChange={onName} placeholder="What should we call you?" sentence={True}/> if step==0 else (
        <View style={s.accessFields}>
            <AccessField label="Target role" value={role} onChange={onRole} placeholder="For example, product designer"/>
            <AccessField label="Location" value={location} onChange={onLocation} placeholder="City, state, or United States"/>
            <View style={{gap:12}}><Text style={s.accessLabel}>Work arrangement</Text><View style={[s.wrap,{gap:8}]}><Chip label="Any" minimal={True} active={len(prefs["modes"])==0} onPress={lambda { put("modes",[]); }}/>{[<Chip key={v} label={v} minimal={True} active={v in prefs["modes"]} onPress={lambda { put("modes",toggled(prefs["modes"],v)); }}/> for v in ["Remote","Hybrid","On-site"]]}</View></View>
        </View> if step==1 else (
        <View>
            {[<Pressable key={v} accessibilityRole="button" accessibilityLabel={v} accessibilityState={{selected:prefs["stage"]==v}} onPress={lambda { put("stage","" if prefs["stage"]==v else v); }} style={s.onboardingChoice}><Text style={[s.onboardingChoiceText,s.onboardingChosenText if prefs["stage"]==v else {}]}>{v}</Text><Icon name={"check" if prefs["stage"]==v else "plus"} size={18} color={"#111111" if prefs["stage"]==v else "#BBBBBB"}/></Pressable> for v in ["Student","Recent graduate","Early career","Experienced","Career changer"]]}
            <Pressable accessibilityRole="button" accessibilityLabel={"Hide extra preferences" if details else "Add more preferences"} accessibilityState={{expanded:details}} onPress={lambda { details=not details; }} style={s.onboardingMore}><Text style={s.accessQuiet}>{"Less detail" if details else "Add more preferences"}</Text><Icon name={"x" if details else "plus"} size={15} color="#707070"/></Pressable>
            {<View style={s.onboardingDetails}><AccessField label="Expected graduation (YYYY-MM)" value={graduation} onChange={onGraduation} placeholder="Optional"/><AccessField label="Available full-time from (YYYY-MM)" value={availableFrom} onChange={onAvailable} placeholder="Optional"/><MatchInputs value={prefs} onChange={onPrefs} minimal={True} showStage={False}/></View> if details else <View/>}
        </View>))}
        <View style={s.accessFooter}><AccessButton label={"Saving…" if busy else ("Start exploring" if step==2 else "Continue")} disabled={busy or (step==0 and not name.strip())} onPress={lambda { if step<2 { step+=1; } else { onSave(); } }}/></View>
    </ScrollView>
}
