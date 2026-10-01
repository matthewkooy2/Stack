#!/usr/bin/env python3
"""Switch the Mac's phone preview with an isolated copy of the main account."""
import argparse
import fcntl
import os
from pathlib import Path
import signal
import socket
import subprocess
import time
from urllib.request import urlopen
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from preview_data import Refresh, check_cli, preview_config
import json

HOME = Path(__file__).resolve().parent.parent


def worktrees():
    output = subprocess.check_output(['git', 'worktree', 'list', '--porcelain'], cwd=HOME, text=True)
    return {path.name: path for line in output.splitlines() if line.startswith('worktree ')
            for path in [Path(line.removeprefix('worktree '))] if (path / 'scripts/dev').is_file()}


def process_cwd(pid):
    result = subprocess.run(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], capture_output=True, text=True)
    return next((Path(line[1:]).resolve() for line in result.stdout.splitlines() if line.startswith('n')), None)


def running(registered):
    output = subprocess.check_output(['ps', '-ax', '-o', 'pid=,command='], text=True)
    found = []
    for line in output.splitlines():
        pid, command = line.strip().split(None, 1)
        if command.endswith('scripts/develop.py'):
            cwd = process_cwd(int(pid))
            if cwd in registered.values():
                found.append((int(pid), cwd))
    return found


def occupied(port):
    with socket.socket() as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(('127.0.0.1', port)) == 0


def ready():
    if not occupied(8000):
        return False
    try:
        with urlopen('http://127.0.0.1:8081/status', timeout=1) as response:
            return response.read() == b'packager-status:running'
    except OSError:
        return False


def stop(pid, path):
    # Recheck identity before signaling; a stale PID must not stop another app.
    if process_cwd(pid) != path:
        return
    command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout.strip()
    if not command.endswith('scripts/develop.py'):
        raise RuntimeError('Process identity changed; refusing to stop it.')
    os.kill(pid, signal.SIGTERM)
    for _ in range(150):
        if process_cwd(pid) != path:
            return
        time.sleep(0.2)
    raise RuntimeError(f'{path.name} did not stop; no other processes were killed.')


def start(path):
    if any(occupied(port) for port in (8000, 8081)):
        raise RuntimeError('Port 8000 or 8081 is occupied by an unmanaged process. It was not stopped.')
    log_path = path / '.jac/logs/develop.log'
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open('a') as log:
        process = subprocess.Popen([str(path / 'scripts/dev')], cwd=path, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True, stdin=subprocess.DEVNULL)
    for _ in range(180):
        if process.poll() is not None:
            raise RuntimeError(f'{path.name} failed to start. See {log_path}')
        if ready():
            # A listening Metro server can still fail to resolve the native entry.
            try:
                with urlopen('http://127.0.0.1:8081/index.bundle?platform=ios&dev=true&minify=false', timeout=90) as bundle:
                    while bundle.read(1024 * 1024):
                        pass
            except OSError as error:
                raise RuntimeError(f'iPhone bundle failed for {path.name}. See {path / ".jac/logs/metro.log"}') from error
            return
        time.sleep(0.5)
    stop(process.pid, path)
    raise RuntimeError(f'{path.name} did not become ready. See {log_path}')


def switch(name, registered, refresh=False):
    if name not in registered:
        raise RuntimeError('Unknown worktree. Choose: ' + ', '.join(sorted(registered)))
    target = registered[name]
    snapshot = None
    if refresh and target == registered.get('mainworktree'):
        raise RuntimeError('Cannot refresh main from itself.')
    # Every feature activation restores the established account and its CLI link.
    # Keep --refresh-from-main as a compatible alias for the new default.
    if target != registered.get('mainworktree'):
        source = registered.get('mainworktree')
        if source is None:
            raise RuntimeError('The mainworktree source is not registered.')
        branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=source, text=True).strip()
        if branch != 'main':
            raise RuntimeError('mainworktree must be on main before refreshing.')
        snapshot = Refresh(source, target)
        check_cli(snapshot.config, target)
    else:
        check_cli(preview_config(json.loads((target / 'storage/agents/config.json').read_text())), target)
    active = running(registered)
    if len(active) > 1:
        raise RuntimeError('Multiple development supervisors found; resolve them before switching.')
    if snapshot is None and active and active[0][1] == target and ready():
        return target
    if os.environ.get('JAC_DB_URL'):
        raise RuntimeError('Unset JAC_DB_URL before switching: phone previews use worktree-local databases.')
    mobile = target / '.jac/mobile-rn'
    required = ['node_modules/expo/bin/cli', 'metro.config.js', 'babel.config.js', 'app.config.js', 'app/App.tsx', 'jac-asset-registry.js']
    if not all((mobile / name).is_file() for name in required):
        raise RuntimeError(f'Set up {target.name} first with its ./scripts/setup. Current preview is unchanged.')
    if (mobile / 'node_modules').is_symlink():
        raise RuntimeError('Use worktree-local node_modules, not a shared mutable dependency symlink.')
    preparation = target / 'scripts/prepare-preview'
    if preparation.is_file():
        # Install/build optional services before taking the current phone offline.
        subprocess.run(['sh', str(preparation)], cwd=target, check=True)
    # Compile before interrupting the phone's current checkout.
    subprocess.run([str(target / 'scripts/jac'), 'run', '--no-serve', 'scripts/compile-mobile.jac'], cwd=target, check=True)
    if active:
        stop(*active[0])
    try:
        if snapshot:
            snapshot.prepare()
            snapshot.apply()
        start(target)
        if snapshot:
            snapshot.finish()
    except Exception:
        for pid, path in running(registered):
            if path == target:
                stop(pid, path)
        if snapshot:
            snapshot.rollback()
        if active:
            print('Switch failed; restarting ' + active[0][1].name, flush=True)
            start(active[0][1])
        raise
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('worktree', nargs='?', default='status', help='Worktree folder name, status, or stop')
    parser.add_argument('--refresh-from-main', action='store_true', help='Compatibility alias: feature previews always copy main account data and CLI settings')
    args = parser.parse_args()
    if args.refresh_from_main and args.worktree in ('status', 'stop'):
        parser.error('--refresh-from-main requires a preview worktree name')
    registered = worktrees()
    lock_path = HOME / '.jac/worktree-dev.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('Another worktree switch is already in progress.')
        if args.worktree == 'status':
            active = {path for _, path in running(registered)}
            for name, path in registered.items():
                print(f'{name}: {"running" if path in active else "stopped"}')
        elif args.worktree == 'stop':
            for pid, path in running(registered):
                stop(pid, path)
            print('Phone preview stopped. Databases and other test servers were left alone.')
        else:
            path = switch(args.worktree, registered, args.refresh_from_main)
            print(f'Phone preview: {path}\nReload Stack on your phone and sign in with your usual account. Server address is unchanged.\nCLI sign-in verified. Feature previews automatically copy main account data and CLI settings; previous preview data is backed up.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
