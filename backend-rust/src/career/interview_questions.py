"""Build deterministic interview questions using the existing reviewed evidence rules."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))

from agents import interview
from agents.memory_access import collect, interview_facts

request = json.load(sys.stdin)
op=request.get("op","create")
if op=="context":
    data=request["data"]
    index=request.get("index")
    if index is None:
        index=interview.target(data)
    print(json.dumps(interview.context(data,request["revision"],request["final"],index)))
    sys.exit()
if op=="client":
    print(json.dumps(interview.client_data(request["data"])))
    sys.exit()
if op=="followup":
    print(json.dumps(interview.followup(request["analysis"],request["data"])))
    sys.exit()
resume_id = request["resume_id"]
resumes = request["resumes"]
facts = request["facts"]
selected = next((r for r in resumes if r["id"] == resume_id and r["confirmed"]), {})
memory = interview_facts(
    collect(request["owner"], resumes, facts, []), request["job"], skip=("resume:" + resume_id,)
)
try:
    data = interview.create(
        request["job"], facts, request["application_id"], resume_id, selected.get("records", []), memory["facts"]
    )
    data["client_id"] = request["client_id"]
    data["memory_coverage"] = memory["coverage"]
except ValueError as exc:
    data = {"error": str(exc)}
json.dump(data, sys.stdout)
