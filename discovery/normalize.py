"""Pure normalization utilities; persistence and orchestration are Jac."""
from typing import Any
import hashlib
import html
import json
import re
import time
import math
from datetime import datetime, timezone
from html.parser import HTMLParser
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
from pathlib import Path

class Text(HTMLParser):
    def __init__(self): super().__init__(); self.parts=[]; self.hidden=0
    def handle_starttag(self,tag,attrs):
        if tag in ('script','style'): self.hidden+=1
        if tag in ('p','li','br','div'): self.parts.append('\n')
    def handle_endtag(self,tag):
        if tag in ('script','style'): self.hidden=max(0,self.hidden-1)
    def handle_data(self,data):
        if not self.hidden:self.parts.append(data)

def plain(value):
    if not value:return ''
    p=Text();p.feed(html.unescape(str(value)));return re.sub(r'\n\s*\n+', '\n\n', html.unescape(''.join(p.parts))).strip()[:50000]

def canonical(url) -> str:
    p=urlsplit(str(url)); query=[(k,v) for k,v in parse_qsl(p.query) if not k.lower().startswith('utm_') and k.lower() not in ('source','ref','gh_src')]
    return urlunsplit((p.scheme.lower(),p.netloc.lower(),p.path.rstrip('/'),urlencode(sorted(query)),''))

def digest(value) -> str:return hashlib.sha256(str(value).encode()).hexdigest()[:32]

def stamp(value):
    try:
        if isinstance(value,(int,float)):return float(value)/1000 if float(value)>1e11 else float(value)
        dt=datetime.fromisoformat(str(value).replace('Z','+00:00')) if value else None
        return (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).timestamp() if dt else 0.0
    except (ValueError,TypeError):return 0.0

from functools import lru_cache
import csv

@lru_cache(maxsize=1)
def taxonomy() -> list[dict[str, Any]]:return json.loads(Path('discovery/occupations.json').read_text())

@lru_cache(maxsize=1)
def title_index():
    index={};codes={}
    for filename,field in [('onet-occupation_data.csv','Title'),('onet-job_titles.csv','Job Title'),('onet-sample_of_reported_titles.csv','Reported Job Title')]:
        with Path('discovery',filename).open() as stream:
            for row in csv.DictReader(stream):
                code=row['O*NET-SOC Code'];title=row[field].lower()
                index[title]=code;codes.setdefault(code,set()).add(title)
                short=row.get('Short Title','').lower()
                if short:index[short]=code;codes[code].add(short)
                for acronym in re.findall(r'\(([A-Z]{2,6})\)',row[field]):
                    index[acronym.lower()]=code;codes[code].add(acronym.lower())
    return index,codes

@lru_cache(maxsize=8192)
def occupation_code(title):
    index,_=title_index();words=re.findall(r"[a-z0-9]+",title.lower())
    for size in range(min(8,len(words)),0,-1):
        for i in range(len(words)-size+1):
            phrase=' '.join(words[i:i+size])
            found=index.get(phrase)
            specific={'nurse','rn','cna','emt','electrician','plumber','carpenter','teacher','physician','pharmacist','dentist','welder','machinist','chef','cook','cashier','accountant','attorney','paralegal','receptionist','janitor','mechanic','librarian','radiologist','veterinarian'}
            if found and (size>=2 or len(words)==1 or phrase in specific):return found
    return ''

def classify(title):
    code=occupation_code(title)[:2]
    return next((f['name'] for f in taxonomy() if f['code']==code),'Uncategorized')

