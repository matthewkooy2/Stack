"""Isolated real API/graph/worker checks; run only in the scheduled runtime lane."""
import copy
from unittest.mock import patch
import unittest
from tests.test_record_resume import RecordWorkflow, RECORDS, extracted
from tests.test_bullet_bank import FACTS


class BankWorkflow(unittest.TestCase):
    setUp = RecordWorkflow.setUp
    rpc = RecordWorkflow.rpc
    worker = RecordWorkflow.worker
    callback = RecordWorkflow.callback
    import_resume = RecordWorkflow.import_resume
    job = RecordWorkflow.job
    dispatch = RecordWorkflow.dispatch
    finish = RecordWorkflow.finish

    def tearDown(self):
        if not self.deleted:
            self.client.set_auth_token(self.owner_token)
            for source in self.rpc('resume_bank')['sources']:
                if source['editable']:
                    self.rpc('resume_bank_delete', {'id': source['id'], 'revision': source['revision']})
        RecordWorkflow.tearDown(self)

    def create(self, confirm=True):
        value = self.rpc('resume_bank_save', {'name': 'Fictional analyst, Example Co, 2024',
            'source': 'My fictional project notes', 'records': FACTS, 'confirm': confirm})
        self.assertNotIn('error', value, value)
        return next(s for s in value['sources'] if s['editable'])

    def target(self):
        rid, review, original = self.import_resume('.docx')
        confirmed = self.rpc('resume_save_records', {'id': rid, 'revision': review['revision'], 'records': RECORDS, 'confirm': True})
        self.assertTrue(confirmed['confirmed'])
        return rid, confirmed['revision'], original

    def test_crud_reload_history_stale_edits_account_isolation_export_and_delete(self):
        source = self.create(False)
        rid, revision, original = self.target()
        selection = [{'id': source['id'], 'revision': source['revision'], 'record_ids': ['r0']}]
        self.assertIn('error', self.rpc('resume_bank_select', {'id': rid, 'revision': revision, 'selection': selection}))
        source = next(s for s in self.rpc('resume_bank_save', {'id': source['id'], 'revision': source['revision'],
            'name': source['name'], 'source': source['source'], 'records': FACTS, 'confirm': True})['sources'] if s['editable'])
        selection[0]['revision'] = source['revision']
        chosen = self.rpc('resume_bank_select', {'id': rid, 'revision': revision, 'selection': selection})
        self.assertNotIn('error', chosen)
        self.client.reload(); self.client.set_auth_token(self.owner_token)
        bank = self.rpc('resume_bank')
        saved = next(s for s in bank['sources'] if s['editable'])
        self.assertTrue(saved['confirmed'])
        self.assertEqual(len(saved['history']), 2)
        self.assertEqual(bank['resumes'][0]['selection'], selection)
        self.assertEqual([r['id'] for r in self.rpc('bootstrap')['resumes']], [rid])
        self.assertIn('error', self.rpc('change_resume', {'id': source['id'], 'action': 'select'}))
        self.assertIn('error', self.rpc('resume_save_records', {'id': source['id'], 'revision': source['revision'], 'records': FACTS, 'confirm': True}))
        exported = next(s for s in self.rpc('account_export')['resumes'] if s['id'] == source['id'])
        self.assertEqual(exported['review']['original']['records'], FACTS)
        self.assertEqual(len(exported['review']['history']), 2)
        self.client.set_auth_token(self.other_token)
        self.assertEqual(self.rpc('resume_bank')['sources'], [])
        for endpoint, args in [('resume_bank_delete', {'id': source['id'], 'revision': source['revision']}),
            ('resume_bank_save', {'id': source['id'], 'revision': source['revision'], 'name': 'foreign', 'source': 'foreign', 'records': FACTS}),
            ('resume_bank_select', {'id': rid, 'revision': revision, 'selection': selection})]:
            self.assertIn('error', self.rpc(endpoint, args))
        self.client.set_auth_token(self.owner_token)
        changed = copy.deepcopy(FACTS);changed[0]['text'] = 'Reduced review time by 20% in 2024.'
        edited = self.rpc('resume_bank_save', {'id': source['id'], 'revision': source['revision'], 'name': source['name'],
            'source': 'Corrected notes', 'records': changed, 'confirm': False})
        self.assertNotIn('error', edited)
        self.assertIn('error', self.rpc('read_resume_source', {'id': rid}))
        self.assertIn('error', self.rpc('resume_bank_save', {'id': source['id'], 'revision': source['revision'], 'name': source['name'],
            'source': source['source'], 'records': FACTS, 'confirm': True}))
        self.assertIn('error', self.rpc('resume_bank_delete', {'id': source['id'], 'revision': source['revision']}))
        deleted = self.rpc('resume_bank_delete', {'id': source['id'], 'revision': source['revision'] + 1})
        self.assertFalse(any(s['editable'] for s in deleted['sources']))
        self.assertIn('error', self.rpc('read_resume_source', {'id': rid}))
        target = next(r for r in deleted['resumes'] if r['id'] == rid)
        self.assertNotIn('error', self.rpc('resume_bank_select', {'id': rid, 'revision': target['revision'], 'selection': []}))
        self.assertEqual(self.rpc('read_resume_source', {'id': rid})['source']['records'], RECORDS)
        with patch('agents.worker.browser_call', return_value={}):
            self.assertTrue(self.rpc('account_delete', {'username': 'mat25-owner', 'password': 'Synthetic-Mat25-password-1'})['deleted'])
        self.deleted = True

    def test_selected_beyond_resume_facts_reach_worker_review_files_and_stale_approval_fails(self):
        source = self.create()
        rid, revision, original = self.target()
        selection = [{'id': source['id'], 'revision': source['revision'], 'record_ids': ['r0', 'r1']}]
        self.assertNotIn('error', self.rpc('resume_bank_select', {'id': rid, 'revision': revision, 'selection': selection}))
        app = self.job()
        self.rpc('select_application_resume', {'id': app['id'], 'resume_id': rid})
        run = self.rpc('agent_start', {'kind': 'resume', 'target_id': app['id']})
        self.assertNotIn('error', run, run)
        claim = self.worker('agent_claim')
        result = self.dispatch(claim)
        self.assertIn('artifact', result, result)
        text, word = extracted(result['artifact'])
        for fact in FACTS:
            self.assertIn(fact['text'], text);self.assertIn(fact['text'], word)
        self.finish(claim, result)
        waiting = self.rpc('agent_run', {'id': run['id']})
        self.assertEqual(waiting['status'], 'review')
        self.rpc('agent_approve', {'id': run['id'], 'step': 'approve_resume', 'review_hash': waiting['review']['hash']})
        final_claim = self.worker('agent_claim')
        final = self.dispatch(final_claim)
        self.assertIn('artifact', final, final)
        provenance = final['artifact']['tailor']['change_record']['bank_sources'][0]
        self.assertEqual(provenance['id'], source['id'])
        self.assertEqual(provenance['records'], FACTS)
        self.finish(final_claim, final)
        self.client.reload();self.client.set_auth_token(self.owner_token)
        saved = next(r for r in self.rpc('bootstrap')['tailored_resumes'] if r['run_id'] == run['id'])
        self.assertTrue(saved['parse']['ok'])
        self.assertEqual(self.rpc('read_tailored_resume', {'id': saved['id']})['change_record']['bank_sources'][0], provenance)
        # A new proposal must not silently approve withdrawn or revised facts.
        run = self.rpc('agent_start', {'kind': 'resume', 'target_id': app['id']})
        claim = self.worker('agent_claim');self.finish(claim, self.dispatch(claim))
        waiting = self.rpc('agent_run', {'id': run['id']})
        self.rpc('agent_approve', {'id': run['id'], 'step': 'approve_resume', 'review_hash': waiting['review']['hash']})
        final_claim = self.worker('agent_claim')
        self.rpc('resume_bank_delete', {'id': source['id'], 'revision': source['revision']})
        invalid = self.dispatch(final_claim)
        self.assertNotIn('artifact', invalid)
        self.assertIn('error', invalid)


if __name__ == '__main__':
    unittest.main()
