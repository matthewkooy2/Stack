"""Configuration tests use fictional profile bytes and mocked macOS security calls."""
import base64
import datetime as dt
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('signing', ROOT / 'scripts/ci/ios-signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
CERT = b'fictional public certificate fixture'
IDENTITY = hashlib.sha1(CERT).hexdigest().upper()
TEAM = 'ABCDE12345'
UUID = '00000000-0000-0000-0000-000000000001'


def profile():
    return {'UUID': UUID, 'ExpirationDate': dt.datetime(2099, 1, 1),
            'TeamIdentifier': [TEAM], 'ApplicationIdentifierPrefix': ['OLDPREFIX1'],
            'Platform': ['iOS'], 'DeveloperCertificates': [CERT],
            'Entitlements': {'application-identifier': 'OLDPREFIX1.com.matthewkooy.stack',
                             'com.apple.developer.team-identifier': TEAM, 'get-task-allow': False}}


class SigningConfiguration(unittest.TestCase):
    def test_matching_distribution_profile_accepts_legacy_app_prefix(self):
        self.assertEqual(signing.validate_profile(profile(), TEAM, [IDENTITY]), (UUID, IDENTITY))

    def test_invalid_profiles_fail_closed(self):
        for key, value in [('ExpirationDate', dt.datetime(2000, 1, 1)), ('TeamIdentifier', ['OTHERTEAM1']),
                           ('ProvisionedDevices', []), ('ProvisionsAllDevices', True), ('Platform', ['macOS']),
                           ('UUID', '../unsafe'), ('DeveloperCertificates', [b'other certificate'])]:
            with self.subTest(key=key):
                fixture = profile(); fixture[key] = value
                with self.assertRaises(ValueError):
                    signing.validate_profile(fixture, TEAM, [IDENTITY])
        for key, value in [('get-task-allow', True), ('application-identifier', 'OLDPREFIX1.*'),
                           ('com.apple.developer.team-identifier', 'OTHERTEAM1')]:
            with self.subTest(key=key):
                fixture = profile(); fixture['Entitlements'][key] = value
                with self.assertRaises(ValueError):
                    signing.validate_profile(fixture, TEAM, [IDENTITY])

    def test_no_private_key_identity_or_ambiguous_identity_rejected(self):
        with self.assertRaises(ValueError):
            signing.validate_profile(profile(), TEAM, [])
        fixture = profile(); fixture['DeveloperCertificates'].append(b'second')
        with self.assertRaises(ValueError):
            signing.validate_profile(fixture, TEAM, [IDENTITY, hashlib.sha1(b'second').hexdigest().upper()])

    def test_missing_assets_never_call_security(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(signing, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Missing reusable'):
                signing.prepare()
            run.assert_not_called()

    def test_security_failure_never_forwards_output_or_password(self):
        failed = SimpleNamespace(returncode=1, stdout=b'fictional private output', stderr=b'fictional password')
        with patch.object(signing.subprocess, 'run', return_value=failed) as process:
            with self.assertRaisesRegex(signing.SigningError, '^security signing operation failed$'):
                signing.run('security', 'import', 'fixture', '-P', 'fictional password')
            self.assertEqual(process.call_args.kwargs, {'capture_output': True})

    def test_malformed_asset_cleanup_does_not_call_apple_or_security(self):
        with tempfile.TemporaryDirectory() as temp:
            env = {'RUNNER_TEMP': temp, 'GITHUB_ENV': str(Path(temp) / 'env'), 'APPLE_TEAM_ID': TEAM,
                   'IOS_DISTRIBUTION_P12_BASE64': 'invalid!', 'IOS_DISTRIBUTION_P12_PASSWORD': 'fixture',
                   'IOS_APP_STORE_PROFILE_BASE64': 'invalid!'}
            with patch.dict(os.environ, env, clear=True), patch.object(signing, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'Invalid base64'):
                    signing.prepare()
                signing.cleanup()
                run.assert_not_called()
                self.assertFalse(signing.state_dir().exists())

    def test_restore_and_cleanup_use_temporary_assets_only(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / 'home'; home.mkdir()
            env_file = Path(temp) / 'env'
            env = {'RUNNER_TEMP': temp, 'GITHUB_ENV': str(env_file), 'APPLE_TEAM_ID': TEAM,
                   'IOS_DISTRIBUTION_P12_BASE64': base64.b64encode(b'fictional p12 fixture').decode(),
                   'IOS_DISTRIBUTION_P12_PASSWORD': 'fixture-password',
                   'IOS_APP_STORE_PROFILE_BASE64': base64.b64encode(b'fictional CMS fixture').decode()}
            calls = []
            def security(*args):
                calls.append(args)
                if args[1] == 'cms': return plistlib.dumps(profile())
                if args[1] == 'create-keychain': Path(args[-1]).touch()
                if args[1:3] == ('list-keychains', '-d') and '-s' not in args:
                    return b'"/fixture/login.keychain-db"\n'
                if args[1] == 'find-identity':
                    return f'1) {IDENTITY} "Apple Distribution: Fixture"\n1 valid identities found'.encode()
                return b''
            with patch.dict(os.environ, env, clear=True), patch.object(Path, 'home', return_value=home), patch.object(signing, 'run', side_effect=security):
                signing.prepare()
                restored = home / 'Library/MobileDevice/Provisioning Profiles' / f'{UUID}.mobileprovision'
                self.assertTrue(restored.exists())
                self.assertFalse((signing.state_dir() / 'distribution.p12').exists())
                self.assertIn(f'IOS_SIGNING_IDENTITY={IDENTITY}', env_file.read_text())
                self.assertTrue(any('-s' in call and '/fixture/login.keychain-db' in call for call in calls))
                signing.cleanup()
                self.assertFalse(restored.exists())
                self.assertFalse(signing.state_dir().exists())

    def test_export_options_are_manual_and_exact(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {
                'APPLE_TEAM_ID': TEAM, 'IOS_SIGNING_IDENTITY': IDENTITY, 'IOS_PROFILE_UUID': UUID,
                'IOS_SIGNING_KEYCHAIN': '/fixture/keychain'}, clear=True):
            out = Path(temp) / 'options.plist'; signing.export_options(out)
            options = plistlib.loads(out.read_bytes())
            self.assertEqual(options['signingStyle'], 'manual')
            self.assertEqual(options['signingCertificate'], IDENTITY)
            self.assertEqual(options['provisioningProfiles'], {'com.matthewkooy.stack': UUID})
            self.assertIs(options['manageAppVersionAndBuildNumber'], False)

    def test_keychain_delete_failure_still_removes_decoded_assets_and_profile(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {'RUNNER_TEMP': temp}, clear=True):
            directory = signing.state_dir(); directory.mkdir()
            for name in ('signing.keychain-db', 'distribution.p12', 'app.mobileprovision'):
                (directory / name).write_bytes(b'fictional fixture')
            installed = Path(temp) / 'installed.mobileprovision'; installed.touch()
            (directory / 'installed-profile').write_text(str(installed))
            with patch.object(signing, 'run', side_effect=signing.SigningError('security signing operation failed')):
                with self.assertRaisesRegex(ValueError, 'cleanup incomplete'):
                    signing.cleanup()
            self.assertFalse(installed.exists())
            self.assertFalse((directory / 'distribution.p12').exists())
            self.assertFalse((directory / 'app.mobileprovision').exists())
            self.assertTrue((directory / 'signing.keychain-db').exists())

    def test_upload_routes_cannot_request_automatic_provisioning(self):
        for name in ('ios-testflight.sh', 'ios-swift-testflight.sh'):
            script = (ROOT / 'scripts/ci' / name).read_text()
            self.assertNotIn('-allowProvisioningUpdates', script)
            self.assertNotIn('-authenticationKeyPath', script)
            self.assertNotIn('CODE_SIGN_STYLE=Automatic', script)
            self.assertIn('CODE_SIGN_STYLE=Manual', script)
        expo = (ROOT / 'scripts/ci/ios-testflight.sh').read_text()
        self.assertIn("config.build_settings['PROVISIONING_PROFILE_SPECIFIER']", expo)
        self.assertNotIn('PROVISIONING_PROFILE_SPECIFIER="$IOS_PROFILE_UUID"', expo)
        for name in ('testflight.yml', 'swift-testflight.yml'):
            workflow = (ROOT / '.github/workflows' / name).read_text()
            self.assertIn('python3 scripts/ci/ios-signing.py prepare', workflow)
            self.assertIn('if: always()\n        run: python3 scripts/ci/ios-signing.py cleanup', workflow)


if __name__ == '__main__':
    unittest.main()
