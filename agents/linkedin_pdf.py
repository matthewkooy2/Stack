"""Read a member's own LinkedIn "Save to PDF" export into review sections.

Stack never signs in to LinkedIn or reads its pages; the member downloads this file
from their own profile and chooses to upload it. Text comes from the bounded
`pdf_safety` worker. LinkedIn's export has a narrow left sidebar (Contact, Top
Skills, Languages, Certifications, Honors-Awards) beside a main column (name,
headline, location, then Summary, Experience, Education and similar sections).
Contact details other than the profile address are discarded, never stored or
sent to a model.
"""
import base64
import re
import time
from pathlib import Path

MAX_BYTES = 10 * 1024 * 1024
MAX_ENCODED = 13_981_016
MAX_TEXT = 60000
# Per-section and total limits keep the review inside a small local model's context.
SECTION_LIMIT = 5000
TOTAL_LIMIT = 9000
# Model-visible order; earlier sections keep their text when the total limit is reached.
ORDER = ('headline', 'intro', 'about', 'experience', 'skills', 'education', 'certifications',
         'projects', 'volunteer', 'honors', 'languages', 'publications')
MAIN_HEADINGS = {
    'summary': 'about', 'about': 'about', 'experience': 'experience', 'education': 'education',
    'projects': 'projects', 'volunteer experience': 'volunteer', 'volunteering': 'volunteer',
    'publications': 'publications', 'honors-awards': 'honors', 'honors & awards': 'honors',
    'certifications': 'certifications', 'licenses & certifications': 'certifications',
    'languages': 'languages', 'skills': 'skills',
}
SIDE_HEADINGS = {
    'contact': 'contact', 'top skills': 'skills', 'skills': 'skills', 'languages': 'languages',
    'certifications': 'certifications', 'honors-awards': 'honors', 'publications': 'publications',
}
# Sections a profile commonly has that this export never includes.
NEVER_EXPORTED = ('featured', 'recommendations', 'activity')
LIMITATIONS = ('Reviewed from your LinkedIn PDF export. The export leaves out your photo, banner, '
               'Featured section, recommendations and activity, and may shorten long sections. '
               'Sections missing from the file are unknown, not absent from your profile.')
NOT_LINKEDIN = ('This doesn\'t look like a LinkedIn profile PDF. On linkedin.com, open your profile, '
                'choose More (or Resources), then Save to PDF, and upload that file.')
PROFILE_URL = re.compile(r'(?:https?://)?(?:[a-z]{2,3}\.)?(?:www\.)?linkedin\.com/in/[A-Za-z0-9_%\-]+', re.I)
FOOTER = re.compile(r'^Page\s*\d+\s*of\s*\d+$', re.I)
DATE_RANGE = re.compile(
    r'\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|'
    r'Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?|\d{4})\b.*\s[-–]\s', re.I)
BULLET = re.compile(r'^[•●▪◦\-*]\s')


def _rows(spans, gap=2.5):
    """Group positioned fragments into visual rows, left to right."""
    rows = []
    for x, y, w, h, text in sorted(spans, key=lambda s: (s[1], s[0])):
        if rows and abs(rows[-1]['y'] - y) <= gap:
            row = rows[-1]
            row['parts'].append((x, text))
            row['h'] = max(row['h'], h)
            row['right'] = max(row['right'], x + w)
        else:
            rows.append({'y': y, 'h': h, 'x': x, 'right': x + w, 'parts': [(x, text)]})
    for row in rows:
        row['text'] = re.sub(r'\s+', ' ', ' '.join(t for _, t in sorted(row['parts']))).strip()
        row['x'] = min(x for x, _ in row['parts'])
    return [row for row in rows if row['text']]


def _join(rows):
    """Join wrapped body lines; keep entry headers, dates and bullets on their own lines."""
    lines, previous = [], None
    for row in rows:
        text = row['text']
        # LinkedIn wraps body text near 70 characters; shorter lines end on purpose.
        wrapped = (previous is not None and row['h'] < 11.2 and previous['h'] < 11.2
                   and not BULLET.match(text) and not DATE_RANGE.search(previous['text'])
                   and 0 < row['y'] - previous['y'] <= row['h'] * 2
                   and len(previous['text']) >= 50)
        if wrapped and lines:
            # LinkedIn wraps "full-stack" and "CI/CD" after the hyphen or slash without adding a space.
            joiner = '' if re.search(r'[A-Za-z0-9][-/]$', lines[-1]) and re.match(r'[A-Za-z0-9]', text) else ' '
            lines[-1] += joiner + text
        else:
            lines.append(text)
        previous = row
    return '\n'.join(lines)


