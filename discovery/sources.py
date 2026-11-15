"""Public job-board adapters: bounded page I/O only; Jac owns writes."""
from typing import Any
import json
import os
import re
from html.parser import HTMLParser
from urllib.parse import urlencode, quote, urljoin, urlsplit
from xml.etree import ElementTree
from discovery.transport import fetch, json_fetch, page_fetch, public_url
from discovery.normalize import normalize, plain, digest
from discovery.card import pay_excerpt
from discovery.html_extract import Extractor, extract
from discovery.matching import STATES

US_CODES=set('AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC'.split())

def country(location,explicit=''):
    if str(explicit).upper() in ('US','USA','UNITED STATES','UNITED STATES OF AMERICA'):return 'US'
    if explicit:return str(explicit)
    if re.search(r'\b(?:united states|usa|us)\b|\bU\.S\.(?!\w)',location,re.I):return 'US'
    if any(x.strip() in US_CODES for x in re.split(r'[,;\s]',location)):return 'US'
    if any(re.search(r'\b'+x+r'\b',location,re.I) for x in STATES):return 'US'
    if re.search(r'\b(New York|San Francisco|Los Angeles|Boston|Chicago|Seattle|Austin|Detroit|Atlanta|San Diego|New Jersey|North Carolina|South Carolina|New Mexico|New Hampshire|Rhode Island|West Virginia|North Dakota|South Dakota)\b',location,re.I):return 'US'
    return 'Unknown'

def base(source, item):
    return {'company':source['name'],'employer_domain':source.get('domain',''),'source_job_id':str(item.get('id',''))}

def greenhouse_pay(j):
    # A single unqualified base range can populate numeric filters. Region- or
    # tier-specific ranges remain in Greenhouse's formatted posting content.
    ranges = j.get('pay_input_ranges') or []
    if len(ranges) != 1:
        return {}
    band = ranges[0]
    title = (band.get('title') or '').strip(' :')
    if not re.fullmatch(r'(?:(?:annual|yearly|hourly) )?(?:base )?(?:salary|pay)(?: range)?', title, re.I):
        return {}
    def amount(key):
        cents = band.get(key)
        return cents / 100 if type(cents) is int and cents >= 0 else None
    unit = 'year' if title.lower().startswith(('annual ', 'yearly ')) else 'hour' if title.lower().startswith('hourly ') else None
    return {'min': amount('min_cents'), 'max': amount('max_cents'), 'currency': band.get('currency_type'), 'unit': unit}


