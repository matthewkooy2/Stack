"""Job score contract (agents/job_score.jac): confirmed records only, canonical inputs, a fixed rubric.

Run with `jac run tests/test_job_score.py`. A change that moves the pinned output below changes the
contract: bump job_score.VERSION and update docs/JOB_SCORE.md with it.
"""
import copy
import json
from pathlib import Path
import unittest
from agents import job_score, scoring
from agents import record_resume as rr

ROOT = Path(__file__).resolve().parents[1]
# Fixed fictional records as a user confirms them, including a negated claim.
RECORDS = json.loads((ROOT / 'tests/fixtures/record-resume.json').read_text(encoding='utf-8'))
JOB = {'title': 'Python Data Analyst', 'description': '\n'.join([
    'What you will do:',
    '- Build dashboards in Python and Tableau.',
    '- Document SQL queries for stakeholders.',
    'Requirements:',
    "- Bachelor's degree in Computer Science or a related field.",
    '- 2+ years of experience in data analysis.',
    '- Experience with SQL and Python.',
    '- Team leadership and strong communication skills.',
    '- CPA license required.',
    'Nice to have:',
    '- AWS experience.'])}
AS_OF = '2026-11'


def records(*rows):
    return [{'id': 'r%d' % i, 'kind': kind, 'text': text} for i, (kind, text) in enumerate(rows)]


def by_term(result):
    return {r['term']: r for r in result['requirements']}


class Contract(unittest.TestCase):
    def test_fixed_inputs_give_the_pinned_output(self):
        result = job_score.score(RECORDS, JOB, AS_OF)
        self.assertEqual((result['contract'], result['version'], result['status'], result['score']),
                         ('stack.job_score', 1, 'scored', 62))
        self.assertEqual([(c['key'], c['weight'], c['score']) for c in result['components']],
                         [('skills', 55, 71), ('title', 10, 33), ('education', 10, 100),
                          ('experience', 10, 100), ('keywords', 15, 0)])
        self.assertEqual({t: (r['kind'], r['status'], r['evidence']) for t, r in by_term(result).items()}, {
            'Python': ('skill', 'applied', ['r4']),
            'SQL': ('skill', 'applied', ['r5']),
            'Data analysis': ('skill', 'missing', []),
            'AWS': ('skill', 'mentioned', ['r8']),
            'Data visualization': ('skill', 'applied', ['r4']),
            'Tableau': ('skill', 'missing', []),
            'Python Data Analyst': ('title', 'partial', ['r3']),
            "Bachelor's": ('education', 'met', ['r8']),
            '2+ years': ('experience', 'met', ['r3']),
            'cpa license': ('keyword', 'missing', []),
            'communication': ('soft_skill', 'missing', []),
            'leadership': ('soft_skill', 'missing', []),
        })
        self.assertEqual(by_term(result)['2+ years']['counted_years'], 3.0)
        self.assertEqual(result['missing_required'], ['Data analysis'])
        self.assertEqual(result['inputs']['digest'], 'c810c3703114713db484b7ca6a9ea375e2bcd9649b60dc0f2c1a7bca289cc729')
        self.assertEqual((result['inputs']['records'], result['inputs']['evidence_records']), (10, 5))
        self.assertEqual(result['rubric']['weights'], job_score.WEIGHTS)
        self.assertEqual(result['rubric']['vocabulary_digest'], job_score.vocabulary_digest())

    def test_repeated_and_equivalent_inputs_give_identical_output(self):
        first = job_score.score(RECORDS, JOB, AS_OF)
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(job_score.score(copy.deepcopy(RECORDS), dict(JOB), AS_OF), sort_keys=True))
        # Line endings, spacing, blank lines and fields the score does not read change nothing, not even the digest.
        noisy = {**JOB, 'title': '  Python   Data Analyst ', 'description': '\r\n\r\n'.join('  ' + line.replace(' ', '\t ') for line in JOB['description'].split('\n')),
                 'company': 'Other Co', 'url': 'https://example.com/job', 'location': 'Remote', 'salary': '$90,000', 'id': 'job_x'}
        spaced = [{**r, 'text': '  ' + r['text'].replace(' ', '   ') + ' '} for r in RECORDS]
        self.assertEqual(json.dumps(job_score.score(spaced, noisy, AS_OF), sort_keys=True), json.dumps(first, sort_keys=True))

    def test_renumbered_records_keep_the_score(self):
        renumbered = [{**r, 'id': 'r%d' % (int(r['id'][1:]) + 40)} for r in RECORDS]
        first, second = job_score.score(RECORDS, JOB, AS_OF), job_score.score(renumbered, JOB, AS_OF)
        self.assertEqual((second['score'], second['components']), (first['score'], first['components']))
        self.assertEqual(by_term(second)['Python']['evidence'], ['r44'])
        self.assertNotEqual(second['inputs']['digest'], first['inputs']['digest'])

    def test_as_of_is_an_explicit_input(self):
        rows = records(('heading', 'Experience'), ('paragraph', 'Engineer | Acme | Jan 2025 – Present'),
                       ('bullet', 'Built Go services handling 2,000 requests per second.'))
        job = {'title': 'Engineer', 'description': 'Requirements:\n- 2+ years of experience with Go.'}
        early, late = job_score.score(rows, job, '2026-01'), job_score.score(rows, job, '2027-01')
        self.assertEqual((by_term(early)['2+ years']['counted_years'], by_term(early)['2+ years']['status']), (1.0, 'partial'))
        self.assertEqual((by_term(late)['2+ years']['counted_years'], by_term(late)['2+ years']['status']), (2.0, 'met'))
        self.assertLess(early['score'], late['score'])
        self.assertNotEqual(early['inputs']['digest'], late['inputs']['digest'])
        self.assertEqual(job_score.canonical_as_of(job_score.date(2026, 3, 9)), '2026-03')
        self.assertRegex(job_score.canonical_as_of(), r'^\d{4}-\d{2}$')


