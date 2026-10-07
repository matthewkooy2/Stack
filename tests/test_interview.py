"""Fixed synthetic acceptance through persisted account APIs and real worker dispatch.

The controlled HTTP model is fixture inference, never claimed as a real model.
Run with the pinned Jac CLI. An opt-in live script reuses this same journey.
"""
import base64
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
import wave
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import patch

if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Interview acceptance requires a disposable scratch database.')
os.environ['JAC_DB_SCRATCH'] = '1'
from jaclang.testing.testing import JacTestClient
from agents.worker import dispatch
from agents import interview as flow
from discovery.normalize import normalize, digest

ANSWER1 = 'I built a SQL tracker for a class project. I inspected the query plan and added an index. I verified the result with fixture queries.'
ANSWER2 = 'I compared indexed and full table scans on our fixture data. I explained the write overhead to my teammate. We chose the index for the read-heavy tracker.'
CORRECTED = 'I compared indexed and full table scans on our fixture data. I explained the write overhead to my teammate. We kept the full table scan for the small class tracker.'
FACT = {'key':'resume.project', 'value':'Built a SQL tracker for a class project', 'verified':True}
DESCRIPTION = 'Build SQL-backed tools and explain query performance tradeoffs. Collaborate with teammates and verify changes using tests.'

@contextmanager
def fixture_model():
    state={'mode':'valid','requests':[]}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_POST(self):
            payload=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            state['requests'].append(payload)
            if state['mode']=='malformed': body=b'{malformed'
            else:
                task=json.loads(payload['messages'][1]['content'])
                answers=task['context']['interview']['answer_sources']
                if 'focus_quote' in payload['response_format']['json_schema']['schema']['properties']:
                    source=task['context']['interview']['latest_source'];answer=answers[source]
                    quote='query plan' if 'query plan' in answer else 'write overhead'
                    artifact={'question':flow.QUESTIONS[1] if 'query plan' in answer else flow.QUESTIONS[2],
                        'focus_quote':quote,'strength':flow.STRENGTHS[0],
                        'improvement':flow.IMPROVEMENTS[1],
                        'evidence':[{'source':source,'quote':quote,'claim':'Reviewed answer excerpt'}]}
                    if state['mode']=='invented': artifact['focus_quote']='Invented ten million dollars'
                    if state['mode']=='fabricated_prose': artifact['strength']='You were CEO and grew revenue by ten million dollars.'
                    if state['mode']=='unrelated_question': artifact['question']='Describe your Mars mission.'
                else:
                    artifact={'summary':flow.SUMMARY,
                        'strengths':[{'criterion':'Verification','source':next(iter(answers)),'quote':next(iter(answers.values()))}],
                        'rubric':[{'criterion':criterion,'score':3,'feedback':flow.IMPROVEMENTS[i%3]} for i,criterion in enumerate(flow.CRITERIA)],
                        'next_exercises':[flow.EXERCISES[1]],
                        'followup_questions':list(flow.QUESTIONS[1:3]),
                        'evidence':[{'source':source,'quote':answer,'claim':'Reviewed answer excerpt'} for source,answer in answers.items()]}
                body=json.dumps({'model':'qwen-fixture','choices':[{'finish_reason':'stop','message':{'content':json.dumps(artifact)}}]}).encode()
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try: yield 'http://127.0.0.1:'+str(server.server_port),state
    finally: server.shutdown();server.server_close();thread.join(2)

