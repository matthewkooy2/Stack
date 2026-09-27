"""Own the Mac API, Jac compilation and Metro; no global toolchain changes."""
import json
import os
from pathlib import Path
import signal
import secrets
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
MOBILE = ROOT / '.jac/mobile-rn'
JAC = str(ROOT / 'scripts/jac')

def host_address():
    if os.environ.get('STACK_HOST'):
        return os.environ['STACK_HOST']
    result = subprocess.run(['ipconfig', 'getifaddr', 'en0'], capture_output=True, text=True)
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    raise SystemExit('Set STACK_HOST to this Mac’s Wi-Fi IP address, then run scripts/dev again.')

def compile_mobile():
    subprocess.run([JAC, 'run', '--no-serve', 'scripts/compile-mobile.jac'], cwd=ROOT, check=True)

def snapshot(paths):
    return {str(p):p.stat().st_mtime_ns for parent in paths for p in parent.rglob('*') if p.is_file() and p.suffix in ('.jac','.js','.py','.json')}

def main():
    if not (MOBILE/'node_modules').exists():
        raise SystemExit('Run ./scripts/setup first.')
    for port in (8000,8081):
        with socket.socket() as probe:
            if probe.connect_ex(('127.0.0.1',port)) == 0:
                raise SystemExit(f'Port {port} is already in use. Stop the existing Stack process before restarting.')
    private=ROOT/'storage/discovery';private.mkdir(parents=True,exist_ok=True)
    token=private/'worker-token'
    if not token.exists():token.write_text(secrets.token_urlsafe(48));token.chmod(0o600)
    config=private/'credentials.json'
    if config.exists():
        for key,value in json.loads(config.read_text()).items():
            if key in ('ADZUNA_APP_ID','ADZUNA_APP_KEY','STACK_ADZUNA_APPROVED','THEIRSTACK_API_KEY','STACK_THEIRSTACK_TERMS_ACCEPTED','USAJOBS_API_KEY','USAJOBS_EMAIL','GITHUB_TOKEN'):
                os.environ[key]=str(value)
    host=host_address()
    api=f'http://{host}:8000'
    (MOBILE/'stack-host.json').write_text(json.dumps({'apiBaseUrl':api}))
    (MOBILE/'__jacApiBase.js').write_text('globalThis.__JAC_API_BASE_URL__ = '+json.dumps(api)+';\n')
    compile_mobile()
    # Jac's generated entry imports this file; the compiler may recreate its stub.
    (MOBILE/'__jacApiBase.js').write_text('globalThis.__JAC_API_BASE_URL__ = '+json.dumps(api)+';\n')
    processes=[]
    logs=ROOT/'.jac/logs';logs.mkdir(parents=True,exist_ok=True)
    def start(command,cwd,log,env=None):
        with (logs/log).open('a') as f:
            p=subprocess.Popen(command,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,env=env,start_new_session=True)
        processes.append(p)
        return p
    def stop(p):
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    def interrupted(*_):raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,interrupted)
    try:
        backend=start([JAC,'run','--no-client','--port','8000','Stack'],ROOT,'api.log')
        worker=start([JAC,'run','--no-serve','scripts/discovery-worker.jac'],ROOT,'discovery.log')
        env=os.environ.copy();env['STACK_API_URL']=api;env['REACT_NATIVE_PACKAGER_HOSTNAME']=host
        metro=start(['node','node_modules/expo/bin/cli','start','--dev-client','--port','8081'],MOBILE,'metro.log',env)
        print(f'Stack API: {api}\nMetro: http://{host}:8081\nOpen Stack on your iPhone on the same Wi-Fi.\nLogs: {logs}\nJac screen edits reload automatically. Ctrl-C stops the servers and discovery worker.',flush=True)
        previous=snapshot([ROOT/'mobile',ROOT/'native',ROOT/'core',ROOT/'discovery'])
        backend_time=(ROOT/'main.jac').stat().st_mtime_ns
        while True:
            time.sleep(1)
            if backend.poll() is not None or metro.poll() is not None or worker.poll() is not None:
                raise RuntimeError('A development server stopped. Inspect .jac/logs.')
            current=snapshot([ROOT/'mobile',ROOT/'native',ROOT/'core',ROOT/'discovery'])
            changed={p for p in current.keys()|previous.keys() if current.get(p)!=previous.get(p)}
            if any('/mobile/' in p or p.endswith('/native/device.js') for p in changed):
                try:compile_mobile()
                except subprocess.CalledProcessError:print('Compilation failed; fix the reported Jac error and save again.',flush=True)
            modified=(ROOT/'main.jac').stat().st_mtime_ns
            if modified!=backend_time or any('/core/' in p or '/discovery/' in p for p in changed):
                stop(worker)
                stop(backend);backend=start([JAC,'run','--no-client','--port','8000','Stack'],ROOT,'api.log')
                worker=start([JAC,'run','--no-serve','scripts/discovery-worker.jac'],ROOT,'discovery.log')
            previous=current;backend_time=modified
    except KeyboardInterrupt:
        pass
    finally:
        for p in reversed(processes):stop(p)

if __name__=='__main__':main()