class Evidence(unittest.TestCase):
    def test_negated_name_and_contact_lines_are_never_evidence(self):
        rows = records(('title', 'Ruby Kubernetes'), ('paragraph', 'ruby@example.com | github.com/ruby-docker'),
                       ('heading', 'Experience'), ('paragraph', 'Engineer | Acme | 2021 – 2023'),
                       ('bullet', "Didn't use Docker in production. Built Go services for 3 teams."),
                       ('bullet', 'Never deployed with Kubernetes.'))
        job = {'title': 'Backend Engineer', 'description': 'Requirements:\n- Experience with Ruby, Docker and Kubernetes.\n- Experience with Go.'}
        found = by_term(job_score.score(rows, job, AS_OF))
        self.assertEqual({t: found[t]['status'] for t in ('Ruby', 'Docker', 'Kubernetes', 'Go')},
                         {'Ruby': 'missing', 'Docker': 'missing', 'Kubernetes': 'missing', 'Go': 'applied'})
        # The non-negated clause of a partly negated record still counts.
        self.assertEqual(found['Go']['evidence'], ['r4'])

    def test_credit_follows_the_confirmed_section(self):
        rows = records(('heading', 'Experience'), ('paragraph', 'Engineer | Acme | 2021 – 2023'),
                       ('bullet', 'Built Python services for 3 teams.'),
                       ('heading', 'Education'), ('paragraph', 'Relevant coursework: Kubernetes'),
                       ('heading', 'Technical Skills'), ('paragraph', 'Docker, Terraform'))
        job = {'title': 'Engineer', 'description': 'Requirements:\n- Experience with Python.\n- Experience with Kubernetes.\n- Experience with Docker.\n- Experience with Rust.'}
        found = by_term(job_score.score(rows, job, AS_OF))
        self.assertEqual({t: (found[t]['status'], found[t]['credit']) for t in ('Python', 'Kubernetes', 'Docker', 'Rust')},
                         {'Python': ('applied', 1.0), 'Kubernetes': ('mentioned', 0.8), 'Docker': ('listed', 0.6), 'Rust': ('missing', 0.0)})

    def test_alternatives_are_one_requirement_and_new_confirmed_evidence_raises_the_score(self):
        base = [('heading', 'Experience'), ('paragraph', 'Engineer | Acme | 2021 – 2024'), ('bullet', 'Built Go services for 3 teams.')]
        job = {'title': 'Engineer', 'description': 'Requirements:\n- Proficiency in Java, Go, or Rust.\n- Experience with PostgreSQL.'}
        before = job_score.score(records(*base), job, AS_OF)
        either = by_term(before)['Java, Go or Rust']
        self.assertEqual((either['status'], either['via']), ('applied', 'Go'))
        self.assertEqual(before['missing_required'], ['PostgreSQL'])
        after = job_score.score(records(*base, ('bullet', 'Cut PostgreSQL query time by 40%.')), job, AS_OF)
        self.assertGreater(after['score'], before['score'])
        self.assertEqual((by_term(after)['PostgreSQL']['evidence'], after['missing_required']), (['r3'], []))


class Limits(unittest.TestCase):
    def test_listing_with_nothing_to_compare_is_not_scored(self):
        result = job_score.score(RECORDS, {'title': 'Analyst', 'description': 'Join us.'}, AS_OF)
        self.assertEqual((result['status'], result['score'], result['components']), ('insufficient_job', None, []))

    def test_invalid_inputs_are_refused(self):
        for rows, job, as_of in ((RECORDS, JOB, '2026-13'), (RECORDS, JOB, 'November'), ([], JOB, AS_OF),
                                 ([{'id': 'r0', 'kind': 'fact', 'text': 'Python'}], JOB, AS_OF), (RECORDS, None, AS_OF)):
            with self.assertRaises(ValueError):
                job_score.score(rows, job, as_of)

    def test_legacy_summary_reports_the_job_score(self):
        result = job_score.score(RECORDS, JOB, AS_OF)
        outline = rr.prepare({'records': RECORDS, 'template': 'classic', 'upload_digest': '', 'revision': 0})['outline']
        legacy = job_score.legacy_summary(result, scoring.quality(outline))
        self.assertEqual((legacy['match'], legacy['match_components']), (62, result['components']))
        self.assertIsNotNone(legacy['quality'])
        self.assertEqual(legacy['missing'], [{'term': 'Data analysis', 'required': True, 'supported': False},
                                             {'term': 'Tableau', 'required': False, 'supported': False}])
        self.assertEqual(legacy['requirements']['resume_years'], 3.0)


if __name__ == '__main__':
    unittest.main()
