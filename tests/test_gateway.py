"""Real HTTP boundary checks with a fixture upstream and no account data."""
import json
import threading
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import patch
from agents import gateway

class Gateway(unittest.TestCase):
    def test_revoked_sessions_are_blocked_but_fresh_proof_deletion_can_recover(self):
        calls = []
        def upstream(path, body, authorization=''):
            calls.append((path,json.loads(body)))
            if path == '/function/auth_apple_session':
                return 200, b'{"data":{"result":{"ok":false,"code":"APPLE_REVOKED"}}}'
            return 200, b'{"data":{"result":{"ok":true}}}'
        gateway._rates.clear()
        server = gateway.ThreadingHTTPServer(('127.0.0.1',0),gateway.Handler)
        thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        def request(path):
            try:
                with urlopen(Request('http://127.0.0.1:'+str(server.server_port)+path,data=b'{}',
                    headers={'Authorization':'Bearer marked-session','Content-Type':'application/json'})) as response:
                    return response.status
            except HTTPError as error:
                with error: return error.code
        try:
            with patch.object(gateway,'upstream',side_effect=upstream):
                for path in ['/function/bootstrap','/function/agent_admission','/browser/stream','/sso/google/begin']:
                    self.assertEqual(request(path),401)
                    self.assertNotIn(path,[x[0] for x in calls])
                self.assertEqual(calls[0][1],{'token':'marked-session'})
                for name in ['auth_apple_delete_begin','account_delete_apple','account_delete']:
                    self.assertEqual(request('/function/'+name),200)
                self.assertEqual(request('/function/auth_apple_session'),404)
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_notification_retries_transient_failures_and_rejects_invalid_payloads(self):
        gateway._rates.clear()
        server = gateway.ThreadingHTTPServer(('127.0.0.1',0),gateway.Handler)
        thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        def request(body, length=None):
            headers={'Content-Type':'application/json'}
            if length: headers['Content-Length']=str(length)
            try:
                with urlopen(Request('http://127.0.0.1:'+str(server.server_port)+'/auth/apple/notifications',
                    data=json.dumps(body).encode(),headers=headers),timeout=3) as response:
                    return response.status
            except HTTPError as error:
                with error: return error.code
        try:
            for code, expected in [('APPLE_INVALID',400),('APPLE_CONFLICT',503),('APPLE_DISABLED',503),('APPLE_UNAVAILABLE',503)]:
                raw=json.dumps({'data':{'result':{'ok':False,'code':code}}}).encode()
                with patch.object(gateway,'upstream',return_value=(200,raw)):
                    self.assertEqual(request({'payload':'signed-fixture'}),expected)
            with patch.object(gateway,'upstream',return_value=(200,b'{"data":{"result":{"ok":true}}}')) as transport:
                self.assertEqual(request({'payload':'signed-fixture'}),200)
                self.assertEqual(transport.call_args.args[0],'/function/auth_apple_notification')
                self.assertEqual(request({'payload':'x','other':True}),400)
                transport.reset_mock()
                self.assertEqual(request({'payload':'x'},20001),413)
                transport.assert_not_called()
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_all_user_routes_require_admission_and_worker_routes_stay_private(self):
        calls = []
        def upstream(path, body, authorization=''):
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
