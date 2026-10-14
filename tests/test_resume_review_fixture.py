"""Fail-closed tests for the native resource preparation boundary."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "resume_fixture", Path(__file__).resolve().parents[1] / "scripts/ci/resume-review/prepare.py"
)
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class ResumeFixturePreparationTests(unittest.TestCase):
    def producer(self, root, script):
        path = root / fixture.PRODUCER
        path.parent.mkdir(parents=True)
        path.write_text(script)

    def test_producer_bytes_are_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.producer(root, "import sys; sys.stdout.buffer.write(b'{\"sample\":true}\\n')")
            expected = b'{"sample":true}\n'
            self.assertEqual(fixture.generate(root, hashlib.sha256(expected).hexdigest()), expected)

    def test_changed_contract_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.producer(root, "print('{}')")
            with self.assertRaisesRegex(ValueError, "Shared resume contract changed"):
                fixture.generate(root, hashlib.sha256(b'different').hexdigest())

    def test_failed_producer_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.producer(root, "raise RuntimeError('producer unavailable')")
            with self.assertRaises(subprocess.CalledProcessError):
                fixture.generate(root, hashlib.sha256(b'{}').hexdigest())

    def test_failed_preparation_removes_stale_resource(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.producer(root, "print('{}')")
            resource = root / 'stale.json'
            resource.write_text('{}')
            with patch.object(fixture, 'ROOT', root), patch.object(fixture, 'RESOURCE', resource):
                with self.assertRaisesRegex(ValueError, "Shared resume contract changed"):
                    fixture.main()
            self.assertFalse(resource.exists())


if __name__ == '__main__':
    unittest.main()
