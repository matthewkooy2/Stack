"""Private browser worker with live, owner-scoped frames and one Playwright thread."""
import from concurrent.futures { ThreadPoolExecutor }
import from http.server { BaseHTTPRequestHandler, ThreadingHTTPServer }
import json;
import os;
import secrets;
import threading;
import from agents.browser { BrowserPool }
class BrowserHost {
    def init(self: BrowserHost, factory: any = BrowserPool) -> any {
        self.executor = ThreadPoolExecutor(max_workers=1);
        self.pool = self.executor.submit(factory).result();
        self.operation = threading.Lock();
    }
    def dispatch(self: BrowserHost, path: any, data: any) -> any {
        (owner, run) = (data['owner'], data.get('id', ''));
        if ((path == '/frame') and not self.operation.acquire(blocking=False)) {
            return self.pool.frames.get((owner, run));
        }
        if (path != '/frame') {
            self.operation.acquire();
        }
        try {
            return self.executor.submit(self.perform, path, data).result();
        } finally {
            self.operation.release();
        }
    }
    def perform(self: BrowserHost, path: any, data: any) -> any {
        self.pool.expire();
        (owner, run) = (data['owner'], data.get('id', ''));
        if (path == '/purge') {
            return self.pool.purge(owner);
        }
        if (path == '/close') {
            return self.pool.close(owner, run);
        }
        if (path == '/frame') {
            if ((owner, run) not in self.pool.sessions) {
                return {'pending': True};
            }
            return self.pool.handoff(owner, run, {'type': 'snapshot'});
        }
        if (path == '/handoff') {
            return self.pool.handoff(owner, run, data.get('event', {}));
        }
        if (path == '/linkedin_scan') {
            return self.pool.linkedin_scan(owner, run, data['context']);
        }
        if (path == '/inspect') {
            return self.pool.inspect(owner, run, data['context']);
        }
        if (path in ('/fill', '/submit')) {
            return getattr(self.pool, path[1:])(
                owner, run, data['context'], data['artifacts']
            );
        }
        raise ValueError('Unknown browser operation.');
    }
    def expire(self: BrowserHost) -> any {
        if self.operation.acquire(blocking=False) {
            try {
                self.executor.submit(self.pool.expire).result();
            } finally {
                self.operation.release();
            }
        }
    }
}
def main() -> any {
    token = os.environ.get('STACK_BROWSER_TOKEN', '');
    if (len(token) < 32) {
        raise SystemExit('Configure STACK_BROWSER_TOKEN (at least 32 characters).');
    }
    host = BrowserHost();
    class Handler(BaseHTTPRequestHandler) {
        def log_message(self: Handler, *_: any) -> any {
            ;
        }
        def authorized(self: Handler) -> any {
            return secrets.compare_digest(
                self.headers.get('Authorization', ''), ('Bearer ' + token)
            );
        }
        def reply(self: Handler, result: any) -> any {
            raw = json.dumps(result).encode();
            self.send_response(200);
            self.send_header('Content-Type', 'application/json');
            self.send_header('Cache-Control', 'no-store');
            self.send_header('Content-Length', str(len(raw)));
            self.end_headers();
            self.wfile.write(raw);
        }
        def do_GET(self: Handler) -> any {
            if ((self.path != '/health') or not self.authorized()) {
                self.send_error(403);
                return;
            }
            self.reply(
                {'ready': host.executor.submit(host.pool.browser.is_connected).result()}
            );
        }
        def do_POST(self: Handler) -> any {
            if not self.authorized() {
                self.send_error(403);
                return;
            }
            if (
                self.path
                not in (
                    '/frame',
                    '/handoff',
                    '/close',
                    '/purge',
                    '/linkedin_scan',
                    '/inspect',
                    '/fill',
                    '/submit'
                )
            ) {
                self.send_error(404);
                return;
            }
            try {
                size = int(self.headers.get('Content-Length', 0));
                if not (0 < size <= 16000000) {
                    self.send_error(413);
                    return;
                }
                data = json.loads(self.rfile.read(size));
                result = host.dispatch(self.path, data);
            } except Exception as exc {
                result = {
                    'error': str(exc)
                        if isinstance(exc, ValueError)
                        else 'Browser operation failed. Review the session or resume the task.'
                };
            }
            self.reply(result);
        }
    }
    class Server(ThreadingHTTPServer) {
        def service_actions(self: Server) -> any {
            host.expire();
        }
    }
    Server(
        (os.environ.get('STACK_BROWSER_BIND', '127.0.0.1'), 8011), Handler
    ).serve_forever();
}
with entry {
    if (__name__ == '__main__') {
        main();
    }
}
