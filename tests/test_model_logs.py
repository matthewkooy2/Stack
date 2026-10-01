"""Response retention before validation, across providers and retries."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from agents import contracts, local_cli, provider, worker, voice


GOOD = {'summary': 'Has experience', 'strengths': [], 'gaps': [], 'unknowns': [],
        'evidence': [{'source': 'fact:resume.project', 'quote': 'Built a tracker', 'claim': 'Has experience'}]}
CONTEXT = {'facts': [{'key': 'resume.project', 'value': 'Built a tracker', 'verified': True}]}


class ModelLogs(unittest.TestCase):
    def cli(self, name, raw, record):
        def run(command, directory, *args, **kwargs):
            if command[1:3] == ['login', 'status']:
                return 0, 'Logged in using ChatGPT'
            if command[1:3] == ['auth', 'status']:
                return 0, json.dumps({'loggedIn': True, 'authMethod': 'oauth', 'apiProvider': 'firstParty'})
            if name == 'codex-cli':
                Path(command[command.index('--output-last-message') + 1]).write_text(raw)
                return 0, ''
            return 0, raw
        c = {**contracts.config(), 'provider': name, 'model': 'test-model'}
        with patch.object(local_cli.shutil, 'which', return_value='/mock/cli'), patch.object(local_cli, 'run', side_effect=run):
            return provider.generate('fit', CONTEXT, c, record=record)

    def test_both_clis_retain_exact_success_and_rejected_and_malformed_output(self):
        for name in ('codex-cli', 'claude-cli'):
            for report in (GOOD, {**GOOD, 'evidence': [{'source': 'missing', 'quote': 'invented', 'claim': 'bad'}]}, None):
                with self.subTest(provider=name, report=report):
                    raw = 'not JSON' if report is None else json.dumps(report if name == 'codex-cli' else {'structured_output': report}, indent=2)
                    events = []
                    if report == GOOD:
                        result = self.cli(name, raw, events.append)
                        self.assertEqual(result['artifact'], GOOD)
                    else:
                        with self.assertRaises(ValueError):
                            self.cli(name, raw, events.append)
                    self.assertEqual([x['status'] for x in events], ['started', 'received', 'accepted' if report == GOOD else 'rejected'])
                    self.assertEqual(events[-1]['raw_response'], raw)
                    self.assertEqual(events[-1]['provider'], name)
                    self.assertEqual(events[-1]['model'], 'test-model')
                    if report != GOOD:
                        self.assertTrue(events[-1]['error'])

    def test_api_providers_retain_success_rejection_and_incomplete_responses(self):
        for name in ('openai', 'meta'):
            for status in ('good', 'bad', 'incomplete'):
                report = GOOD if status == 'good' else {**GOOD, 'evidence': [{'source': 'missing', 'quote': 'no', 'claim': 'no'}]}
                if name == 'openai':
                    response = {'status': 'incomplete' if status == 'incomplete' else 'completed', 'output': [{'content': [{'type': 'output_text', 'text': json.dumps(report)}]}]}
                else:
                    response = {'choices': [{'finish_reason': 'length' if status == 'incomplete' else 'stop', 'message': {'content': json.dumps(report)}}]}
                events = []
                with patch.dict(os.environ, {'OPENAI_API_KEY': 'secret-api', 'MODEL_API_KEY': 'secret-meta'}), patch.object(provider, 'http', return_value=response):
                    c = {**contracts.config(), 'provider': name, 'model': 'test'}
                    if status == 'good':
                        provider.generate('fit', CONTEXT, c, record=events.append)
                    else:
                        with self.assertRaises(ValueError):
                            provider.generate('fit', CONTEXT, c, record=events.append)
                self.assertEqual(json.loads(events[-1]['raw_response']), response)
                self.assertNotIn('secret-api', json.dumps(events))
                self.assertNotIn('secret-meta', json.dumps(events))
                self.assertEqual(events[-1]['status'], 'accepted' if status == 'good' else 'rejected')

    def test_worker_records_durably_with_identity_and_keeps_each_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.json'
            path.write_text(json.dumps({'provider': 'codex-cli', 'local_cli_owner': 'alice', 'local_cli_daily_limit': 10}))
            with patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(path)}):
                work = {'owner': 'alice', 'id': 'run', 'lease': 'lease', 'step': 'fit', 'context': CONTEXT,
                        'artifacts': {}, 'provider_config_hash': contracts.digest(contracts.config())}
                def generate(*args, record_response=None):
                    record_response('invalid JSON', 'model_json')
                    raise ValueError('Invalid JSON')
                with patch.object(worker, 'call', return_value={'saved': True}) as save, patch.object(local_cli, 'generate', side_effect=generate):
                    for _ in range(2):
                        self.assertTrue(worker.dispatch(work, 'private-worker-token')['needs_input'])
                self.assertEqual(save.call_count, 6)
                final = [c.args[1] for c in save.call_args_list if c.args[1]['record']['status'] == 'rejected']
                self.assertEqual(len({v['record']['attempt_id'] for v in final}), 2)
                for args in final:
                    self.assertEqual(args['owner'], 'alice')
                    self.assertEqual(args['id'], 'run')
                    self.assertEqual(args['lease'], 'lease')
                    self.assertNotIn('private-worker-token', json.dumps(args['record']))
                    self.assertEqual(args['record']['raw_response'], 'invalid JSON')

    def test_logging_failure_stops_generation_before_unlogged_request(self):
        with patch.object(provider, '_generate') as generate:
            with self.assertRaisesRegex(ValueError, 'Cannot save'):
                provider.generate('fit', CONTEXT, {**contracts.config(), 'provider': 'codex-cli'},
                                  record=lambda _: (_ for _ in ()).throw(ValueError('Cannot save')))
        generate.assert_not_called()

    def test_voice_response_keeps_transcript_and_completion_metadata(self):
        for status in ('completed', 'cancelled', 'failed'):
            raw = json.dumps({'type': 'response.done', 'response': {'id': 'voice-turn', 'status': status,
                'output': [{'content': [{'type': 'audio', 'transcript': 'Tell me about your project.'}]}]}})
            with patch.object(voice, 'call', return_value={'saved': True}) as saved:
                voice.record_response({'token': 'private', 'owner': 'alice', 'id': 'run', 'lease': 'lease'}, 'voice-model', raw)
            record = saved.call_args.args[1]['record']
            self.assertEqual(record['raw_response'], raw)
            self.assertEqual(record['status'], 'completed' if status == 'completed' else 'rejected')
            self.assertNotIn('token', record)

    def test_provider_error_without_response_is_recorded(self):
        events = []
        with patch.object(local_cli, 'generate', side_effect=ValueError('Subscription unavailable')):
            with self.assertRaises(ValueError):
                provider.generate('fit', CONTEXT, {**contracts.config(), 'provider': 'codex-cli'}, record=events.append)
        self.assertEqual(events[-1]['status'], 'error')
        self.assertNotIn('raw_response', events[-1])
        self.assertEqual(events[-1]['error'], 'Subscription unavailable')


if __name__ == '__main__':
    unittest.main()
