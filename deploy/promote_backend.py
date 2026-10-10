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
import browser_release

LIVE = Path("/opt/stack")
STATE = Path("/var/lib/stack-release")
SERVICES = ("stack-gateway.service", "stack-worker.service", "stack-api.service")


def deployment_services():
    # Preserve the operator's activation choice. Never activate an absent or
    # disabled collector as a side effect of publishing application code.
    state = subprocess.run(["systemctl", "is-enabled", "stack-discovery.service"],
                           capture_output=True, text=True, timeout=30)
    return (("stack-discovery.service",) + SERVICES
            if state.returncode == 0 and state.stdout.strip() == "enabled" else SERVICES)


def run(args, cwd=None):
    # Do not send dependency/service logs containing private host values to CI.
    result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    if result.returncode:
        raise RuntimeError("Host command failed: " + Path(args[0]).name)
    return result.stdout


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
        parent.chmod(0o750)
    temp = path.with_name(path.name + ".release-new")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
        os.fchown(stream.fileno(), 0, group)
        # The privileged entry point uses umask 077. Set the final mode
        # explicitly so stack can read source installed for its group.
        os.fchmod(stream.fileno(), 0o640)
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
        browser = manifest.get("browser")
        browser_enabled = authorization.get("automatic_browser_deploy") is True
        assert not browser_enabled or browser is not None, "Browser-enabled host requires a coordinated release"
        assert browser is None or browser_enabled, "Automatic browser deployment is not approved"
        backend = {name: value for name, value in payload.items() if not name.startswith("browser/")}
        policy_path = STATE / "source-state.json"
        policy = json.loads(root_file(policy_path))
        assert source_state(policy) == policy, "Intervening local source changes require review"
        assert set(policy) <= set(backend), "Source deletion requires review"
        assert not any(target(name).exists() for name in set(backend) - set(policy)), "New source paths already exist locally; review required"
        stack = pwd.getpwnam("stack")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = Path("/var/backups/stack") / ("source-release-" + stamp)
        backup.mkdir(mode=0o700)
        # Browser preparation still runs as the unprivileged stack account.
        stage = STATE / "build" / stamp
        stage.mkdir(mode=0o750)
        os.chown(stage, stack.pw_uid, stack.pw_gid)
        browser_plan = browser_release.prepare(browser, payload, stage, manifest["commit"], run, root_file) if browser else None
        for name in backend:
            path = target(name)
            if path.exists():
                copy = backup / "source" / name
                copy.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, copy)
        (backup / "source-state.json").write_bytes(canonical(policy))
        # No readiness/test gates or automatic rollback: command failures surface.
        # A private source backup remains available for an attended correction.
        services = deployment_services()
        for service in services:
            run(["systemctl", "stop", service])
        if browser_plan and browser_plan["changed"]:
            run(["systemctl", "stop", "stack-browser.service"])
        for name, value in backend.items():
            write_atomic(target(name), value, stack.pw_gid)
        run(["runuser", "-u", "stack", "--", "env", "STACK_JAC_BIN=/usr/local/bin/jac",
             "/opt/stack/scripts/jac", "install", "--no-npm"], cwd=LIVE)
        write_atomic(policy_path, canonical(manifest["files"]), 0)
        policy_path.chmod(0o600)
        if browser_plan:
            browser_release.promote(browser_plan, backup, write_atomic)
            if browser_plan["changed"]:
                run(["systemctl", "start", "stack-browser.service"])
        for service in reversed(services):
            run(["systemctl", "start", service])
        result = {"status": "restart_commands_completed", "commit": manifest["commit"], "sha256": sha,
                  "source_backup": str(backup), "health_checks_run": False}
        if browser_plan:
            result.update(browser_image=browser_plan["image"], browser_rebuilt=browser_plan["changed"],
                          browser_source=browser["fingerprint"])
        write_atomic(STATE / "last-release.json", canonical(result), 0)
        (STATE / "last-release.json").chmod(0o600)
        print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"status": "failed", "error": str(error) if isinstance(error, (AssertionError, RuntimeError)) else type(error).__name__}))
        sys.exit(1)
