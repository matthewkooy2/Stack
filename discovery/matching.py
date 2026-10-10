"""Deterministic job matching: listing facts, user criteria, and explained verdicts.

Every check reports one of four statuses:
  match    - the listing states something compatible with the user's input
  partial  - compatible, with a caveat (stretch, overqualified, preferred qualification)
  unknown  - the listing does not state it, or states it ambiguously
  conflict - the listing states something incompatible
Required conflicts exclude a job. Preferences and caveats only change ranking.
No network, storage, or model calls; facts carry the source text they came from.
"""
import csv
import re
from datetime import date
from functools import lru_cache
from pathlib import Path

from discovery.normalize import plain
from discovery.timeline import assess

MODES = ('Remote', 'Hybrid', 'On-site')
TYPES = ('Full-time', 'Part-time', 'Contract', 'Temporary', 'Internship')
LEVELS = ('Internship', 'Entry-level', 'Mid-level', 'Senior', 'Leadership')
STAGES = ('Student', 'Recent graduate', 'Early career', 'Experienced', 'Career changer')
EDUCATION = ('High school', 'Associate', "Bachelor's", "Master's", 'Doctorate')
# Checks a user may mark "nice to have" instead of required.
SOFTENABLE = ('location', 'modes', 'employment_types', 'salary', 'level', 'experience', 'education')
HOURS_PER_YEAR = 2080

