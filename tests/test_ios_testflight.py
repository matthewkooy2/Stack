"""Exercise the TestFlight script with every build/sign/upload command stubbed."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STUB = '#!/bin/sh\necho "$(basename "$0") $*" >> "$STACK_TEST_LOG"\n'
# Simulates Xcode: archive writes the app with Expo's CFBundleVersion; export writes the IPA.
XCODEBUILD = STUB + '''prev=; archive=; export=; action=build
for arg in "$@"; do
  case "$prev" in -archivePath) archive=$arg ;; -exportPath) export=$arg ;; esac
  case "$arg" in archive) action=archive ;; -exportArchive) action=export ;; esac
  prev=$arg
done
if [ "$action" = archive ] && [ "${STACK_TEST_NO_BUNDLE:-}" != 1 ]; then
  app="$archive/Products/Applications/Stack.app"
  mkdir -p "$app"
  echo bundled > "$app/main.jsbundle"
  printf '<plist version="1.0"><dict><key>CFBundleVersion</key><string>%s</string></dict></plist>' \\
    "${STACK_TEST_BUNDLE_VERSION:-$STACK_BUILD_NUMBER}" > "$app/Info.plist"
fi
if [ "$action" = export ]; then mkdir -p "$export"; echo ipa > "$export/Stack.ipa"; fi
'''

@unittest.skipUnless(sys.platform == 'darwin', 'TestFlight builds run only on macOS')
class TestFlightScript(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ('scripts/ci/ios-testflight.sh', 'native/app.config.js', 'native/build-config.js',
                     'native/package.json', 'native/package-lock.json'):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        (self.root / 'native/Podfile.lock').write_text('PODS:\n  - ExpoModulesCore\n\nSPEC CHECKSUMS:\n  ExpoModulesCore: ' + 'a' * 40 + '\n')
        (self.root / '.jac/mobile-rn/ios').mkdir(parents=True)
        (self.root / 'bin').mkdir()
        for name in ('node', 'npm', 'pod', 'xcrun'):
            target = self.root / 'bin' / name
            target.write_text(STUB); target.chmod(0o755)
        (self.root / 'bin/xcodebuild').write_text(XCODEBUILD)
        (self.root / 'bin/xcodebuild').chmod(0o755)
        (self.root / 'scripts/jac').write_text(STUB + 'echo "jac-cache $STACK_JAC_CACHE_HOME" >> "$STACK_TEST_LOG"\n'
                                              '[ "$1" = --version ] && echo "jac 0.37.21  (Darwin arm64)"\nexit 0\n')
        (self.root / 'scripts/jac').chmod(0o755)
        key = self.root / 'AuthKey_FIXTURE.p8'
        key.write_text('fixture')
        self.log = self.root / 'commands.log'
        self.ci = self.root / '.jac/ci-ios'
        inherited = {k: v for k, v in os.environ.items() if not k.startswith(('STACK_', 'ASC_', 'GITHUB_', 'APPLE_'))}
        self.env = {**inherited, 'PATH': str(self.root/'bin')+':'+os.environ['PATH'], 'STACK_TEST_LOG': str(self.log),
                    'STACK_API_URL': 'https://stack.example.com', 'GITHUB_RUN_NUMBER': '41', 'GITHUB_RUN_ATTEMPT': '2',
                    'RUNNER_TEMP': str(self.root / 'runner-temp'),
                    'APPLE_TEAM_ID': 'ABCDE12345', 'ASC_KEY_ID': 'FIXTURE', 'ASC_ISSUER_ID': 'fixture-issuer',
                    'ASC_AUTH_KEY_PATH': str(key)}

    def run_script(self, **env):
        return subprocess.run(['bash', str(self.root/'scripts/ci/ios-testflight.sh')], env={**self.env, **env},
                              capture_output=True, text=True)

    def commands(self, name):
        return [line for line in self.log.read_text().splitlines() if line.startswith(name + ' ')]

    def test_upload_archives_exports_and_uploads_numbered_build(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive, export = self.commands('xcodebuild')
        self.assertTrue(archive.endswith(' archive'), archive)
        self.assertIn('-authenticationKeyPath', archive)
        self.assertIn('DEVELOPMENT_TEAM=ABCDE12345', archive)
        self.assertIn('-exportArchive', export)
        self.assertIn('-authenticationKeyPath', export)
        options = plistlib.loads((self.ci/'ExportOptions.plist').read_bytes())
        self.assertIs(options['manageAppVersionAndBuildNumber'], False)
        self.assertEqual(options['teamID'], 'ABCDE12345')
        self.assertIn('--upload-app', self.commands('xcrun')[0])
        # The pinned compiler cannot build the mobile runtime from a cache inside the project.
        self.assertEqual(set(self.commands('jac-cache')), {f"jac-cache {self.root/'runner-temp/jac-tool-cache'}"})

    def test_validate_archives_unsigned_without_secrets_or_upload(self):
        env = {k: '' for k in ('APPLE_TEAM_ID', 'ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_AUTH_KEY_PATH')}
        result = self.run_script(STACK_TESTFLIGHT_MODE='validate', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        archive, = self.commands('xcodebuild')
        self.assertTrue(archive.endswith(' archive'), archive)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', archive)
        self.assertNotIn('-authenticationKeyPath', archive)
        self.assertEqual(self.commands('xcrun'), [])
        self.assertIn('41.2 validated', result.stdout)

    def test_unchanged_build_number_prevents_upload(self):
        result = self.run_script(STACK_TEST_BUNDLE_VERSION='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CFBundleVersion '1', expected '41.2'", result.stderr)
        self.assertEqual(len(self.commands('xcodebuild')), 1)
        self.assertEqual(self.commands('xcrun'), [])

    def test_stale_archive_cannot_satisfy_missing_bundle(self):
        stale = self.ci/'Stack.xcarchive/Products/Applications/Stack.app'
        stale.mkdir(parents=True)
        (stale/'main.jsbundle').write_text('stale')
        result = self.run_script(STACK_TEST_NO_BUNDLE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing its embedded JavaScript bundle', result.stderr)
        self.assertEqual(self.commands('xcrun'), [])

    def test_upload_requires_signing_configuration_before_building(self):
        result = self.run_script(ASC_KEY_ID='')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ASC_KEY_ID', result.stderr)
        self.assertFalse(self.log.exists())

    def test_invalid_mode_is_rejected(self):
        result = self.run_script(STACK_TESTFLIGHT_MODE='publish')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('upload or validate', result.stderr)

if __name__ == '__main__': unittest.main()
