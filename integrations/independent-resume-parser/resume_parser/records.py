"""Original conservative record extraction from ordered lines and their geometry.

Field values are literal slices of extracted text. Missing values stay empty;
section/source evidence remains available even when record inference is wrong.
"""
import re
from bisect import bisect_right
from dataclasses import dataclass

from .dates import DATE, DATE_RANGE

BULLET = re.compile(r'^\s*[•●▪◦‣*\-]\s+')
SCHOOL = re.compile(r'\b(?:university|college|institute|polytechnic|school|academy)\b', re.I)
DEGREE = re.compile(r'\b(?:bachelor|master|associate|doctor|diploma|certificate|'
                    r'B\.?Sc\.?|M\.?Sc\.?|B\.?A\.?|M\.?A\.?|B\.?S\.?|M\.?S\.?|Ph\.?D\.?)\b', re.I)
ROLE = re.compile(r'\b(?:engineer|developer|manager|analyst|designer|intern|director|'
                  r'consultant|assistant|specialist|scientist|founder|officer|architect|'
                  r'technician|coordinator|administrator|professor|teacher|lead)\b', re.I)
COMPANY = re.compile(r'\b(?:labs?|systems|university|college|inc|llc|ltd|group|corp|company)\b', re.I)
ACTION = re.compile(r'^(?:built|developed|led|created|designed|implemented|managed|'
                    r'improved|maintained|delivered|worked|supported|conducted|wrote|'
                    r'presented|contributed|collaborated|explored|communicate|assess|'
                    r'maintain|published|used|visualized|achieved|responsible)\b', re.I)
LOCATION = re.compile(r'^[^\d|<>:]{2,70},\s*(?:[A-Z]{2}|Canada|United Kingdom|United States|Australia)$')
GPA = re.compile(r'\b(?:cumulative\s+)?GPA\s*:?\s*(\d{1,2}(?:\.\d+)?(?:\s*/\s*\d{1,2}(?:\.\d+)?)?)', re.I)


@dataclass(frozen=True)
class Slice:
    line: dict
    start: int
    end: int

    @property
    def text(self):
        return self.line['text'][self.start:self.end]

    def trim(self, chars=None):
        value = self.text
        left = len(value) - len(value.lstrip(chars))
        right = len(value.rstrip(chars))
        return Slice(self.line, self.start + left, max(self.start + left, self.start + right))

    def sub(self, start, end):
        return Slice(self.line, self.start + start, self.start + end)


def evidence_for(pieces, confidence, reason, separator=' '):
    ranges, ids = [], []
    for piece in pieces:
        mappings = piece.line['sourceRanges']
        index = bisect_right(mappings, piece.start, key=lambda item: item['lineRange'][1])
        supporting = []
        while index < len(mappings) and mappings[index]['lineRange'][0] < piece.end:
            supporting.append(mappings[index]['sourceSpanId'])
            index += 1
        ranges.append({'lineId': piece.line['id'], 'lineRange': [piece.start, piece.end],
                       'sourceSpanIds': supporting})
        ids.extend(supporting)
    return {'confidence': confidence, 'reason': reason, 'reviewed': False,
            'sourceSpanIds': list(dict.fromkeys(ids)), 'sourceRanges': ranges,
            'separator': separator}


def content(line):
    piece = Slice(line, 0, len(line['text'])).trim()
    if line['isHeading']:
        if ':' not in piece.text:
            return piece.sub(0, 0)
        piece = piece.sub(piece.text.index(':') + 1, len(piece.text)).trim()
    return piece


def parts(piece, spans):
    """Split header cells using visible gaps and literal separators, not fonts."""
    cuts = {piece.start, piece.end}
    previous = None
    for mapping in piece.line['sourceRanges']:
        start, end = mapping['lineRange']
        if end <= piece.start or start >= piece.end:
            continue
        span = spans[mapping['sourceSpanId']]
        if not span['text'].strip():
            continue
        if previous:
            old, old_end = previous
            gap = span['bbox'][0] - old['bbox'][0] - old['bbox'][2]
            if gap > max(24, abs(span['bbox'][3]) * 2.5):
                cuts.update((max(piece.start, old_end), min(piece.end, start)))
        previous = (span, end)
    # Match the delimiter first. Leading unbounded whitespace in a search
    # pattern would repeatedly backtrack on a hostile long whitespace run.
    for match in re.finditer(r'\||(?<=\s)[-–—](?=\s)|(?<=\s)at(?=\s)', piece.text):
        cuts.update((piece.start + match.start(), piece.start + match.end()))
    ordered = sorted(cuts)
    return [item for a, b in zip(ordered, ordered[1:])
            if (item := Slice(piece.line, a, b).trim()).text
            and item.text not in ('|', '-', '–', '—', 'at')]


