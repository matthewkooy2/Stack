#!/usr/bin/env python3
"""Isolated Mac backend + browser jobs lab. No iOS, worker, or production settings."""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
LAB = ROOT / '.jac/jobs-lab'
APP = LAB / 'app'
ALLOWED = {'/user/register', '/user/login'} | {
    '/function/' + name for name in
    ('bootstrap', 'save_profile', 'save_search', 'job_feed', 'source_status', 'get_job')
}


def stage():
    """A distinct project base selects a distinct embedded PostgreSQL database.

    Do not rely on JAC_DATA_PATH: this Jac version hashes base_path for PG names.
    Copy only backend source; storage and local config are never imported.
    """
    APP.mkdir(parents=True, exist_ok=True)
    for name in ('main.jac', 'jac.toml'):
        shutil.copy2(ROOT / name, APP / name)
    for name in ('core', 'agents', 'discovery', 'dependencies', 'scripts'):
        destination = APP / name
        if destination.exists():
            shutil.rmtree(destination)
    for name in ('core', 'agents', 'discovery', 'dependencies'):
        shutil.copytree(ROOT / name, APP / name, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store'))
    dependencies = ROOT / '.jac/venv'
    if not dependencies.is_dir():
        raise SystemExit('Backend dependencies are missing. Run ./scripts/jac install in this worktree, then restart the lab.')
    staged_dependencies = APP / '.jac/venv'
    if staged_dependencies.exists():
        shutil.rmtree(staged_dependencies)
    shutil.copytree(dependencies, staged_dependencies, symlinks=True)
    (APP / 'scripts').mkdir(exist_ok=True)
    for name in ('jobs-lab-seed.jac', 'jobs_lab_data.py'):
        source = ROOT / 'scripts' / name
        if source.exists():
            shutil.copy2(source, APP / 'scripts' / name)
    # A root-level Jac target inherits [project].name, exactly like main.jac.
    # A scripts/ target instead derives a different embedded DB name from its stem.
    seed = ROOT / 'scripts/jobs-lab-seed.jac'
    if seed.exists():
        shutil.copy2(seed, APP / 'jobs-lab-seed.jac')


def environment(count):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('STACK_', 'JAC_')) and key not in {
               'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'GOOGLE_APPLICATION_CREDENTIALS',
               'GITHUB_TOKEN', 'GH_TOKEN', 'ADZUNA_APP_ID', 'ADZUNA_APP_KEY',
               'THEIRSTACK_API_KEY', 'USAJOBS_API_KEY', 'USAJOBS_EMAIL'}}
    env.update(JAC_DB_URL='', PYTHON_DOTENV_DISABLED='1',
               JAC_CACHE_HOME=str(ROOT / '.jac/tool-cache'),
               STACK_AGENT_CONFIG=str(LAB / 'agents.json'),
               STACK_JOBS_LAB_COUNT=str(count))
    # Use the project's established short socket location on macOS.
    common = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse',
                                      '--path-format=absolute', '--git-common-dir'], text=True).strip()
    temporary = Path(common).parent / '.jac-tmp'
    temporary.mkdir(exist_ok=True)
    env['TMPDIR'] = str(temporary)
    (LAB / 'agents.json').write_text(json.dumps({'invite_only': False, 'monthly_cents': 0,
                                                 'user_monthly_cents': 0, 'action_daily_limits': {}}))
    (LAB / 'agents.json').chmod(0o600)
    return env


def handler(api):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, status, content, kind='application/json', api_ms=None):
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(content)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            if api_ms is not None:
                self.send_header('X-Stack-API-ms', f'{api_ms:.1f}')
            self.end_headers()
            self.wfile.write(content)

        def do_GET(self):
            if self.path == '/':
                self.send(200, (ROOT / 'web/jobs-lab.html').read_bytes(), 'text/html; charset=utf-8')
            elif self.path == '/lab-info':
                manifest = LAB / 'manifest.json'
                self.send(200, manifest.read_bytes() if manifest.exists() else b'{"kind":"synthetic","note":"Catalog manifest unavailable"}')
            else:
                self.send(404, b'{"error":"Not found"}')

        def do_POST(self):
            if self.path not in ALLOWED:
                self.send(404, b'{"error":"Not found"}')
                return
            # Keep a local page on another origin from submitting account changes.
            origin = self.headers.get('Origin')
            expected = f'http://{self.headers.get("Host", "")}'
            if origin and origin != expected:
                self.send(403, b'{"error":"Origin not allowed"}')
                return
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 <= length <= 65536:
                self.send(413, b'{"error":"Request too large"}')
                return
            body = self.rfile.read(length)
            headers = {'Content-Type': 'application/json'}
            if self.headers.get('Authorization'):
                headers['Authorization'] = self.headers['Authorization']
            began = time.perf_counter()
            try:
                with urlopen(Request(api + self.path, data=body, headers=headers), timeout=180) as response:
                    self.send(response.status, response.read(), api_ms=(time.perf_counter()-began)*1000)
            except HTTPError as error:
                self.send(error.code, error.read(), api_ms=(time.perf_counter()-began)*1000)
            except (OSError, URLError):
                self.send(502, b'{"error":"Local API unavailable; inspect .jac/jobs-lab/api.log"}')
    return Handler


