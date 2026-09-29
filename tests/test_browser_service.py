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
            self.assertEqual(host.dispatch('/frame', {'owner': 'owner', 'id': 'run'}), {'image': 'live-frame'})
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


if __name__ == '__main__': unittest.main()
