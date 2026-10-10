"""Disposable persisted Jobs searches: role/level scope, timelines and pagination."""
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Jobs verification requires disposable embedded data; unset JAC_DB_URL.')
os.environ['JAC_DB_SCRATCH'] = '1'
from jaclang.testing.testing import JacTestClient
from core import catalog
from discovery.normalize import normalize, digest

ROOT = Path(__file__).resolve().parents[1]
PRESET = {'levels': ['Entry-level'], 'employment_types': ['Full-time'], 'confirmed_level': True}


class JobsFeedAPI(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.jac/jobs-feed-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.tmp.cleanup)
        self.client = JacTestClient.from_file(str(ROOT / 'main.jac'), base_path=self.tmp.name)
        self.addCleanup(self.client.close)
        self.token = self.client.register_user('jobs-fixture-a', 'Fixture-password-a-123').data['token']
        self.client.set_auth_token(self.token)
        self.rpc('bootstrap')
        # Test worker boundary only; never read a real collector token or production graph.
        gate = patch.object(catalog, '_worker_allowed', return_value=True)
        gate.start()
        self.addCleanup(gate.stop)
        self.url = 'https://example.com/jobs-fixture'
        self.source = 'career:' + digest(self.url)
        self.rpc('import_job_url', {'url': self.url})
        claim = self.system('discovery_claim', {'preferred_id': self.source})
        self.assertEqual(claim['id'], self.source)
        rows = []
        for i in range(72):
            title = ('Fry Cook' if i < 35 else 'Senior Software Engineer' if i < 40 else
                     'Software Engineer Intern' if i < 43 else 'Software Engineer' if i < 46 else
                     'Junior Software Engineer')
            text = 'Build software.'
            if i >= 46 and i % 2 == 0:
                text += ' Candidates must be graduating in 2027.'
            if i == 71:
                text += ' Candidates must be graduating in 2026.'
            rows.append(normalize({'title': title, 'company': 'Fixture ' + str(i),
                                   'url': self.url + '/' + str(i), 'country': 'US',
                                   'employment_type': 'Internship' if 40 <= i < 43 else 'Full-time',
                                   'description': text, 'posted_at': time.time() - i * 100}, claim['config']))
        self.system('discovery_complete', {'id': self.source, 'lease': claim['lease'],
                                          'result': {'jobs': rows, 'complete': True}})

    def rpc(self, name, args=None):
        response = self.client.post('/function/' + name, json=args or {})
        self.assertTrue(response.ok, response.text)
        result = response.data['result']
        self.assertNotIn('error', result)
        return result

    def system(self, name, args):
        self.client.clear_auth()
        try:
            return self.rpc(name, {'token': 'fictional-test-token', **args})
        finally:
            self.client.set_auth_token(self.token)

    def test_scope_before_pagination_persistence_and_unknown_timing(self):
        self.rpc('save_timeline', {'graduation_month': '2027-05', 'available_from': '2027-06'})
        filters = {**PRESET, 'sort': 'newest', 'exclude_companies': ['Fixture 47']}
        saved = self.rpc('save_search', {'query': 'Software engineer', 'filters': filters})
        restored = self.rpc('bootstrap')['saved_search']
        self.assertEqual(restored['query'], saved['query'])
        self.assertEqual(restored['filters'], saved['filters'])
        args = {'query': restored['query'], 'filters': restored['filters']}
        first = self.rpc('search_jobs', args)
        self.assertEqual(first['total'], 24)
        self.assertEqual(len(first['jobs']), 24)
        self.assertFalse(first['next_cursor'])
        self.assertTrue(first['criteria']['confirmed_level'])
        self.assertTrue(all(j['title'] == 'Junior Software Engineer' for j in first['jobs']))
        self.assertEqual({j['timeline']['status'] for j in first['jobs']}, {'match', 'unclear'})
        self.assertTrue(any(x['reason'] == 'Level' for x in first['excluded']))
        # Remove one employer exclusion to exercise the full 25-row boundary, then all timelines
        # to obtain 26 matching rows and verify the second page has only one matching row.
        paged_args = {'query': 'Software engineer', 'filters': {**PRESET, 'sort': 'newest', 'timeline': 'all'}}
        page = self.rpc('search_jobs', paged_args)
        self.assertEqual(page['total'], 26)
        self.assertEqual(len(page['jobs']), 25)
        self.assertTrue(page['next_cursor'])
        tail = self.rpc('search_jobs', {**paged_args, 'cursor': page['next_cursor']})
        self.assertEqual(len(tail['jobs']), 1)
        self.assertFalse(tail['next_cursor'])
        all_jobs = page['jobs'] + tail['jobs']
        self.assertEqual(len({j['id'] for j in all_jobs}), 26)
        self.assertEqual([j['posted_at'] for j in all_jobs], sorted((j['posted_at'] for j in all_jobs), reverse=True))
        response = self.client.post('/function/search_jobs', json={**paged_args, 'filters': {**PRESET, 'sort': 'relevance'}, 'cursor': page['next_cursor']})
        self.assertIn('error', response.data['result'])
        confirmed = self.rpc('search_jobs', {'query': 'Software engineer', 'filters': {**PRESET, 'timeline': 'confirmed'}})
        self.assertEqual(len(confirmed['jobs']), 13)
        self.assertTrue(all(j['timeline']['status'] == 'match' for j in confirmed['jobs']))
        interns = self.rpc('search_jobs', {'query': 'Software engineer', 'filters': {'levels': ['Internship'], 'employment_types': ['Internship'], 'confirmed_level': True}})
        self.assertEqual(len(interns['jobs']), 3)
        self.assertTrue(all(j['title'].endswith('Intern') for j in interns['jobs']))
        global_jobs = self.rpc('search_jobs', {'filters': {'timeline': 'all'}})
        self.assertEqual(global_jobs['total'], 72)
        other = self.client.register_user('jobs-fixture-b', 'Fixture-password-b-456').data['token']
        self.client.set_auth_token(other)
        self.assertEqual(self.rpc('bootstrap')['saved_search'], {})
        self.assertEqual(self.rpc('search_jobs', {'filters': {'timeline': 'all'}})['total'], 72)
        self.client.set_auth_token(self.token)
        self.assertEqual(self.rpc('bootstrap')['saved_search'], restored)
        # A profile location edit wins over its older search override, preserving role,
        # strict level, sort and employer choices. No default preset is reapplied.
        self.rpc('save_search', {'query': restored['query'], 'filters': {**filters, 'location': 'Detroit, MI'}})
        self.rpc('save_profile', {'name': 'Fixture', 'role': '', 'location': 'Texas', 'mode': 'Any', 'notifications': False})
        edited = self.rpc('bootstrap')['saved_search']
        self.assertEqual(edited['query'], restored['query'])
        self.assertNotIn('location', edited['filters'])
        for key in ('levels', 'confirmed_level', 'sort', 'exclude_companies'):
            self.assertEqual(edited['filters'][key], restored['filters'][key])
        self.rpc('save_search', {'query': '', 'filters': {**PRESET, 'any_role': True, 'sort': 'newest'}})
        self.rpc('save_profile', {'name': 'Fixture', 'role': 'Registered nurse', 'location': 'Texas', 'mode': 'Any', 'notifications': False})
        role_edited = self.rpc('bootstrap')['saved_search']
        self.assertNotIn('any_role', role_edited['filters'])
        self.assertEqual(role_edited['filters']['sort'], 'newest')
        scoped = self.rpc('search_jobs', {'query': role_edited['query'], 'filters': role_edited['filters']})
        self.assertEqual(scoped['criteria']['roles'], 'Registered nurse')
        self.assertEqual(scoped['jobs'], [])

    def test_confirmed_timeline_requires_profile_date_and_filters_validate(self):
        result = self.rpc('search_jobs', {'query': 'Software engineer', 'filters': {**PRESET, 'timeline': 'confirmed'}})
        self.assertEqual(result['jobs'], [])
        self.assertEqual(result['total'], 0)
        self.assertTrue(any('Set your graduation date' in n for n in result['criteria']['notices']))
        for value in ('true', 1, []):
            response = self.client.post('/function/save_search', json={'query': 'Software engineer', 'filters': {'confirmed_level': value}})
            self.assertIn('error', response.data['result'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
