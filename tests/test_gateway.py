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
        def upstream(path, body, authorization=''):
            calls.append(path)
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
                # Ownership-confirmed deletion remains available before admission
                # and after a partial cleanup; Jac still requires private auth.
                self.assertEqual(request('/function/account_delete'), 200)
                self.assertEqual(request('/function/account_delete_apple'), 200)
                for endpoint in gateway.APPLE_PUBLIC | gateway.APPLE_PRIVATE:
                    gateway._rates.clear()
                    self.assertEqual(request('/function/' + endpoint), 200)
                self.assertEqual(request('/sso/apple/begin'), 404)
                gateway._rates.clear()
                for _ in range(20):
                    self.assertEqual(request('/function/auth_apple_begin'), 200)
                self.assertEqual(request('/function/auth_apple_begin'), 429)
                gateway._rates.clear()
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

if __name__ == '__main__':
    unittest.main()
