"""Read-only attended preparation: write a review baseline, never activate it.

Reads selected public files from the existing read-only browser container and
hashes protected host files locally. No credentials, service changes or builds.
"""
import argparse
import io
import json
from pathlib import Path
import subprocess
import tarfile

from backend_release import canonical, digest, validate
from browser_release import IMAGE_ID, PROTECTED, docker_config, isolation
from promote_backend import root_file


def run(args):
    p = subprocess.run(args, capture_output=True, timeout=30)
    assert p.returncode == 0, "Read-only Docker inspection failed"
    return p.stdout


def public_file(name):
    data = run(["/usr/bin/docker", "cp", "stack-browser-pc:" + name, "-"])
    assert len(data) < 4 * 1024 * 1024
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        members = list(archive)
        assert len(members) == 1 and members[0].isfile(), "Unexpected image source file"
        return archive.extractfile(members[0]).read()


def prepare(artifact, commit, sha, output):
    assert not output.exists(), "Existing review documents are preserved"
    manifest, payload = validate(artifact.read_bytes(), commit, sha)
    meta = manifest["browser"]
    image = root_file(Path("/etc/stack/browser-image-id")).decode().strip()
    assert IMAGE_ID.fullmatch(image)
    docker_config(image, run)
    container = json.loads(run(["/usr/bin/docker", "container", "inspect", "stack-browser-pc"]))[0]
    assert container["Image"] == image and container["Config"]["User"] == "pwuser"
    host = container["HostConfig"]
    assert host["ReadonlyRootfs"] and not host["Privileged"] and not container["Mounts"]
    isolation(container)
    assert all(digest(public_file("/app/" + n)) == h for n, h in meta["files"].items()), "Existing browser source differs from reviewed release"
    assert public_file("/app/jac.toml") == payload["browser/contract/deploy/browser.jac.toml"]
    for name in ("deploy/browser-entrypoint", "deploy/install-browser.jac"):
        assert public_file("/app/" + name) == payload["browser/contract/" + name]
    actual = public_file("/app/deploy/browser.Dockerfile")
    first, rest = actual.split(b"\n", 1)
    assert first.startswith(b"FROM python@sha256:") and len(first) == len(b"FROM python@sha256:") + 64
    assert b"FROM python:3.12.11-slim-bookworm\n" + rest == payload["browser/contract/deploy/browser.Dockerfile"]
    assert digest(root_file(Path("/etc/stack/browser-seccomp.json"))) == meta["contract"]["deploy/browser-seccomp.json"]
    state = {"format": 1, "base_image": image, "image": image, "files": meta["files"],
             "contract": meta["contract"], "fingerprint": meta["fingerprint"], "source_commit": commit,
             "protected": {p: digest(root_file(Path(p))) for p in PROTECTED},
             "isolation": isolation(container)}
    output.write_bytes(canonical(state))
    output.chmod(0o600)
    print(json.dumps({"review_file_created": True, "image": image, "source_files": len(meta["files"]),
                      "live_settings_changed": False, "builds_or_restarts_run": False}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.artifact, args.commit, args.sha256, args.output)
