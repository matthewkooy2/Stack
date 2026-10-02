"""Attended setup only: write baseline hashes to a requested review file.

Does not install helpers, grant access or change live source/services.
The operator must review the file and install it root-owned after approval.
"""
import argparse
import json
from pathlib import Path
from backend_release import canonical, digest, validate

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--artifact", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--sha256", required=True)
    p.add_argument("--live", default="/opt/stack")
    p.add_argument("--output", required=True)
    args = p.parse_args()
    manifest, payload = validate(Path(args.artifact).read_bytes(), args.commit, args.sha256)
    live = Path(args.live)
    state = {name: digest((live / name).read_bytes()) if (live / name).is_file() else None for name in manifest["files"]}
    Path(args.output).write_bytes(canonical(state))
    print(json.dumps({"status": "review_file_created", "files": len(state), "live_changes": False}))
