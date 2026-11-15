"""Disposable onboarding saves: every in-repo client payload shape, boundaries and field-specific errors."""
import os
from pathlib import Path
import tempfile
import unittest

if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Onboarding verification requires disposable embedded data; unset JAC_DB_URL.')
os.environ['JAC_DB_SCRATCH'] = '1'
from jaclang.testing.testing import JacTestClient

ROOT = Path(__file__).resolve().parents[1]
MAIN = os.environ.get('STACK_ONBOARDING_MAIN', 'main.jac')
# Native PreferenceForm.json for a new account that picked a stage and one work arrangement.
NATIVE_PREFS = {'stage': 'Student', 'years': '', 'education': '', 'modes': ['Remote'], 'employment_types': [],
                'salary_min': '', 'salary_period': 'year', 'exclude_companies': '', 'exclude_terms': '', 'soft': []}
# mobile/main.jac _preferenceForm after the three Onboarding.jac steps (name, role/location/mode, stage).
MOBILE_PREFS = {'stage': 'Recent graduate', 'years': '', 'education': '', 'modes': ['Hybrid', 'On-site'],
                'employment_types': [], 'salary_min': '', 'salary_period': 'year', 'exclude_companies': '',
                'exclude_terms': '', 'soft': []}
VALID = [
    # The installed phone's "A little about your search" step: optional role/location/stage, no name or mode field.
    ('phone search step', {'name': '', 'role': 'Software Engineer', 'location': '', 'mode': '', 'notifications': True,
                           'preferences': {**NATIVE_PREFS, 'stage': 'Student', 'modes': []}}),
    ('native ProfileView', {'name': 'Fixture Person', 'role': 'Product designer', 'location': 'Detroit, MI', 'mode': 'Remote',
                            'notifications': True, 'graduation_month': '', 'available_from': '', 'preferences': NATIVE_PREFS}),
    ('mobile onboarding', {'name': 'Fixture Person', 'role': '', 'location': 'United States', 'mode': 'Any',
                           'notifications': True, 'graduation_month': '', 'available_from': '', 'preferences': MOBILE_PREFS}),
    ('older single chip', {'name': 'Fixture Person', 'role': 'Analyst', 'location': 'Texas', 'mode': 'On-site', 'notifications': False}),
    ('length boundaries', {'name': 'n' * 100, 'role': 'r' * 160, 'location': 'l' * 160, 'mode': 'Any', 'notifications': False,
                           'graduation_month': '2027-05', 'available_from': '2027-06'}),
]


class OnboardingProfileAPI(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.jac/onboarding-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.tmp.cleanup)
        self.client = JacTestClient.from_file(str(ROOT / MAIN), base_path=self.tmp.name)
        self.addCleanup(self.client.close)
        self.client.set_auth_token(self.client.register_user('onboarding-fixture', 'Fixture-password-123').data['token'])
        self.rpc('bootstrap')

    def rpc(self, name, args=None):
        response = self.client.post('/function/' + name, json=args or {})
        self.assertTrue(response.ok, response.text)
        return response.data['result']

    def test_client_payloads_are_saved_exactly(self):
        for label, args in VALID:
            with self.subTest(label):
                result = self.rpc('save_profile', args)
                self.assertNotIn('error', result)
                profile = result['profile']
                self.assertEqual((profile['name'], profile['role'], profile['location'], profile['onboarded']),
                                 (args['name'], args['role'], args['location'], True))
                if 'preferences' in args:
                    self.assertEqual(profile['preferences']['stage'], args['preferences']['stage'])
                    self.assertEqual(profile['preferences']['modes'], args['preferences']['modes'])

    def test_blank_name_keeps_saved_name(self):
        self.rpc('save_profile', {'name': 'Fixture Person', 'role': 'Analyst', 'location': 'Texas', 'mode': 'Hybrid', 'notifications': False})
        profile = self.rpc('save_profile', {'name': '  ', 'role': 'Data analyst', 'location': 'Texas', 'mode': '', 'notifications': False})['profile']
        self.assertEqual((profile['name'], profile['role'], profile['mode']), ('Fixture Person', 'Data analyst', 'Any'))

    def test_invalid_fields_name_the_field_and_change_nothing(self):
        base = {'name': 'Fixture', 'role': 'Nurse', 'location': 'Texas', 'mode': 'Any', 'notifications': False}
        cases = [({'name': 'x' * 101}, 'name'), ({'role': 'r' * 161}, 'target roles'),
                 ({'location': 'l' * 161}, 'location'), ({'mode': 'Onsite'}, 'work arrangement'),
                 ({'preferences': {**NATIVE_PREFS, 'stage': 'Wizard'}}, 'career stage'), ({'graduation_month': 'May'}, 'YYYY-MM')]
        for change, word in cases:
            with self.subTest(word=word, change=str(change)[:40]):
                error = self.rpc('save_profile', {**base, **change}).get('error', '')
                self.assertIn(word, error)
        self.assertFalse(self.rpc('bootstrap')['profile']['onboarded'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
