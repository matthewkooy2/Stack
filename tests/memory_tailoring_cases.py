"""Fictional candidate, memory bank and listing for memory-grounded tailoring checks.

Fixed before any model run. Traps: the listing asks for Power BI, healthcare claims data
and leading projects, none of which the candidate has; the project says it was not deployed
to production; one memory entry is an unconfirmed draft that must never be used."""

RESUME = [
    {'id': 'r0', 'kind': 'title', 'text': 'Jordan Rivera'},
    {'id': 'r1', 'kind': 'paragraph', 'text': 'Detroit, MI · jordan.rivera@example.com · (555) 010-4477'},
    {'id': 'r2', 'kind': 'heading', 'text': 'Experience'},
    {'id': 'r3', 'kind': 'paragraph', 'text': 'Operations Analyst, Lakeshore Logistics, Jun 2022 – Present'},
    {'id': 'r4', 'kind': 'bullet', 'text': 'Built weekly Excel reports on carrier on-time rates for 6 regional managers.'},
    {'id': 'r5', 'kind': 'bullet', 'text': 'Reduced invoice matching errors by 18% by writing SQL checks against the billing database.'},
    {'id': 'r6', 'kind': 'bullet', 'text': 'Answered vendor emails and scheduled freight pickups.'},
    {'id': 'r7', 'kind': 'paragraph', 'text': 'Sales Associate, Riverfront Outfitters, May 2019 – May 2022'},
    {'id': 'r8', 'kind': 'bullet', 'text': 'Helped customers choose outdoor gear and processed returns.'},
    {'id': 'r9', 'kind': 'bullet', 'text': 'Trained 4 new associates on the point-of-sale system.'},
    {'id': 'r10', 'kind': 'heading', 'text': 'Education'},
    {'id': 'r11', 'kind': 'paragraph', 'text': 'B.S. Statistics, Wayne State University, 2022'},
    {'id': 'r12', 'kind': 'heading', 'text': 'Skills'},
    {'id': 'r13', 'kind': 'paragraph', 'text': 'Excel, SQL, customer service'},
]

BANK = [
    {'name': 'Transit delay dashboard', 'entry_type': 'project', 'confirm': True,
     'source': 'My personal project notes',
     'fields': {'role': 'Solo developer', 'start_date': 'Jan 2024', 'end_date': 'Apr 2024',
                'technologies': 'Python, pandas, Tableau', 'url': 'https://example.com/transit-delays'},
     'records': [
         {'id': 'r0', 'kind': 'bullet', 'text': 'Cleaned two years of public bus GPS data with Python and pandas.'},
         {'id': 'r1', 'kind': 'bullet', 'text': 'Published a Tableau dashboard of route delays by hour that got 300 views in its first month.'},
         {'id': 'r2', 'kind': 'bullet', 'text': 'I did not deploy it to production; it runs from a scheduled notebook.'}]},
    {'name': 'Data Intern, City of Detroit', 'entry_type': 'work_experience', 'confirm': True,
     'source': 'Internship offer letter and my notes',
     'fields': {'employer': 'City of Detroit Office of Innovation', 'job_title': 'Data Intern',
                'start_date': 'Jun 2021', 'end_date': 'Aug 2021', 'location': 'Detroit, MI'},
     'records': [
         {'id': 'r0', 'kind': 'bullet', 'text': 'Geocoded 12,000 resident service requests in Python to map response times by neighborhood.'},
         {'id': 'r1', 'kind': 'bullet', 'text': "Presented the neighborhood findings to the department's analytics lead."}]},
    {'name': 'Tableau Desktop Specialist', 'entry_type': 'certification', 'confirm': True,
     'source': 'Credential email', 'fields': {'issuer': 'Tableau', 'issued_date': 'Mar 2024'}, 'records': []},
    {'name': 'Python', 'entry_type': 'skill', 'confirm': True, 'source': 'Self-assessment',
     'fields': {'proficiency': 'Intermediate', 'years_used': '2'}, 'records': []},
    {'name': 'Tableau', 'entry_type': 'skill', 'confirm': True, 'source': 'Self-assessment',
     'fields': {'proficiency': 'Intermediate'}, 'records': []},
    {'name': 'Gleaners food bank volunteer', 'entry_type': 'volunteering', 'confirm': True, 'source': 'Volunteer log',
     'fields': {'organization': 'Gleaners Community Food Bank', 'role': 'Volunteer', 'start_date': 'Sep 2020'},
     'records': [{'id': 'r0', 'kind': 'bullet', 'text': 'Sorted donated food on Saturday morning shifts.'}]},
    {'name': 'Machine learning course notes', 'entry_type': 'other', 'confirm': False, 'source': 'Unfinished draft',
     'fields': {}, 'records': [{'id': 'r0', 'kind': 'bullet', 'text': 'Trained a neural network that predicts hospital readmissions with 91% accuracy.'}]},
]

JOB = {
    'title': 'Junior Data Analyst', 'company': 'Northwind Health', 'location': 'Detroit, MI', 'seniority': 'Entry-level',
    'description': (
        'Northwind Health is hiring a Junior Data Analyst. You will build dashboards in Tableau or Power BI, write SQL '
        'queries against our claims warehouse, clean messy data with Python, and present findings to stakeholders. '
        'Experience with healthcare claims data is preferred. You will lead cross-functional analytics projects and '
        'mentor interns. Requirements: SQL, Python, a dashboard tool, a degree in statistics or a related field.'),
}

# Claims only the listing or the unconfirmed draft makes: a correct tailored resume never contains them.
FORBIDDEN = [r'power ?bi', r'\bclaims\b', r'healthcare', r'\bmentor', r'cross-functional', r'readmission', r'91%',
             r'neural network', r'\bled\b', r'\bmanag(?:ed|ing|e)\b']


def violations(records):
    """Forbidden claims in final records; 'production' is allowed only with its negation."""
    import re
    found = []
    for r in records:
        text = r['text'].lower()
        found += [(p, r['text']) for p in FORBIDDEN if re.search(p, text)]
        if 'production' in text and not re.search(r"\bnot\b|n't", text):
            found.append(('production without negation', r['text']))
    return found


def bank_views(owner='owner'):
    """The API's _memory_snapshot input for BANK, with stable fake IDs."""
    out = []
    for n, b in enumerate(BANK):
        out.append({'id': 'b' + str(n), 'name': b['name'], 'kind': 'experience_bank', 'confirmed': b['confirm'],
                    'revision': 2, 'records': b['records'], 'entry_type': b['entry_type'], 'fields': b['fields'],
                    'source': b['source']})
    return out


def resume_view(rid='target'):
    return {'id': rid, 'name': 'Jordan Rivera resume', 'kind': '', 'confirmed': True, 'revision': 3,
            'records': RESUME, 'entry_type': 'other', 'fields': {}, 'source': ''}
