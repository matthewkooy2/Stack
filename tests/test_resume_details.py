"""Original synthetic truth and regression cases for the structured review contract."""
import copy
import hashlib
import json
import unittest

from agents import resume_details as D
from tests.fixtures import resume_layouts as L
from tests.fixtures.resume_contract import encoded_fixture


def flat_truth(expected):
    out = {'profile.' + k: v for k, v in expected['profile'].items()}
    for group in ('educations', 'workExperiences', 'projects'):
        for i, row in enumerate(expected[group]):
            for field, value in row.items():
                out[f'{group}.{i}.{field}'] = '\n'.join(value) if isinstance(value, list) else value
    out['skills.descriptions'] = '\n'.join(expected['skills'])
    out['additional.descriptions'] = '\n'.join(expected['additional'])
    return out


def positioned(pages):
    return {'pages': [{'number': n, 'width': 612, 'height': 792,
                      'spans': [{'id': f'p{n}s{i}', 'text': text, 'bbox': [54, 54 + i * 14, 6 * len(text), 11],
                                 'direction': 'ltr', 'endOfLine': False}
                                for i, text in enumerate(rows)]}
                     for n, rows in enumerate(pages, 1)]}


class DetailsContract(unittest.TestCase):
    def test_swift_fixture_matches_current_parser_contract_and_original_evidence(self):
        raw = encoded_fixture()
        self.assertEqual(hashlib.sha256(raw.replace(b'\r\n', b'\n')).hexdigest(),
                         'cc3a78e44470ed1eae1055e9d39c189b6946e66d2fe2eb4b95fc5a564b9fcc31')
        fixture = json.loads(raw)
        self.assertEqual(fixture['definitions'], D.definitions())
        self.assertEqual(fixture['limits'], D.limits())
        self.assertEqual(fixture['sections'], D.sections(fixture['values']))
        original = {'lines': fixture['source']['lines'], 'evidence': fixture['evidence']}
        for key, value in fixture['original_values'].items():
            if value:
                self.assertEqual(D.reconstruct(original, key), value, key)
        self.assertIn('educations.20.school', fixture['original_values'])
        self.assertNotIn('educations.20.school', fixture['values'])
        self.assertFalse(fixture['confirmed'])
        self.assertEqual(fixture['trusted_source'], '')

    def test_summary_continues_on_next_page(self):
        original = D.build(positioned([
            ['Riley Sample', 'Summary', 'Experienced engineer who builds reliable systems'],
            ['and supports teams.', 'Experience', 'Harbor | Data Analyst | 2017 - 2019'],
        ]))
        self.assertEqual(original['values']['profile.summary'],
                         'Experienced engineer who builds reliable systems\nand supports teams.')
        self.assertEqual(D.reconstruct(original, 'profile.summary'), original['values']['profile.summary'])
        self.assertEqual(D.normalize({'profile.summary': 'First paragraph.\nSecond paragraph.'})['profile.summary'],
                         'First paragraph.\nSecond paragraph.')

    def test_projection_preserves_individual_bullets(self):
        values = D.normalize({'workExperiences.0.company': 'Northwind',
                              'workExperiences.0.descriptions': 'First achievement.\nSecond achievement.'})
        self.assertEqual([r['text'] for r in D.records_from(values) if r['kind'] == 'bullet'],
                         ['First achievement.', 'Second achievement.'])

    def test_projection_overhead_and_record_limits_reject_unconfirmable_drafts(self):
        values = {}
        for i in range(20):
            for field in ('school', 'degree', 'gpa', 'date', 'location'):
                values[f'educations.{i}.{field}'] = 'x' * 300
            if i < 5:
                values[f'educations.{i}.descriptions'] = '\n'.join(['y' * 1499] * 4)
        self.assertEqual(sum(map(len, values.values())), 59995)
        with self.assertRaisesRegex(D.DetailsError, 'reviewed-record limits'):
            D.normalize(values)
        with self.assertRaisesRegex(D.DetailsError, 'reviewed-record limits'):
            D.normalize({'workExperiences.0.company': 'Northwind',
                         'workExperiences.0.descriptions': '\n'.join(['Achievement'] * 299)})

    def test_continued_job_and_inferred_section_cross_pages(self):
        original = D.build(positioned([
            ['Riley Sample', 'Experience', 'Northwind Labs | Software Engineer | 2020 - Present',
             '- Built a reliable import service.'],
            ['- Maintained its documentation.', 'Harbor Systems | Data Analyst | 2017 - 2019',
             '- Designed operational reports.'],
        ]))
        values = original['values']
        self.assertEqual(values['workExperiences.0.descriptions'],
                         'Built a reliable import service.\nMaintained its documentation.')
        self.assertEqual(values['workExperiences.1.company'], 'Harbor Systems')
        self.assertEqual(values['workExperiences.1.descriptions'], 'Designed operational reports.')
        inferred = D.build(positioned([['Riley Sample'],
                                      ['Harbor Systems | Data Analyst | 2017 - 2019', '- Designed operational reports.']]))
        self.assertEqual(inferred['values']['workExperiences.0.descriptions'], 'Designed operational reports.')

    def test_original_fields_and_evidence_survive_edit_caps_and_worker_attach(self):
        rows = ['Riley Sample', 'Education']
        for i in range(21):
            rows += [f'Fictional University {i} | 2010 - 2014', 'Bachelor of Science']
        original = D.build(positioned([rows]))
        key = 'educations.20.school'
        self.assertEqual(original['values'][key], 'Fictional University 20')
        self.assertEqual(D.reconstruct(original, key), original['values'][key])
        self.assertNotIn(key, original['editable_values'])
        attached, _ = D.attach_import({}, {'details': original}, [{'id': 'r0', 'kind': 'title', 'text': 'Riley Sample'}], 'digest')
        before = copy.deepcopy(attached['details']['original'])
        saved = D.save(attached, {'profile.name': 'Changed Name'}, False, 1, 1.0, 'Synthetic.pdf')
        self.assertEqual(saved['details']['original'], before)
        self.assertEqual(saved['details']['original_values'][key], 'Fictional University 20')
        self.assertEqual(D.view(saved)['provenance'], {})

    def test_legacy_corrections_survive_reparse_without_implicit_trust(self):
        original = D.build(positioned([['Riley Sample', 'Experience',
                                      'Northwind Labs | Engineer | 2020 - Present']]))
        legacy = {'profile.name': ' User Corrected Name ',
                  'workExperiences.8.company': 'User Corrected Company'}
        for existing_records in ([], [{'id': 'r0', 'kind': 'title', 'text': 'Reviewed'}]):
            review = {'values': copy.deepcopy(legacy), 'records': existing_records,
                      'confirmed_at': 42.0, 'record_history': [{'revision': 1}]}
            before = copy.deepcopy(review)
            attached, first = D.attach_import(review, {'details': original},
                                              [{'id': 'r1', 'kind': 'title', 'text': 'Imported'}], 'digest')
            self.assertEqual(review, before)
            self.assertEqual(first, not bool(existing_records))
            self.assertEqual(attached['values']['profile.name'], 'User Corrected Name')
            self.assertEqual(attached['values']['workExperiences.0.company'], 'User Corrected Company')
            self.assertEqual(attached['details']['legacy_values'], legacy)
            self.assertEqual(attached['details']['original_values'], original['values'])
            self.assertFalse(attached['details']['confirmed'])
            self.assertEqual(attached['details']['confirmed_at'], 0.0)
            self.assertEqual(attached['record_history'], review['record_history'])
            if existing_records:
                self.assertEqual(attached['records'], existing_records)
            saved = D.save(attached, {'profile.name': 'Later edit'}, False, 1, 2.0, 'Synthetic.pdf')
            self.assertEqual(saved['details']['legacy_values'], legacy)
        for invalid in ({'unknown': 'Preserve me'}, {'profile.name': 'x' * 301}, None):
            review = {'values': invalid, 'records': existing_records}
            attached, _ = D.attach_import(review, {'details': original}, [], 'digest')
            self.assertEqual(attached['values'], invalid)
            self.assertNotIn('details', attached)
            self.assertIn('details_error', attached)

    def test_short_lines_fit_confirmed_projection_without_loss(self):
        lines = ['Skill %d' % i for i in range(299)]
        values = D.normalize({'profile.name': 'Riley Sample', 'skills.descriptions': '\n'.join(lines)})
        records = D.records_from(values)
        self.assertLessEqual(len(records), 300)
        text = ' '.join(r['text'] for r in records)
        for line in lines:
            self.assertIn(line, text)
        review = D.save({'records': [{'id': 'r0', 'kind': 'title', 'text': 'Original'}]}, values, True, 0, 1.0, 'Synthetic.pdf')
        self.assertTrue(review['details']['confirmed'])

    def test_replacement_reorders_deletes_and_withdraws_confirmation(self):
        review = {'records': [{'id': 'r0', 'kind': 'title', 'text': 'Original'}]}
        first = D.save(review, {'workExperiences.0.company': 'Northwind',
                                'workExperiences.1.company': 'Harbor'}, True, 0, 1.0, 'Synthetic.pdf')
        draft = D.save(first, {'workExperiences.4.company': 'Harbor'}, False, 1, 2.0, 'Synthetic.pdf')
        self.assertFalse(draft['details']['confirmed'])
        self.assertEqual(draft['values']['workExperiences.0.company'], 'Harbor')
        self.assertNotIn('workExperiences.1.company', draft['values'])
        self.assertEqual(first['details']['history'][0]['values']['workExperiences.0.company'], 'Northwind')

    def test_actual_pdf_fields_and_exact_evidence(self):
        for options in ({}, {'education': 1, 'work': 1, 'projects': 1},
                        {'education': 3, 'work': 5, 'projects': 4}, {'first_work_title_first': True}):
            with self.subTest(options=options):
                raw, expected = L.resume(**options)
                original = D.parse_pdf(raw)
                self.assertEqual(original['values'], flat_truth(expected))
                for key, value in original['values'].items():
                    if value:
                        self.assertEqual(D.reconstruct(original, key), value, key)


if __name__ == '__main__':
    unittest.main()
