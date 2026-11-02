"""Typed, user-authored resume inputs; definitions are also the client contract."""
from copy import deepcopy
from typing import Any


def _field(key, label, input='text', required=False):
    return {'key': key, 'label': label, 'input': input,
            'required_on_confirm': required, 'max_length': 1500}


DATES = [_field('start_date', 'Start date', 'month'), _field('end_date', 'End date', 'month')]
LINK = _field('url', 'Link', 'url')
TYPES = {
    'work_experience': ('Work experience', [
        _field('employer', 'Employer', required=True), _field('job_title', 'Job title', required=True),
        _field('start_date', 'Start date', 'month', True), DATES[1],
        _field('location', 'Location'), _field('employment_type', 'Employment type'), LINK]),
    'project': ('Project', [_field('role', 'Role'), _field('organization', 'Organization'),
        *DATES, _field('technologies', 'Technologies'), LINK, _field('repository_url', 'Repository link', 'url')]),
    'skill': ('Skill', [_field('category', 'Category'), _field('proficiency', 'Proficiency'),
        _field('years_used', 'Years used'), _field('last_used', 'Last used', 'month'), LINK]),
    'education': ('Education', [_field('institution', 'Institution', required=True),
        _field('degree', 'Degree'), _field('field_of_study', 'Field of study'), *DATES,
        _field('gpa', 'GPA'), _field('honors', 'Honors'), _field('location', 'Location'), LINK]),
    'coursework': ('Coursework / courseload', [_field('institution', 'Institution'),
        _field('course_code', 'Course code'), _field('term', 'Term'), _field('credits', 'Credits'),
        _field('grade', 'Grade'), _field('topics', 'Courses / topics', 'textarea'), LINK]),
    'certification': ('Certification / license', [_field('issuer', 'Issuer', required=True),
        _field('issued_date', 'Issued date', 'month'), _field('expiration_date', 'Expiration date', 'month'),
        _field('credential_id', 'Credential ID'), LINK]),
    'volunteering': ('Volunteering / service', [_field('organization', 'Organization', required=True),
        _field('role', 'Role'), *DATES, _field('location', 'Location'), LINK]),
    'leadership': ('Leadership', [_field('organization', 'Organization'),
        _field('position', 'Position', required=True), *DATES, LINK]),
    'award': ('Award / scholarship', [_field('issuer', 'Issuer'), _field('date', 'Date', 'month'),
        _field('level', 'Level'), _field('criteria', 'Criteria', 'textarea'), LINK]),
    'publication': ('Publication / presentation', [_field('authors', 'Authors'),
        _field('publisher', 'Publisher / venue'), _field('date', 'Date', 'month'),
        _field('doi', 'DOI'), LINK]),
    'research': ('Research', [_field('institution', 'Institution / lab'), _field('role', 'Role'),
        _field('supervisor', 'Supervisor'), *DATES, _field('methods', 'Methods'), LINK]),
    'language': ('Language', [_field('proficiency', 'Proficiency', required=True),
        _field('assessment', 'Assessment / credential'), _field('score', 'Score')]),
    'activity': ('Activity / membership', [_field('organization', 'Organization'),
        _field('role', 'Role'), *DATES, LINK]),
    'military_service': ('Military service', [_field('branch', 'Branch', required=True),
        _field('rank', 'Rank'), _field('specialty', 'Specialty'), *DATES, _field('location', 'Location')]),
    'other': ('Other resume content', [_field('organization', 'Organization'), *DATES, LINK]),
}


def definitions() -> list[dict[str, Any]]:
    return [{'key': key, 'label': label, 'fields': deepcopy(fields)}
            for key, (label, fields) in TYPES.items()]


def normalize(entry_type, fields, confirmed):
    if entry_type not in TYPES:
        raise ValueError('Choose a supported memory bank entry type.')
    if not isinstance(fields, dict):
        raise ValueError('Send the entry fields as a map of field names to text.')
    allowed = {f['key']: f for f in TYPES[entry_type][1]}
    if fields.keys() - allowed.keys():
        raise ValueError('Use the fields defined for this entry type.')
    result = {}
    for key, value in fields.items():
        if not isinstance(value, str) or len(value) > allowed[key]['max_length']:
            raise ValueError('Keep each memory bank field to 1,500 text characters or less.')
        if value.strip():
            result[key] = value.strip()
    if confirmed:
        missing = [f['label'] for f in allowed.values() if f['required_on_confirm'] and not result.get(f['key'])]
        if missing:
            raise ValueError('Complete these fields before confirming: ' + ', '.join(missing) + '.')
    return result


def context_lines(source: dict[str, Any]) -> list[str]:
    """Keep supplied context with selected claims, without inferring missing values."""
    entry_type = source.get('entry_type', 'other')
    fields = source.get('fields', {})
    return [f['label'] + ': ' + fields[f['key']]
            for f in TYPES.get(entry_type, ('', []))[1] if fields.get(f['key'])]
