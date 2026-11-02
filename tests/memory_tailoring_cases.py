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


def standin(rewrites=None, omit=(), include=(), verdict='supported'):
    """A deterministic agents.provider.generate stand-in for memory tailoring steps.

    Keeps every base resume line verbatim except `rewrites` (record id -> text) and `omit`
    (record ids), adds memory entries whose names are in `include`, and rates/verifies
    whatever it is asked about. Other steps get the legacy record proposal shape."""
    import re
    rewrites = rewrites or {}

    def generate(step, context, *args, **kwargs):
        if step == 'tailor_screen':
            return {'artifact': {'ratings': {h: {'relevance': 70, 'lines': [], 'reason': 'Fixture'} for h in context['handles']}}, 'cost_cents': 0}
        if step == 'tailor_verify':
            return {'artifact': {'results': {c['id']: {'verdict': verdict, 'problem': ''} for c in context['candidates']}}, 'cost_cents': 0}
        if step != 'tailor_compose':
            return {'artifact': {'summary': '', 'ranking': [], 'entry_order': [], 'evidence': [], 'omit': [], 'rewrites': []}, 'cost_cents': 0}
        sections, item = [], None
        for row in context['base_resume'].split('\n'):
            if row.startswith('### Section: '):
                sections.append({'heading': row[len('### Section: '):], 'items': []})
            elif row.startswith('## R.e'):
                item = {'entry': row.split(' ')[1], 'reason': 'Fixture', 'lines': []}
                sections[-1]['items'].append(item)
            elif row.startswith('R.r') and ' | ' in row:
                cite, text = row.split(' | ', 1)
                rid = cite[2:]
                if rid not in omit:
                    item['lines'].append({'text': rewrites.get(rid, text), 'cites': [cite]})
        for h, name in re.findall(r'^## (E\d+) · [^·]+ · ([^·\n]+)', context['memory'], re.M):
            if name.strip() in include:
                lines = re.findall(r'^' + h + r'\.(r\d+) \| (.+)$', context['memory'], re.M)
                sections[0]['items'].append({'entry': h, 'reason': 'Fixture', 'lines': [{'text': t, 'cites': [h + '.' + i]} for i, t in lines]})
        return {'artifact': {'summary': 'Fixture tailoring.', 'sections': sections, 'left_out': []}, 'cost_cents': 0}
    return generate