def normalize(raw, source):
    title=plain(raw.get('title'));company=plain(raw.get('company'))
    url=str(raw.get('url',''))
    if not title or not company or not url.startswith(('https://','http://')):raise ValueError('Listing lacks title, employer, or public application URL.')
    locations=raw.get('locations') or ([raw['location']] if raw.get('location') else [])
    locations=[plain(x) for x in locations if x]
    mode=raw.get('mode') or 'Unknown'
    if mode not in ('Remote','Hybrid','On-site'):mode='Unknown'
    kind=str(raw.get('employment_type') or 'Unknown').replace('_',' ').title()
    # Providers spell these many ways ("Full-Time", "FULL_TIME", "full time").
    kind={'fulltime':'Full-time','parttime':'Part-time','contractor':'Contract','contract':'Contract','intern':'Internship','internship':'Internship','temporary':'Temporary'}.get(re.sub(r'[\s_-]+','',kind.lower()),kind)
    seniority=raw.get('seniority') or 'Unknown'
    if seniority=='Unknown':
        from discovery.matching import _level_facts
        seniority=_level_facts({'title':title,'employment_type':kind})['level'] or 'Unknown'
    salary=raw.get('compensation') or {}; low=salary.get('min');high=salary.get('max');unit=str(salary.get('unit') or 'unknown').lower()
    unit={'yearly':'year','annual':'year','annually':'year','hourly':'hour','per year':'year','per hour':'hour','per month':'month','per annum':'year','pa':'year','ph':'hour'}.get(unit,unit)
    salary={**salary,'min':low,'max':high,'unit':unit,'currency':salary.get('currency') or 'Unknown','estimated':bool(salary.get('estimated'))}
    amounts='–'.join(str(int(x)) if float(x).is_integer() else str(x) for x in (low,high) if isinstance(x,(int,float)))
    salary_label=f"{salary['currency']} {amounts} / {unit}" if amounts else 'Pay not listed'
    now=time.time();posted_at=stamp(raw.get('posted_at'));expires_at=stamp(raw.get('expires_at'))
    employer_domain=(raw.get('employer_domain') or '').lower()
    requisition=str(raw.get('requisition') or '')
    # Requisition IDs are only comparable within a known employer domain.
    usable_requisition=bool(re.search(r'[0-9]',requisition)) and not re.search(r'(?i)see |opening id|tbd|pending|unknown',requisition)
    identity=employer_domain+'|'+requisition if employer_domain and usable_requisition else canonical(url)
    return {'id':'job_'+digest(identity),'identity':identity,'title':title,'company':company,'url':url,'canonical_url':canonical(url),
      'requisition':requisition,'employer_domain':employer_domain,'description':plain(raw.get('description')),'snippet':bool(raw.get('snippet')),
      'locations':locations,'location':', '.join(locations) or 'Location not listed','country':raw.get('country') or 'Unknown','remote_eligibility':plain(raw.get('remote_eligibility')),
      'mode':mode,'employment_type':kind,'seniority':seniority,'occupation':raw.get('occupation') or classify(title),'compensation':salary,
      'salary':salary_label,'salary_note':'Estimated pay' if salary['estimated'] else ('Employer-provided pay' if amounts else 'Pay period and amount unknown'),
      'requirements':[plain(x) for x in raw.get('requirements',[]) if x],'qualifications':plain(raw.get('qualifications')),'eligibility':plain(raw.get('eligibility')),
      'posted_at':posted_at,'expires_at':expires_at,'discovered_at':now,'checked_at':now,'posted':datetime.fromtimestamp(posted_at,timezone.utc).strftime('%b %d') if posted_at else 'Posting date unknown',
      'source':source['adapter'],'source_name':source['name'],'source_id':source['id'],'source_job_id':str(raw.get('source_job_id') or requisition or canonical(url)),
      'attribution':raw.get('attribution') or {},'demo':False,'initial':company[:1].upper(),'color':'#EDF2FF',
      'tags':[x for x in [kind,seniority] if x!='Unknown'],'reason':'Matches your search filters. Review the employer’s requirements before applying.'}

LIST_FILTERS={'modes':('Remote','Hybrid','On-site'),'levels':('Internship','Entry-level','Mid-level','Senior','Leadership'),'employment_types':('Full-time','Part-time','Contract','Temporary','Internship'),
  'soft':('location','modes','employment_types','salary','level','experience','education'),'exclude_companies':None,'exclude_terms':None}

