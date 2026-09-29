"""Offline checks for review payloads, task presentation and feature readiness."""
import time
import unittest
from agents import experience
from agents.contracts import EXTERNAL, STEPS, digest


class Review(unittest.TestCase):
    def test_every_external_step_is_reviewed(self):
        # Resume changes are reviewed too, although approving them shares nothing.
        self.assertEqual(experience.REVIEWED, set(EXTERNAL) | {'approve_resume'})
        self.assertLess(STEPS['application'].index('approve_resume'), STEPS['application'].index('fill'))

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
        self.assertEqual(digest(experience.review_payload('fill', context, artifacts)), digest([context, artifacts]))
        with self.assertRaises(ValueError):
            experience.review_payload('fit', context, artifacts)

    def test_fill_summary_lists_only_confirmed_answers_and_documents(self):
        context = {'job': {'company': 'Acme', 'url': 'https://jobs.lever.co/acme/1'},
                   'facts': [{'key': 'email', 'value': 'a@example.com', 'verified': True}, {'key': 'phone', 'value': '555', 'verified': False}]}
        fields = [{'label': 'Email', 'type': 'email', 'key': 'email'}, {'label': 'Phone', 'type': 'tel', 'key': 'phone'},
                  {'label': 'Resume', 'type': 'file', 'key': 'answer:resume', 'required': True},
                  {'label': 'Cover letter', 'type': 'file', 'key': 'answer:cover', 'required': True}]
        artifacts = {'inspect': {'fields': fields}, 'tailor': {'pdf': {'name': 'Tailored resume.pdf', 'pages': 1, 'diff': '+x'}}}
        summary = experience.review_summary('fill', context, artifacts)
        self.assertEqual(summary['answers'], [{'label': 'Email', 'value': 'a@example.com'}])
        self.assertEqual([d['name'] for d in summary['documents']], ['Tailored resume.pdf'])
        self.assertTrue(any('Cover letter' in n for n in summary['notes']))
        self.assertEqual(summary['destination'], 'jobs.lever.co')
        self.assertIn('does not submit', summary['consequence'])

    def test_send_and_calendar_summaries_show_exact_content(self):
        send = experience.review_summary('send', {'contact': {'name': 'Casey', 'email': 'c@example.com'}, 'followup': True}, {'draft': {'subject': 'S', 'body': 'B'}})
        self.assertEqual((send['to'], send['subject'], send['body'], send['followup']), ('c@example.com', 'S', 'B', True))
        self.assertTrue(send['title'].startswith('Send follow-up'))
        event = {'summary': 'Onsite', 'start': {'dateTime': '2026-10-01T15:00:00+00:00'}, 'end': {'dateTime': '2026-10-01T16:00:00+00:00'}, 'location': 'Zoom'}
        calendar = experience.review_summary('calendar', {'event': event}, {})
        self.assertEqual(calendar['event']['start'], '2026-10-01T15:00:00+00:00')


class Presentation(unittest.TestCase):
    def test_progress_and_next_action(self):
        view = experience.present('application', 'review', 4, STEPS['application'], {'job': {'title': 'Analyst', 'company': 'Acme'}})
        self.assertEqual((view['step_number'], view['step_total'], view['next_action'], view['step_label']), (5, 6, 'review', 'Fill the application'))
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
                'web_url': '', 'certified_adapters': [], 'operator_limits': {}, 'resumes': 0, 'applications': 0,
                'resume_facts': 0, 'verified_facts': 0, 'contacts_selected': 0}
        return {**base, **changes}

    def test_catalog_covers_all_features_with_explanations(self):
        features = experience.feature_status(self.facts())
        self.assertEqual(len(features), 11)
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

    def test_submission_certification_is_optional(self):
        policy = {'enabled': True, 'expires_at': time.time() + 60, 'actions': ['model', 'browser_fill'], 'daily_limits': {'browser_fill': 2}}
        facts = self.facts(model={'configured': True}, policy=policy, browser=True, operator_limits={'browser_fill': 5},
                           applications=1, resumes=1, resume_facts=3)
        by = {f['key']: f for f in experience.feature_status(facts)}
        self.assertEqual(by['applications']['state'], 'ready')
        optional = [c for c in by['applications']['checks'] if not c['ok']]
        self.assertTrue(optional and all(c['optional'] for c in optional))
        self.assertTrue(by['applications']['limited'])
        self.assertFalse(by['coaching']['limited'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
