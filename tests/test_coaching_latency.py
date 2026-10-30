"""A faster model for the coach step only (#124); no live model calls."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from agents import contracts, local_cli, provider

REPLY = {'verdict': 'Clear.', 'scores': [{'name': 'Ownership', 'score': 3, 'why': 'Said what you did.'}],
         'work_on': 'Add the result.', 'follow_ups': [], 'example': ''}


class CoachModel(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'config.json'
        env = patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(self.path)})
        env.start();self.addCleanup(env.stop)

    def configure(self, **changes):
        self.path.write_text(json.dumps(changes))
        return contracts.config()

    def models(self, step, c):
        seen = []
        def generate(name, model, *args, **kwargs):
            seen.append(model)
            return {'text': json.dumps(REPLY)} if kwargs.get('lenient') else {'summary': 'x', 'strengths': [], 'gaps': [], 'unknowns': [], 'evidence': []}
        with patch.object(local_cli, 'generate', side_effect=generate):
            provider.generate(step, {'session': {'answer': 'I did it.'}}, c)
        return seen

    def test_unset_keeps_the_configuration_digest(self):
        plain = self.configure(provider='claude-cli', model='claude-opus-5-5')
        self.assertNotIn('coach_models', plain)
        self.assertEqual(contracts.digest(plain), contracts.digest(self.configure(provider='claude-cli', model='claude-opus-5-5', coach_models={})))
        self.assertNotIn('coach_models', self.configure(provider='claude-cli', coach_models={'claude-cli': '  '}))

    def test_coach_uses_its_model_and_other_steps_do_not(self):
        c = self.configure(provider='claude-cli', model='claude-opus-5-5', coach_models={'claude-cli': 'claude-sonnet-5-5'})
        self.assertEqual(self.models('coach', c), ['claude-sonnet-5-5'])
        self.assertEqual(self.models('fit', c), ['claude-opus-5-5'])

    def test_only_the_matching_provider_is_overridden(self):
        c = self.configure(provider='codex-cli', model='', coach_models={'claude-cli': 'claude-sonnet-5-5'})
        self.assertEqual(self.models('coach', c), [''])

    def test_the_attempt_records_the_model_used(self):
        c = self.configure(provider='claude-cli', model='', coach_models={'claude-cli': 'claude-sonnet-5-5'})
        saved = []
        with patch.object(local_cli, 'generate', return_value={'text': json.dumps(REPLY)}):
            provider.generate('coach', {'session': {'answer': 'I did it.'}}, c, record=saved.append)
        self.assertEqual({a['model'] for a in saved}, {'claude-sonnet-5-5'})


if __name__ == '__main__':
    unittest.main()
