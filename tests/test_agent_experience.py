"""Offline checks for review payloads, task presentation and feature readiness."""
import time
import unittest
from agents import experience
from agents.contracts import EXTERNAL, STEPS, digest


class Review(unittest.TestCase):
    def test_every_external_step_is_reviewed(self):
        # Resume changes are reviewed too, although approving them shares nothing.
        self.assertEqual(experience.REVIEWED, set(EXTERNAL) | {'approve_resume'})
        self.assertEqual(STEPS['resume'], ['tailor', 'approve_resume'])
        self.assertNotIn('application', STEPS)

    def test_resume_review_binds_changes_and_rejections(self):
        tailored = {'changes': [{'id': 's1.e0.b0', 'kind': 'rewrite', 'where': 'Experience', 'before': 'a', 'after': 'b', 'reason': 'r'}],
                    'rejected': [], 'dropped': [], 'plan': {'rewrites': {'s1.e0.b0': 'b'}}, 'source_digest': 'x', 'pdf': {'pages': 1}}
        payload = experience.review_payload('approve_resume', {}, {'tailor': tailored})
        rejected = experience.review_payload('approve_resume', {}, {'tailor': {**tailored, 'rejected': ['s1.e0.b0']}})
        self.assertNotEqual(digest(payload), digest(rejected))
        summary = experience.review_summary('approve_resume', {'job': {'company': 'Acme'}}, {'tailor': tailored})
        self.assertEqual((summary['title'], summary['pages'], len(summary['changes'])), ('Review your tailored resume for Acme', 1, 1))
        self.assertIn('Nothing is shared', summary['consequence'])

    def test_payload_matches_worker_hash_inputs(self):
        context = {'event': {'uid': 'u', 'summary': 'Interview'}, 'job': {'url': 'https://jobs.lever.co/x'}}
        artifacts = {'draft': {'subject': 'Hi', 'body': 'Body'}}
        # agents.worker hashes exactly these values before asking for authorization.
        self.assertEqual(digest(experience.review_payload('send', context, artifacts)), digest(artifacts['draft']))
        self.assertEqual(digest(experience.review_payload('calendar', context, artifacts)), digest(context['event']))
        with self.assertRaises(ValueError):
            experience.review_payload('fit', context, artifacts)

    def test_send_and_calendar_summaries_show_exact_content(self):
        send = experience.review_summary('send', {'contact': {'name': 'Casey', 'email': 'c@example.com'}, 'followup': True}, {'draft': {'subject': 'S', 'body': 'B'}})
        self.assertEqual((send['to'], send['subject'], send['body'], send['followup']), ('c@example.com', 'S', 'B', True))
        self.assertTrue(send['title'].startswith('Send follow-up'))
        event = {'summary': 'Onsite', 'start': {'dateTime': '2026-10-01T15:00:00+00:00'}, 'end': {'dateTime': '2026-10-01T16:00:00+00:00'}, 'location': 'Zoom'}
        calendar = experience.review_summary('calendar', {'event': event}, {})
        self.assertEqual(calendar['event']['start'], '2026-10-01T15:00:00+00:00')


class Presentation(unittest.TestCase):
    def test_progress_and_next_action(self):
        view = experience.present('resume', 'review', 1, STEPS['resume'], {'job': {'title': 'Analyst', 'company': 'Acme'}})
        self.assertEqual((view['step_number'], view['step_total'], view['next_action'], view['step_label']), (2, 2, 'review', 'Approve resume changes'))
        self.assertEqual(view['context_label'], 'Analyst · Acme')
        self.assertTrue(view['attention'])
        self.assertFalse(view['active'])
        self.assertEqual(experience.present('network', 'queued', 0, STEPS['network'], {'followup': True})['title'], 'Follow-up email')

    def test_backoff_is_explained(self):
        now = time.time()
        view = experience.present('code', 'queued', 0, STEPS['code'], {}, next_at=now + 120, now=now)
        self.assertIn('Retrying', view['explanation'])
        self.assertTrue(view['active'])


class Features(unittest.TestCase):
    def facts(self, **changes):
        base = {'now': time.time(), 'policy': {'enabled': False}, 'model': {'configured': False, 'message': 'Not configured'},
                'google_scopes': [], 'google_client': False, 'browser': False, 'sandbox': False, 'voice_error': 'Disabled',
                'web_url': '', 'operator_limits': {}, 'resumes': 0, 'applications': 0,
                'resume_facts': 0, 'verified_facts': 0, 'contacts_selected': 0}
        return {**base, **changes}

    def test_catalog_covers_all_features_with_explanations(self):
        features = experience.feature_status(self.facts())
        self.assertEqual(len(features), 10)
        for f in features:
            for key in ('summary', 'input', 'review', 'alternative', 'where'):
                self.assertTrue(f[key], (f['key'], key))
            self.assertTrue(all(c['ok'] or c['fix'] for c in f['checks']))
        kinds = {k for f in features for k in f['kinds']}
        self.assertEqual(kinds, set(STEPS))

    def test_operator_gaps_are_unavailable_user_gaps_are_setup(self):
        by = {f['key']: f for f in experience.feature_status(self.facts())}
        self.assertEqual(by['code']['state'], 'unavailable')
        self.assertEqual(by['coaching']['state'], 'unavailable')
        ready_model = self.facts(model={'configured': True}, policy={'enabled': False})
        by = {f['key']: f for f in experience.feature_status(ready_model)}
        self.assertEqual(by['coaching']['state'], 'setup')
        policy = {'enabled': True, 'expires_at': time.time() + 60, 'actions': ['model'], 'daily_limits': {}}
        by = {f['key']: f for f in experience.feature_status(self.facts(model={'configured': True}, policy=policy))}
        self.assertEqual(by['coaching']['state'], 'ready')
        self.assertEqual(by['profile']['state'], 'setup')

    def test_expired_rules_and_missing_limits_are_not_ready(self):
        expired = {'enabled': True, 'expires_at': time.time() - 1, 'actions': ['model']}
        by = {f['key']: f for f in experience.feature_status(self.facts(model={'configured': True}, policy=expired))}
        self.assertEqual(by['coaching']['state'], 'setup')
        policy = {'enabled': True, 'expires_at': time.time() + 60, 'actions': ['gmail_read', 'calendar_write'], 'daily_limits': {}}
        by = {f['key']: f for f in experience.feature_status(self.facts(policy=policy, google_client=True, google_scopes=['read', 'calendar']))}
        self.assertEqual(by['email']['state'], 'ready')
        # Calendar writes need a user and an operator daily limit.
        self.assertNotEqual(by['calendar']['state'], 'ready')
        self.assertEqual([c['key'] for c in by['calendar']['checks'] if not c['ok']], ['perm:calendar_write', 'operator:calendar_write'])



if __name__ == '__main__':
    unittest.main(verbosity=2)
