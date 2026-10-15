"""Manual Apple HTTP cases; kept outside the approved blocking CI selection."""
import json
import threading
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import patch
from agents import gateway


class AppleGateway(unittest.TestCase):
    def setUp(self):
        gateway._rates.clear()
        self.server = gateway.ThreadingHTTPServer(('127.0.0.1', 0), gateway.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, path, body=None, authenticated=False, length=None):
        headers = {'Content-Type': 'application/json'}
        if authenticated:
            headers['Authorization'] = 'Bearer marked-session'
        if length is not None:
            headers['Content-Length'] = str(length)
        try:
            request = Request('http://127.0.0.1:' + str(self.server.server_port) + path,
                              data=json.dumps(body or {}).encode(), headers=headers)
            with urlopen(request, timeout=3) as response:
                return response.status
        except HTTPError as error:
            with error:
                return error.code

    def test_revoked_sessions_are_blocked_but_fresh_proof_deletion_can_recover(self):
        calls = []
        def upstream(path, body, authorization=''):
            calls.append((path, json.loads(body)))
            if path == '/function/auth_apple_session':
                return 200, b'{"data":{"result":{"ok":false,"code":"APPLE_REVOKED"}}}'
            return 200, b'{"data":{"result":{"ok":true}}}'
        with patch.object(gateway, 'upstream', side_effect=upstream):
            for path in ['/function/bootstrap', '/function/agent_admission', '/browser/stream', '/sso/google/begin']:
                self.assertEqual(self.request(path, authenticated=True), 401)
                self.assertNotIn(path, [item[0] for item in calls])
            self.assertEqual(calls[0][1], {'token': 'marked-session'})
            for name in ['auth_apple_delete_begin', 'account_delete_apple', 'account_delete']:
                self.assertEqual(self.request('/function/' + name, authenticated=True), 200)
            self.assertEqual(self.request('/function/auth_apple_session', authenticated=True), 404)

    def test_notification_retries_transient_failures_and_rejects_invalid_payloads(self):
        path = '/auth/apple/notifications'
        for code, expected in [('APPLE_INVALID', 400), ('APPLE_CONFLICT', 503),
                               ('APPLE_DISABLED', 503), ('APPLE_UNAVAILABLE', 503)]:
            raw = json.dumps({'data': {'result': {'ok': False, 'code': code}}}).encode()
            with patch.object(gateway, 'upstream', return_value=(200, raw)):
                self.assertEqual(self.request(path, {'payload': 'signed-fixture'}), expected)
        with patch.object(gateway, 'upstream', return_value=(200, b'{"data":{"result":{"ok":true}}}')) as transport:
            self.assertEqual(self.request(path, {'payload': 'signed-fixture'}), 200)
            self.assertEqual(transport.call_args.args[0], '/function/auth_apple_notification')
            self.assertEqual(self.request(path, {'payload': 'x', 'other': True}), 400)
            transport.reset_mock()
            self.assertEqual(self.request(path, {'payload': 'x'}, length=20001), 413)
            transport.assert_not_called()

    def test_apple_routes_preserve_deletion_and_have_separate_auth_rate_limits(self):
        with patch.object(gateway, 'upstream', return_value=(200, b'{"data":{"result":{"ok":true}}}')):
            for name in ['account_delete', 'account_delete_apple']:
                self.assertEqual(self.request('/function/' + name), 200)
            for endpoint in gateway.APPLE_PUBLIC | gateway.APPLE_PRIVATE:
                gateway._rates.clear()
                self.assertEqual(self.request('/function/' + endpoint), 200)
            self.assertEqual(self.request('/sso/apple/begin'), 404)
            gateway._rates.clear()
            for _ in range(20):
                self.assertEqual(self.request('/function/auth_apple_begin'), 200)
            self.assertEqual(self.request('/function/auth_apple_begin'), 429)


if __name__ == '__main__':
    unittest.main()
