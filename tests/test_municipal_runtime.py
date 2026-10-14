"""Run only against a disposable Jac API. Required runtime checks never skip.

STACK_API_URL and STACK_WORKER_API must name that isolated local API.
--prepare stores a manifest; restart the backend, then run --fixtures.
--live collects only the configured San Francisco source and writes an audit.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from discovery import sources,worker
from discovery.normalize import normalize
from test_api import account,rpc
from test_municipal_discovery import SOURCE,detail

TOKEN=Path('storage/discovery/worker-token').read_text().strip()
STATE=Path('artifacts/municipal-runtime-state.json')

def service(name,**args):return worker.call(name,{'token':TOKEN,**args})

def report():return service('discovery_report')

def source_state():return next(x for x in report()['sources'] if x['id']==SOURCE['id'])

def reset(action='refresh'):service('discovery_manage',id=SOURCE['id'],action=action)

def run_fixture(payload):
    reset('retry')
    with patch.object(sources,'json_fetch',side_effect=payload):
        result=worker.batch(TOKEN,SOURCE['id'])
    assert not result.get('idle'),result
    return result

def prepare():
    # Claim once to register sources, then return that lease without making HTTP calls.
    work=service('discovery_claim',preferred_id=SOURCE['id'])
    service('discovery_complete',id=work['id'],lease=work['lease'],error='Disposable fixture setup')
    reset('configure')
    first=run_fixture(lambda _: {'totalFound':12,'content':[{'id':str(i)} for i in range(12)]})
    assert first['result']['checkpoint']=={'ids':[str(i) for i in range(12)],'detail_offset':0}
    _,_,a=account();rpc(a,'bootstrap')
    STATE.parent.mkdir(exist_ok=True)
    STATE.write_text(json.dumps({'account':a,'checkpoint':first['result']['checkpoint']}))
    print('PASS: adapter → worker → persisted ID manifest; restart backend before --fixtures',flush=True)

def fixtures():
    state=json.loads(STATE.read_text());a=state['account']
    reset('retry')
    work=service('discovery_claim',preferred_id=SOURCE['id'])
    assert work['checkpoint']==state['checkpoint'],work
    # Return the checked lease; the actual batch claims it again with the same checkpoint.
    service('discovery_complete',id=work['id'],lease=work['lease'],error='Checkpoint verified after server restart')
    for count in (10,2):
        page=run_fixture(lambda url:detail(url.rsplit('/',1)[1]))
        assert not page['error'],page
        assert len(page['result']['jobs'])==count
    jobs=rpc(a,'search_jobs',query='MunicipalTest',filters={'timeline':'all'})['jobs']
    assert len(jobs)==12,jobs
    assert all(j['company']==SOURCE['name'] and j['employment_type']=='Full-time' and j['country']=='US' for j in jobs)
    selected=jobs[0];rpc(a,'swipe',job_id=selected['id'],action='apply')
    # Duplicate via a second, separately registered source, same employer requisition.
    import_url='https://example.com/municipal-fixture'
    rpc(a,'import_job_url',url=import_url)
    from discovery.normalize import digest
    second_id='career:'+digest(import_url)
    other=service('discovery_claim',preferred_id=second_id)
    raw=detail('0')
    alias=normalize({'title':raw['name'],'company':SOURCE['name'],'url':import_url,
                     'employer_domain':SOURCE['domain'],'requisition':'opening-0',
                     'country':'US','location':'San Francisco, CA','description':'Independent fixture copy.'},other['config'])
    service('discovery_complete',id=other['id'],lease=other['lease'],result={'jobs':[alias],'complete':True})
    assert len(rpc(a,'search_jobs',query='MunicipalTest',filters={'timeline':'all'})['jobs'])==12
    # Malformed refresh may not close previous listings.
    reset();bad=run_fixture(lambda _: {'totalFound':'bad','content':[]})
    assert bad['error'] and source_state()['status']=='error'
    assert len(rpc(a,'search_jobs',query='MunicipalTest',filters={'timeline':'all'})['jobs'])==12
    # Explicit employer expiry becomes unavailable immediately, including a warm search cache.
    reset()
    run_fixture(lambda _: {'totalFound':1,'content':[{'id':'1'}]})
    expired=detail('1');expired['customField'][0]['valueLabel']='01/01/20'
    run_fixture(lambda _:expired)
    assert not rpc(a,'get_job',id=normalize({'title':detail('1')['name'],'company':SOURCE['name'],'url':detail('1')['applyUrl'],'employer_domain':'sf.gov','requisition':'opening-1'},SOURCE)['id'])['active']
    assert len(rpc(a,'search_jobs',query='MunicipalTest',filters={'timeline':'all'})['jobs'])==11
    # Two clean missing cycles separated by 24h are needed for removal. Do not wait a day:
    # the focused Jac test checks that time boundary with actual persisted nodes.
    reset('disable')
    assert worker.batch(TOKEN,SOURCE['id']).get('idle')
    reset('purge')
    remaining=rpc(a,'search_jobs',query='MunicipalTest',filters={'timeline':'all'})['jobs']
    assert len(remaining)<=1,remaining  # only independently supplied copy may remain
    assert not any(j.get('source_id')==SOURCE['id'] for j in remaining)
    # Existing tracked decision survives source withdrawal.
    assert len([x for x in rpc(a,'bootstrap')['applications'] if x['job_id']==selected['id']])==1
    service('discovery_manage',id=second_id,action='purge')
    assert rpc(a,'search_jobs',query='MunicipalTest',filters={'timeline':'all'})['jobs']==[]
    print('PASS: restart, fixture worker/catalog/account journey, identity, malformed response, expiry, disable, purge and tracked decision',flush=True)

def live(jac):
    reset('configure')
    _,_,a=account();rpc(a,'bootstrap')
    before=report();batches=0;collected={};manifest=[]
    while batches<110:
        # Each fresh Jac worker process proves persisted checkpoints are used.
        reset('retry')
        subprocess.run([jac,'run','--main','--no-serve','scripts/discovery-worker.jac','--','--once','--source',SOURCE['id']],check=True,timeout=300)
        batches+=1;current=report();state=next(s for s in current['sources'] if s['id']==SOURCE['id'])
        assert state['status']!='error',state
        for job in current['jobs']:
            if job.get('source_id')==SOURCE['id']:collected[job['id']]=job
        if state['status']=='ready':break
    else:raise AssertionError('Collection exceeded manifest/batch budget')
    # Refetch all active IDs with independent listing requests, then ten exact details.
    endpoint='https://api.smartrecruiters.com/v1/companies/'+SOURCE['board']+'/postings'
    active=set();offset=0
    while offset<1000:
        payload=sources.json_fetch(endpoint+f'?limit=100&offset={offset}&country=us')
        active.update(str(x['id']) for x in payload['content']);offset+=len(payload['content'])
        if offset>=payload['totalFound']:break
        assert payload['content']
    visible=[j for j in collected.values() if j.get('active')]
    assert len(visible)>=25,len(visible)
    samples=[]
    for summary in sorted(visible,key=lambda j:j['source_job_id'])[:10]:
        job=rpc(a,'get_job',id=summary['id'])
        ident=job['source_job_id'];assert ident in active,ident
        raw=sources.json_fetch(endpoint+'/'+ident)
        assert raw['active'] and raw.get('visibility','PUBLIC')=='PUBLIC'
        assert job['title']==sources.plain(raw['name'])
        assert job['company']==raw['company']['name']
        assert job['url']==raw['applyUrl']
        assert job['description']==sources.plain('\n'.join(x.get('text','') for x in raw['jobAd']['sections'].values()))
        assert job['qualifications']==sources.plain(raw['jobAd']['sections'].get('qualifications',{}).get('text',''))
        assert job['employment_type']==raw['typeOfEmployment']['label']
        assert job['country']=='US' and raw['location']['city'] in job['location']
        from discovery.normalize import stamp
        assert job['posted_at']==stamp(raw.get('releasedDate'))
        assert job['expires_at']==(sources.smartrecruiters_expiry(SOURCE,raw) or 0)
        if raw.get('compensation'):
            assert job['compensation']['min']==raw['compensation'].get('min')
            assert job['compensation']['max']==raw['compensation'].get('max')
        view=rpc(a,'get_job',id=job['id']);assert view['active'] and view['description']==job['description']
        # Exact title queries exercise account matching, rather than worker report alone.
        results=rpc(a,'search_jobs',query=job['title'][:160],filters={'timeline':'all'})['jobs']
        assert job['id'] in [x['id'] for x in results],job['title']
        samples.append({k:job[k] for k in ('id','source_job_id','url','title','location','employment_type','posted_at','expires_at','salary')})
    result={'audited_at':time.time(),'source':SOURCE,'batches':batches,
            'before_active_us':sum(j.get('active',False) and j.get('country')=='US' for j in before['jobs']),
            'before_government':sum(j.get('active',False) and j.get('source_id')==SOURCE['id'] for j in before['jobs']),
            'after_active_us':sum(j.get('active',False) and j.get('country')=='US' for j in current['jobs']),
            'after_government':len(visible),'official_active_ids':len(active),
            'sample_verified':len(samples),'samples':samples,'scope':'Disposable catalog, not production or nationwide recall'}
    Path('artifacts/municipal-live-audit.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['prepare','fixtures','live']);parser.add_argument('--jac',default='jac')
    args=parser.parse_args();{'prepare':prepare,'fixtures':fixtures,'live':lambda:live(args.jac)}[args.mode]()
