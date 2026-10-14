import from "@jac/mobui" { View, Text, Pressable, TextInput }
import from "../device.js" { Icon }
import from ..theme { s }

def:pub Button(label: str, onPress: any, secondary: bool = False, disabled: bool = False, icon: str = "") -> JsxElement {
    <Pressable accessibilityRole="button" accessibilityLabel={label} disabled={disabled} onPress={onPress} style={[s.button,s.secondary if secondary else {},{opacity:0.5 if disabled else 1}]}>
        {<Icon name={icon} color={"#43526B" if secondary else "#FFFFFF"} size={18}/> if icon else <View/>}
        <Text style={[s.buttonText,s.secondaryText if secondary else {}]}>{label}</Text>
    </Pressable>
}
def:pub Field(label: str, value: str, onChange: any, placeholder: str = "", multiline: bool = False, secret: bool = False, minimal: bool = False) -> JsxElement {
    <View>
        <Text style={s.accessLabel if minimal else s.label}>{label}</Text>
        <TextInput accessibilityLabel={label} style={[s.accessInput if minimal else s.input,{minHeight:125,textAlignVertical:"top"} if multiline else {}]} value={value} onChangeText={onChange} placeholder={placeholder} placeholderTextColor="#95A0B2" multiline={multiline} secureTextEntry={secret} autoCapitalize={"none" if secret or label=="Username" else "sentences"} autoCorrect={not secret and label!="Username"}/>
    </View>
}
def:pub Chip(label: str, active: bool = False, onPress: any = None, minimal: bool = False) -> JsxElement {
    <Pressable accessibilityRole="button" accessibilityLabel={label} accessibilityState={{selected:active}} onPress={onPress} disabled={onPress is None} style={[s.accessChip if minimal else s.chip,(s.accessSelectedChip if minimal else s.selectedChip) if active else {}]}><Text style={[s.accessChipText if minimal else s.chipText,(s.accessSelectedText if minimal else s.selectedText) if active else {}]}>{label}</Text></Pressable>
}
def:pub Empty(title: str, text: str, icon: str = "sparkles") -> JsxElement {
    <View style={s.empty}><Icon name={icon} size={36} color="#6E8DE1"/><Text style={[s.heading,{textAlign:"center"}]}>{title}</Text><Text style={[s.body,{textAlign:"center"}]}>{text}</Text></View>
}
def:pub Logo(job: dict[str, any]) -> JsxElement {
    <View style={[s.logo,{backgroundColor:job["color"]}]}><Text style={s.logoText}>{job["initial"]}</Text></View>
}
