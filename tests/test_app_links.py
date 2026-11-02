"""The app return must not leak credentials, accept a foreign redirect, or change old clients."""
import json
import os
import unittest
from unittest.mock import patch
from urllib.parse import urlencode
from agents import app_links


class AppLinksTests(unittest.TestCase):
    state = 's' * 43

    def start(self, **changes):
        args = dict(scope='openid email profile', response_type='code', code_challenge_method='S256',
                    state=self.state, redirect_uri='https://stack.example/sso/google/callback')
        args.update(changes)
        return '/auth/google/start?' + urlencode({'url': 'https://accounts.google.com/o/oauth2/v2/auth?' + urlencode(args)})

    @patch.dict(os.environ, {'STACK_SSO_CALLBACK_URL': 'https://stack.example/auth/google'})
    def test_native_sheet_is_bound_to_identity_scopes_origin_and_state(self):
        location, cookie = app_links.native_start(self.start())
        self.assertTrue(location.startswith('https://accounts.google.com/'))
        self.assertIn('Secure; HttpOnly; SameSite=Lax', cookie)
        self.assertEqual(app_links.native_return(cookie, self.state),
                         'com.matthewkooy.stack://auth/google?state=' + self.state)
        self.assertEqual(app_links.native_return(cookie, 'x' * 43), '')
        self.assertEqual(app_links.native_return('', self.state), '')
        for values in ({'scope': 'openid email profile gmail'}, {'redirect_uri': 'https://evil.example/callback'},
                       {'state': 'wrong'}, {'code_challenge_method': 'plain'}, {'response_type': 'token'}):
            with self.assertRaises(ValueError):
                app_links.native_start(self.start(**values))
        for path in (self.start() + '&url=other', self.start().replace('accounts.google.com', 'evil.example')):
            with self.assertRaises(ValueError):
                app_links.native_start(path)

    def test_universal_links_never_claim_oauth_callbacks_and_fallback_has_real_app_link(self):
        details = json.loads(app_links.association())['applinks']['details'][0]
        self.assertEqual(details['appIDs'], ['38BZ2B7677.com.matthewkooy.stack'])
        self.assertEqual(details['components'], [{'/': '/open'}, {'/': '/open/*'}])
        page = app_links.page(success=True).decode()
        self.assertIn('href="com.matthewkooy.stack://open"', page)
        self.assertIn('Continue in Stack', page)
        self.assertNotIn('<script', page)
        self.assertNotIn('javascript:', page)
        self.assertIn('://open/jobs', app_links.page(destination='jobs').decode())
        self.assertNotIn('attacker', app_links.page(destination='attacker').decode())

    @patch.dict(os.environ, {'STACK_SSO_HOST': 'https://dev.stackmvp.top'})
    def test_banner_uses_verified_store_record_and_escapes_configuration(self):
        self.assertIn('app-id=6820196890', app_links.banner())
        self.assertIn('app-argument=https://dev.stackmvp.top/open', app_links.banner())
        with patch.dict(os.environ, {'STACK_APP_STORE_ID': '"bad'}):
            self.assertEqual(app_links.banner(), '')
        with patch.dict(os.environ, {'STACK_SSO_HOST': '', 'STACK_SSO_CALLBACK_URL': 'https://dev.stackmvp.top/auth/google'}):
            self.assertIn('app-argument=https://dev.stackmvp.top/open', app_links.banner())


if __name__ == '__main__':
    unittest.main()
