"""Live frames remain accessible during capture, without crossing browser threads."""
import threading
import unittest
import json
import os
from io import BytesIO
from unittest.mock import patch
from agents import worker
from agents.browser_control import browser_diagnostic, sanitize_browser_diagnostic, BROWSER_ERROR_MESSAGE
from agents.browser import BrowserFrames
from agents.browser_service import BrowserHost


class Pool:
    def __init__(self):
        self.thread = threading.get_ident()
        self.frames = BrowserFrames()
        self.sessions = {('owner', 'run'): {}}
        self.started = threading.Event()
        self.release = threading.Event()

    def expire(self):
        assert threading.get_ident() == self.thread

    def handoff(self, owner, run, event):
        assert threading.get_ident() == self.thread
        return {'image': 'idle-frame'}

    def linkedin_scan(self, owner, run, context):
        assert threading.get_ident() == self.thread
        self.frames.put((owner, run), {'image': 'live-frame'})
        self.started.set()
        assert self.release.wait(5), 'test capture timed out'
        return {'artifact': 'capture'}


class BrowserService(unittest.TestCase):
    def test_scan_failure_retains_only_safe_stage_type_and_duration(self):
        host=BrowserHost(Pool)
        def failed(owner,run,context):
            host.pool.operation_stage='navigate_profile'
            raise TimeoutError('https://private.invalid/profile?token=secret Cookie=secret private profile')
        host.pool.linkedin_scan=failed
        try:
            with patch('agents.browser_service.time.monotonic',side_effect=[10.0,15.0]):
                result=host.dispatch('/linkedin_scan',dict(owner='owner',id='run',context={}))
            self.assertEqual(result,dict(error=BROWSER_ERROR_MESSAGE,browser_diagnostic=dict(
                version=1,operation='linkedin_scan',stage='navigate_profile',error_type='TimeoutError',code='browser_timeout',duration_ms=5000)))
            self.assertEqual(host.control.state(('owner','run'))['mode'],'agent')
            self.assertNotIn('private',json.dumps(result));self.assertNotIn('secret',json.dumps(result))
        finally:host.executor.shutdown()

    def test_worker_keeps_sanitized_diagnostic_instead_of_losing_it_as_value_error(self):
        remote=dict(error='raw exception containing private profile',browser_diagnostic=dict(
            version=1,operation='linkedin_scan',stage='navigate_profile',error_type='TimeoutError',duration_ms=5000,
            url='https://private.invalid',cookie='secret',traceback='private profile'))
        with patch.dict(os.environ,{'STACK_BROWSER_URL':'http://browser.invalid','STACK_BROWSER_TOKEN':'synthetic'}), \
             patch('urllib.request.urlopen',return_value=BytesIO(json.dumps(remote).encode())):
            result=worker.browser_call('linkedin_scan',dict(owner='owner',id='run',context={}))
        self.assertEqual(result['error'],BROWSER_ERROR_MESSAGE)
        self.assertEqual(result['browser_diagnostic']['stage'],'navigate_profile')
        self.assertNotIn('private',json.dumps(result));self.assertNotIn('secret',json.dumps(result))

    def test_transport_failure_never_retains_raw_exception_text(self):
        with patch.dict(os.environ,{'STACK_BROWSER_URL':'http://browser.invalid','STACK_BROWSER_TOKEN':'synthetic'}), \
             patch('urllib.request.urlopen',side_effect=TimeoutError('private URL and Cookie=secret')):
            result=worker.browser_call('linkedin_scan',dict(owner='owner',id='run',context={}))
        self.assertEqual(result['browser_diagnostic']['stage'],'rpc_transport')
        self.assertEqual(result['browser_diagnostic']['error_type'],'TimeoutError')
        self.assertNotIn('secret',json.dumps(result))

    def test_arbitrary_diagnostic_names_and_fields_are_not_a_content_channel(self):
        injected=dict(version=1,operation='linkedin_scan',stage='https://private.invalid',error_type=['secret'],duration_ms=True,profile='private')
        clean=sanitize_browser_diagnostic(injected)
        self.assertEqual(clean['stage'],'operation');self.assertEqual(clean['error_type'],'Exception')
        self.assertEqual(clean['duration_ms'],0);self.assertNotIn('private',json.dumps(clean))
        self.assertEqual(sanitize_browser_diagnostic(dict(injected,operation=['secret'])),{})
        private_type=type('PrivateProfileAndCookie',(Exception,),{})
        self.assertEqual(browser_diagnostic('linkedin_scan','operation',private_type('secret'),0)['error_type'],'Exception')

    def test_frames_during_capture_are_immediate_and_owner_scoped(self):
        host = BrowserHost(Pool)
        results = []
        capture = threading.Thread(target=lambda: results.append(host.dispatch(
            '/linkedin_scan', {'owner': 'owner', 'id': 'run', 'context': {}})))
        try:
            capture.start()
            self.assertTrue(host.pool.started.wait(2))
            self.assertEqual(host.dispatch('/frame', {'owner': 'owner', 'id': 'run'})['image'], 'live-frame')
            self.assertEqual(host.dispatch('/frame', {'owner': 'other', 'id': 'run'}), {'pending': True})
            self.assertEqual(host.dispatch('/frame', {'owner': 'owner', 'id': 'other'}), {'pending': True})
        finally:
            host.pool.release.set()
            capture.join(3)
            host.executor.shutdown()
        self.assertEqual(results, [{'artifact': 'capture'}])

    def test_idle_snapshots_stay_on_playwright_thread(self):
        host = BrowserHost(Pool)
        try:
            self.assertNotEqual(host.pool.thread, threading.get_ident())
            self.assertEqual(host.dispatch('/frame', {'owner': 'owner', 'id': 'run'}), {'image': 'idle-frame'})
            self.assertEqual(host.dispatch('/frame', {'owner': 'other', 'id': 'run'}), {'pending': True})
            host.expire()
        finally:
            host.executor.shutdown()



