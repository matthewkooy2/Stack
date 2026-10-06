#!/usr/bin/env python3
"""Public contributor commands. No production access or provider requests by default."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from uuid import UUID

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ('storage/', '.jac/', '.codex/', '.claude/', 'jac.local.toml', '.env',
           'deploy/api.env', 'deploy/worker.env', 'deploy/discovery.env',
           'discovery/credentials.json')
FLAGS = {
    'codex': ('exec', ('--ignore-user-config', '--ephemeral', '--skip-git-repo-check',
                      '--sandbox', '--json', '--output-schema', '--output-last-message')),
    'claude': ('', ('--safe-mode', '--restricted', '--tools', '--strict-mcp-config',
                   '--mcp-config', '--disable-slash-commands', '--no-chrome',
                   '--no-session-persistence', '--permission-mode', '--output-format', '--json-schema')),
}


def check_platform():
    if sys.platform not in ('linux', 'darwin'):
        raise RuntimeError('Use Ubuntu 24.04 inside WSL2; run these commands in its Linux terminal.')


def tracked_private(root):
    result = subprocess.run(['git', 'ls-files', '-z'], cwd=root, capture_output=True, check=True)
    paths = result.stdout.decode().split('\0')
    return [p for p in paths if any(p == x or (x.endswith('/') and p.startswith(x)) for x in PRIVATE)
            or (p.startswith('.env.') and not p.endswith('.example'))]


def private_file(path, value):
    """Create with private permissions from the first byte; never replace existing data."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise RuntimeError('A local private file is a symlink; use an ordinary private file.')
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return
    with os.fdopen(fd, 'w') as output:
        output.write(value)


def initialize(root):
    if (root / 'jac.local.toml').exists():
        raise RuntimeError('Contributor commands require a clone without jac.local.toml overrides. Preserve that file and use a separate public clone for local development.')
    if tracked_private(root):
        raise RuntimeError('Private runtime paths are tracked by Git. Untrack them before setup; rotate any exposed credentials.')
    # Do not read/copy an operator's environment or provider credential stores.
    for parent in (root / 'storage', root / 'storage/agents', root / 'storage/discovery', root / 'storage/contributor'):
        if parent.is_symlink():
            raise RuntimeError('A private runtime directory is a symlink; use ordinary local directories.')
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    private_file(root / 'storage/agents/worker-token', secrets.token_urlsafe(48))
    private_file(root / 'storage/discovery/worker-token', secrets.token_urlsafe(48))
    private_file(root / 'storage/contributor/runtime.json', json.dumps({
        'auth_secret': secrets.token_urlsafe(64),
        'connection_key': base64.urlsafe_b64encode(secrets.token_bytes(32)).decode(),
    }, indent=2) + '\n')
    config = json.loads((root / 'deploy/agent-config.example.json').read_text())
    config.update(invite_only=False, web_url='http://127.0.0.1:8080', capture_agent_content=False)
    private_file(root / 'storage/agents/config.json', json.dumps(config, indent=2) + '\n')


def configuration(root):
    if (root / 'jac.local.toml').exists():
        raise RuntimeError('Use a separate public clone without jac.local.toml overrides; existing deployment settings are preserved.')
    if tracked_private(root):
        raise RuntimeError('Private runtime files are tracked. Untrack them before continuing; rotate exposed credentials.')
    paths = ('storage/agents/config.json', 'storage/contributor/runtime.json',
             'storage/agents/worker-token', 'storage/discovery/worker-token')
    for name in paths:
        path = root / name
        if not path.is_file() or path.is_symlink():
            raise RuntimeError('Missing or unsafe local configuration. Run make setup; no existing files are overwritten.')
        if path.stat().st_mode & 0o077:
            raise RuntimeError('Private runtime files need mode 600. Run chmod 600 storage/agents/* storage/discovery/worker-token storage/contributor/runtime.json.')
    config = json.loads((root / paths[0]).read_text())
    runtime = json.loads((root / paths[1]).read_text())
    if not isinstance(config, dict) or not isinstance(runtime, dict):
        raise RuntimeError('Local configuration must be JSON objects. Restore a private backup or repair it locally.')
    if not isinstance(runtime.get('auth_secret'), str) or len(runtime['auth_secret']) < 64:
        raise RuntimeError('Local auth secret is missing or too short. Restore storage/contributor/runtime.json from a private backup.')
    if len(base64.urlsafe_b64decode(runtime.get('connection_key', ''))) != 32:
        raise RuntimeError('Invalid local encryption key. Restore the private runtime configuration; do not rotate keys for existing connections.')
    for name in paths[2:]:
        if len((root / name).read_text().strip()) < 32:
            raise RuntimeError('Invalid worker token. Restore private worker files from backup.')
    provider = config.get('provider', 'openai')
    if provider not in ('openai', 'meta', 'codex-cli', 'claude-cli'):
        raise RuntimeError('Unknown model provider. Run make login PROVIDER=codex OWNER=your-account-id.')
    if provider.endswith('-cli'):
        UUID(config.get('local_cli_owner', ''))
        if type(config.get('local_cli_daily_limit')) is not int or not 1 <= config['local_cli_daily_limit'] <= 100:
            raise RuntimeError('Set a CLI daily request cap between 1 and 100 with make login.')
    return config, runtime


