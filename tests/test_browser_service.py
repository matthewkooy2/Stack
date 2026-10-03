"""Live frames remain accessible during capture, without crossing browser threads."""
import threading
import unittest
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
