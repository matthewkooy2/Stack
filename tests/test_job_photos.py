import unittest

from discovery.card import card_view
from discovery.photos import NATURE, posting_photo


class PostingPhotos(unittest.TestCase):
    def test_qualified_places_and_ambiguous_names(self):
        self.assertEqual(posting_photo({'location': 'Seattle, Washington, US'}), 'seattle')
        self.assertEqual(posting_photo({'location': 'Dublin, Ireland'}), 'dublin')
        self.assertIn(posting_photo({'location': 'Dublin, CA'}), NATURE)
        self.assertIn(posting_photo({'location': 'New York', 'country': 'US'}), NATURE)
        self.assertIn(posting_photo({'location': 'South San Francisco, CA'}), NATURE)

    def test_city_evidence_respects_scope_and_search(self):
        job = {'location': 'Taiwan', 'description': 'This role is based in Taipei'}
        self.assertEqual(card_view(job)['photo_id'], 'taipei')
        self.assertIn(posting_photo({'location': 'Germany'}, 'Dublin, Ireland'), NATURE)
        job = {'locations': ['Boston, MA', 'San Francisco, CA']}
        self.assertIn(posting_photo(job), NATURE)
        self.assertEqual(posting_photo(job, preferred_location='Boston, MA'), 'boston')
        self.assertIn(posting_photo(job, preferred_location='Dallas, TX'), NATURE)

    def test_stable_fallback_on_legacy_remote_or_empty_records(self):
        for label in ('', 'N/A', 'Remote US', 'San Francisco Bay Area', 'Hybrid'):
            job = {'id': 'job-sample', 'location': label}
            photo = posting_photo(job)
            self.assertIn(photo, NATURE)
            self.assertEqual(posting_photo(dict(job, title='Changed title')), photo)