def sections_from_layout(layout):
    """Section text from `pdf_safety.inspect_spans` layout. Pure, so it is testable without the worker."""
    pages = [page for page in layout if page.get('spans')]
    if not pages:
        raise ValueError(NOT_LINKEDIN)
    first = pages[0]
    # The name is the largest text on the first page and starts the main column.
    name_span = max(first['spans'], key=lambda s: s[3])
    if name_span[3] < 18:
        raise ValueError(NOT_LINKEDIN)
    split = name_span[0] - 20
    main, side = [], []
    for number, page in enumerate(pages):
        height = page['height']
        for x, y, w, h, text in page['spans']:
            if not text.strip():
                continue
            # Footer fragments ("Page", "1", "of", "2") sit in the bottom margin in small type.
            if y > height - 30 and h < 10:
                continue
            target = side if x < split else main
            # Offset each page so rows from different pages never merge.
            target.append((x, y + number * 10000, w, h, text))
    main_rows = [row for row in _rows(main) if not FOOTER.match(row['text'])]
    side_rows = [row for row in _rows(side) if not FOOTER.match(row['text'])]

    grouped, current, intro, seen_heading = {}, None, [], False
    for row in main_rows:
        key = MAIN_HEADINGS.get(row['text'].casefold())
        if key and row['h'] >= 14:
            current, seen_heading = key, True
            grouped.setdefault(current, [])
        elif not seen_heading:
            intro.append(row)
        elif current:
            grouped[current].append(row)
    if not seen_heading or not intro:
        raise ValueError(NOT_LINKEDIN)
    name = intro[0]['text']
    details = [row['text'] for row in intro[1:]]
    # Headline lines come first; LinkedIn prints the location on the last intro line.
    headline = ' '.join(details[:-1] if len(details) > 1 else details)
    location = details[-1] if len(details) > 1 else ''

    side_grouped, current = {}, None
    for row in side_rows:
        key = SIDE_HEADINGS.get(row['text'].casefold())
        if key and row['h'] >= 12.5:
            current = key
            side_grouped.setdefault(current, [])
        elif current:
            side_grouped[current].append(row)
    contact = ''.join(row['text'] for row in side_grouped.pop('contact', []))
    found = PROFILE_URL.search(contact)
    url = ''
    if found:
        url = 'https://www.' + re.sub(r'^(?:https?://)?(?:[a-z]{2,3}\.)?(?:www\.)?', '', found.group(0), flags=re.I) + '/'

    sections = {}
    if headline:
        sections['headline'] = headline
    sections['intro'] = '\n'.join(part for part in (name, headline, location) if part)
    for key, rows in grouped.items():
        text = _join(rows)
        if text:
            sections[key] = text
    for key, rows in side_grouped.items():
        text = '\n'.join(row['text'] for row in rows)
        if text:
            sections[key] = (sections[key] + '\n' + text) if key in sections else text
    return {'sections': sections, 'url': url, 'name': name}


def capture(parsed, file_name=''):
    """A bounded review capture with the same shape as the browser capture it replaces."""
    sections, budget, shortened = {}, TOTAL_LIMIT, []
    for key in ORDER + tuple(k for k in parsed['sections'] if k not in ORDER):
        text = parsed['sections'].get(key, '').strip()
        if not text or budget <= 0:
            if text:
                shortened.append(key)
            continue
        limit = min(SECTION_LIMIT, budget)
        if len(text) > limit:
            text = text[:limit].rsplit('\n', 1)[0] if '\n' in text[:limit] else text[:limit]
            shortened.append(key)
        sections[key] = text
        budget -= len(text)
    read = [key for key in sections if key not in ('headline', 'intro')]
    expected = ('about', 'experience', 'education', 'skills')
    limitations = LIMITATIONS
    if shortened:
        limitations += ' Shortened for review: ' + ', '.join(shortened) + '.'
    return {
        'source': 'pdf',
        'file': Path(file_name).name[:160],
        'url': parsed['url'],
        'captured_at': time.time(),
        'sections': sections,
        'unread_sections': [key for key in expected if key not in sections] + list(NEVER_EXPORTED),
        'limitations': limitations,
        'summary': 'Read ' + (', '.join(read) if read else 'your headline') + ' from your LinkedIn PDF.',
    }


def parse(raw, file_name=''):
    if not isinstance(raw, bytes) or len(raw) > MAX_BYTES:
        raise ValueError('Choose a LinkedIn PDF of 10 MB or less.')
    if not raw.startswith(b'%PDF-'):
        raise ValueError(NOT_LINKEDIN)
    from agents.pdf_safety import inspect_spans
    layout = inspect_spans(raw, MAX_TEXT)['layout']
    return capture(sections_from_layout(layout), file_name)


def parse_encoded(name, content):
    if not isinstance(name, str) or not name.strip() or len(name) > 160 or Path(name).suffix.lower() != '.pdf':
        raise ValueError('Choose the PDF you saved from your LinkedIn profile.')
    if not isinstance(content, str) or len(content) > MAX_ENCODED:
        raise ValueError('Choose a LinkedIn PDF of 10 MB or less.')
    try:
        raw = base64.b64decode(content, validate=True)
    except ValueError:
        raise ValueError('The PDF could not be read. Choose it again.') from None
    return parse(raw, name)
