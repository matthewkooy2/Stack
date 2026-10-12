"""Editable resume details over Stack's independent structured parser.

The parser's output is kept as immutable evidence. Users edit a flat string map
(`profile.name`, `workExperiences.0.company`, ...) that is always replaced as a
whole. Nothing here trusts a parse: facts and confirmed records exist only after
an explicit confirmation, and any later draft withdraws them.
"""
import hashlib
import json
import re
from pathlib import Path
from typing import Any

MAX_TEXT = 60000
MAX_KEYS = 1500
MAX_SCALAR = 300
MAX_SUMMARY = 2000
MAX_LONG = 6000
MAX_BULLET = 1500
MAX_HISTORY = 100
PROFILE = ('name', 'email', 'phone', 'location', 'url', 'summary')
LONG = ('skills.descriptions', 'additional.descriptions')
GROUPS = {
    'educations': ('Education', ('school', 'degree', 'gpa', 'date', 'location', 'descriptions'), 20),
    'workExperiences': ('Work experience', ('company', 'jobTitle', 'date', 'location', 'descriptions'), 30),
    'projects': ('Project', ('project', 'date', 'descriptions'), 30),
}
LABELS = {
    'name': 'Name', 'email': 'Email', 'phone': 'Phone', 'location': 'Location', 'url': 'Link',
    'summary': 'Summary', 'school': 'School', 'degree': 'Degree', 'gpa': 'GPA', 'date': 'Date',
    'descriptions': 'Descriptions', 'company': 'Company', 'jobTitle': 'Job title', 'project': 'Project',
}
PARSER_KEYS = {'education': 'educations', 'workExperience': 'workExperiences', 'projects': 'projects'}
FIRST_FIELD = {'educations': 'school', 'workExperiences': 'company', 'projects': 'project'}
INDEXED = re.compile(r'^(educations|workExperiences|projects)\.(0|[1-9]\d{0,4})\.([A-Za-z]+)$')
CONTROL = re.compile(r'[\x00-\x08\x0b-\x1f\x7f]')
WARNINGS = {
    'COLUMN_ORDER_INFERRED': 'A multi-column layout was detected. Reading order was inferred; check that sections and entries are in the right place.',
    'INCOMPLETE_RECORD': 'An entry is missing its school, company or title, or project name. Complete or remove it.',
    'NO_EXTRACTABLE_TEXT': 'This document has no readable text layer. Scanned or image-only resumes are not supported and no OCR is performed.',
    'NO_LAYOUT': 'This format has no page geometry, so entry boundaries rely on text cues and blank lines. Check each entry.',
    'FIELDS_TRUNCATED': 'Some extracted text exceeded the editable limits and was shortened here. The complete original text remains available as source evidence.',
    'ENTRIES_TRUNCATED': 'More entries were found than can be edited. The complete original text remains available as source evidence.',
}
EXTRACTOR = 'pypdf text visitor in the bounded pdf_safety worker'


class DetailsError(ValueError):
    pass


def definitions():
    """Field definitions so a client can add entries when a parse found none."""
    return [{'key': 'profile', 'label': 'Profile', 'repeatable': False, 'max': 1,
             'fields': [{'key': 'profile.' + f, 'name': f, 'label': LABELS[f], 'multiline': f == 'summary'} for f in PROFILE]}] + [
        {'key': group, 'label': label, 'repeatable': True, 'max': limit,
         'fields': [{'key': group + '.{n}.' + f, 'name': f, 'label': LABELS.get(f, f.title()),
                     'multiline': f == 'descriptions'} for f in fields]}
        for group, (label, fields, limit) in GROUPS.items()
    ] + [{'key': 'skills', 'label': 'Skills', 'repeatable': False, 'max': 1,
          'fields': [{'key': 'skills.descriptions', 'name': 'descriptions', 'label': 'Skills', 'multiline': True}]},
         {'key': 'additional', 'label': 'Additional', 'repeatable': False, 'max': 1,
          'fields': [{'key': 'additional.descriptions', 'name': 'descriptions', 'label': 'Additional', 'multiline': True}]}]


