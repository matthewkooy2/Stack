"""Measure job matching against hand-labeled persona/listing pairs.

Reports unsuitable jobs admitted and suitable jobs excluded for the pre-fix
matcher (frozen copy below) and the current matcher. No network or server.
Run: python3 tests/matching_eval.py [cases|heldout] [--json]
  cases   - synthetic listings written for this evaluation (default)
  heldout - original synthetic regression scenarios (historical CLI name)
"""
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from discovery.normalize import normalize, occupation_code, classify
from discovery.timeline import analyze, assess, timeline_includes

SETS = {'cases': 'tests/fixtures/matching_cases.json', 'heldout': 'tests/fixtures/matching_heldout.json'}
CASES = json.loads((ROOT / SETS['cases']).read_text())
TODAY = datetime.fromisoformat(CASES['today']).replace(tzinfo=timezone.utc).timestamp()


def legacy_fields(title, employment_type):
    """Frozen pre-fix normalization: employment-type spelling and title seniority."""
    kind = str(employment_type or 'Unknown').replace('_', ' ').title()
    kind = {'Full Time': 'Full-time', 'Part Time': 'Part-time', 'Contractor': 'Contract', 'Intern': 'Internship', 'Internship': 'Internship', 'Temporary': 'Temporary'}.get(kind, kind)
    seniority = 'Unknown'
    if re.search(r'\b(senior|sr\.?|lead|principal|staff)\b', title, re.I): seniority = 'Senior'
    elif re.search(r'\b(junior|entry[ -]level|new grad|graduate|apprentice|intern)\b', title, re.I): seniority = 'Entry-level'
    return {'employment_type': kind, 'seniority': seniority}


def listings(cases=CASES):
    jobs = {}
    if cases is not CASES:
        # The separate synthetic regression records use normalized field names.
        for key, record in cases['listings'].items():
            job = {**record, 'id': 'job_' + key.lower().ljust(32, '0')[:32], 'occupation': classify(record['title'])}
            job['timeline_analysis'] = analyze(job)
            job['_legacy'] = legacy_fields(job['title'], job.get('employment_type'))
            jobs[key] = job
        return jobs
    for key, raw in CASES['listings'].items():
        raw = dict(raw)
        adapter = raw.pop('adapter')
        mode = raw.get('mode')
        raw['mode'] = {'OnSite': 'On-site'}.get(mode, mode)
        raw['employment_type'] = {'FullTime': 'Full-time', 'PartTime': 'Part-time'}.get(raw.get('employment_type'), raw.get('employment_type'))
        comp = raw.get('compensation')
        if comp and adapter == 'ashby':
            comp['unit'] = str(comp['unit']).replace('1 ', '').lower()
        raw.setdefault('country', 'US')
        raw['url'] = f'https://example.com/jobs/{key}'
        raw['posted_at'] = TODAY - 86400
        job = normalize(raw, {'id': 'eval', 'name': raw['company'], 'adapter': adapter})
        job['timeline_analysis'] = analyze(job)
        job['_legacy'] = legacy_fields(job['title'], raw.get('employment_type'))
        jobs[key] = job
    return jobs


def legacy_matches(job, query, filters):
    """Frozen copy of discovery.normalize.matches before the matching rewrite."""
    if job.get('country') not in ('US', 'USA', 'United States'): return False
    title = job.get('title', '').lower()
    terms = query.lower().split()
    if terms and not all(t in title for t in terms):
        code = occupation_code(query)
        if not code or code != occupation_code(title): return False
    for key, field in [('mode', 'mode'), ('occupation', 'occupation'), ('experience', 'seniority'), ('employment_type', 'employment_type')]:
        if filters.get(key) and filters[key] != job.get(field): return False
    location = filters.get('location', '').lower()
    if location and location not in ('us', 'usa', 'united states') and location not in job.get('location', '').lower(): return False
    minimum = filters.get('salary_min', 0)
    if minimum:
        salary = job.get('compensation', {})
        if salary.get('estimated') or salary.get('unit') != filters.get('salary_period', 'year') or salary.get('currency') != 'USD' or (salary.get('max') or salary.get('min') or 0) < minimum: return False
    return True


