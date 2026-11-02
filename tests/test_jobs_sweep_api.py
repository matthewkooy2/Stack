"""Disposable daily sweep: listing lifecycle, failed sources, stored matches and the removed per-user collection."""
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Sweep verification requires disposable embedded data; unset JAC_DB_URL.')
os.environ['JAC_DB_SCRATCH'] = '1'
from jaclang.testing.testing import JacTestClient
from discovery.normalize import normalize
from tests.catalog_fixture import BOARD, open_worker_gate, sweep, catalog_modules

ROOT = Path(__file__).resolve().parents[1]
OTHER = {**BOARD, 'id': 'lever:fixture', 'adapter': 'lever', 'name': 'Other Board'}
LIST = {'id': 'github:fixture', 'adapter': 'github', 'repo': 'example/jobs', 'name': 'Fixture list', 'sector': 'Technology', 'approved': True}


def listing(source, n, title='Software Engineer'):
    return normalize({'title': title, 'company': source['name'], 'url': f"https://example.com/{source['id']}/{n}",
                      'country': 'US', 'employment_type': 'Full-time', 'description': 'Build software.',
                      'posted_at': time.time() - n * 60}, source)


class JobsSweepAPI(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.jac/jobs-sweep-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.tmp.cleanup)
        self.client = JacTestClient.from_file(str(ROOT / 'main.jac'), base_path=self.tmp.name)
        self.addCleanup(self.client.close)
        self.token = self.client.register_user('sweep-fixture-a', 'Fixture-password-a-123').data['token']
        self.client.set_auth_token(self.token)
        self.rpc('bootstrap')
        self.rpc('agent_settings')
        open_worker_gate(self, (BOARD, OTHER, LIST))

    def rpc(self, name, args=None, ok=True):
        response = self.client.post('/function/' + name, json=args or {})
        self.assertTrue(response.ok, response.text)
        result = response.data['result']
        if ok:
            self.assertNotIn('error', result)
        return result

    def system(self, name, args):
        self.client.clear_auth()
        try:
            return self.rpc(name, {'token': 'fictional-test-token', **args})
        finally:
            self.client.set_auth_token(self.token)

    def ids(self):
        return {j['id'] for j in self.rpc('job_feed')['jobs']}

    def test_clean_source_closes_missing_listings_and_failed_source_keeps_them(self):
        a, b = [listing(BOARD, n) for n in range(3)], [listing(OTHER, n) for n in range(2)]
        sweep(self.system, {BOARD['id']: a, OTHER['id']: b, LIST['id']: []})
        self.assertEqual(self.ids(), {j['id'] for j in a + b})
        # The next day: the first board dropped one listing, the second board failed.
        sweep(self.system, {BOARD['id']: a[:2], OTHER['id']: 'Board timed out.', LIST['id']: []})
        self.assertEqual(self.ids(), {j['id'] for j in a[:2] + b})
        status = {s['id']: s for s in self.rpc('source_status')['sources']}
        self.assertEqual(status[OTHER['id']]['status'], 'error')
        self.assertIn('kept', status[OTHER['id']]['message'])
        self.assertEqual(status[BOARD['id']]['status'], 'ready')
        self.assertFalse(self.rpc('get_job', {'id': a[2]['id']})['active'])
        # A board that suddenly lists nothing is treated as a failure, not as every job closing.
        sweep(self.system, {BOARD['id']: [], OTHER['id']: b, LIST['id']: []})
        self.assertEqual(self.ids(), {j['id'] for j in a[:2] + b})
        self.assertEqual({s['id']: s for s in self.rpc('source_status')['sources']}[BOARD['id']]['status'], 'error')

    def test_sweep_stores_matches_and_opening_jobs_only_reads_them(self):
        sweep(self.system, {BOARD['id']: [listing(BOARD, n) for n in range(30)], OTHER['id']: [], LIST['id']: []})
        swept = time.time()
        first = self.rpc('job_feed')
        computed = first['computed_at']
        self.assertLess(computed, swept, 'The sweep, not the first read, stores the matches')
        self.assertEqual(len(first['jobs']), 25)
        self.assertTrue(first['next_cursor'])
        self.assertEqual(len(self.rpc('job_feed', {'cursor': first['next_cursor']})['jobs']), 5)
        self.assertEqual(self.rpc('job_feed')['computed_at'], computed)
        self.assertNotIn('prepared_jobs', self.rpc('bootstrap'))
        # Changing the search recomputes this account once and answers with the first page.
        saved = self.rpc('save_search', {'query': 'Designer', 'filters': {}})
        self.assertEqual(saved['feed']['jobs'], [])
        self.assertGreater(saved['feed']['computed_at'], computed)
        reset = self.rpc('reset_search')
        self.assertEqual(len(reset['feed']['jobs']), 25)
        # The old refresh flag is accepted from released builds but never queues collection.
        self.assertEqual(len(self.rpc('search_jobs', {'refresh': True})['jobs']), 25)

    def test_lists_add_their_boards_to_the_same_run(self):
        run = self.system('jobs_sweep_begin', {})
        order = [s['config']['id'] for s in run['sources']]
        self.assertEqual(order[0], LIST['id'])
        found = {'id': 'ashby:found', 'adapter': 'ashby', 'board': 'found', 'name': 'found', 'sector': 'Technology', 'approved': True}
        review = {'id': 'career:abc', 'adapter': 'career', 'url': 'https://example.org/careers', 'name': 'x', 'approved': False}
        added = self.system('jobs_sweep_source', {'run': run['run'], 'id': LIST['id'], 'candidates': [found, review], 'complete': True})['added']
        self.assertEqual([c['id'] for c in added], ['ashby:found'])
        self.system('jobs_sweep_source', {'run': run['run'], 'id': 'ashby:found', 'jobs': [listing(found, 1)], 'complete': True})
        while not self.system('jobs_sweep_finish', {'run': run['run']})['done']:
            pass
        self.assertEqual(len(self.rpc('job_feed')['jobs']), 1)
        self.assertIn('ashby:found', {s['id'] for s in self.rpc('source_status')['sources']})
        self.assertNotIn('career:abc', {s['id'] for s in self.rpc('source_status')['sources']})

    def test_old_catalog_fallback_and_title_change_before_sweep_finishes(self):
        old = listing(BOARD, 0, 'Fry Cook')
        run = sweep(self.system, {BOARD['id']: [old]}, finish=False)
        # Before the first projection is built, a new user's request remains correct.
        before = self.rpc('search_jobs', {'query': 'Fry cook'})
        self.assertEqual(before['total'], 1)
        while not self.system('jobs_sweep_finish', {'run': run})['done']:
            pass
        changed = listing(BOARD, 0, 'Junior Software Engineer')
        new_run = self.system('jobs_sweep_begin', {'only': [BOARD]})['run']
        self.system('jobs_sweep_source', {'run': new_run, 'id': BOARD['id'], 'jobs': [changed], 'complete': True})
        token = self.client.register_user('after-title-change', 'Fixture-password-b-456').data['token']
        self.client.set_auth_token(token)
        self.rpc('bootstrap')
        # The index must adopt the new title within the source transaction, even
        # while collection is still in progress and before nightly matching.
        updated = self.rpc('search_jobs', {'query': 'Software engineer'})
        self.assertEqual(updated['total'], 1)
        self.assertEqual(updated['jobs'][0]['title'], changed['title'])
        self.assertEqual(self.rpc('search_jobs', {'query': 'Fry cook'})['total'], 0)

    def test_many_title_updates_publish_matching_projection_once_per_page(self):
        sweep(self.system, {BOARD['id']: [listing(BOARD, 0)]})
        batch = [listing(BOARD, n + 1, f'Junior Software Engineer Team {n}') for n in range(100)]
        run = self.system('jobs_sweep_begin', {'only': [BOARD]})['run']
        module = catalog_modules()[0]
        with patch.object(module, '_update_projection', wraps=module._update_projection) as publish:
            self.system('jobs_sweep_source', {'run': run, 'id': BOARD['id'], 'jobs': batch, 'complete': True})
            self.assertEqual(publish.call_count, 1)
            self.assertEqual(len(publish.call_args.args[0]), 100)
        token = self.client.register_user('after-many-titles', 'Fixture-password-d-789').data['token']
        self.client.set_auth_token(token)
        self.rpc('bootstrap')
        result = self.rpc('search_jobs', {'query': 'Software engineer'})
        self.assertEqual(result['total'], 101)
        self.assertEqual(len(result['jobs']), 25)

    def test_source_purge_removes_public_matching_facts_for_new_accounts(self):
        sweep(self.system, {BOARD['id']: [listing(BOARD, 0)]})
        self.system('discovery_manage', {'id': BOARD['id'], 'action': 'purge'})
        token = self.client.register_user('after-source-purge', 'Fixture-password-c-789').data['token']
        self.client.set_auth_token(token)
        self.rpc('bootstrap')
        result = self.rpc('search_jobs', {'query': 'Software engineer'})
        self.assertEqual(result['jobs'], [])
        self.assertEqual(result['total'], 0)

    def test_import_is_deferred(self):
        self.assertIn('error', self.rpc('import_job_url', {'url': 'https://example.com/job'}, ok=False))
        self.assertIn('error', self.rpc('get_import_status', {'id': 'x'}, ok=False))


if __name__ == '__main__':
    unittest.main(verbosity=2)
