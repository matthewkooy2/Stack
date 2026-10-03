"""Disposable audio/job storage and private child lifecycle; no real model or account data."""
import base64
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
import io
import json
import os
from pathlib import Path
import struct
import shutil
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import wave
from agents.transcription_store import Store, wav_info
from agents import transcription_worker as worker
from agents import setup_transcription, transcription_readiness

ROOT = Path(__file__).resolve().parents[1]

def wav(seconds=1, value=1000, rate=16000):
    output = io.BytesIO()
    with wave.open(output, 'wb') as audio:
        audio.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        audio.writeframes(struct.pack('<h', value) * int(rate * seconds))
    return output.getvalue()


class Jobs(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.jac/transcription-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.directory.cleanup)
        self.store = Store(self.directory.name)
        self.raw = wav()

    def upload(self, owner='owner-a', ident='recording-000001', raw=None):
        return self.store.upload(owner, ident, base64.b64encode(raw or self.raw).decode())

    def auth(self, work):
        return {k: work[k] for k in ('owner', 'lease')} | {'ident': work['id']}

    def expire(self, work):
        with self.store.transaction() as db:
            data = self.store.row(db, work['owner'], work['id'])
            data['lease_until'] = time.time()-1
            self.store.write(db, data)

    def test_response_loss_replay_restart_worker_finish_and_edit(self):
        accepted = self.upload()
        repeated = Store(self.directory.name).upload('owner-a', 'recording-000001', base64.b64encode(self.raw).decode())
        self.assertEqual(accepted['id'], repeated['id'])
        self.assertEqual(accepted['status'], 'queued')
        work = self.store.claim()
        self.assertEqual(self.store.claim(), {'idle': True})
        self.assertEqual(base64.b64decode(work['content']), self.raw)
        self.store.progress(**self.auth(work), stage='loading', timings={'decode_ms': 4})
        self.store.progress(**self.auth(work), stage='transcribing', percent=50, timings={'load_ms': 8})
        self.store.finish(**self.auth(work), result={'text': 'I tested retries.', 'transcribe_ms': 20})
        completed = Store(self.directory.name).get('owner-a', accepted['id'])
        self.assertEqual(completed['status'], 'completed')
        edited = self.store.action('owner-a', accepted['id'], 'save', 'I tested safe retries.', completed['revision'])
        self.assertEqual(edited['original_transcript'], 'I tested retries.')
        self.assertEqual(edited['transcript'], 'I tested safe retries.')
        with self.assertRaisesRegex(ValueError, 'another device'):
            self.store.action('owner-a', accepted['id'], 'save', 'stale', completed['revision'])
        self.assertEqual(self.upload()['transcript'], 'I tested safe retries.')
        self.store.transfer('owner-a', accepted['id'], 1500)
        self.assertEqual(self.store.get('owner-a', accepted['id'])['timings']['transfer_ms'], 1500)

    def test_ownership_and_content_identity(self):
        accepted = self.upload()
        for op in (lambda: self.store.get('owner-b', accepted['id']),
                   lambda: self.store.audio('owner-b', accepted['id']),
                   lambda: self.store.action('owner-b', accepted['id'], 'delete'),
                   lambda: self.store.transfer('owner-b', accepted['id'], 5)):
            with self.assertRaisesRegex(ValueError, 'not found'): op()
        with self.assertRaisesRegex(ValueError, 'different audio'): self.upload(raw=wav(value=2000))
        self.assertNotEqual(self.upload(owner='owner-b')['id'], accepted['id'])
        self.assertNotIn('owner', accepted)
        self.assertNotIn('lease', accepted)

    def test_duplicate_concurrent_upload_and_global_single_claim(self):
        self.upload()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.upload(), range(2)))
            claims = list(pool.map(lambda _: self.store.claim(), range(2)))
        self.assertEqual(results[0]['id'], results[1]['id'])
        self.assertEqual(sum(not r.get('idle') for r in claims), 1)

    def test_cancel_delete_account_delete_reject_late_results(self):
        accepted = self.upload()
        work = self.store.claim()
        self.store.action('owner-a', accepted['id'], 'cancel')
        with self.assertRaisesRegex(ValueError, 'cancelled'):
            self.store.finish(**self.auth(work), result={'text': 'Late answer'})
        self.store.action('owner-a', accepted['id'], 'retry')
        new_work = self.store.claim()
        self.assertNotEqual(work['lease'], new_work['lease'])
        self.store.delete_owner('owner-a')
        with self.assertRaises(ValueError): self.store.finish(**self.auth(new_work), result={'text': 'Late answer'})
        with self.assertRaisesRegex(ValueError, 'unavailable'): self.upload()
        self.assertEqual(self.store.claim(), {'idle': True})
        with self.store.transaction() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM recordings').fetchone()[0], 0)

    def test_expired_lease_recovery_attempt_limit_and_retry_same_audio(self):
        accepted = self.upload()
        first = self.store.claim()
        self.expire(first)
        second = self.store.claim()
        with self.assertRaisesRegex(ValueError, 'expired'):
            self.store.progress(**self.auth(first), stage='loading')
        self.expire(second)
        third = self.store.claim()
        self.expire(third)
        self.assertEqual(self.store.claim(), {'idle': True})
        self.assertEqual(self.store.get('owner-a', accepted['id'])['status'], 'failed')
        self.store.action('owner-a', accepted['id'], 'retry')
        again = self.store.claim()
        self.assertEqual(again['content'], first['content'])
        self.assertEqual(again['id'], first['id'])
        self.store.finish(**self.auth(again), result={'error': 'No speech was transcribed.'})
        self.assertEqual(self.store.get('owner-a', accepted['id'])['status'], 'failed')

    def test_setup_state_retry_and_stale_worker_report(self):
        self.assertEqual(self.store.runtime_status()['status'],'pending')
        first=self.store.runtime_worker('start')
        self.store.runtime_worker('report',{'status':'unavailable','stage':'toolchain','message':'Missing cmake','missing_tools':['cmake']},first['generation'])
        self.assertEqual(self.store.runtime_retry('owner-a')['status'],'pending')
        new=self.store.runtime_worker('start')
        with self.assertRaisesRegex(ValueError,'replaced'):
            self.store.runtime_worker('report',{'status':'ready'},first['generation'])
        self.store.runtime_worker('report',{'status':'ready','probe_passed':True,'stage':'ready'},new['generation'])
        self.assertTrue(self.store.runtime_status()['probe_passed'])
        self.assertNotIn('generation',self.store.runtime_status())

    def test_queue_limits_and_validation(self):
        for i in range(3): self.upload(ident='recording-00000'+str(i))
        with self.assertRaisesRegex(ValueError, 'queue is full'): self.upload(ident='recording-000009')
        for raw in (b'bad', wav(value=0), wav(rate=8000), wav(seconds=.1), wav(seconds=301), self.raw[:-20]):
            with self.subTest(size=len(raw)):
                with self.assertRaises(ValueError): wav_info(raw)
        with self.assertRaises(ValueError): self.store.upload('a','recording-000010','!!!')
        with self.assertRaises(ValueError): self.store.upload('a','../escape','YWJj')
        with self.assertRaises(ValueError): self.store.transfer('owner-a',self.store.list('owner-a')[0]['id'],float('nan'))


