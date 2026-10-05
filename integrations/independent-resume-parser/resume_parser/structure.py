"""Conservative geometric grouping and auditable, non-generative classification."""
import re
from bisect import bisect_right

HEADINGS = {
    'education': ('education', 'academic background', 'qualifications'),
    'employment': ('experience', 'work experience', 'employment', 'professional experience', 'work history'),
    'projects': ('projects', 'selected projects', 'personal projects'),
    'skills': ('skills', 'technical skills', 'technologies', 'competencies'),
    'unclassified': ('summary', 'profile', 'interests', 'awards', 'certifications', 'publications', 'volunteering'),
}
EMAIL = re.compile(r"(?<![\w.!#$%&'*+/=?^`{|}~-])[\w.!#$%&'*+/=?^`{|}~-]{1,64}@[\w-]{1,63}(?:\.[\w-]{1,63}){1,4}(?![\w.-])", re.UNICODE)
URL = re.compile(r'(?:https?://|www\.|(?:linkedin|github)\.com/)[^\s<>]{1,2048}', re.I)
PHONE = re.compile(r'(?<!\w)(?:\+\d{1,3}[ .-]?)?(?:\(\d{2,4}\)|\d{2,4})[ .-]\d{3,4}[ .-]\d{3,4}(?!\w)')
DATE = re.compile(r'\b(?:(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+)?(?:19|20)\d{2}\b|\b(?:Present|Current)\b', re.I)


def heading(text):
    value = text.strip().rstrip(':').casefold()
    return next((kind for kind, names in HEADINGS.items() if value in names), None)


def candidate(value, lines, confidence, reason):
    return {'value': value, 'confidence': confidence, 'reason': reason,
            'sourceSpanIds': [span for line in lines for span in line['sourceSpanIds']],
            'reviewed': False}


def matched_candidate(match, line, confidence, reason):
    # Ranges are ordered and disjoint. Bisect avoids scanning a fragmented line
    # once per match (and avoids copying every unrelated span into every match).
    ranges = line['sourceRanges']
    start = bisect_right(ranges, match.start(), key=lambda item: item['lineRange'][1])
    ids = []
    for index in range(start, len(ranges)):
        item = ranges[index]
        if item['lineRange'][0] >= match.end():
            break
        ids.append(item['sourceSpanId'])
    return {'value': match.group(), 'confidence': confidence, 'reason': reason,
            'sourceSpanIds': ids, 'lineId': line['id'],
            'lineRange': [match.start(), match.end()], 'reviewed': False}


def page_lines(page):
    spans = [s for s in page['spans'] if s['text']]
    # PDF.js can emit a whitespace-only item spanning an entire column gutter.
    # Preserve it in output, but do not treat it as ink for layout detection.
    ink = [s for s in spans if s['text'].strip()]
    # Repeated horizontal whitespace near the middle is evidence for two columns.
    # Scan fixed geometric positions, requiring >=3 baselines on each side.
    # Full-width headings are allowed above the start of the columns.
    split, best, top = None, 0, None
    for fraction in (0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65):
        x = page['width'] * fraction
        left = [s for s in ink if s['bbox'][0] + s['bbox'][2] < x - 12]
        right = [s for s in ink if s['bbox'][0] > x + 12]
        # Date-only right margins should not become independent reading columns.
        right = [s for s in right if not re.fullmatch(r'[\s\d/.,–—-]*(?:(?:Present|Current))?', s['text'], re.I)
                 and len(DATE.sub('', s['text']).strip(' -–—')) > 3]
        if len(left) < 3 or len(right) < 3:
            continue
        start = max(min(s['bbox'][1] for s in left), min(s['bbox'][1] for s in right)) - 4
        headings = [s['bbox'][1] - 4 for s in left + right if heading(s['text'])]
        if headings:
            start = min(start, min(headings))
        crossing = [s for s in ink if s['bbox'][1] >= start and s['bbox'][0] < x + 12
                    and s['bbox'][0] + s['bbox'][2] > x - 12]
        score = min(len({round(s['bbox'][1] / 4) for s in left}),
                    len({round(s['bbox'][1] / 4) for s in right}))
        if not crossing and score > best:
            split, best, top = x, score, start
    regions = {}
    for span in spans:
        x, y, width, height = span['bbox']
        region = 'body' if split is None else ('header' if y < top else 'left' if x < split else 'right')
        regions.setdefault(region, []).append(span)
    result = []
    for region in ('header', 'body', 'left', 'right'):
        rows = []
        for span in sorted(regions.get(region, []), key=lambda s: (s['bbox'][1], s['bbox'][0])):
            y = span['bbox'][1]
            if not rows or abs(y - rows[-1][0]['bbox'][1]) > max(2, min(abs(span['bbox'][3]), 16) * .3):
                rows.append([])
            rows[-1].append(span)
        for row in rows:
            row.sort(key=lambda s: s['bbox'][0])
            text = ''
            source_ranges = []
            previous = None
            for span in row:
                # Never normalize a PDF.js span; spaces inserted between distant
                # fragments are display-only and the exact spans remain in source.
                if previous and text and not text[-1].isspace() and not span['text'][:1].isspace():
                    gap = span['bbox'][0] - previous['bbox'][0] - previous['bbox'][2]
                    if gap > 1:
                        text += ' '
                start = len(text)
                text += span['text']
                source_ranges.append({'sourceSpanId': span['id'], 'lineRange': [start, len(text)]})
                previous = span
            result.append({'id': f"p{page['number']}l{len(result)}", 'text': text,
                           'page': page['number'], 'region': region, 'sourceRanges': source_ranges,
                           'y': row[0]['bbox'][1], 'height': max(abs(s['bbox'][3]) for s in row),
                           'sourceSpanIds': [s['id'] for s in row]})
    return result, split is not None


