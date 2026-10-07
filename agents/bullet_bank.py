"""User-authored experience groups in the existing reviewed Resume record store."""
from copy import deepcopy
from agents.record_resume import validate_records

KIND = 'experience_bank'


def save_review(previous, name, source, records, confirmed, revision, now):
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 160:
        raise ValueError('Name this experience in 160 characters or less.')
    if not isinstance(source, str) or not 1 <= len(source.strip()) <= 500:
        raise ValueError('Describe the source of these facts in 500 characters or less.')
    checked = validate_records(records)
    if any(r['kind'] not in ('paragraph', 'bullet') for r in checked):
        raise ValueError('Use paragraphs or bullets for experience facts; the experience name supplies the heading.')
    snapshot = {'name': name.strip(), 'source': source.strip(), 'records': checked,
                'confirmed': confirmed, 'revision': revision + 1, 'saved_at': now}
    history = deepcopy(previous.get('history', []))
    if len(history) >= 100:
        raise ValueError('This experience has 100 revisions. Export it before creating a new group.')
    history.append(snapshot)
    return {**previous, 'kind': KIND, 'records': checked, 'source': source.strip(),
            'template': 'classic', 'original': deepcopy(previous.get('original', snapshot)),
            'history': history, 'confirmed_at': now if confirmed else 0.0}


def compose(base, selections, sources):
    """Resolve exact private, confirmed source revisions; never infer claims."""
    records = deepcopy(validate_records(base))
    if not isinstance(selections, list) or len(selections) > 100:
        raise ValueError('Choose up to 100 experience sources.')
    by_id = {s['id']: s for s in sources}
    seen, provenance = set(), []
    next_id = max(int(r['id'][1:]) for r in records) + 1
    for selection in selections:
        if not isinstance(selection, dict):
            raise ValueError('Invalid experience selection.')
        if (not isinstance(selection.get('id'), str) or not isinstance(selection.get('revision'), int)
                or isinstance(selection.get('revision'), bool)):
            raise ValueError('Invalid experience source or revision.')
        source = by_id.get(selection.get('id'))
        ids = selection.get('record_ids')
        if (not source or not source['confirmed'] or source['id'] in seen
                or source['revision'] != selection.get('revision')
                or not isinstance(ids, list) or not ids or any(not isinstance(rid, str) for rid in ids)
                or len(ids) != len(set(ids))):
            raise ValueError('Selected experience changed or is unavailable. Review your bullet bank selection again.')
        available = {r['id']: r for r in validate_records(source['records'])}
        if any(not isinstance(rid, str) or rid not in available for rid in ids):
            raise ValueError('A selected experience record is unavailable. Review your selection again.')
        seen.add(source['id'])
        records.append({'id': 'r' + str(next_id), 'kind': 'heading', 'text': source['name']})
        next_id += 1
        mapping = []
        included = []
        # Keep source order and grouping; selection does not rewrite a claim.
        # Imported paragraphs/headings can carry employer, dates or credentials.
        # Their semantics cannot be inferred reliably, so retain every non-bullet
        # context line in original order around the selected imported bullets.
        for original in source['records']:
            if original['id'] in ids or (not source.get('editable', True) and original['kind'] != 'bullet'):
                rid = 'r' + str(next_id)
                records.append({**original, 'id': rid})
                included.append(original)
                mapping.append({'id': rid, 'source_record_id': original['id']})
                next_id += 1
        provenance.append({'id': source['id'], 'name': source['name'],
                           'revision': source['revision'], 'source': source['source'],
                           'upload_digest': source.get('upload_digest', ''),
                           'confirmed_at': source.get('confirmed_at', 0.0),
                           'records': deepcopy(included),
                           'mapping': mapping})
    return {'records': validate_records(records), 'bank_sources': provenance}
