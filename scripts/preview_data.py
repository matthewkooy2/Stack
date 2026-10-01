"""Stopped-writer account snapshots for local phone previews (Jac 0.37.21)."""
import copy
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile
import time
from uuid import UUID, uuid4


def namespace(path):
    return '_jac_app_' + hashlib.sha256(str(path / 'main.jac').encode()).hexdigest()[:16]


def remap(value, source, target):
    if isinstance(value, list):
        return [remap(item, source, target) for item in value]
    if not isinstance(value, dict):
        return value
    result = {key: remap(item, source, target) for key, item in value.items()}
    module = result.get('__module__', '')
    if '__type__' in result and module.startswith(source + '.'):
        result['__module__'] = target + module[len(source):]
    return result


def preview_config(raw):
    if raw.get('provider') not in ('codex-cli', 'claude-cli') or not raw.get('local_cli_owner'):
        raise RuntimeError('Main must have a local CLI subscription linked to an account before refresh.')
    if not 1 <= int(raw.get('local_cli_daily_limit', 0)) <= 100:
        raise RuntimeError('Main needs a valid local CLI request limit.')
    return dict(provider=raw['provider'], local_cli_owner=UUID(raw['local_cli_owner']).hex,
                local_cli_daily_limit=min(20, int(raw['local_cli_daily_limit'])),
                model=str(raw.get('model', '')), capture_agent_content=bool(raw.get('capture_agent_content')),
                monthly_cents=0, user_monthly_cents=0, action_daily_limits={},
                certified_adapters=[], sandbox_available=False)


def check_cli(config, directory):
    """Check the existing Mac subscription in the same environment as the worker."""
    provider = config['provider']
    name = 'codex' if provider == 'codex-cli' else 'claude'
    executable = shutil.which(name)
    if not executable:
        raise RuntimeError(f'{name} CLI is missing from PATH; current preview is unchanged.')
    env = {k: v for k, v in os.environ.items() if k in (
        'PATH', 'HOME', 'USER', 'TMPDIR', 'LANG', 'LC_ALL', 'CODEX_HOME',
        'SSL_CERT_FILE', 'SSL_CERT_DIR', 'CODEX_CA_CERTIFICATE')}
    command = [executable, 'login', 'status'] if name == 'codex' else [executable, 'auth', 'status']
    try:
        result = subprocess.run(command, cwd=directory, env=env, capture_output=True, text=True, timeout=15)
        if name == 'codex':
            signed_in = result.returncode == 0 and 'Logged in using ChatGPT' in result.stdout + result.stderr
        else:
            auth = json.loads(result.stdout) if result.returncode == 0 else {}
            signed_in = (auth.get('loggedIn') and auth.get('authMethod') in ('oauth', 'claude.ai')
                         and auth.get('apiProvider') == 'firstParty')
    except (OSError, subprocess.TimeoutExpired, ValueError):
        raise RuntimeError(f'Could not verify {name} subscription sign-in; current preview is unchanged.') from None
    if not signed_in:
        login = 'codex login' if name == 'codex' else 'claude auth login'
        raise RuntimeError(f'Sign in to your Mac subscription with {login}; current preview is unchanged.')


def sanitize(rows, source, target, owner, now):
    """Keep history/content, but never replay imported work or credentials."""
    rows = copy.deepcopy(rows)
    removed = {r['id'] for r in rows if r['arch_type'] == 'AgentPushDevice'}
    found = False
    for row in rows:
        row['props'] = remap(row['props'], source, target)
        if row['arch_module'].startswith(source + '.'):
            row['arch_module'] = target + row['arch_module'][len(source):]
        data = row['props'].get('archetype', {})
        kind = row['arch_type']
        if kind == 'AgentMemory':
            enabled = UUID(row['root_id']).hex == UUID(owner).hex
            found |= enabled
            data['policy'] = dict(enabled=enabled, actions=['model'] if enabled else [],
                                  expires_at=now + 7 * 86400 if enabled else 0,
                                  domains=[], daily_limits={}, followup_limit=0,
                                  followup_days=7, analyze_top_matches=False)
            data['revision'] = data.get('revision', 0) + 1
        elif kind == 'AgentRun':
            data.update(lease='', lease_until=0, next_at=0, approvals={}, review={}, ticket_hash='')
            if data.get('status') not in ('completed', 'cancelled', 'failed'):
                data.update(status='blocked', message='Copied from main for preview; resume explicitly to test.')
        elif kind == 'AgentTicket':
            data.update(state='cancelled', due_at=0)
        elif kind == 'AgentConnection':
            data.update(sealed='', scopes=[], state='disconnected', checkpoint='', calendar_id='')
        elif kind == 'AgentNotification':
            data['state'] = 'cancelled'
        elif kind == 'AgentContact':
            data['next_at'] = 0
    if not found:
        raise RuntimeError('The linked main account has no agent settings; preview was not replaced.')
    return [r for r in rows if r['id'] not in removed and r['src'] not in removed and r['dst'] not in removed]