class Journey:
    def __init__(self, directory, url, model='qwen-fixture', provider='lmstudio'):
        self.path=Path(directory)/'config.json'
        self.path.write_text(json.dumps({'provider':provider,'model':model,'local_model_url':url,
            'max_output_tokens':1600,'local_model_context_tokens':16384,'capture_agent_content':True,'local_cli_daily_limit':1}))
        self.env=patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(self.path),'STACK_AGENT_WORKER_TOKEN':'mat5-synthetic-worker',
            'STACK_TRANSCRIPTION_STORAGE':str(Path(directory)/'recordings'),'STACK_LOCAL_MODEL_API_KEY':''})
        self.env.start()
        self.client=JacTestClient.from_file(str(Path('main.jac').resolve()),base_path=str(Path(directory)/'db'))
        self.tokens=[];self.timings=[]
        for user in ('interview-alice','interview-bob'):
            result=self.client.register_user(user,'Synthetic-interview-password-123');assert result.ok,result.text
            self.tokens.append(result.data['token'])
            self.rpc('agent_settings')
            self.rpc('agent_save_policy',{'policy':{'enabled':True,'expires_at':time.time()+3600,'actions':['model']}})
        self.client.set_auth_token(self.tokens[0])
        # Seed a normalized catalog listing through token-gated discovery APIs, then save it as the user.
        worker_file=Path('storage/discovery/worker-token');worker_file.parent.mkdir(parents=True,exist_ok=True)
        if not worker_file.exists(): worker_file.write_text('mat5-synthetic-discovery')
        discovery_token=worker_file.read_text().strip();url='https://example.com/mat5-role'
        self.rpc('import_job_url',{'url':url});self.client.clear_auth()
        work=self.rpc('discovery_claim',{'token':discovery_token,'preferred_id':'career:'+digest(url)})
        assert not work.get('idle'),work
        job=normalize({'title':'SQL Tools Engineer','company':'Synthetic class team','url':url+'/engineer',
                       'country':'US','location':'Detroit, MI','description':DESCRIPTION,'posted_at':time.time()},work['config'])
        self.rpc('discovery_complete',{'token':discovery_token,'id':work['id'],'lease':work['lease'],
            'result':{'jobs':[job],'complete':True}})
        self.client.set_auth_token(self.tokens[0]);self.rpc('swipe',{'job_id':job['id'],'action':'apply'})
        self.application=self.rpc('bootstrap')['applications'][0]['id']
        self.rpc('agent_save_facts',{'facts':[FACT]})
        self.session=self.rpc('interview_create',{'application_id':self.application,'client_id':'fixed-interview-create'})
        assert 'SQL' in self.session['data']['questions'][0]['question']
        assert 'resume.project' in self.session['data']['questions'][1]['evidence'][0]['source']
    def close(self): self.client.close();self.env.stop()
    def rpc(self,name,args=None,allow_error=False):
        response=self.client.post('/function/'+name,json=args or {});assert response.ok,response.text
        data=response.data['result']
        if not allow_error: assert 'error' not in data,(name,data)
        return data
    def get(self): return self.rpc('interview_get',{'id':self.session['id']})
    def answer(self,text,recording_id=''):
        current=self.get();self.session=self.rpc('interview_answer',{'id':current['id'],'revision':current['revision'],
            'answer':text,'client_id':'answer-'+str(len(current['data']['turns'])),'recording_id':recording_id})
        return self.session
    def work(self,finish=True):
        self.client.clear_auth();work=self.rpc('agent_claim',{'token':'mat5-synthetic-worker'})
        assert not work.get('idle'),work
        start=time.monotonic()
        with patch('agents.worker.call',side_effect=self.rpc): result=dispatch(work,'mat5-synthetic-worker')
        self.timings.append({'step':work['step'],'seconds':round(time.monotonic()-start,3)})
        if finish:self.rpc('agent_finish',{'token':'mat5-synthetic-worker',**{k:work[k] for k in ('id','owner','lease')},'result':result})
        self.client.set_auth_token(self.tokens[0]);return work,result
    def complete(self):
        self.answer(ANSWER1);self.work()
        current=self.get();first=current['data']['analysis']['1'];assert first['focus_quote'] in ANSWER1
        self.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'followup'})
        assert first['question'] in self.get()['data']['questions'][1]['question']
        assert first['focus_quote'] in self.get()['data']['questions'][1]['question']
        assert DESCRIPTION.split('.')[0] in self.get()['data']['questions'][1]['question']
        self.answer(ANSWER2);self.work()
        current=self.get();assert current['data']['analysis']['2']['focus_quote'] in ANSWER2
        assert flow.followup(current['data']['analysis']['2'],current['data'])!=flow.followup(first,current['data'])
        current=self.rpc('interview_correct',{'id':current['id'],'revision':current['revision'],'index':1,'answer':CORRECTED})
        assert current['data']['turns'][1]['original']==ANSWER2
        assert not current['data']['coaching'] and not current['data']['analysis']
        current=self.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'finish'})
        self.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'analyze'})
        work,result=self.work();assert work['context']['interview']['answer_sources']['answer:2']==CORRECTED
        assert result['artifact']['evidence']
        self.client.reload();self.client.set_auth_token(self.tokens[0]);current=self.get()
        assert current['data']['status']=='finished' and current['data']['coaching']==result['artifact']
        return current

