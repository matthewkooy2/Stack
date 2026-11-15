"""Deterministic source contracts and security regressions, no network or credentials."""
import unittest
from unittest.mock import patch
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from discovery import sources as s
from discovery.normalize import normalize, matches, validate_filters, canonical, classify, same_opening
from discovery.ranking import rank, encode_cursor, decode_cursor, posting_label
from discovery.transport import public_url, addresses
from discovery.html_extract import extract

SOURCE={'id':'test','name':'Example','adapter':'career','domain':'example.com'}
def job(**kw):return normalize({'title':'Registered Nurse','company':'Example','url':'https://example.com/jobs/123','location':'Detroit, MI','country':'US',**kw},SOURCE)

class DiscoveryContracts(unittest.TestCase):
 def test_date_filter_and_ranking(self):
  unknown=job(title='Nurse',url='https://example.com/unknown')
  older=job(title='Nurse',posted_at=1000,url='https://example.com/old')
  newer=job(title='Nurse Manager',posted_at=2000,url='https://example.com/new')
  self.assertFalse(matches(unknown,'nurse',{'has_posting_date':True}))
  self.assertTrue(matches(older,'nurse',{'has_posting_date':True}))
  self.assertTrue(matches(unknown,'nurse',{'has_posting_date':False}))
  self.assertEqual(sorted([unknown,older,newer],key=lambda j:rank(j,'newest','nurse')),[newer,older,unknown])
  self.assertEqual(sorted([unknown,older,newer],key=lambda j:rank(j,'relevance','nurse')),[older,unknown,newer])
  self.assertEqual(sorted([unknown,older,newer],key=lambda j:rank(j,'relevance','')),[newer,older,unknown])
  self.assertEqual(validate_filters('',{})['filters']['sort'],'relevance')
  for f in ({'has_posting_date':'true'},{'sort':'random'}):
   with self.assertRaises(ValueError):validate_filters('',f)
 def test_rank_cursor_and_date_labels(self):
  key=rank(job(posted_at=1000),'newest','nurse')
  cursor=encode_cursor('search',key)
  self.assertEqual(decode_cursor(cursor,'search'),key)
  for value in (cursor,'bad',encode_cursor('search',[False,0,'job_'+'a'*32])):
   with self.assertRaises(ValueError):decode_cursor(value,'changed' if value==cursor else 'search')
  with patch('discovery.ranking.time.time',return_value=1000000):
   self.assertEqual(posting_label(0),'Posting date unknown')
   self.assertEqual(posting_label(999000),'Posted within 24 hours')
   self.assertEqual(posting_label(1000000-2*86400),'Posted 2 days ago')
 def test_placeholder_requisitions_never_merge_different_openings(self):
  a=job(requisition='See Opening ID',employer_domain='example.com')
  b=job(requisition='See Opening ID',employer_domain='example.com',url='https://example.com/jobs/456')
  self.assertNotEqual(a['id'],b['id'])
  self.assertEqual(job(requisition='R123',employer_domain='example.com')['id'],job(requisition='R123',employer_domain='example.com',url='https://elsewhere.com/123')['id'])
 def test_distinct_requisitions_and_tracking_urls(self):
  self.assertNotEqual(job(requisition='R1',employer_domain='x.com')['id'],job(requisition='R2',employer_domain='x.com')['id'])
  self.assertEqual(canonical('https://x.com/job/1?utm_source=google&job=2'),canonical('https://x.com/job/1?job=2'))
 def test_unknowns_and_hourly_salary(self):
  j=job(compensation={'min':35,'max':42,'unit':'hour','currency':'USD'})
  self.assertEqual(j['mode'],'Unknown');self.assertIn('/ hour',j['salary'])
  self.assertEqual(job(compensation={'min':30,'unit':'Per Year'})['compensation']['currency'],'Unknown')
  self.assertEqual(job(compensation={'min':30,'unit':'Per Year'})['compensation']['unit'],'year')
  self.assertTrue(matches(j,'nurse',{'country':'US','salary_min':40,'salary_period':'hour'}))
  # Hourly pay is converted (2,080 hours/year), not excluded for using a different unit.
  self.assertTrue(matches(j,'nurse',{'salary_min':40,'salary_period':'year'}))
  self.assertFalse(matches(j,'nurse',{'salary_min':90000,'salary_period':'year'}))
  # Unlisted pay is uncertain, not a conflict: shown unless confirmed matches are requested.
  self.assertTrue(matches(job(),'nurse',{'salary_min':1,'salary_period':'year'}))
  self.assertFalse(matches(job(),'nurse',{'salary_min':1,'salary_period':'year','confirmed_only':True}))
 def test_professions_and_aliases(self):
  self.assertEqual(classify('Registered Nurse'),'Healthcare practitioners')
  self.assertEqual(classify('Electrician'),'Construction and extraction')
  self.assertEqual(classify('Software Engineer'),'Computer and mathematics')
  self.assertTrue(matches(job(title='Registered Nurse'),'RN',{}))
  self.assertTrue(matches(job(title='Astral Flibbertigibbet'),'flibbertigibbet',{}))
 def test_validation(self):
  for filters in ({'country':'CA'},{'salary_min':-1},{'surprise':True}):
   with self.assertRaises(ValueError):validate_filters('nurse',filters)
 def test_external_content_sanitized(self):
  self.assertEqual(job(description='<script>evil()</script><p>Hello &amp; bye</p>')['description'],'Hello & bye')
  self.assertEqual(job(description='&lt;p&gt;Graduating in 2027&lt;/p&gt;')['description'],'Graduating in 2027')
 def test_ssrf(self):
  for url in ('file:///etc/passwd','http://localhost/jobs','http://user:pass@example.com','http://example.com:8080','http://metadata.google.internal'):
   with self.assertRaises(ValueError):public_url(url)
  with patch('socket.getaddrinfo',return_value=[(2,1,6,'',('127.0.0.1',80))]):
   with self.assertRaises(ValueError):addresses('example.com',80)
  with patch('socket.getaddrinfo',return_value=[(2,1,6,'',('8.8.8.8',80)),(2,1,6,'',('10.0.0.1',80))]):
   with self.assertRaises(ValueError):addresses('example.com',80)
 def test_greenhouse_page_checkpoint(self):
  def reply(url,**kwargs):
   if 'content=true' in url:raise ValueError('Source response exceeds the configured body limit.')
   if url.endswith('/jobs'):return {'jobs':[{'id':i} for i in range(11)]}
   n=url.rsplit('/',1)[-1].split('?')[0];return {'id':n,'title':'Nurse','absolute_url':'https://example.com/jobs/'+n,'content':'Valid','location':{'name':'Detroit, MI'},'requisition_id':'See Opening ID'}
  with patch.object(s,'json_fetch',side_effect=reply):
   r=s.collect({**SOURCE,'adapter':'greenhouse','board':'test'},{});self.assertFalse(r['complete']);self.assertEqual(len(r['jobs']),10);self.assertEqual(len(set(j['id'] for j in r['jobs'])),10)
   r2=s.collect({**SOURCE,'adapter':'greenhouse','board':'test'},r['checkpoint']);self.assertTrue(r2['complete']);self.assertEqual(len(r2['jobs']),1)
 def test_greenhouse_publication_and_scoped_employer_detail(self):
  board={**SOURCE,'id':'greenhouse:test','adapter':'greenhouse','board':'test','posting_schema_host':'example.com','posting_body_selector':'.listing-body'}
  item={'id':15,'title':'Analyst','absolute_url':'https://example.com/jobs/15','location':{'name':'US'},
        'first_published':'2025-02-01','updated_at':'2026-05-02','content':'Board description',
        'metadata':[{'name':'Time Type','value':'Full time'}]}
  schema={'@type':'JobPosting','identifier':{'value':'15'},'title':'Analyst','description':'Employer description',
          'jobLocation':{'address':{'addressCountry':'US','addressLocality':'Chicago'}},
          'baseSalary':{'currency':'USD','value':{'minValue':'90,000','maxValue':120000,'unitText':'YEAR'}}}
  import json
  def read(detail):
   page={'text':'<script type="application/ld+json">'+json.dumps(detail)+'</script><div class="listing-body"><p>US base salary: $90,000 to $120,000.</p></div><footer>Salary: $5.</footer>','url':item['absolute_url']}
   with patch.object(s,'json_fetch',side_effect=[{'jobs':[{'id':15}]},item]),patch.object(s,'page_fetch',return_value=page) as fetch:
    result=s.collect(board,{})['jobs'][0]
    fetch.assert_called_once_with(item['absolute_url'],allowed_hosts={'example.com'})
    return result
  enriched=read(schema);other=read({**schema,'identifier':{'value':'16'}})
  self.assertEqual(enriched['id'],other['id']);self.assertEqual(enriched['posted_at'],1738368000)
  self.assertEqual(enriched['salary'],'USD 90000–120000 / year');self.assertEqual(other['salary'],'Pay not listed')
  self.assertEqual(enriched['locations'],['Chicago, US']);self.assertEqual(other['employment_type'],'Full-time')
  self.assertEqual(other['description'],'Board description')
  self.assertIn('US base salary',enriched['pay_text']);self.assertNotIn('$5',enriched['pay_text'])
  self.assertFalse(other['pay_text'])
  with patch.object(s,'json_fetch',return_value=item),patch.object(s,'page_fetch',side_effect=ValueError('Page blocked')):
   fallback=s.collect(board,{'ids':['15']})['jobs'][0]
   self.assertEqual(fallback['id'],enriched['id']);self.assertEqual(fallback['description'],'Board description')
   self.assertEqual(fallback['attribution']['employer_details_status'],'unavailable')
 def test_greenhouse_pay_period_and_regional_ranges(self):
  band={'title':'Hourly Base Pay Range:','min_cents':1850,'max_cents':2500,'currency_type':'USD'}
  self.assertEqual(s.greenhouse_pay({'pay_input_ranges':[band]})['min'],18.5)
  self.assertEqual(s.greenhouse_pay({'pay_input_ranges':[band]})['unit'],'hour')
  self.assertIsNone(s.greenhouse_pay({'pay_input_ranges':[{**band,'title':'Base Salary'}]})['unit'])
  self.assertFalse(s.greenhouse_pay({'pay_input_ranges':[band,band]}))
 def test_ashby_unlisted_and_multiple_locations(self):
  payload={'jobs':[{'title':'Nurse','isListed':False},{'title':'Nurse','jobUrl':'https://example.com/jobs/1','location':'Detroit','secondaryLocations':[{'location':'Chicago'}],'address':{'postalAddress':{'addressCountry':'USA'}},'employmentType':'FullTime'}]}
  with patch.object(s,'json_fetch',return_value=payload):
   r=s.collect({**SOURCE,'adapter':'ashby','board':'test'},{});self.assertEqual(len(r['jobs']),1);self.assertEqual(r['jobs'][0]['locations'],['Detroit','Chicago']);self.assertEqual(r['jobs'][0]['country'],'US')
 def test_explicit_secondary_us_address_and_eligible_remote_region(self):
  data={'title':'Analyst','jobUrl':'https://example.com/job/1','location':'Toronto',
        'address':{'postalAddress':{'addressCountry':'CA'}},
        'secondaryLocations':[{'location':'Portland','address':{'addressCountry':'US'}}]}
  with patch.object(s,'json_fetch',return_value={'jobs':[data]}):
   observed=s.collect({**SOURCE,'adapter':'ashby','board':'test'}, {})['jobs'][0]
   self.assertEqual(observed['country'],'US')
  self.assertEqual(s.country('Remote US'),'US');self.assertEqual(s.country('New Zealand'),'Unknown')
 def test_lever_pagination(self):
  payload=[{'id':str(i),'text':'Nurse','hostedUrl':'https://example.com/jobs/'+str(i),'categories':{'location':'Detroit, MI'}} for i in range(100)]
  with patch.object(s,'json_fetch',return_value=payload):
   r=s.collect({**SOURCE,'adapter':'lever','board':'test'},{});self.assertEqual(r['checkpoint']['offset'],100);self.assertFalse(r['complete'])
 def test_smartrecruiters_details_and_completion(self):
  with patch.object(s,'json_fetch',side_effect=[{'content':[{'id':'1'}],'totalFound':1},{'id':'1','name':'Chef','location':{'country':'us','city':'Detroit'},'jobAd':{'sections':{'jobDescription':{'text':'Cook meals'}}}}]):
   r=s.collect({**SOURCE,'adapter':'smartrecruiters','board':'test'},{});self.assertTrue(r['complete']);self.assertEqual(r['jobs'][0]['description'],'Cook meals')
 def test_paid_providers_are_not_adapters(self):
  for adapter in ('adzuna','theirstack','usajobs'):self.assertNotIn(adapter,s.ADAPTERS)
 def test_jsonld_graph_remote_geography(self):
  import json
  data={'@graph':[{'@type':'JobPosting','title':'Nurse','hiringOrganization':{'name':'Example'},'description':'Care','jobLocationType':'TELECOMMUTE','applicantLocationRequirements':{'name':'United States'},'baseSalary':{'currency':'USD','value':{'minValue':30,'maxValue':40,'unitText':'HOUR'}}}]}
  with patch.object(s,'page_fetch',return_value={'url':'https://example.com/job/1','text':'<script type="application/ld+json">'+json.dumps(data)+'</script>'}):
   j=s.collect({**SOURCE,'url':'https://example.com/job/1'}, {})['jobs'][0];self.assertEqual(j['remote_eligibility'],'United States');self.assertEqual(j['country'],'US');self.assertEqual(j['compensation']['unit'],'hour')
 def test_github_directory_is_not_a_job_and_does_not_execute(self):
  with patch.object(s,'fetch',return_value={'status':200,'headers':{'etag':'v1'},'text':'[Company](https://jobs.lever.co/company)\n<script>execute()</script>'}):
   r=s.collect({**SOURCE,'adapter':'github','repo':'example/jobs'},{});self.assertEqual(r['jobs'],[]);self.assertEqual(r['candidates'][0]['adapter'],'lever');self.assertEqual(r['checkpoint']['etag'],'v1')
  with patch.object(s,'fetch',return_value={'status':304}):
   self.assertEqual(s.collect({**SOURCE,'adapter':'github','repo':'example/jobs'},{'etag':'v1'})['candidates'],[])
 def test_html_parser_requires_explicit_selectors(self):
  page='<h1 id="title">Nurse</h1><div class="description">Care for patients</div>'
  self.assertEqual(extract(page,SOURCE,'https://example.com/1'),[])
  self.assertEqual(extract(page,{**SOURCE,'selectors':{'title':'#title','description':'.description'}},'https://example.com/1')[0]['title'],'Nurse')
 def test_similarity_requires_strong_evidence(self):
  text='Provide compassionate patient care in the community. '*30
  a=job(description=text);b={**a,'source':'theirstack'}
  self.assertTrue(same_opening(a,b))
  self.assertFalse(same_opening(a,{**b,'snippet':True}))
  self.assertFalse(same_opening({**a,'requisition':'A1'},{**b,'requisition':'A2'}))
  self.assertFalse(same_opening(a,{**b,'locations':['Boston, MA']}))
 def test_source_shape_change_not_an_empty_success(self):
  with patch.object(s,'json_fetch',return_value={'error':'bad'}):
   with self.assertRaises(ValueError):s.collect({**SOURCE,'adapter':'ashby','board':'test'}, {})

if __name__=='__main__':unittest.main(verbosity=2)