def main():
    global LAB, APP
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count', type=int, default=40000, help='Synthetic catalog rows (default: 40000)')
    parser.add_argument('--name', default='', help='Separate persistent dataset, e.g. --name 50k --count 50000')
    parser.add_argument('--api-port', type=int, default=18200)
    parser.add_argument('--web-port', type=int, default=18280)
    parser.add_argument('--stage-only', action='store_true', help='Prepare isolated source without starting services')
    args = parser.parse_args()
    if args.count < 1 or args.api_port == args.web_port or any(not 1024 <= port <= 65535 for port in (args.api_port, args.web_port)):
        parser.error('Choose a positive row count and two distinct ports from 1024 to 65535.')
    if args.name:
        if not re.fullmatch(r'[a-zA-Z0-9_-]{1,40}', args.name):
            parser.error('Dataset name must be 1-40 letters, numbers, underscores, or hyphens.')
        LAB = ROOT / ('.jac/jobs-lab-' + args.name)
        APP = LAB / 'app'
    if not args.stage_only:
        for port in (args.api_port, args.web_port):
            with socket.socket() as probe:
                if probe.connect_ex(('127.0.0.1', port)) == 0:
                    raise SystemExit(f'Port {port} is occupied. Choose another port; existing services were left running.')
    stage()
    env = environment(args.count)
    if args.stage_only:
        print(APP)
        return
    jac = ROOT / '.jac/tools/bin/jac'
    executable = str(jac) if jac.is_file() else shutil.which('jac')
    if not executable:
        raise SystemExit('Install the project Jac compiler (0.37.21) before starting the lab.')
    print(f'Preparing synthetic catalog ({args.count:,} rows). First seed may take a few minutes.', flush=True)
    subprocess.run([executable, 'run', '--backend', 'python', '--no-serve', 'jobs-lab-seed.jac'],
                   cwd=APP, env=env, check=True)
    stage()
    # The seeder records catalog shape and sizing assumptions next to its isolated source.
    manifest = APP / 'storage/jobs-lab/manifest.json'
    if manifest.exists():
        shutil.copy2(manifest, LAB / 'manifest.json')
    api = f'http://127.0.0.1:{args.api_port}'
    log = (LAB / 'api.log').open('a')
    process = subprocess.Popen([executable, 'run', '--no-client', '--host', '127.0.0.1',
                                '--workers', '1', '--port', str(args.api_port), 'Stack'],
                               cwd=APP, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    server = None
    def interrupted(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        deadline = time.monotonic() + 600
        while True:
            if process.poll() is not None:
                raise SystemExit(f'API stopped. Inspect {LAB / "api.log"}')
            try:
                with urlopen(Request(api + '/function/health', data=b'{}',
                                     headers={'Content-Type': 'application/json'}), timeout=1) as response:
                    if json.load(response).get('data', {}).get('result', {}).get('status') == 'ok':
                        break
            except (OSError, URLError):
                pass
            if time.monotonic() > deadline:
                raise SystemExit(f'API startup timed out. Inspect {LAB / "api.log"}')
            time.sleep(.5)
        server = ThreadingHTTPServer(('127.0.0.1', args.web_port), handler(api))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        print(f'Jobs lab ready: http://127.0.0.1:{args.web_port}/\nAPI: {api}\n'
              f'Isolated data: {APP}\nCtrl-C stops both services. Accounts persist across restarts.\n'
              'Backend source is staged at startup; restart this command after backend changes.', flush=True)
        while process.poll() is None:
            time.sleep(.5)
        raise SystemExit(f'API stopped. Inspect {LAB / "api.log"}')
    except KeyboardInterrupt:
        pass
    finally:
        if server:
            server.shutdown()
            server.server_close()
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        log.close()


if __name__ == '__main__':
    main()
