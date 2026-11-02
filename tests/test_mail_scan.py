"""Mailbox discovery and durable import journeys; no live Gmail or personal accounts."""
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
from cryptography.fernet import Fernet
from jaclang.testing.testing import JacTestClient
from agents import google, mail_scan

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = [
    ('Northwind Hospital', 'Registered Nurse', 'RN-42', 'Submitted',
     'Dear applicant, Northwind Hospital received your application for Registered Nurse, requisition RN-42.'),
    ('Maple Cafe', 'Kitchen Assistant', 'KC-12', 'Interview',
     'We invite you to interview for Kitchen Assistant at Maple Cafe. Your application number is KC-12.'),
]


def proposal(company='Northwind Hospital', title='Registered Nurse', reference='RN-42', status='Submitted',
             proof='received your application', decision='confirmed'):
    return dict(decision=decision, company=company, title=title, reference=reference, status=status, quote=proof)


def message(key, text, at=1_760_000_000, thread=None):
    return {'id': key, 'threadId': thread or 'thread-' + key, 'internalDate': str(at * 1000),
            'payload': {'mimeType': 'text/plain', 'headers': [{'name': 'Subject', 'value': 'Application update'},
                        {'name': 'From', 'value': 'hiring@example.test'}],
                        'body': {'data': base64.urlsafe_b64encode(text.encode()).decode()}}}


class Discovery(unittest.TestCase):
    def test_search_uses_selected_dates_without_saved_companies_and_consumes_next_page(self):
        paths = []
        def request(tokens, path, body=None):
            paths.append(path)
            if path.startswith('messages?'):
                query = parse_qs(urlsplit(path).query)
                self.assertIn('after:1700000000', query['q'][0])
                self.assertNotIn('newer_than:30d', query['q'][0])
                self.assertNotIn('Northwind', query['q'][0])
                self.assertEqual(query['pageToken'], ['page-two'])
                return {'messages': [{'id': 'm1'}], 'nextPageToken': 'page-three'}
            return message('m1', FIXTURES[0][-1])
        context = {'since': 1_700_000_001, 'until': 1_800_000_000, 'scan_cursor': 'page-two', 'applications': []}
        with patch.object(google, 'request', request), patch.object(mail_scan, 'extract', return_value=proposal()):
            result = mail_scan.scan_page({}, context, {'local_model_context_tokens': 8192})
        self.assertFalse(result['done'])
        self.assertEqual(result['scan_cursor'], 'page-three')
        self.assertTrue(result['events'][0]['discovery']['confirmed'])
        self.assertEqual(result['events'][0]['discovery']['title'], 'Registered Nurse')

    def test_unrelated_messages_and_invented_fields_never_become_imports(self):
        self.assertIsNone(mail_scan.validate_discovery({'decision': 'not_application'}, 'A weekly job alert'))
        with self.assertRaises(ValueError):
            mail_scan.validate_discovery(proposal(company='Invented Inc'), FIXTURES[0][-1])
        uncertain = mail_scan.validate_discovery(proposal(title='', decision='uncertain'), FIXTURES[0][-1])
        self.assertFalse(uncertain['confirmed'])

    def test_date_validation_rejects_future_and_nonfinite_values(self):
        for value in (-1, float('nan'), float('inf'), True, 101):
            with self.assertRaises(ValueError):
                mail_scan.validate_since(value, now=100)
        self.assertEqual(mail_scan.validate_since(0, now=100), 0)

    def test_truncated_unclear_mail_goes_to_review_and_repeated_page_is_an_error(self):
        context = {'since': 0, 'until': 1_800_000_000}
        def request(tokens, path, body=None):
            return {'messages': [{'id': 'long'}]} if path.startswith('messages?') else message('long', 'application ' + 'x' * 9000)
        with patch.object(google, 'request', request), patch.object(mail_scan, 'extract', return_value={'decision': 'not_application'}):
            result = mail_scan.scan_page({}, context, {'local_model_context_tokens': 8192})
        self.assertTrue(result['events'][0]['ambiguous'])
        with patch.object(google, 'request', return_value={'nextPageToken': 'repeated'}):
            with self.assertRaises(ValueError):
                mail_scan.scan_page({}, {**context, 'scan_cursor': 'repeated'}, {})

    def test_followup_thread_does_not_need_company_or_role_repeated(self):
        event = google.classify(message('followup', 'We are pleased to offer you the position.', thread='known'), [], [], {'known': 'owned-app'})
        self.assertEqual((event['application_id'], event['status'], event['ambiguous']), ('owned-app', 'Offer', False))


