"""Durable workflow integration using controlled worker results, no external IO."""
import concurrent.futures
import os
from pathlib import Path
import time
import json
import unittest
from test_api import account, rpc, request


class AgentAPI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _,_,cls.a=account();_,_,cls.b=account()
        rpc(cls.a,'bootstrap');rpc(cls.b,'bootstrap')
        cls.worker=os.environ.get('STACK_AGENT_WORKER_TOKEN','') or Path('storage/agents/worker-token').read_text().strip()

    def worker_call(self,name,**args):
        status,result=request('/function/'+name,{'token':self.worker,**args})
        self.assertEqual(status,200,result)
        return result['data']['result']

    def test_01_memory_is_private_and_explicit(self):
        saved=rpc(self.a,'agent_save_facts',facts=[{'key':'name','value':'Agent Alice','verified':True}])
        self.assertEqual(saved['facts'][0]['value'],'Agent Alice')
        self.assertFalse(rpc(self.b,'agent_settings')['facts'])
        self.assertFalse(saved['policy']['enabled'])
        self.assertIn('error',rpc(self.a,'agent_save_policy',policy={'enabled':True}))

    def test_02_session_revision_and_isolation(self):
        session=rpc(self.a,'prep_create',problem_id='two-sum',language='python')
        self.assertIn('error',rpc(self.b,'prep_get',id=session['id']))
        data={**session['data'],'code':'def solve(nums,target): return []'}
        saved=rpc(self.a,'prep_save',id=session['id'],revision=0,data=data)
        self.assertEqual(saved['revision'],1)
        self.assertIn('error',rpc(self.a,'prep_save',id=session['id'],revision=0,data=data))

    def test_03_durable_code_run_and_duplicate_callbacks(self):
        session=rpc(self.a,'prep_create',problem_id='brackets',language='cpp')
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            runs=list(pool.map(lambda _:rpc(self.a,'agent_start',kind='code',target_id=session['id']),range(4)))
        self.assertEqual(len({r['id'] for r in runs}),1);run=runs[0]
        self.assertIn('error',rpc(self.b,'agent_run',id=run['id']))
        claim=self.worker_call('agent_claim')
        self.assertEqual(claim['id'],run['id'])
        self.assertTrue(self.worker_call('agent_claim').get('idle'))
        args={k:claim[k] for k in ('id','owner','lease')}
        done=self.worker_call('agent_finish',**args,result={'artifact':{'passed':5,'total':5}})
        self.assertEqual(done['status'],'completed')
        self.assertIn('error',self.worker_call('agent_finish',**args,result={'artifact':{'passed':0}}))
        self.assertEqual(len(rpc(self.a,'prep_get',id=session['id'])['results']),1)

    def test_04_unset_budget_blocks_paid_run(self):
        policy={'enabled':True,'expires_at':time.time()+3600,'actions':['model'],'domains':[],'daily_limits':{}}
        rpc(self.a,'agent_save_policy',policy=policy)
        session=rpc(self.a,'prep_create',problem_id='project',language='')
        run=rpc(self.a,'agent_start',kind='prep',target_id=session['id'])
        self.worker_call('agent_claim')
        result=rpc(self.a,'agent_run',id=run['id'])
        self.assertEqual(result['status'],'blocked');self.assertEqual(result['cost_cents'],0)

    def test_05_cancel_prevents_claim(self):
        session=rpc(self.b,'prep_create',problem_id='two-sum',language='cpp')
        run=rpc(self.b,'agent_start',kind='code',target_id=session['id'])
        rpc(self.b,'agent_cancel',id=run['id'])
        self.assertTrue(self.worker_call('agent_claim').get('idle'))

    def test_06_contacts_and_worker_authority(self):
        c=rpc(self.a,'agent_save_contact',data={'name':'Test','email':'known@example.com','selected':True})['contacts'][0]
        self.assertIn('error',rpc(self.b,'agent_stop_contact',id=c['id']))
        stopped=rpc(self.a,'agent_stop_contact',id=c['id'])['contacts'][0]
        self.assertTrue(stopped['stopped'])
        self.assertIn('error',rpc(self.a,'agent_start',kind='network',target_id=c['id']))
        self.assertIn('error',request('/function/agent_claim',{'token':'wrong'})[1]['data']['result'])
        self.assertIn('error',request('/function/agent_claim',{'token':self.worker},self.a)[1]['data']['result'])

    def test_07_parallel_memory_initialization(self):
        _,_,user=account()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            values=list(pool.map(lambda _:rpc(user,'agent_settings'),range(4)))
        self.assertTrue(all(v['revision']==0 for v in values))

    def test_08_import_is_unselected_and_deduplicated(self):
        csv='name,email,relationship\nAda,ada@example.com,Former teammate\n'
        a=rpc(self.b,'agent_import_contacts',content=csv)['contacts']
        b=rpc(self.b,'agent_import_contacts',content=csv)['contacts']
        self.assertEqual(len(a),len(b));self.assertFalse(a[0]['selected'])
        self.assertIn('error',rpc(self.b,'agent_start',kind='network',target_id=a[0]['id']))

    def test_09_account_delete_is_owned_and_cancels_work(self):
        user,password,token=account();rpc(token,'bootstrap')
        s=rpc(token,'prep_create',problem_id='brackets',language='python')
        run=rpc(token,'agent_start',kind='code',target_id=s['id'])
        claim=self.worker_call('agent_claim');self.assertEqual(claim['id'],run['id'])
        self.assertIn('error',rpc(self.b,'account_delete',username=user,password=password))
        exported=rpc(token,'account_export');self.assertEqual(len(exported['agents']['sessions']),1)
        deleted=rpc(token,'account_delete',username=user,password=password);self.assertTrue(deleted['deleted'])
        self.assertIn('error',self.worker_call('agent_finish',**{k:claim[k] for k in ('id','owner','lease')},result={'artifact':{}}))
        status,result=request('/function/agent_admission',{},token)
        self.assertTrue(status!=200 or not result.get('data',{}).get('result',{}).get('admitted'))

    @unittest.skipUnless(os.environ.get('STACK_TEST_AGENT_CONFIG'), 'Requires a dedicated test API config, never production config')
    def test_10_global_budget_is_atomic_across_accounts(self):
        path=Path(os.environ['STACK_TEST_AGENT_CONFIG']);before=path.read_text()
        try:
            baseline=sum(u['cents'] for u in self.worker_call('agent_report')['usage'] if u['key']=='cost:'+time.strftime('%Y-%m',time.gmtime()))
            path.write_text(json.dumps({'invite_only':False,'monthly_cents':baseline+1,'user_monthly_cents':1,'model':'test-only', 'input_cents_per_million':1,'output_cents_per_million':1,'max_output_tokens':256}))
            runs=[]
            for token in (self.a,self.b):
                rpc(token,'agent_save_policy',policy={'enabled':True,'expires_at':time.time()+3600,'actions':['model']})
                session=rpc(token,'prep_create',problem_id='project')
                runs.append((token,rpc(token,'agent_start',kind='prep',target_id=session['id'])))
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                claims=list(pool.map(lambda _:self.worker_call('agent_claim'),range(2)))
            active=[c for c in claims if not c.get('idle')]
            self.assertEqual(len(active),1)
            states=[rpc(token,'agent_run',id=run['id']) for token,run in runs]
            self.assertEqual(sum(s['cost_cents'] for s in states),1)
            self.assertEqual(sorted(s['status'] for s in states),['blocked','running'])
            self.worker_call('agent_finish',**{k:active[0][k] for k in ('id','owner','lease')},result={'artifact':{'summary':'Controlled test'}})
        finally:path.write_text(before)


if __name__=='__main__':unittest.main(verbosity=2)
