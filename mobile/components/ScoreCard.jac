import from "@jac/mobui" { View, Text, Pressable }
import from ..theme { s }
import from .UI { Chip }

"""The two resume scores (docs/RESUME_SCORING.md): job match and resume quality, before → after when tailoring."""
def:pub scoreLine(label: str, before: any, after: any) -> str {
    if after is None { return label+": not enough information"; }
    if before is None or before==after { return label+": "+str(after); }
    change=after-before;
    return label+": "+str(before)+" → "+str(after)+" ("+("+" if change>0 else "")+str(change)+")";
}

def:pub componentsLine(after: list[dict[str, any]], before: list[dict[str, any]]) -> list[str] {
    previous={c["key"]:c["score"] for c in before};
    return [c["label"]+" "+(str(previous[c["key"]])+" → " if c["key"] in previous and previous[c["key"]]!=c["score"] else "")+str(c["score"]) for c in after];
}

def:pub ScoreCard(after: dict[str, any], before: dict[str, any] = {}, title: str = "RESUME SCORE") -> JsxElement {
    has open: bool = False;
    missing=after.get("missing",[]);required=[m for m in missing if m.get("required")];
    requirements=after.get("requirements",{});years=requirements.get("years") or {};
    <View style={[s.mutedBox,{gap:8}]}>
        <Text style={s.label}>{title}</Text>
        <Text style={s.strong}>{scoreLine("Job match",before.get("match") if len(before)>0 else None,after.get("match"))}</Text>
        <Text style={s.strong}>{scoreLine("Resume quality",before.get("quality") if len(before)>0 else None,after.get("quality"))}</Text>
        {<Text style={s.small}>{"Missing required: "+", ".join([m["term"] for m in required[0:4]])}</Text> if len(required)>0 else <View/>}
        <Pressable accessibilityRole="button" accessibilityLabel={"Hide score details" if open else "Score details"} onPress={lambda { open=not open; }}>
            <Text style={[s.small,{color:"#3765E8",fontWeight:"700"}]}>{"Hide score details" if open else "Score details"}</Text>
        </Pressable>
        {<View style={{gap:8}}>
            <Text style={s.small}>{"Job match · "+" · ".join(componentsLine(after.get("match_components",[]),before.get("match_components",[]) if len(before)>0 else []))}</Text>
            <Text style={s.small}>{"Quality · "+" · ".join(componentsLine(after.get("quality_components",[]),before.get("quality_components",[]) if len(before)>0 else []))}</Text>
            {<Text style={s.small}>{"Missing from your resume (add only if true): "+", ".join([m["term"]+(" · in your facts" if m.get("supported") else "")+(" · required" if m.get("required") else "") for m in missing])}</Text> if len(missing)>0 else <Text style={s.small}>Every skill the listing names appears on your resume.</Text>}
            {<Text style={s.small}>{"Only on your skills line: "+", ".join(after["listed_only"])+". Show them in a bullet where your work used them."}</Text> if len(after.get("listed_only",[]))>0 else <View/>}
            {<Text style={s.small}>{"Listing phrases not on your resume: "+", ".join([k["term"] for k in after.get("keywords",[]) if not k["found"]])}</Text> if len([k for k in after.get("keywords",[]) if not k["found"]])>0 else <View/>}
            {<Text style={s.small}>{"Repeated too often: "+", ".join([x["term"]+" ×"+str(x["count"]) for x in after["stuffed"]])}</Text> if len(after.get("stuffed",[]))>0 else <View/>}
            {<Text style={s.small}>{"The listing asks for "+str(years["min"])+"+ years; Stack counts about "+str(requirements.get("resume_years",0))+" from your dates (internships count half)."}</Text> if years.get("min") else <View/>}
            {[<Text key={str(i)+x.get("id","")} style={s.small}>{"• "+x["where"]+": "+x["detail"]+" — “"+x["text"]+"”"}</Text> for (i,x) in enumerate(after.get("issues",[])[0:6])]}
            <Text style={s.small}>Stack's own weights, computed without AI. A guide to tailoring, not a prediction of hiring.</Text>
        </View> if open else <View/>}
    </View>
}
