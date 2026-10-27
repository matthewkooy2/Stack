"""Black-box catalog/account tests. Fixtures are removed from the live catalog."""
import sys,json,time,uuid,unittest,concurrent.futures
from pathlib import Path
from urllib.request import Request,urlopen
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from discovery.normalize import normalize
from test_api import account,rpc,request,BASE
from catalog_fixture import career
TOKEN=Path('storage/discovery/worker-token').read_text().strip()
def worker(name,**args):
    _,result=request('/function/'+name,{'token':TOKEN,**args})
    if not result.get('ok'):raise RuntimeError(result)
    data=result['data']['result']
    if data.get('error'):raise RuntimeError(data['error'])
    return data

def sweep(source,pages):
    """One run over `source`: a list of pages of listings, or an error string."""
    run=worker('jobs_sweep_begin',only=[source])['run']
    if isinstance(pages,str):worker('jobs_sweep_source',run=run,id=source['id'],error=pages)
    for i,page in enumerate([] if isinstance(pages,str) else pages):
        worker('jobs_sweep_source',run=run,id=source['id'],complete=i==len(pages)-1,**page)
    while not worker('jobs_sweep_finish',run=run)['done']:pass
    return run

class CatalogAPI(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
    _,_,cls.a=account();_,_,cls.b=account();cls.label='CatalogTest'+uuid.uuid4().hex[:8]
    cls.url='https://example.com/stack-tests/'+cls.label;cls.source=career(cls.url);cls.source_id=cls.source['id']
    cls.jobs=[normalize({'title':cls.label+' Nurse '+str(i),'company':'Temporary API test','url':cls.url+'/'+str(i),'country':'US','location':'Detroit, MI','description':'Test fixture, removed at end.','posted_at':(time.time()-i*86400 if i<27 else 0),'compensation':{'min':30,'max':45,'unit':'hour','currency':'USD'}},cls.source) for i in range(30)]
    cls.expired=normalize({'title':cls.label+' Expired','company':'Temporary API test','url':cls.url+'/expired','country':'US','expires_at':time.time()-100},cls.source)
    cls.run=sweep(cls.source,[{'jobs':cls.jobs+[cls.expired]}])
 @classmethod
 def tearDownClass(cls):worker('discovery_manage',id=cls.source_id,action='purge')
 def test_01_auth_service_boundary(self):
    status,_=request('/function/search_jobs',{})
    self.assertIn(status,(401,403))
    _,r=request('/function/jobs_sweep_begin',{'token':'wrong'})
    self.assertIn('error',r['data']['result'])
    _,r=request('/function/jobs_sweep_begin',{'token':TOKEN},token=self.a)
    self.assertIn('error',r['data']['result'])
 def test_02_shared_search_and_keyset_pagination(self):
    first=rpc(self.a,'search_jobs',query=self.label,filters={})
    self.assertEqual(len(first['jobs']),25);self.assertTrue(first['next_cursor'])
    second=rpc(self.a,'search_jobs',query=self.label,filters={},cursor=first['next_cursor'])
    self.assertEqual(len(second['jobs']),5);self.assertFalse(second['next_cursor'])
    self.assertEqual(len({j['id'] for j in first['jobs']+second['jobs']}),30)
    self.assertEqual([j['id'] for j in first['jobs']],[j['id'] for j in rpc(self.b,'search_jobs',query=self.label,filters={})['jobs']])
    self.assertIn('error',rpc(self.a,'search_jobs',query='changed',filters={},cursor=first['next_cursor']))
 def test_02b_newest_date_filter_and_sort_persistence(self):
    first=rpc(self.a,'search_jobs',query=self.label,filters={'has_posting_date':True,'sort':'newest'})
    second=rpc(self.a,'search_jobs',query=self.label,filters={'has_posting_date':True,'sort':'newest'},cursor=first['next_cursor'])
    jobs=first['jobs']+second['jobs']
    self.assertEqual(len(jobs),27)
    self.assertTrue(all(j['posted_at'] for j in jobs))
    self.assertEqual([j['posted_at'] for j in jobs],sorted([j['posted_at'] for j in jobs],reverse=True))
    self.assertIn('error',rpc(self.a,'search_jobs',query=self.label,filters={'has_posting_date':True,'sort':'relevance'},cursor=first['next_cursor']))
    relevant=rpc(self.a,'search_jobs',query=self.label+' Nurse 2',filters={'sort':'relevance'})
    self.assertEqual(relevant['jobs'][0]['title'],self.label+' Nurse 2')
    rpc(self.a,'save_search',query=self.label,filters={'has_posting_date':True,'sort':'relevance'})
    saved=rpc(self.a,'bootstrap')['saved_search']['filters']
    self.assertTrue(saved['has_posting_date']);self.assertEqual(saved['sort'],'relevance')
 def test_03_filters_expiry_and_real_apply(self):
    # Fixtures do not state a work arrangement: shown as unconfirmed, hidden when only confirmed matches are wanted.
    remote=rpc(self.a,'search_jobs',query=self.label,filters={'mode':'Remote'})['jobs']
    self.assertTrue(remote);self.assertTrue(all(j['match']['verdict']=='uncertain' for j in remote))
    self.assertIn('Work arrangement: Work arrangement not stated',remote[0]['match']['uncertain'])
    self.assertEqual(rpc(self.a,'search_jobs',query=self.label,filters={'mode':'Remote','confirmed_only':True})['jobs'],[])
    self.assertTrue(rpc(self.a,'search_jobs',query=self.label,filters={'salary_min':40,'salary_period':'hour'})['jobs'])
    # $30-45/hour is at most $93,600/year at 2,080 hours.
    self.assertTrue(rpc(self.a,'search_jobs',query=self.label,filters={'salary_min':90000,'salary_period':'year'})['jobs'])
    self.assertFalse(rpc(self.a,'search_jobs',query=self.label,filters={'salary_min':100000,'salary_period':'year'})['jobs'])
    self.assertIn('error',rpc(self.a,'swipe',job_id=self.expired['id'],action='apply'))
    job_id=self.jobs[0]['id']
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda _:rpc(self.a,'swipe',job_id=job_id,action='apply'),range(4)))
    apps=[a for a in rpc(self.a,'bootstrap')['applications'] if a['job_id']==job_id]
    self.assertEqual(len(apps),1);self.assertFalse(apps[0]['demo']);self.assertEqual(apps[0]['status'],'Ready to apply')
    self.assertEqual(apps[0]['job']['title'],self.jobs[0]['title'])
    self.assertFalse([a for a in rpc(self.b,'bootstrap')['applications'] if a['job_id']==job_id])
    self.assertIn('error',rpc(self.b,'mark_application_submitted',id=apps[0]['id']))
    updated=rpc(self.a,'mark_application_submitted',id=apps[0]['id'])
    self.assertEqual(next(a for a in updated['applications'] if a['id']==apps[0]['id'])['status'],'Submitted')
 def test_04_import_deferred_and_saved_search(self):
    self.assertIn('error',rpc(self.a,'import_job_url',url=self.url))
    saved=rpc(self.a,'save_search',query='Registered Nurse',filters={'mode':'Remote'})
    self.assertIn('jobs',saved['feed'])
    self.assertEqual(rpc(self.a,'bootstrap')['saved_search']['query'],'Registered Nurse')
    self.assertEqual(rpc(self.b,'bootstrap')['saved_search'],{})
 def test_05_finished_sweep_rejects_late_pages(self):
    with self.assertRaises(RuntimeError):worker('jobs_sweep_source',run=self.run,id=self.source_id,jobs=[],complete=True)
 def test_06_failed_or_partial_source_does_not_close_jobs(self):
    sweep(self.source,'Source returned HTTP 503.')
    self.assertTrue(rpc(self.a,'get_job',id=self.jobs[0]['id'])['active'])
    sweep(self.source,[{'jobs':[self.jobs[0]]},{'jobs':[],'invalid':1}])
    self.assertTrue(rpc(self.a,'get_job',id=self.jobs[-1]['id'])['active'])
 def test_07_sweep_updates_listings_and_closes_missing_ones(self):
    rpc(self.a,'search_jobs',query=self.label)  # Stored before the sweep.
    changed=dict(self.jobs[0],description='Build updated software for clinical teams.')
    expired=dict(self.jobs[-1],expires_at=time.time()-100)
    sweep(self.source,[{'jobs':[changed,expired]}])
    first=rpc(self.a,'search_jobs',query=self.label)
    jobs=first['jobs']+(rpc(self.a,'search_jobs',query=self.label,cursor=first['next_cursor'])['jobs'] if first['next_cursor'] else [])
    self.assertNotIn(expired['id'],[j['id'] for j in jobs])
    self.assertEqual([j['id'] for j in jobs],[changed['id']])
    self.assertEqual(jobs[0]['highlights']['responsibilities'],['Build updated software for clinical teams.'])
    self.assertFalse(rpc(self.a,'get_job',id=expired['id'])['active'])
    self.assertFalse(rpc(self.a,'get_job',id=self.jobs[1]['id'])['active'])
    self.assertEqual(len([a for a in rpc(self.a,'bootstrap')['applications'] if a['job_id']==self.jobs[0]['id']]),1)

if __name__=='__main__':unittest.main(verbosity=2)
