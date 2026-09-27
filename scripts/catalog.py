#!/usr/bin/env python3
"""Local source administration and coverage audit; never prints credentials."""
import argparse,json,sys,time
from pathlib import Path
from collections import Counter,defaultdict
from urllib.request import Request,urlopen
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from discovery.sources import collect
from discovery.transport import json_fetch
from urllib.parse import quote
from discovery.normalize import canonical

ROOT=Path(__file__).resolve().parents[1]
def call(name,**args):
    token=(ROOT/'storage/discovery/worker-token').read_text().strip()
    req=Request('http://127.0.0.1:8000/function/'+name,data=json.dumps({'token':token,**args}).encode(),headers={'Content-Type':'application/json'})
    result=json.load(urlopen(req,timeout=120))['data']['result']
    if result.get('error'):raise RuntimeError(result['error'])
    return result

def report(audit=False):
    data=call('discovery_report');jobs=data['jobs'];sources={s['id']:s for s in data['sources']};sectors=sorted({x['sector'] for x in json.loads((ROOT/'discovery/employers.json').read_text())})
    active=[j for j in jobs if j['active'] and not j['stale'] and j['country']=='US']
    rows=[]
    for sector in sectors:
        ss=[s for s in sources.values() if s.get('sector')==sector]
        js=[j for j in active if any(sources.get(x['source_id'],{}).get('sector')==sector for x in j['sources'])]
        missing=[s['name'] for s in ss if not s.get('last_success') or s['status'] in ('error','review','unavailable','partial')]
        rows.append({'sector':sector,'registered_sources':len(ss),'active_us_jobs':len(js),'missing_or_incomplete_employers':missing})
    output={'generated_at':time.time(),'catalog_jobs':len(jobs),'active_us_jobs':len(active),'occupation_counts':dict(Counter(j['occupation'] for j in active)),
      'sectors':rows,'sources':data['sources'],'reserved_usage':data['usage'],'audit':{'status':'not_run','required_sample':120},
      'limits':['Registered employers are discovery candidates, not verified coverage.','Missing credentials and review-needed sites remain uncovered.','Physical iPhone acceptance must be performed separately.']}
    if audit:
        # Refetch direct employer feeds independently of the stored/imported provider results.
        configs={c['id']:c for c in json.loads((ROOT/'discovery/sources.json').read_text()) if c['adapter'] in ('ashby','lever','smartrecruiters','greenhouse')}
        grouped=defaultdict(list)
        for j in active:
            for observation in j['sources']:
                if observation['source_id'] in configs:grouped[observation['source_id']].append(j);break
        selected=[]
        # Round-robin instead of auditing just the largest employer.
        while len(selected)<120 and any(grouped.values()):
            for key,values in grouped.items():
                if values and len(selected)<120:selected.append((key,values.pop(0)))
        known={};errors={}
        for key in {key for key,_ in selected}:
            cfg=configs[key];board=quote(cfg['board'],safe='');ids=set()
            try:
                if cfg['adapter']=='greenhouse':
                    payload=json_fetch(f'https://boards-api.greenhouse.io/v1/boards/{board}/jobs')
                    ids={str(j['id']) for j in payload['jobs']}
                elif cfg['adapter']=='ashby':
                    payload=json_fetch(f'https://api.ashbyhq.com/posting-api/job-board/{board}')
                    ids={str(j.get('id') or canonical(j['jobUrl'])) for j in payload['jobs'] if j.get('isListed',True)}
                elif cfg['adapter']=='lever':
                    offset=0
                    while True:
                        batch=json_fetch(f'https://api.lever.co/v0/postings/{board}?mode=json&limit=100&skip={offset}')
                        ids.update(str(j['id']) for j in batch)
                        if len(batch)<100:break
                        offset+=100
                else:
                    offset=0
                    while True:
                        batch=json_fetch(f'https://api.smartrecruiters.com/v1/companies/{board}/postings?country=us&limit=100&offset={offset}')
                        ids.update(str(j['id']) for j in batch['content']);offset+=len(batch['content'])
                        if offset>=batch['totalFound']:break
                        if not batch['content']:raise ValueError('Incomplete reference feed')
                known[key]=ids
                print('Reference verified:',key,len(ids),'active source IDs',flush=True)
            except Exception as exc:errors[key]=type(exc).__name__+': '+str(exc)[:160]
        def verified_job(key,j):
            return any(x['source_id']==key and x['source_job_id'] in known.get(key,set()) for x in j['sources'])
        verified=sum(verified_job(key,j) for key,j in selected)
        duplicates=len(selected)-len({canonical(j['url']) for _,j in selected})
        output['audit']={'status':'passed' if len(selected)>=120 and verified/len(selected)>=.95 and duplicates/len(selected)<=.02 else 'incomplete_or_failed',
            'sample_size':len(selected),'verified_active':verified,'active_fraction':verified/len(selected) if selected else 0,'duplicate_fraction':duplicates/len(selected) if selected else 0,'source_errors':errors,
            'reference_method':'Independent refetch of official employer feeds; not a market-wide recall measurement.',
            'sample':[{'id':j['id'],'url':j['url'],'source':key,'verified':verified_job(key,j)} for key,j in selected]}
    folder=ROOT/'artifacts';folder.mkdir(exist_ok=True)
    (folder/'discovery-coverage.json').write_text(json.dumps(output,indent=2)+'\n')
    print(json.dumps({k:output[k] for k in ('catalog_jobs','active_us_jobs','occupation_counts')},indent=2))
    for row in rows:print(f"{row['sector']}: {row['active_us_jobs']} active US jobs; {len(row['missing_or_incomplete_employers'])} sources incomplete")
    print('Audit:',output['audit']['status'],'— artifacts/discovery-coverage.json')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['report','audit','refresh','retry','disable','purge','configure']);parser.add_argument('source',nargs='?');args=parser.parse_args()
    if args.action in ('report','audit'):report(args.action=='audit')
    else:
        if not args.source:parser.error('A source ID is required.')
        print(call('discovery_manage',id=args.source,action=args.action))
