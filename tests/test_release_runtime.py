"""Actual Jac endpoint and browser dispatch, with embedded DB and fake Chromium."""
import importlib.util
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(importlib.util.find_spec('jaclang'), 'Run with pinned Jac runtime')
class Runtime(unittest.TestCase):
    def test_api_authorization_and_nonce_without_account_or_provider(self):
        from jaclang.testing.testing import JacTestClient
        from agents import release_readiness
        if os.environ.get('JAC_DB_URL'):
            self.fail('Disposable tests require no external database URL')
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {'JAC_DB_SCRATCH': '1', 'STACK_AGENT_WORKER_TOKEN': 'synthetic-readiness'}), \
                patch.object(release_readiness, 'REVISION', 'a' * 40):
            client = JacTestClient.from_file(str(ROOT / 'main.jac'), base_path=directory)
            try:
                response = client.post('/function/release_smoke', json={'token': 'invalid', 'nonce': 'b' * 32})
                self.assertIn('error', response.data['result'])
                response = client.post('/function/release_smoke', json={'token': 'synthetic-readiness', 'nonce': 'b' * 32})
                self.assertTrue(response.ok, response.text)
                self.assertEqual(response.data['result'], {'commit': 'a' * 40, 'nonce': 'b' * 32, 'protocol': 1})
                response = client.post('/function/release_smoke', json={'token': 'synthetic-readiness', 'nonce': 'bad'})
                self.assertIn('error', response.data['result'])
            finally: client.close()

    def test_serving_browser_dispatch_uses_isolated_context_and_closes(self):
        from agents.browser_service import BrowserHost
        evidence = {}
        class Context:
            def route(self, pattern, handler): evidence['blocked'] = pattern
            def new_page(self): return self
            def set_content(self, value, timeout): evidence['content'] = value
            def locator(self, selector): return self
            def inner_text(self, timeout): return 'Stack readiness'
            def close(self): evidence['closed'] = True
        class Browser:
            def new_context(self):
                evidence['thread'] = threading.get_ident()
                return Context()
        class Pool:
            def __init__(self):
                self.browser = Browser(); self.sessions = {('fictional', 'session'): 'preserved'}
        host = BrowserHost(Pool)
        try:
            result = host.dispatch('/release-smoke', {'owner': 'release-smoke', 'nonce': 'b' * 32})
            self.assertEqual(result, {'ready': True, 'nonce': 'b' * 32})
            self.assertEqual(evidence['blocked'], '**/*'); self.assertTrue(evidence['closed'])
            self.assertNotEqual(evidence['thread'], threading.get_ident())
            self.assertEqual(host.pool.sessions, {('fictional', 'session'): 'preserved'})
        finally: host.executor.shutdown()


if __name__ == '__main__': unittest.main()