class InterviewAcceptance(unittest.TestCase):
    def test_complete_persisted_worker_journey_and_account_isolation(self):
        with tempfile.TemporaryDirectory() as directory,fixture_model() as (url,state):
            journey=Journey(directory,url)
            try:
                done=journey.complete();self.assertEqual(len(state['requests']),3)
                for payload in state['requests']:self.assertEqual(payload['model'],'qwen-fixture')
                journey.client.set_auth_token(journey.tokens[1])
                for endpoint,args in [('interview_get',{'id':done['id']}),('interview_correct',{'id':done['id'],'revision':done['revision'],'index':0,'answer':'Other user'}),
                    ('interview_answer',{'id':done['id'],'revision':done['revision'],'answer':'Other user','client_id':'other'}),
                    ('interview_continue',{'id':done['id'],'revision':done['revision'],'action':'finish'}),
                    ('interview_create',{'application_id':journey.application,'client_id':'other-create'})]:
                    self.assertIn('error',journey.rpc(endpoint,args,True))
                self.assertFalse(journey.rpc('prep_sessions')['sessions'])
                journey.client.set_auth_token(journey.tokens[0])
                self.assertIn('error',journey.rpc('prep_save',{'id':done['id'],'revision':done['revision'],'data':{'problem_id':'project'}},True))
                self.assertIn('error',journey.rpc('interview_answer',{'id':done['id'],'revision':done['revision'],'answer':'after finish','client_id':'finished'},True))
            finally: journey.close()
    def test_recoverable_malformed_invented_unavailable_and_typed_continuation(self):
        for mode in ('malformed','invented','fabricated_prose','unrelated_question','unavailable','cloud'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory,fixture_model() as (url,state):
                journey=Journey(directory,url)
                try:
                    state['mode']=mode;session=journey.answer(ANSWER1);pending=session['data']['pending']
                    if mode in ('unavailable','cloud'):
                        config=json.loads(journey.path.read_text());config.update(local_model_url='http://127.0.0.1:9')
                        if mode=='cloud':config.update(provider='openai',model='cloud-model')
                        journey.path.write_text(json.dumps(config))
                    if mode=='cloud':
                        journey.client.clear_auth();self.assertTrue(journey.rpc('agent_claim',{'token':'mat5-synthetic-worker'}).get('idle'));journey.client.set_auth_token(journey.tokens[0])
                    else:journey.work()
                    current=journey.get();self.assertIn(current['run']['status'],('needs_input','blocked'));self.assertEqual(current['data']['turns'][0]['answer'],ANSWER1)
                    self.assertEqual(current['run']['cost_cents'],0);self.assertEqual(current['run']['subscription_calls'],0)
                    current=journey.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'next'})
                    self.assertFalse(current['data']['pending']);journey.answer(ANSWER2)
                    current=journey.get();journey.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'finish'})
                    self.assertEqual(journey.get()['data']['status'],'finished')
                finally:journey.close()
    def test_revision_and_pending_correction_reject_stale_worker_result(self):
        with tempfile.TemporaryDirectory() as directory,fixture_model() as (url,_):
            journey=Journey(directory,url)
            try:
                original=journey.session;session=journey.answer(ANSWER1)
                duplicate=journey.rpc('interview_answer',{'id':session['id'],'revision':original['revision'],'answer':ANSWER1,'client_id':'answer-0'})
                self.assertEqual(len(duplicate['data']['turns']),1)
                self.assertIn('error',journey.rpc('interview_answer',{'id':session['id'],'revision':original['revision'],'answer':'stale','client_id':'new'},True))
                work,result=journey.work(False)
                current=journey.get();journey.rpc('interview_correct',{'id':current['id'],'revision':current['revision'],'index':0,'answer':'I inspected a query plan but did not add an index.'})
                journey.client.clear_auth();self.assertIn('error',journey.rpc('agent_finish',{'token':'mat5-synthetic-worker',**{k:work[k] for k in ('id','owner','lease')},'result':result},True))
                journey.client.set_auth_token(journey.tokens[0]);self.assertFalse(journey.get()['data']['analysis'])
            finally:journey.close()

    def test_practice_interview_lists_and_study_plan_are_disjoint(self):
        with tempfile.TemporaryDirectory() as directory,fixture_model() as (url,_):
            journey=Journey(directory,url)
            try:
                self.assertEqual(journey.rpc('prep_sessions')['sessions'],[])
                self.assertEqual([s['id'] for s in journey.rpc('interview_sessions')['sessions']],[journey.session['id']])
                plan=journey.rpc('prep_for_application',{'application_id':journey.application})['plan']
                self.assertTrue(plan)
                self.assertNotIn(journey.session['id'],[p['session_id'] for p in plan])
                ordinary=journey.rpc('prep_sessions')['sessions']
                self.assertTrue(ordinary)
                self.assertTrue(all(s['data'].get('mode')!='interview' for s in ordinary))
                for session in ordinary:
                    self.assertIn('answer',session['data'])
                    self.assertIn('code',session['data'])
                again=journey.rpc('prep_for_application',{'application_id':journey.application})['plan']
                self.assertEqual([p['session_id'] for p in again],[p['session_id'] for p in plan])
            finally:journey.close()

    def test_actual_gateway_routes_enforce_admission_and_account_ownership(self):
        from agents import gateway
        with tempfile.TemporaryDirectory() as directory,fixture_model() as (url,_):
            journey=Journey(directory,url)
            gateway._rates.clear()
            server=gateway.ThreadingHTTPServer(('127.0.0.1',0),gateway.Handler)
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            def upstream(path,body,authorization=''):
                if authorization.startswith('Bearer '): journey.client.set_auth_token(authorization[7:])
                else: journey.client.clear_auth()
                response=journey.client.post(path,json=json.loads(body))
                return (200 if response.ok else 401),response.text.encode()
            def request(name,args=None,token=None):
                headers={'Content-Type':'application/json'}
                if token: headers['Authorization']='Bearer '+token
                try:
                    with urlopen(Request('http://127.0.0.1:'+str(server.server_port)+'/function/'+name,
                        data=json.dumps(args or {}).encode(),headers=headers)) as response:
                        return response.status,json.load(response)
                except HTTPError as error: return error.code,{}
            try:
                with patch.object(gateway,'upstream',side_effect=upstream):
                    owner,other=journey.tokens
                    for name in ('interview_create','interview_get','interview_answer','interview_correct','interview_continue','interview_sessions'):
                        self.assertIn(name,gateway.PERSONAL)
                        self.assertEqual(request(name)[0],403,name)
                    self.assertEqual(request('agent_claim',token=owner)[0],404)
                    status,result=request('interview_sessions',token=owner)
                    self.assertEqual(status,200);self.assertEqual(result['data']['result']['sessions'][0]['id'],journey.session['id'])
                    self.assertEqual(request('interview_sessions',token=other)[1]['data']['result']['sessions'],[])
                    status,result=request('interview_get',{'id':journey.session['id']},other)
                    self.assertEqual(status,200);self.assertIn('error',result['data']['result'])
                    self.assertIn('error',request('interview_create',{'application_id':journey.application,'client_id':'foreign-http'},other)[1]['data']['result'])
                    current=journey.session
                    for name,args in (
                        ('interview_answer',{'answer':'Foreign answer','client_id':'foreign-http-answer'}),
                        ('interview_correct',{'index':0,'answer':'Foreign correction'}),
                        ('interview_continue',{'action':'finish'})):
                        result=request(name,{'id':current['id'],'revision':current['revision'],**args},other)[1]
                        self.assertIn('error',result['data']['result'])
                    result=request('interview_answer',{'id':current['id'],'revision':current['revision'],'answer':ANSWER1,'client_id':'owner-http-answer'},owner)[1]
                    self.assertEqual(result['data']['result']['data']['turns'][0]['answer'],ANSWER1)
                    journey.client.set_auth_token(owner);journey.work()
                    current=request('interview_get',{'id':current['id']},owner)[1]['data']['result']
                    self.assertTrue(current['data']['analysis'])
            finally:
                server.shutdown();server.server_close();thread.join(2);journey.close()

    def test_recorded_answer_reuses_completed_owner_transcription_and_retains_original(self):
        with tempfile.TemporaryDirectory() as directory,fixture_model() as (url,_):
            journey=Journey(directory,url)
            try:
                buffer=io.BytesIO()
                with wave.open(buffer,'wb') as audio:
                    audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(16000);audio.writeframes(b'\0\0'*16000)
                recording=journey.rpc('transcription_upload',{'client_id':'mat5-recording-owner','content':base64.b64encode(buffer.getvalue()).decode()})
                current=journey.get()
                args={'id':current['id'],'revision':current['revision'],'answer':ANSWER1,'client_id':'recorded-answer','recording_id':recording['id']}
                self.assertIn('error',journey.rpc('interview_answer',args,True))
                journey.client.clear_auth()
                setup=journey.rpc('transcription_processing_runtime',{'token':'mat5-synthetic-worker','action':'start'})
                journey.rpc('transcription_processing_runtime',{'token':'mat5-synthetic-worker','action':'report','generation':setup['generation'],
                    'result':{'status':'ready','probe_passed':True,'stage':'ready'}})
                work=journey.rpc('transcription_processing_claim',{'token':'mat5-synthetic-worker'})
                self.assertTrue(journey.rpc('transcription_processing_finish',{'token':'mat5-synthetic-worker',
                    **{k:work[k] for k in ('id','owner','lease')},'result':{'text':'I inspected the SQL query plan.'}})['saved'])
                journey.client.set_auth_token(journey.tokens[1])
                other=journey.rpc('interview_create',{'application_id':journey.application,'client_id':'foreign'},True)
                self.assertIn('error',other)
                self.assertIn('error',journey.rpc('transcription_get',{'id':recording['id']},True))
                journey.client.set_auth_token(journey.tokens[0])
                saved=journey.rpc('interview_answer',args)
                self.assertEqual(saved['data']['turns'][0]['original'],'I inspected the SQL query plan.')
                self.assertEqual(saved['data']['turns'][0]['answer'],ANSWER1)
                journey.work()
                current=journey.get()
                journey.rpc('interview_correct',{'id':current['id'],'revision':current['revision'],'index':0,'answer':'I inspected the plan, but did not measure speed.'})
                journey.client.reload();journey.client.set_auth_token(journey.tokens[0])
                saved=journey.get()['data']['turns'][0]
                self.assertEqual(saved['recording_id'],recording['id'])
                self.assertEqual(saved['original'],'I inspected the SQL query plan.')
                self.assertEqual(saved['answer'],'I inspected the plan, but did not measure speed.')
            finally:journey.close()

    def test_correction_removes_unanswered_followup_and_preserves_answered_history(self):
        with tempfile.TemporaryDirectory() as directory,fixture_model() as (url,_):
            journey=Journey(directory,url)
            try:
                journey.answer(ANSWER1);journey.work();current=journey.get()
                current=journey.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'followup'})
                self.assertEqual(current['data']['questions'][1]['kind'],'followup')
                current=journey.rpc('interview_correct',{'id':current['id'],'revision':current['revision'],'index':0,'answer':ANSWER1+' I did not measure speed.'})
                self.assertEqual(current['data']['questions'][1]['kind'],'experience')
                self.assertFalse(current['data']['analysis'])
                journey.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'analyze'});journey.work()
                current=journey.get();journey.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'followup'})
                journey.answer(ANSWER2);journey.work();current=journey.get()
                answered=current['data']['questions'][1]
                current=journey.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'followup'})
                current=journey.rpc('interview_correct',{'id':current['id'],'revision':current['revision'],'index':0,'answer':ANSWER1})
                self.assertEqual(current['data']['questions'][1],answered)
                self.assertEqual(current['data']['turns'][1]['question'],answered)
                self.assertTrue(all(q['kind']!='followup' for q in current['data']['questions'][2:]))
            finally:journey.close()

if __name__=='__main__':unittest.main(verbosity=2)