def environment(root, api_port=8000, web_port=8080):
    import bootstrap
    env = bootstrap.environment(root)
    # Explicitly isolate public local development from inherited deployment settings.
    for key in list(env):
        if key.startswith(('STACK_', 'JAC_SERVE_', 'GOOGLE_', 'ADZUNA_', 'THEIRSTACK_', 'USAJOBS_')) or key in (
            'JAC_DB_URL', 'OPENAI_API_KEY', 'MODEL_API_KEY', 'ANTHROPIC_API_KEY', 'EXPO_ACCESS_TOKEN', 'GITHUB_TOKEN'):
            del env[key]
    _, runtime = configuration(root)
    env.update(JAC_SERVE_AUTH_SECRET=runtime['auth_secret'], JAC_SERVE_HOST='127.0.0.1',
               JAC_SERVE_WORKERS='1', JAC_SERVE_DOCS='false', JAC_SERVE_GRAPH='false',
               STACK_AGENT_CONFIG=str(root / 'storage/agents/config.json'),
               STACK_AGENT_WORKER_TOKEN=(root / 'storage/agents/worker-token').read_text().strip(),
               STACK_CONNECTION_KEY=runtime['connection_key'], STACK_WORKER_API=f'http://127.0.0.1:{api_port}',
               STACK_GATEWAY_BIND='127.0.0.1', STACK_GATEWAY_PORT=str(web_port))
    return env


def execute(root, command, env=None):
    subprocess.run(command, cwd=root, env=env, check=True)


def captured(command, env, root):
    try:
        result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=15)
        return result.returncode == 0, result.stdout + result.stderr
    except (OSError, subprocess.TimeoutExpired):
        return False, ''


def provider_check(provider, env, root):
    executable = shutil.which(provider, path=env['PATH'])
    if not executable:
        return False, f'Install {provider} in this Linux environment, then rerun make login.'
    subcommand, flags = FLAGS[provider]
    ok, output = captured([executable, '--version'], env, root)
    if not ok:
        return False, f'{provider} --version failed. Repair its Linux installation.'
    ok, output = captured([executable] + ([subcommand] if subcommand else []) + ['--help'], env, root)
    if not ok or any(flag not in output for flag in flags):
        return False, f'Upgrade {provider}: the required isolation/structured-output flags are unavailable. See docs/LOCAL_DEVELOPMENT.md.'
    return True, f'{provider} supports the required flags; sign-in and subscription capacity are checked when an explicitly requested task runs.'


def provider_auth(provider, env, root):
    executable = shutil.which(provider, path=env['PATH'])
    command = [executable, 'login', 'status'] if provider == 'codex' else [executable, 'auth', 'status']
    ok, output = captured(command, env, root)
    if provider == 'codex':
        return ok and 'Logged in using ChatGPT' in output
    try:
        data = json.loads(output) if ok else {}
        return data.get('loggedIn') is True and data.get('authMethod') in ('oauth', 'claude.ai') and data.get('apiProvider') == 'firstParty'
    except (ValueError, AttributeError):
        return False


