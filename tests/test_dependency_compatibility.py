"""Dependency upgrade contracts, using synthetic data and no network calls.

Run in the pinned Jac runtime with tests/dependency_compatibility_tests.jac.
"""
import base64
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from agents.browser import BrowserPool
from agents.security import seal, unseal
from cryptography.fernet import Fernet
from google.auth.transport.requests import Request
import requests

# Public test key and ciphertext created with cryptography 46.0.5. This is
# intentionally synthetic: do not substitute a real account or browser cache.
KEY = base64.urlsafe_b64encode(b'K' * 32).decode()
OLD_CONNECTION = 'gAAAAABlU_EAGy1IC5qbzNGbMISGfCZPxl4QJJH4Oet7WI97AV2dbW0zjTi1EH6ZqcrM_1FInf4qW9TKqFMl9UbmCcjwI-9p3jNtrXpAzmIQNnDnflZ_G_xrsnQ1qIBWlIucbDh3ZcDV0mk5bJdIeOFtyUm91cper-uUE96yLUDHx0eu7fCBkBQ='
OLD_BROWSER = 'gAAAAABlU_EANYOej1rpaRSCHV4I6vr44dM3gLt1aDzbOToKzej7iULTMd_wcs4lbYiZQdnF6hG6Et5q4avElvdI2pJdxPFsRMRGrlNmNcdznRkE8FVGFQDVaWdQUJ2XtVLfHrsHWbDpuWlZfandwRPNHb3R63Hbfg=='
CONNECTION = {'access_token': 'synthetic-compatibility-token', 'provider': 'test'}
BROWSER = {'storage': {'cookies': [], 'origins': []}, 'fields': []}


class DependencyCompatibility(unittest.TestCase):
    def test_existing_account_connections_remain_readable(self):
        with patch.dict(os.environ, {'STACK_CONNECTION_KEY': KEY}):
            self.assertEqual(unseal(OLD_CONNECTION), CONNECTION)

    def test_new_connections_round_trip_without_changing_the_payload(self):
        with patch.dict(os.environ, {'STACK_CONNECTION_KEY': KEY}):
            token = seal(CONNECTION)
            self.assertEqual(unseal(token), CONNECTION)
            self.assertEqual(json.loads(Fernet(KEY.encode()).decrypt(token.encode())), CONNECTION)

    def test_missing_wrong_or_corrupt_keys_fail_without_exposing_content(self):
        wrong_key = base64.urlsafe_b64encode(b'W' * 32).decode()
        for key, token in [('', OLD_CONNECTION), (wrong_key, OLD_CONNECTION), (KEY, 'invalid')]:
            with self.subTest(key=bool(key), corrupt=token == 'invalid'), \
                    patch.dict(os.environ, {'STACK_CONNECTION_KEY': key}):
                with self.assertRaises(ValueError) as error:
                    unseal(token)
                self.assertEqual(str(error.exception),
                                 'Connection could not be unlocked. Reconnect your account.')

    def test_existing_browser_sessions_keep_the_24_hour_expiry(self):
        pool = BrowserPool.__new__(BrowserPool)  # No Playwright process needed.
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
                'STACK_BROWSER_STORAGE': directory, 'STACK_BROWSER_SESSION_KEY': KEY}):
            path = pool.path('test-owner', 'test-run')
            path.parent.mkdir(parents=True)
            path.write_text(OLD_BROWSER)
            with patch('time.time', return_value=1700000010):
                self.assertEqual(pool.load('test-owner', 'test-run'), BROWSER)
            with patch('time.time', return_value=1700086401):
                self.assertEqual(pool.load('test-owner', 'test-run'), {})
            self.assertFalse(path.exists(), 'expired cache must be removed')

    def test_browser_checkpoints_remain_encrypted_and_filter_password_fields(self):
        pool = BrowserPool.__new__(BrowserPool)
        field = {'type': 'text', 'value': 'synthetic'}
        pool.sessions = {('test-owner', 'test-run'): {
            'context': SimpleNamespace(storage_state=lambda: BROWSER['storage']),
            'page': SimpleNamespace(evaluate=lambda _: [field, {'type': 'password', 'value': 'private'}]),
        }}
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
                'STACK_BROWSER_STORAGE': directory, 'STACK_BROWSER_SESSION_KEY': KEY}):
            pool.checkpoint('test-owner', 'test-run')
            path = pool.path('test-owner', 'test-run')
            self.assertNotIn(b'synthetic', path.read_bytes())
            self.assertEqual(pool.load('test-owner', 'test-run'),
                             {'storage': BROWSER['storage'], 'fields': [field]})
            if os.name != 'nt':
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_google_auth_transport_prepares_the_request_with_updated_requests(self):
        response = requests.Response()
        response.status_code = 200
        response._content = b'{"access_token":"synthetic"}'
        response.headers['Content-Type'] = 'application/json'
        with requests.Session() as session, patch.object(session, 'send', return_value=response) as send:
            result = Request(session=session)(url='https://oauth2.googleapis.com/token', method='POST',
                                              body=b'grant_type=synthetic',
                                              headers={'Content-Type': 'application/x-www-form-urlencoded'},
                                              timeout=5)
            self.assertEqual(result.status, 200)
            self.assertEqual(result.data, response.content)
            prepared = send.call_args.args[0]
            self.assertEqual(prepared.method, 'POST')
            self.assertEqual(prepared.url, 'https://oauth2.googleapis.com/token')
            self.assertEqual(prepared.body, b'grant_type=synthetic')
            self.assertEqual(send.call_args.kwargs['timeout'], 5)


if __name__ == '__main__':
    unittest.main()
