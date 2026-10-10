"""Offline checks of collector activation boundaries; no production writes."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('activation', Path(__file__).parents[1] /
                                           'deploy/pc-host/stack_discovery_activation.py')
activation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activation)


class ActivationTests(unittest.TestCase):
    def test_refresh_requires_matching_positive_batch(self):
        self.assertTrue(activation.refreshed('gh: 12 listings\n', 'gh'))
        for text in ('', 'gh: 0 listings', 'other: 12 listings', 'gh: error'):
            self.assertFalse(activation.refreshed(text, 'gh'))

    def test_rejects_nonpublic_or_unapproved_source(self):
        for raw in ('{"adapter":"adzuna","approved":true}',
                    '{"adapter":"greenhouse","approved":false}',
                    '{"adapter":"career","approved":true,"renderer":"playwright"}'):
            with patch.object(activation, 'run', return_value=raw):
                with self.assertRaises(AssertionError):
                    activation.validate_source('configured-source')

    def test_accepts_existing_public_source(self):
        with patch.object(activation, 'run', return_value='{"adapter":"greenhouse","approved":true}'):
            activation.validate_source('employer:example')

    def test_source_is_not_shell_or_sql(self):
        with patch.object(activation, 'run') as run:
            with self.assertRaises(AssertionError):
                activation.validate_source("bad'; DROP TABLE anchors;")
            run.assert_not_called()
        command = activation.service_command('employer:example')
        self.assertEqual(command[-3:], ['--once', '--source', 'employer:example'])
        self.assertIn('--property=RuntimeMaxSec=180', command)


if __name__ == '__main__':
    unittest.main()
