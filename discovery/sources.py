"""Provider adapters: bounded page I/O only; Jac owns scheduling and writes."""
from typing import Any
import json
import os
import re
from html.parser import HTMLParser
from urllib.parse import urlencode, quote, urljoin, urlsplit
from xml.etree import ElementTree
from discovery.transport import fetch, json_fetch, page_fetch, public_url
from discovery.normalize import normalize, plain, digest
from discovery.html_extract import extract
from discovery.render import render_page

US_REGIONS = set('Alabama Alaska Arizona Arkansas California Colorado Connecticut Delaware Florida Hawaii Idaho Illinois Indiana Iowa Kansas Kentucky Louisiana Maine Maryland Massachusetts Michigan Minnesota Mississippi Missouri Montana Nebraska Nevada Ohio Oklahoma Oregon Pennsylvania Tennessee Texas Utah Vermont Virginia Washington Wisconsin Wyoming'.lower().split())
US_CODES=set('AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC'.split())

def country(location,explicit=''):
    if str(explicit).upper() in ('US','USA','UNITED STATES','UNITED STATES OF AMERICA'):return 'US'
    if explicit:return str(explicit)
    if re.search(r'\b(united states|usa|u\.s\.)\b',location,re.I):return 'US'
    if any(x.strip() in US_CODES for x in re.split(r'[,;\s]',location)):return 'US'
    if any(re.search(r'\b'+x+r'\b',location,re.I) for x in US_REGIONS):return 'US'
    if re.search(r'\b(New York|San Francisco|Los Angeles|Boston|Chicago|Seattle|Austin|Detroit|Atlanta|San Diego|New Jersey|North Carolina|South Carolina|New Mexico|New Hampshire|Rhode Island|West Virginia|North Dakota|South Dakota)\b',location,re.I):return 'US'
    return 'Unknown'

def base(source, item):
    return {'company':source['name'],'employer_domain':source.get('domain',''),'source_job_id':str(item.get('id',''))}

