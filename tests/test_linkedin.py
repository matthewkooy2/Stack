"""Minimal profile capture, direct model transport, and preserved account scope."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch
from agents import linkedin, worker
from agents.browser import BrowserPool, BrowserFrames
from agents.browser_control import BrowserControl

URL = 'https://www.linkedin.com/in/candidate/'
TEXT = 'Candidate\nSoftware engineer\nI build tools.'
CAPTURE = linkedin.snapshot(URL, {'profile': TEXT})
REVIEW_TEXT = 'Profile coaching. {Plain text, not JSON.}'

class LinkedIn(unittest.TestCase):
    def pool(self):
        pool = BrowserPool.__new__(BrowserPool)
        pool.browser = MagicMock()
        pool.sessions = {}
        pool.frames = BrowserFrames()
        pool.control = BrowserControl()
        page = pool.browser.new_context.return_value.new_page.return_value
        page.url = URL
        page.viewport_size = {'width': 430, 'height': 780}
        page.screenshot.return_value = b'fake-jpeg'
        page.evaluate.side_effect = lambda script: TEXT if script == linkedin.CAPTURE_JS else None
        return pool, page

    def test_addresses_are_passed_through_without_destination_validation(self):
        for url in ('http://localhost:8000/', 'https://example.test/a?b=1#c', 'file:///tmp/example.html', URL):
            self.assertEqual(linkedin.profile_url(url), url)
        self.assertEqual(linkedin.profile_url(' example.test/a '), 'https://example.test/a')

    def test_user_logs_in_then_resume_captures_without_cookie_or_header_checks(self):
        pool, page = self.pool()
        self.assertTrue(linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})['needs_input'])
        page.evaluate.assert_not_called()
        result = linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        self.assertEqual(result['artifact']['sections'], {'profile': TEXT})
        self.assertEqual(page.goto.call_count, 2)
        page.wait_for_function.assert_not_called()
        pool.browser.new_context.return_value.cookies.assert_not_called()
        pool.browser.new_context.return_value.route.assert_not_called()
        pool.browser.new_context.return_value.set_default_timeout.assert_called_once_with(0)
        self.assertFalse(pool.sessions)
        pool.browser.new_context.return_value.close.assert_called_once()

    def test_browser_inputs_have_no_coordinate_text_or_scroll_limits(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        pool.handoff('owner', 'run', {'type': 'click', 'x': 431, 'y': 900})
        page.mouse.click.assert_called_once_with(431, 900)
        pool.handoff('owner', 'run', {'type': 'text', 'text': 'a' * 9000})
        page.keyboard.insert_text.assert_called_once_with('a' * 9000)
        pool.handoff('owner', 'run', {'type': 'scroll', 'dy': 5000})
        page.mouse.wheel.assert_called_once_with(0, 5000)
        pool.handoff('owner', 'run', {'type': 'unknown'})

    def test_login_does_not_expire_and_sessions_remain_owner_scoped(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'a', 'run', {'linkedin_url': URL})
        linkedin.scan(pool, 'b', 'run', {'linkedin_url': URL})
        pool.sessions[('a', 'run')]['touched'] = 0
        pool.expire()
        self.assertEqual(len(pool.sessions), 2)
        pool.close('a', 'run')
        self.assertIn(('b', 'run'), pool.sessions)
        self.assertEqual(pool.frames.get(('a', 'run')), {'pending': True})
        pool.browser.new_context.return_value.storage_state.assert_not_called()

    def test_unrestricted_browser_mode_ignores_stale_control_and_sequence(self):
        control = BrowserControl(); key = ('a', 'run')
        control.relax(key)
        state = control.transition(key, 'take', -100, 'x', 'old-instance')
        self.assertTrue(state['relaxed'])
        control.begin(key, dict(generation=-1, sequence=-1, instance='old', controller='other'))
        control.end(key)
        control.transition(key, 'resume', -100, 'someone-else', 'old')
        generation, mode = control.begin(key, agent_generation=-1, agent_instance='old')
        control.check(key, generation, mode);control.end(key)
        self.assertNotIn('relaxed', control.state(('b', 'run')))
        ticket = control.grant(key)
        with patch('agents.browser_control.time.monotonic', return_value=10**12):
            self.assertEqual(control.consume(ticket), key)
        for _ in range(3): control.watch(key, 1)

    def test_codex_is_one_direct_call_without_login_preflight_timeout_or_output_limit(self):
        def generate(command, **kwargs):
            self.assertNotIn('timeout', kwargs)
            Path(command[command.index('--output-last-message') + 1]).write_text(REVIEW_TEXT * 10000)
            return MagicMock()
        with patch.object(linkedin.subprocess, 'run', side_effect=generate) as run:
            result = linkedin.review(CAPTURE, {'target_role': 'Engineer', 'facts': ['unrelated private fact']},
                                     {'provider': 'codex-cli', 'model': ''})
        self.assertEqual(result['artifact']['summary'], REVIEW_TEXT * 10000)
        self.assertEqual(run.call_count, 1)
        self.assertNotIn('unrelated private fact', run.call_args.kwargs['input'])
        self.assertIn('Engineer', run.call_args.kwargs['input'])
        self.assertNotIn('findings', result['artifact'])

    def test_minimal_config_ignores_unrelated_policy_and_resource_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            path.write_text(json.dumps({'monthly_cents': 'invalid', 'local_cli_daily_limit': 'invalid',
                'model_options': {'local': {'provider': 'lmstudio', 'model': 'selected', 'local_model_url': 'http://fixture'}}}))
            with patch.dict('os.environ', {'STACK_AGENT_CONFIG': str(path)}):
                c = linkedin.model_config('local')
        self.assertEqual((c['provider'], c['model'], c['local_model_url']), ('lmstudio', 'selected', 'http://fixture'))

if __name__ == '__main__': unittest.main()
