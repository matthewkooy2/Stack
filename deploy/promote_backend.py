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
import shlex
import subprocess
import sys
from backend_release import MAX_BYTES, canonical, digest, validate
from backend_release import contract
from release_safety import Held, compatibility, transaction, wait_ready
from release_probe import Probe
import browser_release

LIVE = Path("/opt/stack")
STATE = Path("/var/lib/stack-release")
SERVICES = ("stack-gateway.service", "stack-worker.service", "stack-api.service")


def run(args, cwd=None, timeout=None):
    # Do not send dependency/service logs containing private host values to CI.
    timeout = timeout or (180 if 'build' in args else 30)
    result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
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
    import secrets
    temp = path.with_name(path.name + ".release-" + secrets.token_hex(8))
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


def secret_env(path):
    values = {}
    for line in root_file(path).decode().splitlines():
        if not line or line.startswith('#'):
            continue
        key, value = line.split('=', 1)
        parts = shlex.split(value)
        assert len(parts) <= 1, 'Unsupported environment format'
        values[key] = parts[0] if parts else ''
    return values


def service_stop(services):
    # Confirmation matters: stop-command success alone is insufficient.
    for service in services:
        run(['systemctl', 'stop', service])
    for service in services:
        state = run(['systemctl', 'show', '--property=ActiveState', '--value', service]).decode().strip()
        assert state in ('inactive', 'failed'), 'Writers are not quiescent'