def preserve_usage(rows, previous, shared_root):
    """Refreshing cannot replenish this preview's already consumed quota."""
    existing = {r['props']['archetype']['key']: r for r in rows if r['arch_type'] == 'AgentUsage'}
    for old in previous:
        if old['arch_type'] != 'AgentUsage':
            continue
        values = old['props']['archetype']
        current = existing.get(values['key'])
        if current:
            for field in ('actions', 'cents'):
                current['props']['archetype'][field] = max(current['props']['archetype'][field], values[field])
            continue
        node = copy.deepcopy(old)
        node_id, edge_id = str(uuid4()), str(uuid4())
        node.update(id=node_id, root_id=shared_root)
        node['props'].update(id=node_id, root=shared_root, access=None, edges=[])
        edge = dict(id=edge_id, kind='EdgeAnchor', arch_type='GenericEdge',
                    arch_module='jaclang.runtime.archetype', fingerprint='', root_id=shared_root,
                    src=shared_root, dst=node_id, undirected=False, format_version=1, version=0,
                    props=dict(id=edge_id, root=shared_root, access=None, source=shared_root,
                               target=node_id, __type__='EdgeAnchor', __module__='jaclang.runtime.archetype',
                               persistent=True, is_undirected=False,
                               archetype=dict(__type__='GenericEdge', __module__='jaclang.runtime.archetype')))
        rows.extend([node, edge])
        existing[values['key']] = node


class Database:
    def __init__(self, path):
        self.path = path
        data = path / '.jac/tool-cache/pg/main'
        self.name = 'jac_stack_' + hashlib.sha1(str(path).encode()).hexdigest()[:8]
        self.env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
        self.env.update(PGHOST=str(Path(tempfile.gettempdir()) / ('jacpg-' + hashlib.sha1(str(data).encode()).hexdigest()[:10])),
                        PGPORT='5432', PGUSER='jac', PGDATABASE=self.name, PGCONNECT_TIMEOUT='5')

    def run(self, tool, *args, input=None, database=None):
        executable = shutil.which(tool) or str(Path('/opt/homebrew/opt/postgresql@16/bin') / tool)
        result = subprocess.run([executable, *args], env={**self.env, 'PGDATABASE': database or self.name},
                                input=input, text=True, capture_output=True)
        if result.returncode:
            # SQL errors can contain private COPY rows; never echo those into shared logs.
            raise RuntimeError(f'{tool} failed for {self.path.name}; database/files were retained. Check local PostgreSQL availability.')
        return result.stdout

    def ensure(self):
        # Jac owns cluster initialization and version selection, including on a
        # brand-new checkout. This opens no API or workers and makes no model call.
        try:
            result = subprocess.run([str(self.path / 'scripts/jac'), 'db', 'sql', 'SELECT 1'],
                                    cwd=self.path, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f'Local PostgreSQL initialization timed out for {self.path.name}; preview data was retained.') from None
        if result.returncode:
            raise RuntimeError(f'Could not initialize local PostgreSQL for {self.path.name}; preview data was retained.')

    def sql(self, query, database=None):
        return self.run('psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', input=query, database=database).strip()

    def rows(self, query, database=None):
        return [json.loads(line) for line in self.sql(query, database).splitlines() if line]

    def idle(self):
        count = self.sql("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid();")
        if count != '0':
            raise RuntimeError(f'{self.path.name} has another database connection. Stop its test/API writers before refreshing.')

    def rename(self, old, new):
        if not all(re.fullmatch(r'[a-z0-9_]+', value) for value in (old, new)):
            raise RuntimeError('Invalid database name.')
        self.sql(f'ALTER DATABASE "{old}" RENAME TO "{new}";', 'postgres')