def legacy_shown(job, persona):
    # The most favorable translation of a persona into the old app's inputs:
    # single-valued chips, no exclusions, education, or years.
    modes = persona.get('modes') or []
    types = persona.get('employment_types') or []
    stage = persona.get('stage', '')
    filters = {'location': persona.get('location', ''), 'mode': modes[0] if len(modes) == 1 else '',
               'employment_type': types[0] if len(types) == 1 else '',
               'experience': 'Entry-level' if stage in ('Student', 'Recent graduate') else '',
               'salary_min': persona.get('salary_min', 0), 'salary_period': persona.get('salary_period', 'year')}
    if not legacy_matches({**job, **job['_legacy']}, persona['roles'], filters): return False, None
    timeline = assess(job, {'graduation_month': persona.get('graduation_month', ''), 'available_from': ''})
    return timeline_includes(timeline, 'compatible'), None


def current_shown(job, persona):
    from discovery.matching import evaluate, facts, criteria
    view = dict(job)
    view['facts'] = facts(view)
    result = evaluate(view, criteria(persona, '', {}))
    return not result['excluded'], result


def score(fn, jobs, cases=CASES):
    rows = []
    for name, persona in cases['personas'].items():
        labels = cases['labels'][name]
        for key, job in jobs.items():
            label = labels.get(key, 'unsuitable')
            shown, result = fn(job, persona)
            confirmed = bool(result and result['verdict'] == 'match')
            rows.append({'persona': name, 'listing': key, 'title': job['title'], 'label': label, 'shown': shown, 'confirmed': confirmed if shown else False, 'result': result})
    def count(label, shown=None, confirmed=None):
        return [r for r in rows if r['label'] == label and (shown is None or r['shown'] == shown) and (confirmed is None or r['confirmed'] == confirmed)]
    return rows, {
        'pairs': len(rows),
        'suitable': len(count('suitable')), 'unknown': len(count('unknown')), 'unsuitable': len(count('unsuitable')),
        'unsuitable_admitted': count('unsuitable', True),
        'suitable_excluded': count('suitable', False),
        'unknown_excluded': count('unknown', False),
        'unknown_claimed_confirmed': count('unknown', True, True),
        'suitable_marked_uncertain': count('suitable', True, False),
    }


def summary(name, metrics, has_verdicts):
    print(f'\n== {name} ==')
    print(f"pairs {metrics['pairs']} (suitable {metrics['suitable']}, unknown {metrics['unknown']}, unsuitable {metrics['unsuitable']})")
    for key in ('unsuitable_admitted', 'suitable_excluded', 'unknown_excluded') + (('unknown_claimed_confirmed', 'suitable_marked_uncertain') if has_verdicts else ()):
        items = metrics[key]
        print(f'{key}: {len(items)}')
        for r in items:
            print(f"   {r['persona']:<26} {r['listing']} {r['title']}")


def main(name='cases'):
    cases = CASES if name == 'cases' else json.loads((ROOT / SETS[name]).read_text())
    with patch('discovery.timeline.date') as fake_date, patch('discovery.matching.date') as match_date, patch('time.time', return_value=TODAY):
        fake_date.today.return_value = match_date.today.return_value = datetime.fromtimestamp(TODAY, timezone.utc).date()
        jobs = listings(cases)
        _, before = score(legacy_shown, jobs, cases)
        summary(f'{name} - before: legacy matcher', before, False)
        rows, after = score(current_shown, jobs, cases)
        summary(f'{name} - after: current matcher', after, True)
        if '--json' in sys.argv:
            out = [{k: v for k, v in r.items() if k != 'result'} | {'checks': r['result']['checks'] if r['result'] else []} for r in rows if r['label'] != 'unsuitable' or r['shown']]
            print(json.dumps(out, indent=1, default=str))
        return before, after


if __name__ == '__main__':
    main(next((a for a in sys.argv[1:] if a in SETS), 'cases'))