# Second candidate, different field. Traps: only Six Sigma Yellow Belt training (the listing
# wants a Green Belt), assisted rather than managed a line changeover, no SolidWorks.
PRIYA_RESUME = [
    {'id': 'r0', 'kind': 'title', 'text': 'Priya Nair'},
    {'id': 'r1', 'kind': 'paragraph', 'text': 'Grand Rapids, MI · priya.nair@example.com'},
    {'id': 'r2', 'kind': 'heading', 'text': 'Education'},
    {'id': 'r3', 'kind': 'paragraph', 'text': 'B.S. Mechanical Engineering, Western Michigan University, May 2025, GPA 3.4'},
    {'id': 'r4', 'kind': 'heading', 'text': 'Experience'},
    {'id': 'r5', 'kind': 'paragraph', 'text': 'Manufacturing Engineering Co-op, Lakeview Plastics, Jan 2024 – Aug 2024'},
    {'id': 'r6', 'kind': 'bullet', 'text': 'Assisted the process engineer with a mold changeover on Line 3.'},
    {'id': 'r7', 'kind': 'bullet', 'text': 'Logged scrap counts by shift in Excel and charted weekly trends.'},
    {'id': 'r8', 'kind': 'paragraph', 'text': 'Barista, Bluebird Coffee, Jun 2021 – Dec 2023'},
    {'id': 'r9', 'kind': 'bullet', 'text': 'Prepared drinks during peak hours and kept the station stocked.'},
    {'id': 'r10', 'kind': 'heading', 'text': 'Skills'},
    {'id': 'r11', 'kind': 'paragraph', 'text': 'AutoCAD, Excel, MATLAB'},
]
PRIYA_BANK = [
    {'name': 'Senior design: conveyor jam sensor', 'entry_type': 'project', 'confirm': True, 'source': 'Capstone report',
     'fields': {'role': 'Team member (4 students)', 'organization': 'Western Michigan University', 'start_date': 'Sep 2024',
                'end_date': 'Apr 2025', 'technologies': 'Arduino, AutoCAD, MATLAB'},
     'records': [
         {'id': 'r0', 'kind': 'bullet', 'text': 'Designed the sensor bracket in AutoCAD and printed 3 prototypes.'},
         {'id': 'r1', 'kind': 'bullet', 'text': 'Wrote MATLAB scripts that flagged jams from vibration data in bench tests.'},
         {'id': 'r2', 'kind': 'bullet', 'text': 'Our team cut false jam alerts from 14 to 3 per test run after tuning thresholds.'}]},
    {'name': 'Six Sigma Yellow Belt training', 'entry_type': 'certification', 'confirm': True, 'source': 'Course completion email',
     'fields': {'issuer': 'Western Michigan University Continuing Education', 'issued_date': 'Mar 2024'}, 'records': [
         {'id': 'r0', 'kind': 'paragraph', 'text': 'Completed Yellow Belt training; I have not earned a Green Belt.'}]},
    {'name': 'Root cause analysis on Line 3 scrap', 'entry_type': 'work_experience', 'confirm': True, 'source': 'Co-op final presentation',
     'fields': {'employer': 'Lakeview Plastics', 'job_title': 'Manufacturing Engineering Co-op', 'start_date': 'Jan 2024', 'end_date': 'Aug 2024'},
     'records': [
         {'id': 'r0', 'kind': 'bullet', 'text': 'Ran a fishbone analysis with operators that traced short shots to an uncalibrated dryer.'},
         {'id': 'r1', 'kind': 'bullet', 'text': 'After the dryer was recalibrated, Line 3 scrap fell from 6.1% to 4.2% over six weeks.'}]},
    {'name': 'Society of Women Engineers', 'entry_type': 'activity', 'confirm': True, 'source': 'Membership card',
     'fields': {'organization': 'Society of Women Engineers', 'role': 'Member', 'start_date': 'Sep 2021', 'end_date': 'May 2025'}, 'records': []},
]
PRIYA_JOB = {
    'title': 'Manufacturing Process Engineer I', 'company': 'Harbor Precision Molding', 'location': 'Holland, MI', 'seniority': 'Entry-level',
    'description': (
        'We need an entry-level process engineer to reduce scrap on injection molding lines. You will lead root cause '
        'investigations, run DOE studies, manage mold changeovers, and build fixtures in SolidWorks. Six Sigma Green Belt '
        'required. Experience with SPC charts and Minitab is a plus. B.S. in Mechanical or Manufacturing Engineering.'),
}
PRIYA_FORBIDDEN = [r'green belt(?!.*not)', r'solidworks', r'minitab', r'\bdoe\b', r'\bspc\b', r'\bmanag(?:ed|ing|e)\b', r'\bled\b']


def filler_bank(n=80):
    """Varied, realistic but unrelated confirmed entries that push the bank past one request."""
    jobs = ['Line cook', 'Camp counselor', 'Library page', 'Grocery stocker', 'Tutor', 'Delivery driver', 'Lifeguard', 'Usher']
    out = []
    for i in range(n):
        role = jobs[i % len(jobs)]
        out.append({'name': role + ' ' + str(i + 1), 'entry_type': 'work_experience', 'confirm': True, 'source': 'Old resume notes',
                    'fields': {'employer': 'Neighborhood Employer ' + str(i + 1), 'job_title': role,
                               'start_date': 'Jun ' + str(2010 + i % 10), 'end_date': 'Aug ' + str(2010 + i % 10)},
                    'records': [{'id': 'r' + str(k), 'kind': 'bullet',
                                 'text': '%s duty %d: greeted visitors, kept shared areas tidy, followed the posted weekly schedule and opened on weekends.' % (role, k)}
                                for k in range(6)]})
    return out
