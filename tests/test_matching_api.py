"""End-to-end matching through the API: profile inputs -> search -> displayed jobs.

Creates temporary catalog fixtures through the worker path (normalize -> upsert),
then checks exclusion, uncertainty, explanations, saved-search precedence, and
preference changes. Fixtures are purged afterward. Requires the local server.
"""
import sys,time,uuid,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from discovery.normalize import normalize,digest
from test_api import account,rpc
from test_catalog_api import worker

BASE_PREFS={'stage':'Recent graduate','years':0,'education':"Bachelor's",'modes':[],'employment_types':['Full-time'],'salary_min':35,'salary_period':'hour','exclude_companies':[],'exclude_terms':[],'soft':[]}

class MatchingAPI(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
    _,_,cls.a=account();cls.label='Zq'+uuid.uuid4().hex[:8]
    cls.url='https://example.com/stack-match-tests/'+cls.label;cls.source_id='career:'+digest(cls.url)
    rpc(cls.a,'import_job_url',url=cls.url)
    work=worker('discovery_claim',preferred_id=cls.source_id)
    assert work.get('id')==cls.source_id,work
    def listing(key,**raw):
        base={'title':f'Registered Nurse {cls.label}','company':'Match test employer','url':f'{cls.url}/{key}','country':'US','location':'Detroit, MI','posted_at':time.time()-3600}
        return normalize({**base,**raw},work['config'])
    cls.jobs={
      'fit':listing('fit',employment_type='Full-time',description='New graduates welcome. RN license required. Pay range: $38 - $52 per hour.'),
      'contract':listing('contract',employment_type='Contract',description='13-week assignment. Pay: $60 per hour.'),
      'camden':listing('camden',location='Camden, NJ',employment_type='Full-time',description='Pay: $40 per hour.'),
      'unknown':listing('unknown',description='Care for patients on a busy unit.'),
      'senior':listing('senior',title=f'Senior Registered Nurse {cls.label}',employment_type='Full-time',description='Requirements\n5+ years of acute care experience required. Pay: $50 per hour.'),
    }
    worker('discovery_complete',id=work['id'],lease=work['lease'],result={'jobs':list(cls.jobs.values()),'complete':True})
    cls.ids={k:v['id'] for k,v in cls.jobs.items()}
 @classmethod
 def tearDownClass(cls):worker('discovery_manage',id=cls.source_id,action='purge')
 def profile(self,location='Detroit, MI',**prefs):
    result=rpc(self.a,'save_profile',name='Match Tester',role=f'{self.label} registered nurse',location=location,mode='Any',notifications=False,graduation_month='2026-05',available_from='',preferences={**BASE_PREFS,**prefs})
    self.assertNotIn('error',result);return result
 def search(self,query='',**filters):
    result=rpc(self.a,'search_jobs',query=query,filters=filters)
    self.assertNotIn('error',result)
    return result,{k for k,v in self.ids.items() if v in [j['id'] for j in result['jobs']]},{j['id']:j for j in result['jobs']}
 def test_01_profile_inputs_drive_results_and_explanations(self):
    self.profile()
    result,shown,jobs=self.search()
    self.assertEqual(result['criteria']['sources']['roles'],'profile')
    self.assertEqual(shown,{'fit','unknown'})
    fit,unknown=jobs[self.ids['fit']]['match'],jobs[self.ids['unknown']]['match']
    self.assertEqual(fit['verdict'],'match')
    self.assertTrue(any('Detroit' in r for r in fit['reasons']));self.assertTrue(any('$38/hr' in r for r in fit['reasons']))
    self.assertIn('RN license required.',fit['confirm'])
    self.assertEqual(unknown['verdict'],'uncertain')
    self.assertEqual({u.split(':')[0] for u in unknown['uncertain']},{'Employment type','Pay'})
    # Confirmed matches rank above unconfirmed ones.
    self.assertLess([j['id'] for j in result['jobs']].index(self.ids['fit']),[j['id'] for j in result['jobs']].index(self.ids['unknown']))
    reasons={x['reason'] for x in result['excluded']}
    self.assertTrue({'Employment type','Location'}<=reasons and reasons&{'Level','Experience'},reasons)
    _,shown,_=self.search(confirmed_only=True)
    self.assertEqual(shown,{'fit'})
    detail=rpc(self.a,'get_job',id=self.ids['unknown'])
    self.assertEqual(detail['match']['verdict'],'uncertain')
 def test_02_changing_preferences_updates_results(self):
    self.profile(employment_types=['Contract'])
    self.assertEqual(self.search()[1],{'contract','unknown'})
    self.profile(employment_types=['Full-time'],soft=['employment_types'])
    result,shown,jobs=self.search()
    self.assertEqual(shown,{'fit','unknown','contract'})
    order=[j['id'] for j in result['jobs']]
    self.assertLess(order.index(self.ids['fit']),order.index(self.ids['contract']))
    self.assertTrue(any(c.startswith('Employment type') for c in jobs[self.ids['contract']]['match']['caveats']))
    self.profile(stage='Experienced',years=8)
    self.assertIn('senior',self.search()[1])
 def test_03_saved_search_overrides_are_explicit_and_profile_edits_win(self):
    self.profile()
    saved=rpc(self.a,'save_search',query='',filters={'location':'Camden, NJ','employment_types':['Full-time'],'salary_min':35,'salary_period':'hour'})
    # Only the value that differs from the profile is stored as an override.
    self.assertEqual(saved['query'],'');self.assertEqual(set(saved['filters'])-{'country','sort'},{'location'})
    result,shown,_=self.search(**saved['filters'])
    self.assertEqual(result['criteria']['sources']['location'],'search')
    self.assertEqual(shown,{'camden'})
    self.profile(location='Newark, NJ')
    boot=rpc(self.a,'bootstrap')
    self.assertNotIn('location',boot['saved_search']['filters'])
    result,shown,_=self.search(**boot['saved_search']['filters'])
    self.assertEqual(result['criteria']['location'],'Newark, NJ');self.assertEqual(shown,set())
    rpc(self.a,'save_search',query='',filters={'mode':'Remote'})
    self.assertEqual(rpc(self.a,'bootstrap')['saved_search']['filters'].get('modes'),['Remote'])
    rpc(self.a,'reset_search')
    self.assertEqual(rpc(self.a,'bootstrap')['saved_search'],{'query':'','filters':{}})
 def test_04_conflicting_inputs_are_reported(self):
    self.profile(stage='Student')
    result,shown,jobs=self.search(query=f'Senior {self.label} registered nurse')
    # The senior listing conflicts with the student stage; a listing without a stated level stays visible but unconfirmed.
    self.assertEqual(shown,{'unknown'})
    self.assertIn('Level: Level not stated',jobs[self.ids['unknown']]['match']['uncertain'])
    self.assertTrue(any('career stage is Student' in n for n in result['criteria']['notices']))
 def test_05_invalid_preferences_rejected(self):
    for bad in ({'stage':'Wizard'},{'years':-1},{'modes':['Moon']},{'salary_min':'lots'},{'unknown_key':1}):
        result=rpc(self.a,'save_profile',name='Match Tester',role='nurse',location='',mode='Any',notifications=False,preferences={**BASE_PREFS,**bad})
        self.assertIn('error',result,bad)

if __name__=='__main__':unittest.main(verbosity=2)
