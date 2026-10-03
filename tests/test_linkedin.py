"""Profile capture boundaries, lifecycle and analysis; no LinkedIn or model calls."""
import copy
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from agents import linkedin, provider, worker, contracts
from agents.browser import BrowserPool, BrowserFrames

URL = 'https://www.linkedin.com/in/candidate/'
CAPTURE = linkedin.snapshot(URL, {'intro': 'Candidate\nSoftware engineer', 'about': 'I build tools.', 'experience': 'Built a tracker.'})
REVIEW = {'summary': 'Make your impact clearer.', 'strengths': ['Relevant engineering experience.'],
          'findings': [{'section': 'about', 'priority': 'high', 'quote': 'I build tools.',
                        'weakness': 'The description is broad.', 'why_it_matters': 'Recruiters need to understand your focus.',
                        'recommendation': 'Name a specific project and the problem it solves.'}],
          'rewrites': [{'section': 'headline', 'text': 'Software engineer | Building tools',
                        'evidence': [{'source': 'linkedin:intro', 'quote': 'Software engineer', 'claim': 'Role'}]}],
          'questions': ['What measurable impact did the tracker have?'],
          'evidence': [{'source': 'linkedin:about', 'quote': 'I build tools.', 'claim': 'Broad description'}]}


class LinkedIn(unittest.TestCase):
    def pool(self):
        pool = BrowserPool.__new__(BrowserPool)
        pool.browser = MagicMock()
        pool.sessions = {}
        pool.frames = BrowserFrames()
        page = pool.browser.new_context.return_value.new_page.return_value
        page.url = URL
        page.viewport_size = {'width': 430, 'height': 780}
        page.screenshot.return_value = b'fake-jpeg'
        pool.browser.new_context.return_value.cookies.return_value = [{'name': 'li_at', 'value': 'synthetic-fixture'}]
        page.locator.return_value.count.return_value = 0
        page.evaluate.side_effect = lambda script: CAPTURE['sections'] if script == linkedin.CAPTURE_JS else None
        return pool, page

    def test_only_explicit_linkedin_profiles_are_accepted(self):
        self.assertEqual(linkedin.profile_url('https://linkedin.com/in/candidate/?trk=abc#x'), URL)
        for url in ('http://www.linkedin.com/in/a', 'https://linkedin.com.evil.test/in/a',
                    'https://user:pw@linkedin.com/in/a', 'https://linkedin.com/feed/',
                    'https://linkedin.com/in/a/details/experience/', 'https://linkedin.com/in/a%2fb',
                    'https://linkedin.com:444/in/a', 'https://127.0.0.1/in/a', 'https://linkedin.com/in/%2E%2E'):
            with self.subTest(url=url), self.assertRaises(ValueError): linkedin.profile_url(url)

    def test_browser_destination_boundary(self):
        for url in ('https://www.linkedin.com/login', 'https://www.linkedin.com/checkpoint/challenge'):
            self.assertTrue(linkedin.browser_request_allowed(url, True))
        self.assertTrue(linkedin.browser_request_allowed('https://static.licdn.com/a.js'))
        for url in ('https://linkedin.com.evil.test/', 'file:///tmp/a', 'http://linkedin.com/', 'https://127.0.0.1/', 'https://www.linkedin.com:444/'):
            self.assertFalse(linkedin.browser_request_allowed(url))
        self.assertFalse(linkedin.browser_request_allowed('https://static.licdn.com/a', True))

    def test_capture_is_bounded_and_unread_is_not_missing(self):
        captured = linkedin.snapshot(URL, {**{k: 'x'*8000 for k in linkedin.SECTIONS}, 'password': 'secret', 'messages': 'private'})
        self.assertLessEqual(sum(map(len, captured['sections'].values())), 24000)
        self.assertNotIn('password', captured['sections']);self.assertNotIn('messages', captured['sections'])
        self.assertIn('skills', CAPTURE['unread_sections'])
        self.assertIn('not confirmed missing', CAPTURE['limitations'])
        with self.assertRaises(ValueError): linkedin.snapshot(URL, {'about': 'No profile header'})

    def test_first_scan_always_waits_for_user_then_captures_and_closes(self):
        pool, page = self.pool()
        result = linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        self.assertTrue(result['needs_input']);page.evaluate.assert_not_called()
        page.goto.assert_called_once_with('https://www.linkedin.com/login', wait_until='domcontentloaded', timeout=5000)
        self.assertNotIn('storage_state', pool.browser.new_context.call_args.kwargs)
        result = linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        self.assertEqual(result['artifact']['sections'], CAPTURE['sections'])
        self.assertFalse(pool.sessions)
        pool.browser.new_context.return_value.close.assert_called_once()
        self.assertEqual(pool.frames.get(('owner', 'run')), {'pending': True})

    def test_capture_waits_for_hydrated_header_and_publishes_progress(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        with patch.object(pool, 'publish', wraps=pool.publish) as frames:
            result = linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        self.assertIn('artifact', result)
        page.wait_for_function.assert_called_once()
        self.assertGreaterEqual(frames.call_count, 16)
        self.assertIn(unittest.mock.call('window.scrollTo(0, 0)'), page.evaluate.call_args_list)

    def test_resumed_navigation_and_capture_failures_identify_the_actual_stage(self):
        for failure, stage in [('navigation', 'navigate_profile'), ('capture', 'capture_frame')]:
            with self.subTest(failure=failure):
                pool, page = self.pool()
                linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
                if failure == 'navigation':
                    page.url = 'https://www.linkedin.com/login'
                    page.goto.side_effect = TimeoutError('synthetic private text')
                else: page.screenshot.side_effect = RuntimeError('synthetic private text')
                with self.assertRaises((TimeoutError, RuntimeError)):
                    linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
                self.assertEqual(pool.operation_stage, stage)
                self.assertIn(('owner', 'run'), pool.sessions)

    def test_loading_timeout_pauses_without_fabricated_capture(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        page.wait_for_function.side_effect = TimeoutError('fixture loading delay')
        result = linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        self.assertTrue(result['needs_input'])
        self.assertNotIn('artifact', result)
        self.assertIn(('owner', 'run'), pool.sessions)

    def test_public_profile_cannot_be_captured_without_signing_in(self):
        pool, page = self.pool()
        pool.browser.new_context.return_value.cookies.return_value = []
        linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        result = linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        self.assertTrue(result['needs_input'])
        self.assertNotIn('artifact', result)
        page.evaluate.assert_not_called()

    def test_mobile_frame_coordinates_and_owner_isolation(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        image = pool.handoff('owner', 'run', {'type': 'click', 'x': 210, 'y': 380})
        self.assertEqual((image['width'], image['height']), (430, 780))
        page.mouse.click.assert_called_once_with(210, 380)
        with self.assertRaisesRegex(ValueError, 'outside'):
            pool.handoff('owner', 'run', {'type': 'click', 'x': 431, 'y': 300})
        self.assertEqual(pool.frames.get(('other', 'run')), {'pending': True})

    def test_login_wall_never_becomes_a_profile_artifact(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        page.url = 'https://www.linkedin.com/checkpoint/challenge'
        result = linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        self.assertTrue(result['needs_input']);self.assertNotIn('artifact', result)
        page.evaluate.assert_not_called()
        self.assertIn(('owner', 'run'), pool.sessions)

    def test_redirect_to_other_profile_is_not_captured(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})
        page.url = 'https://www.linkedin.com/in/someone-else/'
        self.assertTrue(linkedin.scan(pool, 'owner', 'run', {'linkedin_url': URL})['needs_input'])
        page.evaluate.assert_not_called()

    def test_sessions_are_owner_scoped_and_never_checkpointed(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'a', 'run', {'linkedin_url': URL})
        linkedin.scan(pool, 'b', 'run', {'linkedin_url': URL})
        self.assertEqual(len(pool.sessions), 2)
        pool.checkpoint('a', 'run')
        page.evaluate.assert_not_called()
        pool.browser.new_context.return_value.storage_state.assert_not_called()
        pool.close('a', 'run')
        self.assertIn(('b', 'run'), pool.sessions)
        pool.sessions[('b', 'run')]['touched'] = 0
        pool.expire();self.assertFalse(pool.sessions)

    def test_purge_removes_only_owners_live_frames(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'a', 'run', {'linkedin_url': URL})
        linkedin.scan(pool, 'b', 'run', {'linkedin_url': URL})
        with tempfile.TemporaryDirectory() as directory, patch.dict('os.environ', {'STACK_BROWSER_STORAGE': directory}):
            pool.purge('a')
        self.assertEqual(pool.frames.get(('a', 'run')), {'pending': True})
        self.assertIn('image', pool.frames.get(('b', 'run')))
        self.assertIn(('b', 'run'), pool.sessions)

    def test_missing_header_requests_help_instead_of_fake_review(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'a', 'run', {'linkedin_url': URL})
        page.evaluate.side_effect = lambda script: {} if script == linkedin.CAPTURE_JS else None
        self.assertTrue(linkedin.scan(pool, 'a', 'run', {'linkedin_url': URL})['needs_input'])

    def test_profile_handoff_refuses_file_upload(self):
        pool, page = self.pool()
        linkedin.scan(pool, 'a', 'run', {'linkedin_url': URL})
        with self.assertRaisesRegex(ValueError, 'does not upload'):
            pool.handoff('a', 'run', {'type': 'file'})
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            pool.handoff('other', 'run', {'type': 'snapshot'})

    def test_analysis_quotes_and_rewrite_sources_are_checked(self):
        context = {'linkedin_profile': CAPTURE, 'facts': []}
        sources = provider.sources_for(context)
        result = linkedin.validate_review(copy.deepcopy(REVIEW), CAPTURE, sources)
        self.assertEqual(result['unread_sections'], CAPTURE['unread_sections'])
        for change in ({'quote': 'Invented profile content'}, {'section': 'skills'}, {'priority': 'urgent'}):
            bad = copy.deepcopy(REVIEW);bad['findings'][0].update(change)
            with self.assertRaises(ValueError): linkedin.validate_review(bad, CAPTURE, sources)
        bad = copy.deepcopy(REVIEW);bad['rewrites'][0]['evidence'][0]['quote'] = 'Managed 50 people'
        with self.assertRaises(ValueError): linkedin.validate_review(bad, CAPTURE, sources)

    def test_analysis_uses_captured_profile_and_keeps_unknowns(self):
        config = {**contracts.config(), 'provider': 'codex-cli'}
        context = {'linkedin_profile': CAPTURE, 'target_role': 'Engineer', 'facts': []}
        with patch('agents.local_cli.generate', return_value=copy.deepcopy(REVIEW)) as generate:
            result = provider.generate('linkedin_review', context, config)
        self.assertEqual(result['artifact']['profile_url'], URL)
        self.assertIn('linkedin:about', generate.call_args.args[3])
        self.assertIn('unknown, not missing', generate.call_args.args[3])

    def test_invalid_analysis_is_blocked_without_requesting_answers(self):
        c = {**contracts.config(), 'provider': 'codex-cli', 'local_cli_owner': 'owner', 'local_cli_daily_limit': 5}
        work = {'step': 'linkedin_review', 'owner': 'owner', 'id': 'run', 'lease': 'lease',
                'context': {}, 'artifacts': {'linkedin_scan': CAPTURE}, 'provider_config_hash': contracts.digest(c)}
        with patch.object(worker, 'config', return_value=c), patch.object(provider, 'generate', side_effect=ValueError('Source quotation mismatch')):
            result = worker.dispatch(work, 'token')
        self.assertTrue(result['blocked'])
        self.assertNotIn('needs_input', result)
        self.assertEqual(result['requests'], [])
        self.assertEqual(work['artifacts']['linkedin_scan'], CAPTURE)

    def test_review_validation_reports_a_useful_reason(self):
        invalid = copy.deepcopy(REVIEW)
        invalid['findings'][0]['quote'] = 'Invented quote'
        with patch('agents.local_cli.generate', return_value=invalid):
            with self.assertRaisesRegex(ValueError, 'captured evidence.*retry analysis'):
                provider.generate('linkedin_review', {'linkedin_profile': CAPTURE, 'facts': []},
                                  {**contracts.config(), 'provider': 'codex-cli'})

    def test_worker_routes_scan_and_passes_artifact_to_model(self):
        c = {**contracts.config(), 'provider': 'codex-cli', 'local_cli_owner': 'owner', 'local_cli_daily_limit': 5}
        work = {'step': 'linkedin_scan', 'owner': 'owner', 'id': 'run', 'lease': 'lease',
                'context': {'linkedin_url': URL}, 'artifacts': {'linkedin_scan': CAPTURE}, 'provider_config_hash': contracts.digest(c)}
        with patch.object(worker, 'browser_call', return_value={'needs_input': True}) as browser:
            self.assertTrue(worker.dispatch(work, 'token')['needs_input'])
            browser.assert_called_once_with('linkedin_scan', work)
        work['step'] = 'linkedin_review'
        with patch.object(worker, 'config', return_value=c), patch.object(provider, 'generate', return_value={'artifact': REVIEW}) as generate:
            worker.dispatch(work, 'token')
            self.assertEqual(generate.call_args.args[1]['linkedin_profile'], CAPTURE)


if __name__ == '__main__': unittest.main()