STATES = {'alabama': 'AL', 'alaska': 'AK', 'arizona': 'AZ', 'arkansas': 'AR', 'california': 'CA', 'colorado': 'CO', 'connecticut': 'CT', 'delaware': 'DE', 'florida': 'FL', 'georgia': 'GA', 'hawaii': 'HI', 'idaho': 'ID', 'illinois': 'IL', 'indiana': 'IN', 'iowa': 'IA', 'kansas': 'KS', 'kentucky': 'KY', 'louisiana': 'LA', 'maine': 'ME', 'maryland': 'MD', 'massachusetts': 'MA', 'michigan': 'MI', 'minnesota': 'MN', 'mississippi': 'MS', 'missouri': 'MO', 'montana': 'MT', 'nebraska': 'NE', 'nevada': 'NV', 'new hampshire': 'NH', 'new jersey': 'NJ', 'new mexico': 'NM', 'new york': 'NY', 'north carolina': 'NC', 'north dakota': 'ND', 'ohio': 'OH', 'oklahoma': 'OK', 'oregon': 'OR', 'pennsylvania': 'PA', 'rhode island': 'RI', 'south carolina': 'SC', 'south dakota': 'SD', 'tennessee': 'TN', 'texas': 'TX', 'utah': 'UT', 'vermont': 'VT', 'virginia': 'VA', 'washington': 'WA', 'west virginia': 'WV', 'wisconsin': 'WI', 'wyoming': 'WY', 'district of columbia': 'DC', 'washington dc': 'DC', 'washington d.c.': 'DC'}
CODES = set(STATES.values())
# Cities often listed without a state. Only unambiguous, large US cities.
CITY_STATE = {'new york': 'NY', 'nyc': 'NY', 'new york city': 'NY', 'los angeles': 'CA', 'san francisco': 'CA', 'south san francisco': 'CA', 'san diego': 'CA', 'san jose': 'CA', 'oakland': 'CA', 'sacramento': 'CA', 'palo alto': 'CA', 'mountain view': 'CA', 'sunnyvale': 'CA', 'menlo park': 'CA', 'chicago': 'IL', 'boston': 'MA', 'cambridge, ma': 'MA', 'seattle': 'WA', 'bellevue': 'WA', 'austin': 'TX', 'dallas': 'TX', 'houston': 'TX', 'san antonio': 'TX', 'denver': 'CO', 'boulder': 'CO', 'atlanta': 'GA', 'miami': 'FL', 'orlando': 'FL', 'tampa': 'FL', 'phoenix': 'AZ', 'scottsdale': 'AZ', 'philadelphia': 'PA', 'pittsburgh': 'PA', 'detroit': 'MI', 'ann arbor': 'MI', 'minneapolis': 'MN', 'nashville': 'TN', 'raleigh': 'NC', 'durham': 'NC', 'charlotte': 'NC', 'salt lake city': 'UT', 'las vegas': 'NV', 'new orleans': 'LA', 'baltimore': 'MD', 'st. louis': 'MO', 'saint louis': 'MO', 'kansas city': 'MO', 'columbus': 'OH', 'cleveland': 'OH', 'cincinnati': 'OH', 'indianapolis': 'IN', 'milwaukee': 'WI', 'honolulu': 'HI', 'omaha': 'NE', 'portland': 'OR', 'washington, dc': 'DC', 'washington d.c.': 'DC'}
# New York City boroughs are the same city for a job seeker.
CITY_ALIASES = {'nyc': 'new york', 'new york city': 'new york', 'manhattan': 'new york', 'brooklyn': 'new york', 'queens': 'new york', 'bronx': 'new york', 'the bronx': 'new york', 'staten island': 'new york', 'st. louis': 'saint louis', 'st louis': 'saint louis', 'washington d.c.': 'washington', 'washington dc': 'washington'}
COUNTRY_WORDS = {'us', 'usa', 'u.s.', 'u.s.a.', 'united states', 'united states of america', 'america'}
NON_US = re.compile(r'\b(canada|mexico|united kingdom|uk|europe|european union|emea|apac|latam|germany|france|spain|ireland|india|australia|brazil|netherlands|poland|portugal|japan|singapore|philippines)\b', re.I)
PREFERRED = re.compile(r'\b(prefer\w*|nice[- ]to[- ]have|bonus|a plus|plus if|ideally|desired|desirable|advantageous|not required)\b', re.I)
REQUIRED = re.compile(r'\b(require[ds]?|requirements?|must|minimum|mandatory|at least|need(?:ed)?)\b', re.I)
ALTERNATIVE = re.compile(r'\b(or equivalent|equivalent (?:practical |work |professional )?experience|or (?:a )?combination|or related experience|in lieu of|or willingness to obtain)\b', re.I)
NUMBERS = {'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'twelve': 12, 'fifteen': 15}
NUM = r'(\d{1,2}|' + '|'.join(NUMBERS) + r')'
YEARS = re.compile(r'\b(?:(?:a )?minimum (?:of )?|at least |over |more than )?' + NUM + r'(?:\s*(?:-|–|to)\s*' + NUM + r')?\s*\+?\s*(?:or more |plus )?years?[’\']?\b(?![- ]old)'
                   r'(?:[^.;\n]{0,60}?\bexperience|\s+(?:of\s+)?(?:professional\s+|relevant\s+|hands-on\s+)?(?:managing|leading|working|building|developing|designing|delivering|selling|teaching|supervising|running|operating|in\s+(?:a|an)\s+[\w-]+\s+role))', re.I)
# Company history ("for over 20 years serving clients") is not a requirement.
NOT_REQUIREMENT = re.compile(r'\b(ago|founded|history|in business|for over|over the (?:past|last))\b', re.I)
DEGREES = [(5, re.compile(r'\b(ph\.?d|doctorate|doctoral degree)\b', re.I)), (4, re.compile(r"(?i:\b(master(?:['’]?s)?\s+(?:degree|of|in)|master['’]s|mba|msn)\b)|\bM\.?S\.?\b")), (3, re.compile(r"(?i:\b(bachelor(?:['’]?s)?|bsn|undergraduate degree|(?:4|four)[- ]year degree|college degree)\b)|\bB\.?[AS]\.?\b")), (2, re.compile(r"\b(associate'?s? degree|associate of)\b", re.I)), (1, re.compile(r'\b(high school (?:diploma|degree|education|graduate|or (?:equivalent|ged))|ged)\b', re.I))]
CONFIRM = re.compile(r"\b(licen[cs]e[ds]?|licensure|certifi\w+|cdl|security clearance|clearance|u\.?s\.? citizen\w*|work authorization|authorized to work|driver'?s license|background check)\b", re.I)
PAY_WORDS = re.compile(r'\b(salary|salaries|pay|paid|compensation|wage|rate|earn|hourly|per hour|/\s?hr|/\s?hour|annually|per year|per annum|/\s?year|/\s?yr|base)\b', re.I)
NOT_PAY = re.compile(r'\b(funding|funded|raised|revenue|valuation|series [a-f]|investors?|401\s?\(?k|bonus|sign[- ]on|relocation|tuition|reimburse\w*|budget|million|billion)\b', re.I)
MONEY = re.compile(r'\$\s?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)\s?([kK]\b|[mMbB]\b)?')
SECTIONS = [('preferred', re.compile(r'^(?:preferred|desired|bonus|nice[- ]to[- ]have|additional|pluses)\b.{0,40}$', re.I)),
            ('required', re.compile(r'^(?:(?:minimum|basic|required|key)\s+)?(?:qualifications|requirements|skills|experience)\b.{0,20}$|^what you(?:.ll| will) (?:need|bring)|^who you are|^about you|^must have', re.I)),
            ('other', re.compile(r'^(?:benefits|perks|about (?:us|the company)|compensation|equal opportunity|what you(?:.ll| will) do|responsibilities|the role)\b.{0,40}$', re.I))]


# ---------------------------------------------------------------- text helpers

def stem(word: str) -> str:
    word = {'sr': 'senior', 'jr': 'junior', 'mgr': 'manager', 'engr': 'engineer', 'internship': 'intern'}.get(word, word)
    if len(word) > 5 and word.endswith('ing'): word = word[:-3]
    if len(word) > 3 and word.endswith('s') and not word.endswith('ss'): word = word[:-1]
    if len(word) > 4 and word.endswith('e'): word = word[:-1]
    return word


def tokens(text: str) -> list[str]:
    return [stem(w) for w in re.findall(r'[a-z0-9]+', str(text).lower())]


def lines(job: dict):
    """Yield (sentence, section) pairs from the listing's own text fields."""
    for field in ('description', 'qualifications', 'eligibility'):
        section = 'required' if field == 'qualifications' else ''
        for line in plain(job.get(field) or '').splitlines():
            line = line.strip(' \t•●▪·*-–')
            if not line: continue
            heading = line.rstrip(':').strip()
            if len(heading) < 60:
                found = next((name for name, pattern in SECTIONS if pattern.search(heading)), None)
                if found:
                    section = found
                    if len(heading) == len(line.rstrip(':').strip()) and not re.search(r'\d', heading): continue
            for sentence in re.split(r'(?<=[.!?])\s+(?=[A-Z0-9$])|;\s+', line):
                if sentence.strip(): yield sentence.strip(), section


def clip(text: str, size: int = 160) -> str:
    text = re.sub(r'\s+', ' ', text).strip()
    return text if len(text) <= size else text[:size - 1].rsplit(' ', 1)[0] + '…'


# ---------------------------------------------------------------- occupations

@lru_cache(maxsize=1)
def onet():
    """Title -> set of O*NET codes. Ambiguous titles keep every code."""
    index, names = {}, {}
    def add(title, code):
        title = ' '.join(re.findall(r'[a-z0-9]+', title.lower()))
        if title: index.setdefault(title, set()).add(code)
    for filename, field in [('onet-occupation_data.csv', 'Title'), ('onet-job_titles.csv', 'Job Title'), ('onet-sample_of_reported_titles.csv', 'Reported Job Title')]:
        with Path('discovery', filename).open() as stream:
            for row in csv.DictReader(stream):
                code, title = row['O*NET-SOC Code'], row[field]
                names.setdefault(code, row['Title'])
                add(title, code)
                add(re.sub(r'\s*\([^)]*\)', '', title), code)
                if row.get('Short Title'): add(row['Short Title'], code)
                for acronym in re.findall(r'\(([A-Z]{2,6})\)', title): add(acronym, code)
    return index, names


def codes_for(text: str, whole: bool = False) -> set[str]:
    """Codes of the longest title phrase found in text. Ambiguous single words are ignored."""
    index, _ = onet()
    words = re.findall(r'[a-z0-9]+', str(text).lower())
    if whole:
        return index.get(' '.join(words), set())
    for size in range(min(8, len(words)), 0, -1):
        for i in range(len(words) - size + 1):
            found = index.get(' '.join(words[i:i + size]))
            if found and (size >= 2 or len({c[:7] for c in found}) == 1):
                return found
    return set()


def occupation_name(codes: set[str]) -> str:
    _, names = onet()
    groups = sorted({names.get(c, c) for c in codes})
    return groups[0] if len(groups) == 1 else ''


ROLE_QUALIFIERS = [
    (re.compile(r'\b(?:intern(?:ship)?s?|co-?op)\b', re.I), 'types', 'Internship'),
    (re.compile(r'\b(?:part[- ]time)\b', re.I), 'types', 'Part-time'),
    (re.compile(r'\b(?:full[- ]time)\b', re.I), 'types', 'Full-time'),
    (re.compile(r'\b(?:senior|sr\.?)\b', re.I), 'levels', 'Senior'),
    (re.compile(r'\b(?:junior|jr\.?|entry[- ]level|new grad(?:uate)?)\b', re.I), 'levels', 'Entry-level'),
    (re.compile(r'\b(?:remote)\b', re.I), 'modes', 'Remote'),
]
# Words that turn a preceding occupation into a modifier of a different job ("Nurse Recruiter", "Teacher Assistant").
MODIFIED_BY = {stem(w) for w in ('recruiter', 'recruitment', 'recruiting', 'sourcer', 'staffing', 'placement', 'assistant', 'aide', 'scheduler', 'liaison', 'coordinator', 'advocate', 'consultant', 'sales', 'marketing', 'trainer', 'training')}
STOP = {'a', 'an','the', 'and', 'of', 'for', 'in', 'at', 'to', 'with', 'job', 'jobs', 'role', 'roles', 'position', 'positions', 'opening', 'work'}


def parse_roles(text: str) -> list[dict]:
    """Split 'Nurse, charge nurse or RN' into roles; lift level/type words into requirements."""
    roles = []
    for part in re.split(r'\s*(?:,|;|\||/|\bor\b)\s*', str(text or ''), flags=re.I)[:6]:
        part = part.strip()
        if not part: continue
        role = {'text': part, 'types': [], 'levels': [], 'modes': []}
        core = part
        for pattern, key, value in ROLE_QUALIFIERS:
            if pattern.search(core):
                role[key].append(value)
                core = pattern.sub(' ', core)
        words = [w for w in re.findall(r'[a-z0-9]+', core.lower()) if w not in STOP]
        # A role made only of qualifiers ("Intern", "Remote") still has to appear in the title.
        words = words or [w for w in re.findall(r'[a-z0-9]+', part.lower()) if w not in STOP]
        role['core'] = ' '.join(words)
        role['stems'] = [stem(w) for w in words]
        role['codes'] = codes_for(role['core'], whole=True) or codes_for(role['core'])
        roles.append(role)
    return roles


def role_match(title: str, roles: list[dict]) -> dict:
    """Best title match across target roles. Related titles require a shared O*NET occupation."""
    if not roles:
        return {'status': 'match', 'score': 0.0, 'kind': 'any', 'role': None, 'detail': 'No target role set'}
    title_stems = tokens(title)
    title_codes = codes_for(title)
    best = None
    for role in roles:
        stems, kind, score = role['stems'], '', 0.0
        if not stems:
            kind, score = 'any', 0.5
        elif title_stems == stems or [s for s in title_stems if s not in ('senior', 'junior', 'intern')] == stems:
            kind, score = 'exact', 3.0
        elif any(title_stems[i:i + len(stems)] == stems for i in range(len(title_stems))):
            kind, score = 'phrase', 2.5
        elif set(stems) <= set(title_stems):
            kind, score = 'words', 2.0
        elif role['codes'] and title_codes and {c[:7] for c in role['codes']} & {c[:7] for c in title_codes}:
            kind, score = 'related', 1.0
        # The role word only modifies a different occupation ("Teacher Recruitment Specialist").
        if kind in ('phrase', 'words') and role['codes'] and title_codes and not ({c[:2] for c in role['codes']} & {c[:2] for c in title_codes}):
            kind, score = '', 0.0
        if kind in ('phrase', 'words'):
            last = max(i for i, s in enumerate(title_stems) if s == stems[-1])
            if last + 1 < len(title_stems) and title_stems[last + 1] in MODIFIED_BY and title_stems[last + 1] not in stems:
                kind, score = '', 0.0
        if kind and (best is None or score > best['score']):
            name = occupation_name(title_codes & role['codes']) or occupation_name(role['codes'])
            detail = {'exact': f'Title matches “{role["text"]}”', 'phrase': f'Title contains “{role["text"]}”', 'words': f'Title includes the words in “{role["text"]}”',
                      'related': f'Related title for “{role["text"]}”' + (f' (O*NET: {name})' if name else ''), 'any': 'Matches any title'}[kind]
            best = {'status': 'match', 'score': score, 'kind': kind, 'role': role, 'detail': detail}
    return best or {'status': 'conflict', 'score': 0.0, 'kind': '', 'role': None, 'detail': 'Title does not match your target roles'}


# ---------------------------------------------------------------- locations

def _place(city: str, state: str) -> dict:
    city = city.lower().strip(' .()')
    city = CITY_ALIASES.get(city, city)
    return {'city': city, 'state': state}


def parse_places(text: str) -> tuple[list[dict], list[str]]:
    """Physical places and remote segments from a free-text location."""
    places, remote = [], []
    for piece in re.split(r'\s*(?:;|\||\n)\s*', str(text or '')):
        if not piece.strip(): continue
        if re.search(r'\bremote\b', piece, re.I):
            # "Remote - CA, OR, WA" lists eligible states; in "Seattle, New York, US - Remote"
            # or "Remote - US, Austin" the other names are offices, not the remote region.
            scope, offices, extend = [], [], False
            for part in [x.strip() for x in piece.split(',') if x.strip()]:
                low = part.lower().strip(' ()')
                if re.search(r'\bremote\b', part, re.I):
                    scope.append(part)
                    own = re.sub(r'(?i)\bremote\b', ' ', part).strip(' -–:()').lower()
                    extend = own in STATES or own.upper() in CODES
                elif extend and (low in STATES or part.strip(' ()').upper() in CODES):
                    scope.append(part)
                else:
                    extend = False
                    offices.append(part)
            remote.append(', '.join(scope))
            if offices: places += parse_places(', '.join(offices))[0]
            continue
        parts = [p.strip(' ()') for p in re.split(r',|&|\band\b', piece) if p.strip(' ()')]
        pending = None
        for i, part in enumerate(parts):
            low = part.lower()
            nxt = parts[i + 1] if i + 1 < len(parts) else ''
            if low in COUNTRY_WORDS: continue
            if part.upper() in CODES and (part.isupper() or len(parts) > 1):
                if pending is not None and not pending['state']: pending['state'] = part.upper()
                elif not any(p['state'] == part.upper() for p in places): places.append(_place('', part.upper()))
                pending = None
                continue
            if low in STATES and not (nxt.upper() in CODES) and not (low in CITY_STATE and len(parts) > 1):
                if pending is not None and not pending['state']: pending['state'] = STATES[low]
                elif not (pending is not None and pending['state'] == STATES[low]): places.append(_place('', STATES[low]))
                pending = None
                continue
            if NON_US.search(low) or re.search(r'\d', low) or len(low) > 40: continue
            pending = _place(low, CITY_STATE.get(CITY_ALIASES.get(low, low), ''))
            places.append(pending)
    return places, remote


def parse_user_location(text: str) -> dict | None:
    text = str(text or '').strip()
    if not text or text.lower() in COUNTRY_WORDS or text.lower() in ('anywhere', 'remote', 'anywhere in the us'): return None
    places, _ = parse_places(text)
    return places[0] if places else {'city': text.lower(), 'state': ''}


def remote_scope(job: dict, segments: list[str], sentences: list | None = None) -> dict:
    """Where a remote job may be performed, from location text and eligibility sentences."""
    text = ' '.join(segments + [job.get('remote_eligibility') or ''] + re.findall(r'(?i)\bremote\s*[-–(:]\s*([^)\]]+)', job.get('title', '')))
    for sentence, _ in (lines(job) if sentences is None else sentences):
        if re.search(r'\b(resid\w*|located|based|live) in\b|\bremote (?:within|in)\b', sentence, re.I) and re.search(r'\bremote\b|\bresid', sentence, re.I):
            text += ' ' + sentence
    states = set()
    for name, code in STATES.items():
        if re.search(r'\b' + re.escape(name) + r'\b', text, re.I) and not re.search(r'\bnew york city\b', text, re.I) or (name == 'new york' and re.search(r'\bnew york\b(?! city)', text, re.I)):
            states.add(code)
    states |= {c for c in re.findall(r'\b([A-Z]{2})\b', text) if c in CODES and c != 'US'}
    us = bool(re.search(r'(?<![a-z])(us|usa|u\.s\.?|united states)(?![a-z])', text, re.I))
    only_abroad = bool(NON_US.search(text)) and not us and not states
    return {'us': us, 'states': sorted(states), 'abroad_only': only_abroad}


# ---------------------------------------------------------------- listing facts

def _mode_facts(job: dict, places: list, remote_segments: list, sentences: list | None = None) -> dict:
    found, evidence = set(), []
    stated = job.get('mode')
    if stated in MODES:
        found.add(stated); evidence.append(f'Source lists {stated}')
    if remote_segments:
        found.add('Remote'); evidence.append(f'Location: {clip(remote_segments[0], 80)}')
    title = job.get('title', '')
    if re.search(r'(?:^|[(\[\-–,|/:]\s*)(?:fully\s+)?remote(?:\s*[-–(]\s*(?:us|usa|united states)\)?)?\s*(?:$|[)\]\-–,|/:])', title, re.I):
        found.add('Remote'); evidence.append(f'Title: {title}')
    if re.search(r'(?:^|[(\[\-–,|/:]\s*)hybrid\s*(?:$|[)\]\-–,|/:])', title, re.I):
        found.add('Hybrid'); evidence.append(f'Title: {title}')
    patterns = [
        ('Remote', r'\b(?:this|the) (?:role|position|job|opportunity) is (?:a )?(?:fully |100% |completely )?remote\b|\b(?:fully|100%|completely) remote\b|\bremote (?:within|in) (?:the )?(?:us|u\.s\.|united states|tristate)|\bwork from home (?:role|position)\b'),
        ('Hybrid', r'\b(?:this|the) (?:role|position|job) is (?:a )?hybrid\b|\bhybrid (?:role|position|schedule|work (?:model|schedule|arrangement))\b|\b(?:\w+|\d) days? (?:per|a|each) week in (?:the |our )?office\b'),
        ('On-site', r'\b(?:this|the) (?:role|position|job) is (?:an? )?(?:fully )?(?:on-?site|in[- ]person|in[- ]office)\b|\b(?:fully )?(?:on-?site|in[- ]person|in[- ]office) (?:role|position)\b|\b(?:must|required to|expected to) (?:work|be) (?:on-?site|in[- ]person|in (?:the|our) office)\b'),
    ]
    for sentence, _ in (lines(job) if sentences is None else sentences):
        for mode, pattern in patterns:
            if re.search(pattern, sentence, re.I) and mode not in found:
                found.add(mode); evidence.append(clip(sentence))
    # A remote listing that also names offices may allow other arrangements.
    open_other = 'Remote' in found and bool(places) and len(found) == 1
    return {'modes': sorted(found), 'mode_open': open_other, 'mode_evidence': evidence[:2]}


def _employment_facts(job: dict, sentences: list | None = None) -> dict:
    found, excludes, evidence = set(), set(), []
    raw = str(job.get('employment_type') or '')
    key = re.sub(r'[\s_-]+', '', raw.lower())
    mapping = {'fulltime': 'Full-time', 'parttime': 'Part-time', 'contract': 'Contract', 'contractor': 'Contract', 'freelance': 'Contract',
               'temporary': 'Temporary', 'temp': 'Temporary', 'seasonal': 'Temporary', 'intern': 'Internship', 'internship': 'Internship',
               'perdiem': 'Part-time', 'prn': 'Part-time', 'casual': 'Part-time'}
    if key in mapping:
        found.add(mapping[key]); evidence.append(f'Source lists {raw}')
    elif key == 'permanent':
        excludes |= {'Contract', 'Temporary', 'Internship'}; evidence.append('Source lists Permanent (hours not stated)')
    elif 'full' in key and 'part' in key:
        found |= {'Full-time', 'Part-time'}; evidence.append(f'Source lists {raw}')
    title = job.get('title', '')
    for pattern, value in [(r'\bfull[- ]?time\b', 'Full-time'), (r'\bpart[- ]?time\b|\bper diem\b|\bprn\b', 'Part-time'), (r'\b(?:intern|internship|co-?op)\b', 'Internship'),
                           (r'\b(?:seasonal|temporary|temp)\b', 'Temporary'), (r'(?:[(\[\-–,]\s*)contract(?:or)?\s*(?:$|[)\]])|\bcontract[- ]to[- ]hire\b', 'Contract')]:
        if re.search(pattern, title, re.I) and value not in found:
            found.add(value); evidence.append(f'Title: {title}')
    for sentence, _ in (lines(job) if sentences is None else sentences):
        m = re.search(r'\b(?:this is a|is a|this) (full|part)[- ]time (?:position|role|job|opportunity)\b', sentence, re.I)
        if m:
            value = 'Full-time' if m.group(1).lower() == 'full' else 'Part-time'
            if value not in found: found.add(value); evidence.append(clip(sentence))
    return {'employment': sorted(found), 'employment_excludes': sorted(excludes), 'employment_evidence': evidence[:2]}


def _level_facts(job: dict, sentences: list | None = None) -> dict:
    title = job.get('title', '')
    low = title.lower()
    level, evidence = '', ''
    if job.get('employment_type') in ('Internship', 'Intern') or re.search(r'\b(?:intern|internship|co-?op)\b', low):
        level = 'Internship'
    elif re.search(r'\b(?:director|vice president|vp|head of|chief|executive director)\b|\b(?:assistant |vice )?principal\b(?=\s*(?:$|,|-|–|\(|of\b))', low):
        level = 'Leadership'
    elif re.search(r'\b(?:senior|sr\.?)\b(?!\s+(?:living|care|center|citizens?|services|community|housing|home|residents?|day))', low) \
            or re.search(r'\b(?:principal|master)\b(?!\s+(?:scheduler|data|agreement|teacher))', low) \
            or re.search(r'\bstaff\s+(?:software|engineer|machine|data|product|design|designer|platform|security|site|backend|frontend|full|ml|infrastructure|research engineer|scientist)', low) \
            or re.search(r'\blead\b', low) and not re.search(r'\b(?:shift|crew|team|lead teacher)\b', low) \
            or re.search(r'\b(?:iii|iv|lll)\s*$|\b(?:iii|iv)\b', low):
        level = 'Senior'
    elif re.search(r'\b(?:journeyman|ii|ll|2)\s*$|\b(?:journeyman|ii)\b|\blead teacher\b|\b(?:shift|crew|team) lead\b', low):
        level = 'Mid-level'
    elif re.search(r'\b(?:junior|jr\.?|entry[- ]level|new grads?|new graduates?|recent grad\w*|graduate program|early career|apprentice\w*|trainee)\b|\b(?:i|l|1)\s*$', low):
        level = 'Entry-level'
    if level:
        evidence = f'Title: {title}'
    else:
        for sentence, _ in (lines(job) if sentences is None else sentences):
            # "Mentor entry-level engineers" describes other people, not this role.
            if re.search(r'\b(?:this is an? |is an? )entry[- ]level\b|\bentry[- ]level (?:position|role|opportunity|apprenticeship)\b|\bnew grad\w*\b[^.]{0,40}?\bwelcome|\brecent graduates? (?:are )?(?:welcome|encouraged)|\bno experience (?:required|necessary)\b', sentence, re.I) \
                    and not re.search(r'\b(?:mentor\w*|supervis\w*|train\w*|lead\w*|manag\w*|guid\w*)\b[^.]{0,30}\bentry[- ]level', sentence, re.I):
                level, evidence = 'Entry-level', clip(sentence); break
    return {'level': level, 'level_evidence': evidence}


def _years_facts(job: dict, sentences: list | None = None) -> dict:
    required, preferred = [], []
    for sentence, section in (lines(job) if sentences is None else sentences):
        if re.search(r'\bno (?:prior )?experience (?:is )?(?:required|necessary|needed)\b', sentence, re.I):
            required.append((0, clip(sentence))); continue
        if NOT_REQUIREMENT.search(sentence): continue
        found = [(int(NUMBERS.get(m.group(1).lower(), m.group(1)) if not m.group(1).isdigit() else m.group(1))) for m in YEARS.finditer(sentence)]
        found = [n for n in found if n <= 25]
        if not found: continue
        # Alternatives ("5 years, or 3 with a master's") set the lowest bar in the sentence.
        value = min(found) if re.search(r'\bor\b', sentence, re.I) else max(found)
        soft = PREFERRED.search(sentence) or section == 'preferred'
        (preferred if soft else required).append((value, clip(sentence)))
    if required:
        value, quote = max(required)
        return {'years': {'min': value, 'required': True, 'quote': quote}}
    if preferred:
        value, quote = max(preferred)
        return {'years': {'min': value, 'required': False, 'quote': quote}}
    return {'years': None}


def _education_facts(job: dict, sentences: list | None = None) -> dict:
    required, preferred, enrolled = [], [], False
    for sentence, section in (lines(job) if sentences is None else sentences):
        levels = [level for level, pattern in DEGREES if pattern.search(sentence)]
        if not levels: continue
        if re.search(r'\b(?:currently (?:pursuing|enrolled)|pursuing|enrolled in)\b', sentence, re.I):
            enrolled = True
        entry = {'level': min(levels), 'alternative': bool(ALTERNATIVE.search(sentence)), 'quote': clip(sentence)}
        (preferred if PREFERRED.search(sentence) or section == 'preferred' else required).append(entry)
    if required:
        best = max(required, key=lambda x: x['level'])
        return {'education': {**best, 'required': True, 'enrolled': enrolled, 'name': EDUCATION[best['level'] - 1]}}
    if preferred:
        best = max(preferred, key=lambda x: x['level'])
        return {'education': {**best, 'required': False, 'enrolled': enrolled, 'name': EDUCATION[best['level'] - 1]}}
    return {'education': None}


def _unit(text: str, amount: float) -> str:
    text = text.lower()
    if re.search(r'\b(?:hour|hourly|hr)\b|/\s?h(?:ou)?r', text): return 'hour'
    if re.search(r'\b(?:week|weekly)\b', text): return 'week'
    if re.search(r'\b(?:month|monthly)\b', text): return 'month'
    if re.search(r'\b(?:year|yearly|annual\w*|per annum|yr|salary)\b', text): return 'year'
    return 'hour' if amount < 300 else 'year' if amount >= 10000 else ''


PER_YEAR = {'hour': HOURS_PER_YEAR, 'week': 52, 'month': 12, 'year': 1, 'day': 260}


def _pay_facts(job: dict, sentences: list | None = None) -> dict:
    comp = job.get('compensation') or {}
    low, high = comp.get('min'), comp.get('max')
    numbers = [x for x in (low, high) if isinstance(x, (int, float)) and x > 0]
    if numbers and comp.get('estimated'):
        return {'pay': None, 'pay_note': 'Pay shown by the source is an estimate, not employer-stated'}
    if numbers:
        currency = comp.get('currency') or 'Unknown'
        if currency not in ('USD', 'Unknown'):
            return {'pay': None, 'pay_note': f'Pay is listed in {currency}'}
        unit = {'yearly': 'year', 'annual': 'year', 'hourly': 'hour', 'weekly': 'week', 'monthly': 'month'}.get(str(comp.get('unit')).lower(), str(comp.get('unit')).lower())
        if unit not in PER_YEAR: unit = _unit('', max(numbers))
        if unit:
            return {'pay': {'min': float(low) if isinstance(low, (int, float)) and low > 0 else None, 'max': float(high) if isinstance(high, (int, float)) and high > 0 else None,
                            'unit': unit, 'source': 'Structured pay from the source', 'quote': ''}, 'pay_note': ''}
    ranges, context = [], 0
    for sentence, _ in (lines(job) if sentences is None else sentences):
        # "The base salary range for this position is:" followed by "$150,000—$200,000 USD".
        if NOT_PAY.search(sentence) and not MONEY.search(sentence): context = 0; continue
        worded = bool(PAY_WORDS.search(sentence))
        if worded and not MONEY.search(sentence): context = 3; continue
        if not (worded or context) or NOT_PAY.search(sentence): context = max(0, context - 1); continue
        context = max(0, context - 1)
        amounts = []
        for m in MONEY.finditer(sentence):
            if m.group(2) and m.group(2).lower() in ('m', 'b'): amounts = []; break
            amounts.append(float(m.group(1).replace(',', '')) * (1000 if m.group(2) and m.group(2).lower() == 'k' else 1))
        if not amounts: continue
        unit = _unit(sentence, max(amounts))
        if not unit: continue
        starting = re.search(r'\b(?:starting|starts|from|at least|minimum)\b', sentence, re.I) and len(amounts) == 1
        capped = re.search(r'\bup to\b', sentence, re.I) and len(amounts) == 1
        ranges.append({'min': None if capped else min(amounts[:2]), 'max': None if starting else max(amounts[:2]), 'unit': unit, 'quote': clip(sentence)})
        if len(ranges) == 4: break
    if ranges:
        # The first range is usually the primary location; others vary by location or level.
        return {'pay': {**ranges[0], 'source': 'Pay stated in the listing text', 'alternatives': ranges[1:]}, 'pay_note': ''}
    return {'pay': None, 'pay_note': ''}


def _confirm_facts(job: dict, sentences: list | None = None) -> dict:
    items = []
    for sentence, section in (lines(job) if sentences is None else sentences):
        if CONFIRM.search(sentence) and not PREFERRED.search(sentence) and not re.search(r'equal opportunity|without regard|reasonable accommodation|e-verify|eeo', sentence, re.I):
            if section == 'required' or REQUIRED.search(sentence) or len(sentence) < 90:
                items.append(clip(sentence, 120))
    return {'confirm': list(dict.fromkeys(items))[:3]}


FACTS_VERSION = 5


def facts(job: dict) -> dict:
    """Listing facts with evidence. Unknown means the listing does not say."""
    sentences = list(lines(job))
    locations = job.get('locations') or ([job['location']] if job.get('location') and job['location'] != 'Location not listed' else [])
    places, remote_segments = [], []
    for location in locations:
        found, remote = parse_places(location)
        places += found; remote_segments += remote
    result = {'version': FACTS_VERSION, 'places': places, 'remote_scope': remote_scope(job, remote_segments, sentences)}
    result.update(_mode_facts(job, places, remote_segments, sentences))
    for extract in (_employment_facts, _level_facts, _years_facts, _education_facts, _pay_facts, _confirm_facts):
        result.update(extract(job, sentences))
    return result


def current_facts(job: dict) -> dict:
    """Stored facts when they are current; otherwise recompute."""
    stored = job.get('facts')
    return stored if isinstance(stored, dict) and stored.get('version') == FACTS_VERSION else facts(job)


# ---------------------------------------------------------------- criteria

def _list(value, allowed=None) -> list[str]:
    if isinstance(value, str): value = [x for x in re.split(r'\s*[,;\n]\s*', value) if x]
    if not isinstance(value, list): raise ValueError('Expected a list.')
    items = [str(x).strip() for x in value if str(x).strip() and str(x).strip() != 'Any']
    if any(len(x) > 80 for x in items) or len(items) > 20: raise ValueError('Lists must have at most 20 short items.')
    if allowed is not None and set(items) - set(allowed): raise ValueError('Unsupported choice: ' + ', '.join(sorted(set(items) - set(allowed))))
    return list(dict.fromkeys(items))


def validate_preferences(prefs: dict) -> dict:
    """Profile-level matching inputs. Missing keys mean 'not provided'."""
    if not isinstance(prefs, dict): raise ValueError('Preferences must be an object.')
    allowed = {'stage', 'years', 'education', 'modes', 'employment_types', 'salary_min', 'salary_period', 'exclude_companies', 'exclude_terms', 'soft'}
    if set(prefs) - allowed: raise ValueError('Unsupported preference: ' + ', '.join(sorted(set(prefs) - allowed)))
    result = {}
    stage = prefs.get('stage') or ''
    if stage not in ('',) + STAGES: raise ValueError('Choose a listed career stage.')
    result['stage'] = stage
    years = prefs.get('years')
    if years in ('', None): result['years'] = None
    else:
        try: years = float(years)
        except (TypeError, ValueError): raise ValueError('Years of experience must be a number.') from None
        if years != years or not 0 <= years <= 60: raise ValueError('Years of experience must be between 0 and 60.')
        result['years'] = years
    education = prefs.get('education') or ''
    if education not in ('',) + EDUCATION: raise ValueError('Choose a listed education level.')
    result['education'] = education
    result['modes'] = _list(prefs.get('modes', []), MODES)
    result['employment_types'] = _list(prefs.get('employment_types', []), TYPES)
    salary = prefs.get('salary_min') or 0
    if isinstance(salary, str):
        try: salary = float(salary.replace(',', '').replace('$', '') or 0)
        except ValueError: raise ValueError('Minimum pay must be a number.') from None
    if isinstance(salary, bool) or not isinstance(salary, (int, float)) or salary != salary or not 0 <= salary <= 10000000: raise ValueError('Minimum pay must be a positive number.')
    result['salary_min'] = float(salary)
    result['salary_period'] = prefs.get('salary_period') or 'year'
    if result['salary_period'] not in ('hour', 'year'): raise ValueError('Pay period must be hour or year.')
    result['exclude_companies'] = _list(prefs.get('exclude_companies', []))
    result['exclude_terms'] = _list(prefs.get('exclude_terms', []))
    result['soft'] = _list(prefs.get('soft', []), SOFTENABLE)
    return result


# Search-level keys that may override a profile value, and the profile key they override.
OVERRIDES = {'query': 'roles', 'location': 'location', 'modes': 'modes', 'employment_types': 'employment_types', 'salary_min': 'salary_min',
             'salary_period': 'salary_period', 'exclude_companies': 'exclude_companies', 'exclude_terms': 'exclude_terms', 'soft': 'soft'}


def criteria(profile: dict, query: str = '', filters: dict | None = None) -> dict:
    """Merge profile inputs with explicit search overrides; record where each value came from."""
    filters = dict(filters or {})
    profile = dict(profile or {})
    base = validate_preferences({k: v for k, v in profile.items() if k in ('stage', 'years', 'education', 'modes', 'employment_types', 'salary_min', 'salary_period', 'exclude_companies', 'exclude_terms', 'soft')})
    values = {'roles': profile.get('roles', ''), 'location': profile.get('location', ''), **base,
              'graduation_month': profile.get('graduation_month', ''), 'available_from': profile.get('available_from', '')}
    sources = {k: ('profile' if values.get(k) not in ('', None, [], 0.0) else 'unset') for k in values}
    search = {'query': query, **filters} if query else dict(filters)
    for key, target in OVERRIDES.items():
        if key in search and search[key] is not None:
            value = search[key]
            if target in ('modes', 'employment_types', 'exclude_companies', 'exclude_terms', 'soft'):
                value = _list(value, {'modes': MODES, 'employment_types': TYPES, 'soft': SOFTENABLE}.get(target))
            if key == 'salary_min': value = float(value or 0)
            if value != values.get(target):
                values[target] = value
                sources[target] = 'search'
    if sources.get('salary_period') == 'search' and sources.get('salary_min') == 'unset': sources['salary_period'] = 'unset'
    roles = parse_roles(values['roles'])
    levels = _list(filters.get('levels', []), LEVELS)
    role_levels = sorted({lvl for r in roles for lvl in r['levels']})
    notices = []
    if filters.get('timeline') == 'confirmed' and not values['graduation_month']:
        notices.append('Set your graduation date to find confirmed timeline matches. Unknown graduation timing is included only in Hide timeline mismatches or All timelines.')
    if role_levels and values['stage']:
        clash = [lvl for lvl in role_levels if STAGE_FIT.get(values['stage'], {}).get(lvl) == 'conflict']
        if clash:
            notices.append(f'Your target role asks for {", ".join(clash).lower()} positions, but your career stage is {values["stage"]}. Those listings are excluded until one of them changes.')
    role_types = sorted({t for r in roles for t in r['types']})
    if role_types and values['employment_types'] and not set(role_types) & set(values['employment_types']):
        notices.append(f'Your target role implies {", ".join(role_types)}, but your employment types are {", ".join(values["employment_types"])}. No listing can satisfy both.')
    if values['salary_min'] and values['stage'] in ('Student',) and values['salary_period'] == 'year' and values['salary_min'] >= 150000:
        notices.append('Your minimum pay is high for student roles; few listings will meet it.')
    return {**values, 'roles_parsed': roles, 'levels': levels, 'sources': sources, 'notices': notices,
            'location_place': parse_user_location(values['location']),
            'occupation': filters.get('occupation', ''), 'posted_days': filters.get('posted_days', 0), 'has_posting_date': bool(filters.get('has_posting_date')),
            'timeline': filters.get('timeline', 'compatible'), 'confirmed_only': bool(filters.get('confirmed_only')),
            'confirmed_level': bool(filters.get('confirmed_level'))}


# ---------------------------------------------------------------- evaluation

STAGE_FIT = {
    'Student': {'Internship': 'match', 'Entry-level': 'match', 'Mid-level': 'conflict', 'Senior': 'conflict', 'Leadership': 'conflict'},
    'Recent graduate': {'Internship': 'partial', 'Entry-level': 'match', 'Mid-level': 'partial', 'Senior': 'conflict', 'Leadership': 'conflict'},
    'Early career': {'Internship': 'partial', 'Entry-level': 'match', 'Mid-level': 'match', 'Senior': 'partial', 'Leadership': 'conflict'},
    'Experienced': {'Internship': 'partial', 'Entry-level': 'partial', 'Mid-level': 'match', 'Senior': 'match', 'Leadership': 'match'},
    'Career changer': {'Internship': 'partial', 'Entry-level': 'match', 'Mid-level': 'match', 'Senior': 'partial', 'Leadership': 'partial'},
}
LABELS = {'role': 'Role', 'exclusions': 'Exclusions', 'location': 'Location', 'modes': 'Work arrangement', 'employment_types': 'Employment type',
          'salary': 'Pay', 'level': 'Level', 'experience': 'Experience', 'education': 'Education', 'timeline': 'Graduation timeline',
          'occupation': 'Occupation', 'posted': 'Posting date'}


def _money(value: float, unit: str) -> str:
    if unit == 'hour': return f'${value:,.2f}'.replace('.00', '') + '/hr'
    return f'${value / 1000:,.0f}k/yr' if value >= 1000 else f'${value:,.0f}/yr'


def _pay_status(pay: dict, want: float, unit: str) -> tuple[str, str]:
    factor = PER_YEAR[pay['unit']] / PER_YEAR[unit]
    low = pay['min'] * factor if pay['min'] else None
    high = pay['max'] * factor if pay['max'] else None
    shown = '–'.join(_money(x, unit) for x in dict.fromkeys(x for x in (low, high) if x))
    converted = ' (converted at 2,080 hours/year)' if pay['unit'] != unit and 'hour' in (pay['unit'], unit) else ''
    wanted = _money(want, unit)
    if high is not None and high < want - 1e-6:
        return 'conflict', f'Pays {shown}{converted}, below your {wanted} minimum'
    if high is None and low is not None and low < want:
        return 'unknown', f'Starts at {shown}{converted}; top of range not stated (your minimum is {wanted})'
    if low is not None and low < want:
        return 'match', f'Range {shown}{converted} reaches your {wanted} minimum'
    if low is None and high is not None:
        return 'unknown', f'Up to {shown}{converted}; starting pay not stated'
    return 'match', f'Pays {shown}{converted}; your minimum is {wanted}'


def _pay_check(f: dict, c: dict) -> tuple[str, str]:
    pay = f.get('pay')
    if not pay:
        return 'unknown', f.get('pay_note') or 'Pay not listed'
    status, detail = _pay_status(pay, c['salary_min'], c['salary_period'])
    others = [_pay_status(x, c['salary_min'], c['salary_period'])[0] for x in pay.get('alternatives', [])]
    if others:
        if status == 'conflict' and any(x != 'conflict' for x in others):
            return 'unknown', detail + '; pay varies by location or level'
        detail += ' (first of several listed ranges)'
    return status, detail


def _location_check(f: dict, c: dict) -> tuple[str, str]:
    user = c['location_place']
    modes = set(c['modes'])
    job_modes = set(f['modes'])
    scope = f['remote_scope']
    options = []
    remote_ok = not modes or 'Remote' in modes
    if 'Remote' in job_modes and remote_ok:
        if scope['abroad_only']:
            options.append(('conflict', 'Remote only outside the US'))
        elif scope['states']:
            listed = ', '.join(scope['states'])
            if user and user['state']:
                options.append(('match', f'Remote for residents of {listed}') if user['state'] in scope['states'] else ('conflict', f'Remote limited to {listed}'))
            else:
                options.append(('unknown', f'Remote limited to {listed}; add your state to check'))
        else:
            options.append(('match', 'Remote in the US' if scope['us'] else 'Remote (US listing; eligible states not stated)'))
    physical = not modes or bool(modes - {'Remote'})
    job_physical = bool(job_modes - {'Remote'}) or not job_modes or f['mode_open']
    if user and physical and job_physical:
        if not f['places']:
            if not job_modes: options.append(('unknown', 'Location not listed'))
        else:
            statuses = []
            for p in f['places']:
                if user['state'] and p['state'] and user['state'] != p['state']: statuses.append('conflict'); continue
                if user['city']:
                    if p['city'] and p['city'] == user['city']: statuses.append('match')
                    elif p['city']: statuses.append('conflict')
                    else: statuses.append('unknown')
                elif user['state']:
                    statuses.append('match' if p['state'] == user['state'] else 'unknown')
            names = ', '.join(dict.fromkeys(((p['city'].title() + (', ' if p['city'] and p['state'] else '')) if p['city'] else '') + p['state'] for p in f['places']))
            where = c['location']
            if 'match' in statuses: options.append(('match', f'In {where}'))
            elif 'unknown' in statuses: options.append(('unknown', f'Listed as {names}; could not confirm it is in {where}'))
            else: options.append(('conflict', f'Located in {names}, not {where}'))
    if not options and user and not job_modes and f['places']:
        # Remote-only users: a listed office with no stated arrangement is probably, but not certainly, on-site.
        names = ', '.join(dict.fromkeys((p['city'].title() + ', ' if p['city'] else '') + p['state'] for p in f['places']))
        return 'unknown', f'Listed in {names}; remote work not stated'
    if not options:
        return 'n/a', ''
    for status in ('match', 'unknown', 'partial', 'conflict'):
        for s, detail in options:
            if s == status: return s, detail
    return options[-1]


def _mode_check(f: dict, c: dict) -> tuple[str, str]:
    wanted, found = set(c['modes']), set(f['modes'])
    if not found:
        return 'unknown', 'Work arrangement not stated'
    if wanted & found:
        return 'match', ' / '.join(sorted(wanted & found))
    if f['mode_open'] and wanted - {'Remote'}:
        return 'unknown', 'Listed as remote; other arrangements at listed offices not stated'
    return 'conflict', f'{" / ".join(sorted(found))}; you want {" / ".join(sorted(wanted))}'


def _type_check(f: dict, wanted: set) -> tuple[str, str]:
    found = set(f['employment'])
    if found & wanted: return 'match', ' / '.join(sorted(found & wanted))
    if found: return 'conflict', f'{" / ".join(sorted(found))}; you want {" / ".join(sorted(wanted))}'
    if wanted <= set(f['employment_excludes']): return 'conflict', f'Permanent role; you want {" / ".join(sorted(wanted))}'
    return 'unknown', 'Permanent position; hours not stated' if f['employment_excludes'] else 'Employment type not stated'


def _level_check(f: dict, c: dict, role_levels: list) -> tuple[str, str, bool]:
    """Returns status, detail, and whether the user stated the level explicitly."""
    level = f['level']
    explicit = list(dict.fromkeys(c['levels'] + role_levels))
    if explicit:
        if not level:
            return ('conflict' if c['confirmed_level'] else 'unknown'), 'Level not stated', True
        return ('match', level, True) if level in explicit else ('conflict', f'{level}; you asked for {", ".join(explicit)}', True)
    if not c['stage'] or not level: return 'n/a', '', False
    fit = STAGE_FIT[c['stage']][level]
    detail = {'match': f'{level} fits {c["stage"].lower()}', 'partial': f'{level} role; you are {c["stage"].lower()}' + (' (may be overqualified)' if LEVELS.index(level) < 2 and c['stage'] == 'Experienced' else ' (stretch)'),
              'conflict': f'{level} role; too senior for {c["stage"].lower()}'}[fit]
    return fit, detail, False


def _experience_check(f: dict, c: dict) -> tuple[str, str]:
    years, have = f['years'], c['years']
    if have is None or not years: return 'n/a', ''
    need = years['min']
    have_text = f'you have {have:g}'
    if have >= need: return 'match', f'Asks {need}+ years; {have_text}'
    if not years['required']: return 'partial', f'Prefers {need}+ years; {have_text}'
    if need - have <= 1: return 'partial', f'Asks {need}+ years; {have_text} (within a year)'
    return 'conflict', f'Requires {need}+ years; {have_text}'


def _education_check(f: dict, c: dict, internship: bool) -> tuple[str, str]:
    edu, have = f['education'], c['education']
    if not have or not edu: return 'n/a', ''
    have_level = EDUCATION.index(have) + 1
    today = date.today()
    in_progress = bool(c['graduation_month']) and c['graduation_month'] > f'{today.year}-{today.month:02d}'
    need = edu['level']
    if have_level >= need:
        if in_progress and not internship and not edu['enrolled'] and have_level == need:
            return 'partial', f'{edu["name"]} {"required" if edu["required"] else "preferred"}; yours is expected {c["graduation_month"]}'
        return 'match', f'{edu["name"]} {"required" if edu["required"] else "preferred"}; you have {have}' + (' (in progress)' if in_progress else '')
    if not edu['required'] or edu['alternative']:
        return 'partial', f'{edu["name"]} {"preferred" if not edu["required"] else "or equivalent experience"}; you have {have}'
    return 'conflict', f'Requires {edu["name"]}; you have {have}'


def _exclusion_check(job: dict, c: dict) -> tuple[str, str]:
    company = job.get('company', '').lower()
    for name in c['exclude_companies']:
        if re.search(r'\b' + re.escape(name.lower()) + r'\b', company):
            return 'conflict', f'Excluded employer: {job.get("company")}'
    text = ' '.join([job.get('title', ''), job.get('company', ''), plain(job.get('description') or '')])
    for term in c['exclude_terms']:
        if re.search(r'\b' + re.escape(term.lower()) + r'\w*', text.lower()):
            return 'conflict', f'Mentions excluded term “{term}”'
    return 'match', ''


def evaluate(job: dict, c: dict, now: float | None = None) -> dict:
    """Explain how a listing relates to each input. Facts must already be attached as job['facts']."""
    import time
    now = time.time() if now is None else now
    f = current_facts(job)
    checks = []
    def add(key, status, detail, required=True):
        if status != 'n/a': checks.append({'key': key, 'label': LABELS[key], 'status': status, 'detail': detail, 'required': required})
    soft = set(c['soft'])

    role = role_match(job.get('title', ''), c['roles_parsed'])
    if c['roles_parsed']: add('role', role['status'], role['detail'])
    if job.get('country') not in ('US', 'USA', 'United States'):
        checks.append({'key': 'location', 'label': 'Country', 'status': 'conflict', 'detail': 'Not a US listing', 'required': True})
    if c['exclude_companies'] or c['exclude_terms']:
        status, detail = _exclusion_check(job, c)
        if status == 'conflict': add('exclusions', status, detail)
    if c['occupation']:
        add('occupation', 'match' if job.get('occupation') == c['occupation'] else 'conflict', job.get('occupation', 'Uncategorized'))
    if c['location_place'] or c['modes']:
        status, detail = _location_check(f, c)
        add('location', status, detail, 'location' not in soft)
    if c['modes']:
        status, detail = _mode_check(f, c)
        add('modes', status, detail, 'modes' not in soft)
    role_info = role.get('role') or {}
    types = set(c['employment_types'])
    if role_info.get('types'):
        types = set(role_info['types']) if not types else types & set(role_info['types']) or set(role_info['types']) | {'__none__'}
    if types:
        status, detail = _type_check(f, types - {'__none__'})
        if '__none__' in types: status, detail = 'conflict', 'Target role and employment types disagree'
        add('employment_types', status, detail, 'employment_types' not in soft)
    if c['salary_min']:
        status, detail = _pay_check(f, c)
        add('salary', status, detail, 'salary' not in soft)
    status, detail, explicit = _level_check(f, c, role_info.get('levels', []))
    add('level', status, detail, explicit or 'level' not in soft)
    status, detail = _experience_check(f, c)
    add('experience', status, detail, 'experience' not in soft)
    internship = 'Internship' in f['employment'] or f['level'] == 'Internship'
    status, detail = _education_check(f, c, internship)
    add('education', status, detail, 'education' not in soft)
    if c['graduation_month']:
        timeline = job.get('timeline') or assess(job, {'graduation_month': c['graduation_month'], 'available_from': c['available_from']})
        mode = c['timeline']
        if timeline['status'] == 'incompatible':
            add('timeline', 'conflict', timeline['reason'], mode != 'all')
        elif timeline['status'] == 'match':
            add('timeline', 'match', timeline['label'])
        elif timeline['status'] == 'unclear' and (timeline.get('evidence') or mode == 'confirmed'):
            add('timeline', 'unknown', timeline['reason'], True)
    if c['has_posting_date'] or c['posted_days']:
        posted = job.get('posted_at') or 0
        if not posted: add('posted', 'conflict', 'Posting date unknown')
        elif c['posted_days'] and posted < now - c['posted_days'] * 86400: add('posted', 'conflict', f'Posted more than {c["posted_days"]:g} days ago')

    required = [x for x in checks if x['required']]
    excluded = any(x['status'] == 'conflict' for x in required)
    unknown = [x for x in required if x['status'] == 'unknown']
    if c['timeline'] == 'confirmed' and not any(x['key'] == 'timeline' and x['status'] == 'match' for x in checks):
        excluded = True
    if c['confirmed_only'] and unknown:
        excluded = True
    weights = {'match': 1.0, 'partial': -0.75, 'unknown': -0.5, 'conflict': -3.0}
    score = role['score'] * 4 + sum(weights[x['status']] * (1.0 if x['required'] else 1.5) for x in checks if x['key'] != 'role')
    reasons = [x['detail'] for x in checks if x['status'] == 'match' and x['detail']][:4]
    caveats = [f'{x["label"]}: {x["detail"]}' for x in checks if x['status'] == 'partial' or (x['status'] == 'conflict' and not x['required'])]
    uncertain = [f'{x["label"]}: {x["detail"]}' for x in checks if x['status'] == 'unknown']
    return {'excluded': excluded, 'verdict': 'excluded' if excluded else ('uncertain' if unknown else 'match'),
            'label': 'Excluded' if excluded else ('Some requirements unconfirmed' if unknown else ('Meets your requirements, with notes' if caveats else 'Meets your requirements')),
            'score': round(score, 3), 'checks': checks, 'reasons': reasons, 'caveats': caveats[:4], 'uncertain': uncertain[:4],
            'confirm': f['confirm'], 'role_kind': role['kind']}