def _limit(key):
    field = key.rsplit('.', 1)[-1]
    if key == 'profile.summary':
        return MAX_SUMMARY
    return MAX_LONG if field == 'descriptions' else MAX_SCALAR


def _clean(value, multiline):
    value = CONTROL.sub('', str(value).replace('\r\n', '\n').replace('\r', '\n').replace('\t', ' '))
    if multiline:
        return [re.sub(r'[ ]+', ' ', line).strip() for line in value.split('\n') if line.strip()]
    return re.sub(r'\s+', ' ', value).strip()


def normalize(values, strict=True):
    """Canonical flat map: full replacement, contiguous indices, every field present.

    strict raises for caller mistakes. Non-strict (parser output only) truncates to
    the same bounds and reports what happened, because the user did not cause it.
    """
    if not isinstance(values, dict):
        raise DetailsError('Send the complete resume details as a map of field names to text.')
    if strict and len(values) > MAX_KEYS:
        raise DetailsError('Resume details have too many fields.')
    entries = {group: {} for group in GROUPS}
    singles = {}
    for key, value in values.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise DetailsError('Every resume detail needs a text field name and text value.')
        match = INDEXED.match(key)
        if match:
            group, index, field = match.groups()
            if field not in GROUPS[group][1]:
                raise DetailsError('Unknown resume field: ' + key[:60])
            entries[group].setdefault(int(index), {})[field] = value
        elif key in ['profile.' + f for f in PROFILE] or key in LONG:
            singles[key] = value
        else:
            raise DetailsError('Unknown resume field: ' + key[:60])
    result, truncated, dropped = {}, False, False

    def keep(key, value):
        nonlocal truncated
        multiline = key.endswith('descriptions') or key == 'profile.summary'
        cleaned = _clean(value, multiline)
        limit, text = _limit(key), cleaned
        if multiline:
            lines = []
            for line in cleaned:
                if key != 'profile.summary' and len(line) > MAX_BULLET:
                    if strict:
                        raise DetailsError('Keep each description under %d characters.' % MAX_BULLET)
                    line, truncated = line[:MAX_BULLET].rstrip(), True
                lines.append(line)
            text = '\n'.join(lines)
            while len(text) > limit and not strict and lines:
                lines.pop()
                text, truncated = '\n'.join(lines), True
        elif len(text) > limit and not strict:
            text, truncated = text[:limit].rstrip(), True
        if len(text) > limit:
            raise DetailsError('%s is longer than %d characters.' % (LABELS.get(key.rsplit('.', 1)[-1], key), limit))
        return text

    for field in PROFILE:
        key = 'profile.' + field
        result[key] = keep(key, singles.get(key, ''))
    for group, (label, fields, limit) in GROUPS.items():
        rows = []
        for index in sorted(entries[group]):
            row = {f: keep('%s.0.%s' % (group, f), entries[group][index].get(f, '')) for f in fields}
            if any(row.values()):
                rows.append(row)
        if len(rows) > limit:
            if strict:
                raise DetailsError('Keep at most %d %s entries.' % (limit, label.lower()))
            rows, dropped = rows[:limit], True
        for n, row in enumerate(rows):
            for f in fields:
                result['%s.%d.%s' % (group, n, f)] = row[f]
    for key in LONG:
        result[key] = keep(key, singles.get(key, ''))
    if sum(map(len, result.values())) > MAX_TEXT:
        raise DetailsError('Resume details exceed %d characters.' % MAX_TEXT)
    if strict and any(result.values()):
        # The advertised aggregate limits cover the compatibility projection,
        # including labels and separators. Reject an unconfirmable draft now.
        try:
            records_from(result)
        except ValueError as error:
            raise DetailsError('Resume details exceed the reviewed-record limits: ' + str(error)) from None
    return (result, truncated, dropped) if not strict else result


