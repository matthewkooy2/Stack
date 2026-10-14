"""Disposable release simulation: source rollback never restores user data."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'deploy'))
from release_safety import Held, compatibility, transaction, wait_ready

PRIOR = 'a' * 40
CANDIDATE = 'b' * 40


class FakeClock:
    def __init__(self): self.now = 0
    def time(self): return self.now
    def sleep(self, seconds): self.now += seconds


class Safety(unittest.TestCase):
    def test_timeout_retry_and_late_success(self):
        clock = FakeClock()
        attempts = []
        def check(commit, remaining):
            attempts.append(remaining)
            raise Held('api_smoke')
        with self.assertRaisesRegex(Held, 'api_smoke'):
            wait_ready(check, CANDIDATE, attempts=3, interval=2, clock=clock.time, sleep=clock.sleep)
        self.assertEqual(len(attempts), 3)
        self.assertEqual(clock.now, 4)
        def late(commit, remaining): clock.now += 61
        with self.assertRaises(Held):
            wait_ready(late, CANDIDATE, attempts=1, clock=clock.time, sleep=clock.sleep)

    def test_one_epoch_allows_consecutive_routine_releases(self):
        files = {'jac.toml': 'a' * 64, 'main.jac': 'b' * 64, 'agents/gateway.jac': 'c' * 64}
        valid = dict(protocol=2, epoch=PRIOR, files=files, routine_files=['agents/gateway.jac'],
                     browser_files={}, routine_browser_files=[], browser_contract={},
                     data_compatible=True, irreversible_migrations=False)
        old = files
        for value in ('d', 'e', 'f'):
            new = {**files, 'agents/gateway.jac': value * 64}
            compatibility(valid, old, new)
            old = new
        for field in ('protocol', 'epoch', 'files', 'browser_files', 'browser_contract',
                      'data_compatible', 'irreversible_migrations'):
            with self.subTest(field=field), self.assertRaises(Held):
                compatibility({**valid, field: None}, files, files)
        for new in ({**files, 'main.jac': 'e' * 64}, {**files, 'jac.toml': 'e' * 64},
                    {**files, 'new.py': 'e' * 64}, {'jac.toml': files['jac.toml']}):
            with self.subTest(new=new), self.assertRaises(Held):
                compatibility(valid, files, new)
        with self.assertRaises(Held):
            compatibility(valid, {**files, 'main.jac': 'f' * 64}, files)
        with self.assertRaises(Held):
            compatibility({**valid, 'routine_files': ['jac.toml']}, files, files)
        with self.assertRaises(Held):
            compatibility(valid, files, files, candidate_browser={'epoch': PRIOR, 'files': {'evil.py': 'e' * 64}})
        browser = {'files': {'agents/browser.jac': 'a' * 64}, 'contract': {'Dockerfile': 'b' * 64}}
        approved = {**valid, 'browser_files': browser['files'], 'browser_contract': browser['contract']}
        compatibility(approved, files, files, browser, browser)
        with self.assertRaises(Held):
            compatibility(approved, files, files, browser, {**browser, 'contract': {'Dockerfile': 'c' * 64}})

    def simulate(self, failure=''):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            code, data, config = (root / n for n in ('code', 'user-data', 'private-config'))
            code.write_text(PRIOR); data.write_text('saved account'); config.write_text('synthetic secret')
            backup = code.read_bytes()
            writers, receipts, events = [True], [], []
            def stop():
                events.append('stop')
                if failure == 'stop' and events.count('stop') == 2:
                    raise RuntimeError('synthetic stop failure')
                writers[0] = False
            def install():
                self.assertFalse(writers[0]); code.write_text(CANDIDATE)
                if failure in ('install', 'stop'): raise RuntimeError('synthetic partial install')
            def restore():
                self.assertFalse(writers[0]); events.append('restore')
                code.write_bytes(backup)
                if failure == 'restore': raise Held('runtime_config')
            def start():
                events.append('start'); writers[0] = True
                if failure == 'start' and code.read_text() == CANDIDATE:
                    raise RuntimeError('synthetic start failure')
            def check(commit, remaining):
                self.assertTrue(writers[0]); self.assertEqual(code.read_text(), commit)
                if failure in ('unhealthy', 'timeout', 'recovery', 'restore') and commit == CANDIDATE:
                    raise Held('worker_round_trip' if failure == 'unhealthy' else 'readiness_timeout')
                if failure == 'recovery' and commit == PRIOR:
                    raise Held('api_smoke')
            def wait(check, commit):
                clock = FakeClock()
                return wait_ready(check, commit, attempts=3, interval=2, deadline=5,
                                  clock=clock.time, sleep=clock.sleep)
            def finalize():
                if failure == 'finalize': raise RuntimeError('synthetic receipt failure')
            result = transaction(PRIOR, CANDIDATE, stop=stop, install=install, start=start,
                check=check, restore=restore, persist=lambda r: receipts.append(copy.deepcopy(r)),
                finalize=finalize, wait=wait)
            self.assertEqual(data.read_text(), 'saved account')
            self.assertEqual(config.read_text(), 'synthetic secret')
            self.assertNotIn('synthetic secret', json.dumps(receipts))
            self.assertEqual(receipts[-1]['status'], result['status'])
            if not failure:
                self.assertEqual(code.read_text(), CANDIDATE)
                self.assertEqual(result['status'], 'healthy')
            else:
                self.assertIn(result['status'], ('failed', 'held'))
                self.assertEqual(code.read_text(), PRIOR if 'restore' in events else CANDIDATE)
            if failure in ('restore', 'recovery', 'stop'):
                self.assertEqual(result['status'], 'held')
                self.assertFalse(writers[0])
            return result, events

    def test_success(self): self.simulate()
    def test_partial_install_failure(self): self.simulate('install')
    def test_start_failure(self): self.simulate('start')
    def test_unhealthy_candidate_reports_check(self):
        result, _ = self.simulate('unhealthy')
        self.assertEqual(result['failing_check'], 'worker_round_trip')
        self.assertEqual(result['recovery'], 'healthy')
    def test_timeout(self): self.simulate('timeout')
    def test_failed_prior_readiness_holds(self): self.simulate('recovery')
    def test_failed_restore_holds(self): self.simulate('restore')
    def test_failed_stop_never_restores(self):
        _, events = self.simulate('stop')
        self.assertNotIn('restore', events)
    def test_finalization_failure_recovers(self): self.simulate('finalize')


if __name__ == '__main__': unittest.main()
