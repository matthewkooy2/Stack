"""Provider boundaries and subscription accounting; no live model calls."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from agents import contracts, local_cli, provider, worker


REPORT = {'summary': 'Relevant project experience.', 'strengths': ['Built a tracker'],
          'gaps': [], 'unknowns': [], 'evidence': [
              {'source': 'fact:resume.project', 'quote': 'Built a tracker', 'claim': 'Has project experience'}]}
CONTEXT = {'facts': [{'key': 'resume.project', 'value': 'Built a tracker', 'verified': True}]}


class Providers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'config.json'
        self.env = patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(self.path)})
        self.env.start();self.addCleanup(self.env.stop)

    def configure(self, **changes):
        self.path.write_text(json.dumps(changes))
        return contracts.config()

    def test_default_api_remains_disabled(self):
        self.assertFalse(contracts.model_status('owner')['configured'])
        self.assertEqual(contracts.config()['provider'], 'openai')

    def test_subscription_requires_owner_and_cap_but_not_money(self):
        c = self.configure(provider='codex-cli', local_cli_owner='alice', local_cli_daily_limit=5)
        contracts.model_access(c, 'alice')
        self.assertTrue(contracts.model_status('alice')['configured'])
        self.assertEqual(contracts.model_status('alice')['billing'], 'subscription')
        for owner in ('', 'bob'):
            with self.assertRaises(ValueError): contracts.model_access(c, owner)
        for cap in (0, -1, 101):
            with self.assertRaises(ValueError): contracts.model_access({**c, 'local_cli_daily_limit': cap}, 'alice')
        with self.assertRaises(ValueError): contracts.reserve_cents(CONTEXT)

    def test_api_prices_and_budgets_still_required(self):
        for name in ('openai', 'meta', 'invalid'):
            c = self.configure(provider=name, model='test')
            with self.assertRaises(ValueError): contracts.model_access(c, 'alice')

    def test_subscription_owner_accepts_both_uuid_formats(self):
        owner, other = uuid4(), uuid4()
        for stored, requested in ((str(owner), owner.hex), (owner.hex, str(owner))):
            c = self.configure(provider='codex-cli', local_cli_owner=stored, local_cli_daily_limit=20)
            contracts.model_access(c, requested)
            self.assertTrue(contracts.model_status(requested)['configured'])
            with self.assertRaises(ValueError):
                contracts.model_access(c, other.hex)

    def test_subscription_has_no_http_fallback_or_dollar_estimate(self):
        self.configure(provider='codex-cli')
        with patch.object(local_cli, 'generate', return_value=REPORT), patch.object(provider, 'http') as http:
            result = provider.generate('fit', CONTEXT)
        self.assertEqual(result['artifact'], REPORT)
        self.assertEqual(result['cost_cents'], 0)
        http.assert_not_called()
        with patch.object(local_cli, 'generate', side_effect=ValueError('Limit reached')), patch.object(provider, 'http') as http:
            with self.assertRaisesRegex(ValueError, 'Limit reached'): provider.generate('fit', CONTEXT)
        http.assert_not_called()

    def test_all_providers_keep_source_validation(self):
        bad = {**REPORT, 'evidence': [{'source': 'fact:resume.project', 'quote': 'Invented work', 'claim': 'False'}]}
        for name in ('codex-cli', 'claude-cli'):
            self.configure(provider=name)
            with patch.object(local_cli, 'generate', return_value=bad):
                with self.assertRaisesRegex(ValueError, 'validated'): provider.generate('fit', CONTEXT)

    def test_meta_uses_own_key_and_structured_output(self):
        self.configure(provider='meta', model='muse-test', input_cents_per_million=100, output_cents_per_million=500)
        result = {'choices': [{'finish_reason': 'stop', 'message': {'content': json.dumps(REPORT)}}],
                  'usage': {'prompt_tokens': 100, 'completion_tokens': 100}, 'id': 'meta-result'}
        with patch.dict(os.environ, {'MODEL_API_KEY': 'meta-secret', 'OPENAI_API_KEY': 'wrong-secret'}), patch.object(provider, 'http', return_value=result) as http:
            value = provider.generate('fit', CONTEXT)
        url, payload, headers = http.call_args.args
        self.assertEqual(url, 'https://api.meta.ai/v1/chat/completions')
        self.assertEqual(headers['Authorization'], 'Bearer meta-secret')
        self.assertEqual(payload['response_format']['json_schema']['schema'], provider.SCHEMAS['fit'])
        self.assertEqual(value['provider_id'], 'meta-result')
        self.assertGreater(value['cost_cents'], 0)

    def test_cli_environment_drops_secrets_and_provider_overrides(self):
        secret_names = ('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'MODEL_API_KEY', 'CODEX_API_KEY',
                        'ANTHROPIC_BASE_URL', 'STACK_AGENT_WORKER_TOKEN', 'CLAUDE_CODE_USE_BEDROCK')
        with patch.dict(os.environ, {**{k: 'secret' for k in secret_names}, 'USER': 'local-owner'}):
            env = local_cli.environment()
        self.assertFalse(set(secret_names) & set(env))
        self.assertIn('HOME', env)
        self.assertEqual(env['USER'], 'local-owner')

    def test_cli_start_failure_is_actionable(self):
        with patch.object(local_cli.subprocess, 'Popen', side_effect=OSError('Private filesystem detail')):
            with self.assertRaisesRegex(ValueError, '^The local CLI could not start'):
                local_cli.run(['missing-cli'], self.tmp.name)

    def test_codex_is_ephemeral_tool_free_and_uses_stdin(self):
        calls = []
        def run(command, directory, prompt='', **kwargs):
            calls.append((command, directory, prompt))
            if command[1:3] == ['login', 'status']: return 0, 'Logged in using ChatGPT'
            Path(command[command.index('--output-last-message')+1]).write_text(json.dumps(REPORT))
            return 0, ''
        with patch.object(local_cli.shutil, 'which', return_value='/tools/codex'), patch.object(local_cli, 'run', side_effect=run):
            self.assertEqual(local_cli.generate('codex-cli', '', 'system', 'private resume', provider.SCHEMAS['fit']), REPORT)
        command, directory, prompt = calls[-1]
        self.assertNotIn('private resume', ' '.join(command));self.assertIn('private resume', prompt)
        self.assertIn('--ephemeral', command);self.assertIn('--ignore-user-config', command)
        self.assertEqual(command[command.index('--sandbox')+1], 'read-only')
        self.assertIn('forced_login_method="chatgpt"', command)
        self.assertIn('shell_tool', command);self.assertIn('plugins', command)
        self.assertFalse(Path(directory).exists())

    def test_codex_refuses_api_login_before_generation(self):
        with patch.object(local_cli.shutil, 'which', return_value='/tools/codex'), patch.object(local_cli, 'run', return_value=(0, 'Logged in using an API key')) as run:
            with self.assertRaisesRegex(ValueError, 'codex login'):
                local_cli.generate('codex-cli', '', '', '', {})
            self.assertEqual(run.call_count, 1)

    def test_claude_disables_tools_and_preserves_oauth(self):
        calls = []
        def run(command, directory, prompt='', **kwargs):
            calls.append(command)
            if command[1:3] == ['auth', 'status']:
                return 0, json.dumps({'loggedIn': True, 'authMethod': 'claude.ai', 'apiProvider': 'firstParty'})
            return 0, json.dumps({'is_error': False, 'structured_output': REPORT})
        with patch.object(local_cli.shutil, 'which', return_value='/tools/claude'), patch.object(local_cli, 'run', side_effect=run):
            self.assertEqual(local_cli.generate('claude-cli', '', '', '', {}), REPORT)
        self.assertEqual(calls[-1][calls[-1].index('--tools')+1], '')
        self.assertIn('--safe-mode', calls[-1]);self.assertNotIn('--bare', calls[-1])
        self.assertIn('--strict-mcp-config', calls[-1])

    def test_cli_timeout_and_output_limit(self):
        with self.assertRaisesRegex(ValueError, 'timed out'):
            local_cli.run([sys.executable, '-c', 'import time; time.sleep(10)'], self.tmp.name, seconds=0.1)
        with self.assertRaisesRegex(ValueError, 'output limit'):
            local_cli.run([sys.executable, '-c', 'print("x"*10000)'], self.tmp.name, limit=100)

    def test_worker_pauses_on_config_change_without_running_provider(self):
        c = self.configure(provider='codex-cli', local_cli_owner='alice', local_cli_daily_limit=5)
        work = {'id': 'run', 'owner': 'alice', 'lease': 'lease', 'step': 'fit', 'context': CONTEXT,
                'artifacts': {}, 'provider_config_hash': contracts.digest(c)}
        self.configure(provider='openai')
        with patch.object(provider, 'generate') as generate:
            result = worker.dispatch(work, 'token')
        self.assertTrue(result['needs_input']);generate.assert_not_called()

    def test_worker_cli_errors_pause_instead_of_retrying(self):
        c = self.configure(provider='codex-cli', local_cli_owner='alice', local_cli_daily_limit=5)
        work = {'id': 'run', 'owner': 'alice', 'lease': 'lease', 'step': 'fit', 'context': CONTEXT,
                'artifacts': {}, 'provider_config_hash': contracts.digest(c)}
        with patch.object(provider, 'generate', side_effect=ValueError('Subscription limit')):
            self.assertTrue(worker.dispatch(work, 'token')['needs_input'])


if __name__ == '__main__': unittest.main(verbosity=2)
