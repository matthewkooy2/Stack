"""Real Jac API, graph persistence, private worker leases and optional real model."""
import base64
import json
import os
from pathlib import Path
import resource
import tempfile
import time
import unittest
from unittest.mock import patch
if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Story verification requires disposable embedded data; unset JAC_DB_URL.')
os.environ['JAC_DB_SCRATCH']='1'
from jaclang.testing.testing import JacTestClient
from agents import contracts, worker
from tests.test_stories import FIXTURE, proposal
from tests.test_transcription import wav

ROOT=Path(__file__).resolve().parents[1]
TOKEN='fictional-story-worker'

class API(unittest.TestCase):
    def setUp(self):
        scratch=ROOT/'.jac/story-api-tests';scratch.mkdir(parents=True,exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=scratch);self.addCleanup(self.tmp.cleanup)
        self.config=Path(self.tmp.name)/'config.json'
        self.config.write_text(json.dumps({'provider':os.environ.get('STACK_STORY_MODEL_PROVIDER','ollama'),'model':os.environ.get('STACK_STORY_MODEL','qwen3:4b-instruct'),
            'local_model_url':os.environ.get('STACK_STORY_MODEL_URL','http://127.0.0.1:11434'),
            'max_output_tokens':1800,'local_model_timeout':90}))
        env=patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(self.config),
            'STACK_AGENT_WORKER_TOKEN':TOKEN,'STACK_TRANSCRIPTION_STORAGE':str(Path(self.tmp.name)/'audio')})
        env.start();self.addCleanup(env.stop)
        self.client=JacTestClient.from_file(str(ROOT/'main.jac'),base_path=self.tmp.name)
        self.addCleanup(self.client.close)
        self.a=self.client.register_user('fictional-story-a','Fixture-password-a-123').data['token']
        self.b=self.client.register_user('fictional-story-b','Fixture-password-b-456').data['token']
        self.client.set_auth_token(self.a)
        self.rpc('agent_save_policy',{'policy':{'enabled':True,'actions':['model'],'expires_at':time.time()+3600}})

    def rpc(self,name,args=None):
        response=self.client.post('/function/'+name,json=args or {})
        self.assertTrue(response.ok,response.text)
        return response.data['result']

    def system(self,name,args=None):
        self.client.clear_auth()
        try:return self.rpc(name,{'token':TOKEN,**(args or {})})
        finally:self.client.set_auth_token(self.a)

    def source(self,event):
        self.rpc('agent_save_facts',{'facts':[{'key':'resume.'+event['id'],'value':event['text'],
            'source':FIXTURE['label'],'verified':True}]})
        return next(s for s in self.rpc('story_sources')['sources'] if s['key']=='fact:resume.'+event['id'])

    def create(self,source,title):
        return self.rpc('story_create',{'source_key':source['key'],'source_revision':source['revision'],
            'excerpt':source['text'],'title':title,'reviewed_single_event':True})

    def finish(self,claim,value):
        return self.system('agent_finish',{**{k:claim[k] for k in ('id','owner','lease')},'result':{'artifact':value}})

    def test_api_worker_storage_corrections_isolation_and_delete(self):
        event=FIXTURE['events'][0];src=self.source(event);story=self.create(src,'Fictional retry event')
        self.assertIn('result',[q['field'] for q in story['missing']])
        run=self.rpc('story_generate',{'id':story['id'],'revision':0})
        claim=self.system('agent_claim');self.assertEqual(claim['id'],run['id'])
        self.assertIn('error',self.rpc('agent_finish',{**{k:claim[k] for k in ('id','owner','lease')},'token':TOKEN,'result':{}}))
        self.assertIn('error',self.system('agent_finish',{**{k:claim[k] for k in ('id','owner','lease')},'lease':'wrong','result':{}}))
        self.assertEqual(self.finish(claim,proposal(event,src['key']))['status'],'completed')
        self.assertIn('error',self.finish(claim,proposal(event,src['key'])))
        saved=self.rpc('story_get',{'id':story['id']});self.assertEqual(saved['revision'],1)
        self.assertEqual(len(self.rpc('story_list',{'topic':'ownership'})['stories']),1)
        run=self.rpc('story_generate',{'id':story['id'],'revision':1});claim=self.system('agent_claim')
        changed=self.rpc('story_save',{'id':story['id'],'revision':1,'fields':{'result':'I have not measured production outcomes.'}})
        self.assertEqual(self.finish(claim,proposal(event,src['key']))['status'],'blocked')
        self.assertIn('error',self.rpc('story_generate',{'id':story['id'],'revision':2}))
        self.assertIn('error',self.rpc('story_save',{'id':story['id'],'revision':1,'fields':{'result':'stale'}}))
        self.client.reload();self.client.set_auth_token(self.a)
        reloaded=self.rpc('story_get',{'id':story['id']});self.assertEqual(reloaded,changed)
        self.assertEqual(reloaded['history'][-1]['content']['fields']['result']['quote'],event['fields']['result'])
        self.assertEqual(self.rpc('account_export')['stories'][0],reloaded)
        self.client.set_auth_token(self.b)
        self.assertEqual(self.rpc('story_list')['stories'],[])
        self.assertEqual(self.rpc('story_sources')['sources'],[])
        for name,args in [('story_get',{'id':story['id']}),('story_save',{'id':story['id'],'revision':2,'fields':{'result':'stolen'}}),
                          ('story_generate',{'id':story['id'],'revision':2}),('story_delete',{'id':story['id'],'revision':2}),
                          ('story_create',{'source_key':src['key'],'source_revision':src['revision'],'excerpt':src['text'],'title':'foreign','reviewed_single_event':True})]:
            self.assertIn('error',self.rpc(name,args))
        self.client.set_auth_token(self.a)
        self.assertTrue(self.rpc('story_delete',{'id':story['id'],'revision':2})['deleted'])
        self.assertEqual(self.rpc('story_list')['stories'],[])

    def test_confirmed_imported_resume_sources_revision_and_isolation(self):
        # A real uploaded fixture uses the ordinary resume import/confirmation API.
        raw=(ROOT/'tests/fixtures/synthetic-resume.pdf').read_bytes()
        state=self.rpc('upload_resume',{'name':'Fictional-history.pdf','content':base64.b64encode(raw).decode()})
        rid=state['resumes'][-1]['id']
        claim=self.system('resume_processing_claim')
        self.assertEqual(claim['kind'],'import')
        event=FIXTURE['events'][0]
        records=[{'id':'r0','kind':'paragraph','text':event['text']}]
        done=self.system('resume_processing_finish',{**{k:claim[k] for k in ('id','owner','lease')},'result':{'records':records}})
        self.assertTrue(done['saved'],done)
        self.assertEqual(self.rpc('story_sources')['sources'],[])
        review=self.rpc('agent_extract_resume',{'id':rid})
        self.assertFalse(review['confirmed'])
        confirmed=self.rpc('resume_save_records',{'id':rid,'revision':review['revision'],'records':records,'confirm':True})
        src=self.rpc('story_sources')['sources'][0]
        self.assertEqual(src['kind'],'reviewed_resume_records')
        self.assertEqual(src['text'],event['text'])
        story=self.create(src,'Confirmed fictional resume event')
        revised=[{'id':'r0','kind':'paragraph','text':event['text']+' I corrected the timing.'}]
        withdrawn=self.rpc('resume_save_records',{'id':rid,'revision':confirmed['revision'],'records':revised,'confirm':False})
        self.assertEqual(self.rpc('story_sources')['sources'],[])
        self.assertIn('error',self.create(src,'withdrawn source'))
        self.rpc('resume_save_records',{'id':rid,'revision':withdrawn['revision'],'records':revised,'confirm':True})
        fresh=self.rpc('story_sources')['sources'][0]
        self.assertNotEqual(fresh['revision'],src['revision'])
        self.assertIn('error',self.create(src,'stale source'))
        self.client.reload();self.client.set_auth_token(self.a)
        self.assertEqual(self.rpc('story_get',{'id':story['id']})['source']['text'],event['text'])
        self.assertEqual(self.rpc('story_sources')['sources'][0],fresh)
        self.client.set_auth_token(self.b)
        self.assertEqual(self.rpc('story_sources')['sources'],[])
        self.assertIn('error',self.create(fresh,'foreign source'))
        self.client.set_auth_token(self.a)
        self.rpc('change_resume',{'id':rid,'action':'delete'})
        self.assertEqual(self.rpc('story_sources')['sources'],[])
        self.assertEqual(self.rpc('story_get',{'id':story['id']})['source']['text'],event['text'])

    def test_recorded_sources_revisions_missing_outcomes_and_separate_events(self):
        event=FIXTURE['events'][1]
        rec=self.rpc('transcription_upload',{'client_id':'fictional-story-recording-001','content':base64.b64encode(wav()).decode()})
        claim=self.system('transcription_processing_claim')
        self.system('transcription_processing_finish',{**{k:claim[k] for k in ('id','owner','lease')},'result':{'text':event['text']}})
        src=self.rpc('story_sources')['sources'][0];story=self.create(src,'Fictional disagreement')
        self.rpc('transcription_action',{'id':rec['id'],'action':'save','revision':1,'text':event['text']+' I corrected the timing.'})
        self.assertIn('error',self.create(src,'stale'))
        self.assertEqual(self.rpc('story_get',{'id':story['id']})['source']['text'],event['text'])
        self.assertEqual(story['source']['original_transcript'],event['text'])
        self.rpc('story_generate',{'id':story['id'],'revision':0});claim=self.system('agent_claim')
        hostile=proposal(event,src['key']);hostile['fields']['result']['quote']='Revenue doubled.'
        self.assertEqual(self.finish(claim,hostile)['status'],'blocked')
        self.rpc('story_generate',{'id':story['id'],'revision':0});claim=self.system('agent_claim')
        self.assertEqual(self.finish(claim,proposal(event,src['key']))['status'],'completed')
        value=self.rpc('story_get',{'id':story['id']});self.assertIn('result',[q['field'] for q in value['missing']])
        other=self.create(self.source(FIXTURE['events'][2]),'Fictional school')
        self.assertNotEqual(other['id'],story['id']);self.assertEqual(len(self.rpc('story_list')['stories']),2)
        self.assertTrue(self.rpc('account_delete',{'username':'fictional-story-a','password':'Fixture-password-a-123'})['deleted'])
        self.assertTrue(self.system('agent_claim')['idle'])

    @unittest.skipUnless(os.environ.get('STACK_STORY_REAL_MODEL')=='1','Opt-in real local inference')
    def test_real_worker_inference_fixed_histories(self):
        evidence=[]
        for event in FIXTURE['events']:
            source=self.source(event);story=self.create(source,'Fictional '+event['id'])
            self.rpc('story_generate',{'id':story['id'],'revision':0});claim=self.system('agent_claim')
            def call(name,args):return self.system(name,{k:v for k,v in args.items() if k!='token'})
            start=time.monotonic()
            with patch.object(worker,'call',side_effect=call):result=worker.dispatch(claim,TOKEN)
            done=self.system('agent_finish',{**{k:claim[k] for k in ('id','owner','lease')},'result':result})
            self.assertEqual(done['status'],'completed',done)
            saved=self.rpc('story_get',{'id':story['id']})
            for item in saved['content']['evidence']:self.assertIn(item['quote'],event['text'])
            if event['id']=='retry':
                self.assertTrue(saved['content']['fields']['personal']['quote'])
                self.assertTrue(saved['content']['fields']['team']['quote'])
                self.assertTrue(saved['content']['fields']['result']['quote'])
            else:self.assertIn('result',[q['field'] for q in saved['missing']])
            self.assertTrue(saved['content']['topics'])
            evidence.append({'fixture':event['id'],'elapsed_seconds':round(time.monotonic()-start,3),'content':saved['content'],
                'model_logs':self.rpc('agent_model_logs',{'id':claim['id']}),'test_process_max_rss_kib':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
        (ROOT/'.jac/story-real-evidence.json').write_text(json.dumps(evidence,indent=2))
        self.client.reload();self.client.set_auth_token(self.a)
        self.assertEqual(len(self.rpc('story_list')['stories']),3)

if __name__=='__main__':unittest.main()
