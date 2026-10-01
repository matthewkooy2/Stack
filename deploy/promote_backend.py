"""Fixed privileged entry point for approved automatic backend deployments.

Install root-owned, separately from application releases. No CLI arguments.
Only this helper receives sudo permission; package tools run as stack.
Application data/config/browser runtime and Tailscale are never replaced.
"""
import datetime
import fcntl
import json
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import sys
from backend_release import MAX_BYTES, canonical, digest, validate

LIVE = Path("/opt/stack")
STATE = Path("/var/lib/stack-release")
SERVICES = ("stack-gateway.service", "stack-worker.service", "stack-api.service")


def run(args, cwd=None):
    # Do not send dependency/service logs containing private host values to CI.
    result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    if result.returncode:
        raise RuntimeError("Host command failed: " + Path(args[0]).name)


def root_file(path):
    st = path.lstat()
    assert stat.S_ISREG(st.st_mode) and st.st_uid == 0 and not st.st_mode & 0o022, "Untrusted host configuration"
    return path.read_bytes()


def target(name):
    path = LIVE / name
    assert not path.is_symlink(), "Linked live file"
    parent = path.parent
    while parent != LIVE.parent:
        assert not parent.is_symlink(), "Linked live directory"
        parent = parent.parent
    return path


def source_state(names):
    return {n: digest(target(n).read_bytes()) if target(n).is_file() else None for n in names}


def write_atomic(path, data, group):
    missing = []
    parent = path.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    for parent in reversed(missing):
        parent.mkdir(mode=0o750)
        os.chown(parent, 0, group)
    temp = path.with_name(path.name + ".release-new")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
        os.fchown(stream.fileno(), 0, group)
    os.replace(temp, path)


def main():
    assert os.geteuid() == 0 and len(sys.argv) == 1, "Fixed privileged entry point only"
    os.umask(0o077)
    # Parent directories are root-owned; only incoming/ and build workspaces
    # grant the relevant unprivileged account write access.
    st = STATE.lstat()
    assert stat.S_ISDIR(st.st_mode) and st.st_uid == 0 and not st.st_mode & 0o022
    with (STATE / "deploy.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        request = json.loads(sys.stdin.buffer.read(1025))
        authorization = json.loads(root_file(Path("/etc/stack-release/access.json")))
        assert authorization.get("automatic_main_deploy") is True, "Automatic deployment is not approved"
        assert set(request) == {"commit", "sha256"}
        # Exact identity is also enforced by validate before any live writes.
        sha = request["sha256"]
        assert isinstance(sha, str) and len(sha) == 64 and all(x in "0123456789abcdef" for x in sha)
        incoming = STATE / "incoming" / (sha + ".tar.gz")
        fd = os.open(incoming, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            st = os.fstat(stream.fileno())
            assert stat.S_ISREG(st.st_mode) and st.st_size <= MAX_BYTES
            data = stream.read(MAX_BYTES + 1)
        manifest, payload = validate(data, request["commit"], sha)
        policy_path = STATE / "source-state.json"
        policy = json.loads(root_file(policy_path))
        assert source_state(policy) == policy, "Intervening local source changes require review"
        assert set(policy) <= set(payload), "Source deletion requires review"
        stack = pwd.getpwnam("stack")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = Path("/var/backups/stack") / ("source-release-" + stamp)
        backup.mkdir(mode=0o700)
        # Prepare Node dependencies as stack in a new directory before touching
        # services. Existing node_modules remain intact until preparation succeeds.
        stage = STATE / "build" / stamp
        stage.mkdir(mode=0o750)
        os.chown(stage, stack.pw_uid, stack.pw_gid)
        for name in ("package.json", "package-lock.json"):
            p = stage / name
            p.write_bytes(payload["integrations/resume-parser/" + name])
            os.chown(p, stack.pw_uid, stack.pw_gid)
            p.chmod(0o640)
        run(["runuser", "-u", "stack", "--", "npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=stage)
        for name in payload:
            path = target(name)
            if path.exists():
                copy = backup / "source" / name
                copy.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, copy)
        (backup / "source-state.json").write_bytes(canonical(policy))
        # No readiness/test gates or automatic rollback: command failures surface.
        # A private source backup remains available for an attended correction.
        for service in SERVICES:
            run(["systemctl", "stop", service])
        for name, value in payload.items():
            write_atomic(target(name), value, stack.pw_gid)
        nodes = target("integrations/resume-parser/node_modules")
        if nodes.exists():
            os.replace(nodes, backup / "parser-node-modules")
        os.replace(stage / "node_modules", nodes)
        run(["runuser", "-u", "stack", "--", "/opt/stack/scripts/jac", "install", "--no-npm"], cwd=LIVE)
        write_atomic(policy_path, canonical(manifest["files"]), 0)
        policy_path.chmod(0o600)
        for service in reversed(SERVICES):
            run(["systemctl", "start", service])
        print(json.dumps({"status": "restart_commands_completed", "commit": manifest["commit"], "sha256": sha,
                          "source_backup": str(backup), "health_checks_run": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"status": "failed", "error": str(error) if isinstance(error, (AssertionError, RuntimeError)) else type(error).__name__}))
        sys.exit(1)
