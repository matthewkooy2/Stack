import from "@jac/mobui" { View, Text }
import from ..theme { s }

def:pub ResumeUnavailable() -> JsxElement {
    <View style={s.card}>
        <Text style={s.heading}>Resume details are temporarily unavailable</Text>
        <Text style={s.body}>Your PDF remains saved. You can preview it and upload your LaTeX source for tailoring.</Text>
    </View>
}
