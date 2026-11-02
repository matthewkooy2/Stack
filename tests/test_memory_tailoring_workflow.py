"""Real API, graph, worker and files for memory-grounded tailoring, with two accounts.

By default a deterministic stand-in replaces only the model. STACK_TEST_REAL_MODEL=1 with
STACK_TEST_MODEL and STACK_TEST_MODEL_URL runs the operator's local model (for example
Qwen on NInfer) through the real worker and writes evidence to .jac/memory-tailoring-evidence.
"""
import base64
import contextlib
import json
import os
import re
import time
import unittest
from unittest.mock import patch
from xml.sax.saxutils import escape

import agents.memory_tailoring as mt
import tests.test_record_resume as record_cases
from tests.memory_tailoring_cases import (BANK, JOB, PRIYA_BANK, PRIYA_FORBIDDEN, PRIYA_JOB, PRIYA_RESUME, RESUME,
                                          filler_bank, standin, violations)
from tests.catalog_fixture import career, publish

REAL = os.environ.get('STACK_TEST_REAL_MODEL') == '1'
ROOT = record_cases.ROOT
TOKEN = record_cases.TOKEN
EVIDENCE = ROOT / '.jac/memory-tailoring-evidence'
OTHER_MARKER = 'Zebra Analytics Fellowship'


