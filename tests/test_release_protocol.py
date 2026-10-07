import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'deploy'))
import release_channel
import release_probe
from release_safety import Held


class Protocol(unittest.TestCase):
    @unittest.skipUnless(hasattr(os, 'O_NOFOLLOW'), 'Linux IPC safety flags required')
    def test_actual_ipc_nonce_round_trip_and_captured_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            previous = Path.cwd()
            os.chdir(folder)
            try:
                Path('.jac').mkdir()
                Path('.release-identity.json').write_text(json.dumps({'commit': 'a' * 40}))
                spec = importlib.util.spec_from_file_location('synthetic_readiness', ROOT / 'agents/release_readiness.py')
                module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
                release_channel.channel('prepare', 'a' * 40, 'b' * 32)
                calls = []
                def call(name, args):
                    calls.append(name)
                    return module.api_smoke(args['nonce'])
                module.worker_smoke(call, 'synthetic-token')
                self.assertEqual(release_channel.channel('read'), {'commit': 'a' * 40, 'nonce': 'b' * 32, 'protocol': 1})
                self.assertEqual(calls, ['release_smoke'])
                Path('.release-identity.json').write_text(json.dumps({'commit': 'c' * 40}))
                self.assertEqual(module.api_smoke('b' * 32)['commit'], 'a' * 40)
                release_channel.channel('prepare', 'c' * 40, 'd' * 32)
                module.worker_smoke(call, 'synthetic-token')
                with self.assertRaises(OSError): release_channel.channel('read')
                release_channel.channel('close')
                self.assertFalse(Path('.jac/release-readiness/challenge.json').exists())
            finally: os.chdir(previous)

    def test_probe_rejects_wrong_revision_worker_gateway_browser(self):
        for failing in ('api_smoke', 'worker_round_trip', 'gateway', 'browser_smoke'):
            probe = release_probe.Probe(Path('.'), 'private-token', 'browser-token', lambda _: None)
            def ipc(action, *args):
                if action == 'read':
                    return expected if failing != 'worker_round_trip' else {**expected, 'nonce': '0' * 32}
                return {}
            def http(url, body=None, **kwargs):
                if '8000' in url:
                    return {'data': {'result': expected if failing != 'api_smoke' else {**expected, 'commit': '0' * 40}}}
                if '8080' in url:
                    return {'commit': 'a' * 40, 'ready': failing != 'gateway'}
                return {'ready': failing != 'browser_smoke', 'nonce': probe.nonce}
            def prepare(action, *args):
                nonlocal expected
                if action == 'prepare': expected = {'commit': args[0], 'nonce': args[1], 'protocol': 1}
                return ipc(action, *args)
            expected = {}
            with patch.object(probe, 'ipc', prepare), patch.object(release_probe, 'http', http):
                with self.subTest(check=failing), self.assertRaisesRegex(Held, failing):
                    probe('a' * 40, 60)

    def test_http_secret_is_stdin_and_hard_deadline(self):
        import subprocess
        with patch.object(release_probe.subprocess, 'run', side_effect=subprocess.TimeoutExpired('synthetic', .1)) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                release_probe.http('http://127.0.0.1:8000/function/release_smoke', token='private-synthetic', timeout=.1)
        args, kwargs = run.call_args
        self.assertNotIn('private-synthetic', repr(args))
        self.assertIn(b'private-synthetic', kwargs['input'])
        self.assertEqual(kwargs['timeout'], .1)


if __name__ == '__main__': unittest.main()
