"""Synthetic contributor security and lifecycle checks; never use operator credentials."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('stack_contributor', ROOT / 'scripts/contributor.py')
contributor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contributor)


class Contributor(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='stack-contributor-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(['git', 'init', '--quiet', '--template=', str(self.root)], check=True, capture_output=True)
        (self.root / 'deploy').mkdir()
        (self.root / 'deploy/agent-config.example.json').write_text((ROOT / 'deploy/agent-config.example.json').read_text())
        (self.root / '.gitignore').write_bytes((ROOT / '.gitignore').read_bytes())
        contributor.initialize(self.root)

    def test_fresh_initialization_and_repeat_preserve_every_private_byte(self):
        config, runtime = contributor.configuration(self.root)
        self.assertFalse(config['invite_only'])
        self.assertEqual(config['monthly_cents'], 0)
        self.assertFalse(config['capture_agent_content'])
        self.assertEqual(config['local_cli_owner'], '')
        paths = list((self.root / 'storage').rglob('*'))
        before = {str(p): p.read_bytes() for p in paths if p.is_file()}
        contributor.initialize(self.root)
        self.assertEqual(before, {str(p): p.read_bytes() for p in paths if p.is_file()})
        self.assertNotIn(runtime['auth_secret'], (self.root / '.gitignore').read_text())
        result = subprocess.run(['git', 'status', '--porcelain'], cwd=self.root, check=True, capture_output=True, text=True)
        self.assertNotIn('storage', result.stdout)

    def test_tracked_runtime_paths_fail_before_new_secrets_are_generated(self):
        subprocess.run(['git', 'add', '-f', 'storage/agents/worker-token'], cwd=self.root, check=True)
        with self.assertRaisesRegex(RuntimeError, 'tracked'):
            contributor.initialize(self.root)
        with self.assertRaisesRegex(RuntimeError, 'tracked'):
            contributor.configuration(self.root)

    @unittest.skipIf(os.name == 'nt', 'Linux file permission boundary')
    def test_credentials_private_from_creation_and_unsafe_modes_rejected(self):
        for path in (self.root / 'storage').rglob('*'):
            self.assertFalse(path.stat().st_mode & 0o077)
        path = self.root / 'storage/contributor/runtime.json'
        path.chmod(0o644)
        with self.assertRaisesRegex(RuntimeError, 'mode 600'):
            contributor.configuration(self.root)

    @unittest.skipIf(os.name == 'nt', 'Linux symlink boundary')
    def test_private_symlink_is_not_followed(self):
        path = self.root / 'storage/agents/worker-token'
        path.unlink()
        destination = self.root / 'unrelated-secret'
        destination.write_text('synthetic-private-marker')
        path.symlink_to(destination)
        with self.assertRaises(RuntimeError):
            contributor.initialize(self.root)
        self.assertEqual(destination.read_text(), 'synthetic-private-marker')

    def test_clean_preserves_account_database_uploads_keys_and_logs(self):
        preserve = ('.jac/tool-cache/pg/main/account', 'storage/resumes/upload.pdf',
                    '.jac/logs/contributor-api.log', '.jac/tools/jac', '.jac/venv/sentinel')
        for name in preserve:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('persistent-synthetic-data')
        for name in ('.jac/client/workspace/dist/index.html', '.jac/mobile-rn/build', '.jac/xcode-device/build'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('generated')
        contributor.clean(self.root)
        for name in preserve:
            self.assertEqual((self.root / name).read_text(), 'persistent-synthetic-data')
        self.assertFalse((self.root / '.jac/client/workspace').exists())
        contributor.configuration(self.root)

    def test_inherited_production_config_and_api_keys_are_removed(self):
        inherited = {'PATH': os.environ['PATH'], 'HOME': str(self.root), 'JAC_DB_URL': 'synthetic-production-url',
                     'STACK_AGENT_CONFIG': 'private-production-config', 'OPENAI_API_KEY': 'synthetic-api-key',
                     'GOOGLE_CLIENT_SECRET': 'synthetic-google-secret', 'ANTHROPIC_API_KEY': 'synthetic-paid-key'}
        bootstrap = types.SimpleNamespace(environment=lambda root: dict(inherited))
        with patch.dict(sys.modules, {'bootstrap': bootstrap}):
            env = contributor.environment(self.root)
        for key in ('JAC_DB_URL', 'OPENAI_API_KEY', 'GOOGLE_CLIENT_SECRET', 'ANTHROPIC_API_KEY'):
            self.assertNotIn(key, env)
        self.assertEqual(env['JAC_SERVE_HOST'], '127.0.0.1')
        self.assertEqual(env['JAC_SERVE_WORKERS'], '1')
        self.assertEqual(env['STACK_AGENT_CONFIG'], str(self.root / 'storage/agents/config.json'))
        self.assertEqual(env['HOME'], str(self.root))

    def test_doctor_redacts_malformed_configuration(self):
        marker = 'synthetic-private-error-content'
        (self.root / 'storage/agents/config.json').write_text(marker)
        bootstrap = types.SimpleNamespace(environment=lambda root: {'PATH': os.environ['PATH']})
        output = io.StringIO()
        with patch.dict(sys.modules, {'bootstrap': bootstrap}), patch.object(contributor, 'captured', return_value=(False, marker)), contextlib.redirect_stdout(output):
            with self.assertRaises(RuntimeError):
                contributor.doctor(self.root)
        self.assertNotIn(marker, output.getvalue())
        self.assertIn('configuration', output.getvalue())
        self.assertIn('make setup', output.getvalue())

    def test_provider_requires_isolation_flags_without_model_request(self):
        for provider in ('codex', 'claude'):
            command, flags = contributor.FLAGS[provider]
            calls = []
            def fake_capture(argv, env, root):
                calls.append(argv)
                return True, 'supported version' if '--version' in argv else ' '.join(flags)
            with patch.object(contributor.shutil, 'which', return_value='/synthetic/' + provider), patch.object(contributor, 'captured', side_effect=fake_capture):
                self.assertTrue(contributor.provider_check(provider, {'PATH': ''}, self.root)[0])
            self.assertTrue(all('--version' in argv or '--help' in argv for argv in calls))
            with patch.object(contributor.shutil, 'which', return_value='/synthetic/' + provider), patch.object(contributor, 'captured', return_value=(True, 'unsupported old version')):
                self.assertFalse(contributor.provider_check(provider, {'PATH': ''}, self.root)[0])

    def test_existing_deployment_override_is_preserved_and_refused(self):
        path = self.root / 'jac.local.toml'
        value = '[scale.database]\nurl="synthetic-production-database"\n'
        path.write_text(value)
        with self.assertRaisesRegex(RuntimeError, 'jac.local.toml'):
            contributor.initialize(self.root)
        with self.assertRaisesRegex(RuntimeError, 'jac.local.toml'):
            contributor.configuration(self.root)
        self.assertEqual(path.read_text(), value)

    def test_auth_probe_accepts_subscription_and_rejects_api_without_printing(self):
        for provider, accepted, rejected in (
            ('codex', 'Logged in using ChatGPT', 'Logged in using an API key'),
            ('claude', json.dumps({'loggedIn': True, 'authMethod': 'oauth', 'apiProvider': 'firstParty'}),
             json.dumps({'loggedIn': True, 'authMethod': 'api_key', 'apiProvider': 'firstParty'})),
        ):
            with patch.object(contributor.shutil, 'which', return_value='/synthetic/' + provider):
                with patch.object(contributor, 'captured', return_value=(True, accepted)):
                    self.assertTrue(contributor.provider_auth(provider, {'PATH': ''}, self.root))
                with patch.object(contributor, 'captured', return_value=(True, rejected)):
                    self.assertFalse(contributor.provider_auth(provider, {'PATH': ''}, self.root))

    def test_network_exposure_requires_explicit_choice(self):
        with self.assertRaisesRegex(RuntimeError, '--expose'):
            contributor.development(self.root, host='0.0.0.0')


if __name__ == '__main__':
    unittest.main()
