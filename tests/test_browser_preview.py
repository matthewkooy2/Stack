import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


dev = module('develop', ROOT / 'scripts/develop.py')
browser = module('browser_preview', ROOT / 'scripts/browser-preview.py')


class BrowserPreview(unittest.TestCase):
    def test_refresh_restores_web_url_without_losing_cli_owner(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = Path(directory)
            config = root / 'storage/agents/config.json'
            config.parent.mkdir(parents=True)
            original = {'provider': 'codex-cli', 'local_cli_owner': 'test-owner', 'local_cli_daily_limit': 20}
            config.write_text(json.dumps(original))
            with patch.object(dev, 'ROOT', root):
                self.assertEqual(dev.configure_browser_preview('test.local'), 'http://test.local:8080')
                first_token = os.environ['STACK_BROWSER_TOKEN']
                self.assertEqual(len(os.environ['STACK_BROWSER_SESSION_KEY']), 44)
                dev.configure_browser_preview('next.local')
            actual = json.loads(config.read_text())
            self.assertEqual(actual, {**original, 'web_url': 'http://next.local:8080'})
            self.assertGreaterEqual(len(first_token), 32)
            self.assertNotEqual(first_token, os.environ['STACK_BROWSER_TOKEN'])
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            self.assertNotIn('STACK_BROWSER_TOKEN', config.read_text())
            self.assertNotIn('STACK_BROWSER_SESSION_KEY', config.read_text())

    def test_readiness_waits_for_connected_browser(self):
        process = Mock()
        process.poll.return_value = None
        response = Mock(status=200)
        response.read.return_value = b'{"ready": true}'
        context = Mock()
        context.__enter__ = Mock(return_value=response)
        context.__exit__ = Mock(return_value=False)
        with patch.object(dev, 'urlopen', return_value=context) as request:
            dev.wait_for_service(process, 'http://127.0.0.1:8011/health', 'synthetic-token')
        self.assertEqual(request.call_args.args[0].get_header('Authorization'), 'Bearer synthetic-token')

    def test_dead_browser_does_not_report_ready(self):
        process = Mock()
        process.poll.return_value = 1
        with self.assertRaisesRegex(RuntimeError, 'failed to start'), patch.object(dev, 'urlopen') as request:
            dev.wait_for_service(process, 'http://127.0.0.1:8011/health')
        request.assert_not_called()

    def test_image_context_excludes_accounts_and_credentials(self):
        self.assertTrue(all(name.startswith(('agents/', 'discovery/', 'deploy/')) for name in browser.FILES))
        self.assertFalse(any('storage' in name or name.startswith('.jac/') or 'credentials' in name for name in browser.FILES))
        self.assertIn('agents/linkedin.jac', browser.FILES)

    def test_missing_docker_fails_before_build(self):
        with patch.object(browser.shutil, 'which', return_value=None), patch.object(browser.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Install Docker'):
                browser.prepare()
        run.assert_not_called()

    def test_low_disk_space_prevents_browser_download(self):
        with patch.object(browser.shutil, 'which', return_value='/local/docker'), \
             patch.object(browser.shutil, 'disk_usage', return_value=Mock(free=500 * 1024 ** 2)), \
             patch.object(browser.subprocess, 'run', side_effect=[Mock(returncode=0), Mock(returncode=1)]) as run:
            with self.assertRaisesRegex(RuntimeError, 'Free at least 2 GB'):
                browser.prepare()
        self.assertEqual(run.call_count, 2)

    def test_mac_starts_docker_before_installing_preview(self):
        with patch.object(browser.sys, 'platform', 'darwin'), \
             patch.object(browser.shutil, 'which', return_value='/local/docker'), \
             patch.object(browser.subprocess, 'run', side_effect=[Mock(returncode=1), Mock(returncode=0), Mock(returncode=0), Mock(returncode=0)]) as run:
            browser.prepare()
        self.assertEqual(run.call_args_list[1].args[0], ['docker', 'desktop', 'start', '--timeout', '45'])

    def test_cached_browser_needs_no_download_with_low_disk_space(self):
        with patch.object(browser.shutil, 'which', return_value='/local/docker'), \
             patch.object(browser.shutil, 'disk_usage') as usage, \
             patch.object(browser.subprocess, 'run', return_value=Mock(returncode=0)):
            browser.prepare()
        usage.assert_not_called()

    def test_gateway_exposes_linkedin_but_not_worker_authority(self):
        from agents.gateway import PERSONAL
        self.assertIn('agent_linkedin_start', PERSONAL)
        self.assertIn('agent_features', PERSONAL)
        self.assertNotIn('agent_claim', PERSONAL)
        self.assertNotIn('agent_authorize', PERSONAL)


if __name__ == '__main__':
    unittest.main()
