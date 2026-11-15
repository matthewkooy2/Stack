"""Small source-text excerpts for cards. No generated fit claims or inferred requirements."""
import re
from functools import lru_cache
from discovery.normalize import plain
from discovery.photos import posting_photo

# Quote the employer's range (including geography, currency and any stated
# period). A dollar amount alone could be a benefit, budget or funding figure.
PAY_LABEL = re.compile(r'\b(?:salary|wages?|pay (?:rate|range|scale)|base (?:pay|range|compensation)|compensation(?: range)?|on[- ]target earnings|OTE|hourly (?:rate|pay))\b', re.I)
AMOUNT = re.compile(r'(?:[$£€]|\b(?:USD|CAD|EUR|GBP)\s+)\s*\d', re.I)
NON_WAGE = re.compile(r'\b(?:budget|revenue|funding|valuation|stipend|reimbursement|tuition|401\s*\(?k|sign[- ]on bonus|HSA|FSA|allowance)\b', re.I)


def pay_excerpt(lines):
    quotes = []
    previous = ''
    for line in lines:
        for sentence in re.split(r'(?<=[.!?])\s+(?=[A-Z$£€])', line.strip()):
            if not sentence:
                continue
            if AMOUNT.search(sentence) and not NON_WAGE.search(sentence):
                quote = ''
                if PAY_LABEL.search(sentence):
                    quote = sentence
                elif AMOUNT.match(sentence) and PAY_LABEL.search(previous) and not NON_WAGE.search(previous):
                    quote = previous + ' ' + sentence
                if quote and len(quote) <= 480 and quote not in quotes:
                    quotes.append(quote)
                    if len(quotes) == 2:
                        return '\n'.join(quotes)
            previous = sentence
    return '\n'.join(quotes)


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
def excerpts(description: str, qualifications: str, duties: str = '') -> dict:
    responsibilities, requirements = [], []
    section = ''
    fallback = []
    arrangement = ''
    lines = plain(description).splitlines()
    pay = pay_excerpt(lines)
    location = posting_location(lines)
    if duties:
        lines = ['Responsibilities', *plain(duties).splitlines(), 'Job description', *lines]
    if qualifications:
        lines.extend(['Qualifications', *plain(qualifications).splitlines()])
    for line in lines:
        line=line.strip(' \t•-')
        if not line: continue
        lower=line.lower().rstrip(':')
        if len(line)<85 and re.search(r'^(?:what you(?:.ll| will) do(?: at [^:]{1,35})?|essential duties|(?:key |your )?responsibilities|the role|your (?:role|impact)|job description|position purpose)$',lower): section='role';continue
        if len(line)<85 and re.search(r'^(?:(?:(?:required|preferred|minimum|basic) )?(?:qualifications|requirements|experience)|what you(?:.ll| will) (?:need|bring)|who you are|we.d love to hear from you if you have|about you)$',lower): section='requirements';continue
        if len(line)<85 and re.search(r'^(benefits|about (?:us|the company)|where you.ll be|additional information|company description|compensation|equal opportunity)',lower): section='';continue
        for sentence in re.split(r'(?<=[.!?])\s+(?=[A-Z])',line):
            # Keep the complete workplace choice, including eligibility and exceptions.
            if not arrangement and len(sentence) <= 240 and re.search(
                r'\b(?:this (?:role|position|job)|this is an? [^.!?]{0,25}(?:role|position|job))\b'
                r'[^.!?]{0,120}\b(?:or (?:fully )?remote(?:ly)?|remote(?:ly)? or)\b', sentence, re.I
            ):
                arrangement = sentence
            if len(sentence)<(3 if section else 28):continue
            if re.search(r'equal opportunity|without regard|reasonable accommodation|privacy notice|recruitment scam|protected (?:status|class)',sentence,re.I):continue
            clipped=sentence if len(sentence)<=230 else sentence[:227].rsplit(' ',1)[0]+'…'
            if section=='requirements' or re.search(r'\b(?:years? (?:of )?(?:professional )?experience|bachelor|master.s degree|must have|proficien|experience (?:with|in)|graduat|knowledge of|familiarity with)\b',sentence,re.I):
                if clipped not in requirements:requirements.append(clipped)
            elif section=='role' or re.search(r'^(?:you (?:will|would)|you.ll|build|design|develop|implement|collaborate|work (?:with|on)|deliver|maintain|support|lead|manage|provide|perform|assist|responsible for)\b',sentence,re.I):
                if clipped not in responsibilities:responsibilities.append(clipped)
            if section != 'requirements':fallback.append(clipped)
    result = {'responsibilities':responsibilities[:2] or fallback[:1], 'requirements':requirements[:2], 'pay_excerpt':pay}
    if location:
        result['location_excerpt'] = location
    if arrangement:
        result['work_arrangement'] = arrangement
    return result


def card_view(job: dict, preferred_location: str = '') -> dict:
    result=dict(job)
    highlights = dict(excerpts(job.get('description') or '', job.get('qualifications') or '', job.get('responsibilities') or ''))
    explicit = [r for r in job.get('requirements') or [] if isinstance(r, str) and r.strip()]
    highlights['requirements'] = list(dict.fromkeys(explicit + highlights['requirements']))[:2]
    supplied = (job.get('pay_text') or '').strip()
    if len(supplied) > 960:
        supplied = pay_excerpt(supplied.splitlines())
    if supplied:
        highlights['pay_excerpt'] = supplied
        if job.get('salary') and job['salary'] != 'Pay not listed':
            highlights['pay_context'] = supplied
    location = highlights.get('location_excerpt', '')
    result['photo_id'] = posting_photo(job, location, preferred_location)
    label = job.get('location') or ''
    if location and location.casefold() not in label.casefold():
        # Keep the original scope (including remote alternatives) beside the employer's wording.
        redundant = label.casefold() in {'', 'n/a', 'na', 'tbd', 'unknown', 'location', 'location not listed',
                                         (job.get('mode') or '').casefold()}
        result['location'] = location if redundant else f'{location} · {label}'
    result['highlights'] = highlights
    # Full text remains at get_job. The deck only needs these compact excerpts.
    for key in ('description','responsibilities','pay_text','qualifications','eligibility','requirements','timeline_analysis','observations','sources','facts'):
        result.pop(key,None)
    if 'timeline' in result:
        result['timeline']={k:v for k,v in result['timeline'].items() if k!='evidence'}
    return result
