import from "../prototype/auth-animation.js" { NativeAccessButton }
import from "@jac/mobui" { View, Text, Pressable, TextInput, ScrollView }
import from "../auth-marks.js" { AuthMark }
import from "../device.js" { Icon }
import from ..theme { s }

def:pub AccessButton(label: str, onPress: any, disabled: bool = False, provider: str = "", outlined: bool = False) -> JsxElement {
    return <NativeAccessButton label={label} onPress={onPress} disabled={disabled} provider={provider} outlined={outlined} mark={AuthMark} styles={s}/>;
}

def:pub AccessField(label: str, value: str, onChange: any, placeholder: str = "", secret: bool = False, sentence: bool = False) -> JsxElement {
    <View style={{gap:10}}><Text style={s.accessLabel}>{label}</Text>
        <TextInput accessibilityLabel={label} style={s.accessInput} value={value} onChangeText={onChange} placeholder={placeholder} placeholderTextColor="#A0A0A0" secureTextEntry={secret} autoCapitalize={"words" if sentence else "none"} autoCorrect={sentence}/>
    </View>
}

def:pub AccessBack(onPress: any, label: str = "Back", disabled: bool = False) -> JsxElement {
    <Pressable accessibilityRole="button" accessibilityLabel={label} disabled={disabled} onPress={onPress} style={s.accessBack}><Icon name="back" size={22} color="#111111"/></Pressable>
}

def:pub Welcome(onStack: any, onProvider: any, busy: bool = False, error: str = "") -> JsxElement {
    <ScrollView style={s.accessScreen} contentContainerStyle={s.welcomePage} keyboardShouldPersistTaps="handled">
        <View style={s.welcomeIntro}><Text style={s.welcomeBrand}>Stack.</Text><Text style={s.welcomeSubtitle}>Your next chapter,{"\n"}one opportunity at a time.</Text></View>
        <View style={s.welcomeActions}>
            {<Text accessibilityLiveRegion="polite" style={s.accessError}>{error}</Text> if error else <View/>}
            <AccessButton label="Continue with Apple" provider="apple" onPress={lambda { return onProvider("apple"); }} disabled={busy} outlined={True}/>
            <AccessButton label="Continue with Google" provider="google" onPress={lambda { return onProvider("google"); }} disabled={busy} outlined={True}/>
            <AccessButton label="Continue with Stack" provider="stack" onPress={onStack} disabled={busy} outlined={True}/>
        </View>
    </ScrollView>
}

def:pub StackAccess(username: str, password: str, invite: str, signup: bool, busy: bool, error: str, onUsername: any, onPassword: any, onInvite: any, onSubmit: any, onToggle: any, onBack: any) -> JsxElement {
    has invitationOpen: bool = False;
    <ScrollView style={s.accessScreen} contentContainerStyle={s.accessPage} keyboardShouldPersistTaps="handled">
        <AccessBack onPress={onBack} disabled={busy}/>
        <View style={s.accessIntro}><Text style={s.accessTitle}>{"Make your move." if signup else "Welcome back."}</Text><Text style={s.accessBody}>{"Create your Stack account." if signup else "Your next chapter is waiting."}</Text></View>
        <View style={s.accessFields}>
            <AccessField label="Username" value={username} onChange={onUsername} placeholder="Your username"/>
            <AccessField label="Password" value={password} onChange={onPassword} secret={True} placeholder={"At least 8 characters" if signup else "Your password"}/>
            {<AccessField label="Beta invitation (first visit)" value={invite} onChange={onInvite} placeholder="Invitation code"/> if invitationOpen else <Pressable accessibilityRole="button" accessibilityLabel="I have an invitation code" onPress={lambda { invitationOpen=True; }}><Text style={s.accessQuiet}>I have an invitation code</Text></Pressable>}
            {<Text accessibilityLiveRegion="polite" style={s.accessError}>{error}</Text> if error else <View/>}
        </View>
        <View style={s.accessFooter}>
            <AccessButton label={"Please wait…" if busy else ("Create account" if signup else "Sign in")} onPress={onSubmit} disabled={busy}/>
            <Pressable accessibilityRole="button" accessibilityLabel={"Already have an account? Sign in" if signup else "New here? Create an account"} disabled={busy} onPress={onToggle} style={{paddingVertical:14}}><Text style={s.accessLink}>{"Already have an account? Sign in" if signup else "New here? Create an account"}</Text></Pressable>
        </View>
    </ScrollView>
}