def flat_values(resume):
    """Map the parser's `resume` object to the flat contract (empty strings for unknown)."""
    values = {}
    profile = resume['profile']
    for field in PROFILE:
        values['profile.' + field] = profile['link' if field == 'url' else field]
    for source, group in PARSER_KEYS.items():
        for index, record in enumerate(resume[source]):
            for field in GROUPS[group][1]:
                value = record.get(field, '')
                values['%s.%d.%s' % (group, index, field)] = '\n'.join(value) if isinstance(value, list) else value
    values['skills.descriptions'] = '\n'.join(resume['skills']['descriptions'])
    values['additional.descriptions'] = '\n'.join(resume['unclassified'])
    return values


def flat_key(pointer):
    """Translate a parser JSON pointer into its flat key and, for descriptions, the item index."""
    parts = pointer.strip('/').split('/')
    if parts[:2] == ['resume', 'profile']:
        if len(parts) == 3:
            return 'profile.' + ('url' if parts[2] == 'link' else parts[2]), None
        return 'profile.links.' + parts[3], None
    if parts[:2] == ['resume', 'skills']:
        return 'skills.descriptions', int(parts[3])
    if parts[:2] == ['resume', 'unclassified']:
        return 'additional.descriptions', int(parts[2])
    group = PARSER_KEYS.get(parts[1])
    if group and len(parts) >= 4:
        item = int(parts[4]) if len(parts) == 5 and parts[3] == 'descriptions' else None
        return '%s.%s.%s' % (group, parts[2], parts[3]), item
    return None, None


def _evidence(result):
    grouped = {}
    for pointer, item in result['recordEvidence'].items():
        key, index = flat_key(pointer)
        if key is None:
            continue
        ranges = [{'lineId': r['lineId'], 'lineRange': r['lineRange'], 'sourceSpanIds': r['sourceSpanIds']}
                  for r in item['sourceRanges']]
        entry = {'confidence': item['confidence'], 'reason': item['reason'], 'separator': item['separator'],
                 'sourceSpanIds': item['sourceSpanIds'], 'sourceRanges': ranges}
        grouped.setdefault(key, []).append((-1 if index is None else index, entry))
    return {key: [entry for _, entry in sorted(items, key=lambda x: x[0])] for key, items in grouped.items()}


def _lines(result):
    lines = [line for blocks in result['sections'].values() for block in blocks for line in block['lines']]
    lines.sort(key=lambda l: (l['page'], int(l['id'].rsplit('l', 1)[1])))
    return lines


def build(extracted, layout_note=''):
    """Run the independent parser on page spans and return the immutable original document."""
    from agents.resume_parser import structure, PARSER_NAME, PARSER_VERSION
    result = structure(extracted)
    lines = _lines(result)
    text = '\n'.join(line['text'] for line in lines)
    if not text.strip():
        raise DetailsError(WARNINGS['NO_EXTRACTABLE_TEXT'])
    if len(text) > MAX_TEXT:
        raise DetailsError('Resume text exceeds the supported limit.')
    original_values = flat_values(result['resume'])
    values, truncated, dropped = normalize(original_values, strict=False)
    warnings = [{**w, 'message': WARNINGS.get(w['code'], w.get('message', w['code']))} for w in result['warnings']]
    if layout_note:
        warnings.append({'code': layout_note, 'message': WARNINGS[layout_note]})
    for flag, code in ((truncated, 'FIELDS_TRUNCATED'), (dropped, 'ENTRIES_TRUNCATED')):
        if flag:
            warnings.append({'code': code, 'message': WARNINGS[code]})
    evidence = _evidence(result)
    spans = {s['id']: s for page in extracted['pages'] for s in page['spans']}
    used = {sid for line in lines for sid in line['sourceSpanIds']}
    return {
        'parser': {'name': PARSER_NAME, 'version': PARSER_VERSION, 'extractor': EXTRACTOR, 'schema': 2},
        'values': original_values, 'editable_values': values, 'evidence': evidence, 'warnings': warnings, 'text': text,
        'lines': [{'id': l['id'], 'text': l['text'], 'page': l['page'], 'region': l['region']} for l in lines],
        'spans': [[sid, spans[sid]['text']] + [round(v, 2) for v in spans[sid]['bbox']] for sid in spans if sid in used],
        'pages': [{'number': p['number'], 'width': p['width'], 'height': p['height']} for p in extracted['pages']],
        'digest': hashlib.sha256(json.dumps(original_values, sort_keys=True).encode()).hexdigest(),
    }


