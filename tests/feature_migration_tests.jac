"""Differential validation against the frozen feature commits, never live worktree files."""
import importlib;
import builtins;
import subprocess;
import from pathlib { Path }
import from types { ModuleType }
import from unittest.mock { patch }

def legacy(name: str, revision: str) -> any {
    source=subprocess.check_output(["git","show",revision+":agents/"+name+".py"],text=True);
    module=ModuleType("frozen_"+name);module.__file__=str(Path("agents/"+name+".py").resolve());
    builtins.exec(compile(source,module.__file__,"exec"),module.__dict__);return module;
}
def outcome(fn: any,args: list[any]) -> any {
    try { return {"value":fn(*args)}; }
    except Exception as e { return {"error":type(e).__name__,"message":str(e)}; }
}
def compare(name: str,fn: str,cases: list[list[any]],revision: str="816f9dd") -> None {
    before=getattr(legacy(name,revision),fn);after=getattr(importlib.import_module("agents."+name),fn);
    for args in cases { assert outcome(before,args)==outcome(after,args),name+"."+fn+": "+repr(args); }
}
test "new production modules resolve to Jac without Python duplicates or inline blocks" {
    for name in ["experience","latex","tailoring","resume_templates","parse_check","scoring","skills","linkedin","browser","browser_service","gateway","voice"] {
        path=Path(importlib.import_module("agents."+name).__file__ as str);
        assert path.suffix==".jac" and not path.with_suffix(".py").exists() and "::py::" not in path.read_text(),str(path);
    }
}
test "LaTeX escaping validation templates and structure retain frozen behavior" {
    compare("latex","escape",[[s] for s in ["A&B_#%$~^\\{}","", "José — résumé\nNext"]]);
    compare("latex","plain",[[s] for s in [r"\textbf{Built \& shipped}",r"\href{https://example.test}{Example}",r"50\% of users", ""]]);
    compare("latex","load",[["resume.tex",Path("tests/fixtures/jake-resume.tex").read_bytes()],["bad.exe",b"x"],["resume.tex",b"\\input{/etc/passwd}"]]);
    tex=Path("tests/fixtures/jake-resume.tex").read_text();source={"main":"resume.tex","files":{"resume.tex":tex}};
    compare("latex","parse",[[source]]);
    compare("resume_templates","body",[["jake",{"profile.name":"A & B","workExperiences.0.company":"ACME","workExperiences.0.descriptions":"Built tools."}],["bad",{}]]);
    compare("parse_check","expected_profile",[[tex]]);
}
test "scoring skills and LinkedIn validation retain deterministic output and errors" {
    compare("scoring","outline_from_parser",[[{}],[{"profile.name":"A","workExperiences.0.company":"Company","workExperiences.0.descriptions":"Built a SQL tool."}]]);
    compare("scoring","bullet_flaws",[[s] for s in ["Built a SQL tool that saved 10 hours.","Responsible for things","I am an excellent team player.",""]]);
    compare("scoring","score",[[[],{"title":"Engineer","description":"Requires Python and SQL"},[]]]);
    compare("skills","find",[[s] for s in ["Python, SQL and C++ on AWS","R and Go","", "communication and leadership"]]);
    compare("linkedin","profile_url",[[s] for s in ["https://linkedin.com/in/example/","bad","https://linkedin.com.evil.test/in/a/","https://www.linkedin.com/in/a/?trk=x"]],"f477c75");
    with patch("time.time",return_value=1234.0) { compare("linkedin","snapshot",[["https://www.linkedin.com/in/a/",{"intro":"Name. Engineer","about":"Built tools."}]],"f477c75"); }
}

test "conditional expressions preserve branch grouping in headings GPA and brevity" {
    compare("experience","context_label",[["network",{"contact":{"name":"A"}}],["network",{"contact":{"name":"A","company":"B"}}]]);
    compare("experience","review_summary",[["send",{"followup":True,"contact":{"name":"A"}},{"draft":{}}]]);
    compare("resume_templates","body",[["jake",{"educations.0.school":"University","educations.0.degree":"BS","educations.0.gpa":"3.8"}]]);
    outline=[{"id":"s0","title":"Experience","entries":[{"id":"s0.e0","heading":"","bullets":[{"id":"s0.e0.b0","text":"Did work"}],"lines":[]}]}];
    compare("scoring","resume_items",[[outline]]);
    compare("scoring","quality",[[outline],[outline,None,1],[outline,None,2]]);
    compare("tailoring","_where",[[{"sections":[{"id":"s0","title":"Skills"}],"entries":[]},"s0.l0"]]);
}
