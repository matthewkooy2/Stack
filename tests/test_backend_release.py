"""Exercise source-only releases and the receiver's rejection boundaries."""
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'deploy'))
import backend_release as release


class SourceRelease(unittest.TestCase):
    def test_exact_commit_round_trip_is_deterministic_without_parser(self):
        commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
        with tempfile.TemporaryDirectory() as directory:
            first, second = Path(directory) / 'first.tar.gz', Path(directory) / 'second.tar.gz'
            built = release.build(ROOT, commit, first)
            release.build(ROOT, commit, second)
            data = first.read_bytes()
            self.assertEqual(data, second.read_bytes())
            manifest, payload = release.validate(data, commit, built['sha256'])
            self.assertEqual(manifest['format'], 3)
            self.assertFalse(any('resume-parser' in name for name in payload))
            self.assertNotIn('agents/resume_parser.jac', payload)
            self.assertNotIn('agents/parse_check.jac', payload)
            self.assertNotIn('[client.react_native]', payload['jac.toml'].decode())
            with self.assertRaises(AssertionError):
                release.validate(data + b'changed', commit, built['sha256'])
            with self.assertRaises(AssertionError):
                release.validate(data, '0' * 40, built['sha256'])

    def test_receiver_refuses_retired_parser_paths_and_archive_links(self):
        for path in ('.jac/resume-parser.cjs', 'integrations/resume-parser/run.mjs', '../main.jac'):
            self.assertFalse(release.allowed(path))
        with io.BytesIO() as stream:
            with tarfile.open(fileobj=stream, mode='w:gz') as archive:
                member = tarfile.TarInfo('payload/main.jac')
                member.type = tarfile.SYMTYPE
                member.linkname = '/etc/stack/api.env'
                archive.addfile(member)
            data = stream.getvalue()
        with self.assertRaisesRegex(AssertionError, 'Links'):
            release.validate(data, '0' * 40, release.digest(data))


if __name__ == '__main__':
    unittest.main()
