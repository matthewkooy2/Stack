"""The curated gate must never accept an absent, skipped or misidentified XCTest."""
import importlib.util
from pathlib import Path
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


if __name__ == '__main__':
    unittest.main()