def spans_from_layout(layout):
    return {'pages': [{'number': n, 'width': page['width'], 'height': page['height'],
                       'spans': [{'id': 'p%ds%d' % (n, i), 'text': t, 'bbox': [x, y, w, h],
                                  'direction': 'ltr', 'endOfLine': False}
                                 for i, (x, y, w, h, t) in enumerate(page['spans'])]}
                      for n, page in enumerate(layout, 1)]}


def spans_from_lines(lines):
    """DOCX has paragraphs, not geometry: one row per paragraph, a taller gap at blank lines."""
    spans, y = [], 40.0
    for text in lines:
        text = re.sub(r'\s+', ' ', text).strip()
        if text:
            spans.append({'id': 'p1s%d' % len(spans), 'text': text, 'bbox': [40.0, y, 6.0 * len(text), 11.0],
                          'direction': 'ltr', 'endOfLine': False})
            y += 14.0
        else:
            y += 14.0
    return {'pages': [{'number': 1, 'width': 612.0, 'height': max(792.0, y + 40.0), 'spans': spans}]}


def parse_pdf(raw):
    from agents import pdf_safety
    layout = pdf_safety.inspect_spans(raw, MAX_TEXT)['layout']
    if not any(s[4].strip() for page in layout for s in page['spans']):
        raise DetailsError(WARNINGS['NO_EXTRACTABLE_TEXT'] + ' Upload a text-based PDF.')
    return build(spans_from_layout(layout))


def parse_docx(raw):
    from agents.record_resume import inspect_docx
    return build(spans_from_lines(inspect_docx(raw)), 'NO_LAYOUT')


def parse(name, raw):
    return parse_docx(raw) if Path(name).suffix.lower() == '.docx' else parse_pdf(raw)


def reconstruct(original, key):
    """Rebuild an original field value from stored line text and its evidence."""
    lines = {l['id']: l['text'] for l in original['lines']}
    pieces = []
    for item in original['evidence'].get(key, []):
        pieces.append(item['separator'].join(lines[r['lineId']][r['lineRange'][0]:r['lineRange'][1]]
                                              for r in item['sourceRanges']))
    return '\n'.join(pieces)


def new_details(original):
    """Stored shape: `original` never changes; `values` is the user's current version."""
    return {'original': original, 'values': dict(original.get('editable_values', original['values'])), 'original_values': dict(original['values']),
            'history': [], 'confirmed': False, 'confirmed_at': 0.0}


def empty_original():
    return {'parser': None, 'values': normalize({}), 'evidence': {}, 'warnings': [], 'text': '', 'lines': [],
            'spans': [], 'pages': [], 'digest': ''}


