import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('worktree_dev', Path(__file__).resolve().parents[1] / 'scripts/worktree-dev.py')
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


class WorktreeDevelopment(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.target = Path(self.temporary.name) / 'feature'
        self.previous = Path(self.temporary.name) / 'mainworktree'
        self.registered = {'feature': self.target, 'mainworktree': self.previous}
        for filename in ['node_modules/expo/bin/cli', 'metro.config.js', 'babel.config.js', 'app.config.js', 'app/App.tsx', 'jac-asset-registry.js']:
            path = self.target / '.jac/mobile-rn' / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        self.addCleanup(patch.stopall)
        patch.dict(dev.os.environ, {}, clear=True).start()
        self.running = patch.object(dev, 'running', return_value=[(123, self.previous)]).start()
        self.stop = patch.object(dev, 'stop').start()
        self.start = patch.object(dev, 'start').start()
        self.compile = patch.object(dev.subprocess, 'run').start()
        self.refresh = patch.object(dev, 'Refresh').start()
        self.cli = patch.object(dev, 'check_cli').start()
        patch.object(dev.subprocess, 'check_output', return_value='main\n').start()

    def test_unknown_worktree_never_stops_preview(self):
        with self.assertRaisesRegex(RuntimeError, 'Unknown worktree'):
            dev.switch('../elsewhere', self.registered)
        self.stop.assert_not_called()

    def test_unprepared_worktree_never_stops_preview(self):
        (self.target / '.jac/mobile-rn/app.config.js').unlink()
        with self.assertRaisesRegex(RuntimeError, 'Set up'):
            dev.switch('feature', self.registered)
        self.stop.assert_not_called()

    def test_external_database_override_rejected(self):
        with patch.dict(dev.os.environ, {'JAC_DB_URL': 'postgres://shared'}):
            with self.assertRaisesRegex(RuntimeError, 'Unset JAC_DB_URL'):
                dev.switch('feature', self.registered)
        self.stop.assert_not_called()

    def test_compile_failure_keeps_previous_preview(self):
        self.compile.side_effect = dev.subprocess.CalledProcessError(1, 'jac')
        with self.assertRaises(dev.subprocess.CalledProcessError):
            dev.switch('feature', self.registered)
        self.stop.assert_not_called()

    def test_optional_service_preparation_fails_before_stopping_preview(self):
        preparation = self.target / 'scripts/prepare-preview'
        preparation.parent.mkdir(parents=True)
        preparation.touch()
        self.compile.side_effect = dev.subprocess.CalledProcessError(1, 'prepare-preview')
        with self.assertRaises(dev.subprocess.CalledProcessError):
            dev.switch('feature', self.registered)
        self.assertEqual(self.compile.call_args.args[0], ['sh', str(preparation)])
        self.stop.assert_not_called()
        self.refresh.return_value.apply.assert_not_called()

    def test_switch_automatically_copies_account_and_cli_settings(self):
        self.assertEqual(dev.switch('feature', self.registered), self.target)
        self.stop.assert_called_once_with(123, self.previous)
        self.start.assert_called_once_with(self.target)
        self.assertEqual(self.compile.call_args.kwargs['cwd'], self.target)
        self.refresh.assert_called_once_with(self.previous, self.target)
        self.cli.assert_called_once_with(self.refresh.return_value.config, self.target)
        self.refresh.return_value.prepare.assert_called_once()
        self.refresh.return_value.apply.assert_called_once()
        self.refresh.return_value.finish.assert_called_once()

    def test_failed_start_rolls_back(self):
        self.start.side_effect = [RuntimeError('Failed startup'), None]
        with self.assertRaisesRegex(RuntimeError, 'Failed startup'):
            dev.switch('feature', self.registered)
        self.assertEqual([call.args[0] for call in self.start.call_args_list], [self.target, self.previous])

    def test_already_running_feature_repairs_account_and_config(self):
        self.running.return_value = [(123, self.target)]
        with patch.object(dev, 'ready', return_value=True):
            self.assertEqual(dev.switch('feature', self.registered), self.target)
        self.refresh.return_value.apply.assert_called_once()
        self.cli.assert_called_once()
        self.stop.assert_called_once_with(123, self.target)

    def test_main_does_not_copy_or_replace_data(self):
        config = self.previous / 'storage/agents/config.json'
        config.parent.mkdir(parents=True)
        config.write_text('{}')
        with patch.object(dev, 'preview_config'), patch.object(dev, 'ready', return_value=True):
            dev.switch('mainworktree', self.registered)
        self.refresh.assert_not_called()
        self.cli.assert_called_once()
        self.stop.assert_not_called()

    def test_cli_failure_preserves_running_preview(self):
        self.cli.side_effect = RuntimeError('Sign in to your Mac subscription')
        with self.assertRaisesRegex(RuntimeError, 'Sign in'):
            dev.switch('feature', self.registered)
        self.stop.assert_not_called()
        self.refresh.return_value.prepare.assert_not_called()

    def test_missing_main_fails_before_stopping(self):
        with self.assertRaisesRegex(RuntimeError, 'not registered'):
            dev.switch('feature', {'feature': self.target})
        self.stop.assert_not_called()

    def test_multiple_supervisors_require_resolution(self):
        self.running.return_value.append((456, self.target))
        with self.assertRaisesRegex(RuntimeError, 'Multiple development'):
            dev.switch('feature', self.registered)
        self.stop.assert_not_called()

    def test_refresh_runs_even_when_target_is_already_active(self):
        self.running.return_value = [(123, self.target)]
        with patch.object(dev, 'Refresh') as refresh, patch.object(dev.subprocess, 'check_output', return_value='main\n'):
            dev.switch('feature', self.registered, refresh=True)
        self.stop.assert_called_once_with(123, self.target)
        refresh.return_value.prepare.assert_called_once()
        refresh.return_value.apply.assert_called_once()
        refresh.return_value.finish.assert_called_once()

    def test_refresh_start_failure_restores_data_before_restarting(self):
        self.start.side_effect = [RuntimeError('Failed startup'), None]
        with patch.object(dev, 'Refresh') as refresh, patch.object(dev.subprocess, 'check_output', return_value='main\n'):
            with self.assertRaisesRegex(RuntimeError, 'Failed startup'):
                dev.switch('feature', self.registered, refresh=True)
            refresh.return_value.rollback.assert_called_once()
            refresh.return_value.finish.assert_not_called()


if __name__ == '__main__':
    unittest.main()
