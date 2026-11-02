"""The local lab must test current source and preserve its separate account storage."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from scripts import jobs_lab_data

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('jobs_lab', ROOT / 'scripts/jobs-lab.py')
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

class JobsLabStage(unittest.TestCase):
    def test_restage_removes_deleted_source_and_preserves_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'source'
            app = Path(directory) / 'isolated'
            root.mkdir()
            for name in ('main.jac', 'jac.toml'):
                (root / name).write_text('fixture')
            for name in ('core', 'agents', 'discovery', 'dependencies', 'scripts'):
                (root / name).mkdir()
            (root / '.jac/venv/bin').mkdir(parents=True)
            (root / '.jac/venv/bin/python').symlink_to('/usr/bin/python3')
            (root / 'core/removed.py').write_text('old')
            with patch.object(lab, 'ROOT', root), patch.object(lab, 'APP', app):
                lab.stage()
                (app / 'storage').mkdir()
                (app / 'storage/account').write_text('keep')
                (root / 'core/removed.py').unlink()
                (root / 'core/current.py').write_text('new')
                lab.stage()
                self.assertFalse((app / 'core/removed.py').exists())
                self.assertEqual((app / 'core/current.py').read_text(), 'new')
                self.assertEqual((app / 'storage/account').read_text(), 'keep')

    def test_occupied_port_does_not_replace_running_app_source(self):
        with patch('sys.argv', ['jobs-lab.py']), patch.object(lab, 'stage') as stage, \
             patch.object(lab.socket, 'socket') as socket:
            socket.return_value.__enter__.return_value.connect_ex.return_value = 0
            with self.assertRaisesRegex(SystemExit, 'occupied'):
                lab.main()
            stage.assert_not_called()

    def test_unchanged_fixture_manifest_preserves_prepared_app_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'manifest.json'
            with patch.object(jobs_lab_data, 'Path', return_value=marker):
                jobs_lab_data.manifest(25000)
                os.utime(marker, ns=(1_000_000_000, 1_000_000_000))
                jobs_lab_data.manifest(25000)
                self.assertEqual(marker.stat().st_mtime_ns, 1_000_000_000)
                jobs_lab_data.manifest(50000)
                self.assertNotEqual(marker.stat().st_mtime_ns, 1_000_000_000)

if __name__ == '__main__':
    unittest.main()
