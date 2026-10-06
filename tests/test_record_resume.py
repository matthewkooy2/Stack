"""Fixed fictional fixtures: real import, generators, Jac persistence and workers.

STACK_TEST_REAL_MODEL=1 additionally invokes the operator's local model through
the actual worker, retaining model logs, output extraction and elapsed times.
"""
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import secrets
import tempfile
import time
import unittest
from unittest.mock import patch
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape
from zipfile import ZIP_DEFLATED, ZipFile
from pypdf import PdfReader
from reportlab.pdfgen.canvas import Canvas
from agents import record_resume as rr
if importlib.util.find_spec('jaclang') is not None:
    from agents import provider, resume_processing, worker
    from agents.worker import dispatch as worker_dispatch

ROOT = Path(__file__).resolve().parents[1]
RECORDS = json.loads((ROOT / 'tests/fixtures/record-resume.json').read_text(encoding='utf-8'))
# Explicit human selection eligibility; source fixture text stays fixed.
RECORDS[6]['allow_omit'] = True
TOKEN = 'mat25-disposable-worker'


def fixture(suffix):
    """Independent source documents; not produced by the resume generator."""
    if suffix == '.pdf':
        output = io.BytesIO()
        canvas = Canvas(output, pagesize=(612, 792))
        canvas.setFont('Helvetica', 11)
        for index, r in enumerate(RECORDS):
            canvas.drawString(40, 740 - index * 30, ('- ' if r['kind'] == 'bullet' else '') + r['text'])
        canvas.save()
        return output.getvalue()
    paragraphs = ''.join('<w:p><w:r><w:t>' + escape(('• ' if r['kind'] == 'bullet' else '') + r['text']) + '</w:t></w:r></w:p>' for r in RECORDS)
    return docx_fixture(paragraphs)


