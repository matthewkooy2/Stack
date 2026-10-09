"""Independently authored record fixtures, not copied from a sample resume."""
import copy
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
import subprocess
import sys

from fixtures import pdf
from resume_parser import parse_pdf
from resume_parser.dates import DATE, DATE_RANGE
from resume_parser.structure import structure
from resume_parser.report import render_html

NODE = os.environ.get('STACK_PARSER_TEST_NODE', 'node')
RECORD_ROWS = [
    (40, 35, 'Morgan Sample'),
    (40, 55, 'morgan@example.invalid | 202-555-0184 | github.com/morgan'),
    (40, 85, 'Education'),
    (40, 105, 'Harbor University'), (470, 105, 'Portland, OR'),
    (40, 120, 'BSc Mathematics'), (450, 120, 'Aug. 2017 - May 2020'),
    (40, 135, 'GPA: 3.80/4.00'),
    (40, 165, 'Meadow College'), (485, 165, 'Salem, OR'),
    (40, 180, 'Associate in Science'), (450, 180, 'Sep. 2015 - May 2017'),
    (40, 210, 'Experience'),
    (40, 230, 'Software Engineer'), (455, 230, 'Sept. 2022 - Present'),
    (40, 245, 'Clear Sky Labs'), (470, 245, 'Portland, OR'),
    (45, 265, '• Delivered stable releases'),
    (53, 278, 'for two product teams.'),
    (45, 292, '• Mentored an analyst at Meadow College.'),
    (40, 325, 'Quartz Systems'), (460, 325, 'May 2020 - Aug. 2022'),
    (40, 340, 'Data Analyst'), (485, 340, 'Salem, OR'),
    (45, 360, '• Checked synthetic measurements.'),
    (40, 395, 'Research Assistant'), (450, 395, 'June 2019 - May 2020'),
    (40, 410, 'Harbor University'),
    (45, 430, '• Catalogued fictional weather records.'),
    (40, 465, 'Projects'),
    (40, 485, 'Tide Clock | Python, SQLite'), (450, 485, 'Jan. 2023 - Mar. 2023'),
    (45, 505, '• Built a tide calendar.'),
    (40, 535, 'Map Cabinet | Rust'), (450, 535, 'Apr. 2021 - Dec. 2021'),
    (45, 555, '• Indexed public map titles.'),
    (40, 590, 'Technical Skills'),
    (40, 610, 'Languages: Python, Rust, SQL'),
    (40, 625, 'Tools: Git, SQLite'),
]


def raw_rows(rows):
    return {'pages': [{'number': 1, 'width': 612, 'height': 792, 'spans': [
        {'id': f's{i}', 'text': text, 'bbox': [x, y, min(len(text)*5, 540), 11]}
        for i, (x, y, text) in enumerate(rows)]}]}