def greenhouse(source, checkpoint):
    board=quote(source['board'],safe='');offset=checkpoint.get('offset',0);ids=checkpoint.get('ids');full=None
    schema_host = source.get('posting_schema_host')
    if ids is None:
        if not schema_host:
            try:
                payload=json_fetch(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs?content=true&pay_transparency=true",body_limit=24*1024*1024)
                if not isinstance(payload.get('jobs'),list):raise ValueError('Greenhouse response shape changed.')
                full=payload['jobs']
            except ValueError as exc:
                if 'body limit' not in str(exc):raise
        if full is None:
            # Enriched boards use the same bounded batches as oversized boards.
            payload=json_fetch(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs")
            if not isinstance(payload.get('jobs'),list):raise ValueError('Greenhouse response shape changed.')
            ids=[str(x['id']) for x in payload['jobs']]
    page=ids[offset:offset+10] if ids is not None else []
    items=full if full is not None else [json_fetch(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs/{item_id}?pay_transparency=true") for item_id in page]
    jobs=[]
    for j in items:
        loc=(j.get('location') or {}).get('name','')
        metadata = {m.get('name'): m.get('value') for m in j.get('metadata') or []}
        locations = [loc]
        for field in ('Job Posting Location', 'Careers Page: Location'):
            values = metadata.get(field)
            if isinstance(values, list):
                locations.extend(v for v in values if isinstance(v, str) and v)
        kind = metadata.get('Employment Type') or metadata.get('Time Type')
        arrangements = set(re.findall(r'\b(remote|hybrid|on-site)\b', loc.lower()))
        mode = 'Unknown'
        if len(arrangements) == 1 and not re.search(r'\b(?:not|no|non|except|excluding)\b', loc, re.I):
            mode = arrangements.pop().capitalize()
        job = {**base(source,j),'company':j.get('company_name') or source['name'],'title':j['title'],'url':j['absolute_url'],
          'locations':list(dict.fromkeys(locations)),'country':country(', '.join(locations)),
          'posted_at':j.get('first_published'),'employment_type':kind if isinstance(kind,str) else None,'compensation':greenhouse_pay(j),
          'description':j.get('content',''),'requisition':str(j.get('requisition_id') or j['id']),
          'mode':mode}
        if schema_host and urlsplit(job['url']).hostname == schema_host:
            employer_details(job, source, schema_host)
        jobs.append(job)
    done=full is not None or offset+len(page)>=len(ids)
    return jobs,{} if done else {'offset':offset+len(page),'ids':ids},done,[]

def ashby_country(place):
    address = place.get('address') or {}
    address = address.get('postalAddress') or address
    return country(place.get('location') or '', address.get('addressCountry') or '')


def ashby(source, checkpoint):
    payload=json_fetch(f"https://api.ashbyhq.com/posting-api/job-board/{quote(source['board'],safe='')}?includeCompensation=true")
    if not isinstance(payload.get('jobs'),list):raise ValueError('Ashby response shape changed.')
    jobs=[]
    for j in payload['jobs']:
        if not j.get('isListed',True):continue
        locs=[j.get('location','')]+[x.get('location','') for x in j.get('secondaryLocations',[])]
        countries = [ashby_country(place) for place in [j, *(j.get('secondaryLocations') or [])]]
        pay=j.get('compensation') or {};comps=pay.get('summaryComponents') or []
        comp=next((x for x in comps if x.get('compensationType')=='Salary'),{})
        jobs.append({**base(source,j),'title':j['title'],'url':j['jobUrl'],'locations':locs,
          'country':'US' if 'US' in countries else countries[0],'description':j.get('descriptionHtml') or j.get('descriptionPlain',''),
          'pay_text':pay.get('compensationTierSummary'),'posted_at':j.get('publishedAt'),'employment_type':{'FullTime':'Full-time','PartTime':'Part-time'}.get(j.get('employmentType'),j.get('employmentType')),
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
          'description':'\n'.join(filter(None,[j.get('descriptionPlain') or j.get('description'),
              *(f"{x.get('text') or ''}\n{x.get('content') or ''}" for x in j.get('lists',[])),
              j.get('salaryDescriptionPlain') or j.get('salaryDescription'), j.get('additionalPlain') or j.get('additional')])),
          'pay_text':j.get('salaryDescriptionPlain') or j.get('salaryDescription'),'posted_at':j.get('createdAt'),'employment_type':c.get('commitment'),
          'mode':{'remote':'Remote','hybrid':'Hybrid','on-site':'On-site'}.get(j.get('workplaceType'),'Unknown'),
          'compensation':{'min':salary.get('min'),'max':salary.get('max'),'currency':salary.get('currency'),'unit':salary.get('interval')}})
    return jobs,{'offset':offset+100} if len(payload)==100 else {},len(payload)<100,[]

def smartrecruiters_manifest(source, checkpoint, url):
    """Freeze a bounded public ID manifest before any detail batches are written."""
    offset=checkpoint.get('listing_offset',0);ids=checkpoint.get('ids',[])
    if type(offset) is not int or offset<0 or not isinstance(ids,list):
        raise ValueError('Invalid SmartRecruiters manifest checkpoint; refresh source.')
    payload=json_fetch(url+'?'+urlencode({'offset':offset,'limit':100,'country':'us'}))
    if not isinstance(payload,dict) or not isinstance(payload.get('content'),list):
        raise ValueError('SmartRecruiters response shape changed.')
    total=payload.get('totalFound');items=payload['content']
    if type(total) is not int or not 0<=total<=1000 or len(items)>100:
        raise ValueError('SmartRecruiters manifest exceeds the 1,000-posting budget or is malformed.')
    if checkpoint.get('total',total)!=total or (not items and offset<total):
        raise ValueError('SmartRecruiters manifest changed or is incomplete; refresh source.')
    page_ids=[str(x['id']) for x in items if isinstance(x,dict) and x.get('id')]
    if len(page_ids)!=len(items) or len(set(ids+page_ids))!=len(ids)+len(page_ids):
        raise ValueError('SmartRecruiters manifest has missing or repeated IDs; refresh source.')
    ids=ids+page_ids;after=offset+len(items)
    if after>total or len(ids)!=after:
        raise ValueError('SmartRecruiters manifest count changed; refresh source.')
    if after==total:
        return [],({'ids':ids,'detail_offset':0} if ids else {}),not ids,[]
    return [],{'ids':ids,'listing_offset':after,'total':total},False,[]

def smartrecruiters_expiry(source, j):
    # This exact employer field states a calendar deadline, inclusive in local time.
    field=source.get('close_date_field')
    if not field:return None
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo
    values=[x.get('valueLabel') for x in j.get('customField',[]) if x.get('fieldLabel')==field]
    if len(values)!=1 or not values[0]:return None
    for fmt in ('%m/%d/%y','%m/%d/%Y','%Y-%m-%d'):
        try:
            day=datetime.strptime(values[0],fmt)
            return (day+timedelta(days=1)).replace(tzinfo=ZoneInfo(source['deadline_timezone'])).timestamp()
        except ValueError:pass
    return None

def smartrecruiters(source, checkpoint):
    offset=checkpoint.get('offset',0)
    url=f"https://api.smartrecruiters.com/v1/companies/{quote(source['board'],safe='')}/postings"
    snapshot=source.get('snapshot',False)
    if snapshot:
        if 'detail_offset' not in checkpoint:
            if checkpoint.get('offset'):raise ValueError('Refresh source to start a SmartRecruiters manifest.')
            return smartrecruiters_manifest(source,checkpoint,url)
        ids=checkpoint.get('ids');offset=checkpoint['detail_offset']
        if not isinstance(ids,list) or len(ids)>1000 or type(offset) is not int or not 0<=offset<len(ids):
            raise ValueError('Invalid SmartRecruiters detail checkpoint; refresh source.')
        payload={'content':[{'id':x} for x in ids[offset:offset+10]],'totalFound':len(ids)}
    else:payload=json_fetch(url+'?'+urlencode({'offset':offset,'limit':10,'country':'us'}))
    if not isinstance(payload,dict) or not isinstance(payload.get('content'),list) or type(payload.get('totalFound')) is not int or len(payload['content'])>10:raise ValueError('SmartRecruiters response shape changed.')
    jobs=[]
    # A small page keeps the entire lease bounded despite detail lookups.
    for item in payload['content']:
        try:j=json_fetch(url+'/'+quote(str(item['id']),safe=''))
        except ValueError as exc:
            # A public posting withdrawn after enumeration is absent, not a failed page.
            if snapshot and str(exc)=='Source returned HTTP 404.':continue
            raise
        if not isinstance(j,dict) or str(j.get('id'))!=str(item['id']):raise ValueError('SmartRecruiters detail identity changed.')
        if j.get('active') is False or j.get('visibility','PUBLIC')!='PUBLIC':continue
        loc=j.get('location') or {};sections=(j.get('jobAd') or {}).get('sections') or {}
        text='\n'.join('\n'.join(filter(None,[part.get('title'),part['text']])) for part in sections.values() if part.get('text'))
        if not text.strip() or not j.get('name'):raise ValueError('SmartRecruiters listing lacks required text.')
        pay=j.get('compensation') or {}
        jobs.append({**base(source,j),'company':(j.get('company') or {}).get('name') or source['name'], 'title':j['name'],
          'url':j.get('applyUrl') or f"https://jobs.smartrecruiters.com/{source['board']}/{j['id']}",'location':', '.join(str(loc.get(k,'')) for k in ('city','region','country') if loc.get(k)),
          'country':country('',loc.get('country','')),'description':text,'posted_at':j.get('releasedDate'),'requisition':str(j.get('jobId') or j['id']),
          'qualifications':(sections.get('qualifications') or {}).get('text',''),'expires_at':smartrecruiters_expiry(source,j),
          'employment_type':(j.get('typeOfEmployment') or {}).get('label'),'seniority':(j.get('experienceLevel') or {}).get('label'),
          'mode':'Hybrid' if loc.get('hybrid') else ('Remote' if loc.get('remote') else 'Unknown'),
          'compensation':{'min':pay.get('min'),'max':pay.get('max'),'currency':pay.get('currency'),'unit':{'YEARLY':'year','MONTHLY':'month','HOURLY':'hour'}.get(pay.get('period'),'unknown')}})
    done=offset+len(payload['content'])>=payload['totalFound']
    if not payload['content'] and not done:raise ValueError('Incomplete SmartRecruiters page.')
    after=({'ids':ids,'detail_offset':offset+len(payload['content'])} if snapshot else {'offset':offset+len(payload['content'])}) if not done else {}
    return jobs,after,done,[]

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

def schema_text(value):
    if isinstance(value, list):
        return '\n'.join(filter(None, (schema_text(x) for x in value)))
    return value if isinstance(value, str) else ''


def schema_job(j,url,source):
    org=j.get('hiringOrganization') or {};org={'name':org} if isinstance(org,str) else org
    places=j.get('jobLocation') or [];places=[places] if isinstance(places,dict) else places
    locations=[];codes=[]
    for place in places:
        a=place.get('address') or {};a={'streetAddress':a} if isinstance(a,str) else a
        c=a.get('addressCountry','');c=c.get('name','') if isinstance(c,dict) else c
        codes.append(country('',c));locations.append(', '.join(str(part) for part in (a.get('addressLocality'),a.get('addressRegion'),c) if part) or a.get('streetAddress',''))
    eligibility=j.get('applicantLocationRequirements') or [];eligibility=eligibility if isinstance(eligibility,list) else [eligibility]
    remote_area=', '.join(x.get('name','') if isinstance(x,dict) else str(x) for x in eligibility)
    if not codes:codes=[country(remote_area)]
    pay=j.get('baseSalary')
    if isinstance(pay,list):
        pay=pay[0] if len(pay)==1 else None
    pay=pay if isinstance(pay,dict) else {'value':pay}
    val=pay.get('value')
    val=val if isinstance(val,dict) else {'value':val}
    ident=j.get('identifier') or {};ident=ident.get('value','') if isinstance(ident,dict) else str(ident)
    domain=urlsplit(org.get('sameAs') or source.get('domain','')).hostname or source.get('domain','')
    employment=j.get('employmentType');employment=' / '.join(x for x in employment if isinstance(x,str)) if isinstance(employment,list) else employment
    return {'title':j.get('title',''),'company':org.get('name') or source['name'],'employer_domain':domain,'requisition':ident,
      'url':urljoin(url,j.get('url') or url),'locations':locations,'country':'US' if 'US' in codes else codes[0],
      'description':j.get('description',''),'responsibilities':schema_text(j.get('responsibilities')),'posted_at':j.get('datePosted'),'expires_at':j.get('validThrough'),
      'mode':'Remote' if j.get('jobLocationType')=='TELECOMMUTE' else 'Unknown','remote_eligibility':remote_area,
      'qualifications':schema_text([j.get(k) for k in ('qualifications','experienceRequirements','educationRequirements','skills')]),'employment_type':employment,
      'compensation':{'min':val.get('minValue',val.get('value')),'max':val.get('maxValue',val.get('value')),'unit':val.get('unitText'),'currency':pay.get('currency') or j.get('salaryCurrency')}}

def identify(url,name='',sector='Uncategorized') -> dict[str, Any]:
    p=public_url(url);parts=p.path.strip('/').split('/');host=p.hostname.lower()
    adapter='';board=''
    if host in ('boards.greenhouse.io','job-boards.greenhouse.io') and parts:adapter='greenhouse';board=parts[0]
    elif host=='jobs.ashbyhq.com' and parts:adapter='ashby';board=parts[0]
    elif host=='jobs.lever.co' and parts:adapter='lever';board=parts[0]
    elif host in ('careers.smartrecruiters.com','jobs.smartrecruiters.com') and parts:adapter='smartrecruiters';board=parts[0]
    if adapter:return {'id':adapter+':'+board,'adapter':adapter,'board':board,'name':name or board,'sector':sector,'domain':'','approved':True,'url':url}
    return {'id':'career:'+digest(url),'adapter':'career','name':name or host,'url':url,'domain':host,'sector':sector,'approved':False}

def page_postings(page):
    for script in page.scripts:
        try:
            data = json.loads(script)
        except ValueError:
            continue
        yield from posting_objects(data)


def employer_details(job, source, host):
    try:
        response = page_fetch(job['url'], allowed_hosts={host})
    except (ValueError, OSError):
        # A missing, blocked or timed-out supplement must not stop the ATS sweep.
        job['attribution'] = {'employer_details_status': 'unavailable'}
        return
    page = Page()
    page.feed(response['text'])
    matches = [schema_job(item, response['url'], source) for item in page_postings(page)
               if plain(item.get('title')) == plain(job['title'])]
    matches = [item for item in matches if str(item['requisition']) == job['source_job_id']]
    if len(matches) != 1:
        return
    detail = matches[0]
    # Use the employer page for display fields only. Board identities, URLs,
    # lifecycle and publication timestamps continue to come from the board.
    for key in ('description', 'qualifications', 'responsibilities', 'employment_type', 'remote_eligibility'):
        if detail.get(key):
            job[key] = detail[key]
    if any(detail['locations']):
        job['locations'] = list(dict.fromkeys(filter(None, detail['locations'])))
    if detail['country'] != 'Unknown':
        job['country'] = detail['country']
    if detail['mode'] != 'Unknown':
        job['mode'] = detail['mode']
    if any(isinstance(detail['compensation'].get(key), (int, float)) for key in ('min', 'max')):
        job['compensation'] = detail['compensation']
    selector = source.get('posting_body_selector')
    if selector:
        body = Extractor({'body': selector})
        body.feed(response['text'])
        job['pay_text'] = pay_excerpt((body.result.get('body') or '').splitlines())
    job['attribution'] = {'employer_posting': response['url']}


def career(source,checkpoint):
    url=checkpoint.get('url') or source['url']; response=page_fetch(url);p=Page();p.feed(response['text']);jobs=[]
    jobs=[schema_job(j,response['url'],source) for j in page_postings(p)]
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

ADAPTERS={'greenhouse':greenhouse,'ashby':ashby,'lever':lever,'smartrecruiters':smartrecruiters,'career':career,'github':github,'github_search':github_search}

def collect(source,checkpoint) -> dict[str, Any]:
    raw,after,complete,candidates=ADAPTERS[source['adapter']](source,checkpoint)
    jobs=[];invalid=0
    for item in raw:
        try:jobs.append(normalize(item,source))
        except (ValueError,TypeError,KeyError):invalid+=1
    return {'jobs':jobs,'checkpoint':after,'complete':complete,'candidates':candidates,'invalid':invalid,'received':len(raw)}
