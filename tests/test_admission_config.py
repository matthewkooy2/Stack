"""Private config boundary; synthetic files only, no external calls."""
import json
import os
from pathlib import Path
import tempfile
import traceback
import unittest
from unittest.mock import patch
from agents import contracts


class AdmissionConfig(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='stack-admission-config-')
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'private-marker.json'
        env = patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(self.path)})
        env.start()
        self.addCleanup(env.stop)

    def test_missing_and_incomplete_config_close_admission(self):
        self.assertIs(contracts.config()['invite_only'], True)
        for raw in ({}, {'model': 'synthetic'}, {'monthly_cents': 0}):
            with self.subTest(raw=raw):
                self.path.write_text(json.dumps(raw))
                self.assertIs(contracts.config()['invite_only'], True)

    def test_only_boolean_false_opens_admission(self):
        for value in (True, None, 0, 1, '', 'false', 'true', [], {}):
            with self.subTest(value=value):
                self.path.write_text(json.dumps({'invite_only': value}))
                self.assertIs(contracts.config()['invite_only'], True)
        self.path.write_text('{"invite_only":false}')
        self.assertIs(contracts.config()['invite_only'], False)

    def assert_safe_failure(self):
        with self.assertRaises(ValueError) as failure:
            contracts.config()
        self.assertIn('Check STACK_AGENT_CONFIG', str(failure.exception))
        self.assertIsNone(failure.exception.__cause__)
        self.assertTrue(failure.exception.__suppress_context__)
        rendered = ''.join(traceback.format_exception(failure.exception))
        self.assertNotIn('secret-marker', rendered)
        self.assertNotIn(str(self.path), rendered)

    def test_malformed_and_non_object_config_fail_without_secrets(self):
        for text in ('secret-marker', '{"secret-marker":', 'null', '[]', 'false', '42', '"secret-marker"'):
            with self.subTest(text=text):
                self.path.write_text(text)
                self.assert_safe_failure()
        self.path.write_bytes(b'\xffsecret-marker')
        self.assert_safe_failure()

    def test_invalid_limits_do_not_leak_values_or_allow_public_admission(self):
        for key in ('monthly_cents', 'user_monthly_cents', 'local_cli_daily_limit',
                    'input_cents_per_million', 'output_cents_per_million', 'max_output_tokens'):
            for value in ('secret-marker', None, {}, float('inf')):
                with self.subTest(key=key, value=value):
                    self.path.write_text(json.dumps({'invite_only': False, key: value}))
                    self.assert_safe_failure()

    def test_unreadable_config_fails_without_path_or_os_details(self):
        with patch.object(Path, 'read_text', side_effect=PermissionError('secret-marker')):
            self.assert_safe_failure()
        self.path.mkdir()
        self.assert_safe_failure()

    def test_configuration_is_reloaded_after_public_access_is_removed(self):
        self.path.write_text('{"invite_only":false}')
        self.assertFalse(contracts.config()['invite_only'])
        self.path.unlink()
        self.assertTrue(contracts.config()['invite_only'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