class MemoryWorkflow(unittest.TestCase):
    setUp = record_cases.RecordWorkflow.setUp
    tearDown = record_cases.RecordWorkflow.tearDown
    rpc = record_cases.RecordWorkflow.rpc
    worker = record_cases.RecordWorkflow.worker
    callback = record_cases.RecordWorkflow.callback
    finish = record_cases.RecordWorkflow.finish

    def setUp(self):
        record_cases.RecordWorkflow.setUp(self)
        raw = json.loads(self.config.read_text())
        # Room for whole-bank tailoring; the worker also respects what the server reports.
        raw.update(local_model_context_tokens=int(os.environ.get('STACK_TEST_CONTEXT', '65536')), local_model_timeout=90)
        self.config.write_text(json.dumps(raw))
        self.prompts = []

    def upload(self, name, records):
        paragraphs = ''.join('<w:p><w:r><w:t>' + escape(('• ' if r['kind'] == 'bullet' else '') + r['text']) + '</w:t></w:r></w:p>' for r in records)
        state = self.rpc('upload_resume', {'name': name, 'content': base64.b64encode(record_cases.docx_fixture(paragraphs)).decode()})
        rid = state['resumes'][-1]['id']
        self.resumes.append(rid)
        claim = self.worker('resume_processing_claim')
        empty = {'profile': {k: '' for k in ('name', 'email', 'phone', 'location', 'link', 'summary')}, 'skills': {'descriptions': []},
                 'education': [], 'workExperience': [], 'projects': [], 'unclassified': []}
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(record_cases.resume_processing, 'call', side_effect=self.callback))
            # Detail drafting is a separate feature; keep this test about tailoring.
            stack.enter_context(patch('agents.local_model.complete', return_value={'text': json.dumps(empty), 'model': 'fixture', 'id': '', 'usage': {}}))
            result = record_cases.resume_processing.process(claim, TOKEN)
        self.assertNotIn('error', result, result)
        self.assertTrue(self.worker('resume_processing_finish', {**{k: claim[k] for k in ('id', 'owner', 'lease')}, 'result': result})['saved'])
        review = self.rpc('agent_extract_resume', {'id': rid})
        confirmed = self.rpc('resume_save_records', {'id': rid, 'revision': review['revision'], 'records': records, 'confirm': True})
        self.assertTrue(confirmed['confirmed'], confirmed)
        return rid

    def bank(self, entries):
        for b in entries:
            saved = self.rpc('resume_bank_save', {'id': '', 'revision': 0, 'name': b['name'], 'source': b['source'], 'records': b['records'],
                                                  'confirm': b['confirm'], 'entry_type': b['entry_type'], 'fields': b['fields']})
            self.assertNotIn('error', saved, (b['name'], saved))

    def job(self, spec):
        marker = 'MEM' + os.urandom(4).hex()
        url = 'https://example.com/' + marker
        now = time.time()
        jid = 'job_' + __import__('hashlib').sha256((url + '/0').encode()).hexdigest()[:32]
        job = {'id': jid, 'identity': url + '/0', 'canonical_url': url + '/0', 'url': 'https://jobs.lever.co/stacktest/' + marker,
               'title': spec['title'], 'company': spec['company'], 'description': spec['description'],
               'country': 'US', 'location': spec['location'], 'locations': [spec['location']], 'mode': 'On-site', 'employment_type': 'Full-time',
               'seniority': spec['seniority'], 'occupation': 'Engineering', 'compensation': {}, 'salary': 'Pay not listed', 'salary_note': '',
               'source': 'smartrecruiters', 'source_id': 'career:' + __import__('hashlib').sha256(url.encode()).hexdigest()[:32],
               'source_name': 'Test', 'source_job_id': '0', 'attribution': {}, 'posted': 'Today', 'posted_at': now, 'checked_at': now,
               'discovered_at': now, 'expires_at': 0, 'snippet': False, 'requirements': [], 'qualifications': '', 'eligibility': '',
               'remote_eligibility': '', 'initial': spec['company'][0], 'color': '#EDF2FF', 'tags': [], 'reason': 'Synthetic verification', 'demo': False}
        self.assertNotIn('error', publish(lambda name, args: self.worker(name, args), career(url), [job]))
        return self.rpc('swipe', {'job_id': jid, 'action': 'apply'})['applications'][-1]

    def dispatch(self, claim, model):
        import agents.provider as provider
        real = provider.generate

        def spy(step, context, *args, **kwargs):
            result = (real if REAL else model)(step, context, *args, **kwargs)
            self.prompts.append((step, json.dumps(context, ensure_ascii=False), result.get('artifact')))
            return result
        with patch.dict(record_cases.worker_dispatch.__globals__, {'call': self.callback}), patch('agents.provider.generate', side_effect=spy):
            return record_cases.worker_dispatch(claim, TOKEN)

    def tailor(self, app_id, rid, model, rejected_kinds=()):
        self.rpc('select_application_resume', {'id': app_id, 'resume_id': rid})
        run = self.rpc('agent_start', {'kind': 'resume', 'target_id': app_id})
        self.assertNotIn('error', run, run)
        claim = self.worker('agent_claim')
        self.assertEqual((claim['id'], claim['step']), (run['id'], 'tailor'), claim)
        started = time.monotonic()
        result = self.dispatch(claim, model)
        seconds = round(time.monotonic() - started, 1)
        self.assertIn('artifact', result, result)
        self.finish(claim, result)
        self.assertTrue(self.worker('agent_claim').get('idle'))
        waiting = self.rpc('agent_run', {'id': run['id']})
        self.assertEqual(waiting['status'], 'review', waiting)
        proposal = result['artifact']
        rejected = [c['id'] for c in proposal['changes'] if c['kind'] in rejected_kinds]
        approved = self.rpc('agent_approve', {'id': run['id'], 'step': 'approve_resume', 'review_hash': waiting['review']['hash'],
                                              'edits': {'rejected': rejected} if rejected else {}})
        self.assertEqual(approved['status'], 'queued', approved)
        # Nothing is saved before approval runs.
        self.assertFalse([x for x in self.rpc('bootstrap')['tailored_resumes'] if x['run_id'] == run['id']])
        final_claim = self.worker('agent_claim')
        self.assertEqual(final_claim['step'], 'approve_resume')
        final = self.dispatch(final_claim, model)
        self.assertIn('artifact', final, final)
        self.finish(final_claim, final)
        self.assertEqual(self.rpc('agent_run', {'id': run['id']})['status'], 'completed')
        saved = next(x for x in self.rpc('bootstrap')['tailored_resumes'] if x['run_id'] == run['id'])
        exported = self.rpc('read_tailored_resume', {'id': saved['id']})
        return {'run': run, 'proposal': proposal, 'final': final['artifact']['tailor'], 'saved': saved, 'exported': exported,
                'rejected': rejected, 'seconds': seconds, 'review': waiting['review']}

    def check_facts(self, outcome, sources, forbidden):
        """Every final line is confirmed text or passes the guards against its cited sources."""
        final = outcome['final']['records']
        found = [r['text'] for r in final if any(re.search(p, r['text'].lower()) for p in forbidden)]
        # A confirmed line that states its own negation ("I have not earned a Green Belt") is truthful.
        # The line still has to pass the guards below, which require the source's negation.
        found = [t for t in found if not re.search(r"\bnot\b|n't|\bnever\b", t.lower())]
        self.assertEqual(found, [], 'forbidden claims in final resume')
        plan = outcome['proposal']['plan']
        headers = {h['text'] for s in plan['sections'] for i in s['items'] for h in i['head']} | {s['heading'] for s in plan['sections']}
        lines = {line['text']: (line, s['heading']) for s in plan['sections'] for i in s['items'] for line in i['lines']}
        for r in final:
            if r['text'] in sources or r['text'] in headers:
                continue
            self.assertIn(r['text'], lines, r)
            line, heading = lines[r['text']]
            self.assertEqual(mt.check_line(line['text'], line['sources'], ' '.join(headers), 'skill' in heading.lower()), '', line)

    def evidence(self, name, outcome, extra=None):
        changes = outcome['proposal']['changes']
        report = {'scenario': name, 'model': os.environ.get('STACK_TEST_MODEL', 'stand-in') if REAL else 'stand-in',
                  'seconds': outcome['seconds'], 'calls': outcome['proposal']['memory_coverage']['calls'],
                  'mode': outcome['proposal']['memory_coverage']['mode'], 'context_tokens': outcome['proposal']['memory_coverage']['context_tokens'],
                  'score': outcome['proposal'].get('score', {}), 'pages': outcome['final']['pdf']['pages'],
                  'changes': [{k: c[k] for k in ('kind', 'where', 'before', 'after')} for c in changes],
                  'notes': outcome['proposal']['notes'], 'coverage': outcome['proposal']['memory_coverage']['entries'],
                  'excluded': outcome['proposal']['memory_coverage']['excluded'], 'rejected': outcome['rejected'],
                  'final_records': outcome['final']['records'], **(extra or {})}
        if REAL:
            EVIDENCE.mkdir(parents=True, exist_ok=True)
            (EVIDENCE / (name + '.json')).write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
            (EVIDENCE / (name + '-prompts.json')).write_text(json.dumps(self.prompts, indent=1, ensure_ascii=False), encoding='utf-8')
        score = {k: {m: v.get(m) for m in ('match', 'quality')} for k, v in report['score'].items()}
        print(json.dumps({**{k: report[k] for k in ('scenario', 'model', 'seconds', 'calls', 'mode', 'pages')}, 'score': score}), flush=True)

    def test_data_analyst_full_memory_accuracy_review_and_isolation(self):
        # The other account has its own memory that must never reach this account's model or files.
        self.client.set_auth_token(self.other_token)
        self.rpc('agent_save_policy', {'policy': {'enabled': True, 'expires_at': time.time() + 3600, 'actions': ['model']}})
        self.rpc('resume_bank_save', {'id': '', 'revision': 0, 'name': OTHER_MARKER, 'source': 'Other account', 'confirm': True,
                                      'entry_type': 'work_experience', 'records': [{'id': 'r0', 'kind': 'bullet', 'text': 'Built Power BI claims dashboards for a hospital network.'}],
                                      'fields': {'employer': 'Zebra Analytics', 'job_title': 'Fellow', 'start_date': 'Jan 2023'}})
        self.client.set_auth_token(self.owner_token)
        rid = self.upload('Jordan Rivera.docx', RESUME)
        self.bank(BANK)
        app = self.job(JOB)
        model = standin({'r4': 'Built weekly Excel reports tracking carrier on-time rates for 6 regional managers.'},
                        omit=('r6', 'r8', 'r9'), include=('Transit delay dashboard', 'Data Intern, City of Detroit', 'Tableau Desktop Specialist'))
        outcome = self.tailor(app['id'], rid, model)
        prompts = '\n'.join(text for _, text, _ in self.prompts)
        # Full memory: every confirmed bank line reached the model; the draft and the other account did not.
        for b in BANK:
            for r in b['records']:
                if b['confirm']:
                    self.assertIn(json.dumps(r['text'], ensure_ascii=False)[1:-1], prompts, r['text'])
                else:
                    self.assertNotIn(r['text'][:40], prompts)
        self.assertNotIn(OTHER_MARKER, prompts)
        self.assertNotIn('hospital network', prompts)
        coverage = {c['name']: c for c in outcome['proposal']['memory_coverage']['entries']}
        self.assertEqual({b['name'] for b in BANK if b['confirm']} - set(coverage), set())
        self.assertIn('Machine learning course notes', [x['name'] for x in outcome['proposal']['memory_coverage']['excluded']])
        self.assertTrue(all(c['reviewed_by'] for c in coverage.values()), coverage)
        self.assertEqual(violations(outcome['final']['records']), [])
        sources = {r['text'] for r in RESUME} | {r['text'] for b in BANK if b['confirm'] for r in b['records']}
        self.check_facts(outcome, sources, [p for p in [r'power ?bi', r'healthcare', r'readmission', r'neural network', r'cross-functional']])
        texts = [r['text'] for r in outcome['final']['records']]
        self.assertEqual(texts[:2], [r['text'] for r in RESUME[:2]])
        self.assertTrue(any('B.S. Statistics' in t for t in texts))
        self.assertNotIn('error', self.rpc('check_tailored_resume', {'id': outcome['saved']['id']}))
        # Review boundary and account isolation for the saved result.
        self.client.set_auth_token(self.other_token)
        self.assertEqual(self.rpc('bootstrap')['tailored_resumes'], [])
        self.assertIn('error', self.rpc('read_tailored_resume', {'id': outcome['saved']['id']}))
        self.assertIn('error', self.rpc('agent_run', {'id': outcome['run']['id']}))
        self.assertEqual([s['name'] for s in self.rpc('resume_bank')['sources']], [OTHER_MARKER])
        self.client.set_auth_token(self.owner_token)
        self.evidence('data-analyst', outcome)
        if not REAL:
            kinds = {c['kind'] for c in outcome['proposal']['changes']}
            self.assertTrue({'add', 'omit', 'rewrite'} <= kinds, kinds)
            self.assertTrue(any('Transit delay dashboard' in t for t in texts))

    def test_worker_memory_endpoint_is_lease_and_owner_bound(self):
        rid = self.upload('Jordan Rivera.docx', RESUME)
        self.bank(BANK[:2])
        app = self.job(JOB)
        self.rpc('select_application_resume', {'id': app['id'], 'resume_id': rid})
        run = self.rpc('agent_start', {'kind': 'resume', 'target_id': app['id']})
        claim = self.worker('agent_claim')
        auth = {k: claim[k] for k in ('id', 'owner', 'lease')}
        memory = self.worker('agent_worker_memory', auth)
        self.assertEqual(memory['owner'], claim['owner'])
        self.assertEqual({e['name'] for e in memory['entries'] if e['kind'] == 'bank'}, {BANK[0]['name'], BANK[1]['name']})
        self.assertIn('error', self.worker('agent_worker_memory', {**auth, 'lease': 'forged'}))
        self.client.set_auth_token(self.other_token)
        other = self.rpc('bootstrap')['user_id']
        self.client.set_auth_token(self.owner_token)
        self.assertIn('error', self.worker('agent_worker_memory', {**auth, 'owner': other}))
        self.client.clear_auth()
        self.assertIn('error', self.rpc('agent_worker_memory', {**auth, 'token': 'not-the-worker'}))
        self.client.set_auth_token(self.owner_token)
        # The same accessor grounds interviews: bank experience appears in the generated questions.
        interview = self.rpc('interview_create', {'application_id': app['id'], 'client_id': 'mem-' + run['id']})
        data = interview['data']
        self.assertTrue(any(c['included'] for c in data['memory_coverage']), data['memory_coverage'])
        self.assertIn('Transit delay dashboard', ' '.join(q['question'] for q in data['questions']))

    def test_manufacturing_same_role_memory_and_rejections(self):
        rid = self.upload('Priya Nair.docx', PRIYA_RESUME)
        self.bank(PRIYA_BANK)
        app = self.job(PRIYA_JOB)
        model = standin(include=('Senior design: conveyor jam sensor',))
        outcome = self.tailor(app['id'], rid, model, rejected_kinds=('order',))
        sources = {r['text'] for r in PRIYA_RESUME} | {r['text'] for b in PRIYA_BANK for r in b['records']}
        self.check_facts(outcome, sources, PRIYA_FORBIDDEN)
        self.evidence('manufacturing', outcome)

    def test_oversized_bank_is_screened_and_fully_reported(self):
        rid = self.upload('Jordan Rivera.docx', RESUME)
        filler = filler_bank(int(os.environ.get('STACK_TEST_FILLER', '80')))
        self.bank(BANK + filler)
        app = self.job(JOB)
        model = standin(include=('Transit delay dashboard',))
        outcome = self.tailor(app['id'], rid, model)
        coverage = outcome['proposal']['memory_coverage']
        self.assertEqual(coverage['mode'], 'screened', coverage['calls'])
        names = {c['name']: c for c in coverage['entries']}
        for b in BANK + filler:
            if b['confirm']:
                self.assertIn(b['name'], names)
                self.assertTrue(names[b['name']]['reviewed_by'] or not names[b['name']]['rated'], names[b['name']])
        for step, text, _ in self.prompts:
            self.assertLessEqual(mt.request_size(step, json.loads(text), {'provider': 'lmstudio', 'max_output_tokens': 1536}),
                                 int(os.environ.get('STACK_TEST_CONTEXT', '65536')))
        self.assertEqual(violations(outcome['final']['records']), [])
        self.evidence('oversized', outcome, {'bank_entries': len(BANK) + len(filler),
                                             'status_counts': {s: sum(c['status'] == s for c in coverage['entries']) for s in
                                                               ('used', 'left_out', 'screened_out', 'did_not_fit')}})


if __name__ == '__main__':
    unittest.main()
