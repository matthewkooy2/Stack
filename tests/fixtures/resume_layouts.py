"""Authored, fictional resume layouts for structured extraction tests.

A minimal PDF writer (Helvetica, text only) plus builders that return both the
document and the records a correct parse should contain. No private or
downloaded resume content is used. The writer follows the one Stack committed
in its standalone parser work (PR 23, tests/fixtures.py), extended with line
wrapping and expected-record bookkeeping.
"""
import textwrap
import zlib


def pdf(pages, *, compressed=False):
    """pages: list of rows [(x, y_from_top, text)]; returns PDF bytes."""
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>']
    kids = []
    for rows in pages:
        page_id = len(objects) + 1
        kids.append(f'{page_id} 0 R')
        commands = []
        for x, y, text in rows:
            escaped = text.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')
            commands.append(f'BT /F1 11 Tf 1 0 0 1 {x} {792 - y} Tm ({escaped}) Tj ET')
        stream = '\n'.join(commands).encode('cp1252')
        if compressed:
            stream = zlib.compress(stream)
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {page_id + 1} 0 R >>'.encode())
        objects.append(f'<< /Length {len(stream)} '.encode() + (b'/Filter /FlateDecode ' if compressed else b'')
                       + b'>>\nstream\n' + stream + b'\nendstream')
    objects[1] = f'<< /Type /Pages /Count {len(pages)} /Kids [{" ".join(kids)}] >>'.encode()
    content, offsets = b'%PDF-1.7\n', [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(content))
        content += f'{number} 0 obj\n'.encode() + obj + b'\nendobj\n'
    start = len(content)
    content += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    content += b''.join(f'{offset:010d} 00000 n \n'.encode() for offset in offsets[1:])
    return content + f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()


def blank_pdf():
    """A page with no text layer, standing in for a scan or image-only export."""
    return pdf([[]])


class Page:
    """Flows lines down pages. `bullet` wraps long text with a hanging indent."""

    def __init__(self, left=54, top=54, bottom=740, step=14):
        self.left, self.top, self.bottom, self.step = left, top, bottom, step
        self.pages, self.rows, self.y = [], [], top

    def _room(self, lines):
        if self.y + lines * self.step > self.bottom:
            self.pages.append(self.rows)
            self.rows, self.y = [], self.top

    def gap(self, points=10):
        self.y += points

    def line(self, text, x=None):
        self._room(1)
        self.rows.append((self.left if x is None else x, self.y, text))
        self.y += self.step

    def heading(self, text):
        self.gap(10)
        self.line(text)

    def bullet(self, text, width=72):
        wrapped = textwrap.wrap(text, width)
        self._room(len(wrapped))
        for index, part in enumerate(wrapped):
            self.line(('- ' + part) if index == 0 else part, self.left + (0 if index == 0 else 8))

    def build(self):
        return pdf(self.pages + [self.rows])


FIRST = ['Northwind Labs', 'Harbor Systems', 'Quill Analytics', 'Blue Heron Group', 'Summit Works',
         'Cedar Point Inc', 'Lantern Labs', 'Orchard Systems', 'Pine Ridge Company', 'Tidewater Group']
TITLES = ['Software Engineer', 'Data Analyst', 'Project Manager', 'Systems Developer', 'Research Assistant',
          'Operations Coordinator', 'Quality Specialist', 'Platform Engineer', 'Support Technician', 'Product Designer']
SCHOOLS = ['Fictional State University', 'Example Valley College', 'Sample Institute of Technology',
           'Placeholder University', 'Imaginary Polytechnic']
DEGREES = ['Bachelor of Science in Computing', 'Master of Science in Data Analysis', 'Associate of Applied Science',
           'Bachelor of Arts in Design', 'Doctor of Philosophy in Statistics']
DATES = ['Jan 2015 - May 2017', 'Aug 2017 - Dec 2018', 'Mar 2019 - Present', '2012 - 2014', 'June 2020 - Sept 2021',
         'Oct 2010 - Feb 2012', '2008 - 2010', 'Nov 2021 - Present', 'Apr 2013 - Jul 2014', 'May 2016 - Aug 2016']
BULLETS = [
    'Built an internal reporting tool that reduced weekly manual spreadsheet work for the finance team across three regional offices.',
    'Maintained the nightly import pipeline and documented every failure mode in the shared runbook for new teammates.',
    'Mentored junior engineers and managers during the developer onboarding program and graded their practice reviews.',
    'Coordinated a university partnership with a college department and presented findings at the annual analyst meeting.',
    'Led weekly planning for a five person team and tracked delivery against agreed milestones.',
    'Designed a customer survey and analysed 2,400 responses to recommend three product changes.',
    'Partnered with the product team to ship a search feature and then onboarded a new software engineer after the release.',
    'Supported the annual hiring season by screening applicants from every nearby university and a regional community college.',
]


