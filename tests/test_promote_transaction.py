"""Run the real promoter against disposable paths and synthetic service/probes.

No production paths, credentials, systemctl, Docker, or network are used.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'deploy'))


@unittest.skipUnless(sys.platform == 'linux', 'Trusted promoter is Linux only')
class Promoter(unittest.TestCase):
    def run_fixture(self, failure=''):
        import promote_backend as promoter
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); live = root / 'live'; state = root / 'state'
            live.mkdir(); state.mkdir(); (state / 'incoming').mkdir(); (state / 'build').mkdir()
            data = live / 'storage'; data.mkdir(); (data / 'account').write_text('keep-current-data')
            backend = {'main.jac': b'candidate', 'jac.toml': b'unchanged-runtime'}
            (live / 'main.jac').write_bytes(b'prior'); (live / 'jac.toml').write_bytes(backend['jac.toml'])
            policy = {n: promoter.digest((live / n).read_bytes()) for n in ('main.jac', 'jac.toml')}
            (state / 'source-state.json').write_bytes(promoter.canonical(policy))
            (live / '.release-identity.json').write_bytes(promoter.canonical({'commit': 'a' * 40}))
            (state / 'last-release.json').write_bytes(promoter.canonical(dict(commit='a' * 40, status='healthy', probe_protocol=1)))
            (state / 'incoming' / ('c' * 64 + '.tar.gz')).write_bytes(b'synthetic-artifact')
            protected_names = ['/etc/stack/api.env', '/etc/stack/worker.env', '/etc/systemd/system/stack-api.service',
                '/etc/systemd/system/stack-worker.service', '/etc/systemd/system/stack-gateway.service',
                '/opt/stack/scripts/jac', '/usr/local/bin/jac']
            protected = {name: b'synthetic-private-config' for name in protected_names}
            approval = dict(protocol=2, epoch='fixture', files=policy, routine_files=['main.jac'],
                browser_files={}, routine_browser_files=[], browser_contract={},
                data_compatible=failure != 'gate', irreversible_migrations=False,
                protected_files={n: promoter.digest(v) for n, v in protected.items()})
            manifest = dict(commit='b' * 40, files={n: promoter.digest(v) for n, v in backend.items()}, runtime_contract='d' * 64)
            rejected = failure in ('gate', 'frozen', 'added', 'deleted', 'runtime', 'forged')
            if failure in ('frozen', 'forged'):
                approval['routine_files'] = []
                if failure == 'forged': manifest['epoch'] = approval['epoch']
            if failure == 'added': backend['agents/new.py'] = b'new'
            if failure == 'deleted': backend.pop('main.jac')
            if failure == 'runtime': backend['jac.toml'] = b'changed-entrypoint'
            manifest['files'] = {n: promoter.digest(v) for n, v in backend.items()}
            browser_state, image = state / 'browser-state.json', root / 'image-id'
            browser_protected = {}
            if failure in ('browser_drift', 'browser_unhealthy'):
                name = '/etc/stack/browser.env'
                protected[name] = b'original-browser-config'
                browser_protected[name] = promoter.digest(protected[name])
                manifest['browser'] = {'fingerprint': 'e' * 64, 'files': {'agents/browser_service.jac': 'e' * 64}, 'contract': {}}
                approval['browser_files'] = manifest['browser']['files']
                approval['routine_browser_files'] = ['agents/browser_service.jac']
                browser_state.write_bytes(promoter.canonical({'protected': browser_protected, 'image': 'prior-image', 'files': manifest['browser']['files'], 'contract': {}}))
                image.write_bytes(b'synthetic-image')
            def root_file(path):
                name = str(path)
                if name in protected: return protected[name]
                if name == '/etc/stack-release/access.json': return promoter.canonical({'automatic_main_deploy': True, 'automatic_browser_deploy': failure.startswith('browser_')})
                if name == '/etc/stack-release/compatibility.json': return promoter.canonical(approval)
                return path.read_bytes()
            # Only backup root is remapped; all other absolute paths are synthetic
            # config reads intercepted above. No real command is ever executed.
            def paths(value):
                return root / 'backups' if str(value) == '/var/backups/stack' else Path(value)
            active = [True]; commands = []
            def run(args, cwd=None, timeout=None):
                commands.append(args)
                if args[1] == 'stop': active[0] = False
                if args[1] == 'start': active[0] = True
                if args[1] == 'show': return b'inactive\n'
                return b''
            class Probe:
                def __init__(self, *args): pass
                def __call__(self, commit, remaining):
                    from release_safety import Held
                    assert active[0] and json.loads((live / '.release-identity.json').read_bytes())['commit'] == commit
                    if commit == 'b' * 40 and failure in ('unhealthy', 'drift', 'browser_drift', 'browser_unhealthy'):
                        if failure == 'drift': protected[protected_names[0]] = b'changed-config'
                        if failure == 'browser_drift': protected['/etc/stack/browser.env'] = b'changed-browser-config'
                        raise Held('api_smoke')
                def close(self): pass
            real_write = promoter.write_atomic
            failed = [False]
            def write(path, content, group):
                if failure == 'install' and path == live / 'jac.toml' and not failed[0]:
                    failed[0] = True; raise RuntimeError('synthetic install failure')
                return real_write(path, content, group)
            from release_safety import wait_ready
            def quick_wait(check, commit): return wait_ready(check, commit, attempts=1)
            def quick_transaction(*args, **kwargs):
                from release_safety import transaction
                return transaction(*args, **kwargs, wait=quick_wait)
            (root / 'backups').mkdir()
            request = io.TextIOWrapper(io.BytesIO(promoter.canonical({'commit': 'b' * 40, 'sha256': 'c' * 64})))
            stack = types.SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid())
            real_lstat = Path.lstat
            def lstat(path):
                value = real_lstat(path)
                if path == state:
                    fields = list(value); fields[4] = 0; fields[0] &= ~0o022
                    return os.stat_result(fields)
                return value
            with patch.multiple(promoter, LIVE=live, STATE=state, Path=paths, root_file=root_file,
                    validate=lambda *args: (manifest, backend), contract=lambda _: 'd' * 64,
                    secret_env=lambda _: {'STACK_AGENT_WORKER_TOKEN': 'synthetic', 'STACK_BROWSER_TOKEN': 'synthetic-browser'}, run=run,
                    Probe=Probe, write_atomic=write, wait_ready=quick_wait, transaction=quick_transaction), \
                    patch.object(promoter.os, 'geteuid', return_value=0), \
                    patch.object(promoter.pwd, 'getpwnam', return_value=stack), \
                    patch.object(promoter.os, 'chown'), patch.object(promoter.os, 'fchown'), \
                    patch.object(Path, 'lstat', lstat), \
                    patch.multiple(promoter.browser_release, BROWSER_STATE=browser_state, IMAGE_PATH=image,
                        prepare=lambda *args: {'changed': True, 'image': 'candidate-image',
                            'state': {'protected': browser_protected, 'image': 'candidate-image'}}), \
                    patch.object(sys, 'argv', ['promote_backend.py']), patch.object(sys, 'stdin', request), \
                    contextlib.redirect_stdout(io.StringIO()):
                old_mask = os.umask(0o077)
                try:
                    if rejected:
                        with self.assertRaises((RuntimeError, AssertionError)): promoter.main()
                    elif failure:
                        with self.assertRaises(SystemExit): promoter.main()
                    else: promoter.main()
                finally: os.umask(old_mask)
            self.assertEqual((data / 'account').read_text(), 'keep-current-data')
            if rejected:
                self.assertEqual(commands, []); self.assertFalse((state / 'transaction.json').exists())
            else:
                result = json.loads((state / 'transaction.json').read_bytes())
                self.assertEqual(result['status'], 'healthy' if not failure else ('held' if failure in ('drift', 'browser_drift') else 'failed'))
                self.assertEqual((live / 'main.jac').read_bytes(), b'prior' if failure else b'candidate')
                if failure:
                    self.assertEqual(json.loads((state / 'source-state.json').read_bytes()), policy)
                    self.assertEqual(json.loads((state / 'last-release.json').read_bytes())['commit'], 'a' * 40)
                if failure.startswith('browser_'):
                    self.assertEqual(image.read_bytes(), b'synthetic-image')
                    self.assertEqual(json.loads(browser_state.read_bytes())['image'], 'prior-image')
                self.assertNotIn('synthetic-private-config', json.dumps(result))

    def test_success(self): self.run_fixture()
    def test_partial_source_install_restores(self): self.run_fixture('install')
    def test_unhealthy_candidate_restores(self): self.run_fixture('unhealthy')
    def test_configuration_drift_holds(self): self.run_fixture('drift')
    def test_browser_protected_drift_holds(self): self.run_fixture('browser_drift')
    def test_browser_image_and_state_restore(self): self.run_fixture('browser_unhealthy')
    def test_incompatible_pair_stops_before_services(self): self.run_fixture('gate')
    def test_frozen_source_stops_before_services(self): self.run_fixture('frozen')
    def test_added_source_stops_before_services(self): self.run_fixture('added')
    def test_deleted_source_stops_before_services(self): self.run_fixture('deleted')
    def test_full_runtime_configuration_stops_before_services(self): self.run_fixture('runtime')
    def test_release_epoch_claim_cannot_authorize_change(self): self.run_fixture('forged')


if __name__ == '__main__': unittest.main()
