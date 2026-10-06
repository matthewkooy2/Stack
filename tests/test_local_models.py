"""Real local HTTP transports and worker/account integration; synthetic fixtures only."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import copy
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from agents import contracts, provider, worker
if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Local model verification requires the embedded disposable database; unset JAC_DB_URL first.')
os.environ['JAC_DB_SCRATCH'] = '1'

from jaclang.testing.testing import JacTestClient

FIT = {'summary':'Confirmed project experience.', 'strengths':['Built a tracker'],
       'gaps':[], 'unknowns':[], 'evidence':[{'source':'fact:resume.project',
       'quote':'Built a tracker', 'claim':'Has project experience'}]}
CONTEXT = {'facts':[{'key':'resume.project', 'value':'Built a tracker', 'verified':True}]}
ANSWER = ('In a class project, our team was missing deadlines. I made a task list, '
          'asked each teammate to own one task, and scheduled a short weekly check-in. '
          'We delivered the project on time. Next time I would agree on responsibilities at kickoff.')
COACH = {'summary':'The answer explains ownership and a concrete result.',
         'rubric':[{'criterion':'Ownership', 'score':3, 'feedback':'Clarify your personal contribution.'}],
         'next_exercises':['Practice explaining a tradeoff.'],
         'followup_questions':['What did you change?', 'What would you do earlier?'],
         'evidence':[{'source':'answer', 'quote':'I made a task list', 'claim':'Took initiative'}]}

def envelope(name, artifact=FIT):
    msg={'role':'assistant', 'content':json.dumps(artifact)}
    if name=='ollama': return {'model':'qwen-test', 'done':True, 'done_reason':'stop', 'message':msg}
    return {'model':'qwen-test', 'id':'local-test', 'choices':[{'finish_reason':'stop', 'message':msg}]}

@contextmanager
def service(name, artifact=FIT, raw=None, status=200, content_type='application/json', drip=False, declared_extra=0, slow_headers=False):
    requests=[]
    body=raw if raw is not None else json.dumps(envelope(name, artifact)).encode()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_POST(self):
            requests.append((self.path, json.loads(self.rfile.read(int(self.headers['Content-Length']))), dict(self.headers)))
            if slow_headers:
                try:
                    self.wfile.write(b'HTTP/1.1 200 OK\r\nX-Slow: ');self.wfile.flush()
                    for _ in range(130): self.wfile.write(b' ');self.wfile.flush();time.sleep(.05)
                except (BrokenPipeError,ConnectionResetError): pass
                return
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            if status==302: self.send_header('Location','http://127.0.0.1:9/secret')
            if not drip: self.send_header('Content-Length',str(len(body)+declared_extra))
            self.end_headers()
            try:
                if drip:
                    for _ in range(130): self.wfile.write(b' '); self.wfile.flush(); time.sleep(.05)
                else: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try: yield 'http://127.0.0.1:'+str(server.server_port),requests
    finally: server.shutdown();server.server_close();thread.join(2)

class LocalModels(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)/'provider.json'
        env=patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(self.path), 'STACK_LOCAL_MODEL_API_KEY':'',
            'OPENAI_API_KEY':'do-not-send', 'MODEL_API_KEY':'do-not-send', 'STACK_AGENT_WORKER_TOKEN':'local-worker-token'})
        env.start();self.addCleanup(env.stop)
    def configure(self,name,url='',**changes):
        self.path.write_text(json.dumps({'provider':name,'model':'qwen-test','local_model_url':url,**changes}))
        return contracts.config()
    def run_model(self,name,url,**kwargs):
        return provider.generate('fit',CONTEXT,self.configure(name,url),**kwargs)
    def test_local_configuration_requires_model_and_private_origin_but_no_money_or_owner(self):
        for name in ('ollama','lmstudio'):
            c=self.configure(name,local_cli_daily_limit=0)
            for account in ('alice','bob'): contracts.model_access(c,account)
            self.assertEqual(contracts.reserve_cents(CONTEXT),0)
            self.assertEqual(contracts.model_status('alice')['billing'],'local')
            self.assertEqual(contracts.model_status('alice')['daily_limit'],0)
            with self.assertRaises(ValueError): contracts.model_access({**c,'model':''},'alice')
            for url in ('https://example.com:443','http://169.254.169.254:80','http://0.0.0.0:1234',
                        'http://127.0.0.1:1234/v1','http://user:secret@127.0.0.1:1234','http://127.0.0.1:0',
                        'http://127.0.0.1:1234?key=x','http://127.0.0.1:1234#x'):
                with self.subTest(name=name,url=url),self.assertRaises(ValueError): contracts.model_access({**c,'local_model_url':url},'alice')
    def test_both_actual_http_transports_keep_schema_sources_logs_and_zero_spend(self):
        for name in ('ollama','lmstudio'):
            with self.subTest(name=name),service(name) as (url,requests),patch.object(provider,'http') as paid:
                attempts=[];events=[]
                result=self.run_model(name,url,record=attempts.append,observe=lambda e,d:events.append((e,d)))
                self.assertEqual(result['artifact'],FIT);self.assertEqual(result['cost_cents'],0)
                self.assertEqual(attempts[-1]['status'],'accepted')
                self.assertEqual(json.loads(attempts[-1]['raw_response']),envelope(name))
                self.assertIn(('model_validation',True),[(e,d.get('valid')) for e,d in events])
                path,payload,headers=requests[0];self.assertNotIn('Authorization',headers)
                self.assertEqual(payload['model'],'qwen-test');self.assertFalse(payload['stream'])
                self.assertEqual(payload['messages'][0]['content'],provider.SYSTEM)
                if name=='ollama':
                    self.assertEqual(path,'/api/chat');self.assertEqual(payload['format'],provider.SCHEMAS['fit'])
                    self.assertEqual(payload['options']['num_ctx'],8192);self.assertEqual(payload['options']['num_predict'],3000)
                    self.assertFalse(payload['think'])
                else:
                    self.assertEqual(path,'/v1/chat/completions');self.assertEqual(payload['response_format']['json_schema']['schema'],provider.SCHEMAS['fit'])
                    self.assertEqual(payload['max_tokens'],3000)
                paid.assert_not_called()
    def test_dedicated_local_token_does_not_forward_paid_provider_credentials_or_proxy(self):
        with service('lmstudio') as (url,requests),patch.dict(os.environ,{'STACK_LOCAL_MODEL_API_KEY':'synthetic-local', 'HTTP_PROXY':'http://127.0.0.1:9', 'http_proxy':'http://127.0.0.1:9','NO_PROXY':'','no_proxy':''}):
            self.run_model('lmstudio',url)
            self.assertEqual(requests[0][2]['Authorization'],'Bearer synthetic-local')
    def test_rejects_bad_output_after_recording_without_api_fallback(self):
        bad=copy.deepcopy(FIT);bad['evidence'][0]['quote']='Invented work'
        for name in ('ollama','lmstudio'):
            partial=envelope(name)
            if name=='ollama': partial['done_reason']='length'
            else: partial['choices'][0]['finish_reason']='length'
            extra={**FIT,'unexpected':True}
            cases=[b'{bad',b'[]',json.dumps(partial).encode(),json.dumps(envelope(name,bad)).encode(),
                   json.dumps(envelope(name,extra)).encode(),json.dumps(envelope(name,{'summary':'Missing fields'})).encode(),
                   b'{"model":"one","model":"two"}',b'\xff',json.dumps({'error':'unavailable model'}).encode()]
            for raw in cases:
                with self.subTest(name=name,raw=raw[:40]),service(name,raw=raw) as (url,_),patch.object(provider,'http') as paid:
                    attempts=[]
                    with self.assertRaises(ValueError): self.run_model(name,url,record=attempts.append)
                    self.assertEqual(attempts[-1]['status'],'rejected');self.assertIn('raw_response',attempts[-1]);paid.assert_not_called()
    def test_bounds_transport_handles_truncation_redirect_and_service_failures(self):
        for opts in ({'raw':b'x'*262145},{'raw':json.dumps(envelope('lmstudio',{**FIT,'summary':'x'*65536})).encode()},
                     {'declared_extra':5},{'status':302},{'status':404},{'content_type':'text/html'}):
            with self.subTest(opts=list(opts)),service('lmstudio',**opts) as (url,_):
                with self.assertRaises(ValueError): self.run_model('lmstudio',url)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
        with self.assertRaisesRegex(ValueError,'unavailable'): self.run_model('lmstudio','http://127.0.0.1:'+str(port))
    def test_deadline_applies_to_dripping_response_and_context_does_not_truncate(self):
        with service('lmstudio',drip=True) as (url,requests):
            c=self.configure('lmstudio',url,local_model_timeout=5)
            start=time.monotonic()
            with self.assertRaisesRegex(ValueError,'timed out'): provider.generate('fit',CONTEXT,c)
            self.assertLess(time.monotonic()-start,6.5)
        with service('lmstudio',slow_headers=True) as (url,requests):
            c=self.configure('lmstudio',url,local_model_timeout=5);start=time.monotonic()
            with self.assertRaisesRegex(ValueError,'timed out'): provider.generate('fit',CONTEXT,c)
            self.assertLess(time.monotonic()-start,6.5)
        with service('lmstudio') as (url,requests):
            with self.assertRaisesRegex(ValueError,'context limit'):
                provider.generate('fit',{'session':{'answer':'x'*20000}},self.configure('lmstudio',url))
            self.assertEqual(requests,[])
    def test_scores_boolean_values_and_nonfinite_fail_strict_schema(self):
        for score in (-1,5,True,2.5,float('nan'),float('inf')):
            artifact=copy.deepcopy(COACH);artifact['rubric'][0]['score']=score
            with self.subTest(score=score),service('lmstudio',artifact) as (url,_):
                with self.assertRaises(ValueError): provider.generate('coach',{'session':{'answer':ANSWER}},self.configure('lmstudio',url))
    def test_worker_pauses_local_errors_and_configuration_changes(self):
        for name in ('ollama','lmstudio'):
            with service(name,raw=b'{invalid') as (url,_):
                c=self.configure(name,url)
                work={'id':'run','owner':'alice','lease':'lease','step':'fit','context':CONTEXT,'artifacts':{},'provider_config_hash':contracts.digest(c)}
                with patch.object(worker,'call',return_value={'saved':True}),patch.object(provider,'http') as paid:
                    self.assertTrue(worker.dispatch(work,'worker-token')['needs_input']);paid.assert_not_called()
                self.configure(name,url,model='different')
                with patch.object(provider,'generate') as gen:
                    self.assertTrue(worker.dispatch(work,'worker-token')['needs_input']);gen.assert_not_called()

    def test_worker_account_workflow_persists_without_subscription_cap_or_api_money(self):
        for name in ('ollama','lmstudio'):
            with self.subTest(name=name),service(name,COACH) as (url,requests):
                self.configure(name,url,local_cli_daily_limit=1,monthly_cents=0,user_monthly_cents=0,capture_agent_content=True)
                client=JacTestClient.from_file(str(Path('main.jac').resolve()),base_path=self.tmp.name+'/'+name)
                def rpc(endpoint,args=None,allow_error=False):
                    response=client.post('/function/'+endpoint,json=args or {});self.assertTrue(response.ok,response.text)
                    result=response.data['result']
                    if not allow_error: self.assertNotIn('error',result,result)
                    return result
                try:
                    accounts=[]
                    for username in ('local-owner','local-other'):
                        registered=client.register_user(username+'-'+name,'Synthetic-local-password-123');self.assertTrue(registered.ok,registered.text)
                        accounts.append((registered.data['token'],rpc('agent_settings')['account_id']))
                    token,owner=accounts[0];other_token,other_owner=accounts[1]
                    client.set_auth_token(token)
                    self.assertTrue(rpc('agent_settings')['activity']['model_provider']['configured'])
                    # Lack of Model permission blocks even free local inference.
                    session=rpc('prep_create',{'problem_id':'project'})
                    data=session['data'];data['answer']=ANSWER
                    session=rpc('prep_save',{'id':session['id'],'revision':session['revision'],'data':data})
                    denied=rpc('agent_start',{'kind':'prep','target_id':session['id']})
                    client.clear_auth();self.assertTrue(rpc('agent_claim',{'token':'local-worker-token'}).get('idle'))
                    client.set_auth_token(token);self.assertEqual(rpc('agent_run',{'id':denied['id']})['status'],'blocked')
                    rpc('agent_save_policy',{'policy':{'enabled':True,'expires_at':time.time()+3600,'actions':['model']}})
                    rpc('agent_retry',{'id':denied['id']})
                    runs=[]
                    # Two real requests for the same account exceed the CLI cap of 1;
                    # a second account can also use local inference with its own permission.
                    for index,(auth,account) in enumerate((accounts[0],accounts[0],accounts[1])):
                        client.set_auth_token(auth)
                        if index==0: current=session;run=denied
                        else:
                            rpc('agent_save_policy',{'policy':{'enabled':True,'expires_at':time.time()+3600,'actions':['model']}})
                            current=rpc('prep_create',{'problem_id':'project'})
                            data=current['data'];data['answer']=ANSWER
                            current=rpc('prep_save',{'id':current['id'],'revision':current['revision'],'data':data})
                            run=rpc('agent_start',{'kind':'prep','target_id':current['id']})
                        client.clear_auth();claim=rpc('agent_claim',{'token':'local-worker-token'})
                        self.assertEqual(claim['id'],run['id']);self.assertEqual(claim['owner'],account);self.assertEqual(claim['reservation_cents'],0)
                        def api(name,args): return rpc(name,args)
                        def observe(event,data): return rpc('agent_trace',{'token':'local-worker-token',**{k:claim[k] for k in ('id','owner','lease')},'event':event,'data':data})
                        with patch.object(worker,'call',side_effect=api),patch.object(provider,'http') as paid:
                            result=worker.dispatch(claim,'local-worker-token',observe=observe);paid.assert_not_called()
                        self.assertEqual(result['artifact'],COACH)
                        rpc('agent_finish',{'token':'local-worker-token',**{k:claim[k] for k in ('id','owner','lease')},'result':result})
                        client.set_auth_token(auth)
                        done=rpc('agent_run',{'id':run['id']});self.assertEqual(done['status'],'completed')
                        self.assertEqual(done['subscription_calls'],0);self.assertEqual(done['cost_cents'],0);self.assertEqual(done['provider'],name)
                        self.assertEqual(rpc('agent_model_logs',{'id':run['id']})['attempts'][0]['status'],'accepted')
                        runs.append((auth,current['id'],run['id']))
                    self.assertEqual(len(requests),3)
                    paused=[]
                    with service(name,raw=b'{invalid JSON') as (bad_url,_):
                        with socket.socket() as unused:
                            unused.bind(('127.0.0.1',0));missing_url='http://127.0.0.1:'+str(unused.getsockname()[1])
                        for failure in ('malformed','unavailable','config-change'):
                            self.configure(name,missing_url if failure=='unavailable' else bad_url)
                            client.set_auth_token(token)
                            current=rpc('prep_create',{'problem_id':'project'})
                            run=rpc('agent_start',{'kind':'prep','target_id':current['id']})
                            client.clear_auth();claim=rpc('agent_claim',{'token':'local-worker-token'})
                            self.assertEqual(claim['id'],run['id'])
                            if failure=='config-change': self.configure(name,bad_url,max_output_tokens=1536)
                            with patch.object(worker,'call',side_effect=lambda endpoint,args:rpc(endpoint,args)),patch.object(provider,'http') as paid:
                                result=worker.dispatch(claim,'local-worker-token');paid.assert_not_called()
                            self.assertTrue(result.get('needs_input'),result)
                            rpc('agent_finish',{'token':'local-worker-token',**{k:claim[k] for k in ('id','owner','lease')},'result':result})
                            client.set_auth_token(token)
                            view=rpc('agent_run',{'id':run['id']});self.assertEqual(view['status'],'needs_input')
                            self.assertEqual(view['cost_cents'],0);self.assertEqual(view['subscription_calls'],0)
                            self.assertEqual(rpc('prep_get',{'id':current['id']})['feedback'],[])
                            attempts=rpc('agent_model_logs',{'id':run['id']})['attempts']
                            if failure=='config-change': self.assertEqual(attempts,[])
                            else: self.assertEqual(attempts[0]['status'],'rejected' if failure=='malformed' else 'error')
                            paused.append(run['id'])
                    client.reload()
                    client.set_auth_token(token)
                    for rid in paused: self.assertEqual(rpc('agent_run',{'id':rid})['status'],'needs_input')
                    for auth,sid,rid in runs:
                        client.set_auth_token(auth)
                        saved=rpc('prep_get',{'id':sid});self.assertEqual(saved['feedback'][0]['data'],COACH)
                        self.assertIn('raw_response',rpc('agent_model_logs',{'id':rid})['attempts'][0])
                        self.assertTrue(rpc('agent_traces',{'id':rid})['events'])
                    client.set_auth_token(other_token)
                    for endpoint,args in [('prep_get',{'id':runs[0][1]}),('agent_run',{'id':runs[0][2]}),('agent_model_logs',{'id':runs[0][2]}),('agent_traces',{'id':runs[0][2]})]:
                        self.assertIn('error',rpc(endpoint,args,allow_error=True))
                finally: client.close()

if __name__=='__main__': unittest.main(verbosity=2)
