"""Private browser worker. Bind behind the authenticated Stack API, never publicly."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import secrets
from pathlib import Path
from importlib.util import find_spec
import sys

if __name__ == '__main__' and find_spec('jaclang') is None:
    launcher = Path(__file__).resolve().parents[1] / 'scripts/jac'
    os.execv(str(launcher), [str(launcher), 'run', '--no-serve', str(Path(__file__).resolve()), *sys.argv[1:]])

from agents.browser import BrowserPool


def main():
    token = os.environ.get('STACK_BROWSER_TOKEN', '')
    if len(token) < 32:
        raise SystemExit('Configure STACK_BROWSER_TOKEN (at least 32 characters).')
    pool = BrowserPool()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            if not secrets.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token):
                self.send_error(403); return
            size = int(self.headers.get('Content-Length', 0))
            if not 0 < size <= 16000000:
                self.send_error(413); return
            try:
                data = json.loads(self.rfile.read(size))
                owner, run = data['owner'], data.get('id', '')
                if self.path == '/purge':
                    result = pool.purge(owner)
                elif self.path == '/handoff':
                    result = pool.handoff(owner, run, data.get('event', {}))
                elif self.path == '/inspect':
                    result = pool.inspect(owner, run, data['context'])
                elif self.path in ('/fill', '/submit'):
                    result = getattr(pool, self.path[1:])(owner, run, data['context'], data['artifacts'])
                else:
                    self.send_error(404); return
                pool.expire()
            except Exception as exc:
                result = {'error': str(exc) if isinstance(exc, ValueError) else 'Browser operation failed. The session can be reviewed in handoff.'}
            raw = json.dumps(result).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
    HTTPServer((os.environ.get('STACK_BROWSER_BIND', '127.0.0.1'), 8011), Handler).serve_forever()


if __name__ == '__main__':
    main()