def docx_fixture(paragraphs):
    """Native source package, authored independently of the output generator."""
    output = io.BytesIO()
    with ZipFile(output, 'w', ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        archive.writestr('_rels/.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        archive.writestr('word/document.xml', '<w:document xmlns:w="' + rr.W + '"><w:body>' + paragraphs + '</w:body></w:document>')
    return output.getvalue()


def prepared(records=RECORDS):
    return rr.prepare({'records': records, 'template': 'classic', 'revision': 1, 'upload_digest': 'fixed-fictional-source'})


def proposal(*args, **kwargs):
    return {'artifact': {'summary': 'Emphasize dashboard experience.', 'ranking': ['r6', 'r5', 'r4'],
        'entry_order': [], 'evidence': [], 'omit': [{'id': 'r6', 'reason': 'Less relevant training notes.'}, {'id': 'r8', 'reason': 'Unsafe credential omission.'}],
        'rewrites': [{'id': 'r4', 'text': 'Built Python dashboards that reduced review time by 25%.', 'reason': 'Remove pronoun.'},
                     {'id': 'r5', 'text': 'Documented SQL queries for the team.', 'reason': 'Remove filler.'},
                     {'id': 'r9', 'text': 'Led a team and hold a CPA license.', 'reason': 'Invented claim must be ignored.'}]}, 'cost_cents': 0}


def extracted(artifact):
    pdf = base64.b64decode(artifact['pdf']['content'], validate=True)
    docx = base64.b64decode(artifact['docx']['content'], validate=True)
    reader = PdfReader(io.BytesIO(pdf))
    pdf_text = '\n'.join(page.extract_text() for page in reader.pages)
    with ZipFile(io.BytesIO(docx)) as archive:
        assert archive.testzip() is None
        tree = ET.fromstring(archive.read('word/document.xml'))
        docx_text = '\n'.join(''.join(p.itertext()) for p in tree.findall('.//{%s}p' % rr.W))
        assert tree.find('.//{%s}pgSz' % rr.W).get('{%s}w' % rr.W) == '12240'
        assert tree.find('.//{%s}pgMar' % rr.W).get('{%s}left' % rr.W) == '864'
    normalized = lambda value: re.sub(r'[\s•]', '', value)
    assert normalized(pdf_text) == normalized(docx_text), (pdf_text, docx_text)
    for page in reader.pages:
        assert tuple(page.mediabox) == (0, 0, 612, 792)
        positions = []
        page.extract_text(visitor_text=lambda text, cm, tm, font, size: positions.append((text, cm[4] + tm[4], cm[5] + tm[5])) if text.strip() else None)
        assert all(30 <= x <= 570 and 30 <= y <= 770 for _, x, y in positions), positions
    return pdf_text, docx_text


class RecordDocuments(unittest.TestCase):
    def test_imports_keep_dates_metrics_credentials_and_negation(self):
        for suffix in ('.pdf', '.docx'):
            records = rr.import_records('Resume' + suffix, fixture(suffix))
            self.assertEqual([r['text'] for r in records], [r['text'] for r in RECORDS])
            self.assertEqual(len(records), len(RECORDS))

    def test_supported_changes_rejections_and_independent_extraction(self):
        source = prepared()
        p = rr.tailor(source, proposal()['artifact'])
        self.assertIn('r4', {c['id'] for c in p['changes']})
        self.assertNotIn('r9', {c['id'] for c in p['changes']})
        self.assertNotIn('omit:r8', {c['id'] for c in p['changes']})
        final = rr.finalize(source, {**p, 'rejected': ['r5', 'omit:r6', 'order:r4']})['tailor']
        text, word = extracted(final)
        for value in ['25%', 'Jan 2022 – Dec 2024', 'AWS Certified Cloud Practitioner', RECORDS[5]['text'], RECORDS[6]['text'], RECORDS[9]['text']]:
            self.assertIn(value, text)
            self.assertIn(value, word)
        self.assertNotIn('I built', text)
        self.assertLess(text.index('Built Python'), text.index('Successfully documented'))
        with self.assertRaisesRegex(ValueError, 'changed after tailoring'):
            rr.finalize({**source, 'digest': 'changed'}, p)

    def test_docx_visible_hyphen_preserves_negative_metric_in_both_outputs(self):
        native = docx_fixture('<w:p><w:r><w:t>Revenue changed by </w:t><w:noBreakHyphen/><w:t>10%.</w:t></w:r></w:p>')
        records = rr.import_records('Negative metric.docx', native)
        self.assertEqual(records[0]['text'], 'Revenue changed by -10%.')
        source = prepared(records)
        output = rr.finalize(source, rr.tailor(source, {}))['tailor']
        pdf, docx = extracted(output)
        self.assertIn('Revenue changed by -10%.', pdf)
        self.assertIn('Revenue changed by -10%.', docx)
        discretionary = docx_fixture('<w:p><w:r><w:t>co</w:t><w:softHyphen/><w:t>operate</w:t></w:r></w:p>')
        self.assertEqual(rr.import_records('Soft hyphen.docx', discretionary)[0]['text'], 'co\u00adoperate')

    def test_unfamiliar_credential_stays_unless_human_marks_selection_eligible(self):
        records = [{'id': 'r0', 'kind': 'heading', 'text': 'Credentials'},
                   {'id': 'r1', 'kind': 'bullet', 'text': 'Earned GXQ'},
                   {'id': 'r2', 'kind': 'bullet', 'text': 'Kept training notes.', 'allow_omit': True},
                   {'id': 'r3', 'kind': 'bullet', 'text': 'Earned CPA', 'allow_omit': True},
                   {'id': 'r4', 'kind': 'bullet', 'text': 'Increased revenue by 25% in 2024.', 'allow_omit': True}]
        source = prepared(records)
        proposed = rr.tailor(source, {'omit': [{'id': r['id']} for r in records[1:]]})
        self.assertEqual(proposed['plan']['omit'], ['r2'])
        approved = rr.finalize(source, proposed)['tailor']
        pdf, docx = extracted(approved)
        for text in ('Earned GXQ', 'Earned CPA', '25%', '2024'):
            self.assertIn(text, pdf); self.assertIn(text, docx)
        self.assertNotIn('Kept training notes.', pdf)
        self.assertNotIn('Kept training notes.', docx)
        with self.assertRaises(ValueError): rr.validate_records([{**records[1], 'allow_omit': 'yes'}])

    def test_multpage_does_not_drop_content_or_force_one_page(self):
        records = [{'id': 'r' + str(i), 'kind': 'paragraph', 'text': 'Record ' + str(i) + ': retained content with 2024 and 25%.'} for i in range(100)]
        output = rr.documents(records, 'jake')
        self.assertGreater(output['pdf']['pages'], 1)
        text, _ = extracted(output)
        self.assertIn('Record 99:', text)

    def test_unreadable_or_unsupported_inputs_fail_without_losing_content(self):
        with self.assertRaises(ValueError): rr.validate_upload('broken.docx', b'not zip')
        for tag in ['drawing', 'ins', 'del', 'moveFrom', 'moveTo', 'moveFromRangeStart', 'moveToRangeEnd', 'altChunk', 'footnoteReference', 'sym']:
            output = io.BytesIO()
            with ZipFile(output, 'w') as archive:
                archive.writestr('word/document.xml', '<w:document xmlns:w="' + rr.W + '"><w:' + tag + '/></w:document>')
            with self.assertRaises(ValueError): rr.import_records('Resume.docx', output.getvalue())
        with self.assertRaises(ValueError): rr.validate_records([RECORDS[0], RECORDS[0]])
        with self.assertRaises(ValueError): rr.documents([{'id': 'r0', 'kind': 'title', 'text': '中文'}])


class RecordWorkflow(unittest.TestCase):
    def setUp(self):
        from jaclang.testing.testing import JacTestClient
        self.temp = tempfile.TemporaryDirectory(prefix='stack-mat25-')
        self.config = Path(self.temp.name) / 'config.json'
        self.config.write_text(json.dumps({'provider': 'lmstudio', 'model': os.environ.get('STACK_TEST_MODEL', 'qwen3-4b-instruct'), 'local_model_url': os.environ.get('STACK_TEST_MODEL_URL', 'http://127.0.0.1:11236'), 'local_model_context_tokens': 32768, 'max_output_tokens': 2048, 'capture_agent_content': True}))
        self.env = patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(self.config), 'STACK_AGENT_WORKER_TOKEN': TOKEN, 'STACK_DISCOVERY_TOKEN': TOKEN, 'STACK_LOCAL_MODEL_API_KEY': ''})
        self.env.start()
        self.client = JacTestClient.from_file(str(ROOT / 'main.jac'), base_path=self.temp.name)
        response = self.client.register_user('mat25-owner', 'Synthetic-Mat25-password-1')
        self.assertTrue(response.ok, response.text)
        self.owner_token = response.data['token']
        response = self.client.register_user('mat25-other', 'Synthetic-Mat25-password-2')
        self.assertTrue(response.ok, response.text)
        self.other_token = response.data['token']
        self.client.set_auth_token(self.owner_token)
        self.owner = self.rpc('bootstrap')['user_id']
        discovery = ROOT / 'storage/discovery/worker-token'
        discovery.parent.mkdir(parents=True, exist_ok=True)
        if not discovery.exists(): discovery.write_text(secrets.token_urlsafe(32))
        self.discovery_token = discovery.read_text().strip()
        self.resumes = []
        self.deleted = False
        self.rpc('agent_save_policy', {'policy': {'enabled': True, 'expires_at': time.time() + 3600, 'actions': ['model']}})

    def tearDown(self):
        if self.deleted:
            self.client.close(); self.env.stop(); self.temp.cleanup()
            return
        self.client.set_auth_token(self.owner_token)
        for rid in self.resumes:
            self.rpc('change_resume', {'id': rid, 'action': 'delete'})
        for r in self.rpc('bootstrap')['tailored_resumes']:
            self.rpc('delete_tailored_resume', {'id': r['id']})
        self.client.close()
        self.env.stop()
        self.temp.cleanup()

    def rpc(self, name, values=None):
        response = self.client.post('/function/' + name, json=values or {})
        self.assertTrue(response.ok, response.text)
        return response.data['result']

    def worker(self, name, values=None):
        self.client.clear_auth()
        try:
            return self.rpc(name, {'token': self.discovery_token if name.startswith('discovery_') else TOKEN, **(values or {})})
        finally:
            self.client.set_auth_token(self.owner_token)

    def callback(self, name, values):
        result = self.worker(name, values)
        if result.get('error'): raise ValueError(result['error'])
        return result

    def import_resume(self, suffix):
        original = fixture(suffix)
        state = self.rpc('upload_resume', {'name': 'Fictional' + suffix, 'content': base64.b64encode(original).decode()})
        rid = state['resumes'][-1]['id']
        self.resumes.append(rid)
        claim = self.worker('resume_processing_claim')
        self.assertEqual(claim['kind'], 'import')
        with patch.object(resume_processing, 'call', side_effect=self.callback):
            result = resume_processing.process(claim, TOKEN)
        self.assertNotIn('error', result)
        saved = self.worker('resume_processing_finish', {**{k: claim[k] for k in ('id', 'owner', 'lease')}, 'result': result})
        self.assertTrue(saved['saved'])
        self.assertIn('error', self.worker('resume_processing_finish', {**{k: claim[k] for k in ('id', 'owner', 'lease')}, 'result': result}))
        review = self.rpc('agent_extract_resume', {'id': rid})
        self.assertFalse(review['confirmed'])
        self.assertEqual([r['text'] for r in review['records']], [r['text'] for r in RECORDS])
        return rid, review, original

    def job(self):
        marker = 'MAT25' + secrets.token_hex(4)
        url = 'https://example.com/' + marker
        source = 'career:' + hashlib.sha256(url.encode()).hexdigest()[:32]
        self.rpc('import_job_url', {'url': url})
        claim = self.worker('discovery_claim', {'preferred_id': source})
        self.assertEqual(claim['id'], source, claim)
        now = time.time()
        jid = 'job_' + hashlib.sha256((url + '/0').encode()).hexdigest()[:32]
        job = {'id': jid, 'identity': url + '/0', 'canonical_url': url + '/0', 'url': 'https://jobs.lever.co/stacktest/' + marker,
            'title': 'Python Data Analyst', 'company': 'Fictional Test Co', 'description': 'Build Python dashboards and document SQL queries.',
            'country': 'US', 'location': 'Detroit, MI', 'locations': ['Detroit, MI'], 'mode': 'Remote', 'employment_type': 'Full-time',
            'seniority': 'Entry-level', 'occupation': 'Business', 'compensation': {}, 'salary': 'Pay not listed', 'salary_note': '',
            'source': 'smartrecruiters', 'source_id': source, 'source_name': 'Test', 'source_job_id': '0', 'attribution': {},
            'posted': 'Today', 'posted_at': now, 'checked_at': now, 'discovered_at': now, 'expires_at': 0, 'snippet': False,
            'requirements': [], 'qualifications': '', 'eligibility': '', 'remote_eligibility': '', 'initial': 'F', 'color': '#EDF2FF',
            'tags': [], 'reason': 'Synthetic verification', 'demo': False}
        done = self.worker('discovery_complete', {'id': source, 'lease': claim['lease'], 'result': {'jobs': [job], 'complete': True}})
        self.assertNotIn('error', done, done)
        return self.rpc('swipe', {'job_id': jid, 'action': 'apply'})['applications'][-1]

    def dispatch(self, claim, real=False):
        with patch.dict(worker_dispatch.__globals__, {'call': self.callback}):
            if real or claim['step'] == 'approve_resume':
                return worker_dispatch(claim, TOKEN)
            with patch('agents.provider.generate', side_effect=proposal):
                return worker_dispatch(claim, TOKEN)

    def finish(self, claim, result):
        return self.worker('agent_finish', {**{k: claim[k] for k in ('id', 'owner', 'lease')}, 'result': result})

    def test_pdf_docx_import_review_approval_files_reload_and_two_account_isolation(self):
        real = os.environ.get('STACK_TEST_REAL_MODEL') == '1'
        for suffix in ('.pdf', '.docx'):
            rid, review, original = self.import_resume(suffix)
            app = self.job()
            self.rpc('select_application_resume', {'id': app['id'], 'resume_id': rid})
            self.assertIn('error', self.rpc('agent_start', {'kind': 'resume', 'target_id': app['id']}))
            # Human review assigns semantic roles while every extracted line remains.
            confirmed = self.rpc('resume_save_records', {'id': rid, 'revision': review['revision'], 'records': RECORDS, 'confirm': True})
            self.assertTrue(confirmed['confirmed'], confirmed)
            self.assertNotIn('error', self.rpc('use_resume_template', {'id': rid, 'template': 'jake'}))
            source = self.rpc('read_resume_source', {'id': rid})['source']
            self.assertEqual((source['format'], source['template'], source['records']), ('records', 'jake', RECORDS))
            self.assertEqual(source['revision'], confirmed['revision'] + 1)
            self.assertEqual(self.rpc('score_resume', {'application_id': app['id']})['source'], 'records')
            self.assertIn('error', self.rpc('resume_save_records', {'id': rid, 'revision': review['revision'], 'records': RECORDS, 'confirm': True}))
            self.client.reload(); self.client.set_auth_token(self.owner_token)
            self.assertTrue(self.rpc('agent_extract_resume', {'id': rid})['confirmed'])
            run = self.rpc('agent_start', {'kind': 'resume', 'target_id': app['id']})
            self.assertNotIn('error', run, run)
            claim = self.worker('agent_claim')
            self.assertEqual(claim['id'], run['id'], claim)
            auth = {k: claim[k] for k in ('id', 'owner', 'lease')}
            self.assertIn('error', self.worker('agent_worker_resume_source', {**auth, 'lease': 'stale'}))
            self.assertEqual(self.worker('agent_worker_resume_source', auth)['records'], RECORDS)
            started = time.monotonic()
            result = self.dispatch(claim, real=real)
            if real:
                attempts = self.rpc('agent_model_logs', {'id': run['id']})['attempts']
                evidence = ROOT / '.jac/record-model-evidence'
                evidence.mkdir(parents=True, exist_ok=True)
                (evidence / (suffix[1:] + '-attempts.json')).write_text(json.dumps(attempts, indent=2), encoding='utf-8')
                print(json.dumps({'format': suffix, 'model_attempts': [{'status': a['status'], 'error': a.get('error', '')} for a in attempts]}), flush=True)
            self.assertIn('artifact', result, result)
            proposed = result['artifact']
            extracted(proposed)
            self.finish(claim, result)
            self.assertTrue(self.worker('agent_claim').get('idle'))
            waiting = self.rpc('agent_run', {'id': run['id']})
            self.assertEqual(waiting['status'], 'review', waiting)
            self.assertEqual(self.rpc('bootstrap')['tailored_resumes'][-1:] if suffix == '.pdf' else [], [])
            rejected = [c['id'] for c in proposed['changes']] if real else ['r5', 'omit:r6', 'order:r4']
            approved = self.rpc('agent_approve', {'id': run['id'], 'step': 'approve_resume', 'review_hash': waiting['review']['hash'], 'edits': {'rejected': rejected}})
            self.assertEqual(approved['status'], 'queued', approved)
            final_claim = self.worker('agent_claim')
            self.assertEqual(final_claim['step'], 'approve_resume')
            final_result = self.dispatch(final_claim)
            self.assertIn('artifact', final_result, final_result)
            self.finish(final_claim, final_result)
            done = self.rpc('agent_run', {'id': run['id']})
            self.assertEqual(done['status'], 'completed', done)
            saved = next(x for x in self.rpc('bootstrap')['tailored_resumes'] if x['run_id'] == run['id'])
            self.assertTrue(saved['parse']['ok'], saved)
            exported = self.rpc('read_tailored_resume', {'id': saved['id']})
            pdf_text, word_text = extracted(exported)
            for text in ['25%', 'Jan 2022 – Dec 2024', 'AWS Certified Cloud Practitioner', RECORDS[5]['text'], RECORDS[6]['text'], RECORDS[9]['text']]:
                self.assertIn(text, pdf_text); self.assertIn(text, word_text)
            self.assertEqual(exported['change_record']['rejected'], sorted(rejected))
            self.assertEqual(base64.b64decode(self.rpc('read_resume', {'id': rid})['content']), original)
            self.client.reload(); self.client.set_auth_token(self.owner_token)
            self.assertEqual(self.rpc('read_tailored_resume', {'id': saved['id']}), exported)
            self.assertEqual(next(x for x in self.rpc('account_export')['tailored_resumes'] if x['id'] == saved['id']), exported)
            self.client.set_auth_token(self.other_token)
            self.assertEqual(self.rpc('bootstrap')['resumes'], [])
            self.assertEqual(self.rpc('bootstrap')['tailored_resumes'], [])
            for endpoint, values in [('read_resume', {'id': rid}), ('agent_extract_resume', {'id': rid}),
                    ('resume_save_records', {'id': rid, 'revision': confirmed['revision'], 'records': RECORDS, 'confirm': True}),
                    ('read_tailored_resume', {'id': saved['id']}), ('delete_tailored_resume', {'id': saved['id']}),
                    ('agent_run', {'id': run['id']})]:
                self.assertIn('error', self.rpc(endpoint, values))
            self.client.set_auth_token(self.owner_token)
            if real:
                logs = self.rpc('agent_model_logs', {'id': run['id']})['attempts']
                self.assertEqual(logs[-1]['status'], 'accepted', logs)
                print(json.dumps({'format': suffix, 'model': json.loads(logs[-1]['raw_response'])['model'],
                      'seconds': round(time.monotonic() - started, 2), 'api_cost_cents': done['cost_cents'],
                      'rejected': rejected, 'retained_record_count': len(RECORDS), 'persisted': True}), flush=True)
            self.assertNotIn('error', self.rpc('check_tailored_resume', {'id': saved['id']}))
            directory = ROOT / 'storage/resumes' / hashlib.sha256(self.owner.encode()).hexdigest()
            generated = [p for p in directory.iterdir() if p.read_bytes() in
                         (base64.b64decode(exported['pdf']['content']), base64.b64decode(exported['docx']['content']))]
            self.assertEqual(len(generated), 2)
            if suffix == '.pdf':
                self.rpc('delete_tailored_resume', {'id': saved['id']})
                self.assertTrue(all(not p.exists() for p in generated))
                self.assertIn('error', self.rpc('read_tailored_resume', {'id': saved['id']}))
                self.assertEqual(base64.b64decode(self.rpc('read_resume', {'id': rid})['content']), original)
            else:
                deleted = self.rpc('account_delete', {'username': 'mat25-owner', 'password': 'Synthetic-Mat25-password-1'})
                self.assertTrue(deleted.get('deleted'), deleted)
                self.deleted = True
                self.assertEqual(list(directory.iterdir()), [])

    def test_changed_review_invalidates_approval_and_deleted_import_lease(self):
        rid, review, _ = self.import_resume('.docx')
        app = self.job()
        confirmed = self.rpc('resume_save_records', {'id': rid, 'revision': review['revision'], 'records': RECORDS, 'confirm': True})
        run = self.rpc('agent_start', {'kind': 'resume', 'target_id': app['id']})
        claim = self.worker('agent_claim'); self.finish(claim, self.dispatch(claim))
        self.assertTrue(self.worker('agent_claim').get('idle'))
        waiting = self.rpc('agent_run', {'id': run['id']})
        corrected = copy.deepcopy(RECORDS); corrected[4]['text'] = 'I built Python dashboards that reduced review time by 20%.'
        self.rpc('resume_save_records', {'id': rid, 'revision': confirmed['revision'], 'records': corrected, 'confirm': True})
        self.rpc('agent_approve', {'id': run['id'], 'step': 'approve_resume', 'review_hash': waiting['review']['hash']})
        claim = self.worker('agent_claim')
        result = self.dispatch(claim)
        self.assertTrue(result.get('needs_input'), result)
        self.assertIn('changed after tailoring', result['message'])
        self.finish(claim, result)
        self.assertEqual(self.rpc('bootstrap')['tailored_resumes'], [])
        state = self.rpc('upload_resume', {'name': 'Deleted.docx', 'content': base64.b64encode(fixture('.docx')).decode()})
        other = state['resumes'][-1]['id']; self.resumes.append(other)
        claim = self.worker('resume_processing_claim')
        self.rpc('change_resume', {'id': other, 'action': 'delete'})
        self.assertIn('error', self.worker('resume_processing_finish', {**{k: claim[k] for k in ('id', 'owner', 'lease')}, 'result': {'records': RECORDS}}))


if __name__ == '__main__':
    unittest.main()
