"""Exercise private configuration rules without touching real operator files."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PrivateConfigurationIgnore(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Keep even disposable fixtures on the same volume as the checkout.
        scratch = ROOT / ".jac"
        scratch.mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="gitignore-", dir=scratch)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.repo = Path(cls.temporary.name)
        cls.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        subprocess.run(
            ["git", "init", "--quiet", "--template=", str(cls.repo)],
            env=cls.env, check=True, capture_output=True,
        )
        (cls.repo / ".gitignore").write_bytes((ROOT / ".gitignore").read_bytes())

    def ignored(self, paths):
        # --no-index also checks templates that are already tracked in Stack.
        result = subprocess.run(
            ["git", "-c", "core.excludesFile=", "check-ignore", "--no-index", "-z", "--stdin"],
            input="\0".join(paths).encode() + b"\0",
            cwd=self.repo, env=self.env, capture_output=True,
        )
        self.assertIn(result.returncode, (0, 1), result.stderr.decode())
        return set(result.stdout.decode().rstrip("\0").split("\0")) if result.stdout else set()

    def test_completed_configuration_and_existing_private_destinations_are_ignored(self):
        paths = {
            "deploy/api.env", "deploy/worker.env", "deploy/discovery.env",
            "deploy/pc-host/stack-browser-prepared/browser.env",
            "discovery/credentials.json", "storage/discovery/credentials.json",
            "storage/service-account.json", "storage/id_rsa", "storage/private-key.pem",
            ".env", ".env.local", "deploy/.env", "deploy/.env.production",
            "signing/fixture.key", "signing/fixture.p8", "signing/fixture.p12",
            "signing/fixture.mobileprovision",
        }
        self.assertEqual(self.ignored(paths), paths)

    def test_examples_and_ordinary_source_files_remain_visible(self):
        paths = {
            "deploy/api.env.example", "deploy/worker.env.example",
            "deploy/discovery.env.example", "discovery/credentials.example.json",
            "deploy/pc-host/stack-browser-prepared/browser.env.example",
            ".env.example", "deploy/.env.example", "deploy/agent-config.example.json",
            "deploy/codex.config.example.toml", "deploy/wsl.conf.example",
            "config.json", "cert.pem", "tests/fixtures/public-certificate.pem",
            "credentials.json", "service-account.json", "id_rsa",
            "tests/fixtures/discovery/credentials.json", "tests/fixtures/deploy/api.env",
            "deploy/api.env.schema.json", "main.jac", "jac.toml",
        }
        self.assertEqual(self.ignored(paths), set())

    def test_all_tracked_source_paths_remain_visible(self):
        result = subprocess.run(
            ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True,
        )
        paths = result.stdout.decode().rstrip("\0").split("\0")
        self.assertTrue(paths)
        self.assertEqual(self.ignored(paths), set())


if __name__ == "__main__":
    unittest.main()