class Child(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.jac/transcription-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)

    def fake_cli(self, sleeping=False):
        path = self.path / 'fake-whisper'
        path.write_text('#!'+shutil.which('python3')+'\nimport json, pathlib, sys, time\n'
                        +'print("main: processing audio", file=sys.stderr, flush=True)\n'
                        +'print("whisper_print_progress_callback: progress = 50%", file=sys.stderr, flush=True)\n'
                        +('time.sleep(20)\n' if sleeping else '')
                        +'out=sys.argv[sys.argv.index("-of")+1]\n'
                        +'pathlib.Path(out+".json").write_text(json.dumps({"transcription":[{"text":"I tested retries."}]}))\n')
        path.chmod(0o700)
        return str(path)

    def test_cli_contract_result_progress_and_scratch_cleanup(self):
        binary = self.fake_cli()
        progress = []
        result = worker.run_cli(binary, 'fake-model', wav(), lambda *args: progress.append(args), scratch=self.path/'scratch')
        self.assertEqual(result['text'], 'I tested retries.')
        self.assertGreater(result['transcribe_ms'], 0)
        self.assertTrue(progress)
        self.assertEqual(list((self.path/'scratch').iterdir()), [])

    def test_cancel_or_timeout_stops_only_owned_child_and_cleans_audio(self):
        binary = self.fake_cli(sleeping=True)
        for deadline, update in ((.15, lambda *a: None), (2, lambda *a: (_ for _ in ()).throw(ValueError('cancelled')))):
            began=time.monotonic()
            with self.assertRaises(ValueError):
                worker.run_cli(binary, 'fake-model', wav(), update, scratch=self.path/'scratch', deadline=deadline)
            self.assertLess(time.monotonic()-began, 5)
            self.assertEqual(list((self.path/'scratch').iterdir()), [])

    def test_bootstrap_report_is_ready_only_after_synthetic_inference(self):
        @contextmanager
        def lock():yield True
        reports=[]
        def call(name,args):
            if args.get('action')=='start':return {'generation':'fixture-generation'}
            reports.append(args['result'].copy());return args['result']
        with patch.object(worker.sys,'platform','linux'),patch.object(worker,'lane_lock',lock),patch.object(worker,'call',side_effect=call),patch.object(worker,'runtime',side_effect=[ValueError('Not installed'),('fake-cli','fake-model')]),patch.object(worker,'run_cli',return_value={'text':'The recording was saved. I tested retries before transcription started.','load_ms':2,'transcribe_ms':4}),patch.object(setup_transcription,'setup') as setup,patch.object(transcription_readiness,'publish'):
            self.assertTrue(worker.prepare_runtime('fixture-token'))
            setup.assert_called_once()
        self.assertEqual(reports[-1]['status'],'ready');self.assertTrue(reports[-1]['probe_passed'])
        with patch.object(worker.sys,'platform','linux'),patch.object(worker,'lane_lock',lock),patch.object(worker,'call',side_effect=call),patch.object(worker,'runtime',return_value=('fake-cli','fake-model')),patch.object(worker,'run_cli',return_value={'text':'Unexpected text','load_ms':2,'transcribe_ms':4}),patch.object(transcription_readiness,'publish'):
            worker.prepare_runtime('fixture-token')
        self.assertEqual(reports[-1]['status'],'unavailable');self.assertFalse(reports[-1]['probe_passed'])

    def test_bootstrap_cannot_download_on_mac_and_reports_missing_tools_on_pc(self):
        with patch.object(setup_transcription.sys,'platform','darwin'):
            with patch.object(setup_transcription.urllib.request,'urlopen',side_effect=AssertionError('Must not download')):
                with self.assertRaisesRegex(RuntimeError,'only on the Linux'):setup_transcription.setup()
        with patch.object(setup_transcription.sys,'platform','linux'),patch.object(setup_transcription.os,'geteuid',return_value=501),patch.object(setup_transcription.shutil,'which',side_effect=lambda name:None if name=='cmake' else '/usr/bin/'+name):
            reports=[]
            with patch.object(setup_transcription.urllib.request,'urlopen',side_effect=AssertionError('No download before toolchain is ready')):
                with self.assertRaisesRegex(RuntimeError,'missing cmake'):
                    setup_transcription.setup(progress=lambda *args,**kw:reports.append((args,kw)))
            self.assertEqual(reports[-1][1]['missing_tools'],['cmake'])

    def test_readiness_is_coarse_and_expires(self):
        with patch.object(transcription_readiness,'PATH',self.path/'readiness.json'):
            transcription_readiness.publish({'status':'ready','stage':'ready','probe_passed':True,'missing_tools':[],'owner':'private-owner','transcript':'private transcript'})
            public=transcription_readiness.public_status()
            self.assertEqual(public['probe'],'passed')
            self.assertNotIn('owner',public);self.assertNotIn('transcript',public)
            with patch.object(transcription_readiness.time,'time',return_value=time.time()+60):
                self.assertEqual(transcription_readiness.public_status()['state'],'pending')

    def test_missing_runtime_is_explicit_and_never_downloads(self):
        with patch.dict(os.environ, {'STACK_TRANSCRIPTION_CLI':str(self.path/'missing'),'STACK_TRANSCRIPTION_MODEL':str(self.path/'missing-model')}):
            with self.assertRaisesRegex(ValueError, 'PC|setup'): worker.runtime()

if __name__=='__main__': unittest.main()
