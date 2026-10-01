#!/usr/bin/python3
"""Unprivileged forced SSH command. Only accepts a bounded artifact stream."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from backend_release import MAX_BYTES, digest, validate


def main():
    command = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    match = re.fullmatch(r"stack-release ([0-9a-f]{40}) ([0-9a-f]{64})", command)
    assert match, "Unsupported SSH command"
    commit, sha = match.groups()
    data = sys.stdin.buffer.read(MAX_BYTES + 1)
    validate(data, commit, sha)
    incoming = Path("/var/lib/stack-release/incoming") / (sha + ".tar.gz")
    # Never overwrite a pending artifact. An identical retry is safe.
    try:
        fd = os.open(incoming, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        fd = os.open(incoming, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            assert digest(stream.read(MAX_BYTES + 1)) == sha
    else:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    subprocess.run(["sudo", "-n", "/usr/local/libexec/stack-release/promote-backend"],
                   input=json.dumps({"commit": commit, "sha256": sha}).encode(), check=True, timeout=1200)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Release rejected; review host approval and private host diagnostics.", file=sys.stderr)
        sys.exit(1)
