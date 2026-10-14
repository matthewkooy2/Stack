"""Deterministic public municipal adapter contracts; no network or credentials."""
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from discovery import sources

SOURCE=next(x for x in json.loads(Path('discovery/sources.json').read_text()) if x.get('snapshot'))

def detail(i='1'):
    return {'id':str(i),'jobId':'opening-'+str(i),'name':'MunicipalTest Inspector '+str(i),
            'active':True,'visibility':'PUBLIC','company':{'name':SOURCE['name']},
            'applyUrl':'https://jobs.smartrecruiters.com/'+SOURCE['board']+'/'+str(i)+'?oga=true',
            'location':{'city':'San Francisco','region':'CA','country':'us','hybrid':True},
            'releasedDate':'2026-10-01T12:00:00Z','typeOfEmployment':{'label':'Full-time'},
            'compensation':{'min':90000,'max':110000,'currency':'USD','period':'YEARLY'},
            'customField':[{'fieldLabel':'Close Date','valueLabel':'10/19/26'}],
            'jobAd':{'sections':{'jobDescription':{'text':'Inspect city facilities.'},
                                'qualifications':{'text':'Requires a current inspection license.'}}}}

class MunicipalContracts(unittest.TestCase):
    def test_manifest_then_bounded_details(self):
        with patch.object(sources,'json_fetch',return_value={'totalFound':12,'content':[{'id':str(i)} for i in range(12)]}):
            first=sources.collect(SOURCE,{})
        self.assertFalse(first['complete']);self.assertEqual(first['jobs'],[])
        state=json.loads(json.dumps(first['checkpoint']))  # persisted restart representation
        with patch.object(sources,'json_fetch',side_effect=lambda url:detail(url.rsplit('/',1)[1])) as fetch:
            page=sources.collect(SOURCE,state)
            self.assertEqual(fetch.call_count,10);self.assertEqual(len(page['jobs']),10)
            last=sources.collect(SOURCE,json.loads(json.dumps(page['checkpoint'])))
            self.assertTrue(last['complete']);self.assertEqual(len(last['jobs']),2)
        self.assertEqual(len({j['id'] for j in page['jobs']+last['jobs']}),12)

    def test_fields_and_inclusive_local_deadline(self):
        with patch.object(sources,'json_fetch',return_value=detail()):
            job=sources.collect(SOURCE,{'ids':['1'],'detail_offset':0})['jobs'][0]
        self.assertEqual(job['company'],SOURCE['name']);self.assertEqual(job['country'],'US')
        self.assertEqual(job['location'],'San Francisco, CA, us')
        self.assertEqual(job['employment_type'],'Full-time');self.assertEqual(job['mode'],'Hybrid')
        self.assertIn('current inspection license',job['qualifications'])
        self.assertIn('Inspect city facilities',job['description'])
        self.assertEqual(job['compensation']['min'],90000);self.assertEqual(job['compensation']['unit'],'year')
        self.assertEqual(job['posted_at'],1790856000)
        from datetime import datetime,timezone
        self.assertEqual(datetime.fromtimestamp(job['expires_at'],timezone.utc).isoformat(),'2026-10-20T07:00:00+00:00')

    def test_multi_page_manifest(self):
        state={}
        for offset in (0,100):
            payload={'totalFound':101,'content':[{'id':str(i)} for i in range(offset,min(101,offset+100))]}
            with patch.object(sources,'json_fetch',return_value=payload) as fetch:
                result=sources.collect(SOURCE,state)
                self.assertEqual(fetch.call_count,1);self.assertIn('limit=100',fetch.call_args.args[0])
            state=json.loads(json.dumps(result['checkpoint']))
        self.assertEqual(len(state['ids']),101);self.assertEqual(state['detail_offset'],0)

    def test_manifest_failure_and_budget(self):
        for payload in ([],{}, {'content':[],'totalFound':'1'}, {'content':[],'totalFound':1001},
                        {'content':[],'totalFound':1}, {'content':[{'id':'1'},{'id':'1'}],'totalFound':2},
                        {'content':[{}],'totalFound':1}, {'content':[{'id':'1'}],'totalFound':0}):
            with self.subTest(payload=payload),patch.object(sources,'json_fetch',return_value=payload):
                with self.assertRaises(ValueError):sources.collect(SOURCE,{})
        with patch.object(sources,'json_fetch',return_value={'content':[{'id':'2'}],'totalFound':3}):
            with self.assertRaises(ValueError):sources.collect(SOURCE,{'ids':['1'],'listing_offset':1,'total':2})

    def test_public_withdrawal_and_404(self):
        for item in ({**detail(),'active':False},{**detail(),'visibility':'INTERNAL'}):
            with patch.object(sources,'json_fetch',return_value=item):
                self.assertEqual(sources.collect(SOURCE,{'ids':['1'],'detail_offset':0})['jobs'],[])
        with patch.object(sources,'json_fetch',side_effect=ValueError('Source returned HTTP 404.')):
            self.assertTrue(sources.collect(SOURCE,{'ids':['1'],'detail_offset':0})['complete'])
        with patch.object(sources,'json_fetch',side_effect=ValueError('Source returned HTTP 503.')):
            with self.assertRaises(ValueError):sources.collect(SOURCE,{'ids':['1'],'detail_offset':0})

    def test_malformed_detail_never_empty_success(self):
        for item in ([],{}, {**detail(),'id':'wrong'}, {**detail(),'jobAd':{}}, {**detail(),'name':''}):
            with patch.object(sources,'json_fetch',return_value=item):
                with self.assertRaises(ValueError):sources.collect(SOURCE,{'ids':['1'],'detail_offset':0})

    def test_unknown_fields_are_not_invented(self):
        item=detail();item.pop('compensation');item['customField'][0]['valueLabel']='Until filled'
        item.pop('releasedDate');item.pop('typeOfEmployment')
        with patch.object(sources,'json_fetch',return_value=item):
            job=sources.collect(SOURCE,{'ids':['1'],'detail_offset':0})['jobs'][0]
        self.assertEqual(job['salary'],'Pay not listed');self.assertEqual(job['expires_at'],0)
        self.assertEqual(job['posted_at'],0);self.assertEqual(job['employment_type'],'Unknown')

if __name__=='__main__':unittest.main(verbosity=2)
