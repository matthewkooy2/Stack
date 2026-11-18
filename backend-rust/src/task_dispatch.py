"""Only the released deterministic worker stages run in this process."""
import json
import os
from pathlib import Path
import sys
import tempfile

root=Path(sys.argv[1]).resolve()
sys.path[:0]=[str(root),str(root/"score-docs")]
from agents.worker import dispatch

work=json.load(sys.stdin)
allowed={"browser_autofill","research","approve_resume","send","sync","calendar","execute"}
try:
    if work["step"] not in allowed or work["context"].get("manual_scan"):
        raise ValueError("This step requires another worker.")
    os.environ["STACK_WORKER_API"]="http://"+os.environ["STACK_PRIVATE_BIND"]
    with tempfile.TemporaryDirectory() as directory:
        os.chdir(directory)
        if work["step"]=="approve_resume":
            Path(".jac").mkdir()
            Path(".jac/tectonic-cache").symlink_to(root/"score-docs/tex-cache",target_is_directory=True)
            os.environ["STACK_TECTONIC"]=str(root/"score-docs/compile-tex")
        value=dispatch(work,os.environ["STACK_AGENT_WORKER_TOKEN"])
except ValueError as error:
    value={"error":str(error)}
except Exception:
    value={"error":"Task worker could not confirm the result."}
print(json.dumps(value))
