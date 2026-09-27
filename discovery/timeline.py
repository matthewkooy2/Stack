"""Conservative, evidence-backed timeline extraction. No model calls or inferred eligibility."""
import calendar
import hashlib
import json
import re
from datetime import date
from discovery.normalize import plain

VERSION = 4
MONTHS = {name.lower(): n for n in range(1, 13) for name in (calendar.month_name[n], calendar.month_abbr[n])}
MONTH = r'(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)'
DATE = re.compile(r'\b(?:(?P<month>'+MONTH+r')\.?\s+(?:(?P<day>\d{1,2})(?:st|nd|rd|th)?[,]?\s+)?(?P<year>20\d{2})|(?P<iso>20\d{2}-\d{2})(?:-\d{2})?|(?P<yearonly>20\d{2}))\b', re.I)
GRAD = re.compile(r'\b(?:graduat\w*|expected (?:degree )?completion|complet\w* (?:your |a |the )?(?:bachelor\S*|master\S*|degree))\b', re.I)


def validate_month(value: str) -> str:
    if not isinstance(value, str) or (value and not re.fullmatch(r'20\d{2}-(?:0[1-9]|1[0-2])', value)):
        raise ValueError('Use YYYY-MM for graduation and availability, or leave blank.')
    return value


def ordinal(value: str) -> int:
    y, m = map(int, value.split('-'))
    return y * 12 + m


def _dates(text):
    results = []
    for match in DATE.finditer(text):
        if match['iso']:
            try: low = high = ordinal(validate_month(match['iso']))
            except ValueError: continue
        else:
            year = int(match['year'] or match['yearonly'])
            month = MONTHS.get('sep' if (match['month'] or '').lower() == 'sept' else (match['month'] or '').lower())
            low, high = year * 12 + (month or 1), year * 12 + (month or 12)
        results.append((low, high, match.start(), match.end()))
    return results


def fingerprint(job: dict) -> str:
    text = json.dumps([VERSION] + [job.get(k, '') for k in ('title','description','qualifications','eligibility','employment_type','snippet')], sort_keys=True)
    return hashlib.sha256(text.encode()).hexdigest()


def analyze(job: dict) -> dict:
    key = fingerprint(job)
    previous = job.get('timeline_analysis', {})
    if previous.get('fingerprint') == key:
        return previous
    evidence, windows, starts, ends = [], [], [], []
    student = completed = returning = False
    ambiguous = False
    # Preserve quotes exactly as present in the sanitized source fields.
    for field in ('description', 'qualifications', 'eligibility'):
        text = plain(job.get(field) or '')
        for sentence in re.split(r'(?<=[.!?])\s+|[\n\r]+|;\s*', text):
            sentence = sentence.strip()
            if not sentence: continue
            low = sentence.lower()
            is_grad = bool(GRAD.search(sentence))
            # Invitations ("New graduates welcome") are not graduation-date constraints.
            if is_grad and not DATE.search(sentence) and re.search(r'\b(?:new|recent) grad\w*\b[^.]{0,40}?\b(?:welcome|encouraged)|\bwelcome (?:new|recent) grad', low):
                is_grad = False
            is_start = bool(re.search(r'\b(?:start(?:ing)? (?:date|work|in|on|between)|begin(?:ning)? (?:work|in|on)|available to (?:start|begin))\b', low))
            is_return = bool(re.search(r'\breturn(?:ing)? to (?:school|university|college|your studies|an? (?:academic|degree) program)', low))
            is_student = bool(re.search(r'\b(?:currently (?:enrolled|pursuing)|must be enrolled)', low))
            is_completed = bool(re.search(r'\b(?:must (?:have )?already (?:graduated|completed|earned)|degree (?:completed|required) (?:before|at|by) (?:the time of )?application)', low))
            is_end = bool(re.search(r'\b(?:internship|program) (?:ends|ending|concludes)|\bend date\b', low))
            if not any((is_grad, is_start, is_return, is_student, is_completed, is_end)): continue
            evidence.append({'field':field, 'quote':sentence})
            # Alternatives, preferences and negations cannot support hard exclusion.
            constraint = low
            graduation_mentions = list(re.finditer(r'\b(?:graduating|graduation(?: date| window)?)\b', low))
            if graduation_mentions:
                constraint = low[graduation_mentions[-1].start():]
            dates = _dates(sentence)
            # Alternatives only qualify a dated or graduation clause, not "Computer Science or a related field".
            uncertain = bool((dates or is_grad) and re.search(r'\b(?:or|preferred|ideally|not|flexible|equivalent|for example)\b', constraint))
            # Preferences/negation before the graduation clause still qualify it.
            uncertain |= bool(re.search(r'\b(?:not|preferred|ideally|for example)\b', low))
            handled = False
            if len(re.findall(r"\b"+MONTH+r"\b", sentence, re.I)) > sum(bool(re.search(MONTH, sentence[a:b], re.I)) for _,_,a,b in dates):
                uncertain = True
            if re.search(r'\b(?:spring|summer|fall|autumn|winter)\b', low) or any(m['day'] for m in DATE.finditer(sentence)):
                uncertain = True
            if uncertain:
                ambiguous = True
                continue
            graduation_prefix = bool(dates and re.search(r'\b(?:graduating|graduate|graduated|graduation(?: date| window)?|expected (?:degree )?completion)\s*(?::|is)?\s*(?:in|during|of|between|from)?\s*$', low[:dates[0][2]]))
            if is_grad and dates and not is_start and not is_end and graduation_prefix:
                if len(dates) == 2 and re.search(r'\b(?:between|through|to)\b|[–—]|\d\s*-\s*', low):
                    windows.append([dates[0][0], dates[1][1]]); handled = True
                elif len(dates) == 1:
                    before_date = low[:dates[0][2]]
                    if re.search(r'\b(?:by|before|after|since|until)\b', before_date):
                        ambiguous = True  # Day-boundaries and relative windows need review.
                    elif re.search(r'\b(?:in|of|date|between|during|expected|graduating|graduation)\b', before_date):
                        windows.append([dates[0][0], dates[0][1]]); handled = True
            if is_start and len(dates) == 1:
                starts.append([dates[0][0], dates[0][1]]); handled = True
            if is_end and len(dates) == 1:
                ends.append([dates[0][0], dates[0][1]]); handled = True
            student |= is_student
            completed |= is_completed
            returning |= is_return
            if not handled and not any((is_student, is_completed, is_return)):
                ambiguous = True
    windows = [list(x) for x in sorted(set(map(tuple, windows)))]
    # Distinct graduation windows can describe alternative programs/degrees.
    if len(windows) > 1 or any(a > b for a,b in windows) or len(evidence)>30: ambiguous = True
    return {'version':VERSION, 'fingerprint':key, 'method':'rules', 'graduation_windows':windows,
            'start_windows':starts, 'end_windows':ends, 'current_student':student,
            'completed_degree':completed, 'return_to_school':returning,
            'ambiguous':ambiguous, 'partial':bool(job.get('snippet')),
            'evidence':evidence[:30]}


