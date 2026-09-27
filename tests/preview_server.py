"""Loopback-only visual QA server with same-origin proxy to the local API."""
from http.server import SimpleHTTPRequestHandler,ThreadingHTTPServer
from urllib.request import Request,urlopen
from urllib.error import HTTPError
from pathlib import Path
class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw):super().__init__(*a,directory=str(Path(__file__).resolve().parents[1]/'.jac/ui-preview'),**kw)
 def do_POST(self):
  if not self.path.startswith(('/user/','/function/')):self.send_error(404);return
  body=self.rfile.read(int(self.headers.get('Content-Length','0')))
  headers={'Content-Type':'application/json'}
  if self.headers.get('Authorization'):headers['Authorization']=self.headers['Authorization']
  try:r=urlopen(Request('http://127.0.0.1:8000'+self.path,data=body,headers=headers),timeout=30)
  except HTTPError as e:r=e
  with r:
   data=r.read();self.send_response(r.status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*a):pass
ThreadingHTTPServer(('127.0.0.1',8128),Handler).serve_forever()
