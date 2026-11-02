"""Small source-text excerpts for cards. No generated fit claims or inferred requirements."""
import re
from functools import lru_cache
from discovery.normalize import plain
from discovery.photos import posting_photo

LOCATION_SECTION = re.compile(
    r'^(?:about\b|role (?:summary|overview)|the role|position overview|job title|department\b|title\b|overview\b|key duties|.+ responsibilities\b|responsibilities\b|'
    r'qualifications\b|requirements\b|benefits\b|what\b|who\b|why\b|how\b|job description|'
    r'available terms|salary\b|compensation\b|interview\b|work schedule|application\b|apply\b)', re.I)
PLACE_WORD = r"[A-Z][\w.'’-]*"
PLACE_NAME = rf"{PLACE_WORD}(?: {PLACE_WORD}){{0,4}}"
PLACE_LINE = re.compile(rf"(?:[-•]\s*)?{PLACE_NAME}(?:[:,]\s*{PLACE_NAME})*")


def posting_location(lines):
    """Read a location the posting explicitly assigns to this role."""
    lines = [line.strip() for line in lines if line.strip()]
    offset = 0
    for i, line in enumerate(lines):
        offset += len(line)
        # Inline headings can be joined to the preceding paragraph by the ATS.
        label = re.search(r'(?:^|(?<=[.!?])\s*)(?:available|job|work) locations?\b\s*(?::\s*(.*)|$)', line, re.I)
        if not label and offset < 2500:
            # A generic heading in the introduction can describe the job. A
            # location in a pay table, interview itinerary or legal notice cannot.
            previous = ' '.join(lines[max(0, i - 3):i])
            if not re.search(r'salary|compensation|pay range|interview|mailing|accommodation|headquarters', previous, re.I):
                label = re.match(r'locations?:\s*(.*)', line, re.I)
        if label:
            end = i
            value = (label.group(1) or '').strip()
            if not value and i + 1 < len(lines):
                end += 1
                value = lines[end]
            # Keep a list of offices together when the source puts one on each line.
            for extra in lines[end + 1:]:
                if LOCATION_SECTION.match(extra) or not PLACE_LINE.fullmatch(extra):
                    break
                value += '; ' + extra.strip('-• ')
            value = re.split(r'About the [Rr]ole|About the [Tt]eam|Responsibilities\b|Qualifications\b', value)[0].strip(' |')
            if value and len(value) <= 200 and not LOCATION_SECTION.match(value):
                return value
        if re.match(r'this (?:role|position) is based in\b', line, re.I) and len(line) <= 200:
            return line
    return ''


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


def card_view(job: dict, preferred_location: str = '') -> dict:
    result=dict(job)
    description = job.get('description') or ''
    role_location = posting_location(plain(description).splitlines())
    result['photo_id'] = posting_photo(job, role_location, preferred_location)
    result['highlights']=excerpts(str(job.get('description') or ''),str(job.get('qualifications') or ''))
    # Full text remains at get_job. The deck only needs these compact excerpts.
    for key in ('description','qualifications','eligibility','requirements','timeline_analysis','observations','sources','facts'):
        result.pop(key,None)
    if 'timeline' in result:
        result['timeline']={k:v for k,v in result['timeline'].items() if k!='evidence'}
    return result
