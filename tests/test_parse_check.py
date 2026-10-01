"""The parser check: what OpenResume reads back from a tailored PDF versus what Stack wrote."""
import unittest
from agents import parse_check

OUTLINE = [
    {'id': 's0', 'title': 'Experience', 'lines': [], 'entries': [
        {'id': 's0.e0', 'heading': 'Harbor Logistics | Software Engineer Intern | Hybrid | March 2026 – Present', 'movable': True,
         'bullets': [{'id': 'b0', 'text': 'Built an authenticated customer portal serving 1,200+ monthly active users.'},
                     {'id': 'b1', 'text': 'Engineered a Python ETL pipeline with **idempotent** processing.'}]}]},
    {'id': 's1', 'title': 'Projects', 'lines': [], 'entries': [
        {'id': 's1.e0', 'heading': '**Court Vision Tracker** | Python, OpenCV', 'movable': True,
         'bullets': [{'id': 'b2', 'text': 'Built a computer-vision pipeline for player detection.'}]}]},
    {'id': 's2', 'title': 'Technical Skills', 'entries': [],
     'lines': [{'id': 'l0', 'label': 'Languages', 'text': 'Python, C++, SQL'}, {'id': 'l1', 'label': 'Data & ML', 'text': 'pandas, NumPy'}]},
]

GOOD = {'profile.name': 'Jordan Rivera', 'profile.email': 'jordan@example.com', 'profile.phone': '555-010-2040',
        'workExperiences.0.company': 'Harbor Logistics', 'workExperiences.0.jobTitle': 'Software Engineer Intern',
        # Line wrapping and hyphenation from the PDF do not matter.
        'workExperiences.0.descriptions': 'Built an authenticated customer portal serving 1,200+ monthly ac-\ntive users.\nEngineered a Python ETL pipeline with idempotent processing.',
        'projects.0.project': 'Court Vision Tracker', 'projects.0.descriptions': 'Built a computer-vision pipeline for player detection.',
        'skills.descriptions': 'Languages: Python, C++, SQL\nData & ML: pandas, NumPy'}


class Compare(unittest.TestCase):
    def test_clean_read_passes_every_check(self):
        result = parse_check.compare(GOOD, 'Jordan Rivera ...', OUTLINE)
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['passed'], result['total']), (7, 7))

    def test_missing_bullets_entries_skills_and_leaked_latex_fail(self):
        values = {**GOOD, 'workExperiences.0.descriptions': 'Built an authenticated customer portal serving 1,200+ monthly active users.',
                  'projects.0.project': 'Something else', 'skills.descriptions': 'Languages: Python, C++, SQL'}
        result = parse_check.compare({k: v for k, v in values.items() if k != 'profile.phone'}, 'Skills [3pt] Data', OUTLINE)
        failed = {c['label']: c['detail'] for c in result['checks'] if not c['ok']}
        self.assertFalse(result['ok'])
        self.assertEqual(failed['Phone'], 'Not found')
        self.assertEqual(failed['Experience: Harbor Logistics'], '1 of 2 bullets read')
        self.assertEqual(failed['Projects: Court Vision Tracker'], 'Not read as its own entry')
        self.assertIn('Data & ML', failed['Technical Skills'])
        self.assertEqual(failed['No LaTeX code in the text'], '[3pt]')

    def test_similar_entry_names_are_not_confused(self):
        outline = [{'id': 's0', 'title': 'Experience', 'lines': [], 'entries': [
            {'id': 'e0', 'heading': 'Volunteer | Food Bank', 'movable': True, 'bullets': [{'id': 'a', 'text': 'Sorted donations weekly.'}]},
            {'id': 'e1', 'heading': 'Volunteer Swim Coach | City Pool', 'movable': True,
             'bullets': [{'id': 'b', 'text': 'Coached 20 swimmers.'}, {'id': 'c', 'text': 'Planned practice sets.'}]}]}]
        values = {'profile.name': 'A', 'profile.email': 'a@example.com', 'profile.phone': '1',
                  'workExperiences.0.jobTitle': 'Volunteer', 'workExperiences.0.company': 'Food Bank', 'workExperiences.0.descriptions': 'Sorted donations weekly.',
                  'workExperiences.1.jobTitle': 'Volunteer Swim Coach', 'workExperiences.1.company': 'City Pool', 'workExperiences.1.descriptions': 'Coached 20 swimmers.\nPlanned practice sets.'}
        self.assertTrue(parse_check.compare(values, '', outline)['ok'])

    def test_header_values_must_be_read_exactly(self):
        tex = ('\\documentclass{article}\\begin{document}\\begin{center}\\textbf{\\Huge \\scshape Jordan Rivera} \\\\ \\small 555-010-2040 $|$ '
               '\\href{mailto:jordan@example.com}{jordan@example.com}\\end{center}\\section{Experience}\\end{document}')
        expected = parse_check.expected_profile(tex)
        self.assertEqual(expected, {'name': 'Jordan Rivera', 'email': 'jordan@example.com', 'phone': '555-010-2040'})
        misread = parse_check.compare({**GOOD, 'profile.name': 'Great Lakes University', 'profile.phone': '(555) 010-2040'}, '', OUTLINE, expected)
        failed = {c['label']: c['detail'] for c in misread['checks'] if not c['ok']}
        self.assertEqual(failed, {'Name': 'Read as Great Lakes University, not Jordan Rivera'})


if __name__ == '__main__':
    unittest.main()