def doctor(root, running=False, api_port=8000, web_port=8080):
    import bootstrap
    problems = []
    try:
        env = environment(root)
    except (OSError, ValueError, RuntimeError) as exc:
        # Values/JSON parse errors can contain private text. Report a fixed message.
        print('FAIL: Local configuration is missing, invalid, unsafe, or tracked. Run make setup, check JSON and private file permissions, and untrack runtime files.')
        env = bootstrap.environment(root)
        problems.append('configuration')
    checks = [('jac', [str(root / 'scripts/jac'), '--version'], 'jac 0.37.21 '),
              ('node', ['node', '--version'], 'v22.22.0'), ('tectonic', ['tectonic', '--version'], 'Tectonic 0.17.0'),
              ('postgres', [str(root / '.jac/tools/postgres/bin/postgres'), '--version'], '18.6')]
    for name, command, expected in checks:
        ok, output = captured(command, env, root)
        ok = ok and expected in output
        print(('OK' if ok else 'FAIL') + ': ' + name + (' version supported.' if ok else ' missing or incompatible; run make setup.'))
        if not ok:
            problems.append(name)
    for path in ('.jac/venv', '.jac/client/workspace/dist/index.html'):
        if not (root / path).exists():
            print('FAIL: Generated dependencies/UI missing; run make setup.')
            problems.append('build')
    for port in (api_port, web_port):
        with socket.socket() as probe:
            used = probe.connect_ex(('127.0.0.1', port)) == 0
        if used and not running:
            print(f'FAIL: Port {port} is occupied. Stop its local service or run doctor --running when Stack is active.')
            problems.append('port')
        elif not running:
            print(f'OK: Port {port} is available.')
    for provider in ('codex', 'claude'):
        ok, message = provider_check(provider, env, root)
        print('OPTIONAL: ' + message)
        try:
            configured = json.loads((root / 'storage/agents/config.json').read_text()).get('provider') == provider + '-cli'
        except (OSError, ValueError, AttributeError):
            configured = False
        if configured and not ok:
            problems.append(provider)
        elif configured and not provider_auth(provider, env, root):
            print(f'FAIL: {provider} subscription login is unavailable in this Linux environment. Run make login with your Account ID.')
            problems.append(provider + '-login')
    print('OPTIONAL: Docker browser, Google, paid job sources, sandbox and model subscription are not required for core development. See docs/LOCAL_DEVELOPMENT.md.')
    if problems:
        raise RuntimeError('Doctor found problems. Follow the fixes above before starting Stack.')