def service_start(services):
    for service in reversed(services):
        run(['systemctl', 'start', service])


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
        # Fail closed until an attended bootstrap establishes a healthy prior
        # supporting the release-smoke protocol. Old restart-only receipts do not.
        prior = json.loads(root_file(STATE / 'last-release.json'))
        assert prior.get('status') == 'healthy' and prior.get('probe_protocol') == 1, 'Healthy baseline bootstrap required'
        identity = root_file(LIVE / '.release-identity.json')
        assert json.loads(identity)['commit'] == prior['commit'], 'Baseline identity mismatch'
        if (STATE / 'transaction.json').exists():
            previous = json.loads(root_file(STATE / 'transaction.json'))
            assert (previous['status'] == 'healthy' or
                    previous['status'] == 'failed' and previous.get('recovery') == 'healthy'), 'Unresolved transaction requires operator recovery'
        approval = json.loads(root_file(Path('/etc/stack-release/compatibility.json')))
        compatibility(approval, prior['commit'], manifest['commit'], sha, manifest['runtime_contract'])
        assert contract(target('jac.toml').read_bytes()) == manifest['runtime_contract'], 'Runtime change requires attended review'
        # Trusted operator review binds the exact pair and data/schema behavior;
        # runtime/config snapshots are hashes only, never CI diagnostic output.
        protected = approval.get('protected_files', {})
        required = {'/etc/stack/api.env', '/etc/stack/worker.env',
                    '/etc/systemd/system/stack-api.service', '/etc/systemd/system/stack-worker.service',
                    '/etc/systemd/system/stack-gateway.service', '/opt/stack/scripts/jac', '/usr/local/bin/jac'}
        assert required <= set(protected), 'Runtime/config inventory required'
        assert all(digest(root_file(Path(p))) == h for p, h in protected.items()), 'Runtime/config changed since compatibility review'
        worker_env = secret_env(Path('/etc/stack/worker.env'))
        worker_token = worker_env.get('STACK_AGENT_WORKER_TOKEN', '')
        assert worker_token, 'Explicit worker credential required for readiness'
        browser_token = secret_env(Path('/etc/stack/browser.env')).get('STACK_BROWSER_TOKEN', '') if browser else ''
        assert not browser or browser_token, 'Browser readiness credential required'
        stack = pwd.getpwnam("stack")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = Path("/var/backups/stack") / ("source-release-" + stamp)
        backup.mkdir(mode=0o700)
        # Browser preparation still runs as the unprivileged stack account.
        stage = STATE / "build" / stamp
        stage.mkdir(mode=0o750)
        os.chown(stage, stack.pw_uid, stack.pw_gid)
        browser_plan = browser_release.prepare(browser, payload, stage, manifest["commit"], run, root_file) if browser else None
        if browser_plan:
            for name, value in browser_plan['state']['protected'].items():
                assert name not in protected or protected[name] == value, 'Conflicting protected runtime inventory'
                protected[name] = value
        def browser_check(timeout):
            expected = json.loads(root_file(browser_release.BROWSER_STATE))
            actual = json.loads(run(['/usr/bin/docker', 'container', 'inspect', 'stack-browser-pc'], timeout=timeout))[0]
            assert actual['Image'] == expected['image'], 'Serving browser image mismatch'
            assert browser_release.isolation(actual) == expected['isolation'], 'Browser isolation changed'
        probe = Probe(LIVE, worker_token, browser_token, browser_check if browser else None)
        # Known-good is proven BEFORE stopping any services or touching source.
        try:
            wait_ready(probe, prior['commit'])
        finally:
            probe.close()
        for name in backend:
            path = target(name)
            if path.exists():
                copy = backup / "source" / name
                copy.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, copy)
        (backup / "source-state.json").write_bytes(canonical(policy))
        (backup / '.release-identity.json').write_bytes(identity)
        (backup / 'last-release.json').write_bytes(canonical(prior))
        if browser_plan:
            (backup / 'browser-state.json').write_bytes(root_file(browser_release.BROWSER_STATE))
            (backup / 'browser-image-id').write_bytes(root_file(browser_release.IMAGE_PATH))
        services = SERVICES + (('stack-browser.service',) if browser else ())
        def install():
            for name, value in backend.items():
                write_atomic(target(name), value, stack.pw_gid)
            write_atomic(target('.release-identity.json'), canonical({'commit': manifest['commit']}), stack.pw_gid)
            # Do not mutate dependencies or persistent caches/data on this path.
            # Runtime contract changes stop above, before promotion.
            if browser_plan:
                browser_release.promote(browser_plan, backup, write_atomic)
        def restore():
            for name in backend:
                if name in policy:
                    write_atomic(target(name), (backup / 'source' / name).read_bytes(), stack.pw_gid)
                else:
                    target(name).unlink(missing_ok=True)
            write_atomic(target('.release-identity.json'), identity, stack.pw_gid)
            write_atomic(policy_path, canonical(policy), 0)
            write_atomic(STATE / 'last-release.json', canonical(prior), 0)
            (STATE / 'last-release.json').chmod(0o600)
            if browser_plan:
                for path, name in ((browser_release.BROWSER_STATE, 'browser-state.json'),
                                   (browser_release.IMAGE_PATH, 'browser-image-id')):
                    write_atomic(path, (backup / name).read_bytes(), 0)
                    path.chmod(0o600)
            assert source_state(policy) == policy, 'Recovery source verification failed'
            assert all(digest(root_file(Path(p))) == h for p, h in protected.items()), 'Recovery runtime/config verification failed'
        def persist(receipt):
            receipt.update(sha256=sha, backup_id=backup.name, probe_protocol=1)
            write_atomic(STATE / 'transaction.json', canonical(receipt), 0)
            (STATE / 'transaction.json').chmod(0o600)
        def finalize():
            assert source_state(manifest['files']) == manifest['files'], 'Candidate source verification failed'
            assert all(digest(root_file(Path(p))) == h for p, h in protected.items()), 'Runtime/config changed during deployment'
            write_atomic(policy_path, canonical(manifest['files']), 0)
            policy_path.chmod(0o600)
            write_atomic(STATE / 'last-release.json', canonical({'status': 'healthy',
                'commit': manifest['commit'], 'sha256': sha, 'probe_protocol': 1}), 0)
            (STATE / 'last-release.json').chmod(0o600)
        # A new Probe ensures the prior preflight reply cannot satisfy promotion.
        probe = Probe(LIVE, worker_token, browser_token, browser_check if browser else None)
        try:
            result = transaction(prior['commit'], manifest['commit'],
                stop=lambda: service_stop(services), install=install,
                start=lambda: service_start(services), check=probe, restore=restore,
                persist=persist, finalize=finalize)
        finally:
            probe.close()
        print(json.dumps(result))
        if result['status'] != 'healthy':
            sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"status": "rejected", "stage": "preflight_or_receipt", "error": type(error).__name__,
                          "action": "Review private host state and compatibility approval; do not retry unresolved transactions."}))
        sys.exit(1)
