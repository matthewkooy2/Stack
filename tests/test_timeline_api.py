"""Timeline analysis persists in shared listings; preferences/results remain per user."""
import unittest,uuid
from test_catalog_api import worker
from test_api import account,rpc,request
from discovery.normalize import normalize,digest

class TimelineAPI(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  _,_,cls.a=account();_,_,cls.b=account();cls.label='TimelineTest'+uuid.uuid4().hex[:8]
  cls.url='https://example.com/'+cls.label;cls.source='career:'+digest(cls.url)
  rpc(cls.a,'import_job_url',url=cls.url);work=worker('discovery_claim',preferred_id=cls.source)
  descriptions=['Must be graduating between December 2026 and June 2027.','Graduating in 2026.','Bachelor degree required.','Graduating in 2027. Start date: January 2027.']
  cls.jobs=[normalize({'title':cls.label+' '+str(i),'company':'Timeline Test','url':cls.url+'/'+str(i),'country':'US','description':d},work['config']) for i,d in enumerate(descriptions)]
  worker('discovery_complete',id=cls.source,lease=work['lease'],result={'jobs':cls.jobs,'complete':True})
 @classmethod
 def tearDownClass(cls):worker('discovery_manage',id=cls.source,action='purge')
 def test_analysis_and_two_account_isolation(self):
  r=rpc(self.a,'save_timeline',graduation_month='2027-05',available_from='2027-06')
  self.assertEqual(r['profile']['graduation_month'],'2027-05')
  self.assertEqual(rpc(self.b,'bootstrap')['profile']['graduation_month'],'')
  jobs=rpc(self.a,'search_jobs',query=self.label)['jobs']
  self.assertEqual({j['timeline']['status'] for j in jobs},{'match','unclear'});self.assertEqual(len(jobs),2)
  confirmed=rpc(self.a,'search_jobs',query=self.label,filters={'timeline':'confirmed'})['jobs']
  self.assertEqual(len(confirmed),1);self.assertEqual(rpc(self.a,'get_job',id=confirmed[0]['id'])['timeline']['evidence'][0]['quote'],self.jobs[0]['description'])
  self.assertEqual(len(rpc(self.b,'search_jobs',query=self.label)['jobs']),4)
  self.assertEqual(len(rpc(self.a,'search_jobs',query=self.label,filters={'timeline':'all'})['jobs']),4)
  self.assertEqual(rpc(self.a,'get_job',id=self.jobs[1]['id'])['timeline']['status'],'incompatible')
  self.assertEqual(rpc(self.b,'get_job',id=self.jobs[1]['id'])['timeline']['status'],'unset')
  rpc(self.a,'swipe',job_id=self.jobs[0]['id'],action='apply')
  self.assertEqual(rpc(self.a,'bootstrap')['applications'][0]['job']['timeline']['status'],'match')
  rpc(self.a,'save_timeline',graduation_month='2026-05')
  self.assertEqual(rpc(self.a,'get_job',id=self.jobs[1]['id'])['timeline']['status'],'match')
  self.assertIn('error',rpc(self.a,'save_timeline',graduation_month='May 2027'))
  self.assertEqual(rpc(self.a,'bootstrap')['profile']['graduation_month'],'2026-05')
  status,_=request('/function/save_timeline',{'graduation_month':'2027-05'})
  self.assertIn(status,(401,403))
  _,r=request('/function/discovery_analyze',{'token':'wrong'})
  self.assertIn('error',r['data']['result'])

if __name__=='__main__':unittest.main()