def infer(text):
    if re.search(r'\b(?:university|college|bachelor|master of|ph\.?d\.?|b\.?sc\.?|m\.?sc\.?)\b', text, re.I):
        return 'education', .6, 'education keyword; no heading'
    if re.match(r'\s*(?:projects?|built|developed)\s*[:\-]', text, re.I):
        return 'projects', .55, 'project label; no heading'
    if re.match(r'\s*(?:skills|languages|technologies|tools)\s*:', text, re.I):
        return 'skills', .65, 'skills label'
    if DATE.search(text) and re.search(r'\b(?:engineer|developer|manager|analyst|designer|intern|director|consultant)\b', text, re.I):
        return 'employment', .55, 'role and date; no heading'
    return 'unclassified', 0, 'no reliable classification'


def structure(extracted):
    lines, warnings = [], []
    for page in extracted['pages']:
        ordered, columns = page_lines(page)
        lines.extend(ordered)
        if columns:
            warnings.append({'code': 'COLUMN_ORDER_INFERRED', 'page': page['number']})
    if not any(line['text'].strip() for line in lines):
        warnings.append({'code': 'NO_EXTRACTABLE_TEXT', 'message': 'Scanned/image-only documents require OCR; no OCR was performed.'})
    contacts = {key: [] for key in ('name', 'email', 'phone', 'url')}
    sections = {key: [] for key in HEADINGS}
    sections['contact'] = []
    previous_region, active, block = None, None, None
    for index, line in enumerate(lines):
        text = line['text']
        region = (line['page'], line['region'])
        if region != previous_region:
            active, block = None, None
        previous_region = region
        found_contact = False
        for field, pattern, score in (('email', EMAIL, .98), ('phone', PHONE, .8), ('url', URL, .9)):
            for match in pattern.finditer(text):
                value = match.group()
                if field == 'phone' and not 7 <= len(re.sub(r'\D', '', value)) <= 15:
                    continue
                item = matched_candidate(match, line, score, f'{field} pattern')
                contacts[field].append(item)
                found_contact = True
        kind = heading(text)
        if kind is None and ':' in text:
            # An explicit inline label starts a section even after another heading.
            kind = heading(text.split(':', 1)[0])
        is_heading = kind is not None
        if is_heading:
            active, block = kind, None
            confidence, reason = .95, 'explicit section heading'
        elif active:
            kind, confidence, reason = active, .85, 'under explicit section heading'
        else:
            kind, confidence, reason = infer(text)
        if found_contact and not active:
            kind, confidence, reason = 'contact', .9, 'contains contact pattern; entire line preserved'
        if index == 0 and kind == 'unclassified' and 2 <= len(text.split()) <= 5 and not re.search(r'[\d@:/]', text):
            contacts['name'].append(candidate(text, [line], .35, 'first-line name candidate; user confirmation required'))
        # Keep section contents in editable blocks. Split on headings, regions,
        # classification changes, or visible vertical gaps; never infer employers.
        gap = line['y'] - block['lines'][-1]['y'] if block else 0
        if block is None or block['kind'] != kind or is_heading or gap > max(22, line['height'] * 1.8):
            block = {'id': f'b{sum(map(len, sections.values()))}', 'kind': kind,
                     'confidence': confidence, 'reason': reason, 'reviewed': False,
                     'lines': [], 'text': '', 'sourceSpanIds': [], 'dates': []}
            sections[kind].append(block)
        line['isHeading'] = is_heading
        block['lines'].append(line)
        block['sourceSpanIds'].extend(line['sourceSpanIds'])
        for match in DATE.finditer(text):
            block['dates'].append(matched_candidate(match, line, .8, 'literal date token; no inferred date boundaries'))
    for blocks in sections.values():
        for item in blocks:
            item['text'] = '\n'.join(line['text'] for line in item['lines'])
    return {'schemaVersion': 1, 'parserVersion': '0.1.0', 'status': 'needs_review',
            'contact': contacts, 'sections': sections, 'source': extracted,
            'warnings': warnings,
            'review': {'required': True, 'instructions': 'Confirm contact candidates, move or split blocks, and edit values. Retain source spans for audit. Confidence values are heuristic scores, not probabilities.'}}