class RecordTests(unittest.TestCase):
    def assert_evidence(self, result):
        lines = {line['id']: line for blocks in result['sections'].values()
                 for block in blocks for line in block['lines']}
        for path, evidence in result['recordEvidence'].items():
            value = result
            for component in path.strip('/').split('/'):
                value = value[int(component)] if isinstance(value, list) else value[component]
            pieces, span_ids = [], []
            for item in evidence['sourceRanges']:
                line = lines[item['lineId']]
                start, end = item['lineRange']
                self.assertGreater(end, start)
                pieces.append(line['text'][start:end])
                expected = [r['sourceSpanId'] for r in line['sourceRanges']
                            if r['lineRange'][0] < end and r['lineRange'][1] > start]
                self.assertEqual(expected, item['sourceSpanIds'])
                span_ids.extend(expected)
            self.assertEqual(value, evidence['separator'].join(pieces), path)
            self.assertEqual(list(dict.fromkeys(span_ids)), evidence['sourceSpanIds'])

    def test_synthetic_pdf_records_and_precise_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'records.pdf'
            path.write_bytes(pdf([RECORD_ROWS]))
            result = parse_pdf(path, node=NODE)
        resume = result['resume']
        self.assertEqual(resume['profile']['name'], 'Morgan Sample')
        self.assertEqual(resume['profile']['email'], 'morgan@example.invalid')
        self.assertEqual(resume['profile']['location'], '')  # Do not borrow a school's location.
        self.assertEqual([r['school'] for r in resume['education']], ['Harbor University', 'Meadow College'])
        self.assertEqual(resume['education'][0]['gpa'], '3.80/4.00')
        self.assertEqual(resume['education'][1]['date'], 'Sep. 2015 - May 2017')
        jobs = resume['workExperience']
        self.assertEqual([r['company'] for r in jobs], ['Clear Sky Labs', 'Quartz Systems', 'Harbor University'])
        self.assertEqual([r['jobTitle'] for r in jobs], ['Software Engineer', 'Data Analyst', 'Research Assistant'])
        self.assertEqual(jobs[0]['date'], 'Sept. 2022 - Present')
        self.assertEqual(jobs[0]['descriptions'], ['Delivered stable releases for two product teams.',
                                                  'Mentored an analyst at Meadow College.'])
        self.assertEqual(jobs[1]['descriptions'], ['Checked synthetic measurements.'])
        self.assertEqual(jobs[2]['descriptions'], ['Catalogued fictional weather records.'])
        self.assertEqual([r['project'] for r in resume['projects']], ['Tide Clock | Python, SQLite', 'Map Cabinet | Rust'])
        self.assertEqual(resume['skills']['descriptions'], ['Languages: Python, Rust, SQL', 'Tools: Git, SQLite'])
        self.assert_evidence(result)
        original_source = copy.deepcopy(result['source'])
        original_sections = copy.deepcopy(result['sections'])
        resume['workExperience'][0]['company'] = 'User correction'
        resume['workExperience'][0]['descriptions'][0] = 'Edited description'
        self.assertEqual(result['source'], original_source)
        self.assertEqual(result['sections'], original_sections)

    def test_dotted_months_are_complete_literal_tokens(self):
        for value in ('Aug. 2018', 'Sep. 2020', 'Sept. 2021', 'September 2022',
                      'Jan. 2023', 'Jun. 2024', 'July 2025', 'Present'):
            with self.subTest(value=value):
                self.assertEqual(DATE.fullmatch(value).group(), value)
        value = 'Aug. 2018 – May 2021'
        self.assertEqual(DATE_RANGE.fullmatch(value).group(), value)

    def test_variable_record_counts_order_and_repeated_titles_through_pdf(self):
        # Independent combinations, not a fixed sample-shaped 2/3/2 schema.
        # Repeat titles/degrees intentionally: identical fields must not dedupe
        # distinct records. Pages repeat headings; continuation without a heading
        # is a separately documented limitation.
        for counts in ((0, 0, 0), (1, 1, 1), (5, 2, 4), (2, 9, 7)):
            for reverse in (False, True):
                with self.subTest(counts=counts, reverse=reverse):
                    specs = [('education', 'Education', 'school', counts[0]),
                             ('workExperience', 'Experience', 'company', counts[1]),
                             ('projects', 'Projects', 'project', counts[2])]
                    pages = [[(40, 40, 'Avery Example'),
                              (40, 60, 'avery@example.invalid')]]
                    expected = {kind: [] for kind, _, _, _ in specs}
                    for kind, heading, key, count in (specs[::-1] if reverse else specs):
                        for index in range(count):
                            if index % 4 == 0:
                                pages.append([(40, 40, heading)])
                            y = 65 + (index % 4) * 160
                            date = f'{2010 + index} - {2011 + index}'
                            if kind == 'education':
                                name = f'Campus {index} University'
                                header = [name, f'BSc Mathematics | {date}']
                            elif kind == 'workExperience':
                                name = f'Employer {index} Labs'
                                # Alternate company-first and title-first headers.
                                header = ([name, f'Software Engineer | {date}'] if index % 2
                                          else [f'Software Engineer | {date}', name])
                            else:
                                name = f'Portfolio {index}'
                                header = [f'{name} | {date}']
                            descriptions = [f'Record {index} detail {j}.' for j in range(index % 3 + 1)]
                            pages[-1].extend((40, y + j * 16, text) for j, text in enumerate(header))
                            pages[-1].extend((45, y + 40 + j * 16, '* ' + text)
                                             for j, text in enumerate(descriptions))
                            expected[kind].append((key, name, date, descriptions))
                    with tempfile.TemporaryDirectory() as directory:
                        path = Path(directory) / 'variable.pdf'
                        path.write_bytes(pdf(pages))
                        result = parse_pdf(path, node=NODE)
                    report = render_html(result)
                    for kind, records in expected.items():
                        actual = result['resume'][kind]
                        self.assertEqual(len(actual), len(records), kind)
                        for item, (key, name, date, descriptions) in zip(actual, records):
                            self.assertEqual(item[key], name)
                            self.assertEqual(item['date'], date)
                            self.assertEqual(item['descriptions'], descriptions)
                            self.assertIn(name, report)
                    self.assert_evidence(result)

    def test_delimited_headers_and_missing_fields(self):
        result = structure(raw_rows([(40, 40, 'Education'),
            (40, 60, 'Fictional University | BSc Computing | 2018 - 2022'),
            (40, 90, 'Experience'), (40, 110, 'Sample Labs | Software Engineer | 2022 - Present'),
            (40, 130, '• Built a scheduling tool.'), (40, 165, 'Data Analyst | 2020 - 2022')]))
        resume = result['resume']
        self.assertEqual(resume['education'][0]['degree'], 'BSc Computing')
        self.assertEqual(resume['workExperience'][0]['company'], 'Sample Labs')
        self.assertEqual(resume['workExperience'][1]['company'], '')
        self.assertEqual(resume['workExperience'][1]['jobTitle'], 'Data Analyst')
        self.assertIn('INCOMPLETE_RECORD', [w['code'] for w in result['warnings']])
        self.assert_evidence(result)

    def test_unknown_employer_is_not_invented_from_bullets(self):
        result = structure(raw_rows([(40, 40, 'Experience'), (40, 60, 'Engineer 2020 - Present'),
                                     (45, 80, '• Helped Harbor University researchers.')]))
        job = result['resume']['workExperience'][0]
        self.assertEqual(job['company'], '')
        self.assertEqual(job['descriptions'], ['Helped Harbor University researchers.'])
        self.assert_evidence(result)

    def test_header_location_summary_and_all_links(self):
        result = structure(raw_rows([(40, 40, 'Avery Example'), (40, 60, 'Portland, OR'),
            (40, 80, 'linkedin.com/in/avery | github.com/avery'),
            (40, 110, 'Summary'), (40, 130, 'Builds accessible scientific tools.'),
            (40, 160, 'Skills: Python, SQL'),
            (40, 190, 'Awards'), (40, 210, 'Community recognition')]))
        profile = result['resume']['profile']
        self.assertEqual(profile['location'], 'Portland, OR')
        self.assertEqual(profile['summary'], 'Builds accessible scientific tools.')
        self.assertEqual(profile['link'], 'linkedin.com/in/avery')
        self.assertEqual(profile['links'], ['linkedin.com/in/avery', 'github.com/avery'])
        self.assertEqual(result['resume']['skills']['descriptions'], ['Python, SQL'])
        self.assertIn('Community recognition', result['resume']['unclassified'])
        self.assert_evidence(result)

    def test_unheaded_education_and_job_cues(self):
        result = structure(raw_rows([(40, 40, 'Avery Example'),
            (40, 70, 'Fictional College | BSc Computing | 2022'),
            (40, 100, 'Software Engineer | Sample Labs | 2022 - Present'),
            (40, 130, 'Something ambiguous remains visible.')]))
        self.assertEqual(result['resume']['education'][0]['school'], 'Fictional College')
        self.assertEqual(result['resume']['workExperience'][0]['company'], 'Sample Labs')
        self.assertIn('Something ambiguous remains visible.', result['resume']['unclassified'])
        self.assert_evidence(result)

    def test_columns_have_independent_record_boundaries(self):
        rows = [(40, 50, 'Education'), (40, 70, 'Cedar College'), (40, 90, 'BSc Physics 2021'),
                (40, 110, 'GPA: 3.5'), (40, 150, 'Skills'), (40, 170, 'Python, SQL'),
                (335, 50, 'Experience'), (335, 70, 'Engineer 2021 - Present'),
                (335, 90, 'Example Labs'), (335, 110, '• Built a tool.'),
                (335, 150, 'Projects'), (335, 170, 'Orbit Planner'), (335, 190, '• Mapped a route.')]
        result = structure(raw_rows(sorted(rows, key=lambda row: (row[1], row[0]))))
        self.assertIn('COLUMN_ORDER_INFERRED', [w['code'] for w in result['warnings']])
        self.assertEqual(result['resume']['education'][0]['school'], 'Cedar College')
        self.assertEqual(result['resume']['workExperience'][0]['company'], 'Example Labs')
        self.assertEqual(result['resume']['projects'][0]['project'], 'Orbit Planner')
        self.assert_evidence(result)

    def test_undated_projects_split_on_visible_header_gaps(self):
        result = structure(raw_rows([(40, 40, 'Projects'), (40, 60, 'Atlas Notes'),
            (45, 80, '• Captured notes.'), (40, 115, 'Cinder Maps'), (45, 135, '• Mapped trails.')]))
        self.assertEqual([r['project'] for r in result['resume']['projects']], ['Atlas Notes', 'Cinder Maps'])
        self.assert_evidence(result)

    def test_summary_does_not_leak_across_pages(self):
        raw = raw_rows([(40, 40, 'Summary'), (40, 60, 'Literal summary')])
        second = raw_rows([(40, 40, 'Unknown continuation')])['pages'][0]
        second['number'] = 2
        second['spans'][0]['id'] = 'page2'
        raw['pages'].append(second)
        result = structure(raw)
        self.assertEqual(result['resume']['profile']['summary'], 'Literal summary')
        self.assertIn('Unknown continuation', result['resume']['unclassified'])

    def test_many_wrapped_lines_do_not_amplify_provenance(self):
        rows = [(40, 10, 'Experience'), (40, 30, 'Engineer 2020 - Present'), (40, 45, 'Sample Labs')]
        rows += [(45, 65+i*12, '• Start' if i == 0 else 'continued text') for i in range(3000)]
        start = time.monotonic()
        result = structure(raw_rows(rows))
        job = result['resume']['workExperience'][0]
        self.assertEqual(len(result['resume']['workExperience']), 1)
        self.assertEqual(len(job['descriptions']), 1)
        evidence = result['recordEvidence']['/resume/workExperience/0/descriptions/0']
        self.assertEqual(len(evidence['sourceSpanIds']), 3000)
        self.assertLess(len(json.dumps(result)), 5_000_000)
        self.assertLess(time.monotonic() - start, 5)

    def test_long_whitespace_header_does_not_stall(self):
        start = time.monotonic()
        result = structure(raw_rows([(40, 40, 'Education'),
                                     (40, 60, 'Cedar' + ' ' * 200000 + 'College')]))
        self.assertEqual(len(result['resume']['education']), 1)
        self.assertLess(time.monotonic() - start, 3)

    def test_html_report_is_inert_and_includes_every_record(self):
        result = structure(raw_rows([(40, 40, 'Projects'),
            (40, 60, '<script>alert(1)</script>'), (45, 80, '• <img src=x onerror=alert(1)>'),
            (40, 115, 'Second Project'), (45, 135, '• Another description')]))
        before = copy.deepcopy(result)
        report = render_html(result)
        self.assertIn('&lt;script&gt;alert(1)&lt;/script&gt;', report)
        self.assertIn('&lt;img src=x onerror=alert(1)&gt;', report)
        self.assertNotIn('<script>', report)
        self.assertNotIn('<img ', report)
        self.assertIn('Project 2', report)
        self.assertIn('Second Project', report)
        self.assertIn('Content-Security-Policy', report)
        self.assertEqual(before, result)

    def test_cli_html_is_utf8_and_contains_all_synthetic_records(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fictional.pdf'
            path.write_bytes(pdf([RECORD_ROWS]))
            completed = subprocess.run([sys.executable, '-m', 'resume_parser', str(path),
                                        '--node', NODE, '--format', 'html'], capture_output=True, timeout=15)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode('utf-8', errors='replace'))
        report = completed.stdout.decode('utf-8')
        for text in ('Education 2', 'Work experience 3', 'Project 2', 'Meadow College', 'Quartz Systems'):
            self.assertIn(text, report)
        self.assertNotIn(b'\r\n', completed.stdout)


if __name__ == '__main__':
    unittest.main()