class BrowserHandoffService(unittest.TestCase):
    def exercise(self, action):
        host = BrowserHost(Pool)
        results = []
        key = ('owner', 'run')
        thread = threading.Thread(target=lambda: results.append(host.dispatch('/linkedin_scan', dict(owner='owner', id='run', context={}))))
        try:
            thread.start();self.assertTrue(host.pool.started.wait(2))
            state = host.dispatch('/control', dict(owner='owner', id='run', action=action, generation=0, controller='viewer-synthetic-test'))
            self.assertEqual(state['mode'], 'pausing' if action == 'take' else 'stopping')
            host.pool.close = lambda *args: host.pool.sessions.pop(key, None)
            host.pool.release.set();thread.join(3)
            self.assertFalse(thread.is_alive())
            self.assertTrue(results[0]['interrupted'])
            self.assertEqual(host.control.state(key)['mode'], 'user' if action == 'take' else 'stopped')
            if action == 'stop': self.assertNotIn(key, host.pool.sessions)
            else:
                state = host.dispatch('/control', dict(owner='owner', id='run', action='resume', generation=1, controller='viewer-synthetic-test'))
                self.assertEqual(state['mode'], 'agent')
                stale = host.dispatch('/inspect', dict(owner='owner', id='run', context={}))
                self.assertTrue(stale['interrupted'], 'old agent generation must not run after resume')
        finally:
            host.pool.release.set();thread.join(3);host.executor.shutdown()

    def test_account_purge_revokes_before_waiting_for_long_operation(self):
        host=BrowserHost(Pool);key=('owner','run');results=[]
        scan=threading.Thread(target=lambda:results.append(host.dispatch('/linkedin_scan',dict(owner='owner',id='run',context={}))))
        purge=threading.Thread(target=lambda:host.dispatch('/purge',dict(owner='owner')))
        host.pool.close=lambda *args:host.pool.sessions.pop(key,None)
        host.pool.purge=lambda owner:dict(purged=True)
        try:
            scan.start();self.assertTrue(host.pool.started.wait(2))
            ticket=host.control.grant(key);purge.start()
            with host.control.condition:
                self.assertTrue(host.control.condition.wait_for(lambda:host.control.state(key).get('revoked'),timeout=1))
            with self.assertRaises(ValueError):host.control.consume(ticket)
            self.assertTrue(scan.is_alive(),'revocation occurs while browser call is still active')
            host.pool.release.set();scan.join(3);purge.join(3)
            self.assertTrue(results[0]['interrupted']);self.assertFalse(purge.is_alive())
        finally:
            host.pool.release.set();scan.join(3);purge.join(3);host.executor.shutdown()

    def test_take_is_out_of_band_and_fences_old_worker_commands(self): self.exercise('take')
    def test_stop_interrupts_and_closes_on_the_playwright_thread(self): self.exercise('stop')

if __name__ == '__main__': unittest.main()
