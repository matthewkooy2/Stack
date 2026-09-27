import from "@jac/mobui" { View, Text }
import from ..theme { s }
import from .UI { Field, Chip }

"""Add or remove one choice from a multi-select list."""
def:pub toggled(items: list[str], item: str) -> list[str] {
    return [x for x in items if x!=item] if item in items else items+[item];
}
"""Matching inputs shared by onboarding and profile editing. The server validates every value."""
def:pub MatchInputs(value: dict[str, any], onChange: any) -> JsxElement {
    def put(key: str, item: any) -> None {
        # A dict literal with a variable key compiles to a literal "key" property in the client; assign on a copy instead.
        updated={**value};updated[key]=item;onChange(updated);
    }
    <View style={{gap:14}}>
        <Text style={s.label}>Career stage</Text>
        <View style={s.wrap}>{[<Chip key={v} label={v} active={value["stage"]==v} onPress={lambda { put("stage","" if value["stage"]==v else v); }}/> for v in ["Student","Recent graduate","Early career","Experienced","Career changer"]]}</View>
        <Field label="Years of experience in this field" value={value["years"]} onChange={lambda (v: str) { put("years",v); }} placeholder="For example, 2"/>
        <Text style={s.label}>Education, completed or in progress</Text>
        <View style={s.wrap}>{[<Chip key={v} label={v} active={value["education"]==v} onPress={lambda { put("education","" if value["education"]==v else v); }}/> for v in ["High school","Associate","Bachelor's","Master's","Doctorate"]]}</View>
        <Text style={s.label}>Open to</Text>
        <View style={s.wrap}>{[<Chip key={v} label={v} active={v in value["modes"]} onPress={lambda { put("modes",toggled(value["modes"],v)); }}/> for v in ["Remote","Hybrid","On-site"]]}</View>
        <Text style={s.small}>Leave all off for any work arrangement.</Text>
        <Text style={s.label}>Employment type</Text>
        <View style={s.wrap}>{[<Chip key={v} label={v} active={v in value["employment_types"]} onPress={lambda { put("employment_types",toggled(value["employment_types"],v)); }}/> for v in ["Full-time","Part-time","Contract","Temporary","Internship"]]}</View>
        <Field label="Minimum pay (USD)" value={value["salary_min"]} onChange={lambda (v: str) { put("salary_min",v); }} placeholder="Optional"/>
        <View style={s.wrap}>{[<Chip key={v} label={"per "+v} active={value["salary_period"]==v} onPress={lambda { put("salary_period",v); }}/> for v in ["hour","year"]]}</View>
        <Field label="Hide these employers" value={value["exclude_companies"]} onChange={lambda (v: str) { put("exclude_companies",v); }} placeholder="Separate with commas"/>
        <Field label="Hide jobs mentioning" value={value["exclude_terms"]} onChange={lambda (v: str) { put("exclude_terms",v); }} placeholder="Separate with commas"/>
        <Text style={s.label}>Nice to have, not required</Text>
        <View style={s.wrap}>{[<Chip key={o["key"]} label={o["label"]} active={o["key"] in value["soft"]} onPress={lambda { put("soft",toggled(value["soft"],o["key"])); }}/> for o in [{"key":"location","label":"Location"},{"key":"modes","label":"Work arrangement"},{"key":"employment_types","label":"Employment type"},{"key":"salary","label":"Pay"},{"key":"level","label":"Level"},{"key":"experience","label":"Experience"},{"key":"education","label":"Education"}]]}</View>
        <Text style={s.small}>Jobs that conflict with a requirement are hidden. Nice-to-haves only change the order. When a listing doesn’t say, the job stays visible and is marked unconfirmed.</Text>
    </View>
}
