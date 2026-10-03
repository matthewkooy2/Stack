"""Capture failures and stale callbacks must not retain CDP sessions or leak frames."""
import time
import unittest
from types import SimpleNamespace
from agents.browser import BrowserPool, BrowserFrames
from agents.browser_control import BrowserControl


class CDP:
    def __init__(self, fail=''):
        self.fail=fail;self.calls=[];self.detached=False
    def on(self, name, callback): self.callback=callback
    def send(self, name, args=None):
        self.calls.append(name)
        if name==self.fail: raise RuntimeError('Synthetic closed page')
    def detach(self): self.detached=True


class CaptureTests(unittest.TestCase):
    def setup_pool(self, fail=''):
        pool=BrowserPool.__new__(BrowserPool)
        pool.frames=BrowserFrames();pool.control=BrowserControl();pool.operation_guard=None
        cdp=CDP(fail);key=('synthetic-owner','synthetic-run');closed=[]
        context=SimpleNamespace(new_cdp_session=lambda page:cdp,close=lambda:closed.append(True))
        pool.sessions={key:dict(context=context,page=SimpleNamespace(),touched=time.time()-3601)}
        pool.control.watch(key,1)
        return pool,cdp,key,closed

    def test_failed_start_detaches_and_uses_fallback(self):
        pool,cdp,key,_=self.setup_pool('Page.startScreencast')
        pool.stream_setup(*key)
        self.assertTrue(cdp.detached)
        self.assertTrue(pool.sessions[key]['capture_fallback'])
        self.assertNotIn('cdp',pool.sessions[key])

    def test_last_viewer_disconnect_detaches_even_if_stop_fails(self):
        pool,cdp,key,_=self.setup_pool('Page.stopScreencast')
        pool.stream_setup(*key);pool.control.watch(key,-1);pool.stream_setup(*key)
        self.assertTrue(cdp.detached);self.assertNotIn('cdp',pool.sessions[key])

    def test_stale_callback_cannot_recreate_closed_session_frame(self):
        pool,cdp,key,closed=self.setup_pool()
        pool.stream_setup(*key);pool.close(*key)
        cdp.callback(dict(data='synthetic-private-frame',sessionId=1))
        self.assertEqual(pool.frames.get(key),{'pending':True})
        self.assertTrue(closed);self.assertIn('Page.screencastFrameAck',cdp.calls)

    def test_stop_without_browser_session_is_acknowledged(self):
        pool,cdp,key,_=self.setup_pool()
        pool.sessions.clear();pool.control.transition(key,'stop',-1)
        pool.viewer_tick()
        self.assertEqual(pool.control.state(key)['mode'],'stopped')

    def test_active_viewer_survives_idle_expiry_then_full_cleanup(self):
        pool,cdp,key,closed=self.setup_pool()
        pool.stream_setup(*key);pool.expire();self.assertIn(key,pool.sessions)
        pool.control.watch(key,-1);pool.expire()
        self.assertNotIn(key,pool.sessions);self.assertTrue(cdp.detached);self.assertTrue(closed)

if __name__=='__main__': unittest.main()
