"""Run the existing deterministic discovery rules on a cache miss. No Jac or network."""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))

from discovery.card import card_view
from discovery.matching import (
    FACTS_VERSION, ROLES_VERSION, criteria, current_facts, evaluate, role_match, validate_preferences,
)
from discovery.normalize import digest, taxonomy, validate_filters
from discovery.ranking import encode_cursor, posting_label, rank
from discovery.timeline import VERSION, assess

CRITERIA_KEYS = (
    'roles location modes stage years education employment_types salary_min salary_period '
    'exclude_companies exclude_terms soft levels graduation_month available_from confirmed_only '
    'confirmed_level timeline sources notices'
).split()


def run(request, records):
    operation = request['op']
    if operation == 'cards':
        cards = []
        for job, fields in next(records):
            job.update(fields)
            cards.append(card_view(job, request['location']))
        return cards
    if operation == 'preferences':
        return validate_preferences(request['prefs'])
    profile = request['prefs']
    timeline = {k: profile[k] for k in ('graduation_month', 'available_from')}
    config = validate_filters(request['search']['query'], request['search']['filters'])
    filters = config['filters']
    if filters.get('any_role'):
        settings = criteria({**profile, 'roles': ''}, '', {k:v for k,v in filters.items() if k != 'any_role'})
        settings['sources']['roles'] = 'search'
    else:
        settings = criteria(profile, config['query'], filters)
    if operation == 'candidate_titles':
        roles = settings['roles_parsed']
        if not roles:
            return True
        return [title for title in records if not title or role_match(title, roles)['status'] != 'conflict']
    if operation == 'application_views':
        result = {}
        for entry in next(records):
            job = entry['job']
            job['timeline'] = assess(job, timeline)
            if not entry['retained']:
                job['posted'] = posting_label(job.get('posted_at', 0))
                job['facts'] = current_facts(job)
                job['match'] = evaluate(job, settings)
            result[job['id']] = job
        return result
    if operation == 'validate':
        return config
    fingerprint = digest(json.dumps([config, profile, timeline, FACTS_VERSION, VERSION, ROLES_VERSION], sort_keys=True))
    rows = []
    excluded = {}
    for job in records:
        if operation == 'rank':
            # A required role conflict is the first check and is deliberately absent
            # from the excluded-reason counts below. Skip all other work for it.
            if settings['roles_parsed'] and role_match(job.get('title', ''), settings['roles_parsed'])['status'] == 'conflict':
                continue
        job['posted'] = posting_label(job.get('posted_at', 0))
        job['facts'] = current_facts(job)
        job['timeline'] = assess(job, timeline)
        match = evaluate(job, settings)
        job['match'] = match
        if operation == 'detail':
            return job
        if match['excluded']:
            conflicts = [c['label'] for c in match['checks'] if c['required'] and c['status'] == 'conflict']
            if conflicts and conflicts[0] != 'Role':
                label = conflicts[0]
                excluded[label] = excluded.get(label, 0) + 1
            continue
        key = rank(job, filters['sort'])
        # Keep time- and profile-dependent values; format display fields on demand.
        fields = {k:job[k] for k in ('id', 'match', 'posted', 'timeline')}
        fields['timeline'] = {k:v for k,v in fields['timeline'].items() if k != 'evidence'}
        rows.append((key, {'_ranked':fields,'expires_at':job.get('expires_at',0)}))
    rows.sort(key=lambda row: row[0])
    timestamp = time.time()
    meta = {
        'total': len(rows), 'timeline_preferences': timeline, 'criteria': {k:settings[k] for k in CRITERIA_KEYS},
        'excluded': [{'reason':k,'count':v} for k,v in sorted(excluded.items(),key=lambda kv:-kv[1])],
        'sources': [], 'occupations': [x['name'] for x in taxonomy()], 'checked_at': timestamp, 'computed_at': timestamp,
    }
    print(json.dumps(meta), flush=True)
    for key, card in rows:
        print(encode_cursor(fingerprint, key), json.dumps(card, separators=(',', ':')), sep='\t')
    return None


if __name__ == '__main__':
    for line in sys.stdin:
        request = json.loads(line)
        if request['op'] == 'rank':
            records = map(json.loads, sys.stdin)
        else:
            records = iter(request.pop('records', ()))
        try:
            result = run(request, records)
        except ValueError as exc:
            for _ in records:
                pass
            result = {'error': str(exc)}
        if result is not None:
            print(json.dumps(result), flush=True)
