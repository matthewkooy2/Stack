"""Opt-in real local-model coaching smoke; synthetic data and disposable accounts."""
import argparse
import json
import os
from pathlib import Path
import tempfile
import time
from unittest.mock import patch

if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Local model verification requires the embedded disposable database; unset JAC_DB_URL first.')
os.environ['JAC_DB_SCRATCH'] = '1'

from jaclang.testing.testing import JacTestClient
from agents.worker import dispatch

ANSWER = ('In a class project, our team was missing deadlines. I made a task list, '
          'asked each teammate to own one task, and scheduled a short weekly check-in. '
          'We delivered the project on time. Next time I would agree on responsibilities at kickoff.')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('provider',choices=['ollama','lmstudio'])
    parser.add_argument('--model',required=True)
    parser.add_argument('--url',default='')
    parser.add_argument('--context-tokens',type=int,default=8192)
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='stack-local-smoke-') as directory:
        path=Path(directory)/'config.json'
        path.write_text(json.dumps({'provider':args.provider,'model':args.model,'local_model_url':args.url,
            'local_model_context_tokens':args.context_tokens,'max_output_tokens':1536,'local_cli_daily_limit':1,
            'capture_agent_content':True}))
        with patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(path),'STACK_AGENT_WORKER_TOKEN':'isolated-local-smoke','STACK_LOCAL_MODEL_API_KEY':''}):
            client=JacTestClient.from_file(str(Path('main.jac').resolve()),base_path=directory)
            def rpc(name,values=None):
                response=client.post('/function/'+name,json=values or {})
                assert response.ok,response.text
                data=response.data['result'];assert 'error' not in data,data;return data
            try:
                created=client.register_user('local-smoke-owner','Synthetic-local-smoke-password-123');assert created.ok,created.text
                token=created.data['token'];owner=rpc('agent_settings')['account_id']
                rpc('agent_save_policy',{'policy':{'enabled':True,'expires_at':time.time()+3600,'actions':['model']}})
                results=[]
                for index in range(2):
                    session=rpc('prep_create',{'problem_id':'project'});data=session['data'];data['answer']=ANSWER
                    session=rpc('prep_save',{'id':session['id'],'revision':session['revision'],'data':data})
                    run=rpc('agent_start',{'kind':'prep','target_id':session['id']})
                    client.clear_auth();work=rpc('agent_claim',{'token':'isolated-local-smoke'})
                    assert work['id']==run['id'] and work['owner']==owner and work['reservation_cents']==0,work
                    def observe(event,data): rpc('agent_trace',{'token':'isolated-local-smoke',**{k:work[k] for k in ('id','owner','lease')},'event':event,'data':data})
                    start=time.monotonic()
                    with patch('agents.worker.call',side_effect=rpc): result=dispatch(work,'isolated-local-smoke',observe=observe)
                    elapsed=time.monotonic()-start
                    assert result.get('artifact',{}).get('text'),result
                    rpc('agent_finish',{'token':'isolated-local-smoke',**{k:work[k] for k in ('id','owner','lease')},'result':result})
                    client.set_auth_token(token);done=rpc('agent_run',{'id':run['id']})
                    assert done['status']=='completed' and done['cost_cents']==0 and done['subscription_calls']==0,done
                    logs=rpc('agent_model_logs',{'id':run['id']})['attempts'];assert logs[-1]['status']=='accepted',logs
                    response=json.loads(logs[-1]['raw_response'])
                    results.append({'session_id':session['id'],'run_id':run['id'],'artifact':result['artifact'],
                        'seconds':round(elapsed,2),'reported_model':response['model']})
                    print(json.dumps({'attempt':index+1,'provider':args.provider,'model':response['model'],'status':done['status'],'api_cost_cents':0,'subscription_calls':0,'seconds':round(elapsed,2)}),flush=True)
                client.reload();client.set_auth_token(token)
                for result in results:
                    assert rpc('prep_get',{'id':result['session_id']})['feedback'][0]['data']==result['artifact']
                    assert rpc('agent_model_logs',{'id':result['run_id']})['attempts'][-1]['status']=='accepted'
                print(json.dumps({'provider':args.provider,'requested_model':args.model,'persisted_after_reload':True,'requests':len(results),'results':results},indent=2))
            finally: client.close()

if __name__=='__main__': main()
