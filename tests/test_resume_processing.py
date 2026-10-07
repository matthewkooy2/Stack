"""Durable resume lifecycle against Jac persistence. No paid calls or deployment."""
import base64
import json
import logging
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from jaclang.testing.testing import JacTestClient
from agents import resume_processing, latex

ROOT = Path(__file__).resolve().parents[1]
PDF = (ROOT / 'tests/fixtures/synthetic-resume.pdf').read_bytes()
TEX = (ROOT / 'tests/fixtures/jake-resume.tex').read_bytes()
TOKEN = 'resume-worker-test'

class ResumeProcessing(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.jac/resume-test-work'
        scratch.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=scratch)
        config = Path(self.directory.name) / 'config.json'
        config.write_text('{}')
        self.environment = patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(config), 'STACK_AGENT_WORKER_TOKEN': TOKEN})
        self.environment.start()
        self.client = JacTestClient.from_file(str(ROOT / 'main.jac'), base_path=self.directory.name)
        registered = self.client.register_user('upload-owner', 'Upload-password-123')
        self.assertTrue(registered.ok, registered.text)
        self.token = registered.data['token']
        self.resume_ids = []

    def tearDown(self):
        self.client.set_auth_token(self.token)
        for resume_id in self.resume_ids:
            self.rpc('change_resume', {'id': resume_id, 'action': 'delete'})
        self.client.close()
        self.environment.stop()
        self.directory.cleanup()

    def rpc(self, name, args=None):
        response = self.client.post('/function/' + name, json=args or {})
        self.assertTrue(response.ok, response.text)
        return response.data['result']

    def worker(self, name, args=None):
        self.client.clear_auth()
        try:
            return self.rpc(name, {'token': TOKEN, **(args or {})})
        finally:
            self.client.set_auth_token(self.token)

    def upload(self):
        state = self.rpc('upload_resume', {'name': 'Candidate.pdf', 'content': base64.b64encode(PDF).decode()})
        resume = state['resumes'][-1]
        if resume['id'] not in self.resume_ids:
            self.resume_ids.append(resume['id'])
        work = self.worker('resume_processing_claim')
        if not work.get('idle'):
            self.assertEqual(work['kind'], 'import')
            self.run_work(work)
        return resume

    def source(self, resume_id, raw=TEX):
        return self.rpc('upload_resume_source', {'id': resume_id, 'name': 'resume.tex', 'content': base64.b64encode(raw).decode()})

    def finish(self, work, result):
        return self.worker('resume_processing_finish', {**{k: work[k] for k in ('id', 'owner', 'lease')}, 'result': result})

    def run_work(self, work, compile_result=None):
        def callback(name, args):
            result = self.worker(name, args)
            if result.get('error'):
                raise ValueError(result['error'])
            return result
        with patch.object(resume_processing, 'call', side_effect=callback):
            if compile_result is None:
                result = resume_processing.process(work, TOKEN)
            else:
                with patch.object(latex, 'compile', return_value=compile_result):
                    result = resume_processing.process(work, TOKEN)
        self.assertNotIn('error', result)
        self.assertTrue(self.finish(work, result)['saved'])
        return result

    def test_pdf_import_is_reviewable_without_confirming_facts_implicitly(self):
        resume = self.upload()
        repeated = self.upload()
        self.assertEqual(resume['id'], repeated['id'])
        self.assertNotIn('pdf', resume['processing'])
        self.assertEqual(self.worker('resume_processing_claim'), {'idle': True})
        review = self.rpc('agent_extract_resume', {'id': resume['id']})
        self.assertTrue(review['records'])
        self.assertFalse(review['confirmed'])
        self.assertIn('temporarily unavailable', self.rpc('resume_save_details', {'id': resume['id'], 'revision': 0, 'values': {'profile.name': 'Invented'}, 'confirm': True})['error'])
        self.assertIn('temporarily unavailable', self.rpc('retry_resume_processing', {'id': resume['id'], 'kind': 'pdf'})['error'])
        self.assertEqual(self.rpc('agent_settings')['facts'], [])
        self.client.reload()
        self.client.set_auth_token(self.token)
        self.assertEqual(base64.b64decode(self.rpc('read_resume', {'id': resume['id']})['content']), PDF)

    def test_failed_source_retry_reopen_compile_and_original_preserved(self):
        resume = self.upload()
        with patch.object(latex, 'compile', side_effect=AssertionError('Upload must not compile')):
            state = self.source(resume['id'])
        source_id = state['resumes'][0]['processing']['source']['id']
        self.assertEqual(self.source(resume['id'])['resumes'][0]['processing']['source']['id'], source_id)
        work = self.worker('resume_processing_claim')
        self.finish(work, {'error': 'Package fetch failed', 'parse_ms': 8, 'compile_ms': 20})
        self.client.reload()
        self.client.set_auth_token(self.token)
        failed = self.rpc('bootstrap')['resumes'][0]['processing']['source']
        self.assertEqual(failed['status'], 'failed')
        self.assertEqual(failed['error'], 'Package fetch failed')
        retried = self.rpc('retry_resume_processing', {'id': resume['id'], 'kind': 'source'})
        self.assertEqual(retried['resumes'][0]['processing']['source']['id'], source_id)
        self.assertNotIn('error', retried['resumes'][0]['processing']['source'])
        self.assertEqual(self.rpc('retry_resume_processing', {'id': resume['id'], 'kind': 'source'})['resumes'][0]['processing']['source']['id'], source_id)
        work = self.worker('resume_processing_claim')
        result = self.run_work(work, {'pdf': PDF, 'pages': 1})
        self.assertGreater(result['parse_ms'], 0)
        self.assertGreater(result['compile_ms'], 0)
        compiled = self.rpc('bootstrap')['resumes'][0]
        self.assertEqual(compiled['processing']['source']['status'], 'completed')
        self.assertEqual(compiled['format']['kind'], 'upload')
        self.assertEqual(base64.b64decode(self.rpc('read_resume', {'id': resume['id']})['content']), PDF)
        self.client.reload()
        self.client.set_auth_token(self.token)
        self.assertEqual(self.rpc('bootstrap')['resumes'][0]['format']['kind'], 'upload')
        # Missing previews are rebuilt by a durable job, not by a phone request.
        owner = self.rpc('bootstrap')['user_id']
        import hashlib
        preview = ROOT / 'storage/resumes' / hashlib.sha256(owner.encode()).hexdigest() / ('compiled-' + source_id + '.pdf')
        preview.unlink()
        with patch.object(latex, 'compile', side_effect=AssertionError('Preview read must not compile')):
            self.assertIn('being rebuilt', self.rpc('read_resume_source', {'id': resume['id']})['error'])
        self.assertEqual(self.rpc('bootstrap')['resumes'][0]['processing']['source']['status'], 'queued')
        self.run_work(self.worker('resume_processing_claim'), {'pdf': PDF, 'pages': 1})
        self.assertTrue(preview.exists())

    def test_expired_worker_reclaimed_and_stale_result_refused(self):
        resume = self.upload()
        self.source(resume['id'])
        old = self.worker('resume_processing_claim')
        with patch.object(time, 'time', return_value=time.time() + 181):
            new = self.worker('resume_processing_claim')
        self.assertNotEqual(new['lease'], old['lease'])
        self.assertIn('error', self.finish(old, {'error': 'stale result'}))
        self.run_work(new, {"pdf": PDF, "pages": 1})
        self.assertEqual(self.rpc('bootstrap')['resumes'][0]['processing']['source']['attempt'], 2)

    def test_replacement_deletion_and_ownership_reject_stale_work(self):
        resume = self.upload()
        self.source(resume['id'])
        old = self.worker('resume_processing_claim')
        self.source(resume['id'], TEX + b'\n% replacement')
        self.assertIn('error', self.finish(old, {'error': 'old upload'}))
        self.source(resume['id'], TEX)
        work = self.worker('resume_processing_claim')
        self.assertEqual(base64.b64decode(work['content']), TEX, 'Returning to a prior source must retain its input')
        self.client.register_user('upload-stranger', 'Stranger-password-123')
        self.assertIn('error', self.rpc('retry_resume_processing', {'id': resume['id'], 'kind': 'source'}))
        self.assertIn('error', self.rpc('upload_resume_source', {'id': resume['id'], 'name': 'resume.tex', 'content': base64.b64encode(TEX).decode()}))
        self.assertIn('error', self.rpc('resume_transfer_complete', {'id': resume['id'], 'job_id': work['id'], 'elapsed_ms': 1}))
        self.client.clear_auth()
        self.assertIn('error', self.rpc('resume_processing_claim', {'token': 'wrong-token'}))
        self.client.set_auth_token(self.token)
        self.rpc('change_resume', {'id': resume['id'], 'action': 'delete'})
        self.assertIn('error', self.finish(work, {'error': 'deleted upload'}))
        self.assertEqual(self.worker('resume_processing_claim'), {'idle': True})

    def test_identical_bytes_in_separate_resumes_have_independent_files(self):
        original = self.upload()
        copied = self.rpc('upload_resume', {'name': 'Copy.pdf', 'content': base64.b64encode(PDF).decode()})['resumes'][-1]
        self.resume_ids.append(copied['id'])
        self.assertNotEqual(original['id'], copied['id'])
        self.source(original['id'])
        self.source(copied['id'])
        self.rpc('change_resume', {'id': original['id'], 'action': 'delete'})
        self.assertEqual(base64.b64decode(self.rpc('read_resume', {'id': copied['id']})['content']), PDF)
        source_work = self.worker('resume_processing_claim')
        if source_work['kind'] == 'import':
            self.run_work(source_work)
            source_work = self.worker('resume_processing_claim')
        self.assertEqual(base64.b64decode(source_work['content']), TEX)
        self.run_work(source_work, {'pdf': PDF, 'pages': 1})

    def test_rename_then_reupload_and_delete_keeps_new_copy_readable(self):
        original = self.upload()
        self.rpc('change_resume', {'id': original['id'], 'action': 'rename', 'name': 'Renamed.pdf'})
        replacement = self.upload()
        self.assertNotEqual(original['id'], replacement['id'])
        self.rpc('change_resume', {'id': original['id'], 'action': 'delete'})
        self.assertEqual(base64.b64decode(self.rpc('read_resume', {'id': replacement['id']})['content']), PDF)
        self.assertEqual(self.worker('resume_processing_claim'), {'idle': True})

    def test_compile_stage_is_visible_and_failures_measure_elapsed_time(self):
        resume = self.upload()
        self.source(resume['id'])
        work = self.worker('resume_processing_claim')
        def callback(name, args):
            result = self.worker(name, args)
            if result.get('error'): raise ValueError(result['error'])
            return result
        def slow_failure(source):
            status = self.rpc('bootstrap')['resumes'][0]['processing']['source']
            self.assertEqual(status['status'], 'compiling')
            time.sleep(.025)
            raise ValueError('Synthetic compiler failure')
        with patch.object(resume_processing, 'call', side_effect=callback), patch.object(latex, 'compile', side_effect=slow_failure):
            result = resume_processing.process(work, TOKEN)
        self.assertGreater(result['compile_ms'], 20)
        self.assertGreater(result['parse_ms'], 0)
        self.assertEqual(result['error'], 'Synthetic compiler failure')
        self.finish(work, result)
        self.assertEqual(self.rpc('bootstrap')['resumes'][0]['processing']['source']['status'], 'failed')

class CompilerOutputBounds(unittest.TestCase):
    def setUp(self):
        # These tests replace the compiler process and do not need a host installation.
        compiler = patch.object(latex, 'engine', return_value='controlled-tectonic')
        compiler.start()
        self.addCleanup(compiler.stop)

    def test_large_compiler_output_is_read_with_a_bound(self):
        loaded = latex.load('resume.tex', TEX)
        def oversized(args, **kwargs):
            path = Path(kwargs['cwd']) / 'resume.pdf'
            with path.open('wb') as stream:
                stream.write(PDF)
                stream.truncate(32 * 1024 * 1024)
            return type('Result', (), {'returncode': 0})()
        with patch.object(latex.subprocess, 'run', side_effect=oversized):
            with patch.object(Path, 'read_bytes', side_effect=AssertionError('Unbounded file read')):
                with self.assertRaisesRegex(ValueError, '10 MB'):
                    latex.compile(loaded)

if __name__ == '__main__':
    unittest.main()
