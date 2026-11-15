"""Practice interview library: real Jac API, graph persistence and worker leases.
Coaching replies are fixture text supplied through agent_finish, never claimed as a real model."""
import base64
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Practice library verification requires disposable embedded data; unset JAC_DB_URL.')
os.environ['JAC_DB_SCRATCH']='1'
from jaclang.testing.testing import JacTestClient
from tests.test_transcription import wav

ROOT=Path(__file__).resolve().parents[1]
TOKEN='fictional-practice-worker'
BANK=json.loads((ROOT/'agents/data/practice_questions.json').read_text())

def coaching(scores, text='Strength: you named your own actions. Improvement: add the result.'):
    return {'text':text+'\n\nSCORES\n'+'\n'.join(f'{k.title()}: {v}/4' for k,v in scores.items()),'summary':text}

class Parsing(unittest.TestCase):
    def test_score_requires_all_four_criteria(self):
        from agents import practice
        full=practice.parse_score(coaching({'specificity':4,'ownership':3,'structure':2,'reflection':3})['text'])
        self.assertEqual(full['score'],75)
        self.assertNotIn('SCORES',full['feedback']);self.assertIn('Improvement',full['feedback'])
        partial=practice.parse_score('Good answer.\nSpecificity: 3/4')
        self.assertIsNone(partial['score']);self.assertEqual(partial['rubric'],{'specificity':3.0})
        self.assertIsNone(practice.parse_score('No scores here.')['score'])
        ranked=practice.rank([{'score':None,'created_at':3},{'score':50,'created_at':1},{'score':90,'created_at':0},{'score':50,'created_at':2}])
        self.assertEqual([(a['score'],a['created_at']) for a in ranked],[(90,0),(50,2),(50,1),(None,3)])

