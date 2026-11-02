"""Four-step coaching through real owner-scoped endpoints; no live data or service."""
import copy
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ['JAC_DB_SCRATCH']='1'
from jaclang.testing.testing import JacTestClient
from agents import provider

class SimpleCoaching(unittest.TestCase):
    def test_visible_snapshot_pair_failures_and_account_isolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg=Path(tmp)/'model.json'
            cfg.write_text(json.dumps({'provider':'lmstudio','model':'synthetic-qwen','local_model_url':'http://127.0.0.1:1234'}))
            with patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(cfg),'JAC_DB_URL':'','STACK_REQUIRE_INVITE':'0'}):
                client=JacTestClient.from_file(str(Path('tests/simple_coaching_api.jac').resolve()),base_path=tmp+'/db')
                def rpc(name,args=None,fail=False):
                    response=client.post('/function/'+name,json=args or {})
                    self.assertTrue(response.ok,response.text)
                    value=response.data['result']
                    if not fail:self.assertNotIn('error',value,value)
                    return value
                try:
                    a=client.register_user('coach-owner','Synthetic-password-123').data['token']
                    session=rpc('prep_create',{'problem_id':'project'})
                    original=copy.deepcopy(session['data'])
                    newer=rpc('prep_save',{'id':session['id'],'revision':session['revision'],'data':{**original,'answer':'A remote saved draft'}})
                    answer='  My exact edited answer.\nI built the dashboard.  '
                    visible={**original,'answer':answer}
                    feedback={'text':'Specific coaching for the dashboard.','summary':'Specific coaching for the dashboard.'}
                    with patch.object(provider,'generate',return_value={'artifact':feedback}) as model:
                        result=rpc('prep_coach',{'id':session['id'],'data':visible})
                        self.assertEqual(model.call_args.args[0],'coach')
                        self.assertEqual(model.call_args.args[1]['session'],{'answer':answer})
                        self.assertEqual(result['data']['answer'],answer)
                        self.assertEqual(rpc('prep_get',{'id':session['id']})['data']['answer'],'A remote saved draft')
                    # Yet another edit after inference must not discard the result or be overwritten.
                    latest=rpc('prep_save',{'id':session['id'],'revision':newer['revision'],'data':{**newer['data'],'answer':'Even newer remote edit'}})
                    packet={'key':'snapshot-1','data':result['data'],'revision':result['revision'],'feedback':feedback}
                    saved=rpc('prep_save_coaching',{'id':session['id'],'submission':packet})
                    self.assertEqual(saved['data']['answer'],'Even newer remote edit')
                    self.assertEqual(saved['feedback'][-1]['answer'],answer)
                    self.assertEqual(saved['feedback'][-1]['session']['answer'],answer)
                    self.assertEqual(saved['feedback'][-1]['data'],feedback)
                    self.assertEqual(rpc('prep_save_coaching',{'id':session['id'],'submission':packet})['feedback'],saved['feedback'])
                    # Normal session saves still enforce revision checks.
                    self.assertIn('error',rpc('prep_save',{'id':session['id'],'revision':0,'data':visible},True))
                    # Failed inference does not write a draft, a run, or a partial answer/feedback pair.
                    with patch.object(provider,'generate',side_effect=ValueError('Synthetic inference unavailable')):
                        self.assertIn('error',rpc('prep_coach',{'id':session['id'],'data':visible},True))
                    self.assertEqual(rpc('prep_get',{'id':session['id']}),saved)
                    # Save with no concurrent edit applies this answer and its pair in one commit.
                    with patch.object(provider,'generate',return_value={'artifact':feedback}):
                        result=rpc('prep_coach',{'id':session['id'],'data':visible})
                    packet={**packet,'key':'snapshot-2','revision':result['revision']}
                    stored=rpc('prep_save_coaching',{'id':session['id'],'submission':packet})
                    self.assertEqual(stored['data']['answer'],answer)
                    self.assertEqual(stored['feedback'][-1]['revision'],stored['revision'])
                    with patch.object(provider,'generate') as model:
                        self.assertIn('error',rpc('prep_coach',{'id':session['id'],'data':{**visible,'answer':'x'*30001}},True));model.assert_not_called()
                    b=client.register_user('coach-other','Synthetic-password-456').data['token']
                    for endpoint,args in [('prep_get',{'id':session['id']}),('prep_coach',{'id':session['id'],'data':visible}),('prep_save_coaching',{'id':session['id'],'submission':packet})]:
                        with patch.object(provider,'generate') as model:
                            self.assertIn('error',rpc(endpoint,args,True));model.assert_not_called()
                    client.clear_auth()
                    response=client.post('/function/prep_coach',json={'id':session['id'],'data':visible})
                    self.assertFalse(response.ok)
                    client.set_auth_token(a)
                    self.assertEqual(rpc('prep_get',{'id':session['id']})['feedback'],stored['feedback'])
                finally:client.close()

if __name__=='__main__':unittest.main(verbosity=2)
