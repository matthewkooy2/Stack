"""Native launcher compatibility without a Mac or a system Python upgrade."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'posix', 'POSIX shell launcher')
class JacLauncher(unittest.TestCase):
    def test_mac_temp_directory_does_not_import_linux_bootstrap(self):
        with tempfile.TemporaryDirectory(prefix='stack-native-launcher-') as directory:
            fixture = Path(directory)
            commands = fixture / 'bin'
            commands.mkdir()
            common = fixture / 'repo/.git'
            common.mkdir(parents=True)
            scripts = {
                'uname': '#!/bin/sh\nprintf "Darwin\\n"\n',
                'git': '#!/bin/sh\nprintf "%s\\n" "$TEST_COMMON_GIT"\n',
                'python3': '#!/bin/sh\ntouch "$TEST_PYTHON_CALLED"\nexit 97\n',
                'pinned-jac': '#!/bin/sh\nprintf "%s\\n" "$TMPDIR" "$@"\n',
            }
            for name, content in scripts.items():
                path = commands / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(commands) + ':/usr/bin:/bin',
                       STACK_JAC_BIN=str(commands / 'pinned-jac'),
                       TEST_COMMON_GIT=str(common), TEST_PYTHON_CALLED=str(fixture / 'python-called'))
            env.pop('STACK_TMP_DIR', None)
            result = subprocess.run(['sh', str(ROOT / 'scripts/jac'), '--version'], env=env,
                                    check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.splitlines(), [str(common.parent / '.jac-tmp'), '--version'])
            self.assertTrue((common.parent / '.jac-tmp').is_dir())
            self.assertFalse((fixture / 'python-called').exists())


if __name__ == '__main__':
    unittest.main()
