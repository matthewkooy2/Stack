"""Exercise the release launcher with every build/sign/install command stubbed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ReleaseLauncher(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ('scripts/ios', 'scripts/ios-release', 'native/app.config.js', 'native/build-config.js'):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        (self.root / '.jac/mobile-rn').mkdir(parents=True)
        (self.root / 'bin').mkdir()
        stub = '#!/bin/sh\necho "$(basename "$0") $*" >> "$STACK_TEST_LOG"\n'
        for name in ('node', 'pod', 'xcrun', 'open', 'security'):
            target = self.root / 'bin' / name
            target.write_text(stub); target.chmod(0o755)
        (self.root / 'scripts/jac').write_text(stub)
        (self.root / 'scripts/jac').chmod(0o755)
        xcode = self.root / 'bin/xcodebuild'
        xcode.write_text(stub + 'if [ "${STACK_TEST_NO_BUNDLE:-}" != 1 ]; then\n mkdir -p .jac/xcode-device/Build/Products/Release-iphoneos/Stack.app\n echo bundled > .jac/xcode-device/Build/Products/Release-iphoneos/Stack.app/main.jsbundle\nfi\n')
        xcode.chmod(0o755)
        self.log = self.root / 'commands.log'
        self.env = {**os.environ, 'PATH':str(self.root/'bin')+':'+os.environ['PATH'], 'STACK_TEAM':'fixture',
                    'STACK_DEVICE':'fixture', 'STACK_API_URL':'https://stack.example.com', 'STACK_TEST_LOG':str(self.log)}

    def test_release_bundles_and_installs_release_without_metro(self):
        subprocess.run([str(self.root/'scripts/ios-release')], env=self.env, check=True, capture_output=True)
        log = self.log.read_text()
        self.assertIn('-configuration Release', log)
        self.assertIn('Products/Release-iphoneos/Stack.app', log)
        self.assertIn('prebuild --platform ios --no-install', log)
        self.assertNotIn('expo start', log)
        self.assertNotIn('security ', log)

    def test_missing_bundle_prevents_install(self):
        result = subprocess.run([str(self.root/'scripts/ios-release')], env={**self.env,'STACK_TEST_NO_BUNDLE':'1'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing its embedded JavaScript bundle', result.stderr)
        self.assertNotIn('xcrun ', self.log.read_text())

if __name__ == '__main__': unittest.main()
