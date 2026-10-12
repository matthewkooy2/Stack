"""Impact routing and real Git ranges, without a simulator or extra framework."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('affected', ROOT / 'scripts/ci/affected-checks.py')
affected = importlib.util.module_from_spec(spec)
spec.loader.exec_module(affected)


class Impact(unittest.TestCase):
    def test_explicit_prose_only_and_mixed_changes(self):
        self.assertEqual(affected.select(['AGENTS.md', 'docs/CI.md', 'README.md']),
                         {'backend': False, 'native': False})
        self.assertEqual(affected.select(['docs/CI.md', 'ios/Stack/View.swift']), affected.ALL)

    def test_web_only_does_not_start_native(self):
        self.assertEqual(affected.select(['web/main.jac', 'web/style.css']),
                         {'backend': True, 'native': False})

    def test_automatic_upload_retains_existing_native_path_scope(self):
        self.assertFalse(affected.upload_relevant(['AGENTS.md', 'docs/CI.md', 'web/main.jac', 'agents/contracts.jac']))
        for path in ['ios/Feature.swift', 'scripts/ci/ios-core.py', 'scripts/ci/resume-review/prepare.py',
                     '.github/actions/prepare-resume-review-fixture/action.yml',
                     '.github/workflows/ios-swift.yml', '.github/workflows/swift-testflight.yml', 'mobile/feature-rpcs.js']:
            self.assertTrue(affected.upload_relevant(['README.md', path]))

    def test_shared_build_test_policy_and_unknown_paths_run_both(self):
        for path in ['ios/project.yml', 'ios/StackTests/Case.swift', 'ios/Stack/Resources/catalog.json',
                     'native/package-lock.json', 'jac.toml', 'Gemfile', '.node-version',
                     'dependencies/web/package-lock.json', 'main.jac', 'core/auth.jac',
                     'agents/contracts.jac', 'agents/transcription_store.py', 'discovery/worker.py',
                     'deploy/backend_release.py', 'mobile/feature-rpcs.js', 'mobile/auth-session.js',
                     'tests/fixtures/resume_contract.py', 'tests/fixtures/README.md',
                     'tests/fixtures/generate_synthetic_resume.py', 'tests/test_gateway.py',
                     'scripts/ci/ios-core-tests.txt', 'scripts/ci/resume-review/contract.json',
                     '.github/actions/prepare-resume-review-fixture/action.yml',
                     '.github/workflows/ci.yml', 'scripts/bootstrap.py',
                     'docs/dependency-exceptions.json', 'new-component/source.rs']:
            with self.subTest(path=path):
                self.assertEqual(affected.select([path]), affected.ALL)

    def test_unavailable_malformed_manual_or_incomplete_diff_runs_both(self):
        for event, name in [({}, 'pull_request'), ({'before': '0' * 40}, 'push'), ({}, 'workflow_dispatch')]:
            self.assertEqual(affected.selection(event, name), affected.ALL)
        with patch.object(affected, 'changed_paths', side_effect=subprocess.CalledProcessError(1, 'git')):
            self.assertEqual(affected.selection({}, 'push'), affected.ALL)

    def test_outputs_and_summary_are_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            event, output, summary = [Path(directory, name) for name in ('event', 'output', 'summary')]
            event.write_text('{}')
            with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event), GITHUB_EVENT_NAME='workflow_dispatch',
                            GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary)):
                affected.main()
            self.assertEqual(output.read_text(), 'backend=true\nnative=true\nnative_upload=true\n')
            self.assertIn('credential scans always run', summary.read_text())

    def test_truncated_or_non_utf8_diff_falls_back_and_newlines_are_preserved(self):
        event = {'before': 'a' * 40, 'after': 'b' * 40}
        for data in (b'ios/partial.swift', b'web/invalid-\xff.js\0'):
            with patch.object(affected, 'git', side_effect=[b'b' * 40, data]):
                self.assertEqual(affected.selection(event, 'push'), affected.ALL)
        with patch.object(affected, 'git', side_effect=[b'b' * 40, b'web/line\nbreak.js\0ios/deleted.swift\0']):
            self.assertEqual(affected.changed_paths(event, 'push'), ['web/line\nbreak.js', 'ios/deleted.swift'])


class GitRanges(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.patch = patch.object(affected, 'ROOT', self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.env = dict(os.environ, GIT_AUTHOR_NAME='Synthetic', GIT_COMMITTER_NAME='Synthetic',
                        GIT_AUTHOR_EMAIL='synthetic@example.test', GIT_COMMITTER_EMAIL='synthetic@example.test')
        self.git('init', '-b', 'main')
        self.write('README.md', 'baseline')
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, env=self.env,
                                       stderr=subprocess.PIPE).decode().strip()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-m', 'synthetic')
        return self.git('rev-parse', 'HEAD')

    def test_push_uses_entire_range_including_earlier_native_change(self):
        self.write('ios/Feature.swift', 'source')
        self.commit()
        self.write('README.md', 'docs follow native')
        after = self.commit()
        self.assertEqual(affected.selection({'before': self.base, 'after': after}, 'push'), affected.ALL)
        self.assertTrue(affected.selection({'before': self.base, 'after': after}, 'push', True)['native_upload'])
        self.assertEqual(affected.selection({'before': 'f' * 40, 'after': after}, 'push'), affected.ALL)
        self.assertEqual(affected.selection({'before': self.base, 'after': self.base}, 'push'), affected.ALL)

    def test_pr_merge_includes_base_changes_since_divergence(self):
        self.git('switch', '-c', 'docs')
        self.write('README.md', 'docs branch')
        branch = self.commit()
        self.git('switch', 'main')
        self.write('agents/contracts.jac', 'base contract update')
        base = self.commit()
        self.git('merge', '--no-ff', '-m', 'synthetic merge', 'docs')
        event = {'pull_request': {'base': {'sha': base}, 'head': {'sha': branch}}}
        self.assertEqual(affected.selection(event, 'pull_request'), affected.ALL)
        event['pull_request']['base']['sha'] = self.base
        self.assertEqual(affected.selection(event, 'pull_request'), affected.ALL)

    def test_prose_only_merge_can_skip_runtime(self):
        self.git('switch', '-c', 'docs')
        self.write('README.md', 'docs')
        branch = self.commit()
        self.git('switch', 'main')
        self.git('merge', '--no-ff', '-m', 'synthetic merge', 'docs')
        event = {'pull_request': {'base': {'sha': self.base}, 'head': {'sha': branch}}}
        self.assertEqual(affected.selection(event, 'pull_request'), {'backend': False, 'native': False})

    def test_rename_delete_and_unusual_names_preserve_both_paths(self):
        self.write('web/old name.js', 'payload')
        before = self.commit()
        (self.root / 'docs').mkdir()
        self.git('mv', 'web/old name.js', 'docs/moved.md')
        after = self.commit()
        paths = affected.changed_paths({'before': before, 'after': after}, 'push')
        self.assertEqual(set(paths), {'web/old name.js', 'docs/moved.md'})
        self.assertEqual(affected.select(paths), {'backend': True, 'native': False})
        self.write('ios/Deleted.swift', 'deleted')
        before = self.commit()
        self.git('rm', 'ios/Deleted.swift')
        after = self.commit()
        self.assertEqual(affected.selection({'before': before, 'after': after}, 'push'), affected.ALL)


if __name__ == '__main__':
    unittest.main()
