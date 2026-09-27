import unittest
from discovery.card import excerpts, card_view


class JobCard(unittest.TestCase):
    def test_duties_and_required_experience_not_company_pitch(self):
        text = '''We build an exciting future for everyone.
What You Will Do
Develop telemetry software for motorsport applications.
Requirements Management
Collect customer requirements and manage delivery timelines.
Required Qualifications
Bachelor’s Degree in Engineering or Computer Science.
1+ years of experience in application engineering.
Equal Opportunity Employer without regard to protected status.'''
        result = excerpts(text, '')
        self.assertEqual(result['responsibilities'][0], 'Develop telemetry software for motorsport applications.')
        self.assertIn('Bachelor', result['requirements'][0])
        self.assertIn('1+ years', result['requirements'][1])
        self.assertNotIn('Collect customer', str(result['requirements']))

    def test_professional_experience_and_unknowns(self):
        result = excerpts('Required Experience\n5+ years of professional software engineering experience.', '')
        self.assertIn('5+ years', result['requirements'][0])
        self.assertEqual(excerpts('', ''), {'responsibilities': [], 'requirements': [], 'pay_excerpt': ''})

    def test_compact_response_preserves_link_attribution_without_mutation(self):
        job = {'id': 'a', 'url': 'https://example.com/apply', 'attribution': {'name': 'Provider'},
               'description': '<p>Build and maintain useful software for customers.</p>',
               'qualifications': '', 'timeline': {'status': 'unclear', 'evidence': [{'quote': 'original'}]}}
        card = card_view(job)
        self.assertNotIn('description', card)
        self.assertNotIn('evidence', card['timeline'])
        self.assertEqual(card['url'], job['url'])
        self.assertEqual(card['attribution'], job['attribution'])
        self.assertIn('evidence', job['timeline'])
        self.assertTrue(card['highlights']['responsibilities'])


if __name__ == '__main__':
    unittest.main()
