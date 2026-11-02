"""One account's confirmed memory as citable entries, shared by tailoring, interviews and stories.

The API collects the signed-in (or leased) account's own graph nodes and passes plain
dicts here; this module never reads storage, so it cannot cross an account boundary.
Unconfirmed drafts are reported as excluded instead of disappearing."""
import hashlib
import json
import re
from typing import Any

from agents.memory_bank import TYPES

SCHEMA_VERSION = 1
BANK_KIND = 'experience_bank'
STORY_FIELDS = ('situation', 'task', 'action', 'result', 'personal', 'team', 'learning')
# Fields rendered into an entry's fixed header; the rest stay citable lines.
HEADER_FIELDS = {
    'work_experience': ('job_title', 'employer', 'employment_type', 'location'),
    'project': ('role', 'organization'),
    'education': ('degree', 'field_of_study', 'institution', 'location'),
    'certification': ('issuer', 'credential_id'),
    'volunteering': ('role', 'organization', 'location'),
    'leadership': ('position', 'organization'),
    'research': ('role', 'institution'),
    'activity': ('role', 'organization'),
    'military_service': ('rank', 'branch', 'specialty', 'location'),
    'award': ('issuer', 'level'),
    'publication': ('publisher',),
    'coursework': ('institution', 'course_code'),
    'other': ('organization',),
}
DATE_FIELDS = (('start_date', 'end_date'), ('issued_date', 'expiration_date'), ('date', ''), ('term', ''))
STOP = set('the and for with that this from your you are will our has have was were been into over per not all any can may '
           'its their they them who what when where which while about across more most such than then also each other '
           'able work working role team using use used job new including include includes'.split())


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _clean(text: Any) -> str:
    return re.sub(r'\s+', ' ', str(text)).strip()


# Types whose header leads with "<title>, <organization>" when both are supplied.
TITLE_FIELDS = {'work_experience': ('job_title', 'employer'), 'volunteering': ('role', 'organization'),
                'leadership': ('position', 'organization'), 'research': ('role', 'institution'),
                'activity': ('role', 'organization'), 'military_service': ('rank', 'branch'),
                'education': ('degree', 'field_of_study', 'institution')}


def header(entry_type: str, name: str, fields: dict[str, str]) -> str:
    """Title, attribution and supplied dates; a missing end date is never shown as Present."""
    lead = TITLE_FIELDS.get(entry_type, ())
    if lead and fields.get(lead[0]) and fields.get(lead[-1]):
        parts, used = [', '.join(fields[k] for k in lead if fields.get(k))], set(lead)
    else:
        parts, used = [name], set()
    for k in HEADER_FIELDS.get(entry_type, ()):
        if k not in used and fields.get(k) and _clean(fields[k]).lower() not in ' '.join(parts).lower():
            parts.append(fields[k])
    for start, end in DATE_FIELDS:
        if fields.get(start) and start in {f['key'] for f in TYPES.get(entry_type, ('', []))[1]}:
            parts.append(fields[start] + (' – ' + fields[end] if end and fields.get(end) else ''))
            break
    else:
        if fields.get('end_date'):
            parts.append('Until ' + fields['end_date'])
    return ' · '.join(_clean(p) for p in parts if _clean(p))


def _bank_entry(r: dict[str, Any]) -> dict[str, Any]:
    entry_type = r.get('entry_type') or 'other'
    fields = {k: _clean(v) for k, v in (r.get('fields') or {}).items() if _clean(v)}
    labels = {f['key']: f['label'] for f in TYPES.get(entry_type, ('', []))[1]}
    shown = set(HEADER_FIELDS.get(entry_type, ()))
    lines = [{'id': 'name', 'role': 'name', 'text': _clean(r['name'])}]
    # Every field stays citable, including those also shown in the header.
    lines += [{'id': 'f.' + k, 'role': 'header' if k in shown else 'field', 'text': labels.get(k, k) + ': ' + v}
              for k, v in fields.items()]
    lines += [{'id': rec['id'], 'role': rec['kind'], 'text': _clean(rec['text'])} for rec in r.get('records', [])]
    return {'key': 'bank:' + r['id'], 'kind': 'bank', 'type': entry_type, 'name': _clean(r['name']),
            'header': header(entry_type, _clean(r['name']), fields), 'fields': fields, 'lines': lines,
            'revision': r.get('revision', 0), 'provenance': _clean(r.get('source', ''))[:500]}


