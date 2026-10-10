"""Activate only the existing production collector; never configure credentials.

Run as root after deploying the reviewed source. Default is read-only preflight.
--apply installs/enables the unit after a bounded batch for --source succeeds.
"""
import argparse
from contextlib import nullcontext
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import subprocess

ROOT = Path('/opt/stack')
UNIT = 'stack-discovery.service'
DEST = Path('/etc/systemd/system') / UNIT
ENV = Path('/etc/stack/discovery.env')
LOCK = Path('/var/lib/stack-release/deploy.lock')


def run(args, timeout=30):
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=timeout).stdout.strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def protected():
    paths = list(Path('/etc/stack').glob('*.env'))
    paths += [ROOT / 'storage/discovery/worker-token',
              ROOT / 'storage/agents/config.json']
    return {str(p): digest(p) for p in paths}


def service_command(source):
    # Source remains an argv value, never shell code. systemd loads private env.
    return ['systemd-run', '--quiet', '--wait', '--collect', '--pipe',
            '--unit=stack-discovery-preflight', '--property=User=stack',
            '--property=Group=stack', '--property=WorkingDirectory=/opt/stack',
            '--property=EnvironmentFile=/etc/stack/discovery.env',
            '--property=RuntimeMaxSec=180',
            '--property=UMask=0077',
            '--property=NoNewPrivileges=true', '--property=PrivateTmp=true',
            '--property=ProtectSystem=strict', '--property=ProtectHome=true',
            '--property=InaccessiblePaths=/var/lib/stack-codex',
            '--property=ReadWritePaths=/opt/stack/.jac /var/lib/stack/.cache',
            '--setenv=STACK_JAC_BIN=/usr/local/bin/jac',
            '--setenv=HOME=/var/lib/stack',
            '--setenv=XDG_CACHE_HOME=/var/lib/stack/.cache',
            '--setenv=PATH=/usr/local/bin:/usr/bin:/bin',
            '--setenv=PYTHONDONTWRITEBYTECODE=1',
            '--setenv=JAC_SCHEMA_REPAIR=detect',
            '/opt/stack/scripts/jac', 'run', '--no-serve',
            'scripts/discovery-worker.jac', '--once', '--source', source]


def validate_source(source):
    assert re.fullmatch(r'[A-Za-z0-9_.:/-]+', source), 'Invalid source ID'
    query = ("SELECT props->'archetype'->'config' FROM anchors WHERE "
             "arch_type='JobSource' AND props->'archetype'->>'key'='" + source + "';")
    raw = run(['runuser', '-u', 'postgres', '--', 'psql', '-X', '-w', '-qAt',
               '-v', 'ON_ERROR_STOP=1', '-d', 'stack', '-c', query])
    config = json.loads(raw)
    assert config.get('approved') and config.get('renderer') != 'playwright'
    assert config.get('adapter') in ('greenhouse', 'lever', 'ashby', 'smartrecruiters',
                                     'career', 'html', 'rss'), 'Initial refresh must use a public source'


def refreshed(output, source):
    return any(re.fullmatch(re.escape(source) + r': [1-9][0-9]* listings', line)
               for line in output.splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--source', default='', help='Existing public source ID for one bounded batch')
    args = parser.parse_args()
    assert os.geteuid() == 0, 'Run preflight as root to inspect private file metadata'
    # Share the production promoter's lock; keep it held through activation.
    with (LOCK.open('r+') if args.apply else nullcontext()) as lock:
        if lock is not None:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        activate(args)


def activate(args):
    assert not ROOT.is_symlink() and not DEST.is_symlink()
    account = pwd.getpwnam('stack')
    assert account.pw_uid != 0
    assert run(['systemctl', 'is-active', 'stack-api.service']) == 'active'
    assert subprocess.run(['systemctl', 'is-active', '--quiet', UNIT],
                          capture_output=True).returncode != 0, 'Collector already active'
    values = dict(line.split('=', 1) for line in ENV.read_text().splitlines()
                  if '=' in line and not line.startswith('#'))
    assert values.get('STACK_WORKER_API') == 'http://127.0.0.1:8000'
    assert not any(values.get(k, '').strip() for k in
                   ('ADZUNA_APP_ID', 'ADZUNA_APP_KEY', 'THEIRSTACK_API_KEY',
                    'USAJOBS_API_KEY', 'USAJOBS_EMAIL', 'GITHUB_TOKEN')), 'Review existing credential scope separately'
    body = (ROOT / 'deploy' / UNIT).read_text()
    assert not DEST.exists() or DEST.read_text() == body, 'Existing unit differs; review before replacing'
    before = protected()
    run(['runuser', '-u', 'stack', '--', 'test', '-r',
         str(ROOT / 'storage/discovery/worker-token')])
    run(['systemd-analyze', 'verify', str(ROOT / 'deploy' / UNIT)])
    print(json.dumps({'status': 'preflight_passed', 'private_files_preserved': True}), flush=True)
    if not args.apply:
        return
    assert args.source, '--apply requires an existing public --source for bounded refresh'
    assert not DEST.exists(), 'Existing unit activation state requires separate review'
    validate_source(args.source)
    installed = False
    try:
        # Complete one lease through the production API before enabling recurrence.
        output = run(service_command(args.source), timeout=200)
        assert refreshed(output, args.source), 'Bounded batch did not produce fresh listings'
        assert protected() == before, 'Private configuration changed during bounded refresh'
        if not DEST.exists():
            with DEST.open('x') as f:
                f.write(body)
            DEST.chmod(0o644)
            installed = True
        run(['systemctl', 'daemon-reload'])
        run(['systemctl', 'enable', '--now', UNIT])
        assert run(['systemctl', 'is-active', UNIT]) == 'active'
        assert run(['systemctl', 'is-enabled', UNIT]) == 'enabled'
        assert protected() == before
        print(json.dumps({'status': 'collector_enabled', 'private_files_preserved': True,
                          'bounded_refresh_completed': True}), flush=True)
    except BaseException:
        subprocess.run(['systemctl', 'disable', '--now', UNIT], capture_output=True)
        if installed:
            DEST.unlink()
            subprocess.run(['systemctl', 'daemon-reload'], capture_output=True)
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Private subprocess output may contain source details; emit only type.
        print(json.dumps({'status': 'failed', 'error_type': type(exc).__name__}), flush=True)
        raise SystemExit(1)
