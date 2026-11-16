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
def load_ci_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/ci' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


affected = load_ci_script('affected-checks')
core_tests = load_ci_script('core-tests')


class Impact(unittest.TestCase):
    def test_explicit_prose_only_and_mixed_changes(self):
        self.assertEqual(affected.select(['AGENTS.md', 'docs/CI.md', 'README.md']),
                         {'backend': False, 'native': False, 'backend_groups': 'none'})
        self.assertEqual(affected.select(['docs/CI.md', 'ios/Stack/View.swift']), affected.ALL)

    def test_web_only_does_not_start_native(self):
        self.assertEqual(affected.select(['web/main.jac', 'web/style.css']),
                         {'backend': True, 'native': False, 'backend_groups': 'all'})
        self.assertEqual(affected.select(['web/apple-auth.js', 'web/style.css']),
                         {'backend': True, 'native': False, 'backend_groups': 'shared'})

    def test_audited_feature_paths_select_existing_suites(self):
        cases = {
            'discovery/ranking.py': ('jobs', 'autofill_workflow_tests.jac'),
            'agents/templates/classic.tex': ('resume', 'resume'),
            'agents/contacts.jac': ('network', 'provider_workflow_tests.jac'),
            'agents/transcription_store.py': ('prep', 'transcription-api'),
            'agents/autofill.py': ('applications', 'application_retirement_tests.jac'),
        }
        shared_python, shared_jac = core_tests.selected_suites('shared')
        self.assertEqual(shared_python, ('offline', 'permissions'))
        self.assertEqual(shared_jac, ('google_signin_tests.jac', 'google_signin_gateway_tests.jac',
                                      'pdf_upload_security_tests.jac'))
        for path, (group, suite) in cases.items():
            with self.subTest(group=group):
                result = affected.select([path])
                self.assertEqual(result, {'backend': True, 'native': True, 'backend_groups': group})
                python_suites, jac_suites = core_tests.selected_suites(group)
                self.assertTrue(set(shared_python + shared_jac) <= set(python_suites + jac_suites))
                self.assertEqual(set(python_suites + jac_suites) - set(shared_python + shared_jac),
                                 core_tests.FEATURE_SUITES[group])
                self.assertIn(suite, python_suites + jac_suites)

    def test_overlaps_union_without_duplicate_or_missing_suites(self):
        self.assertEqual(affected.select(['discovery/card.py', 'web/BulletBank.jac',
                                          'agents/autofill.py', 'web/apple-auth.js'])['backend_groups'],
                         'applications,jobs,resume')
        self.assertEqual(affected.select(['web/Interview.js'])['backend_groups'], 'prep')
        self.assertFalse(affected.select(['web/Interview.js'])['native'])
        full = (tuple(core_tests.SUITES), tuple(core_tests.JAC_SUITES))
        groups = ','.join(core_tests.FEATURE_SUITES)
        for requested in (groups, 'all', ''):
            self.assertEqual(core_tests.selected_suites(requested), full)
        python_suites, jac_suites = core_tests.selected_suites('applications,jobs,resume')
        self.assertEqual(jac_suites.count('autofill_workflow_tests.jac'), 1)
        self.assertNotIn('transcription-api', python_suites)
        with self.assertRaises(KeyError):
            core_tests.selected_suites('resume,unknown')
        self.assertEqual({group for groups in affected.FEATURE_PATHS.values() for group in groups},
                         set(core_tests.FEATURE_SUITES))
        self.assertTrue(set().union(*core_tests.FEATURE_SUITES.values()) <= set(sum(full, ())))

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
                     'agents/contracts.jac', 'discovery/worker.py', 'discovery/transport.py',
                     'discovery/normalize.py', 'agents/templates/new.tex', 'core/automation.jac',
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

    def test_narrow_backend_requires_exact_successful_main_baseline(self):
        base = 'a' * 40
        repository = 'example/stack'
        run = {'id': 42, 'run_attempt': 2, 'event': 'push', 'head_branch': 'main', 'head_sha': base,
               'head_repository': {'full_name': repository}, 'status': 'completed', 'conclusion': 'success'}
        jobs = [{'name': name, 'conclusion': 'success'} for name in ('Backend and security', 'CI passed')]
        events = [
            ({'ref': 'refs/heads/main', 'before': base}, 'push'),
            ({'pull_request': {'base': {'ref': 'main', 'sha': base}}}, 'pull_request'),
        ]
        invalid_runs = [
            {'total_count': 0, 'workflow_runs': []},
            {'total_count': 2, 'workflow_runs': [run]},
            *({'total_count': 1, 'workflow_runs': [dict(run, **invalid)]} for invalid in (
                {'head_sha': 'b' * 40}, {'head_branch': 'other'}, {'event': 'workflow_dispatch'},
                {'head_repository': {'full_name': 'fork/stack'}}, {'status': 'in_progress'},
                {'conclusion': 'failure'}, {'run_attempt': 0},
            )),
        ]
        valid = json.dumps({'total_count': 1, 'workflow_runs': [run]}).encode()
        with patch.dict(os.environ, GITHUB_REPOSITORY=repository), \
                patch.object(affected, 'changed_paths', return_value=['web/Interview.js']):
            for event, name in events:
                with self.subTest(event=name):
                    with patch.object(affected.subprocess, 'check_output',
                                      side_effect=[valid, json.dumps({'jobs': jobs}).encode()]) as api:
                        self.assertEqual(affected.selection(event, name, backend_release=True),
                                         {'backend': True, 'native': False, 'backend_groups': 'prep'})
                        self.assertIn(f'head_sha={base}', api.call_args_list[0].args[0])
                        self.assertIn('runs/42/attempts/2/jobs', api.call_args_list[1].args[0][-1])
                    for evidence in invalid_runs:
                        with patch.object(affected.subprocess, 'check_output',
                                          return_value=json.dumps(evidence).encode()):
                            self.assertEqual(affected.selection(event, name, backend_release=True),
                                             {'backend': True, 'native': False, 'backend_groups': 'all'})
            event, name = events[0]
            for proof in ({'jobs': jobs[:1]}, {'jobs': [jobs[0], dict(jobs[1], conclusion='skipped')]}):
                with patch.object(affected.subprocess, 'check_output',
                                  side_effect=[valid, json.dumps(proof).encode()]):
                    self.assertEqual(affected.selection(event, name, backend_release=True)['backend_groups'], 'all')

    def test_unverified_main_cannot_turn_prose_push_into_green_baseline(self):
        event = {'ref': 'refs/heads/main', 'before': 'a' * 40}
        with patch.dict(os.environ, GITHUB_REPOSITORY='example/stack'), \
                patch.object(affected, 'changed_paths', return_value=['README.md']), \
                patch.object(affected.subprocess, 'check_output',
                             side_effect=subprocess.CalledProcessError(1, 'gh')):
            self.assertEqual(affected.selection(event, 'push', backend_release=True),
                             {'backend': True, 'native': False, 'backend_groups': 'all'})

    def test_outputs_and_summary_are_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            event, output, summary = [Path(directory, name) for name in ('event', 'output', 'summary')]
            event.write_text('{}')
            with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event), GITHUB_EVENT_NAME='workflow_dispatch',
                            GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary)):
                affected.main()
            self.assertEqual(output.read_text(),
                             'backend=true\nnative=true\nbackend_groups=all\nnative_upload=true\n')
            self.assertIn('credential scans always run', summary.read_text())
            self.assertIn('Backend feature groups: all', summary.read_text())

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

    def test_pending_native_changes_survive_a_separate_push_until_confirmed(self):
        self.write('ios/Feature.swift', 'source')
        native = self.commit()
        self.write('README.md', 'unrelated push')
        head = self.commit()
        event = {'before': native, 'after': head, 'ref': 'refs/heads/main'}
        check_output = subprocess.check_output
        records = [{'sha': self.base}]

        def command(args, **kwargs):
            if args[0] == 'gh':
                return json.dumps(records).encode()
            return check_output(args, **kwargs)

        with patch.dict(os.environ, GITHUB_REPOSITORY='example/stack'), \
                patch.object(affected.subprocess, 'check_output', side_effect=command):
            self.assertEqual(affected.selection(event, 'push', True, native_release=True),
                             {'backend': False, 'native': True, 'backend_groups': 'none', 'native_upload': True})
            records[0]['sha'] = native
            self.assertEqual(affected.selection(event, 'push', True, native_release=True),
                             {'backend': False, 'native': False, 'backend_groups': 'none', 'native_upload': False})

    def test_prose_only_merge_can_skip_runtime(self):
        self.git('switch', '-c', 'docs')
        self.write('README.md', 'docs')
        branch = self.commit()
        self.git('switch', 'main')
        self.git('merge', '--no-ff', '-m', 'synthetic merge', 'docs')
        event = {'pull_request': {'base': {'sha': self.base}, 'head': {'sha': branch}}}
        self.assertEqual(affected.selection(event, 'pull_request'),
                         {'backend': False, 'native': False, 'backend_groups': 'none'})

    def test_push_and_pr_select_union_of_feature_changes(self):
        self.git('switch', '-c', 'feature')
        self.write('web/Interview.js', 'prep')
        branch = self.commit()
        self.git('switch', 'main')
        self.write('agents/contacts.jac', 'network')
        base = self.commit()
        self.git('merge', '--no-ff', '-m', 'synthetic merge', 'feature')
        head = self.git('rev-parse', 'HEAD')
        push = {'before': self.base, 'after': head}
        pr = {'pull_request': {'base': {'sha': base}, 'head': {'sha': branch}}}
        for event, name in ((push, 'push'), (pr, 'pull_request')):
            self.assertEqual(affected.selection(event, name)['backend_groups'], 'network,prep')

    def test_rename_delete_and_unusual_names_preserve_both_paths(self):
        self.write('web/old name.js', 'payload')
        before = self.commit()
        (self.root / 'docs').mkdir()
        self.git('mv', 'web/old name.js', 'docs/moved.md')
        after = self.commit()
        paths = affected.changed_paths({'before': before, 'after': after}, 'push')
        self.assertEqual(set(paths), {'web/old name.js', 'docs/moved.md'})
        self.assertEqual(affected.select(paths), {'backend': True, 'native': False, 'backend_groups': 'all'})
        self.write('ios/Deleted.swift', 'deleted')
        before = self.commit()
        self.git('rm', 'ios/Deleted.swift')
        after = self.commit()
        self.assertEqual(affected.selection({'before': before, 'after': after}, 'push'), affected.ALL)


if __name__ == '__main__':
    unittest.main()
