"""Provider boundaries and local subscription behavior; no live model calls."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

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

    def test_explicit_choices_are_private_configured_and_do_not_change_default(self):
        self.configure(provider='codex-cli', model='',
                       model_options={'local': {'provider':'lmstudio', 'model':'fixture-local', 'local_model_url':'http://127.0.0.1:1234'}})
        self.assertEqual(contracts.config('local')['model'], 'fixture-local')
        self.assertEqual(contracts.config('local')['provider'], 'lmstudio')
        self.assertEqual(contracts.config('codex-cli')['model'], '')
        self.assertEqual(contracts.config()['provider'], 'codex-cli')
        self.assertTrue(contracts.model_status('alice', 'local')['configured'])
        self.assertTrue(contracts.model_status('bob', 'codex-cli')['configured'])
        with self.assertRaises(ValueError): contracts.config('https://untrusted.invalid')

    def test_public_deployment_uses_local_configuration_and_blocks_captured_external_provider(self):
        from agents.voice import voice_settings
        previous = self.configure(
            provider="codex-cli",
            model_options={"local": {"provider": "lmstudio", "model": "fixture-local"}},
        )
        with patch.dict(os.environ, {"STACK_FIRST_PARTY_AI_ONLY": "1"}):
            for selection in ("", "codex-cli", "local"):
                current = contracts.config(selection)
                self.assertEqual((current["provider"], current["model"]), ("lmstudio", "fixture-local"))
            with patch.object(local_cli, "generate") as generate, patch.object(provider, "http") as http:
                with self.assertRaisesRegex(ValueError, "Stack-hosted AI"):
                    provider.generate("fit", CONTEXT, previous)
                generate.assert_not_called()
                http.assert_not_called()
            with self.assertRaisesRegex(ValueError, "Live voice is unavailable"):
                voice_settings()

    def test_unconfigured_local_is_visible_without_fallback(self):
        for options in ({}, {'local': {'provider':'openai','model':'cloud'}}, {'local': {'model':'unknown'}}):
            self.configure(provider='codex-cli', model='', model_options=options, fallback_enabled=False)
            status = contracts.model_status('alice', 'local')
            self.assertFalse(status['configured'])
            self.assertEqual(status['provider'], 'ollama')
            self.assertIn('installed local model', status['message'])

    def test_local_fallback_tries_codex_then_claude_and_logs_attempts(self):
        from agents import local_model
        c = self.configure(provider='lmstudio', model='local', fallback_enabled=True)
        attempts, tried = [], []
        def cli(name, *args, **kwargs):
            tried.append(name)
            if name == 'codex-cli':
                raise ValueError('Install and sign in to codex-cli in the environment running Stack.')
            return REPORT
        with patch.object(local_model, 'complete', side_effect=ValueError('The local model service or selected model is unavailable.')), patch.object(local_cli, 'generate', side_effect=cli):
            result = provider.generate('fit', CONTEXT, c, record=attempts.append, allow_fallback=True)
        self.assertEqual(tried, ['codex-cli', 'claude-cli'])
        self.assertEqual(result['artifact'], REPORT)
        self.assertEqual([(a['provider'], a['status']) for a in attempts if a['status'] in ('error', 'accepted')],
                         [('lmstudio', 'error'), ('codex-cli', 'error'), ('claude-cli', 'accepted')])

    def test_api_fallback_uses_model_and_key_without_budget_settings(self):
        from agents import local_model
        c = self.configure(provider='lmstudio', model='local', fallback_enabled=True,
                           local_model_context_tokens=1024,
                           fallback_api={'provider': 'openai', 'model': 'api-model'})
        response = {'status': 'completed', 'output': [{'content': [{'type': 'output_text', 'text': json.dumps(REPORT)}]}]}
        with patch.dict(os.environ, {'OPENAI_API_KEY': 'synthetic'}), \
             patch.object(local_model, 'complete', side_effect=ValueError('Local inference timed out.')), \
             patch.object(local_cli, 'generate', side_effect=ValueError('Install and sign in to CLI.')), \
             patch.object(provider, 'http', return_value=response) as http:
            attempts = []
            result = provider.generate('fit', CONTEXT, c, record=attempts.append, allow_fallback=True)
            self.assertEqual(http.call_args.args[1]['max_output_tokens'], 6144)
            with self.assertRaisesRegex(ValueError, 'API model context limit'):
                provider.generate('fit', {**CONTEXT, 'details': 'x' * 32768}, c, allow_fallback=True)
            self.assertEqual(http.call_count, 1)
        self.assertEqual(result['artifact'], REPORT)
        self.assertEqual(attempts[-1]['provider'], 'openai')
        self.assertEqual(attempts[-1]['status'], 'accepted')

    def test_validation_failure_does_not_fallback(self):
        from agents import local_model
        c = self.configure(provider='lmstudio', model='local', fallback_enabled=True)
        with patch.object(local_model, 'complete', side_effect=ValueError('Local model output does not match the schema.')), \
             patch.object(local_cli, 'generate') as cli:
            with self.assertRaisesRegex(ValueError, 'schema'):
                provider.generate('fit', CONTEXT, c, allow_fallback=True)
            cli.assert_not_called()

    def test_codex_interview_accepts_complete_raw_plain_text(self):
        c = self.configure(provider='codex-cli')
        text = '{broken JSON. Useful coaching without scores.'
        with patch.object(local_cli, 'generate', return_value={'text':text}):
            for step in ('coach','interview_turn','interview_coach'):
                result = provider.generate(step, {'interview':{'turns':[]}}, c)
                self.assertEqual(result['artifact']['text'], text)

    def test_default_api_remains_disabled(self):
        self.assertFalse(contracts.model_status('owner')['configured'])
        self.assertEqual(contracts.config()['provider'], 'openai')

    def test_subscription_needs_no_account_binding_cap_or_money(self):
        c = self.configure(provider='codex-cli', local_cli_owner='legacy', local_cli_daily_limit=1)
        self.assertNotIn('local_cli_owner', c)
        self.assertNotIn('local_cli_daily_limit', c)
        for owner in ('', 'alice', 'bob'):
            contracts.model_access(c, owner)
            self.assertTrue(contracts.model_status(owner)['configured'])
        self.assertEqual(contracts.model_status('alice')['billing'], 'subscription')

    def test_api_model_is_required(self):
        for name in ('openai', 'meta'):
            self.configure(provider=name)
            self.assertFalse(contracts.model_status('alice')['configured'])
            self.configure(provider=name, model='test')
            self.assertTrue(contracts.model_status('alice')['configured'])

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

    def test_story_transport_selects_private_ids_and_resolves_exact_quotes(self):
        from agents.stories import FIELDS, selection_contract
        self.configure(provider='codex-cli')
        source = {'key': 'fact:resume.private', 'text':
                  'A release failed. I wrote a retry test. Our team deployed it. Errors stopped.'}
        contract = selection_contract(source)
        ids = {quote: key for key, quote in contract['quotes'].items()}
        selected = {'fields': {field: '' for field in FIELDS}, 'topics': ['ownership']}
        selected['fields'].update(action=ids['I wrote a retry test.'],
                                  personal=ids['I wrote a retry test.'],
                                  team=ids['Our team deployed it.'], result=ids['Errors stopped.'])
        with patch.object(local_cli, 'generate', return_value=selected) as generate:
            result = provider.generate('story', {'story_source': source,
                                               'facts': [{'key': 'resume.other', 'value': 'Private other event', 'verified': True}]})
        request = json.loads(generate.call_args.args[3])
        self.assertEqual(generate.call_args.args[4], contract['schema'])
        self.assertEqual(request['sources'], {source['key']: source['text']})
        self.assertEqual(request['context'], {'story_quotes': contract['quotes']})
        self.assertNotIn('Private other event', generate.call_args.args[3])
        for claim in result['artifact']['evidence']:
            self.assertEqual(claim['source'], source['key'])
            self.assertIn(claim['quote'], source['text'])
        self.assertEqual(result['artifact']['fields']['personal']['quote'], 'I wrote a retry test.')
        rejected = {**selected, 'fields': {**selected['fields'], 'result': 'foreign:q0'}}
        attempts = []
        def received_response(*args, **kwargs):
            kwargs['record_response'](json.dumps(rejected), 'model_json')
            return rejected
        with patch.object(local_cli, 'generate', side_effect=received_response):
            with self.assertRaisesRegex(ValueError, 'validated'):
                provider.generate('story', {'story_source': source}, record=attempts.append)
        self.assertEqual(attempts[-1]['status'], 'rejected')

    def test_meta_uses_own_key_and_structured_output(self):
        self.configure(provider='meta', model='muse-test')
        result = {'choices': [{'finish_reason': 'stop', 'message': {'content': json.dumps(REPORT)}}],
                  'usage': {'prompt_tokens': 100, 'completion_tokens': 100}, 'id': 'meta-result'}
        with patch.dict(os.environ, {'MODEL_API_KEY': 'meta-secret', 'OPENAI_API_KEY': 'wrong-secret'}), patch.object(provider, 'http', return_value=result) as http:
            value = provider.generate('fit', CONTEXT)
        url, payload, headers = http.call_args.args
        self.assertEqual(url, 'https://api.meta.ai/v1/chat/completions')
        self.assertEqual(headers['Authorization'], 'Bearer meta-secret')
        self.assertEqual(payload['response_format']['json_schema']['schema'], provider.SCHEMAS['fit'])
        self.assertEqual(value['provider_id'], 'meta-result')
        self.assertEqual(value['cost_cents'], 0)

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

    def test_coaching_clis_send_the_schema_and_keep_prose_replies(self):
        text='<img src=x onerror=alert(1)> {broken JSON. Partial:'
        for name in ('codex-cli','claude-cli'):
            calls=[]
            def run(command,directory,prompt='',**kwargs):
                calls.append(command)
                if command[1:3]==['login','status']:return 0,'Logged in using ChatGPT'
                if command[1:3]==['auth','status']:return 0,json.dumps({'loggedIn':True,'authMethod':'claude.ai','apiProvider':'firstParty'})
                if name=='codex-cli':
                    Path(command[command.index('--output-last-message')+1]).write_text(text)
                    return 0,''
                return 0,json.dumps({'is_error':False,'result':text})
            c={**contracts.config(),'provider':name,'model':'test'}
            with patch.object(local_cli.shutil,'which',return_value='/tools/cli'),patch.object(local_cli,'run',side_effect=run):
                self.assertEqual(provider.generate('coach',{'session':{'answer':'My answer'}},c)['artifact']['text'],text)
            self.assertIn('--output-schema' if name=='codex-cli' else '--json-schema',calls[-1])

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
            self.assertEqual(local_cli.generate('claude-cli', '', '', '', provider.SCHEMAS['fit']), REPORT)
        self.assertEqual(calls[-1][calls[-1].index('--tools')+1], '')
        self.assertIn('--safe-mode', calls[-1]);self.assertNotIn('--bare', calls[-1])
        self.assertIn('--strict-mcp-config', calls[-1])

    def test_cancelling_cli_stops_the_running_process(self):
        from threading import Lock, Timer
        from agents.local_model import InferenceCancellation
        cancellation = InferenceCancellation(gate=Lock())
        timer = Timer(0.2, cancellation.stop)
        timer.start()
        try:
            with self.assertRaisesRegex(ValueError, 'Cancelled'):
                local_cli.run([sys.executable, '-c', 'import time; time.sleep(10)'], self.tmp.name,
                              seconds=5, cancellation=cancellation)
        finally:
            timer.cancel();timer.join()

    def test_cli_timeout_and_output_limit(self):
        with self.assertRaisesRegex(ValueError, 'timed out'):
            local_cli.run([sys.executable, '-c', 'import time; time.sleep(10)'], self.tmp.name, seconds=0.1)
        with self.assertRaisesRegex(ValueError, 'output limit'):
            local_cli.run([sys.executable, '-c', 'print("x"*10000)'], self.tmp.name, limit=100)

    def test_worker_pauses_on_config_change_without_running_provider(self):
        c = self.configure(provider='codex-cli')
        work = {'id': 'run', 'owner': 'alice', 'lease': 'lease', 'step': 'fit', 'context': CONTEXT,
                'artifacts': {}, 'provider_config_hash': contracts.digest(c)}
        self.configure(provider='openai')
        with patch.object(provider, 'generate') as generate:
            result = worker.dispatch(work, 'token')
        self.assertTrue(result['needs_input']);generate.assert_not_called()

    def test_worker_cli_errors_pause_instead_of_retrying(self):
        c = self.configure(provider='codex-cli')
        work = {'id': 'run', 'owner': 'alice', 'lease': 'lease', 'step': 'fit', 'context': CONTEXT,
                'artifacts': {}, 'provider_config_hash': contracts.digest(c)}
        with patch.object(provider, 'generate', side_effect=ValueError('Subscription limit')):
            self.assertTrue(worker.dispatch(work, 'token')['needs_input'])


if __name__ == '__main__': unittest.main(verbosity=2)