def files_digest(path):
    result = {}
    if path.is_symlink():
        raise RuntimeError(f'Refusing symlink in private snapshot data: {path}')
    if path.exists():
        for item in sorted(path.rglob('*')):
            if item.is_symlink():
                raise RuntimeError(f'Refusing symlink in private snapshot data: {item}')
            if item.is_file():
                with item.open('rb') as stream:
                    result[str(item.relative_to(path))] = hashlib.file_digest(stream, 'sha256').hexdigest()
    return result


def check_paths(source, target):
    if source.resolve() == target.resolve():
        raise RuntimeError('Cannot refresh main from itself.')
    for path in (source, target):
        for suffix in ('.jac', '.jac/data', '.jac/data/jwt_secret', '.jac/tool-cache', '.jac/tool-cache/pg', '.jac/tool-cache/pg/main',
                       '.jac/preview-backups', 'storage'):
            item = path / suffix
            if item.is_symlink() or not item.resolve().is_relative_to(path.resolve()):
                raise RuntimeError(f'Refusing shared/symlinked private data: {item}')
    for key in ('JAC_DB_URL', 'STACK_AGENT_CONFIG', 'STACK_AGENT_WORKER_TOKEN'):
        if os.environ.get(key):
            raise RuntimeError(f'Unset {key} before refreshing local preview data.')


def replace_rows(db, name, rows):
    columns = 'id,kind,arch_type,arch_module,fingerprint,root_id,src,dst,undirected,props,format_version,version'
    stream = io.StringIO()
    writer = csv.writer(stream, lineterminator='\n')
    for row in rows:
        writer.writerow([json.dumps(row['props']) if key == 'props' else
                         ('\\N' if row.get(key) is None else row[key]) for key in columns.split(',')])
    db.sql('BEGIN; DELETE FROM anchors;\n' + f"COPY anchors ({columns}) FROM STDIN WITH (FORMAT csv, NULL '\\N');\n" +
           stream.getvalue() + '\\.\n' +
           'DELETE FROM jac_outbox; DELETE FROM jac_outbox_seen; COMMIT;', name)