def rpc(url, name, args=None, token=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = Request(url + name, data=json.dumps(args or {}).encode(), headers=headers)
    with urlopen(request, timeout=15) as response:
        result = json.load(response)
    if not result.get('ok'):
        raise RuntimeError('A local health check failed.')
    value = result.get('data', {}).get('result', result.get('data', {}))
    if isinstance(value, dict) and value.get('error'):
        raise RuntimeError('A local authenticated health check was rejected.')
    return value


def wait(process, url, json_health=False):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('A local service exited. Inspect private .jac/logs/contributor-*.log.')
        try:
            if json_health:
                if rpc(url, '/function/health').get('status') == 'ok':
                    return
            else:
                with urlopen(url, timeout=2) as response:
                    if response.status == 200:
                        return
        except (OSError, ValueError):
            pass
        time.sleep(0.5)
    raise RuntimeError('Local services did not become ready. Inspect private .jac/logs/contributor-*.log.')


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def development(root, smoke=False, host='127.0.0.1', expose=False, api_port=8000, web_port=8080):
    if host not in ('127.0.0.1', 'localhost') and not expose:
        raise RuntimeError('Broader exposure requires --expose and an explicit --host. Use a trusted network.')
    if not 1024 <= api_port <= 65535 or not 1024 <= web_port <= 65535 or api_port == web_port:
        raise RuntimeError('Choose two different unprivileged service ports (1024-65535).')
    env = environment(root, api_port, web_port)
    api = f'http://127.0.0.1:{api_port}'
    web = f'http://127.0.0.1:{web_port}'
    if not (root / '.jac/client/workspace/dist/index.html').is_file():
        raise RuntimeError('Run make setup before development.')
    for port in (api_port, web_port):
        with socket.socket() as probe:
            if probe.connect_ex(('127.0.0.1', port)) == 0:
                raise RuntimeError(f'Port {port} is already occupied. Stop the existing local service.')
    # Keep the writer loopback even when the public browser gateway is explicitly exposed.
    env['STACK_GATEWAY_BIND'] = host
    logs = root / '.jac/logs'
    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    processes = []
    def start(name, arguments):
        path = logs / ('contributor-' + name + '.log')
        fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'a') as output:
            process = subprocess.Popen([str(root / 'scripts/jac'), 'run', *arguments], cwd=root,
                                       env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        processes.append(process)
        return process
    def interrupted(*_):
        raise KeyboardInterrupt
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        backend = start('api', ['--no-client', '--host', '127.0.0.1', '--workers', '1', '--port', str(api_port), 'Stack'])
        wait(backend, api, True)
        gateway = start('web', ['--no-serve', 'scripts/gateway-service.jac'])
        wait(gateway, web + '/')
        start('discovery', ['--no-serve', 'scripts/discovery-worker.jac'])
        start('agents', ['--no-serve', 'scripts/agent-worker.jac'])
        time.sleep(3)
        if any(process.poll() is not None for process in processes):
            raise RuntimeError('A worker failed to start. Inspect private .jac/logs/contributor-*.log.')
        # Validate authenticated worker RPCs without dispatching jobs or models.
        agent_token = env['STACK_AGENT_WORKER_TOKEN']
        rpc(api, '/function/agent_schedule', {'token': agent_token})
        discovery_token = (root / 'storage/discovery/worker-token').read_text().strip()
        rpc(api, '/function/discovery_analyze', {'token': discovery_token})
        print(f'Stack browser UI: http://{host}:{web_port}/\nBackend and workers ready. Logs are private under .jac/logs. Ctrl-C stops services.', flush=True)
        if smoke:
            # Keep only synthetic smoke credentials in ignored, private storage so
            # the next run proves account/session persistence after repeat setup.
            fixture = root / 'storage/contributor/smoke.json'
            if fixture.exists():
                if fixture.is_symlink() or fixture.stat().st_mode & 0o077:
                    raise RuntimeError('The synthetic smoke fixture must be an ordinary mode-600 file.')
                smoke_account = json.loads(fixture.read_text())
                request = {'identity': {'type': 'username', 'value': smoke_account['identity']},
                           'credential': {'type': 'password', 'password': smoke_account['password']}}
                account = rpc(web, '/user/login', request)
                token = account['token']
                saved = rpc(web, '/function/prep_get', {'id': smoke_account['session']}, token)
                if saved['data']['answer'] != 'Synthetic contributor persistence check.':
                    raise RuntimeError('The stored synthetic practice session did not survive startup.')
            else:
                smoke_account = {'identity': 'onboarding-' + secrets.token_hex(8),
                                 'password': secrets.token_urlsafe(24)}
                request = {'identities': [{'type': 'username', 'value': smoke_account['identity']}],
                           'credential': {'type': 'password', 'password': smoke_account['password']}}
                account = rpc(web, '/user/register', request)
                token = account['token']
                session = rpc(web, '/function/prep_create', {'problem_id': 'project'}, token)
                session['data']['answer'] = 'Synthetic contributor persistence check.'
                rpc(web, '/function/prep_save', {'id': session['id'], 'revision': session['revision'],
                                               'data': session['data']}, token)
                smoke_account['session'] = session['id']
                private_file(fixture, json.dumps(smoke_account) + '\n')
            settings = rpc(web, '/function/agent_settings', token=token)
            if not settings.get('account_id'):
                raise RuntimeError('Browser account onboarding did not return an account ID.')
            rpc(web, '/function/prep_catalog', token=token)
            print('Synthetic browser signup/login, saved practice session, authenticated workspace, backend health and worker authentication passed. No model calls.', flush=True)
            return
        while True:
            time.sleep(1)
            if any(process.poll() is not None for process in processes):
                raise RuntimeError('A local service stopped. Inspect private .jac/logs/contributor-*.log.')
    except KeyboardInterrupt:
        pass
    finally:
        for process in reversed(processes):
            stop(process)
        signal.signal(signal.SIGTERM, previous)


def login(root, args):
    owner = str(UUID(args.owner))
    if not 1 <= args.daily_limit <= 100:
        raise RuntimeError('Choose a daily request limit from 1 to 100.')
    env = environment(root)
    ok, message = provider_check(args.provider, env, root)
    if not ok:
        raise RuntimeError(message)
    # Login runs with the same HOME/PATH as workers, using only the provider's own credential store.
    executable = shutil.which(args.provider, path=env['PATH'])
    execute(root, [executable, 'login'] if args.provider == 'codex' else [executable, 'auth', 'login'], env)
    if not provider_auth(args.provider, env, root):
        raise RuntimeError('Sign in with a supported subscription before binding a provider. API credentials are not used as fallback.')
    command = [str(root / 'scripts/jac'), 'run', '--no-serve', 'scripts/agent-admin.jac',
               'provider', '--provider', args.provider + '-cli', '--owner', owner, '--daily-limit', str(args.daily_limit)]
    execute(root, command, env)
    print('Provider bound to the specified local Stack account. In the browser Account page, explicitly enable Model permission, then restart make dev.')


def tests(root):
    env = environment(root)
    env.update(PYTHONPATH=str(root), JAC_TEST_JOBS='0')
    # All of these suites use synthetic data and mocked provider/network boundaries.
    for path in ('test_bootstrap.py', 'test_jac_launcher.py', 'test_contributor.py', 'test_gitignore.py', 'test_pdf_safety.py', 'test_fixture_provenance.py',
                 'test_matching.py', 'test_agent_providers.py', 'test_gateway.py'):
        execute(root, [str(root / 'scripts/jac'), 'run', '--no-serve', 'tests/' + path], env)
    execute(root, [str(root / 'scripts/jac'), 'test', 'tests/provider_workflow_tests.jac'], env)
    execute(root, ['node', 'tests/test_web_model_permission.cjs'], env)
    print('Offline contributor and provider checks passed; no real model requests.')


def clean(root):
    # An allowlist of disposable build output. Never remove caches containing PostgreSQL or storage.
    if (root / '.jac').is_symlink():
        raise RuntimeError('Refusing a symlinked runtime directory.')
    for name in ('.jac/client/workspace', '.jac/mobile-rn', '.jac/xcode-device'):
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to((root / '.jac').resolve()):
            raise RuntimeError('Refusing unsafe generated build path.')
        if path.exists():
            shutil.rmtree(path)
    print('Generated UI/native builds removed. Database, uploads, private settings and provider credentials preserved. Run make setup to rebuild.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('setup', 'test', 'clean'):
        commands.add_parser(name)
    doctor_parser = commands.add_parser('doctor')
    doctor_parser.add_argument('--running', action='store_true')
    doctor_parser.add_argument('--api-port', type=int, default=8000)
    doctor_parser.add_argument('--web-port', type=int, default=8080)
    dev = commands.add_parser('dev')
    dev.add_argument('--smoke', action='store_true')
    dev.add_argument('--host', default='127.0.0.1')
    dev.add_argument('--expose', action='store_true')
    dev.add_argument('--api-port', type=int, default=8000)
    dev.add_argument('--web-port', type=int, default=8080)
    auth = commands.add_parser('login')
    auth.add_argument('--provider', choices=('codex', 'claude'), required=True)
    auth.add_argument('--owner', required=True)
    auth.add_argument('--daily-limit', type=int, default=10)
    args = parser.parse_args()
    check_platform()
    if args.command == 'setup':
        initialize(ROOT)
        import bootstrap
        bootstrap.setup(ROOT)
        configuration(ROOT)
        print('Local setup ready. Run make doctor, then make dev. Existing private files and data were preserved.')
    elif args.command == 'doctor':
        doctor(ROOT, args.running, args.api_port, args.web_port)
    elif args.command == 'dev':
        development(ROOT, args.smoke, args.host, args.expose, args.api_port, args.web_port)
    elif args.command == 'login':
        login(ROOT, args)
    elif args.command == 'test':
        tests(ROOT)
    else:
        clean(ROOT)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError):
        print('Contributor command failed. Check tool installation, private JSON and permissions; inspect private logs for startup failures. No secret values are printed.', file=sys.stderr)
        sys.exit(1)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