def provenance(values, original_values):
    """Match each current entry to the original entry it most resembles, field by field.

    Matching compares unchanged non-empty field values, so it survives reorder and
    deletion. An entry rewritten in every field has no origin. This is an aid for
    showing evidence; `original_values` and the stored evidence remain authoritative.
    """
    out = {}
    for group, (label, fields, limit) in GROUPS.items():
        def rows(source):
            found = {}
            for key, value in source.items():
                match = INDEXED.match(key)
                if match and match.group(1) == group:
                    found.setdefault(int(match.group(2)), {})[match.group(3)] = value
            return found
        current, original, taken = rows(values), rows(original_values), set()
        scores = sorted(((sum(1 for f in fields if row.get(f) and row.get(f) == old.get(f)), -abs(i - j), i, j)
                         for i, row in current.items() for j, old in original.items()), reverse=True)
        assigned = {}
        for score, _, i, j in scores:
            if score and i not in assigned and j not in taken:
                assigned[i] = j
                taken.add(j)
        for i, row in current.items():
            key = '%s.%d' % (group, i)
            if i in assigned:
                old = original[assigned[i]]
                out[key] = {'origin': '%s.%d' % (group, assigned[i]),
                            'edited': [f for f in fields if row.get(f, '') != old.get(f, '')]}
            else:
                out[key] = {'origin': '', 'edited': []}
    return out


def sections(values):
    result = [{'key': 'profile', 'group': 'profile', 'index': 0, 'label': 'Profile',
               'summary': values.get('profile.name', ''),
               'fields': [{'key': 'profile.' + f, 'label': LABELS[f], 'value': values.get('profile.' + f, '')}
                          for f in PROFILE]}]
    for group, (label, fields, limit) in GROUPS.items():
        count = len({int(INDEXED.match(k).group(2)) for k in values if INDEXED.match(k) and k.startswith(group + '.')})
        for n in range(count):
            first = values.get('%s.%d.%s' % (group, n, FIRST_FIELD[group]), '')
            result.append({'key': '%s.%d' % (group, n), 'group': group, 'index': n,
                           'label': '%s %d' % (label, n + 1), 'summary': first or values.get('%s.%d.%s' % (group, n, fields[1]), ''),
                           'fields': [{'key': '%s.%d.%s' % (group, n, f), 'label': LABELS.get(f, f),
                                       'value': values.get('%s.%d.%s' % (group, n, f), '')} for f in fields]})
    for key, label in (('skills', 'Skills'), ('additional', 'Additional')):
        value = values.get(key + '.descriptions', '')
        result.append({'key': key, 'group': key, 'index': 0, 'label': label,
                       'summary': value.split('\n')[0] if value else '',
                       'fields': [{'key': key + '.descriptions', 'label': label, 'value': value}]})
    return result


def view(review):
    """Editable-sections view. Never mutates stored data; `values` is always complete."""
    details = review.get('details')
    structured = isinstance(details, dict)
    original = details['original'] if structured else empty_original()
    values = details['values'] if structured else original['values']
    original_values = details['original_values'] if structured else original['values']
    history = details.get('history', []) if structured else []
    return {
        'sections': sections(values), 'definitions': definitions(), 'limits': limits(),
        'values': values, 'original_values': original_values,
        'evidence': original['evidence'], 'provenance': {},
        'source': {'lines': original['lines'], 'spans': original['spans'], 'pages': original['pages']},
        'parser': original['parser'], 'text': original['text'], 'warnings': original['warnings'],
        'details_status': 'ready' if structured else (review.get('details_error') and 'unavailable' or 'pending'),
        'details_error': review.get('details_error', ''),
        'details_confirmed': bool(structured and details.get('confirmed')),
        'details_history': [{k: v for k, v in h.items() if k != 'values'} for h in history],
    }


def limits():
    return {'groups': {g: lim for g, (_, _, lim) in GROUPS.items()}, 'scalar': MAX_SCALAR, 'summary': MAX_SUMMARY,
            'descriptions': MAX_LONG, 'bullet': MAX_BULLET, 'text': MAX_TEXT, 'history': MAX_HISTORY,
            'projection_records': 300, 'projection_text': MAX_TEXT, 'text_includes_projection': True}


