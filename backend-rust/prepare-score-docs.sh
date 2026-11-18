#!/usr/bin/env bash
# Build from the Stack checkout on the same Linux architecture and Python minor as dev.
set -euo pipefail
stage=$(realpath "${1:?provide a release staging directory}")
root=$(pwd)
[[ -f jac.toml && -d "$stage" ]]
[[ $(jac --version) == "jac 0.37.21 "* ]]
scratch=$(mktemp -d)
trap 'rm -r -- "$scratch"' EXIT
mkdir -p "$stage/agents/data" "$stage/score-docs" "$scratch/agents"
cp agents/{__init__,record_resume,pdf_safety,template_library,bullet_bank,memory_bank,mail_scan,apple_auth,request_trace,interview,memory_access,resume_details,browser_control,memory_tailoring,linkedin_pdf}.py "$stage/agents/"
cp -r agents/resume_parser "$stage/agents/"
cp agents/data/{skills,skill_aliases}.json "$stage/agents/data/"
mkdir -p "$stage/agents/templates"
cp -r agents/templates/. "$stage/agents/templates/"
# No checked-in duplicate scorers and no Jac dependency on the serving VM.
cp agents/staging_openai.py "$stage/agents/"
cp agents/data/practice_questions.json "$stage/agents/data/"
for module in linkedin practice provider skills scoring job_score latex resume_templates security google notifications contracts experience tracing local_model coaching worker research tailoring; do
    cp "agents/$module.jac" "$scratch/agents/"
    (cd "$scratch" && jac tool jac2py "agents/$module.jac") > "$stage/agents/$module.py"
done
python3 - "$scratch/render.lock" <<'PY'
import re,sys
from pathlib import Path
text = Path('dependencies/python.lock').read_text()
wanted = {'reportlab','pypdf','pillow','charset-normalizer','cryptography','cffi','pycparser',
          'google-auth','cachetools','pyasn1','pyasn1_modules','rsa'}
entries = re.findall(r'^(\S+?)==[^\n]+(?:\n    --hash=[^\n]+)+', text, re.M)
lines = re.findall(r'^\S+?==[^\n]+(?:\n    --hash=[^\n]+)+', text, re.M)
assert wanted <= set(entries)
Path(sys.argv[1]).write_text('\n'.join(x for x in lines if x.split('==')[0] in wanted)+'\n')
PY
uv pip install --python /usr/bin/python3 --only-binary :all: --require-hashes --no-deps \
    --target "$stage/score-docs" -r "$scratch/render.lock"
# Verify the repository-pinned archive before extracting its one executable.
python3 - "$stage/score-docs/tectonic" <<'PY'
import os,sys,tarfile,shutil
from pathlib import Path
sys.path.insert(0,'scripts')
from bootstrap import DIGESTS, TECTONIC_VERSION, architecture, download
arch=architecture()
name=f'tectonic-{TECTONIC_VERSION}-{arch}-unknown-linux-musl.tar.gz'
cache=Path(os.environ.get('XDG_CACHE_HOME',Path.home()/'.cache'))/'stack-rust-render'
url=f'https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%40{TECTONIC_VERSION}/{name}'
archive=download(url,cache/name,DIGESTS[arch]['tectonic'])
with tarfile.open(archive) as tar:
    member, = [m for m in tar if m.isfile() and Path(m.name).name=='tectonic']
    with tar.extractfile(member) as src, open(sys.argv[1],'wb') as dst:
        shutil.copyfileobj(src,dst)
os.chmod(sys.argv[1],0o755)
PY
cat > "$stage/score-docs/compile-tex" <<'SH'
#!/bin/sh
# The caller supplies -X compile followed by the audited template arguments.
shift 2
# DynamicUser services have no usable home. The caller already isolates each compile.
export HOME="$(pwd -P)"
export XDG_CONFIG_HOME="$HOME/.tectonic-config"
exec "$(dirname "$0")/tectonic" -X compile --only-cached "$@"
SH
chmod +x "$stage/score-docs/compile-tex"
# Warm public TeX package caches with a fixed synthetic fixture. Production records
# never enter the package. Subsequent builds reuse this versioned cache.
work="${XDG_CACHE_HOME:-$HOME/.cache}/stack-rust-render/v33"
mkdir -p "$work"
(
    flock 9
    cd "$work"
    STACK_TECTONIC="$stage/score-docs/tectonic" python3 -I - "$stage" "$root" <<'PY'
import json, sys
from pathlib import Path
stage, root = map(Path,sys.argv[1:3])
sys.path[:0]=[str(stage),str(stage/'score-docs')]
from agents.record_resume import documents
from agents.template_library import LATEX_RECORD_TEMPLATES
records=json.loads((root/'tests/fixtures/record-resume.json').read_text())
for design in sorted(LATEX_RECORD_TEMPLATES):
    documents(records, design)
from agents import latex,resume_templates
for design in resume_templates.TEMPLATES:
    latex.compile(resume_templates.fill(design, {"profile.name":"Synthetic Candidate","experience.0.company":"Fixture Corp","experience.0.role":"Engineer"}))
source = latex.load("resume.tex", (root/"tests/fixtures/jake-resume.tex").read_bytes())
latex.compile(source)
PY
    packages="$work/.jac/tectonic-cache"
    bundle="$packages/bundles/hashes/https,58,,47,,47,relay.fullyjustified.net,47,default_bundle_v33.tar"
    [[ $(cat "$bundle") == 6ffe055852f8faf66c0acbe1a7fb27f87b869a90bad1204f3bf4d9683f597c7c ]]
    mkdir -p "$stage/score-docs/tex-cache"
    cp -r "$packages/bundles" "$packages/formats" "$stage/score-docs/tex-cache/"
    chmod -R a+rX "$stage/score-docs/tex-cache"
) 9>"$work/build.lock"
