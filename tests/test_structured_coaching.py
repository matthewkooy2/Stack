"""Structured coaching from the prep coach step (#112); no live model calls."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from agents import coaching, contracts, local_cli, provider

REPLY = {'verdict': 'Clear ownership, but the result is missing.',
         'scores': [{'name': 'specificity', 'score': 2, 'why': 'Names the project but not the numbers.'},
                    {'name': 'Ownership', 'score': 4, 'why': 'Says what you did yourself.'}],
         'work_on': 'End with the measurable result.',
         'follow_ups': ['What changed afterwards?', 'What would you do differently?'],
         'example': ''}
SESSION = {'session': {'answer': 'I rebuilt the release checklist for my team.'}}


class StructuredCoaching(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'config.json'
        env = patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(self.path), 'OPENAI_API_KEY': 'test', 'MODEL_API_KEY': 'test'})
        env.start();self.addCleanup(env.stop)

    def configure(self, **changes):
        self.path.write_text(json.dumps(changes))
        return contracts.config()

    def check(self, artifact):
        self.assertEqual(artifact['format'], 'structured')
        self.assertEqual(artifact['summary'], REPLY['verdict'])
        self.assertEqual([(s['name'], s['score']) for s in artifact['scores']], [('Specificity', 2), ('Ownership', 4)])
        self.assertEqual(artifact['follow_ups'], REPLY['follow_ups'])
        # Older clients read only text: it always has the same layout.
        self.assertEqual(artifact['text'], 'Clear ownership, but the result is missing.\n\nScores:\n'
                         'Specificity: 2/4 - Names the project but not the numbers.\nOwnership: 4/4 - Says what you did yourself.'
                         '\n\nWork on: End with the measurable result.\n\nFollow-up questions:\n'
                         '1. What changed afterwards?\n2. What would you do differently?')

    def test_schema_is_strict_and_supported_by_the_local_validator(self):
        schema = provider.SCHEMAS['coach']
        self.assertIs(schema, coaching.SCHEMA)
        self.assertEqual(set(schema['required']), set(schema['properties']))
        self.assertFalse(schema['additionalProperties'])
        item = schema['properties']['scores']['items']['properties']['score']
        self.assertEqual((item['minimum'], item['maximum']), (0, 4))
        from agents.local_model import validate
        validate(REPLY, schema)
        with self.assertRaises(ValueError): validate({**REPLY, 'extra': 1}, schema)

    def test_every_provider_returns_the_structured_fields(self):
        text = json.dumps(REPLY)
        c = self.configure(provider='openai', model='gpt-test', monthly_cents=100, user_monthly_cents=100)
        openai = {'id': 'resp', 'status': 'completed', 'usage': {'input_tokens': 900, 'output_tokens': 200},
                  'output': [{'content': [{'type': 'output_text', 'text': text}]}]}
        with patch.object(provider, 'http', return_value=openai) as http:
            self.check(provider.generate('coach', SESSION, c)['artifact'])
        sent = http.call_args[0][1]
        self.assertEqual(sent['text']['format']['schema'], coaching.SCHEMA)
        self.assertIn('Return only the requested JSON.', sent['instructions'])
        self.assertIn('under 250 words', json.loads(sent['input'])['task'])
        c = self.configure(provider='meta', model='muse-test')
        meta = {'id': 'm', 'choices': [{'finish_reason': 'stop', 'message': {'content': text}}]}
        with patch.object(provider, 'http', return_value=meta) as http:
            self.check(provider.generate('coach', SESSION, c)['artifact'])
        self.assertEqual(http.call_args[0][1]['response_format']['json_schema']['schema'], coaching.SCHEMA)
        for name in ('codex-cli', 'claude-cli'):
            def run(command, directory, prompt='', **kwargs):
                if command[1:3] == ['login', 'status']: return 0, 'Logged in using ChatGPT'
                if command[1:3] == ['auth', 'status']:
                    return 0, json.dumps({'loggedIn': True, 'authMethod': 'claude.ai', 'apiProvider': 'firstParty'})
                if name == 'codex-cli':
                    Path(command[command.index('--output-last-message') + 1]).write_text(text);return 0, ''
                return 0, json.dumps({'is_error': False, 'result': '', 'structured_output': REPLY})
            c = self.configure(provider=name, model='')
            with patch.object(local_cli.shutil, 'which', return_value='/tools/cli'), patch.object(local_cli, 'run', side_effect=run):
                self.check(provider.generate('coach', SESSION, c)['artifact'])

    def test_a_reply_that_fails_validation_is_rejected(self):
        c = self.configure(provider='codex-cli')
        for bad in ({}, {'summary': 'Legacy shape only.'}, {'verdict': '  ', 'scores': [{'name': '', 'score': 3, 'why': ''}]},
                    {'verdict': 7, 'scores': 'high'}):
            with self.subTest(bad=bad), patch.object(local_cli, 'generate', return_value={'text': json.dumps(bad)}):
                with self.assertRaisesRegex(ValueError, 'could not be validated'):
                    provider.generate('coach', SESSION, c)
        with patch.object(local_cli, 'generate', return_value={'text': '   '}):
            with self.assertRaisesRegex(ValueError, 'no coaching text'): provider.generate('coach', SESSION, c)

    def test_prose_and_fenced_replies(self):
        c = self.configure(provider='codex-cli')
        prose = 'Overall: 2/4 - add the result.\n\nSpecificity: 2/4 - vague.'
        with patch.object(local_cli, 'generate', return_value={'text': prose}):
            artifact = provider.generate('coach', SESSION, c)['artifact']
        self.assertEqual(artifact, {'text': prose, 'summary': prose, 'format': 'text'})
        fenced = '```json\n' + json.dumps(REPLY) + '\n```'
        with patch.object(local_cli, 'generate', return_value={'text': fenced}):
            self.check(provider.generate('coach', SESSION, c)['artifact'])
        # Claude without structured output falls back to its text result.
        def run(command, directory, prompt='', **kwargs):
            if command[1:3] == ['auth', 'status']:
                return 0, json.dumps({'loggedIn': True, 'authMethod': 'claude.ai', 'apiProvider': 'firstParty'})
            return 0, json.dumps({'is_error': False, 'result': prose})
        c = self.configure(provider='claude-cli')
        with patch.object(local_cli.shutil, 'which', return_value='/tools/claude'), patch.object(local_cli, 'run', side_effect=run):
            self.assertEqual(provider.generate('coach', SESSION, c)['artifact']['format'], 'text')

    def test_long_fields_are_bounded(self):
        long = {**REPLY, 'verdict': 'x ' * 500, 'scores': REPLY['scores'] * 6, 'follow_ups': ['q'] * 5, 'example': 'e' * 9000}
        data = coaching.artifact(long)
        self.assertLessEqual(len(data['verdict']), coaching.LIMITS['verdict'])
        self.assertEqual(len(data['scores']), 9);self.assertEqual(len(data['follow_ups']), 2)
        self.assertLessEqual(len(data['example']), coaching.LIMITS['example'])
        self.assertIn('Example answer:\n', data['text'])

    def test_stored_artifacts_are_checked_again(self):
        self.check(coaching.stored({**coaching.artifact(REPLY), 'injected': '<script>'}))
        self.assertNotIn('injected', coaching.stored({**REPLY, 'injected': 1}))
        legacy = {'text': 'Plain coaching.', 'summary': 'Plain coaching.'}
        self.assertEqual(coaching.stored(legacy), legacy)
        for bad in ({'verdict': '', 'scores': []}, {'text': ''}, {}):
            with self.subTest(bad=bad), self.assertRaises(ValueError): coaching.stored(bad)


if __name__ == '__main__':
    unittest.main()