def records_from(values):
    """Deterministic projection of confirmed details onto reviewed text records."""
    from agents.record_resume import validate_records
    records = []

    def add(kind, text, pack=False):
        if text and text.strip():
            text = text.strip()
            # Pack adjacent lines without omitting text, within the raw-record
            # lane's per-record bound. Hundreds of short skill/bullet lines fit.
            if pack and records and records[-1]['kind'] == kind and len(records[-1]['text']) + len(text) + 1 <= 2000:
                records[-1]['text'] += '\n' + text
            else:
                records.append({'id': 'r%d' % len(records), 'kind': kind, 'text': text})

    add('title', values.get('profile.name', ''))
    add('paragraph', ' | '.join(v for v in (values.get('profile.' + f, '') for f in ('email', 'phone', 'url', 'location')) if v))
    if values.get('profile.summary'):
        add('heading', 'Summary')
        for line in values['profile.summary'].split('\n'):
            add('paragraph', line)
    for group, (label, fields, limit) in GROUPS.items():
        rows = sorted({int(INDEXED.match(k).group(2)) for k in values if INDEXED.match(k) and k.startswith(group + '.')})
        for position, n in enumerate(rows):
            get = lambda f: values.get('%s.%d.%s' % (group, n, f), '')
            if position == 0:
                add('heading', {'educations': 'Education', 'workExperiences': 'Experience', 'projects': 'Projects'}[group])
            head = [get(f) for f in fields if f not in ('descriptions', 'gpa') and get(f)]
            if get('gpa'):
                head.insert(2 if group == 'educations' and len(head) > 1 else len(head), 'GPA: ' + get('gpa'))
            add('paragraph', ' | '.join(head))
            for line in get('descriptions').split('\n'):
                add('bullet', line)
    for key, label in (('skills', 'Skills'), ('additional', 'Additional')):
        if values.get(key + '.descriptions'):
            add('heading', label)
            for line in values[key + '.descriptions'].split('\n'):
                add('paragraph', line, pack=True)
    return validate_records(records)


def facts_for(resume_id: str, name: str, values: dict[str, Any]) -> list[dict[str, Any]]:
    """One verified fact per non-empty profile field and per entry; only built on confirmation."""
    source = 'Confirmed resume details: ' + name
    prefix = 'resume.' + resume_id + '.'
    facts = []
    for field in PROFILE:
        if values.get('profile.' + field):
            facts.append({'key': prefix + 'profile.' + field, 'value': values['profile.' + field]})
    for group, (label, fields, limit) in GROUPS.items():
        rows = sorted({int(INDEXED.match(k).group(2)) for k in values if INDEXED.match(k) and k.startswith(group + '.')})
        for n in rows:
            parts = ['%s: %s' % (LABELS.get(f, f), values['%s.%d.%s' % (group, n, f)])
                     for f in fields if values.get('%s.%d.%s' % (group, n, f))]
            if parts:
                facts.append({'key': '%s%s.%d' % (prefix, group, n), 'value': '\n'.join(parts)})
    for key in LONG:
        if values.get(key):
            facts.append({'key': prefix + key, 'value': values[key]})
    return [{**f, 'source': source, 'verified': True, 'resume_id': resume_id} for f in facts]


def is_resume_fact(fact, resume_id):
    return str(fact.get('key', '')).startswith('resume.' + resume_id + '.') or (
        str(fact.get('key', '')).startswith('resume.') and fact.get('resume_id') == resume_id)