def _resume_entry(r: dict[str, Any]) -> dict[str, Any]:
    return {'key': 'resume:' + r['id'], 'kind': 'resume', 'type': 'imported_resume', 'name': _clean(r['name']),
            'header': 'Confirmed resume: ' + _clean(r['name']), 'fields': {},
            'lines': [{'id': rec['id'], 'role': rec['kind'], 'text': _clean(rec['text'])} for rec in r.get('records', [])],
            'revision': r.get('revision', 0), 'provenance': 'User-confirmed imported resume records'}


def _fact_entry(f: dict[str, Any]) -> dict[str, Any]:
    values = [_clean(x) for x in str(f.get('value', '')).split('\n') if _clean(x)]
    return {'key': 'fact:' + str(f['key']), 'kind': 'fact', 'type': 'verified_fact', 'name': values[0][:160] if values else str(f['key']),
            'header': 'Verified fact: ' + str(f['key']), 'fields': {},
            'lines': [{'id': 'l' + str(i), 'role': 'fact', 'text': v} for i, v in enumerate(values)],
            'revision': digest(f), 'provenance': _clean(f.get('source', ''))[:500]}


def _story_entry(s: dict[str, Any]) -> dict[str, Any]:
    fields = (s.get('content') or {}).get('fields') or {}
    lines, seen = [], set()
    for name in STORY_FIELDS:
        quote = _clean((fields.get(name) or {}).get('quote', ''))
        if quote and quote not in seen:
            seen.add(quote)
            lines.append({'id': name, 'role': 'story', 'text': name.capitalize() + ': ' + quote})
    return {'key': 'story:' + s['id'], 'kind': 'story', 'type': 'behavioral_story', 'name': _clean(s['title']),
            'header': 'Reviewed story: ' + _clean(s['title']), 'fields': {}, 'lines': lines,
            'revision': s.get('revision', 0), 'provenance': 'User-reviewed behavioral story'}


def collect(owner: str, resumes: list[dict[str, Any]], facts: list[dict[str, Any]],
            stories: list[dict[str, Any]]) -> dict[str, Any]:
    """Every confirmed item, in stable order, with excluded drafts listed by name."""
    entries, excluded = [], []
    for r in resumes:
        bank = r.get('kind') == BANK_KIND
        key = ('bank:' if bank else 'resume:') + r['id']
        if not r.get('confirmed'):
            excluded.append({'key': key, 'name': _clean(r['name']), 'reason': 'Draft: confirm it to use it.'})
        elif bank:
            entries.append(_bank_entry(r))
        elif r.get('records'):
            entries.append(_resume_entry(r))
    for f in facts:
        if f.get('verified') and str(f.get('value', '')).strip():
            entries.append(_fact_entry(f))
        elif str(f.get('value', '')).strip():
            excluded.append({'key': 'fact:' + str(f.get('key', '')), 'name': str(f.get('key', '')), 'reason': 'Unverified fact.'})
    for s in stories:
        story = _story_entry(s)
        if story['lines']:
            entries.append(story)
    for e in entries:
        e['digest'] = digest({k: e[k] for k in ('key', 'type', 'name', 'header', 'lines', 'revision')})
    return {'schema_version': SCHEMA_VERSION, 'owner': owner, 'entries': entries, 'excluded': excluded,
            'digest': digest([e['digest'] for e in entries])}


