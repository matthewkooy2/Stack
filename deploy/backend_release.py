"""Deterministic, source-only backend releases. Never read working-tree data.

The receiver uses this same reviewed module, installed root-owned independently
of any release. No package installers or release-supplied hooks run as root.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tomllib

VERSION = 1
MAX_BYTES = 64 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
SCRIPTS = {"scripts/agent-worker.jac", "scripts/discovery-worker.jac", "scripts/gateway-service.jac"}
GENERATED = ".jac/resume-parser.cjs"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def allowed(path):
    p = PurePosixPath(path)
    if str(p) != path or p.is_absolute() or any(x in (".", "..") for x in p.parts):
        return False
    if path in {"main.jac", "jac.toml", GENERATED} | SCRIPTS:
        return True
    if any(x.startswith(".") or x == "node_modules" for x in p.parts):
        return False
    if p.parts[0] in {"core", "agents"}:
        return p.suffix in {".jac", ".py", ".json", ".tex"}
    if p.parts[0] == "discovery":
        return p.suffix in {".py", ".json", ".csv"} and "credentials" not in p.name
    if path.startswith("integrations/resume-parser/"):
        return p.suffix in {".mjs", ".ts", ".json"}
    return False


def server_config(data):
    """Keep server/web configuration; mobile build fields belong to iPhone builds."""
    text = data.decode()
    keep = True
    lines = []
    for line in text.splitlines(keepends=True):
        if line.startswith("["):
            section = line.strip().strip("[]")
            keep = not (section == "client.react_native" or section.startswith("apps.mobile"))
        if keep:
            lines.append(line)
    return "".join(lines).encode()


def contract(config, parser_lock):
    parsed = tomllib.loads(config.decode())
    assert parsed["project"]["jac-version"] == "==0.37.21", "Unreviewed Jac version"
    return digest(canonical({"jac": "0.37.21", "dependencies": parsed["dependencies"],
                             "dev-dependencies": parsed.get("dev-dependencies", {}),
                             "database": parsed.get("database", {}),
                             "parser-lock": digest(parser_lock)}))


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def build(root, commit, parser, output):
    assert SHA.fullmatch(commit), "Require an exact 40-character commit SHA"
    assert git(root, "rev-parse", commit + "^{commit}").decode().strip() == commit
    names = git(root, "ls-tree", "-r", "--name-only", commit).decode().splitlines()
    blobs = {name: git(root, "show", commit + ":" + name) for name in names if allowed(name) and name != GENERATED}
    for name in blobs:
        mode = git(root, "ls-tree", commit, "--", name).split()[0]
        assert mode in (b"100644", b"100755"), "Source links are forbidden"
    # Generated parser must be built from a clean checkout of this exact commit.
    assert git(root, "rev-parse", "HEAD").decode().strip() == commit, "Parser checkout differs"
    assert not git(root, "status", "--porcelain", "--untracked-files=no"), "Tracked checkout is dirty"
    blobs["jac.toml"] = server_config(blobs["jac.toml"])
    blobs[GENERATED] = Path(parser).read_bytes()
    assert 0 < len(blobs[GENERATED]) < MAX_BYTES
    held = {name: digest(git(root, "show", commit + ":" + name)) for name in names if name.startswith("web/")}
    manifest = {"format": VERSION, "commit": commit,
                "runtime_contract": contract(blobs["jac.toml"], blobs["integrations/resume-parser/package-lock.json"]),
                "web_source": held, "files": {name: digest(data) for name, data in sorted(blobs.items())}}
    with Path(output).open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, data in [("manifest.json", canonical(manifest))] + [("payload/" + n, b) for n, b in sorted(blobs.items())]:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o640
                archive.addfile(info, io.BytesIO(data))
    artifact = Path(output).read_bytes()
    assert len(artifact) <= MAX_BYTES, "Artifact too large"
    return {"commit": commit, "sha256": digest(artifact), "bytes": len(artifact), "files": len(blobs)}


def validate(data, commit, expected_digest):
    assert SHA.fullmatch(commit) and DIGEST.fullmatch(expected_digest), "Invalid release identity"
    assert len(data) <= MAX_BYTES and digest(data) == expected_digest, "Artifact digest mismatch"
    files = {}
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive:
            assert member.isfile() and member.name not in files, "Links, directories and duplicates are forbidden"
            assert not member.pax_headers, "Extended archive paths are forbidden"
            assert member.name == "manifest.json" or (member.name.startswith("payload/") and allowed(member.name[8:])), "Forbidden archive path"
            assert 0 <= member.size <= MAX_BYTES
            total += member.size
            assert total <= MAX_BYTES, "Expanded artifact too large"
            files[member.name] = archive.extractfile(member).read()
    manifest = json.loads(files.pop("manifest.json"))
    assert manifest["format"] == VERSION and manifest["commit"] == commit, "Commit mismatch"
    assert DIGEST.fullmatch(manifest["runtime_contract"])
    payload = {name[8:]: value for name, value in files.items()}
    assert manifest["files"] == {name: digest(value) for name, value in payload.items()}, "Payload hash mismatch"
    assert {"main.jac", "jac.toml", GENERATED, "integrations/resume-parser/package-lock.json"} <= payload.keys()
    assert manifest["runtime_contract"] == contract(payload["jac.toml"], payload["integrations/resume-parser/package-lock.json"])
    assert isinstance(manifest["web_source"], dict) and manifest["web_source"]
    assert all(name.startswith("web/") and str(PurePosixPath(name)) == name and ".." not in PurePosixPath(name).parts
               and DIGEST.fullmatch(value) for name, value in manifest["web_source"].items())
    return manifest, payload


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--commit", required=True)
    p.add_argument("--parser", default=".jac/resume-parser.cjs")
    p.add_argument("--output", required=True)
    args = p.parse_args()
    print(json.dumps(build(Path.cwd(), args.commit, args.parser, args.output)))