def validate_filters(query, filters) -> dict[str, Any]:
    """Search-level overrides. A key that is present overrides the profile value, even when empty."""
    if not isinstance(query,str) or len(query)>160:raise ValueError('Search must be under 160 characters.')
    allowed={'location','country','occupation','salary_min','salary_period','posted_days','has_posting_date','sort','timeline','confirmed_only','any_role',*LIST_FILTERS,
      'mode','experience','employment_type'}
    if not isinstance(filters,dict) or set(filters)-allowed:raise ValueError('Unsupported filter.')
    filters=dict(filters)
    # Older clients and saved searches send single values.
    for old,new in (('mode','modes'),('experience','levels'),('employment_type','employment_types')):
        if old in filters:
            value=filters.pop(old)
            if value not in ('','Any',None) and new not in filters:filters[new]=[value]
    result={k:v for k,v in filters.items() if v not in ('','Any',None) or k in LIST_FILTERS}
    for k,v in result.items():
        if k in ('salary_min','posted_days'):
            if isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or v<0 or v>10000000:raise ValueError('Invalid numeric filter.')
        elif k in ('has_posting_date','confirmed_only','any_role'):
            if not isinstance(v,bool):raise ValueError('Yes/no filters must be true or false.')
        elif k=='timeline':
            if v not in ('compatible','confirmed','all'):raise ValueError('Unsupported timeline filter.')
        elif k=='sort':
            if v not in ('newest','relevance'):raise ValueError('Unsupported sort order.')
        elif k=='salary_period':
            if v not in ('hour','year'):raise ValueError('Pay period must be hour or year.')
        elif k in LIST_FILTERS:
            if isinstance(v,str):v=[x.strip() for x in v.split(',') if x.strip()]
            if not isinstance(v,list) or len(v)>20 or any(not isinstance(x,str) or len(x)>80 for x in v):raise ValueError('Invalid list filter.')
            if LIST_FILTERS[k] and set(v)-set(LIST_FILTERS[k]):raise ValueError('Unsupported choice in '+k+'.')
            result[k]=list(dict.fromkeys(x.strip() for x in v if x.strip()))
        elif not isinstance(v,str) or len(v)>160:raise ValueError('Invalid search filter.')
    if result.get('country','US')!='US':raise ValueError('Discovery currently supports US jobs.')
    result['country']='US'
    result.setdefault('sort','relevance')
    return {'query':query.strip(),'filters':result}

def matches(job,query,filters,profile=None) -> bool:
    """True when no required input conflicts with the listing. See discovery.matching."""
    from discovery.matching import criteria,evaluate,facts
    view=dict(job)
    if 'facts' not in view:view['facts']=facts(view)
    return not evaluate(view,criteria(profile or {},query,filters))['excluded']

def source_enabled(adapter) -> str:
    import os
    required={'adzuna':['ADZUNA_APP_ID','ADZUNA_APP_KEY'],'theirstack':['THEIRSTACK_API_KEY'],'usajobs':['USAJOBS_API_KEY','USAJOBS_EMAIL']}
    missing=[k for k in required.get(adapter,[]) if not os.getenv(k)]
    if adapter=='theirstack' and os.getenv('STACK_THEIRSTACK_TERMS_ACCEPTED')!='yes':missing.append('STACK_THEIRSTACK_TERMS_ACCEPTED')
    if adapter=='adzuna' and os.getenv('STACK_ADZUNA_APPROVED')!='yes':missing.append('STACK_ADZUNA_APPROVED')
    return ', '.join(missing)

def dedupe_bucket(job) -> str:
    return digest('|'.join([re.sub(r'\W+','',job.get('company','').lower()),re.sub(r'\W+','',job.get('title','').lower()),','.join(sorted(x.lower().strip() for x in job.get('locations',[])))]))

def same_opening(left,right) -> bool:
    """Only merge cross-source copies with strong corroborating full descriptions."""
    from difflib import SequenceMatcher
    if left.get('source')==right.get('source') or left.get('snippet') or right.get('snippet'):return False
    if left.get('requisition') and right.get('requisition') and left['requisition']!=right['requisition']:return False
    if dedupe_bucket(left)!=dedupe_bucket(right):return False
    a=re.sub(r'\s+',' ',plain(left.get('description'))).lower()[:12000]
    b=re.sub(r'\s+',' ',plain(right.get('description'))).lower()[:12000]
    if min(len(a),len(b))<300:return False
    if left.get('posted_at') and right.get('posted_at') and abs(left['posted_at']-right['posted_at'])>14*86400:return False
    return SequenceMatcher(None,a,b,autojunk=False).ratio()>=.96
