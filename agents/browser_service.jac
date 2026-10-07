"""Private browser worker with live, owner-scoped frames and one Playwright thread."""
import from concurrent.futures { ThreadPoolExecutor }
import from http.server { BaseHTTPRequestHandler, ThreadingHTTPServer }
import json;
import os;
import secrets;
import threading;
import time;
import from agents.browser { BrowserPool }
import from agents.browser_control { BrowserControl, BrowserInterrupted, BROWSER_OPERATIONS, BROWSER_ERROR_MESSAGE, browser_diagnostic }
import from agents.browser_stream { serve }
class BrowserHost {
    def init(self: BrowserHost, factory: any = BrowserPool) -> any {
        self.executor = ThreadPoolExecutor(max_workers=1);
        self.pool = self.executor.submit(factory).result();
        self.operation = threading.Lock();
        self.control = BrowserControl();
        self.pool.control = self.control;
        self.pool.operation_guard = None;
    }
    def dispatch(self: BrowserHost, path: any, data: any) -> any {
        (owner, run) = (data['owner'], data.get('id', ''));
        key=(owner,run);
        if path == '/purge' { self.control.revoke_owner(owner); }
        if path == '/control' { return self.control.transition(key,data['action'],data.get('generation',-1),data.get('controller',''),data.get('instance')); }
        if path == '/subscribe' { return {'ticket':self.control.grant(key)}; }
        if ((path == '/frame') and not self.operation.acquire(blocking=False)) {
            return self.pool.frames.get((owner, run));
        }
        if (path != '/frame') {
            self.operation.acquire();
        }
        try {
            return self.executor.submit(self.controlled, path, data).result();
        } finally {
            self.operation.release();
        }
    }
    def controlled(self: BrowserHost, path: any, data: any) -> any {
        key=(data['owner'],data.get('id',''));
        guarded=path in ['/linkedin_scan'] or (path=='/handoff' and data.get('event',{}).get('type','snapshot')!='snapshot');
        began=False;
        started=time.monotonic();self.pool.operation_stage='control_check';
        try {
            if guarded {
                (generation,mode)=self.control.begin(key,data.get('event',{}) if path=='/handoff' else None,data.get('context',{}).get('browser_generation',0),data.get('context',{}).get('browser_instance',''));began=True;
                self.pool.operation_guard=lambda { self.control.check(key,generation,mode); };
            }
            result=self.perform(path,data);
            if guarded { self.pool.operation_guard(); }
            return result;
        } except BrowserInterrupted as exc {
            state=self.control.state(key);
            if state['mode'] in ['stopping','stopped'] { self.pool.close(*key); }
            return {'interrupted':True,'control':state};
        } except Exception as exc {
            if path[1:] not in BROWSER_OPERATIONS { raise; }
            return {'error':BROWSER_ERROR_MESSAGE,'browser_diagnostic':browser_diagnostic(path[1:],self.pool.operation_stage,exc,int((time.monotonic()-started)*1000))};
        } finally {
            self.pool.operation_guard=None;
            self.pool.operation_stage='operation';
            if began { self.control.end(key); }
        }
    }
    def tick(self: BrowserHost) -> any {
        if self.operation.acquire(blocking=False) {
            try { self.executor.submit(self.pool.viewer_tick).result(); }
            finally { self.operation.release(); }
        }
    }
    def perform(self: BrowserHost, path: any, data: any) -> any {
        if path == '/release-smoke' {
            # A fresh memory-only context uses the serving Chromium instance.
            # Block all requests; no sessions, credentials, models or websites.
            context=self.pool.browser.new_context();
            try {
                context.route('**/*',lambda (route: any) { route.abort(); });
                page=context.new_page();
                page.set_content('<p id="probe">Stack readiness</p>',timeout=2000);
                ready=page.locator('#probe').inner_text(timeout=2000)=='Stack readiness';
                return {'ready':ready,'nonce':data['nonce']};
            } finally { context.close(); }
        }
        self.pool.operation_stage='expire_session';
        self.pool.expire();
        self.pool.operation_stage='operation';
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
            if self.path == '/stream' {
                try {
                    size=int(self.headers.get('Content-Length',0));
                    if not (0<size<=1024) { self.send_error(413);return; }
                    serve(self,host,json.loads(self.rfile.read(size))['ticket']);
                } except ValueError { self.send_error(403); }
                return;
            }
            if not self.authorized() {
                self.send_error(403);
                return;
            }
            if (
                self.path
                not in (
                    '/frame',
                    '/release-smoke',
                    '/control',
                    '/subscribe',
                    '/handoff',
                    '/close',
                    '/purge',
                    '/linkedin_scan'
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
                if self.path == '/release-smoke' {
                    if size>128 or not isinstance(data.get('nonce'),str) or len(data['nonce'])!=32 {
                        self.send_error(400);return;
                    }
                    data={'owner':'release-smoke','nonce':data['nonce']};
                }
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
            host.tick();
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