def assess(job: dict, preferences: dict) -> dict:
    graduation = preferences.get('graduation_month', '')
    availability = preferences.get('available_from', '')
    analysis = job.get('timeline_analysis', {})
    result = {'status':'unclear', 'label':'Timeline unclear', 'reason':'No explicit graduation window found.',
              'evidence':analysis.get('evidence', []), 'graduation_month':graduation, 'available_from':availability}
    if not graduation:
        return {**result, 'status':'unset', 'label':'Set your graduation date', 'reason':'Add your graduation month in Profile to check this listing.'}
    if analysis.get('version') != VERSION:
        return {**result, 'reason':'Timeline analysis is pending.'}
    if analysis.get('partial') or analysis.get('ambiguous'):
        return {**result, 'reason':'The source is incomplete or its requirements need manual review.'}
    grad = ordinal(graduation)
    now = date.today(); this_month = now.year*12+now.month
    windows = analysis.get('graduation_windows', [])
    mismatch = ''
    if windows and not windows[0][0] <= grad <= windows[0][1]:
        mismatch = 'Your graduation month is outside the stated graduation window.'
    if analysis.get('completed_degree') and grad > this_month:
        mismatch = 'This listing explicitly requires graduation before applying.'
    if analysis.get('current_student') and grad < this_month:
        mismatch = 'This listing requires current enrollment; your graduation month has passed.'
    internship = job.get('employment_type') == 'Internship' or bool(re.search(r'\bintern(?:ship)?\b', job.get('title',''), re.I))
    start_windows = analysis.get('start_windows', [])
    if availability and not internship and start_windows and all(end < ordinal(availability) for _,end in start_windows):
        mismatch = 'The stated start date is earlier than your full-time availability.'
    if analysis.get('return_to_school') and analysis.get('end_windows'):
        if all(start >= grad for start,_ in analysis['end_windows']):
            mismatch = 'This internship requires returning to school after it ends, after your graduation month.'
    if mismatch:
        return {**result, 'status':'incompatible', 'label':'Timeline mismatch', 'reason':mismatch}
    if analysis.get('return_to_school'):
        return {**result, 'reason':'Requires returning to school after the internship; confirm your enrollment plans.'}
    if start_windows and not internship and (not availability or any(start < ordinal(availability) <= end for start,end in start_windows)):
        return {**result, 'reason':'The start date needs review against your full-time availability.'}
    if windows:
        return {**result, 'status':'match', 'label':'Graduation window matches', 'reason':'Your graduation month fits the stated window. Check the remaining qualifications before applying.'}
    return result


def timeline_includes(result: dict, mode: str) -> bool:
    return mode == 'all' or (result['status'] == 'match' if mode == 'confirmed' else result['status'] != 'incompatible')
