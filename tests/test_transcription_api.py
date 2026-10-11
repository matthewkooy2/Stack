"""Owner and private-worker boundaries through real Jac endpoints, isolated SSD data."""
import base64
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from jaclang.testing.testing import JacTestClient
from tests.test_transcription import wav

ROOT=Path(__file__).resolve().parents[1]
TOKEN='transcription-fixture-worker'

class API(unittest.TestCase):
    def setUp(self):
        scratch=ROOT/'.jac/transcription-api-tests';scratch.mkdir(parents=True,exist_ok=True)
        self.directory=tempfile.TemporaryDirectory(dir=scratch);self.addCleanup(self.directory.cleanup)
        config=Path(self.directory.name)/'config.json';config.write_text('{"invite_only":false}')
        env=patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(config),'STACK_AGENT_WORKER_TOKEN':TOKEN,'STACK_TRANSCRIPTION_STORAGE':str(Path(self.directory.name)/'audio')})
        env.start();self.addCleanup(env.stop)
        self.client=JacTestClient.from_file(str(ROOT/'main.jac'),base_path=self.directory.name)
        self.addCleanup(self.client.close)
        self.token=self.client.register_user('transcription-owner','Password-fixture-123').data['token']

    def rpc(self,name,args=None):
        response=self.client.post('/function/'+name,json=args or {})
        self.assertTrue(response.ok,response.text)
        return response.data['result']

    def worker(self,name,args=None):
        self.client.clear_auth()
        try:return self.rpc(name,{'token':TOKEN,**(args or {})})
        finally:self.client.set_auth_token(self.token)

    def test_auth_replay_reopen_job_edit_and_owner_export(self):
        self.client.clear_auth()
        self.assertFalse(self.client.post('/function/transcription_list',json={}).ok)
        self.client.set_auth_token(self.token)
        args={'client_id':'recording-api-000001','content':base64.b64encode(wav()).decode()}
        accepted=self.rpc('transcription_upload',args)
        self.assertEqual(accepted['status'],'queued')
        self.client.reload();self.client.set_auth_token(self.token)
        self.assertEqual(self.rpc('transcription_upload',args)['id'],accepted['id'])
        self.assertIn('error',self.rpc('transcription_processing_claim',{'token':TOKEN}))
        self.assertIn('error',self.worker('transcription_processing_claim',{'token':'wrong'}))
        setup=self.worker('transcription_processing_runtime',{'action':'start'})
        self.assertIn('error',self.rpc('transcription_processing_runtime',{'token':TOKEN}))
        self.assertTrue(self.worker('transcription_processing_runtime',{'action':'report','generation':setup['generation'],'result':{'status':'ready','probe_passed':True,'stage':'ready'}})['probe_passed'])
        self.assertTrue(self.rpc('transcription_list')['runtime']['probe_passed'])
        work=self.worker('transcription_processing_claim')
        auth={k:work[k] for k in ('id','owner','lease')}
        self.assertTrue(self.worker('transcription_processing_finish',{**auth,'result':{'text':'I tested retries.'}})['saved'])
        edited=self.rpc('transcription_action',{'id':accepted['id'],'action':'save','text':'I tested safe retries.','revision':1})
        self.assertEqual(edited['original_transcript'],'I tested retries.')
        self.assertEqual(self.rpc('account_export')['recordings'][0]['transcript'],'I tested safe retries.')
        self.assertEqual(base64.b64decode(self.rpc('transcription_audio',{'id':accepted['id']})['content']),wav())
        other=self.client.register_user('different-owner','Password-fixture-456').data['token']
        self.assertIn('error',self.rpc('transcription_get',{'id':accepted['id']}))
        self.assertEqual(self.rpc('transcription_list')['recordings'],[])
        self.client.set_auth_token(self.token)
        self.assertTrue(self.rpc('account_delete',{'username':'transcription-owner','password':'Password-fixture-123'})['deleted'])
        self.assertEqual(self.worker('transcription_processing_claim'),{'idle':True})

    def test_phone_original_edit_replay_owner_and_delete(self):
        args={'client_id':'phone-api-recording-000001','content':base64.b64encode(wav()).decode(),
              'local_transcript':'A phone recognized original.'}
        self.client.clear_auth()
        self.assertFalse(self.client.post('/function/transcription_upload',json=args).ok)
        self.client.set_auth_token(self.token)
        accepted=self.rpc('transcription_upload',args)
        self.assertTrue(self.rpc('transcription_list')['client_transcripts'])
        self.assertEqual(accepted['status'],'completed')
        self.assertEqual(self.worker('transcription_processing_claim'),{'idle':True})

        edited=self.rpc('transcription_action',{'id':accepted['id'],'action':'save','text':'Reviewed correction.','revision':1})
        self.client.reload();self.client.set_auth_token(self.token)
        replay=self.rpc('transcription_upload',args)
        self.assertEqual((replay['id'],replay['transcript'],replay['original_transcript']),
                         (accepted['id'],edited['transcript'],args['local_transcript']))
        self.assertIn('error',self.rpc('transcription_upload',{**args,'local_transcript':'Replacement.'}))
        self.assertIn('error',self.rpc('transcription_action',{'id':accepted['id'],'action':'save','text':'Stale','revision':1}))
        self.client.register_user('phone-other-owner','Password-fixture-456')
        for endpoint,body in [('transcription_get',{'id':accepted['id']}),
                              ('transcription_audio',{'id':accepted['id']}),
                              ('transcription_action',{'id':accepted['id'],'action':'save','text':'Other','revision':2})]:
            self.assertIn('error',self.rpc(endpoint,body))
        other=self.rpc('transcription_upload',args)
        self.assertNotEqual(other['id'],accepted['id'])
        self.client.set_auth_token(self.token)
        exported=self.rpc('account_export')['recordings']
        self.assertEqual(exported[0]['original_transcript'],args['local_transcript'])
        self.assertEqual(exported[0]['transcript'],'Reviewed correction.')
        self.assertTrue(self.rpc('account_delete',{'username':'transcription-owner','password':'Password-fixture-123'})['deleted'])
        self.assertEqual(self.worker('transcription_processing_claim'),{'idle':True})

    def test_phone_validation_and_empty_original_preserve_pc_fallback(self):
        args={'client_id':'phone-api-validation-000001','content':base64.b64encode(wav()).decode()}
        self.assertIn('error',self.rpc('transcription_upload',{**args,'local_transcript':'x'*30001}))
        self.assertIn('error',self.rpc('transcription_upload',{**args,'content':base64.b64encode(b'not a wav').decode(),
                                                             'local_transcript':'A recognized original.'}))
        self.assertIn('error',self.rpc('transcription_upload',{**args,'content':base64.b64encode(wav(value=0)).decode(),
                                                             'local_transcript':'A recognized original.'}))
        self.assertEqual(self.rpc('transcription_list')['recordings'],[])
        fallback=self.rpc('transcription_upload',{**args,'local_transcript':'   '})
        self.assertEqual((fallback['status'],fallback['model'],fallback['revision']),('queued','whisper.cpp/base.en',0))
        self.assertEqual(fallback['original_transcript'],'')
        claimed=self.worker('transcription_processing_claim')
        self.assertEqual(claimed['id'],fallback['id'])
        before=self.rpc('transcription_get',{'id':fallback['id']})
        self.assertIn('error',self.rpc('transcription_upload',{**args,'local_transcript':'Cannot replace the PC job.'}))
        self.assertEqual(self.rpc('transcription_get',{'id':fallback['id']}),before)
        empty=self.rpc('transcription_upload',{**args,'client_id':'phone-api-empty-original-000001','local_transcript':''})
        self.assertEqual((empty['status'],empty['model'],empty['original_transcript']),('queued','whisper.cpp/base.en',''))

if __name__=='__main__':unittest.main()
