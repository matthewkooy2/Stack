import from agents { latex, resume_templates }
import from pathlib { Path }
with entry:__main__ {
    for name in resume_templates.TEMPLATES { latex.compile(resume_templates.fill(name, {"profile.name": "Stack"})); }
    latex.compile(latex.load("resume.tex", Path("tests/fixtures/jake-resume.tex").read_bytes()));
}
