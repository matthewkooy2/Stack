"""Run on a separate Linux host. This process has no account or provider secrets."""
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

from agents.sandbox import execute
from agents.prep import validate_session


def main():
    token = os.environ.get('STACK_SANDBOX_TOKEN', '')
    if len(token) < 32:
        raise SystemExit('Configure STACK_SANDBOX_TOKEN (at least 32 characters).')

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass

        def do_POST(self):
            if self.path != '/execute' or not secrets.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token):
                self.send_error(403);return
            length = int(self.headers.get('Content-Length', 0))
            if not 0 < length < 150000:
                self.send_error(413);return
            try:
                result = execute(validate_session(json.loads(self.rfile.read(length))))
            except Exception as exc:
                result = {'error': str(exc) if isinstance(exc, ValueError) else 'The sandbox is unavailable.'}
            raw = json.dumps(result).encode()
            self.send_response(200);self.send_header('Content-Type', 'application/json');self.send_header('Content-Length', str(len(raw)));self.end_headers();self.wfile.write(raw)

    HTTPServer((os.environ.get('STACK_SANDBOX_BIND', '127.0.0.1'), 8012), Handler).serve_forever()


if __name__ == '__main__': main()
