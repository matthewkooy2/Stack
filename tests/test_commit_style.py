import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check_commit_style.py"
spec = importlib.util.spec_from_file_location("commit_style", SCRIPT)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class CommitStyleTests(unittest.TestCase):
    def test_real_policy_examples(self):
        self.assertEqual(policy.errors("fix<resume>: refresh scores after edits"), [])
        for subject in ["fix(resume): refresh scores", "Merge pull request #40", "fix<resume>: Refresh scores", "fix<resume>: refresh scores.", "fix<resume>: refresh scores\n"]:
            self.assertTrue(policy.errors(subject), subject)
        self.assertEqual(policy.message_errors("fix<resume>: refresh scores\n\nPreserve scores for unchanged source."), [])
        self.assertIn("omit coauthor attribution", policy.message_errors("fix<resume>: refresh scores\n\nCo-Authored-By: Model <model@example.invalid>"))

    def test_range_and_pr_inspect_source_and_merge_subjects(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True).strip()
            git("init", "-q")
            tree = git("mktree")
            # Fixture-only identities; do not modify any user's configured identity.
            def commit(title, parents=()):
                command = ["git", "-C", directory, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", tree]
                for parent in parents:
                    command.extend(["-p", parent])
                return subprocess.check_output(command, input=title, text=True).strip()
            base = commit("Historical baseline")
            feature = commit("fix<resume>: refresh scores", [base])
            sibling = commit("test<resume>: cover score refresh", [base])
            merge = commit("Merge pull request #1", [sibling, feature])
            def check(*args):
                return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=directory, text=True, capture_output=True)
            self.assertEqual(check("--range", f"{base}..{feature}").returncode, 0)
            failure = check("--range", f"{base}..{merge}")
            self.assertEqual(failure.returncode, 1)
            self.assertIn(merge, failure.stdout)
            self.assertNotIn(base, failure.stdout)
            event = Path(directory) / "event.json"
            event.write_text(json.dumps({"pull_request": {"title": "Incorrect PR title", "base": {"sha": base}, "head": {"sha": feature}}}), encoding="utf-8")
            self.assertEqual(check("--event", str(event)).returncode, 1)
            event.write_text(json.dumps({"pull_request": {"title": "fix<resume>: refresh scores", "base": {"sha": base}, "head": {"sha": merge}}}), encoding="utf-8")
            failure = check("--event", str(event))
            self.assertEqual(failure.returncode, 1)
            self.assertIn(merge, failure.stdout)


if __name__ == "__main__":
    unittest.main()
