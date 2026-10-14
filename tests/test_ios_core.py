"""The curated gate must never accept an absent, skipped or misidentified XCTest."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ios_core', ROOT / 'scripts/ci/ios-core.py')
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)


class NativeSelection(unittest.TestCase):
    def log(self):
        return '\n'.join("Test Case '-[" + target + '.' + owner + ' ' + method + "]' passed (0.1 seconds)."
                         for target, owner, method in (case.split('/') for case in core.selected()))

    def test_actual_selection_is_present_and_complete(self):
        core.require_passed(self.log())

    def test_missing_skipped_or_wrong_class_cannot_count_as_passed(self):
        log = self.log()
        for replacement in ('', log.replace(' passed ', ' skipped ', 1),
                            log.replace('AppStoreSessionTests', 'OtherClass', 1)):
            with self.subTest(replacement=replacement[:80]), self.assertRaises(ValueError):
                core.require_passed(replacement)

    def test_retries_cannot_hide_a_missing_single_execution(self):
        with self.assertRaises(ValueError):
            core.require_passed(self.log() + '\n' + self.log())

    @unittest.skipIf(os.name == 'nt', 'Run shell argument boundary on Linux or macOS')
    def test_build_and_full_test_have_no_empty_selector_and_core_forwards_all_33(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts/ci/resume-review').mkdir(parents=True)
            (root / 'ios').mkdir()
            (root / 'bin').mkdir()
            script = root / 'scripts/ci/ios-swift.sh'
            shutil.copy2(ROOT / 'scripts/ci/ios-swift.sh', script)
            for name in ('ios-swift-static.py', 'resume-review/prepare.py'):
                (root / 'scripts/ci' / name).write_text('pass\n')
            (root / 'scripts/ci/ios-core.py').write_text('print(' + repr('\n'.join('-only-testing:' + case for case in core.selected())) + ')\n')
            for name, body in [('uname', 'echo Darwin'), ('xcodegen', 'exit 0'),
                               ('xcodebuild', 'printf "%s\\n" "$@" > "$STUB_ARGUMENTS"')]:
                executable = root / 'bin' / name
                executable.write_text('#!/bin/sh\n' + body + '\n')
                executable.chmod(0o755)
            arguments = root / 'arguments.txt'
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
                       STACK_IOS_DESTINATION='platform=iOS Simulator,name=synthetic',
                       STUB_ARGUMENTS=str(arguments))
            for mode in ('build', 'test', 'core'):
                subprocess.run(['bash', str(script), mode], env=env, check=True, capture_output=True)
                values = arguments.read_text().splitlines()
                self.assertNotIn('', values)
                selectors = [value for value in values if value.startswith('-only-testing:')]
                self.assertEqual(selectors, ['-only-testing:' + case for case in core.selected()] if mode == 'core' else [])


if __name__ == '__main__':
    unittest.main()
