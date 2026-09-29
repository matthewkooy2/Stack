import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
from uuid import uuid4

spec = importlib.util.spec_from_file_location('preview_data', Path(__file__).resolve().parents[1] / 'scripts/preview_data.py')
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


def row(kind, owner, **values):
    ident = str(uuid4())
    return dict(id=ident, kind='NodeAnchor', arch_type=kind, arch_module='_jac_app_source.main',
                fingerprint='', root_id=owner, src=None, dst=None, undirected=False, format_version=1,
                version=0, props=dict(id=ident, root=owner, archetype=dict(
                    __type__=kind, __module__='_jac_app_source.main', **values)))


class PreviewData(unittest.TestCase):
    def setUp(self):
        self.owner = str(uuid4())
        self.memory = row('AgentMemory', self.owner, policy={'actions': ['send_email']}, revision=2,
                          facts=[{'value': 'Resume contents'}])

    def sanitize(self, rows):
        return preview.sanitize(rows, '_jac_app_source', '_jac_app_target', self.owner, 100)

    def test_namespace_only_changes_type_metadata(self):
        value = {'__type__': 'Profile', '__module__': '_jac_app_source.main',
                 'text': '_jac_app_source.main', 'notes': {'__module__': '_jac_app_source.main'}}
        updated = preview.remap(value, '_jac_app_source', '_jac_app_target')
        self.assertEqual(updated['__module__'], '_jac_app_target.main')
        self.assertEqual(updated['text'], value['text'])
        self.assertEqual(updated['notes'], value['notes'])

    def test_model_only_owner_permission_and_no_mutation(self):
        other = row('AgentMemory', str(uuid4()), revision=0)
        original = copy.deepcopy(self.memory)
        owner, guest = self.sanitize([self.memory, other])
        self.assertEqual(owner['props']['archetype']['policy']['actions'], ['model'])
        self.assertEqual(owner['props']['archetype']['policy']['expires_at'], 100 + 7 * 86400)
        self.assertFalse(guest['props']['archetype']['policy']['enabled'])
        self.assertEqual(owner['props']['archetype']['facts'], original['props']['archetype']['facts'])
        self.assertEqual(self.memory, original)

    def test_pending_work_and_external_connections_are_disabled(self):
        values = [self.memory, row('AgentRun', self.owner, status='running', artifacts={'result': 'keep'}, lease='secret'),
                  row('AgentRun', self.owner, status='completed'), row('AgentTicket', self.owner, state='queued'),
                  row('AgentConnection', self.owner, sealed='secret'), row('AgentNotification', self.owner, state='queued'),
                  row('AgentContact', self.owner, next_at=999)]
        result = [item['props']['archetype'] for item in self.sanitize(values)]
        self.assertEqual(result[1]['status'], 'blocked')
        self.assertEqual(result[1]['lease'], '')
        self.assertEqual(result[1]['artifacts'], {'result': 'keep'})
        self.assertEqual(result[2]['status'], 'completed')
        self.assertEqual(result[3]['state'], 'cancelled')
        self.assertEqual(result[4]['sealed'], '')
        self.assertEqual(result[4]['state'], 'disconnected')
        self.assertEqual(result[5]['state'], 'cancelled')
        self.assertEqual(result[6]['next_at'], 0)

    def test_push_devices_and_connecting_edges_removed(self):
        push = row('AgentPushDevice', self.owner, sealed='secret')
        edge = row('GenericEdge', self.owner)
        edge.update(src=self.owner, dst=push['id'])
        self.assertEqual(len(self.sanitize([self.memory, push, edge])), 1)

    def test_unknown_owner_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, 'no agent settings'):
            self.sanitize([])

    def test_config_drops_credentials_and_outbound_permissions(self):
        config = preview.preview_config(dict(provider='codex-cli', local_cli_owner=self.owner, local_cli_daily_limit=30,
                                             api_key='secret', action_daily_limits={'send_email': 10}, model='example'))
        self.assertEqual(config['local_cli_daily_limit'], 20)
        self.assertEqual(config['local_cli_owner'], self.owner.replace('-', ''))
        self.assertEqual(config['action_daily_limits'], {})
        self.assertEqual(config['model'], 'example')
        self.assertNotIn('api_key', config)
        with self.assertRaises(RuntimeError):
            preview.preview_config(dict(provider='openai'))

    def test_quota_survives_repeated_refreshes_and_is_linked_to_new_root(self):
        prior = row('AgentUsage', str(uuid4()), key='cli:today:codex-cli', actions=3, cents=0)
        prior['arch_module'] = '_jac_app_target.core.automation'
        rows = []
        preview.preserve_usage(rows, [prior], self.owner)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]['root_id'], self.owner)
        self.assertEqual(rows[1]['src'], self.owner)
        self.assertEqual(rows[1]['dst'], rows[0]['id'])
        rows[0]['props']['archetype']['actions'] = 8
        preview.preserve_usage(rows, [prior], self.owner)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]['props']['archetype']['actions'], 8)

    def test_symlink_data_and_self_refresh_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / 'main', Path(directory) / 'preview'
            source.mkdir(); target.mkdir()
            with self.assertRaises(RuntimeError):
                preview.check_paths(source, source)
            (target / '.jac').symlink_to(source, target_is_directory=True)
            with self.assertRaises(RuntimeError):
                preview.check_paths(source, target)

    def test_partial_cutover_restores_database_and_storage_without_deleting(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / 'main', Path(directory) / 'preview'
            for path in (source, target):
                (path / 'storage/agents').mkdir(parents=True)
            (source / 'storage/agents/config.json').write_text(json.dumps(dict(
                provider='codex-cli', local_cli_owner=self.owner, local_cli_daily_limit=20)))
            (target / 'storage/original').write_text('keep')
            refresh = preview.Refresh(source, target)
            refresh.backup.mkdir(parents=True)
            refresh.before, refresh.identities, refresh.resumes = '', '', {}
            with patch.object(refresh.source, 'idle'), patch.object(refresh.target, 'idle'), patch.object(refresh.target, 'rename') as rename:
                # The staged file tree is missing: fail after DB cutover and old storage move.
                with self.assertRaises(FileNotFoundError):
                    refresh.apply()
                refresh.rollback()
                self.assertEqual((target / 'storage/original').read_text(), 'keep')
                self.assertEqual(rename.call_count, 4)

    def test_cutover_invalidates_old_sessions_and_rollback_restores_key(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / 'main', Path(directory) / 'preview'
            (source / 'storage/agents').mkdir(parents=True)
            (source / 'storage/agents/config.json').write_text(json.dumps(dict(
                provider='codex-cli', local_cli_owner=self.owner, local_cli_daily_limit=20)))
            secret = target / '.jac/data/jwt_secret'
            secret.parent.mkdir(parents=True)
            secret.write_text('synthetic-old-key')
            refresh = preview.Refresh(source, target)
            (refresh.backup / 'new-storage').mkdir(parents=True)
            (refresh.backup / 'preview-jwt-secret').write_text('synthetic-old-key')
            refresh.before, refresh.identities, refresh.resumes = '', '', {}
            with patch.object(refresh.source, 'idle'), patch.object(refresh.target, 'idle'), patch.object(refresh.target, 'rename'):
                refresh.apply()
                self.assertNotEqual(secret.read_text(), 'synthetic-old-key')
                self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
                refresh.rollback()
                self.assertEqual(secret.read_text(), 'synthetic-old-key')

    def test_new_worktree_initializes_database_without_starting_api(self):
        db = preview.Database(Path('/local/feature'))
        with patch.object(preview.subprocess, 'run', return_value=Mock(returncode=0)) as run:
            db.ensure()
        self.assertEqual(run.call_args.args[0], ['/local/feature/scripts/jac', 'db', 'sql', 'SELECT 1'])
        self.assertEqual(run.call_args.kwargs['cwd'], Path('/local/feature'))


class CliReadiness(unittest.TestCase):
    def check(self, provider, result):
        with patch.object(preview.shutil, 'which', return_value='/local/cli'), \
             patch.object(preview.subprocess, 'run', return_value=result) as run:
            preview.check_cli({'provider': provider}, Path('/local/preview'))
            return run.call_args

    def test_codex_accepts_subscription_reported_on_stderr_and_strips_api_keys(self):
        with patch.dict(os.environ, {'OPENAI_API_KEY': 'synthetic', 'CODEX_HOME': '/local/auth'}):
            args = self.check('codex-cli', Mock(returncode=0, stdout='', stderr='Logged in using ChatGPT'))
        self.assertEqual(args.args[0], ['/local/cli', 'login', 'status'])
        self.assertNotIn('OPENAI_API_KEY', args.kwargs['env'])
        self.assertEqual(args.kwargs['env']['CODEX_HOME'], '/local/auth')

    def test_codex_rejects_api_login(self):
        with self.assertRaisesRegex(RuntimeError, 'codex login'):
            self.check('codex-cli', Mock(returncode=0, stdout='Logged in using an API key', stderr=''))

    def test_claude_checks_subscription_method_and_provider(self):
        self.check('claude-cli', Mock(returncode=0, stdout=json.dumps(dict(
            loggedIn=True, authMethod='oauth', apiProvider='firstParty'))))
        with self.assertRaisesRegex(RuntimeError, 'claude auth login'):
            self.check('claude-cli', Mock(returncode=0, stdout=json.dumps(dict(
                loggedIn=True, authMethod='api_key', apiProvider='firstParty'))))

    def test_missing_executable_and_timeout_fail_without_private_output(self):
        with patch.object(preview.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(RuntimeError, 'missing from PATH'):
                preview.check_cli({'provider': 'codex-cli'}, Path('/local/preview'))
        with patch.object(preview.shutil, 'which', return_value='/local/cli'), \
             patch.object(preview.subprocess, 'run', side_effect=preview.subprocess.TimeoutExpired('cli', 15)):
            with self.assertRaisesRegex(RuntimeError, 'Could not verify'):
                preview.check_cli({'provider': 'codex-cli'}, Path('/local/preview'))


@unittest.skipUnless(os.environ.get('STACK_TEST_PG_WORKTREE'), 'Requires an explicit local PostgreSQL test host')
class PostgreSQLImport(unittest.TestCase):
    def test_copy_and_atomic_rename_in_disposable_database(self):
        db = preview.Database(Path(os.environ['STACK_TEST_PG_WORKTREE']))
        name = 'stack_refresh_test_' + uuid4().hex[:12]
        renamed = name + '_renamed'
        db.sql(f'CREATE DATABASE "{name}";', 'postgres')
        try:
            db.sql('CREATE TABLE anchors (id uuid PRIMARY KEY, kind text NOT NULL, arch_type text NOT NULL, '
                   'arch_module text NOT NULL, fingerprint text NOT NULL, root_id uuid, src uuid, dst uuid, '
                   'undirected boolean NOT NULL, props jsonb NOT NULL, format_version integer, version bigint); '
                   'CREATE TABLE jac_outbox (id text); CREATE TABLE jac_outbox_seen (id text); '
                   "INSERT INTO jac_outbox VALUES ('pending');", name)
            value = row('Profile', str(uuid4()), text='Quotes: "hello"\nTwo lines \\ slash', empty='')
            preview.replace_rows(db, name, [value])
            actual = db.rows('SELECT row_to_json(a) FROM anchors a;', name)
            self.assertEqual(actual, [value])
            self.assertEqual(db.sql('SELECT count(*) FROM jac_outbox;', name), '0')
            db.rename(name, renamed)
            db.rename(renamed, name)
            self.assertEqual(db.sql('SELECT count(*) FROM anchors;', name), '1')
        finally:
            # Only these uniquely named, synthetic test databases are removed.
            db.sql(f'DROP DATABASE IF EXISTS "{name}"; DROP DATABASE IF EXISTS "{renamed}";', 'postgres')


if __name__ == '__main__':
    unittest.main()
