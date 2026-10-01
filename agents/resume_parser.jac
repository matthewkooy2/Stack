"""Local OpenResume boundary and review representation. No model or network calls."""
import json;
import re;
import shutil;
import subprocess;
import from pathlib { Path }

glob FIELDS = {
    "profile": {"name":"Name","email":"Email","phone":"Phone","location":"Location","url":"Link","summary":"Summary"},
    "educations": {"school":"School","degree":"Degree","gpa":"GPA","date":"Date","descriptions":"Descriptions"},
    "workExperiences": {"company":"Company","jobTitle":"Job title","date":"Date","descriptions":"Descriptions"},
    "projects": {"project":"Project","date":"Date","descriptions":"Descriptions"},
    "skills": {"descriptions":"Skills"}, "additional": {"descriptions":"Other details"}
};
glob LABELS = {"profile":"Profile","educations":"Education","workExperiences":"Work experience","projects":"Projects","skills":"Skills","additional":"Additional details"};
glob REPEATED = ["educations","workExperiences","projects"];

def parse_pdf(path: Path) -> dict[str, any] {
    executable=shutil.which("node") or ("/opt/homebrew/bin/node" if Path("/opt/homebrew/bin/node").exists() else "");
    if not executable or not Path(".jac/resume-parser.cjs").exists() { raise ValueError("The resume parser needs setup on your Mac. Run npm --prefix integrations/resume-parser ci, then npm --prefix integrations/resume-parser run build."); }
    try {
        result=subprocess.run([executable,"--max-old-space-size=256","integrations/resume-parser/run.mjs"],input=path.read_bytes(),capture_output=True,timeout=20);
        parsed=json.loads(result.stdout);
    } except subprocess.TimeoutExpired { raise ValueError("Parsing timed out. Try a simpler, text-based PDF.") from None; }
    except Exception { raise ValueError("The local resume parser could not read this PDF.") from None; }
    if result.returncode or parsed.get("error") { raise ValueError(str(parsed.get("error","The resume parser could not finish."))[:500]); }
    values={};resume=parsed["resume"];
    for (section,fields) in FIELDS.items() {
        records=resume.get(section,[]) if section in REPEATED else [resume.get(section,{})];
        if len(records)>20 { raise ValueError("The parser found more than 20 entries in a section. Review a shorter resume."); }
        for (index,record) in enumerate(records or [{}]) {
            prefix=section+"."+str(index) if section in REPEATED else section;
            for field in fields {
                value=record.get(field,"");
                if isinstance(value,list) { value="\n".join(value); }
                if section=="skills" {
                    featured=[s["skill"] for s in record.get("featuredSkills",[]) if s.get("skill")];
                    value="\n".join(featured+[value]) if featured else value;
                }
                values[prefix+"."+field]=str(value).strip();
            }
        }
    }
    return {"values":validate_values(values),"text":parsed["text"],"parser":"OpenResume 4f8255a"};
}

def validate_values(values: dict[str, any]) -> dict[str, str] {
    if not isinstance(values,dict) or len(values)>270 { raise ValueError("Too many resume fields."); }
    result={};
    for (key,value) in values.items() {
        parts=key.split(".");section=parts[0];field=parts[-1];
        valid=section in FIELDS and field in FIELDS[section];
        if section in REPEATED { valid=valid and len(parts)==3 and bool(re.fullmatch(r"[0-9]|1[0-9]",parts[1])); }
        else { valid=valid and len(parts)==2; }
        if not valid or not isinstance(value,str) or len(value)>8000 { raise ValueError("Resume fields must be recognized and contain at most 8,000 characters."); }
        result[key]=value.strip();
    }
    if sum(len(v) for v in result.values())>100000 { raise ValueError("Resume details exceed 100,000 characters."); }
    return result;
}

def sections(values: dict[str, str]) -> list[dict[str, any]] {
    result=[];
    for (section,fields) in FIELDS.items() {
        indexes=sorted({int(k.split(".")[1]) for k in values if k.startswith(section+".")}) if section in REPEATED else [0];
        for index in indexes or [0] {
            prefix=section+"."+str(index) if section in REPEATED else section;
            rows=[{"key":prefix+"."+field,"label":label,"value":values.get(prefix+"."+field,"")} for (field,label) in fields.items()];
            populated=[row["value"].split("\n")[0] for row in rows if row["value"]];
            result.append({"key":prefix,"label":LABELS[section]+(" "+str(index+1) if section in REPEATED and len(indexes)>1 else ""),"summary":populated[0][:90] if populated else "Not found","fields":rows});
        }
    }
    return result;
}

def confirmed_facts(id: str, name: str, values: dict[str, str]) -> list[dict[str, any]] {
    # Keep each entry together, so later agents cannot mix employers or schools.
    return [{"key":"resume."+id+"."+section["key"],"resume_id":id,"source":name,"verified":True,
        "value":"\n".join([field["label"]+": "+field["value"] for field in section["fields"] if field["value"]])}
        for section in sections(values) if `any(field["value"] for field in section["fields"])];
}
