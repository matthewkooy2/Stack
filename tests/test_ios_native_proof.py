"""Reachable release trust boundaries, using synthetic GitHub API records."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_proof', ROOT / 'scripts/ci/ios-native-proof.py')
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)
MACHINE = {'xcode': 'Xcode 27.0\nBuild version 27A266a', 'xcodegen': '2.46.0', 'runtime': proof.RUNTIME,
           'runtime_build': 'synthetic-build', 'device': 'iPhone 18 Pro'}


class ReleaseProof(unittest.TestCase):
    def setUp(self):
        self.run = {'id': 10, 'run_attempt': 1, 'path': proof.WORKFLOW, 'status': 'completed',
                    'conclusion': 'success', 'head_repository': {'full_name': proof.REPO},
                    'repository': {'id': 1}, 'head_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'event': 'pull_request',
                    'pull_requests': [{'head': {'repo': {'id': 1}}, 'base': {'sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}}]}
        self.record = {'run_id': 10, 'attempt': 1, 'commit': 'cccccccccccccccccccccccccccccccccccccccc', 'tree': 'tree',
                       'toolchain': MACHINE, 'reused_run': 0}
        self.commit = {'tree': {'sha': 'tree'}, 'parents': [{'sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}, {'sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}]}
        self.job = {'id': 95, 'name': proof.JOB, 'conclusion': 'success', 'runner_group_name': 'GitHub Actions',
                    'steps': [{'name': name, 'conclusion': 'success'} for name in
                              ('Run selected native cases', 'Compile unsigned Release', 'Publish native proof')]}
        self.api = patch.object(proof, 'api', side_effect=self.lookup).start()
        self.addCleanup(patch.stopall)
        self.runs = patch.object(proof, 'runs', return_value=[self.run]).start()
        self.git = patch.object(proof, 'git', return_value='tree').start()

    def lookup(self, path, raw=False):
        if path == 'actions/jobs/95/logs':
            return ('2026-10-12T01:00:00Z [command]/opt/homebrew/bin/git log -1 --format=%H\n'
                    '2026-10-12T01:00:00Z ' + 'c' * 40 + '\n').encode()
        if path.startswith('git/commits/'):
            return self.commit
        if path.endswith('/jobs?per_page=100'):
            return {'jobs': [self.job]}
        raise AssertionError(path)

    def validate(self):
        proof.validate(self.run, self.record, 'tree', MACHINE)

    def test_success_requires_the_actual_reconstructed_merge_tree(self):
        self.validate()
        self.git.assert_any_call('merge-tree', '--write-tree', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')
        self.git.return_value = 'different-tree'
        with self.assertRaises(ValueError):
            self.validate()

    def test_tree_or_test_policy_change_invalidates_green(self):
        self.commit['tree']['sha'] = 'changed-policy-tree'
        with self.assertRaises(ValueError):
            self.validate()

    def test_wrong_commit_parent_or_changed_base_invalidates_green(self):
        self.commit['parents'][1]['sha'] = 'different'
        with self.assertRaises(ValueError):
            self.validate()
        self.commit['parents'][1]['sha'] = 'b' * 40
        self.git.return_value = 'changed-base-tree'
        with self.assertRaises(ValueError):
            self.validate()

    def test_closed_PR_can_reuse_only_the_GitHub_owned_checkout(self):
        self.run['pull_requests'] = []
        self.validate()
        self.record['commit'] = 'e' * 40
        with self.assertRaisesRegex(ValueError, 'checkout identity'):
            self.validate()

    def test_unavailable_or_fabricated_checkout_log_cannot_authorize_reuse(self):
        for data in (b'', b"HEAD is now at abc [command]git log -1 --format=%H\n" + b'c' * 40):
            with patch.object(proof, 'api', return_value=data), self.assertRaises(ValueError):
                proof.checkout_commit(self.job)

    def test_fork_or_foreign_repository_cannot_authorize_release(self):
        self.run['pull_requests'][0]['head']['repo']['id'] = 2
        with self.assertRaises(ValueError):
            self.validate()
        self.run['pull_requests'][0]['head']['repo']['id'] = 1
        self.run['head_repository']['full_name'] = 'untrusted/fork'
        with self.assertRaises(ValueError):
            self.validate()

    def test_pending_failed_cancelled_or_wrong_workflow_cannot_pass(self):
        for field, value in [('status', 'in_progress'), ('conclusion', 'failure'),
                             ('conclusion', 'cancelled'), ('path', '.github/workflows/other.yml')]:
            original = self.run[field]
            self.run[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.validate()
            self.run[field] = original

    def test_wrong_attempt_or_toolchain_cannot_pass(self):
        for field, value in [('attempt', 2), ('run_id', 11), ('toolchain', {})]:
            original = self.record[field]
            self.record[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate()
            self.record[field] = original

    def test_missing_skipped_failed_or_nonisolated_native_job_cannot_pass(self):
        for step in self.job['steps']:
            step['conclusion'] = 'skipped'
            with self.assertRaises(ValueError):
                self.validate()
            step['conclusion'] = 'success'
        self.job['runner_group_name'] = 'self-hosted'
        with self.assertRaises(ValueError):
            self.validate()

    def test_superseded_green_is_not_a_fallback_for_newer_failure(self):
        self.runs.return_value = [{**self.run, 'id': 11, 'conclusion': 'failure'}]
        with self.assertRaises(ValueError):
            self.validate()

    def test_main_commit_must_match_verified_push_exactly(self):
        self.run.update(event='push', head_branch='main', head_sha='cccccccccccccccccccccccccccccccccccccccc')
        self.validate()
        self.record['commit'] = 'pr-head'
        with self.assertRaises(ValueError):
            self.validate()

    def test_reuse_chains_and_manual_runs_cannot_authorize_release(self):
        with self.assertRaises(ValueError):
            proof.validate(self.run, self.record, 'tree', MACHINE, depth=2)
        self.run['event'] = 'workflow_dispatch'
        with self.assertRaises(ValueError):
            self.validate()

    def test_artifact_claims_alone_cannot_authorize_release(self):
        self.job['conclusion'] = 'failure'
        with self.assertRaises(ValueError):
            self.validate()

    def test_manifest_cannot_inject_git_options_or_choose_a_noncommit(self):
        self.record['commit'] = '--upload-pack=untrusted'
        with self.assertRaisesRegex(ValueError, 'Invalid native commit'):
            self.validate()
        self.api.assert_not_called()

    def test_missing_expired_or_unsafe_artifact_is_rejected(self):
        self.api.side_effect = None
        self.api.return_value = {'artifacts': []}
        with self.assertRaises(ValueError):
            proof.proof_for(self.run)
        artifact = {'id': 99, 'name': 'native-proof-10-1', 'expired': True, 'size_in_bytes': 500}
        self.api.return_value = {'artifacts': [artifact]}
        with self.assertRaises(ValueError):
            proof.proof_for(self.run)
        artifact['expired'] = False
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr('../native-proof.json', json.dumps(self.record))
        self.api.side_effect = [{'artifacts': [artifact]}, data.getvalue()]
        with self.assertRaises(ValueError):
            proof.proof_for(self.run)

    def test_release_rejects_wrong_main_failed_or_pending_backend_and_skipped_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / 'event.json'
            event.write_text(json.dumps({'workflow_run': {'event': 'push', 'head_branch': 'main',
                                                         'head_repository': {'full_name': proof.REPO},
                                                         'head_sha': 'cccccccccccccccccccccccccccccccccccccccc'}}))
            backend = {**self.run, 'id': 20, 'event': 'push', 'head_branch': 'main', 'head_sha': 'cccccccccccccccccccccccccccccccccccccccc'}
            self.run.update(event='push', head_branch='main', head_sha='cccccccccccccccccccccccccccccccccccccccc')
            self.api.side_effect = lambda path, raw=False: ({'object': {'sha': 'cccccccccccccccccccccccccccccccccccccccc'}} if path == 'git/ref/heads/main'
                                                            else {'jobs': [{'name': 'CI passed', 'conclusion': 'skipped'}]})
            with patch.dict(os.environ, {'GITHUB_EVENT_PATH': str(event)}), \
                    patch.object(proof, 'proof_for', return_value=self.record), \
                    patch.object(proof, 'validate'), patch.object(proof.time, 'monotonic', side_effect=[0, 601]):
                self.runs.side_effect = [[self.run], [{**backend, 'status': 'in_progress'}]]
                with self.assertRaisesRegex(ValueError, 'missing or pending'):
                    proof.release(MACHINE)
            with patch.dict(os.environ, {'GITHUB_EVENT_PATH': str(event)}), \
                    patch.object(proof, 'proof_for', return_value=self.record), patch.object(proof, 'validate'):
                self.runs.side_effect = [[self.run], [{**backend, 'conclusion': 'failure'}]]
                with self.assertRaisesRegex(ValueError, 'failed'):
                    proof.release(MACHINE)
                self.runs.side_effect = [[self.run], [backend]]
                with self.assertRaisesRegex(ValueError, 'jobs did not succeed'):
                    proof.release(MACHINE)
                self.api.side_effect = None
                self.api.return_value = {'object': {'sha': 'new-main'}}
                with self.assertRaisesRegex(ValueError, 'no longer current main'):
                    proof.release(MACHINE)


class MergeReleaseChanges(unittest.TestCase):
    def test_normal_feature_and_docs_merges_are_compared_to_the_first_parent(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(proof, 'ROOT', Path(directory)):
            def command(*args):
                return subprocess.check_output(['git', *args], cwd=directory, text=True).strip()
            environment = dict(os.environ, GIT_AUTHOR_NAME='Synthetic', GIT_COMMITTER_NAME='Synthetic',
                               GIT_AUTHOR_EMAIL='synthetic@example.test', GIT_COMMITTER_EMAIL='synthetic@example.test')
            def commit(message):
                subprocess.run(['git', 'add', '.'], cwd=directory, check=True, capture_output=True)
                subprocess.run(['git', 'commit', '-m', message], cwd=directory, env=environment, check=True, capture_output=True)
            command('init', '-b', 'main')
            Path(directory, 'README.md').write_text('baseline')
            commit('baseline')
            self.assertEqual(proof.release_changes('HEAD'), ['README.md'])
            command('switch', '-c', 'feature')
            Path(directory, 'ios').mkdir()
            Path(directory, 'ios/Feature.swift').write_text('struct Feature {}')
            commit('feature')
            command('switch', 'main')
            subprocess.run(['git', 'merge', '--no-ff', '-m', 'feature merge', 'feature'], cwd=directory,
                           env=environment, check=True, capture_output=True)
            self.assertEqual(proof.release_changes('HEAD'), ['ios/Feature.swift'])
            command('switch', '-c', 'docs')
            Path(directory, 'README.md').write_text('documentation only')
            commit('docs')
            command('switch', 'main')
            subprocess.run(['git', 'merge', '--no-ff', '-m', 'docs merge', 'docs'], cwd=directory,
                           env=environment, check=True, capture_output=True)
            self.assertEqual(proof.release_changes('HEAD'), ['README.md'])


class LogTransport(unittest.TestCase):
    def test_escape_capture_is_scoped_to_raw_job_logs_and_supported_clients(self):
        for help_text, expected in [('old client', False), ('--allow-escape-sequences', True)]:
            with patch.object(proof.subprocess, 'check_output', side_effect=[help_text, b'log bytes']) as call:
                self.assertEqual(proof.api('actions/jobs/95/logs', raw=True), b'log bytes')
                command = call.call_args.args[0]
                self.assertEqual('--allow-escape-sequences' in command, expected)
                self.assertIn('Range: bytes=0-131071', command)
        for path, raw in [('actions/runs/10', False), ('actions/artifacts/10/zip', True)]:
            with patch.object(proof.subprocess, 'check_output', return_value=b'{}') as call:
                proof.api(path, raw=raw)
                self.assertEqual(call.call_count, 1)
                self.assertNotIn('--allow-escape-sequences', call.call_args.args[0])


if __name__ == '__main__':
    unittest.main()
