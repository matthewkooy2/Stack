"""Real HTTP boundary checks with a fixture upstream and no account data."""
import json
import threading
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import patch
from agents import gateway

class Gateway(unittest.TestCase):
    def test_all_user_routes_require_admission_and_worker_routes_stay_private(self):
        calls = []
        def upstream(path, body, authorization='', **kwargs):
            calls.append(path)
            if path == '/function/auth_apple_session':
                return 200, b'{"data":{"result":{"ok":true}}}'
            if path == '/function/agent_admission':
                return 200, json.dumps({'data': {'result': {'admitted': authorization == 'Bearer fixture'}}}).encode()
            return 200, b'{"ok":true}'
        gateway._rates.clear()
        server = gateway.ThreadingHTTPServer(('127.0.0.1', 0), gateway.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(path, authenticated=False):
            headers = {'Content-Type': 'application/json'}
            if authenticated:
                headers['Authorization'] = 'Bearer fixture'
            try:
                with urlopen(Request('http://127.0.0.1:' + str(server.server_port) + path, data=b'{}', headers=headers)) as response:
                    return response.status
            except HTTPError as error:
                return error.code
        try:
            with patch.object(gateway, 'upstream', side_effect=upstream):
                self.assertEqual(request('/function/agent_features'), 403)
                for endpoint in sorted(gateway.PERSONAL):
                    self.assertEqual(request('/function/' + endpoint, True), 200, endpoint)
                for endpoint in ['agent_claim', 'agent_finish', 'agent_authorize', 'agent_worker_resume_source', 'agent_model_log', 'agent_upgrade_workflows', 'resume_processing_claim', 'resume_processing_stage', 'resume_processing_finish', 'transcription_processing_claim', 'transcription_processing_progress', 'transcription_processing_finish','transcription_processing_runtime']:
                    self.assertEqual(request('/function/' + endpoint, True), 404, endpoint)
                    self.assertNotIn('/function/' + endpoint, calls)
                gateway._rates.clear()
                for _ in range(20):
                    self.assertEqual(request('/user/login'), 200)
                self.assertEqual(request('/user/login'), 429)
                # User endpoints have a separate, larger quota.
                self.assertEqual(request('/function/agent_features', True), 200)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_linkedin_bypasses_admission_rate_and_body_limits_but_keeps_account_auth(self):
        calls = []
        def upstream(path, body, authorization='', **kwargs):
            calls.append((path, kwargs))
            if authorization != 'Bearer fixture':
                return 401, b'{"ok":false,"data":{"result":{}}}'
            if path == '/function/auth_apple_session':
                return 200, b'{"data":{"result":{"ok":true}}}'
            if path.endswith('agent_admission'):
                return 200, b'{"data":{"result":{"admitted":false}}}'
            result = {'id': 'linkedin-fixture', 'kind': 'linkedin'}
            if json.loads(body).get('id') == 'other': result['kind'] = 'autofill'
            return 200, json.dumps({'ok': True, 'data': {'result': result}}).encode()
        server = gateway.ThreadingHTTPServer(('127.0.0.1', 0), gateway.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True);thread.start()
        def request(name, body, token='fixture'):
            headers = {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token}
            try:
                with urlopen(Request('http://127.0.0.1:' + str(server.server_port) + '/function/' + name,
                                    data=json.dumps(body).encode(), headers=headers), timeout=10) as response:
                    return response.status
            except HTTPError as error: return error.code
        try:
            with patch.object(gateway, 'upstream', side_effect=upstream):
                with gateway._rate_lock:
                    gateway._rates[('127.0.0.1', int(gateway.time.time()/60), False)] = 10000
                self.assertEqual(request('agent_linkedin_start', {'url': 'http://fixture.test'}), 200)
                for name in ('agent_run', 'agent_respond', 'agent_retry', 'agent_cancel',
                             'agent_browser', 'agent_browser_control', 'agent_browser_subscribe'):
                    self.assertEqual(request(name, {'id': 'linkedin-fixture'}), 200)
                self.assertEqual(request('agent_browser', {'id': 'linkedin-fixture',
                    'event': {'type': 'text', 'text': 'x' * 15_000_100}}), 200)
                self.assertFalse(any(path.endswith('agent_admission') for path, _ in calls))
                self.assertTrue(all(options.get('timeout', 'missing') is None for _, options in calls))
                self.assertEqual(request('agent_linkedin_start', {}, token='invalid'), 401)
                self.assertEqual(request('agent_run', {'id': 'other'}), 429)
                gateway._rates.clear()
                self.assertEqual(request('agent_run', {'id': 'other'}), 403)
        finally:
            server.shutdown();server.server_close();thread.join();gateway._rates.clear()

if __name__ == '__main__':
    unittest.main()