def save(review: dict[str, Any], raw_values: dict[str, Any], confirm: bool,
         revision: int, now: float, name: str) -> dict[str, Any]:
    """Return (new review, confirmed). Raises DetailsError without side effects."""
    details = review.get('details')
    if not isinstance(details, dict):
        details = new_details(empty_original())
    values = normalize(raw_values)
    history = list(details.get('history', []))
    if len(history) >= MAX_HISTORY:
        raise DetailsError('This resume has %d detail revisions. Export before making more changes.' % MAX_HISTORY)
    entry = {'revision': revision + 1, 'at': now, 'confirmed': bool(confirm),
             'source': 'User-edited details: ' + name, 'values': values}
    updated = {**details, 'values': values, 'confirmed': bool(confirm),
               'confirmed_at': now if confirm else 0.0, 'history': history + [entry]}
    new = {**review, 'details': updated, 'values': values}
    new.pop('details_error', None)
    if confirm:
        records = records_from(values)
        record_history = list(review.get('record_history', []))
        if len(record_history) >= 100:
            raise DetailsError('This resume has 100 record revisions. Export before confirming new details.')
        if not record_history and review.get('records'):
            record_history = [{'revision': revision, 'records': review['records'], 'confirmed': False,
                               'source': 'Previously reviewed import: ' + name, 'saved_at': review.get('confirmed_at', 0.0)}]
        new.update({'records': records, 'records_source': 'details', 'confirmed_at': now,
                    'record_history': record_history + [{'revision': revision + 1, 'records': records, 'confirmed': True,
                                                         'source': 'User-confirmed resume details: ' + name, 'saved_at': now}]})
        new.setdefault('template', 'classic')
    return new


def _original_from_worker(value):
    """Rebuild the immutable original from worker output, keeping only known, bounded fields."""
    if not isinstance(value, dict):
        raise DetailsError('Structured details were not produced for this resume.')
    values = value.get('values')
    if (not isinstance(values, dict) or len(values) > 20000
            or any(not isinstance(k, str) or not isinstance(v, str) or len(v) > MAX_TEXT for k, v in values.items())):
        raise DetailsError('Structured details exceed the supported limit.')
    editable, _, _ = normalize(values, strict=False)
    text = value.get('text')
    if not isinstance(text, str) or len(text) > MAX_TEXT:
        raise DetailsError('Structured details exceed the supported limit.')
    lists = {}
    for key in ('warnings', 'lines', 'spans', 'pages'):
        item = value.get(key)
        if not isinstance(item, list) or len(item) > 20000:
            raise DetailsError('Structured details exceed the supported limit.')
        lists[key] = item
    evidence = value.get('evidence')
    parser = value.get('parser')
    if not isinstance(evidence, dict) or not isinstance(parser, dict):
        raise DetailsError('Structured details were not produced for this resume.')
    original = {'parser': {k: str(parser.get(k, ''))[:120] for k in ('name', 'version', 'extractor')} | {'schema': 2},
                'values': values, 'editable_values': editable, 'evidence': evidence, 'text': text, **lists,
                'digest': hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()}
    if len(json.dumps(original, ensure_ascii=False)) > 3 * 1024 * 1024:
        raise DetailsError('Structured details exceed the supported limit.')
    return original


def attach_import(review, result, records, upload_digest):
    """Merge a finished import into a review. Returns (review, replaced_records).

    A first import sets the raw records. A re-parse of an older upload may only add
    structured details; it never replaces reviewed, edited or confirmed records, and
    never replaces details that already exist. Parsing never confirms anything.
    """
    new = dict(review)
    first = not review.get('records')
    if first:
        new.update({'records': records, 'imported_records': records, 'template': 'classic',
                    'upload_digest': upload_digest, 'records_source': 'import'})
    if isinstance(review.get('details'), dict):
        return new, first
    try:
        if result.get('details') is None:
            raise DetailsError(str(result.get('details_error') or 'Structured details were not produced for this resume.')[:300])
        details = new_details(_original_from_worker(result['details']))
        # Older reviews store user corrections directly in the flat values map.
        # Re-parsing supplies original evidence, never permission to discard edits
        # or infer structured confirmation from a raw-record confirmation.
        if 'values' in review:
            details['values'] = normalize(review['values'])
            details['legacy_values'] = dict(review['values'])
        new['details'] = details
        new['values'] = details['values']
        new.pop('details_error', None)
    except DetailsError as error:
        new['details_error'] = str(error)[:300]
    return new, first
