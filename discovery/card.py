"""Small source-text excerpts for cards. No generated fit claims or inferred requirements."""
import re
from functools import lru_cache
from discovery.normalize import plain

@lru_cache(maxsize=4096)
def excerpts(description: str, qualifications: str) -> dict:
    responsibilities, requirements = [], []
    section = ''
    fallback = []
    pay = ''
    for line in plain(description+'\n'+qualifications).splitlines():
        line=line.strip(' \t•-')
        if not line: continue
        lower=line.lower().rstrip(':')
        if len(line)<85 and re.search(r'^(?:what you(?:.ll| will) do|(?:key |your )?responsibilities|the role|your (?:role|impact)|job description|position purpose)$',lower): section='role';continue
        if len(line)<85 and re.search(r'^(?:(?:(?:required|preferred|minimum|basic) )?(?:qualifications|requirements|experience)|what you(?:.ll| will) (?:need|bring)|who you are|about you)$',lower): section='requirements';continue
        if len(line)<85 and re.search(r'^(benefits|about (?:us|the company)|compensation|equal opportunity)',lower): section='';continue
        for sentence in re.split(r'(?<=[.!?])\s+(?=[A-Z])',line):
            if len(sentence)<28:continue
            if re.search(r'equal opportunity|without regard|reasonable accommodation|privacy notice|recruitment scam|protected (?:status|class)',sentence,re.I):continue
            clipped=sentence if len(sentence)<=230 else sentence[:227].rsplit(' ',1)[0]+'…'
            if not pay and re.search(r'\bsalary\b|\bpay range\b',sentence,re.I) and re.search(r'\$\s*[\d,]+',sentence):pay=clipped
            if section=='requirements' or re.search(r'\b(?:years? (?:of )?(?:professional )?experience|bachelor|master.s degree|must have|proficien|experience (?:with|in)|graduat|knowledge of|familiarity with)\b',sentence,re.I):
                if clipped not in requirements:requirements.append(clipped)
            elif section=='role' or re.search(r'^(?:you (?:will|would)|you.ll|build|design|develop|implement|collaborate|work (?:with|on)|deliver|maintain|support|lead|manage|provide|perform|assist|responsible for)\b',sentence,re.I):
                if clipped not in responsibilities:responsibilities.append(clipped)
            fallback.append(clipped)
    return {'responsibilities':responsibilities[:2] or fallback[:1], 'requirements':requirements[:2], 'pay_excerpt':pay}


def card_view(job: dict) -> dict:
    result=dict(job)
    result['highlights']=excerpts(str(job.get('description') or ''),str(job.get('qualifications') or ''))
    # Full text remains at get_job. The deck only needs these compact excerpts.
    for key in ('description','qualifications','eligibility','requirements','timeline_analysis','observations','sources','facts'):
        result.pop(key,None)
    if 'timeline' in result:
        result['timeline']={k:v for k,v in result['timeline'].items() if k!='evidence'}
    return result