class Refresh:
    """Stage everything before cutover; retain both old DB and private file backup."""
    def __init__(self, source, target):
        check_paths(source, target)
        self.source, self.target = Database(source), Database(target)
        self.config = preview_config(json.loads((source / 'storage/agents/config.json').read_text()))
        tag = time.strftime('%Y%m%d-%H%M%S') + '-' + uuid4().hex[:6]
        self.backup = target / '.jac/preview-backups' / tag
        self.staged = 'stack_preview_' + uuid4().hex[:12]
        self.old = 'stack_previous_' + uuid4().hex[:12]
        self.db_swapped = self.files_swapped = False
        self.secret_swapped = False
        self.had_storage = (target / 'storage').exists()

    def prepare(self):
        self.source.ensure()
        self.target.ensure()
        self.source.idle()
        self.target.idle()
        self.backup.mkdir(parents=True, mode=0o700)
        self.backup.chmod(0o700)
        for db, filename in ((self.source, 'main.dump'), (self.target, 'preview.dump')):
            db.run('pg_dump', '--format=custom', '--file', str(self.backup / filename))
            (self.backup / filename).chmod(0o600)
            db.run('pg_restore', '--list', str(self.backup / filename))
        previous = self.target.rows("SELECT row_to_json(a) FROM anchors a WHERE arch_type='AgentUsage';")
        self.target.sql(f'CREATE DATABASE "{self.staged}";', 'postgres')
        self.target.run('pg_restore', '--exit-on-error', '--no-owner', '--dbname', self.staged, str(self.backup / 'main.dump'))
        identities = self.target.rows('SELECT doc FROM identity_users;', self.staged)
        if not any(UUID(item['root_id']).hex == UUID(self.config['local_cli_owner']).hex for item in identities):
            raise RuntimeError('Linked main account is missing from the snapshot.')
        shared = [str(UUID(item['root_id'])) for item in identities if item.get('role') == 'system']
        if len(shared) != 1:
            raise RuntimeError('Cannot identify the Jac shared root. Preview was not replaced.')
        rows = self.target.rows('SELECT row_to_json(a) FROM anchors a;', self.staged)
        rows = sanitize(rows, namespace(self.source.path), namespace(self.target.path), self.config['local_cli_owner'], time.time())
        preserve_usage(rows, previous, shared[0])
        replace_rows(self.target, self.staged, rows)
        if int(self.target.sql('SELECT count(*) FROM anchors;', self.staged)) != len(rows):
            raise RuntimeError('Snapshot graph verification failed.')
        self.before = self.source.sql("SELECT md5(string_agg(row_to_json(a)::text, '' ORDER BY id)) FROM anchors a;")
        self.identities = self.source.sql("SELECT md5(string_agg(doc::text, '' ORDER BY user_id)) FROM identity_users;")
        if self.target.sql("SELECT md5(string_agg(doc::text, '' ORDER BY user_id)) FROM identity_users;", self.staged) != self.identities:
            raise RuntimeError('Snapshot account verification failed.')
        staged_storage = self.backup / 'new-storage'
        (staged_storage / 'agents').mkdir(parents=True, mode=0o700)
        resumes = self.source.path / 'storage/resumes'
        self.resumes = files_digest(resumes)
        if resumes.exists():
            shutil.copytree(resumes, staged_storage / 'resumes')
        if files_digest(staged_storage / 'resumes') != self.resumes:
            raise RuntimeError('Resume copy verification failed.')
        config_path = staged_storage / 'agents/config.json'
        config_path.write_text(json.dumps(self.config, indent=2) + '\n')
        config_path.chmod(0o600)
        # Keep the old key only for rollback. A replaced account database must
        # invalidate sessions belonging to the previous preview's identities.
        secret = self.target.path / '.jac/data/jwt_secret'
        if secret.exists():
            shutil.copy2(secret, self.backup / 'preview-jwt-secret')
            (self.backup / 'preview-jwt-secret').chmod(0o600)
        self.write_manifest('prepared')

    def write_manifest(self, state):
        (self.backup / 'manifest.json').write_text(json.dumps(dict(state=state, source=str(self.source.path),
            target=str(self.target.path), previous_database=self.old, staged_database=self.staged,
            database=self.target.name, source_graph_digest=self.before, source_identity_digest=self.identities,
            resume_checksums=self.resumes), indent=2) + '\n')

    def apply(self):
        self.source.idle()
        self.target.idle()
        self.target.rename(self.target.name, self.old)
        try:
            self.target.rename(self.staged, self.target.name)
        except Exception:
            self.target.rename(self.old, self.target.name)
            raise
        self.db_swapped = True
        storage = self.target.path / 'storage'
        if self.had_storage:
            storage.rename(self.backup / 'previous-storage')
        self.files_swapped = True
        (self.backup / 'new-storage').rename(storage)
        secret = self.target.path / '.jac/data/jwt_secret'
        secret.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', dir=secret.parent, prefix='jwt_secret-', delete=False) as stream:
            stream.write(secrets.token_hex(32))
        Path(stream.name).replace(secret)
        self.secret_swapped = True
        self.write_manifest('applied')

    def rollback(self):
        if self.secret_swapped:
            secret = self.target.path / '.jac/data/jwt_secret'
            original = self.backup / 'preview-jwt-secret'
            if original.exists():
                shutil.copy2(original, secret)
            else:
                secret.unlink()
            self.secret_swapped = False
        if self.db_swapped:
            self.target.idle()
            self.target.rename(self.target.name, self.staged)
            self.target.rename(self.old, self.target.name)
            self.db_swapped = False
        if self.files_swapped:
            storage = self.target.path / 'storage'
            if storage.exists():
                storage.rename(self.backup / 'failed-storage')
            if self.had_storage:
                (self.backup / 'previous-storage').rename(storage)
            self.files_swapped = False
        if hasattr(self, 'before'):
            self.write_manifest('rolled-back')

    def finish(self):
        if (self.source.sql("SELECT md5(string_agg(row_to_json(a)::text, '' ORDER BY id)) FROM anchors a;") != self.before
                or self.source.sql("SELECT md5(string_agg(doc::text, '' ORDER BY user_id)) FROM identity_users;") != self.identities
                or files_digest(self.source.path / 'storage/resumes') != self.resumes):
            raise RuntimeError('Main changed during the refresh; preview will be rolled back.')
        self.write_manifest('verified')
        print(f'Preview refreshed. Private backup: {self.backup}', flush=True)