def validate(snapshot: Any, owner: str) -> dict[str, Any]:
    """Worker-side check that a snapshot belongs to the leased account and is intact."""
    if (not isinstance(snapshot, dict) or snapshot.get('schema_version') != SCHEMA_VERSION
            or snapshot.get('owner') != owner or not isinstance(snapshot.get('entries'), list)):
        raise ValueError('Stack could not read your memory bank for this task. Retry the task.')
    for e in snapshot['entries']:
        if e.get('digest') != digest({k: e.get(k) for k in ('key', 'type', 'name', 'header', 'lines', 'revision')}):
            raise ValueError('Your memory bank changed while it was read. Retry the task.')
    if snapshot.get('digest') != digest([e['digest'] for e in snapshot['entries']]):
        raise ValueError('Your memory bank changed while it was read. Retry the task.')
    return snapshot


def words(text: str) -> set[str]:
    return {w for w in re.findall(r'[a-z][a-z0-9+#.]*[a-z0-9+#]|[a-z]', text.lower()) if len(w) > 2 and w not in STOP}


def relevance(entry: dict[str, Any], job: dict[str, Any]) -> float:
    """Deterministic keyword overlap with the listing, used only to order work, never to drop it."""
    wanted = words(' '.join(str(job.get(k, '')) for k in ('title', 'description', 'qualifications')))
    have = words(entry['header'] + ' ' + ' '.join(line['text'] for line in entry['lines']))
    return len(wanted & have) / (1 + len(wanted)) ** 0.5 if wanted else 0.0


def render(entry: dict[str, Any], handle: str, lines: list[dict[str, Any]] | None = None, part: str = '') -> str:
    """Compact citable text: one header line, then `<handle>.<line id> | text` per line."""
    label = TYPES.get(entry['type'], (entry['type'].replace('_', ' ').capitalize(),))[0]
    rows = ['## ' + handle + ' · ' + label + ' · ' + entry['header'] + (' (' + part + ')' if part else '')]
    rows += [handle + '.' + line['id'] + ' | ' + line['text'] for line in (entry['lines'] if lines is None else lines)]
    return '\n'.join(rows)


_GROUP = {'work_experience': 'workExperiences', 'project': 'projects', 'research': 'projects', 'leadership': 'workExperiences', 'volunteering': 'workExperiences',
          'military_service': 'workExperiences', 'behavioral_story': 'stories'}


def interview_facts(snapshot: dict[str, Any], job: dict[str, Any], budget: int = 6000,
                    skip: tuple[str, ...] = ()) -> dict[str, Any]:
    """Confirmed experience for interview questions and coaching, most job-relevant first.

    Interview turns re-send these facts, so they are bounded; `coverage` names every entry
    and whether it was included, so nothing is left out silently."""
    candidates = [e for e in snapshot['entries'] if e['type'] in _GROUP and e['key'] not in skip and e['kind'] != 'fact']
    ranked = sorted(candidates, key=lambda e: -relevance(e, job))
    facts, coverage, used = [], [], 0
    for e in ranked:
        value = '\n'.join([e['header']] + [line['text'] for line in e['lines'] if line['role'] not in ('name', 'header')])[:1500]
        if used + len(value) > budget or len(facts) >= 12:
            coverage.append({'key': e['key'], 'name': e['name'], 'included': False, 'reason': 'Lower relevance; interview context is bounded.'})
            continue
        used += len(value)
        facts.append({'key': 'resume.memory.' + digest(e['key'])[:12] + '.' + _GROUP[e['type']] + '.' + e['type'],
                      'value': value, 'verified': True, 'source': e['provenance'] or 'Confirmed memory bank entry',
                      'memory_key': e['key']})
        coverage.append({'key': e['key'], 'name': e['name'], 'included': True, 'reason': ''})
    return {'facts': facts, 'coverage': coverage, 'excluded': snapshot.get('excluded', [])}
