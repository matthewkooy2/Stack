"""Synthetic expectations authored before benchmark execution; no scorer-derived score labels."""

def records(bullets, role='Software Engineer', section='Experience', skills='', education='', name='Alex Candidate'):
    rows = [('title', name), ('heading', section),
            ('paragraph', role + ' | Example Co | Jan 2020 - Jan 2026')]
    rows += [('bullet', b) for b in bullets]
    if skills:
        rows += [('heading', 'Skills'), ('paragraph', skills)]
    if education:
        rows += [('heading', 'Education'), ('paragraph', education)]
    return [{'id': 'r' + str(i), 'kind': k, 'text': t} for i, (k, t) in enumerate(rows)]

CASES = []
PAIRS = []

def add(key, text, req, checks, **kwargs):
    CASES.append({'id': key, 'records': records(text, **kwargs),
                  'job': {'title': 'Software Engineer', 'description': 'Requirements:\n' + req},
                  'checks': checks})

# Each check: requirement name, supported by confirmed facts?, mandatory?
for skill in ['Python', 'Docker', 'Kubernetes', 'PostgreSQL', 'JavaScript', 'Terraform']:
    slug = skill.lower()
    req = '- Experience with ' + skill + '.'
    add(slug+'_applied', ['Built production systems using '+skill+'.'], req, [(skill, True, True)])
    add(slug+'_absent', ['Prepared schedules and coordinated office meetings.'], req, [(skill, False, True)])
    add(slug+'_negated', ['Never used '+skill+' in production.'], req, [(skill, False, True)])
    add(slug+'_listed', ['Prepared schedules.'], req, [(skill, True, True)], skills=skill)
    PAIRS += [(slug+'_applied', slug+'_absent'), (slug+'_applied', slug+'_listed'),
              (slug+'_listed', slug+'_negated')]

add('negation_not_only', ['Not only built Python services but also maintained them.'],
    '- Experience with Python.', [('Python', True, True)])
add('negation_clause_scope', ['Never used Docker. Built Python APIs.'],
    '- Experience with Python and Docker.', [('Python', True, True), ('Docker', False, True)])
add('contact_false_positive', ['Maintained office schedules.'], '- Experience with Python.',
    [('Python', False, True)], name='Python Candidate')
add('contact_mixed_claim', ['Built Python APIs; see https://example.com/projects for examples.'],
    '- Experience with Python.', [('Python', True, True)])
add('coursework', ['Prepared schedules.'], '- Experience with Python.',
    [('Python', True, True)], education='Coursework: Python programming')
add('alias_postgres', ['Optimized Postgres queries.'], '- Experience with PostgreSQL.', [('PostgreSQL', True, True)])
add('alias_k8s', ['Deployed services on k8s.'], '- Experience with Kubernetes.', [('Kubernetes', True, True)])
add('alternative', ['Built services in Go.'], '- Proficiency in Java, Go, or Rust.', [('Java, Go or Rust', True, True)])
add('alternative_absent', ['Built services in Python.'], '- Proficiency in Java, Go, or Rust.', [('Java, Go or Rust', False, True)])
PAIRS.append(('alternative', 'alternative_absent'))
add('bachelor_met', ['Built Python APIs.'], "- Bachelor's degree required.\n- Experience with Python.",
    [('education', True, True)], education='Bachelor of Science in Computer Science')
add('bsc_met', ['Built Python APIs.'], "- Bachelor's degree required.\n- Experience with Python.",
    [('education', True, True)], education='BSc in Computer Science')
add('degree_absent', ['Built Python APIs.'], "- Bachelor's degree required.\n- Experience with Python.",
    [('education', False, True)])
PAIRS += [('bachelor_met', 'degree_absent'), ('bsc_met', 'degree_absent')]
add('years_met', ['Built Python APIs.'], '- 3+ years of experience.\n- Experience with Python.', [('experience', True, True)])
add('years_wrong_domain', ['Managed restaurant shifts and staff schedules.'],
    '- 3+ years of experience building Python services.', [('experience', False, True)], role='Restaurant Manager')
add('license_missing', ['Prepared tax returns.'], '- CPA license required.', [('cpa license', False, True)], role='Accountant')
add('license_met', ['Holds an active CPA license.'], '- CPA license required.', [('cpa license', True, True)], role='Accountant')
PAIRS.append(('license_met', 'license_missing'))
add('nontech_nursing_met', ['Holds an active RN license. Delivered patient care.'],
    '- Active RN license required.\n- Experience delivering patient care.', [('rn license', True, True)], role='Registered Nurse')
add('nontech_nursing_missing', ['Scheduled patient appointments.'],
    '- Active RN license required.\n- Experience delivering patient care.', [('rn license', False, True)], role='Receptionist')
PAIRS.append(('nontech_nursing_met', 'nontech_nursing_missing'))
add('preferred_absent', ['Built Python APIs.'], '- Experience with Python.\nNice to have:\n- Kubernetes.',
    [('Python', True, True), ('Kubernetes', False, False)])
add('sparse_listing', ['Built Python APIs.'], 'Join our team!', [])
add('duplicate_stuffing', ['Python Python Python Python Python.'], '- Experience with Python.', [('Python', True, True)])

# Role-specific ranking groups, beyond isolated keyword probes.
for group, title, req, strong, partial, unrelated in [
    ('backend', 'Backend Engineer', '- Python, PostgreSQL and Docker.\n- 3+ years of experience.',
     ['Built Python APIs with PostgreSQL and Docker.'], ['Built Python scripts.'], ['Managed retail schedules.']),
    ('frontend', 'Frontend Engineer', '- JavaScript, React and CSS.\n- 3+ years of experience.',
     ['Built React interfaces with JavaScript and CSS.'], ['Built JavaScript scripts.'], ['Prepared tax returns.']),
    ('cloud', 'Cloud Engineer', '- AWS, Terraform and Kubernetes.\n- 3+ years of experience.',
     ['Deployed AWS infrastructure using Terraform and Kubernetes.'], ['Administered AWS accounts.'], ['Managed retail schedules.'])]:
    for level, bullets in [('strong', strong), ('partial', partial), ('unrelated', unrelated)]:
        key = group+'_'+level
        add(key, bullets, req, [], role=title if level != 'unrelated' else 'Retail Manager')
        CASES[-1]['job']['title'] = title
    PAIRS += [(group+'_strong', group+'_partial'), (group+'_partial', group+'_unrelated')]
