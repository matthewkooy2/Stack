"""Build and supervise the credential-isolated browser used by local previews."""
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Only these source files enter the image: no checkout mount, accounts or CLI auth.
FILES = ('deploy/browser.Dockerfile', 'deploy/browser.jac.toml',
         'deploy/browser-entrypoint', 'deploy/browser-service.jac', 'deploy/install-browser.jac',
         'agents/browser_service.jac', 'agents/browser.jac',
         'agents/browser_control.py', 'agents/browser_stream.py', 'agents/linkedin.jac',
         'agents/contracts.jac', 'discovery/transport.py')


def image_name():
    digest = hashlib.sha256()
    for name in FILES:
        digest.update(name.encode())
        digest.update((ROOT / name).read_bytes())
    return 'stack-browser-preview:' + digest.hexdigest()[:16]


def prepare():
    if not shutil.which('docker'):
        raise RuntimeError('Install Docker Desktop for the isolated LinkedIn browser preview.')
    probe = subprocess.run(['docker', 'info', '--format', '{{.ServerVersion}}'], capture_output=True, timeout=15)
    if probe.returncode and sys.platform == 'darwin':
        # The shared Mac preview owns service startup; no separate manual Docker step.
        subprocess.run(['docker', 'desktop', 'start', '--timeout', '45'], capture_output=True, timeout=50)
        probe = subprocess.run(['docker', 'info', '--format', '{{.ServerVersion}}'], capture_output=True, timeout=15)
    if probe.returncode:
        raise RuntimeError('Start Docker Desktop, then switch worktrees again. The current preview is unchanged.')
    image = image_name()
    if subprocess.run(['docker', 'image', 'inspect', image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        return
    if shutil.disk_usage(ROOT).free < 2 * 1024 ** 3:
        raise RuntimeError('Free at least 2 GB before installing the Chromium preview. The current preview is unchanged.')
    with tempfile.TemporaryDirectory(prefix='stack-browser-build-') as directory:
        for name in FILES:
            target = Path(directory) / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        subprocess.run(['docker', 'build', '-t', image, '-f', 'deploy/browser.Dockerfile', directory], check=True)


def run():
    # docker -e NAME takes the value from this process without putting it in argv.
    token = os.environ.get('STACK_BROWSER_TOKEN', '')
    if len(token) < 32:
        raise RuntimeError('The preview supervisor must provide a browser token.')
    name = 'stack-browser-' + hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]
    command = ['docker', 'run', '--rm', '--init', '--name', name,
               '--read-only', '--tmpfs', '/tmp:rw,exec,nosuid,size=1g', '--shm-size=1g',
               # Chromium's namespace sandbox needs chroot; keep all other caps dropped.
               '--cap-drop=ALL', '--cap-add=SYS_CHROOT', '--security-opt', 'no-new-privileges',
               '--security-opt', 'seccomp=' + str(ROOT / 'deploy/browser-seccomp.json'),
               '-p', '127.0.0.1:8011:8011', '-e', 'STACK_BROWSER_TOKEN', '-e', 'STACK_BROWSER_SESSION_KEY', image_name()]
    def interrupted(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    process = subprocess.Popen(command)
    try:
        code = process.wait()
        if code:
            raise RuntimeError('The isolated browser stopped. Inspect .jac/logs/browser.log.')
    except KeyboardInterrupt:
        pass
    finally:
        # Only this worktree's named container is stopped; Docker itself stays up.
        subprocess.run(['docker', 'stop', '--time', '5', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        process.wait(timeout=15)


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['prepare']:
            prepare()
        elif sys.argv[1:] == ['run']:
            run()
        else:
            raise RuntimeError('Use prepare or run.')
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
