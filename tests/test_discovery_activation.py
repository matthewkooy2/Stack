"""Offline checks of collector activation boundaries; no production writes."""
import importlib.util
from pathlib import Path
import unittest
import subprocess
import sys
import tempfile
from contextlib import ExitStack
from types import SimpleNamespace
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

    def exercise_activation(self, apply=False, batch='gh: 12 listings', fail_start=False):
        with tempfile.TemporaryDirectory() as folder, ExitStack() as mocks:
            root = Path(folder)
            (root / 'deploy').mkdir()
            (root / 'deploy' / activation.UNIT).write_text('[Service]\nUser=stack\n')
            env = root / 'discovery.env'
            env.write_text('STACK_WORKER_API=http://127.0.0.1:8000\n')
            lock = root / 'lock'
            lock.touch()
            dest = root / 'installed.service'
            commands = []
            def run(args, **kwargs):
                commands.append(args)
                if args[0] == 'systemd-run':
                    return batch
                if fail_start and args[:3] == ['systemctl', 'enable', '--now']:
                    raise subprocess.CalledProcessError(1, args)
                if args[:2] == ['systemctl', 'is-enabled']:
                    return 'enabled'
                return 'active'
            for name, value in [('ROOT', root), ('DEST', dest), ('ENV', env), ('LOCK', lock)]:
                mocks.enter_context(patch.object(activation, name, value))
            mocks.enter_context(patch.object(activation.os, 'geteuid', return_value=0))
            mocks.enter_context(patch.object(activation.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=999)))
            mocks.enter_context(patch.object(activation, 'protected', return_value={'private':'unchanged'}))
            mocks.enter_context(patch.object(activation, 'validate_source'))
            mocks.enter_context(patch.object(activation, 'run', side_effect=run))
            cleanup = mocks.enter_context(patch.object(activation.subprocess, 'run', return_value=SimpleNamespace(returncode=1)))
            mocks.enter_context(patch.object(sys, 'argv', ['activation'] + (['--apply', '--source', 'gh'] if apply else [])))
            error = None
            try:
                activation.main()
            except BaseException as exc:
                error = exc
            return commands, dest.exists(), error, cleanup.call_args_list

    def test_readonly_preflight_does_not_run_or_install_worker(self):
        commands, installed, error, _ = self.exercise_activation()
        self.assertIsNone(error)
        self.assertFalse(installed)
        self.assertFalse(any(c[0] == 'systemd-run' or c[:2] == ['systemctl', 'enable'] for c in commands))

    def test_zero_listing_batch_never_enables_collector(self):
        commands, installed, error, _ = self.exercise_activation(apply=True, batch='gh: 0 listings')
        self.assertIsInstance(error, AssertionError)
        self.assertFalse(installed)
        self.assertFalse(any(c[:2] == ['systemctl', 'enable'] for c in commands))

    def test_failed_start_removes_only_new_unit(self):
        _, installed, error, cleanup = self.exercise_activation(apply=True, fail_start=True)
        self.assertIsInstance(error, subprocess.CalledProcessError)
        self.assertFalse(installed)
        self.assertTrue(any(c.args[0][:3] == ['systemctl', 'disable', '--now'] for c in cleanup))


if __name__ == '__main__':
    unittest.main()