def date_and_body(piece):
    match = DATE_RANGE.search(piece.text)
    if match is None:
        # A single date is accepted only as a complete cell or at a header's end.
        match = next((m for m in DATE.finditer(piece.text)
                      if not piece.text[m.end():].strip()), None)
    if match is None:
        return None, [piece]
    date = piece.sub(*match.span())
    rest = [piece.sub(0, match.start()).trim(' |–—-'),
            piece.sub(match.end(), len(piece.text)).trim(' |–—-')]
    return date, [item for item in rest if item.text]


class RecordBuilder:
    def __init__(self, sections, contacts, extracted):
        self.sections, self.contacts = sections, contacts
        self.spans = {s['id']: s for p in extracted['pages'] for s in p['spans']}
        self.lines = {line['id']: line for blocks in sections.values()
                      for block in blocks for line in block['lines']}
        self.evidence = {}
        self.description_pieces = {}
        self.resume = {'profile': {key: '' for key in
                       ('name', 'email', 'phone', 'location', 'link', 'summary')},
                       'education': [], 'workExperience': [], 'projects': [],
                       'skills': {'descriptions': []}, 'unclassified': []}
        self.resume['profile']['links'] = []

    def put(self, record, key, pieces, path, score=.65, reason='literal header field', separator=' '):
        pieces = [p for p in pieces if p.text]
        if not pieces:
            return
        record[key] = separator.join(p.text for p in pieces)
        self.evidence[f'{path}/{key}'] = evidence_for(pieces, score, reason, separator)

    def describe(self, record, piece, path, continuation=False):
        match = BULLET.match(piece.text)
        if match:
            piece = piece.sub(match.end(), len(piece.text)).trim()
        if not piece.text:
            return
        items = record['descriptions']
        if continuation and items and not match:
            index = len(items) - 1
            self.description_pieces[f'{path}/descriptions/{index}'][2].append(piece)
        else:
            items.append('')
            self.description_pieces[f'{path}/descriptions/{len(items)-1}'] = (items, len(items)-1, [piece])

    def new_record(self, kind):
        fields = {'education': ('school', 'degree', 'gpa', 'date', 'location'),
                  'workExperience': ('company', 'jobTitle', 'date', 'location'),
                  'projects': ('project', 'date')}[kind]
        record = dict.fromkeys(fields, '')
        record.update(descriptions=[], reviewed=False)
        index = len(self.resume[kind])
        self.resume[kind].append(record)
        return record, f'/resume/{kind}/{index}'

    def profile(self):
        profile = self.resume['profile']
        # Locate the first-line name without scanning all lines per candidate.
        by_span = {sid: line for line in self.lines.values() for sid in line['sourceSpanIds']}
        used = set()
        for field in ('name', 'email', 'phone', 'url'):
            for index, candidate in enumerate(self.contacts[field]):
                if field != 'url' and index:
                    break
                line = (self.lines.get(candidate.get('lineId')) or
                        by_span[candidate['sourceSpanIds'][0]])
                start, end = candidate.get('lineRange', (0, len(line['text'])))
                piece = Slice(line, start, end)
                used.add(line['id'])
                if field == 'url':
                    profile['links'].append(candidate['value'])
                    self.evidence[f'/resume/profile/links/{index}'] = evidence_for(
                        [piece], candidate['confidence'], candidate['reason'])
                    if index:
                        continue
                key = 'link' if field == 'url' else field
                self.put(profile, key, [piece], '/resume/profile', candidate['confidence'], candidate['reason'])
        first_section_y = min((l['y'] for l in self.lines.values()
                               if l['page'] == 1 and l['isHeading']), default=float('inf'))
        summary = []
        in_summary = False
        previous_region = None
        ordered = sorted(self.lines.values(), key=lambda l: (l['page'], int(l['id'].rsplit('l', 1)[1])))
        for line in ordered:
            region = (line['page'], line['region'])
            if region != previous_region:
                in_summary = False
            previous_region = region
            if line['isHeading']:
                label = line['text'].split(':', 1)[0].strip().casefold()
                in_summary = label in ('summary', 'profile')
                if in_summary:
                    used.add(line['id'])
            piece = content(line)
            if in_summary and piece.text:
                summary.append(piece)
                used.add(line['id'])
            elif line['page'] == 1 and line['y'] < first_section_y:
                for cell in parts(piece, self.spans):
                    match = re.match(r'\s*Location\s*:\s*(.+)', cell.text, re.I)
                    if (match or LOCATION.fullmatch(cell.text)) and not profile['location']:
                        if match:
                            cell = cell.sub(*match.span(1))
                        self.put(profile, 'location', [cell], '/resume/profile', .65, 'header location')
        self.put(profile, 'summary', summary, '/resume/profile', .85, 'explicit summary section', '\n')
        for block in self.sections['unclassified']:
            for line in block['lines']:
                if line['id'] not in used and line['text'].strip():
                    index = len(self.resume['unclassified'])
                    self.resume['unclassified'].append(line['text'])
                    self.evidence[f'/resume/unclassified/{index}'] = evidence_for(
                        [Slice(line, 0, len(line['text']))], 0, 'unclassified source text')

    def records(self, section, kind):
        rows = [line for block in self.sections[section] for line in block['lines']]
        record, path, region, previous = None, None, None, None
        for index, line in enumerate(rows):
            current_region = (line['page'], line['region'])
            if current_region != region or line['isHeading']:
                record, previous = None, None
            region = current_region
            piece = content(line)
            if not piece.text:
                continue
            bullet = bool(BULLET.match(piece.text))
            action = bool(ACTION.match(piece.text))
            gap = line['y'] - previous['y'] if previous else 0
            next_piece = content(rows[index+1]) if index+1 < len(rows) else None
            next_role = bool(next_piece and not BULLET.match(next_piece.text)
                             and not ACTION.match(next_piece.text) and ROLE.search(next_piece.text))
            date, remaining = date_and_body(piece) if not (bullet or action) else (None, [piece])
            cells = [cell for part in remaining for cell in parts(part, self.spans)]
            # Header cues never apply to bullet/action sentences. Unrecognized
            # text is retained as descriptions rather than used to fill a field.
            role = not (bullet or action) and any(ROLE.search(c.text) for c in cells)
            school = not (bullet or action) and any(SCHOOL.search(c.text) and not DEGREE.search(c.text) for c in cells)
            has_degree = any(DEGREE.search(c.text) for c in cells)
            new = record is None
            if record and not (bullet or action):
                if kind == 'education':
                    new = bool(school and record['school'] or
                               not has_degree and not GPA.search(piece.text) and
                               record['degree'] and gap > max(18, line['height'] * 1.4))
                elif kind == 'workExperience':
                    new = bool(role and record['jobTitle'] or
                               next_role and record['company'] and (record['jobTitle'] or record['descriptions'])
                               and (date or COMPANY.search(piece.text) or gap > max(18, line['height'] * 1.4)))
                else:
                    new = bool(record['project'] and (date or
                               gap > max(18, line['height'] * 1.4)))
            if new:
                record, path = self.new_record(kind)
            header = not (bullet or action) and (new or not record['descriptions'] or role or school)
            if not header:
                self.describe(record, piece, path, continuation=True)
                previous = line
                continue
            if date and not record['date']:
                self.put(record, 'date', [date], path, .9, 'literal date or date range')
            elif date:
                cells.append(date)  # Conflicting dates stay visible for review.
            if kind == 'projects':
                if not record['project']:
                    self.put(record, 'project', remaining, path)
                else:
                    self.describe(record, piece, path, continuation=True)
                previous = line
                continue
            for cell in cells:
                key = None
                gpa = GPA.search(cell.text) if kind == 'education' else None
                if gpa and not record['gpa']:
                    self.put(record, 'gpa', [cell.sub(*gpa.span(1))], path, .9, 'explicit GPA label')
                    leftovers = [cell.sub(0, gpa.start()).trim(' ,;|'),
                                 cell.sub(gpa.end(), len(cell.text)).trim(' ,;|')]
                    for leftover in leftovers:
                        if leftover.text:
                            if DEGREE.search(leftover.text) and not record['degree']:
                                self.put(record, 'degree', [leftover], path)
                            else:
                                self.describe(record, leftover, path)
                    continue
                if LOCATION.fullmatch(cell.text) and not record['location']:
                    key = 'location'
                elif kind == 'education':
                    if DEGREE.search(cell.text) and not record['degree']:
                        key = 'degree'
                    elif not record['school']:
                        key = 'school'
                elif ROLE.search(cell.text) and not record['jobTitle']:
                    key = 'jobTitle'
                elif not record['company']:
                    key = 'company'
                if key:
                    self.put(record, key, [cell], path)
                else:
                    self.describe(record, cell, path, continuation=True)
            previous = line

    def build(self):
        self.profile()
        self.records('education', 'education')
        self.records('employment', 'workExperience')
        self.records('projects', 'projects')
        for block in self.sections['skills']:
            for line in block['lines']:
                self.describe(self.resume['skills'], content(line), '/resume/skills')
        # Join wrapped descriptions and collect their evidence once. Rebuilding
        # growing strings/ID lists per line would allow quadratic amplification.
        for path, (items, index, pieces) in self.description_pieces.items():
            items[index] = ' '.join(p.text for p in pieces)
            self.evidence[path] = evidence_for(pieces, .7, 'description text')
        warnings = []
        for kind, required in [('education', ('school',)),
                               ('workExperience', ('company', 'jobTitle')),
                               ('projects', ('project',))]:
            for index, record in enumerate(self.resume[kind]):
                missing = [key for key in required if not record[key]]
                if missing:
                    warnings.append({'code': 'INCOMPLETE_RECORD', 'recordPath': f'/resume/{kind}/{index}',
                                     'missingFields': missing})
        return self.resume, self.evidence, warnings


def build_records(sections, contacts, extracted):
    return RecordBuilder(sections, contacts, extracted).build()