class API(unittest.TestCase):
    def setUp(self):
        scratch=ROOT/'.jac/practice-api-tests';scratch.mkdir(parents=True,exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=scratch);self.addCleanup(self.tmp.cleanup)
        config=Path(self.tmp.name)/'config.json'
        config.write_text(json.dumps({'provider':'ollama','model':'qwen3:4b-instruct','local_model_url':'http://127.0.0.1:11434',
            'max_output_tokens':1800,'local_model_timeout':90}))
        env=patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(config),'STACK_AGENT_WORKER_TOKEN':TOKEN,
            'STACK_TRANSCRIPTION_STORAGE':str(Path(self.tmp.name)/'audio')})
        env.start();self.addCleanup(env.stop)
        self.client=JacTestClient.from_file(str(ROOT/'main.jac'),base_path=self.tmp.name)
        self.addCleanup(self.client.close)
        self.a=self.client.register_user('fictional-practice-a','Fixture-password-a-123').data['token']
        self.b=self.client.register_user('fictional-practice-b','Fixture-password-b-456').data['token']
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

    def score(self,attempt,scores):
        claim=self.system('agent_claim');self.assertEqual(claim['id'],attempt['run']['id'])
        self.assertEqual(claim['step'],'coach')
        self.assertEqual(claim['context']['session']['mode'],'library')
        self.assertEqual(claim['context']['problem']['id'],attempt['question_id'])
        done=self.system('agent_finish',{**{k:claim[k] for k in ('id','owner','lease')},'result':{'artifact':coaching(scores)}})
        self.assertEqual(done['status'],'completed',done)
        return self.rpc('practice_attempt_get',{'id':attempt['id']})

    def test_industry_slots_scoring_ranking_delete_and_isolation(self):
        self.assertTrue(self.rpc('practice_slots')['needs_industry'])
        self.assertEqual(self.rpc('bootstrap')['profile']['industry'],'')
        self.assertIn('error',self.rpc('practice_profile',{'industry':'astrology'}))
        self.assertEqual(self.rpc('practice_profile',{'industry':'software'})['industry'],'software')
        self.assertEqual(self.rpc('bootstrap')['profile']['industry'],'software')
        self.assertIn('error',self.rpc('practice_slots',{'track':'technical'}))
        slots=self.rpc('practice_slots')['slots']
        ids=[s['question']['id'] for s in slots]
        expected=[q['id'] for q in BANK['questions'] if '*' in q['industries'] or 'software' in q['industries']]
        self.assertEqual(sorted(ids),sorted(expected));self.assertIn('lib-tech-bug',ids);self.assertNotIn('lib-fin-detail',ids)
        self.assertEqual(ids[0],'lib-intro');self.assertTrue(all(s['attempt_count']==0 and s['best']=={} for s in slots))

        qid='lib-proud'
        self.assertIn('error',self.rpc('practice_attempt_create',{'question_id':qid,'client_id':'c-0','answer':'  '}))
        self.assertIn('error',self.rpc('practice_attempt_create',{'question_id':'lib-missing','client_id':'c-0','answer':'x'}))
        rec=self.rpc('transcription_upload',{'client_id':'fictional-practice-rec-1','content':base64.b64encode(wav()).decode(),
            'local_transcript':'I led the migration and cut build time in half.'})
        first=self.rpc('practice_attempt_create',{'question_id':qid,'client_id':'c-1','answer':'I led the migration and cut build time in half.',
            'recording_id':rec['id'],'video_id':'video-1','duration':42.5})
        self.assertNotIn('error',first);self.assertEqual(first['status'],'queued');self.assertIsNone(first['score'])
        self.assertEqual(first['video_id'],'video-1')
        reread=self.rpc('practice_attempt_get',{'id':first['id']})
        self.assertEqual((reread['status'],reread['run']['id']),('queued',first['run']['id']))
        again=self.rpc('practice_attempt_create',{'question_id':qid,'client_id':'c-1','answer':'duplicate'})
        self.assertEqual(again['id'],first['id'])
        first=self.score(first,{'specificity':2,'ownership':2,'structure':2,'reflection':2})
        self.assertEqual((first['status'],first['score']),('scored',50))
        self.assertEqual(first['rubric']['ownership'],2.0);self.assertNotIn('SCORES',first['feedback'])

        second=self.rpc('practice_attempt_create',{'question_id':qid,'client_id':'c-2','answer':'Better STAR answer.','video_id':'video-2'})
        second=self.score(second,{'specificity':4,'ownership':4,'structure':3,'reflection':3})
        self.assertEqual(second['score'],88)
        third=self.rpc('practice_attempt_create',{'question_id':qid,'client_id':'c-3','answer':'Unparsed answer.'})
        claim=self.system('agent_claim')
        self.system('agent_finish',{**{k:claim[k] for k in ('id','owner','lease')},'result':{'artifact':{'text':'Nice work.','summary':'Nice work.'}}})
        self.assertEqual(self.rpc('practice_attempt_get',{'id':third['id']})['status'],'unscored')

        slot=next(s for s in self.rpc('practice_slots')['slots'] if s['question']['id']==qid)
        self.assertEqual((slot['attempt_count'],slot['best']['id']),(3,second['id']))
        listed=self.rpc('practice_attempts',{'question_id':qid})['attempts']
        self.assertEqual([a['id'] for a in listed],[second['id'],first['id'],third['id']])
        self.assertEqual([s for s in self.rpc('prep_sessions')['sessions'] if s['data'].get('mode')=='library'],[])
        self.assertIn('error',self.rpc('prep_save',{'id':first['id'],'revision':0,'data':{'problem_id':qid}}))

        self.client.set_auth_token(self.b)
        self.assertIn('error',self.rpc('practice_attempt_get',{'id':first['id']}))
        self.assertIn('error',self.rpc('practice_attempt_delete',{'id':first['id']}))
        self.assertTrue(self.rpc('practice_slots')['needs_industry'])
        self.client.set_auth_token(self.a)

        self.client.reload();self.client.set_auth_token(self.a)
        self.assertEqual(self.rpc('practice_attempt_get',{'id':second['id']})['score'],88)
        self.assertTrue(self.rpc('practice_attempt_delete',{'id':first['id']})['deleted'])
        self.assertIn('error',self.rpc('practice_attempt_get',{'id':first['id']}))
        self.assertIn('error',self.rpc('transcription_get',{'id':rec['id']}))
        self.assertEqual(len(self.rpc('practice_attempts',{'question_id':qid})['attempts']),2)

if __name__=='__main__':unittest.main()
