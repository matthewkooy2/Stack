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


class RoutedRelease(unittest.TestCase):
    def setUp(self):
        self.run = {'id': 40, 'run_attempt': 1, 'path': proof.WORKFLOW, 'status': 'completed',
                    'conclusion': 'success', 'event': 'push', 'head_branch': 'main',
                    'head_repository': {'full_name': proof.REPO}, 'head_sha': 'c' * 40}
        self.steps = {'Select affected checks': 'success', 'Report native checks not applicable': 'success',
                      'Run selected native cases': 'skipped', 'Compile unsigned Release': 'skipped',
                      'Publish native proof': 'skipped'}

    def jobs(self):
        return {'jobs': [{'name': proof.JOB, 'conclusion': 'success',
                         'steps': [{'name': name, 'conclusion': result} for name, result in self.steps.items()]}]}

    def test_only_complete_successful_noop_marker_is_recognized(self):
        with patch.object(proof, 'api', side_effect=lambda *a: self.jobs()):
            self.assertTrue(proof.native_not_applicable(self.run))
            for name, original in list(self.steps.items()):
                self.steps[name] = 'failure'
                self.assertFalse(proof.native_not_applicable(self.run))
                self.steps[name] = original
            self.run['conclusion'] = 'failure'
            self.assertFalse(proof.native_not_applicable(self.run))

    def test_automatic_noop_never_reads_proof_signs_or_records(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory, 'event.json')
            event.write_text(json.dumps({'workflow_run': self.run}))
            def api(path, raw=False):
                return {'object': {'sha': 'c' * 40}} if path == 'git/ref/heads/main' else self.jobs()
            with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event)), patch.object(proof, 'api', side_effect=api), \
                    patch.object(proof, 'git') as git, patch.object(proof, 'validate') as validate, \
                    patch.object(proof, 'record') as record, patch.object(proof, 'output') as output:
                proof.release(MACHINE)
                output.assert_any_call('upload', 'false')
                git.assert_not_called()
                validate.assert_not_called()
                record.assert_not_called()
                with self.assertRaisesRegex(ValueError, 'does not authorize native upload'):
                    proof.release(MACHINE, require_upload=True)

    def test_irrelevant_upload_marker_can_only_suppress_upload(self):
        self.steps = {'Select affected checks': 'success', 'Report native upload not applicable': 'success',
                      'Run selected native cases': 'success', 'Compile unsigned Release': 'success',
                      'Publish native proof': 'success'}
        with patch.object(proof, 'api', side_effect=lambda *a: self.jobs()):
            self.assertTrue(proof.native_not_applicable(self.run))
            self.steps['Report native upload not applicable'] = 'skipped'
            self.assertFalse(proof.native_not_applicable(self.run))

    def test_relevant_and_manual_releases_still_require_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory, 'event.json')
            for payload in ({'workflow_run': self.run}, {}):
                event.write_text(json.dumps(payload))
                with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event), GITHUB_REF='refs/heads/main', GITHUB_SHA='c' * 40), \
                        patch.object(proof, 'api', return_value={'object': {'sha': 'c' * 40}}), \
                        patch.object(proof, 'native_not_applicable', return_value=False), \
                        patch.object(proof, 'git', return_value='tree'), patch.object(proof, 'runs', return_value=[self.run]), \
                        patch.object(proof, 'proof_for', side_effect=ValueError('Missing proof')), \
                        self.assertRaisesRegex(ValueError, 'Missing proof'):
                    proof.release(MACHINE)


@unittest.skipIf(os.name == 'nt', 'Direct upload shell boundary runs on Linux or macOS')
class DirectUpload(unittest.TestCase):
    def test_no_upload_revalidation_stops_before_prepare_archive_or_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / 'scripts/ci/ios-swift-testflight.sh'
            script.parent.mkdir(parents=True)
            script.write_text((ROOT / 'scripts/ci/ios-swift-testflight.sh').read_text())
            commands = root / 'bin'
            commands.mkdir()
            log = root / 'commands.log'
            stubs = {
                'uname': '#!/bin/sh\necho Darwin\n',
                'python3': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$COMMAND_LOG"\n'
                           'case "$1" in *ios-native-proof.py) [ "$2" = release-upload ] && exit 7;; esac\nexit 0\n',
                'xcodegen': '#!/bin/sh\necho xcodegen >> "$COMMAND_LOG"\n',
                'xcodebuild': '#!/bin/sh\necho xcodebuild >> "$COMMAND_LOG"\n',
                'xcrun': '#!/bin/sh\necho xcrun >> "$COMMAND_LOG"\n',
            }
            for name, contents in stubs.items():
                path = commands / name
                path.write_text(contents)
                path.chmod(0o755)
            key = root / 'synthetic-key'
            key.write_text('synthetic')
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'],
                       COMMAND_LOG=str(log), STACK_API_URL='https://example.test', APPLE_TEAM_ID='ABCDEFGHIJ',
                       ASC_KEY_ID='synthetic', ASC_ISSUER_ID='synthetic', ASC_AUTH_KEY_PATH=str(key),
                       GITHUB_RUN_NUMBER='1', GITHUB_RUN_ATTEMPT='1', IOS_SIGNING_IDENTITY='synthetic',
                       IOS_PROFILE_UUID='synthetic', IOS_SIGNING_KEYCHAIN='synthetic')
            result = subprocess.run(['bash', str(script)], cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 7, result.stderr)
            calls = log.read_text().splitlines()
            self.assertEqual(len(calls), 2, calls)
            self.assertEqual(calls[-1], 'scripts/ci/ios-native-proof.py release-upload')


if __name__ == '__main__':
    unittest.main()
