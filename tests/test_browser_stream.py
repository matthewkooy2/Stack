"""Real HTTP push and gateway authorization with synthetic frames, no browser."""
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import patch
from agents.browser import BrowserFrames
from agents.browser_control import BrowserControl
from agents.browser_stream import serve
from agents import gateway


class BrowserStreamTests(unittest.TestCase):
    def setUp(self):
        self.key=('synthetic-owner','synthetic-run')
        self.control=BrowserControl();self.frames=BrowserFrames()
        self.host=SimpleNamespace(control=self.control,pool=SimpleNamespace(frames=self.frames))

    def test_push_keeps_only_latest_frame_and_disconnect_leaves_task_running(self):
        first=threading.Event();packets=[];headers={}
        class Sink:
            def write(_,raw): packets.append(json.loads(raw.decode()[6:]));first.set()
            def flush(_): pass
        handler=SimpleNamespace(connection=SimpleNamespace(settimeout=lambda n:None),wfile=Sink(),
            send_response=lambda status:None,send_header=lambda k,v:headers.update({k:v}),end_headers=lambda:None)
        self.frames.put(self.key,dict(image='first',observed_at=1))
        ticket=self.control.grant(self.key)
        thread=threading.Thread(target=lambda:serve(handler,self.host,ticket,duration=.6))
        thread.start();self.assertTrue(first.wait(1));self.assertTrue(self.control.watching(self.key))
        for index in range(20):self.frames.put(self.key,dict(image='latest-'+str(index),observed_at=2))
        thread.join(2);self.assertFalse(thread.is_alive());self.assertFalse(self.control.watching(self.key))
        self.assertEqual([packet['frame']['image'] for packet in packets],['first','latest-19'])
        self.assertEqual(self.control.state(self.key)['mode'],'agent')
        self.assertEqual(headers['Content-Type'],'text/event-stream')
        with self.assertRaises(ValueError):serve(handler,self.host,ticket,duration=0)

    def test_revocation_ends_existing_stream_without_sending_cached_frame(self):
        packets=[]
        class Sink:
            def write(_, raw):
                packets.append(json.loads(raw.decode()[6:]))
                self.control.revoke_owner(self.key[0])
            def flush(_): pass
        handler=SimpleNamespace(connection=SimpleNamespace(settimeout=lambda n:None),wfile=Sink(),
            send_response=lambda status:None,send_header=lambda k,v:None,end_headers=lambda:None)
        self.frames.put(self.key,dict(image='synthetic-private-frame',observed_at=1))
        serve(handler,self.host,self.control.grant(self.key),duration=2)
        self.assertEqual(len(packets),2)
        self.assertTrue(packets[1]['control']['revoked'])
        self.assertNotIn('image',packets[1]['frame'])
        self.assertFalse(self.control.watching(self.key))

    def test_gateway_stream_uses_owner_grant_and_does_not_expose_private_transport(self):
        host=self.host
        class Worker(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                serve(self,host,body['ticket'],duration=.1)
        worker=ThreadingHTTPServer(('127.0.0.1',0),Worker)
        public=ThreadingHTTPServer(('127.0.0.1',0),gateway.Handler)
        threads=[threading.Thread(target=server.serve_forever,daemon=True) for server in (worker,public)]
        for thread in threads:thread.start()
        self.frames.put(self.key,dict(image='fixture-push',observed_at=1))
        gateway._rates.clear();calls=[]
        def upstream(path,body,authorization=''):
            calls.append((path,authorization,json.loads(body)))
            if path.endswith('agent_admission'):result={'admitted':authorization=='Bearer synthetic-account'}
            else:result={'ticket':self.control.grant(self.key),'url':'http://127.0.0.1:'+str(worker.server_port)+'/stream'}
            return 200,json.dumps({'data':{'result':result}}).encode()
        try:
            with patch.object(gateway,'upstream',side_effect=upstream):
                url='http://127.0.0.1:'+str(public.server_port)+'/browser/stream'
                with self.assertRaises(HTTPError) as error:urlopen(Request(url,data=b'{"id":"synthetic-run"}',headers={'Content-Type':'application/json'}))
                self.assertEqual(error.exception.code,403)
                request=Request(url,data=b'{"id":"synthetic-run"}',headers={'Content-Type':'application/json','Authorization':'Bearer synthetic-account'})
                with urlopen(request,timeout=3) as response:
                    raw=response.read().decode();self.assertIn('fixture-push',raw)
                    self.assertNotIn('ticket',raw);self.assertNotIn('/stream',raw)
                self.assertEqual(calls[-1][0],'/function/agent_browser_subscribe')
                self.assertEqual(calls[-1][2],{'id':'synthetic-run'})
        finally:
            for server in (public,worker):server.shutdown();server.server_close()
            for thread in threads:thread.join(2)

if __name__=='__main__':unittest.main()
