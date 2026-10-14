"""Generate the native decode resource through the shared real parser contract.

Before parser integration, CI supplies its pinned source checkout. After integration,
the same producer in this repository is used. No network, database or packages needed.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
PRODUCER = Path("tests/fixtures/resume_contract.py")
RESOURCE = ROOT / "ios/StackTests/Fixtures/resume-review-contract.json"


def generate(source, expected_digest):
    environment = dict(os.environ, PYTHONPATH=str(source))
    result = subprocess.run(
        [sys.executable, str(source / PRODUCER)], cwd=source,
        env=environment, capture_output=True, check=True,
    )
    digest = hashlib.sha256(result.stdout).hexdigest()
    if digest != expected_digest:
        raise ValueError(f"Shared resume contract changed: expected {expected_digest}, got {digest}")
    json.loads(result.stdout)
    return result.stdout


def main():
    # Fail closed even if checkout validation fails.
    RESOURCE.unlink(missing_ok=True)
    contract = json.loads(Path(__file__).with_name("contract.json").read_text())
    source = ROOT
    if not (source / PRODUCER).is_file():
        source = Path(os.environ.get("STACK_RESUME_CONTRACT_SOURCE", str(ROOT / ".jac/resume-contract-source"))).resolve()
        revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        if revision != contract["parser_ref"]:
            raise ValueError(f"Paired parser revision mismatch: {revision}")
        if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"]):
            raise ValueError("Paired parser checkout has tracked changes")
    content = generate(source, contract["canonical_sha256"])
    RESOURCE.parent.mkdir(parents=True, exist_ok=True)
    RESOURCE.write_bytes(content)
    print(f"Prepared shared native contract: {len(content)} bytes, SHA256 {contract['canonical_sha256']}")


if __name__ == "__main__":
    main()