def resume(education=2, work=3, projects=2, skills=True, additional=True, summary=True,
           first_work_title_first=False, page=None):
    """Return (pdf_bytes, expected). Bullet counts vary by record index."""
    page = page or Page()
    expected = {'profile': {'name': 'Riley Sample', 'email': 'riley.sample@example.invalid',
                            'phone': '+1 202-555-0188', 'location': 'Springfield, IL',
                            'url': 'https://example.invalid/riley', 'summary': ''},
                'educations': [], 'workExperiences': [], 'projects': [], 'skills': [], 'additional': []}
    page.line('Riley Sample')
    page.line('riley.sample@example.invalid | +1 202-555-0188 | Springfield, IL')
    page.line('https://example.invalid/riley')
    if summary:
        text = 'Analyst who enjoys turning messy operational data into clear weekly reports for managers.'
        page.heading('Summary')
        page.line(text)
        expected['profile']['summary'] = text
    if education:
        page.heading('Education')
        for i in range(education):
            school, degree, date = SCHOOLS[i % 5], DEGREES[i % 5], DATES[(i * 3) % 10]
            gpa = '3.%d' % (5 + i % 5) if i % 2 == 0 else ''
            location = 'Springfield, IL' if i % 2 == 1 else ''
            page.gap(4 if i else 0)
            page.line(f'{school} | {date}')
            page.line(degree + (f', GPA: {gpa}' if gpa else ''))
            record = {'school': school, 'degree': degree + (f', GPA: {gpa}' if False else ''), 'gpa': gpa,
                      'date': date, 'location': location, 'descriptions': []}
            if location:
                record['location'] = location
                page.line(location)
            for b in range(i % 2):
                text = BULLETS[(i + b) % 8]
                page.bullet(text)
                record['descriptions'].append(text)
            expected['educations'].append(record)
    if work:
        page.heading('Experience')
        for i in range(work):
            company, title, date = FIRST[i % 10], TITLES[i % 10], DATES[(i * 7 + 2) % 10]
            page.gap(4 if i else 0)
            if i % 2 == 0 and not (first_work_title_first and i == 0):
                page.line(f'{company} | {title} | {date}')
            else:
                page.line(f'{title} | {company} | {date}')
            record = {'company': company, 'jobTitle': title, 'date': date, 'location': '', 'descriptions': []}
            for b in range(1 + i % 3):
                text = BULLETS[(i * 2 + b) % 8]
                page.bullet(text)
                record['descriptions'].append(text)
            expected['workExperiences'].append(record)
    if projects:
        page.heading('Projects')
        for i in range(projects):
            name, date = f'Project {["Atlas", "Beacon", "Compass", "Delta"][i % 4]}{i // 4 or ""}', DATES[(i * 3 + 1) % 10]
            page.gap(4 if i else 0)
            page.line(f'{name} | {date}' if i % 2 == 0 else name)
            record = {'project': name, 'date': date if i % 2 == 0 else '', 'descriptions': []}
            for b in range(1 + i % 2):
                text = BULLETS[(i + b + 3) % 8]
                page.bullet(text)
                record['descriptions'].append(text)
            expected['projects'].append(record)
    if skills:
        page.heading('Skills')
        for line in ['Languages: Python, SQL, TypeScript', 'Tools: Git, Linux, Excel', 'Practices: code review, testing']:
            page.line(line)
            expected['skills'].append(line)
    if additional:
        page.heading('Certifications')
        page.line('Fictional Cloud Practitioner, 2022')
        page.heading('Awards')
        page.line('Quarterly Team Recognition Award, 2021')
        expected['additional'] += ['Certifications', 'Fictional Cloud Practitioner, 2022', 'Awards',
                                   'Quarterly Team Recognition Award, 2021']
    return page.build(), expected


def two_column():
    """Sidebar of skills/education beside experience: an honest limit case."""
    rows = [(54, 54, 'Riley Sample'), (54, 70, 'riley.sample@example.invalid | +1 202-555-0188')]
    left = ['Skills', 'Python, SQL', 'TypeScript, Git', 'Education', 'Fictional State University',
            'Bachelor of Science in Computing 2017', 'Certifications', 'Fictional Cloud Practitioner, 2022']
    right = ['Experience', 'Northwind Labs | Software Engineer | 2017 - Present',
             '- Built an internal reporting tool for finance.', '- Maintained a nightly import pipeline.',
             'Projects', 'Project Atlas | 2020', '- Prototype for field data capture.']
    for i, text in enumerate(left):
        rows.append((54, 110 + i * 18, text))
    for i, text in enumerate(right):
        rows.append((330, 110 + i * 18, text))
    return pdf([rows]), {'left': left, 'right': right}
