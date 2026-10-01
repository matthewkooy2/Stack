"""Own the Mac API, Jac compilation and Metro; no global toolchain changes."""
import json
import base64
import os
from pathlib import Path
import signal
import secrets
import socket
import subprocess
import sys
import time
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
MOBILE = ROOT / '.jac/mobile-rn'
JAC = str(ROOT / 'scripts/jac')

def host_address():
    if os.environ.get('STACK_HOST'):
        return os.environ['STACK_HOST']
    # Bonjour resolves this name on the current network; an IP baked into a
    # recently opened development URL goes stale whenever Wi-Fi changes.
    result = subprocess.run(['scutil', '--get', 'LocalHostName'], capture_output=True, text=True, timeout=5)
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()+'.local'
    address=wifi_address()
    if address:return address
    raise SystemExit('Connect your Mac to Wi-Fi, or set STACK_HOST to its reachable hostname.')

def wifi_address():
    result=subprocess.run(['ipconfig','getifaddr','en0'],capture_output=True,text=True,timeout=5)
    return result.stdout.strip() if result.returncode==0 else ''

def metro_environment(host):
    env=os.environ.copy()
    env.update(STACK_API_URL=f'http://{host}:8000',REACT_NATIVE_PACKAGER_HOSTNAME=host,
               EXPO_UNSTABLE_BONJOUR='1')
    return env

def write_host(host):
    api=f'http://{host}:8000'
    (MOBILE/'stack-host.json').write_text(json.dumps({'apiBaseUrl':api}))
    (MOBILE/'__jacApiBase.js').write_text('globalThis.__JAC_API_BASE_URL__ = '+json.dumps(api)+';\n')

def compile_mobile():
    subprocess.run([JAC, 'run', '--no-serve', 'scripts/compile-mobile.jac'], cwd=ROOT, check=True)

def snapshot(paths):
    return {str(p):p.stat().st_mtime_ns for parent in paths for p in parent.rglob('*') if p.is_file() and p.suffix in ('.jac','.js','.py','.json')}

def configure_browser_preview(host):
    """Regenerate local service settings after every main-account refresh."""
    os.environ['STACK_BROWSER_URL']='http://127.0.0.1:8011'
    os.environ['STACK_BROWSER_TOKEN']=secrets.token_urlsafe(48)
    os.environ['STACK_BROWSER_SESSION_KEY']=base64.urlsafe_b64encode(secrets.token_bytes(32)).decode()
    path=ROOT/'storage/agents/config.json'
    config=json.loads(path.read_text())
    config['web_url']=f'http://{host}:8080'
    path.write_text(json.dumps(config,indent=2)+'\n');path.chmod(0o600)
    return config['web_url']

def wait_for_service(process, url, token=''):
    for _ in range(60):
        if process.poll() is not None:
            raise RuntimeError('A preview service failed to start. Inspect .jac/logs/browser.log or workspace.log.')
        try:
            request=Request(url,headers={'Authorization':'Bearer '+token} if token else {})
            with urlopen(request,timeout=1) as response:
                if response.status==200 and (not token or json.load(response).get('ready')):
                    return
        except (OSError,ValueError):
            pass
        time.sleep(0.5)
    raise RuntimeError('A preview service did not become ready. Inspect .jac/logs.')

def main():
    if not (MOBILE/'node_modules').exists():
        raise SystemExit('Run ./scripts/setup first.')
    for port in (8000,8081,8011,8080):
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
    agent_private=ROOT/'storage/agents';agent_private.mkdir(parents=True,exist_ok=True)
    agent_token=agent_private/'worker-token'
    if not agent_token.exists():agent_token.write_text(secrets.token_urlsafe(48));agent_token.chmod(0o600)
    host=host_address()
    api=f'http://{host}:8000'
    web=configure_browser_preview(host)
    write_host(host)
    compile_mobile()
    # Jac's generated entry imports this file; the compiler may recreate its stub.
    write_host(host)
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
        browser=start([sys.executable,'scripts/browser-preview.py','run'],ROOT,'browser.log')
        wait_for_service(browser,os.environ['STACK_BROWSER_URL']+'/health',os.environ['STACK_BROWSER_TOKEN'])
        gateway_env={**os.environ,'STACK_GATEWAY_BIND':'0.0.0.0'}
        workspace=start([str(ROOT/'scripts/jac'),'run','--no-serve','scripts/gateway-service.jac'],ROOT,'workspace.log',gateway_env)
        wait_for_service(workspace,'http://127.0.0.1:8080/')
        print(f'LinkedIn browser ready. Sign-in workspace: {web}',flush=True)
        backend=start([JAC,'run','--no-client','--port','8000','Stack'],ROOT,'api.log')
        worker=start([JAC,'run','--no-serve','scripts/discovery-worker.jac'],ROOT,'discovery.log')
        agent_worker=start([JAC,'run','--no-serve','scripts/agent-worker.jac'],ROOT,'agents.log')
        metro_command=['node','node_modules/expo/bin/cli','start','--dev-client','--port','8081']
        metro=start(metro_command,MOBILE,'metro.log',metro_environment(host))
        network=wifi_address();network_check=time.monotonic()
        print(f'Stack API: {api}\nMetro: http://{host}:8081\nOpen Stack on your iPhone and choose Stack under local development servers.\nAllow Local Network access and keep both devices on the same Wi-Fi.\nWi-Fi changes refresh discovery automatically; the URLs stay the same.\nLogs: {logs}\nJac screen edits reload automatically. Ctrl-C stops all development services.',flush=True)
        previous=snapshot([ROOT/'mobile',ROOT/'native',ROOT/'core',ROOT/'discovery',ROOT/'agents'])
        backend_time=(ROOT/'main.jac').stat().st_mtime_ns
        while True:
            time.sleep(1)
            if any(p.poll() is not None for p in (backend,metro,worker,agent_worker,browser,workspace)):
                raise RuntimeError('A development server stopped. Inspect .jac/logs.')
            if time.monotonic()-network_check>=5:
                address=wifi_address();network_check=time.monotonic()
                if address!=network:
                    network=address
                    if address:
                        host=host_address();write_host(host)
                        stop(metro)
                        metro=start(metro_command,MOBILE,'metro.log',metro_environment(host))
                        print('Wi-Fi changed. Local discovery refreshed; reopen Stack to reconnect.',flush=True)
            current=snapshot([ROOT/'mobile',ROOT/'native',ROOT/'core',ROOT/'discovery',ROOT/'agents'])
            changed={p for p in current.keys()|previous.keys() if current.get(p)!=previous.get(p)}
            if any('/mobile/' in p or p.endswith('/native/device.js') for p in changed):
                try:compile_mobile()
                except subprocess.CalledProcessError:print('Compilation failed; fix the reported Jac error and save again.',flush=True)
            modified=(ROOT/'main.jac').stat().st_mtime_ns
            if modified!=backend_time or any('/core/' in p or '/discovery/' in p or '/agents/' in p for p in changed):
                stop(agent_worker)
                stop(worker)
                stop(backend);backend=start([JAC,'run','--no-client','--port','8000','Stack'],ROOT,'api.log')
                worker=start([JAC,'run','--no-serve','scripts/discovery-worker.jac'],ROOT,'discovery.log')
                agent_worker=start([JAC,'run','--no-serve','scripts/agent-worker.jac'],ROOT,'agents.log')
            previous=current;backend_time=modified
    except KeyboardInterrupt:
        pass
    finally:
        for p in reversed(processes):stop(p)

if __name__=='__main__':main()
