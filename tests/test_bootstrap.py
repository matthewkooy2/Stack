"""Synthetic checks for the public bootstrap's integrity and isolation gates."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sys
import subprocess
import tarfile
import tempfile
import tomllib
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stack_bootstrap", ROOT / "scripts/bootstrap.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def test_download_rejects_bad_hash_and_retains_previous_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "tool"
            target.write_bytes(b"previous")
            with patch.object(bootstrap, "urlopen", return_value=io.BytesIO(b"corrupt")):
                with self.assertRaisesRegex(RuntimeError, "SHA256"):
                    bootstrap.download("https://example.invalid/tool", target, hashlib.sha256(b"verified").hexdigest())
            self.assertEqual(target.read_bytes(), b"previous")
            self.assertFalse(target.with_suffix(".part").exists())

    def test_download_verified_cache_needs_no_network(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "tool"
            target.write_bytes(b"verified")
            with patch.object(bootstrap, "urlopen") as network:
                result = bootstrap.download("https://example.invalid/tool", target, hashlib.sha256(b"verified").hexdigest())
            self.assertEqual(result, target)
            network.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "Linux/WSL2 setup")
    def test_setup_rejects_redirected_generated_directory_before_install(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            (root / ".jac").symlink_to(outside, target_is_directory=True)
            with patch.object(bootstrap, "install_tools") as install:
                with self.assertRaisesRegex(RuntimeError, "symbolic link"):
                    bootstrap.setup(root)
                install.assert_not_called()
            self.assertEqual(list(Path(outside).iterdir()), [])

    @unittest.skipUnless(os.name == "posix", "Linux/WSL2 setup")
    def test_setup_rejects_browser_manifest_drift_before_npm(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            generated = root / ".jac/client/configs/package.json"
            generated.parent.mkdir(parents=True)
            generated.write_text(json.dumps({"dependencies": {"react": "wrong"}}))
            locked = root / "dependencies/web/package.json"
            locked.parent.mkdir(parents=True)
            locked.write_text(json.dumps({"dependencies": {"react": "19.2.3"}}))
            (root / "jac.toml").write_text("[dependencies]\n")
            (root / "dependencies/python.lock").write_text("")
            with patch.object(bootstrap, "install_tools"), patch.object(bootstrap, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "dependency inputs changed"):
                    bootstrap.setup(root)
            self.assertFalse(any("ci" in args[0][2] for args in run.call_args_list))

    @unittest.skipUnless(os.name == "posix", "Linux/WSL2 setup")
    def test_environment_excludes_credentials_and_production_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            inherited = {"PATH": "/usr/bin:/bin", "JAC_DB_URL": "synthetic-production",
                         "STACK_AGENT_CONFIG": "synthetic-config", "OPENAI_API_KEY": "synthetic-key",
                         "ANTHROPIC_API_KEY": "synthetic-key", "GOOGLE_APPLICATION_CREDENTIALS": "synthetic-key",
                         "NPM_TOKEN": "synthetic-key", "PIP_EXTRA_INDEX_URL": "synthetic-index"}
            with patch.dict(os.environ, inherited, clear=True):
                env = bootstrap.environment(Path(directory))
            for key in inherited.keys() - {"PATH", "JAC_DB_URL"}:
                self.assertNotIn(key, env)
            self.assertEqual(env["JAC_DB_URL"], "")
            self.assertEqual(env["PYTHON_DOTENV_DISABLED"], "1")
            self.assertEqual(env["PIP_INDEX_URL"], "https://pypi.org/simple")
            self.assertEqual(env["NPM_CONFIG_REGISTRY"], "https://registry.npmjs.org")
            self.assertTrue(env["PATH"].startswith(str(Path(directory) / ".jac/tools/bin")))

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux active executable semantics")
    def test_archive_repeat_retains_verified_running_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "postgres"
            executable = Path("/usr/bin/sleep")
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode="w") as archive:
                archive.add(executable, arcname="bin/postgres")
            data = payload.getvalue()
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
                bootstrap.install_archive(archive, target)
            installed = target / "bin/postgres"
            inode = installed.stat().st_ino
            process = subprocess.Popen([str(installed), "30"])
            try:
                with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
                    bootstrap.install_archive(archive, target)
                self.assertEqual(installed.stat().st_ino, inode)
                self.assertIsNone(process.poll())
                self.assertEqual(bootstrap.sha256(installed), bootstrap.sha256(executable))
            finally:
                process.terminate()
                process.wait(timeout=5)

    def test_file_update_replaces_content_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            source, installed = Path(directory) / "source", Path(directory) / "installed"
            source.write_bytes(b"verified-correction")
            installed.write_bytes(b"stale")
            bootstrap.install_file(source, installed)
            self.assertEqual(installed.read_bytes(), b"verified-correction")
            self.assertEqual(source.read_bytes(), b"verified-correction")
            self.assertEqual(list(Path(directory).glob(".stack-tool-*")), [])
    def test_python_lock_covers_manifest_exact_versions_and_artifact_hashes(self):
        manifest = tomllib.loads((ROOT / "jac.toml").read_text())
        text = (ROOT / "dependencies/python.lock").read_text()
        entries = re.findall(r"(?m)^([\w-]+)==([^\s]+) \\\n((?:    --hash=sha256:[a-f0-9]{64}(?: \\)?\n)+)", text)
        locked = {name.replace("_", "-"): version for name, version, _ in entries}
        for key in ("dependencies", "dev-dependencies"):
            for name, version in manifest[key].items():
                if isinstance(version, str):
                    self.assertTrue(version.startswith("=="), (name, version))
                    self.assertEqual(locked[name], version[2:])
        self.assertGreaterEqual(len(locked), 23)
        self.assertEqual(locked["pip"], "26.2.1")


if __name__ == "__main__":
    unittest.main()
