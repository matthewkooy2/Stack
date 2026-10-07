"""Public HTTPS upstream: serve the workspace and expose only Stack endpoints.

Run behind Caddy on loopback. The Jac writer and worker endpoints stay private.
"""
import from http.server { SimpleHTTPRequestHandler, ThreadingHTTPServer }
import json;
import os;
import from pathlib { Path }
import threading;
import time;
import from agents.browser_stream { relay }
import from agents.transcription_readiness { public_status }
import urllib.error;
import urllib.request;
import from urllib.parse { urlsplit }
with entry {
    PERSONAL = `set(
        '''bootstrap save_profile save_timeline swipe save_application mark_application_submitted
select_application_resume save_contact upload_resume read_resume change_resume save_reminder change_reminder
search_jobs get_job save_search reset_search import_job_url get_import_status source_status
agent_settings agent_save_facts agent_save_policy agent_activity agent_run agent_cancel agent_respond agent_traces agent_feedback
agent_reconcile agent_contacts agent_save_contact agent_stop_contact agent_import_contacts agent_events agent_resolve_event
agent_google_start agent_google_finish agent_disconnect agent_export agent_start agent_extract_resume resume_save_details
agent_browser agent_browser_control agent_browser_subscribe prep_live prep_progress prep_for_application prep_catalog prep_sessions prep_create prep_get prep_save account_export account_delete
agent_model_logs agent_linkedin_profile agent_linkedin_start agent_features agent_approve agent_retry agent_dismiss
resume_transfer_complete retry_resume_processing upload_resume_source use_resume_template read_resume_source read_tailored_resume check_tailored_resume score_resume delete_tailored_resume agent_continue_tailoring resume_save_records
transcription_upload transcription_list transcription_get transcription_audio transcription_action transcription_transfer_complete transcription_retry_setup
agent_register_push agent_remove_push agent_notification_status agent_admission resume_bank resume_bank_save resume_bank_delete resume_bank_select'''.split()
    );
    IDENTITY = {'/user/register', '/user/login'};
    BASE = os.environ.get('STACK_WORKER_API', 'http://127.0.0.1:8000');
    _rate_lock = threading.Lock();
    _rates = {};
}

def upstream(path: any, body: any, authorization: any = '') -> any {
    headers = {'Content-Type': 'application/json'};
    if authorization {
        headers['Authorization'] = authorization;
    }
    request = urllib.request.Request((BASE + path), data=body, headers=headers);
    try {
        response = urllib.request.urlopen(request, timeout=110);
    } except urllib.error.HTTPError as exc {
        response = exc;
    }
    with response {
        return (response.status, response.read((32 * 1024 * 1024)));
    }
}
class Handler(SimpleHTTPRequestHandler) {
    def init(self: Handler, *args: any, **kwargs: any) -> any {
        super.init(
            *args,
            directory=os.environ.get('STACK_WEB_DIST', '.jac/client/workspace/dist'),
            **kwargs
        );
    }
    def log_message(self: Handler, *_: any) -> any {
        ;
    }
    def end_headers(self: Handler) -> any {
        if urlsplit(self.path).path in ['/', '/index.html'] {
            audio=public_status();
            self.send_header('X-Stack-Transcription-State',audio['state']);
            self.send_header('X-Stack-Transcription-Stage',audio['stage']);
            self.send_header('X-Stack-Transcription-Probe',audio['probe']);
            if audio['missing'] { self.send_header('X-Stack-Transcription-Missing-Tools',audio['missing']); }
        }
        self.send_header('Cache-Control', 'no-store');
        self.send_header('X-Content-Type-Options', 'nosniff');
        self.send_header('Referrer-Policy', 'no-referrer');
        self.send_header(
            'Content-Security-Policy',
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'"
        );
        super.end_headers();
    }
    def do_GET(self: Handler) -> any {
        path = urlsplit(self.path).path;
        if (
            (path not in ('/', '/index.html', '/oauth/google'))
            and not (
                path.startswith('/client.')
                and path.endswith('.js')
                and ('/' not in path[1:])
            )
            and (path != '/styles.css')
        ) {
            self.send_error(404);
            return;
        }
        if (path == '/oauth/google') {
            self.path = '/index.html';
        }
        super.do_GET();
    }
    def do_POST(self: Handler) -> any {
        path = urlsplit(self.path).path;
        function = path.removeprefix('/function/')
            if path.startswith('/function/')
            else '';
        if (
            (path not in IDENTITY)
            and path != '/browser/stream'
            and (function not in PERSONAL)
            and (function != 'agent_accept_invite')
        ) {
            self.send_error(404);
            return;
        }
        try {
            length = int(self.headers.get('Content-Length', 0));
            if not (0 < length <= 15000000) {
                self.send_error(413);
                return;
            }
            address = self.headers.get('X-Forwarded-For', self.client_address[0]).split(
                ','
            )[-1].strip();
            with _rate_lock {
                now = int((time.time() / 60));
                for key in `list(_rates) {
                    if (key[1] < now) {
                        del _rates[key];
                    }
                }
                key = (address, now, (path in IDENTITY));
                _rates[key] = _rates.get(key, 0) + 1;
                if (_rates[key] > (20 if (path in IDENTITY) else 300)) {
                    self.send_error(429);
                    return;
                }
            }
            body = self.rfile.read(length);
            authorization = self.headers.get('Authorization', '');
            if (function in PERSONAL or path == '/browser/stream') {
                (status, admission) = upstream(
                    '/function/agent_admission', b'{}', authorization
                );
                checked = json.loads(admission);
                if (
                    (status != 200)
                    or not checked.get('data', {}).get('result', {}).get('admitted')
                ) {
                    self.send_response(403);
                    self.send_header('Content-Type', 'application/json');
                    self.end_headers();
                    self.wfile.write(
                        b'{"ok":false,"error":{"message":"Sign in and accept your beta invitation."}}'
                    );
                    return;
                }
            }
            if path == '/browser/stream' { relay(self,body,authorization,upstream);return; }
            (status, raw) = upstream(path, body, authorization);
            self.send_response(status);
            self.send_header('Content-Type', 'application/json');
            self.send_header('Content-Length', str(len(raw)));
            self.end_headers();
            self.wfile.write(raw);
        } except Exception {
            self.send_error(503, 'Stack is temporarily unavailable');
        }
    }
}
def main() -> None {
    ThreadingHTTPServer((os.environ.get('STACK_GATEWAY_BIND', '127.0.0.1'), int(os.environ.get('STACK_GATEWAY_PORT', '8080'))), Handler).serve_forever();
}
with entry { if __name__ == '__main__' { main(); } }
