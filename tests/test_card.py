import unittest
from discovery.card import excerpts, card_view


class JobCard(unittest.TestCase):
    def test_card_uses_explicit_role_location_and_keeps_alternatives(self):
        job = {'location': 'Hybrid', 'mode': 'Hybrid', 'description':
               'About us. We have offices in Boston and Paris.Available Locations:\n'
               'Lisbon\nLondon\nSan Francisco, CA\nJob Title: Software Engineer\nBuild software.'}
        self.assertEqual(card_view(job)['location'], 'Lisbon; London; San Francisco, CA')
        self.assertEqual(job['location'], 'Hybrid')
        remote = {'location': 'Taiwan', 'description': 'This role is based in Taipei'}
        self.assertIn('Taipei', card_view(remote)['location'])
        remote.update(location='Remote US', description='Available locations: Austin or remote within the US')
        self.assertIn('remote within the US', card_view(remote)['location'])

    def test_card_skips_incidental_locations_and_empty_headings(self):
        for text in ('Our headquarters are in Boston.', 'For positions based in Los Angeles, pay varies.',
                     'Interview itinerary\nLocation: Austin', 'Available Locations:\nPosition Overview'):
            self.assertEqual(card_view({'description': text, 'location': 'Remote US'})['location'], 'Remote US')

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

    def test_split_pay_and_short_explicit_qualifications(self):
        text = '<h3>Annual base salary range</h3>$80,000–$95,000 USD'
        card = card_view({'description': text, 'qualifications': 'RN license', 'responsibilities': 'Lead audits'})
        self.assertIn('Annual base salary range $80,000–$95,000 USD', card['highlights']['pay_excerpt'])
        self.assertEqual(card['highlights']['responsibilities'][0], 'Lead audits')
        self.assertEqual(card['highlights']['requirements'], ['RN license'])
        choice = 'This role can be held in our office or remotely within the US.'
        self.assertEqual(excerpts(choice, '')['work_arrangement'], choice)
        self.assertEqual(excerpts('HSA: a $100/month company contribution.', '')['pay_excerpt'], '')
        self.assertEqual(excerpts('Compensation: $22/hr', '')['pay_excerpt'], 'Compensation: $22/hr')

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