def greenhouse(source, checkpoint):
    board=quote(source['board'],safe='');offset=checkpoint.get('offset',0);ids=checkpoint.get('ids');full=None
    if ids is None:
        try:
            payload=json_fetch(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs?content=true",body_limit=24*1024*1024)
            if not isinstance(payload.get('jobs'),list):raise ValueError('Greenhouse response shape changed.')
            full=payload['jobs']
        except ValueError as exc:
            if 'body limit' not in str(exc):raise
            payload=json_fetch(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs")
            if not isinstance(payload.get('jobs'),list):raise ValueError('Greenhouse response shape changed.')
            ids=[str(x['id']) for x in payload['jobs']]
    page=ids[offset:offset+10] if ids is not None else []
    items=full if full is not None else [json_fetch(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs/{item_id}") for item_id in page]
    jobs=[]
    for j in items:
        loc=(j.get('location') or {}).get('name','')
        jobs.append({**base(source,j),'title':j['title'],'url':j['absolute_url'],'location':loc,'country':country(loc),
          'description':j.get('content',''),'requisition':str(j.get('requisition_id') or j['id']),
          'mode':'Remote' if re.search(r'\bremote\b',loc,re.I) else 'Unknown'})
    done=full is not None or offset+len(page)>=len(ids)
    return jobs,{} if done else {'offset':offset+len(page),'ids':ids},done,[]

def ashby(source, checkpoint):
    payload=json_fetch(f"https://api.ashbyhq.com/posting-api/job-board/{quote(source['board'],safe='')}?includeCompensation=true")
    if not isinstance(payload.get('jobs'),list):raise ValueError('Ashby response shape changed.')
    jobs=[]
    for j in payload['jobs']:
        if not j.get('isListed',True):continue
        locs=[j.get('location','')]+[x.get('location','') for x in j.get('secondaryLocations',[])]
        address=(j.get('address') or {}).get('postalAddress') or {}
        comps=(j.get('compensation') or {}).get('summaryComponents') or []
        comp=next((x for x in comps if x.get('compensationType')=='Salary'),{})
        jobs.append({**base(source,j),'title':j['title'],'url':j['jobUrl'],'locations':locs,
          'country':country(' '.join(locs),address.get('addressCountry','')),'description':j.get('descriptionHtml') or j.get('descriptionPlain',''),
          'posted_at':j.get('publishedAt'),'employment_type':{'FullTime':'Full-time','PartTime':'Part-time'}.get(j.get('employmentType'),j.get('employmentType')),
          'mode':{'OnSite':'On-site'}.get(j.get('workplaceType'),j.get('workplaceType')) or ('Remote' if j.get('isRemote') else 'Unknown'),
          'compensation':{'min':comp.get('minValue'),'max':comp.get('maxValue'),'currency':comp.get('currencyCode'),'unit':str(comp.get('interval','unknown')).replace('1 ','').lower()}})
    return jobs,{},True,[]

def lever(source, checkpoint):
    offset=checkpoint.get('offset',0)
    payload=json_fetch(f"https://api.lever.co/v0/postings/{quote(source['board'],safe='')}?mode=json&limit=100&skip={offset}")
    if not isinstance(payload,list):raise ValueError('Lever response shape changed.')
    jobs=[]
    for j in payload:
        c=j.get('categories') or {};locs=c.get('allLocations') or [c.get('location','')];salary=j.get('salaryRange') or {}
        jobs.append({**base(source,j),'title':j['text'],'url':j['hostedUrl'],'locations':locs,'country':country(' '.join(locs),j.get('country','')),
          'description':j.get('descriptionPlain','')+'\n'+ '\n'.join(plain(x.get('content','')) for x in j.get('lists',[])),
          'posted_at':j.get('createdAt'),'employment_type':c.get('commitment'),
          'mode':{'remote':'Remote','hybrid':'Hybrid','on-site':'On-site'}.get(j.get('workplaceType'),'Unknown'),
          'compensation':{'min':salary.get('min'),'max':salary.get('max'),'currency':salary.get('currency'),'unit':salary.get('interval')}})
    return jobs,{'offset':offset+100} if len(payload)==100 else {},len(payload)<100,[]

def smartrecruiters(source, checkpoint):
    offset=checkpoint.get('offset',0)
    url=f"https://api.smartrecruiters.com/v1/companies/{quote(source['board'],safe='')}/postings"
    payload=json_fetch(url+'?'+urlencode({'offset':offset,'limit':10,'country':'us'}))
    if not isinstance(payload.get('content'),list) or 'totalFound' not in payload:raise ValueError('SmartRecruiters response shape changed.')
    jobs=[]
    # A small page keeps the entire lease bounded despite detail lookups.
    for item in payload['content']:
        j=json_fetch(url+'/'+quote(str(item['id']),safe=''))
        loc=j.get('location') or {};text='\n'.join(x.get('text','') for x in (j.get('jobAd',{}).get('sections') or {}).values())
        jobs.append({**base(source,j),'company':(j.get('company') or {}).get('name') or source['name'], 'title':j['name'],
          'url':j.get('applyUrl') or f"https://jobs.smartrecruiters.com/{source['board']}/{j['id']}",'location':', '.join(str(loc.get(k,'')) for k in ('city','region','country') if loc.get(k)),
          'country':country('',loc.get('country','')),'description':text,'posted_at':j.get('releasedDate'),'requisition':str(j.get('jobId') or j['id']),
          'employment_type':(j.get('typeOfEmployment') or {}).get('label'),'mode':'Remote' if loc.get('remote') else 'Unknown'})
    done=offset+len(payload['content'])>=payload['totalFound']
    if not payload['content'] and not done:raise ValueError('Incomplete SmartRecruiters page.')
    return jobs,{} if done else {'offset':offset+len(payload['content'])},done,[]

def adzuna(source, checkpoint):
    cfg=source.get('search',{});f=cfg.get('filters',{});page=checkpoint.get('page',1)
    args={'app_id':os.environ['ADZUNA_APP_ID'],'app_key':os.environ['ADZUNA_APP_KEY'],'results_per_page':50,'what':cfg.get('query',''),'where':f.get('location',''),'sort_by':'date'}
    if f.get('posted_days'):args['max_days_old']=f['posted_days']
    payload=json_fetch(f'https://api.adzuna.com/v1/api/jobs/us/search/{page}?'+urlencode(args))
    if not isinstance(payload.get('results'),list):raise ValueError('Adzuna response shape changed.')
    jobs=[]
    for j in payload['results']:
        estimated=str(j.get('salary_is_predicted','0'))=='1'
        # Do not display provider estimates without their additional required branding.
        salary={} if estimated else {'min':j.get('salary_min'),'max':j.get('salary_max'),'unit':'year','currency':'USD','estimated':False}
        jobs.append({'title':j['title'],'company':j.get('company',{}).get('display_name','Employer not listed'),'url':j['redirect_url'],'source_job_id':str(j['id']),
          'location':j.get('location',{}).get('display_name',''),'country':'US','description':j.get('description',''),'snippet':True,'posted_at':j.get('created'),
          'employment_type':{'full_time':'Full-time','part_time':'Part-time'}.get(j.get('contract_time'),j.get('contract_type')),
          'compensation':salary,'attribution':{'label':'Jobs by Adzuna','url':'https://www.adzuna.com','logo':'https://developer.adzuna.com/images/adzuna_logo.png'}})
    # Bounded query window; never used to infer closure.
    done=len(payload['results'])<50 or page>=3
    return jobs,{} if done else {'page':page+1},done,[]

def theirstack(source, checkpoint):
    cfg=source.get('search',{});f=cfg.get('filters',{})
    body={'page':0,'limit':source.get('allowance',25),'job_country_code_or':['US'],'posted_at_max_age_days':int(f.get('posted_days') or 30),'order_by':[{'field':'discovered_at','desc':True}]}
    if cfg.get('query'):body['job_title_pattern_or']=[re.escape(cfg['query'])]
    if checkpoint.get('after'):body['discovered_at_gte']=checkpoint['after']
    if source.get('excluded_ids'):body['job_id_not']=source['excluded_ids']
    if f.get('location') and f['location'].lower() not in ('us','united states'):body['job_location_pattern_or']=[re.escape(f['location'])]
    payload=json_fetch('https://api.theirstack.com/v1/jobs/search',headers={'Authorization':'Bearer '+os.environ['THEIRSTACK_API_KEY']},body=body)
    if not isinstance(payload.get('data'),list):raise ValueError('TheirStack response shape changed.')
    jobs=[]
    for j in payload['data']:
        c=j.get('company_object') or {}
        jobs.append({'title':j['job_title'],'company':j.get('company') or c.get('name',''),'employer_domain':c.get('domain') or '',
          'source_job_id':str(j['id']),'url':j.get('final_url') or j['url'],'description':j.get('description',''),'location':j.get('location',''),
          'country':'US','posted_at':j.get('date_posted'),'mode':'Remote' if j.get('remote') else ('Hybrid' if j.get('hybrid') else 'Unknown'),
          'compensation':{'min':j.get('min_annual_salary'),'max':j.get('max_annual_salary'),'currency':j.get('salary_currency'),'unit':'year'},
          'employment_type':j.get('employment_status'),'seniority':j.get('seniority')})
    return jobs,{},True,[]

def usajobs(source, checkpoint):
    cfg=source.get('search',{});f=cfg.get('filters',{});page=checkpoint.get('page',1)
    params={'Keyword':cfg.get('query',''),'LocationName':f.get('location',''),'ResultsPerPage':50,'Page':page}
    payload=json_fetch('https://data.usajobs.gov/api/search?'+urlencode(params),headers={'Authorization-Key':os.environ['USAJOBS_API_KEY'],'User-Agent':os.environ['USAJOBS_EMAIL'],'Host':'data.usajobs.gov'})
    result=payload.get('SearchResult',{});items=result.get('SearchResultItems')
    if not isinstance(items,list):raise ValueError('USAJOBS response shape changed.')
    jobs=[]
    for item in items:
        j=item['MatchedObjectDescriptor'];details=(j.get('UserArea') or {}).get('Details') or {};pay=(j.get('PositionRemuneration') or [{}])[0]
        jobs.append({'title':j['PositionTitle'],'company':j['OrganizationName'],'url':j['PositionURI'],'requisition':j.get('PositionID',''),'employer_domain':'usajobs.gov',
          'source_job_id':item.get('MatchedObjectId'),'locations':[x['LocationName'] for x in j.get('PositionLocation',[])],'country':'US',
          'description':details.get('JobSummary',''),'qualifications':j.get('QualificationSummary',''),'eligibility':details.get('WhoMayApply',{}).get('Name','')+'\n'+str(details.get('KeyRequirements','')),
          'posted_at':j.get('PublicationStartDate'),'expires_at':j.get('ApplicationCloseDate'),'employment_type':(j.get('PositionSchedule') or [{}])[0].get('Name'),
          'mode':'Remote' if details.get('RemoteIndicator') else 'Unknown',
          'compensation':{'min':float(pay['MinimumRange']) if pay.get('MinimumRange') else None,'max':float(pay['MaximumRange']) if pay.get('MaximumRange') else None,'unit':pay.get('RateIntervalCode'),'currency':'USD'}})
    done=len(items)<50 or page>=3
    return jobs,{} if done else {'page':page+1},done,[]

class Page(HTMLParser):
    def __init__(self):super().__init__();self.links=[];self.scripts=[];self.recording=False;self.buf=[]
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if tag=='a' and a.get('href'):self.links.append(a['href'])
        if tag=='script' and a.get('type','').lower()=='application/ld+json':self.recording=True;self.buf=[]
    def handle_data(self,data):
        if self.recording:self.buf.append(data)
    def handle_endtag(self,tag):
        if tag=='script' and self.recording:
            self.scripts.append(''.join(self.buf));self.recording=False

def posting_objects(obj):
    if isinstance(obj,list):
        for x in obj:yield from posting_objects(x)
    elif isinstance(obj,dict):
        types=obj.get('@type',[]);types=[types] if isinstance(types,str) else types
        if 'JobPosting' in types:yield obj
        for k in ('@graph','mainEntity','itemListElement','item'):
            if k in obj:yield from posting_objects(obj[k])

def schema_job(j,url,source):
    org=j.get('hiringOrganization') or {};org={'name':org} if isinstance(org,str) else org
    places=j.get('jobLocation') or [];places=[places] if isinstance(places,dict) else places
    locations=[];codes=[]
    for place in places:
        a=place.get('address') or {};a={'streetAddress':a} if isinstance(a,str) else a
        c=a.get('addressCountry','');c=c.get('name','') if isinstance(c,dict) else c
        codes.append(country('',c));locations.append(', '.join(str(a.get(k,'')) for k in ('addressLocality','addressRegion') if a.get(k))+(', '+str(c) if c else ''))
    eligibility=j.get('applicantLocationRequirements') or [];eligibility=[eligibility] if isinstance(eligibility,dict) else eligibility
    remote_area=', '.join(x.get('name','') if isinstance(x,dict) else str(x) for x in eligibility)
    if not codes:codes=[country(remote_area)]
    pay=j.get('baseSalary') or {};pay=pay[0] if isinstance(pay,list) and pay else pay
    pay=pay if isinstance(pay,dict) else {};val=pay.get('value') or {};val=val if isinstance(val,dict) else {'value':val}
    ident=j.get('identifier') or {};ident=ident.get('value','') if isinstance(ident,dict) else str(ident)
    domain=urlsplit(org.get('sameAs') or source.get('domain','')).hostname or source.get('domain','')
    employment=j.get('employmentType');employment=employment[0] if isinstance(employment,list) and employment else employment
    return {'title':j.get('title',''),'company':org.get('name') or source['name'],'employer_domain':domain,'requisition':ident,
      'url':urljoin(url,j.get('url') or url),'locations':locations,'country':'US' if 'US' in codes else codes[0],
      'description':j.get('description',''),'posted_at':j.get('datePosted'),'expires_at':j.get('validThrough'),
      'mode':'Remote' if j.get('jobLocationType')=='TELECOMMUTE' else 'Unknown','remote_eligibility':remote_area,
      'qualifications':j.get('qualifications',''),'employment_type':employment,
      'compensation':{'min':val.get('minValue') or val.get('value'),'max':val.get('maxValue'),'unit':val.get('unitText'),'currency':pay.get('currency')}}

def identify(url,name='',sector='Uncategorized') -> dict[str, Any]:
    p=public_url(url);parts=p.path.strip('/').split('/');host=p.hostname.lower()
    adapter='';board=''
    if host in ('boards.greenhouse.io','job-boards.greenhouse.io') and parts:adapter='greenhouse';board=parts[0]
    elif host=='jobs.ashbyhq.com' and parts:adapter='ashby';board=parts[0]
    elif host=='jobs.lever.co' and parts:adapter='lever';board=parts[0]
    elif host in ('careers.smartrecruiters.com','jobs.smartrecruiters.com') and parts:adapter='smartrecruiters';board=parts[0]
    if adapter:return {'id':adapter+':'+board,'adapter':adapter,'board':board,'name':name or board,'sector':sector,'domain':'','approved':True,'url':url}
    return {'id':'career:'+digest(url),'adapter':'career','name':name or host,'url':url,'domain':host,'sector':sector,'approved':False}

def career(source,checkpoint):
    url=checkpoint.get('url') or source['url']; response=render_page(url,source.get('browser_hosts',[])) if source.get('renderer')=='playwright' else page_fetch(url);p=Page();p.feed(response['text']);jobs=[]
    for script in p.scripts:
        try:objects=list(posting_objects(json.loads(script)))
        except ValueError:continue
        for j in objects:jobs.append(schema_job(j,response['url'],source))
    if not jobs:jobs=extract(response["text"],source,response["url"])
    candidates=[]
    for link in p.links:
        target=urljoin(response['url'],link)
        try:
            found=identify(target,source['name'],source.get('sector','Uncategorized'))
            same=urlsplit(target).hostname==urlsplit(response['url']).hostname
            if found['adapter']!='career':candidates.append(found)
            elif same and re.search(r'/(jobs?|careers?|positions?|opportunities)(/|\?|$)',urlsplit(target).path,re.I):candidates.append(found)
        except ValueError:pass
    if response['text'].lstrip().startswith(('<?xml','<urlset','<sitemapindex')):
        tree=ElementTree.fromstring(response['text'])
        for tag in tree.iter():
            if tag.tag.endswith('loc') and tag.text and urlsplit(tag.text).hostname==urlsplit(url).hostname:
                candidates.append(identify(tag.text,source['name'],source.get('sector','Uncategorized')))
    # Same-host pages inherit an explicitly approved employer crawl policy, not arbitrary external domains.
    for c in candidates:
        if c['adapter']=='career' and c['domain']==source.get('domain') and source.get('approved'):
            c['approved']=True;c['depth']=source.get('depth',0)+1
    candidates=[x for x in candidates if x.get('depth',0)<=3][:100]
    return jobs,{},True,candidates

def github(source,checkpoint):
    headers={'Accept':'application/vnd.github.raw+json'}
    if os.getenv('GITHUB_TOKEN'):headers['Authorization']='Bearer '+os.environ['GITHUB_TOKEN']
    if checkpoint.get('etag'):headers['If-None-Match']=checkpoint['etag']
    result=fetch(f"https://api.github.com/repos/{source['repo']}/contents/{source.get('path','README.md')}",headers=headers)
    if result['status']==304:return [],checkpoint,True,[]
    # Link discovery only; repository prose is never copied into listings.
    links=re.findall(r'https?://[^\s<>"\)\]]+',result['text']);candidates=[]
    for url in dict.fromkeys(links):
        if urlsplit(url).hostname in ('github.com','www.linkedin.com','linkedin.com','indeed.com','www.indeed.com'):continue
        try:candidates.append(identify(url,sector=source.get('sector','Technology')))
        except ValueError:pass
    return [],{'etag':result['headers'].get('etag','')},True,candidates[:100]

def github_search(source,checkpoint):
    from datetime import datetime,timedelta,timezone
    terms=['jobs','nursing jobs','education jobs','finance jobs','government jobs','legal jobs','retail jobs','hospitality jobs','manufacturing jobs','construction jobs','logistics jobs','nonprofit jobs']
    index=checkpoint.get('index',0);since=(datetime.now(timezone.utc)-timedelta(days=90)).strftime('%Y-%m-%d')
    headers={'Accept':'application/vnd.github+json'}
    if os.getenv('GITHUB_TOKEN'):headers['Authorization']='Bearer '+os.environ['GITHUB_TOKEN']
    data=json_fetch('https://api.github.com/search/repositories?'+urlencode({'q':terms[index]+' pushed:>='+since+' archived:false stars:>=5','per_page':20,'sort':'updated'}),headers=headers)
    if not isinstance(data.get('items'),list):raise ValueError('GitHub search response shape changed.')
    candidates=[{'id':'github:'+x['full_name'],'name':x['full_name'],'adapter':'github','repo':x['full_name'],'sector':'Uncategorized','approved':False,'policy':'Review relevance, maintenance, and link format before enabling.'} for x in data['items']]
    done=index==len(terms)-1
    return [],{} if done else {'index':index+1},done,candidates

ADAPTERS={'greenhouse':greenhouse,'ashby':ashby,'lever':lever,'smartrecruiters':smartrecruiters,'adzuna':adzuna,'theirstack':theirstack,'usajobs':usajobs,'career':career,'github':github,'github_search':github_search}

def collect(source,checkpoint) -> dict[str, Any]:
    raw,after,complete,candidates=ADAPTERS[source['adapter']](source,checkpoint)
    jobs=[];invalid=0
    for item in raw:
        try:jobs.append(normalize(item,source))
        except (ValueError,TypeError,KeyError):invalid+=1
    return {'jobs':jobs,'checkpoint':after,'complete':complete,'candidates':candidates,'invalid':invalid,'received':len(raw)}