class ImportJourney(unittest.TestCase):
    def setUp(self):
        if os.environ.get('JAC_DB_URL'):
            self.fail('Gmail verification requires disposable embedded data; unset JAC_DB_URL.')
        self.tmp = tempfile.TemporaryDirectory(prefix='stack-mail-scan-')
        self.addCleanup(self.tmp.cleanup)
        config = Path(self.tmp.name) / 'agents.json'
        config.write_text('{}')
        self.environment = patch.dict(os.environ, {'JAC_DB_SCRATCH': '1', 'STACK_AGENT_CONFIG': str(config),
            'STACK_AGENT_WORKER_TOKEN': 'scan-test-worker', 'STACK_CONNECTION_KEY': Fernet.generate_key().decode(),
            'GOOGLE_CLIENT_ID': 'fixture', 'GOOGLE_REDIRECT_URI': 'https://stack.example/oauth/google'})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.client = JacTestClient.from_file(str(ROOT / 'main.jac'), base_path=self.tmp.name)
        self.addCleanup(self.client.close)
        signed = self.client.register_user('mail-scan-owner', 'Fixture-password-1')
        self.assertTrue(signed.ok)
        self.owner = signed.data['token']
        self.client.set_auth_token(self.owner)
        self.rpc('bootstrap')
        runtime = next(module for name, module in sys.modules.items() if name.startswith('_jac_app_') and name.endswith('.core.automation'))
        pending = self.rpc('agent_google_start', {'capabilities': ['read']})
        state = parse_qs(urlsplit(pending['url']).query)['state'][0]
        with patch.object(runtime, 'exchange', return_value={'access_token': 'fixture', 'refresh_token': 'fixture',
                         'expires_at': time.time() + 3600, 'scope': google.SCOPES['read']}):
            self.connection = self.rpc('agent_google_finish', {'state': state, 'code': 'fixture'})['connections'][0]['id']
        self.since = int(time.time()) - 365 * 86400

    def rpc(self, name, args=None):
        response = self.client.post('/function/' + name, json=args or {})
        self.assertTrue(response.ok, response.text)
        value = response.data['result']
        self.assertNotIn('error', value, value)
        return value

    def system(self, name, args=None):
        self.client.clear_auth()
        try:
            return self.rpc(name, {'token': 'scan-test-worker', **(args or {})})
        finally:
            self.client.set_auth_token(self.owner)

    def start(self):
        return self.rpc('gmail_scan_start', {'since': self.since})['scan']

    def claim(self):
        value = self.system('agent_claim')
        self.assertEqual(value['step'], 'sync')
        return {k: value[k] for k in ('id', 'owner', 'lease')}

    def finish(self, auth, events, cursor=''):
        return self.system('agent_finish', {**auth, 'result': {'artifact': {'events': events, 'scan_cursor': cursor,
                            'scanned': 1 if events else 0, 'done': not cursor}}})

    def event(self, key, days=10, reference='RN-42', status='Submitted', confirmed=True):
        proof = {'Submitted': 'received your application', 'Interview': 'invite you to interview', 'Offer': 'pleased to offer you'}[status]
        text = f'Northwind Hospital {proof} for Registered Nurse {reference}.'
        discovery = mail_scan.validate_discovery(proposal(reference=reference, status=status, proof=proof), text)
        discovery.update(status=status, confirmed=confirmed)
        return {'key': key, 'thread_id': 'thread-' + key, 'sender': 'hiring@example.test', 'subject': 'Application update',
                'at': int(time.time()) - days * 86400, 'application_id': '', 'status': status, 'ambiguous': not confirmed,
                'quote': proof, 'excerpt': text, 'calendar': {}, 'discovery': discovery}

    def applications(self):
        return [a for a in self.rpc('bootstrap')['applications'] if not a['demo']]

    def test_external_import_pagination_idempotency_dates_reference_and_calendar(self):
        self.assertEqual(self.applications(), [])
        scan = self.start()
        self.assertEqual(self.start()['id'], scan['id'])
        auth = self.claim()
        first = self.event('interview', days=10, status='Interview')
        first['calendar'] = {'uid': 'interview-uid', 'summary': 'Interview', 'start': {'dateTime': '2026-12-01T16:00:00+00:00'},
                             'end': {'dateTime': '2026-12-01T17:00:00+00:00'}, 'location': 'Video', 'status': 'confirmed'}
        self.assertEqual(self.finish(auth, [first], 'page-two')['status'], 'queued')
        self.assertEqual(self.rpc('gmail_scan_status')['scan']['scan']['imported'], 1)
        # A long historical scan yields to normal tracking instead of monopolizing the worker.
        self.assertEqual(self.system('agent_schedule')['scheduled'], 1)
        tracking = self.system('agent_claim')
        self.assertFalse(tracking['context'].get('manual_scan', False))
        self.system('agent_finish', {**{k: tracking[k] for k in ('id', 'owner', 'lease')},
                    'result': {'artifact': {'events': [], 'checkpoint': {'history_id': 'automatic-cursor'}}}})
        second = self.event('older-confirmation', days=180)
        self.finish(self.claim(), [second])
        app = self.applications()[0]
        self.assertEqual((app['job']['company'], app['job']['title'], app['status']), ('Northwind Hospital', 'Registered Nurse', 'Interview'))
        self.assertEqual(app['created_at'], second['at'])
        self.assertEqual(len(app['history']), 2)
        self.assertEqual(self.rpc('agent_events')['interviews'][0]['application_id'], app['id'])
        self.start()
        self.finish(self.claim(), [first], 'again')
        self.finish(self.claim(), [self.event('separate-requisition', reference='RN-99')])
        self.assertEqual(len(self.applications()), 2)
        self.assertEqual(self.rpc('gmail_scan_status')['scan']['scan']['imported'], 1)

    def test_review_ownership_cancel_and_disconnect_do_not_import_unconfirmed_work(self):
        self.start()
        self.finish(self.claim(), [self.event('unclear', confirmed=False)])
        review = self.rpc('gmail_scan_status')['reviews'][0]
        self.assertEqual(self.applications(), [])
        other = self.client.register_user('mail-scan-other', 'Fixture-password-2').data['token']
        self.client.set_auth_token(other)
        response = self.client.post('/function/gmail_scan_dismiss', json={'id': review['id']})
        self.assertIn('error', response.data['result'])
        self.client.set_auth_token(self.owner)
        self.rpc('agent_resolve_event', {'id': review['id'], 'application_id': '', 'company': 'Northwind Hospital',
                                       'title': 'Registered Nurse', 'status': 'Submitted'})
        self.assertEqual(len(self.applications()), 1)
        self.start()
        self.finish(self.claim(), [self.event('ignore', confirmed=False)])
        ignored = self.rpc('gmail_scan_status')['reviews'][0]
        self.rpc('gmail_scan_dismiss', {'id': ignored['id']})
        self.assertEqual(self.rpc('gmail_scan_status')['reviews'], [])
        self.assertFalse(any(event['key'] == 'ignore' for event in self.rpc('agent_events')['events']))
        scan = self.start()
        auth = self.claim()
        self.rpc('agent_cancel', {'id': scan['id']})
        self.client.clear_auth()
        response = self.client.post('/function/agent_finish', json={'token': 'scan-test-worker', **auth,
                                   'result': {'artifact': {'events': [self.event('late')], 'scanned': 1, 'scan_cursor': '', 'done': True}}})
        self.assertIn('error', response.data['result'])
        self.client.set_auth_token(self.owner)
        self.start()
        auth = self.claim()
        self.rpc('agent_disconnect', {'id': self.connection})
        self.assertEqual(self.finish(auth, [self.event('disconnected')])['status'], 'cancelled')
        self.assertEqual(len(self.applications()), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
