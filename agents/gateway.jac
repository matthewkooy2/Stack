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
import from urllib.parse { urlsplit, parse_qs, urlencode }
with entry {
    PERSONAL = `set(
        '''bootstrap save_profile save_timeline swipe save_application mark_application_submitted
select_application_resume save_contact upload_resume read_resume change_resume save_reminder change_reminder
search_jobs get_job save_search reset_search import_job_url get_import_status source_status
agent_settings agent_save_model agent_save_facts agent_save_policy agent_activity agent_run agent_cancel agent_respond agent_traces agent_feedback
agent_reconcile agent_contacts agent_save_contact agent_stop_contact agent_import_contacts agent_events agent_resolve_event
agent_google_start agent_google_finish agent_disconnect agent_export agent_start agent_extract_resume resume_save_details
agent_browser agent_browser_control agent_browser_subscribe prep_live prep_progress prep_for_application prep_catalog prep_sessions prep_create prep_get prep_save account_export account_delete
interview_create interview_get interview_answer interview_correct interview_continue interview_sessions
agent_model_logs agent_linkedin_profile agent_linkedin_start agent_features agent_approve agent_retry agent_dismiss
resume_transfer_complete retry_resume_processing upload_resume_source use_resume_template read_resume_source read_tailored_resume check_tailored_resume score_resume delete_tailored_resume agent_continue_tailoring resume_save_records
transcription_upload transcription_list transcription_get transcription_audio transcription_action transcription_transfer_complete transcription_retry_setup
agent_register_push agent_remove_push agent_notification_status agent_admission resume_bank resume_bank_save resume_bank_delete resume_bank_select'''.split()
    );
    IDENTITY = {'/user/register', '/user/login'};
    SSO = {'/sso/google/begin', '/sso/google/finish', '/sso/google/poll'};
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

class NoRedirect(urllib.request.HTTPRedirectHandler) {
    def redirect_request(self: NoRedirect, req: any, fp: any, code: any, msg: any, headers: any, newurl: any) -> any { return None; }
}

def sso_callback_upstream(query: dict[str, str]) -> any {
    request=urllib.request.Request(BASE+'/sso/google/callback?'+urlencode(query));
    try { response=urllib.request.build_opener(NoRedirect()).open(request,timeout=30); }
    except urllib.error.HTTPError as error { response=error; }
    with response { return (response.status,response.read(65536),response.headers.get('Location','')); }
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
    def list_directory(self: Handler, path: any) -> any { self.send_error(503,'Stack is starting');return None; }
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
            (path not in ('/', '/index.html', '/oauth/google', '/auth/google', '/sso/google/callback'))
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
        if path == '/sso/google/callback' { self.sso_callback();return; }
        if path == '/auth/google' { self.path='/index.html'; }
        super.do_GET();
    }
    def sso_callback(self: Handler) -> any {
        # Jac owns PKCE, state, provider exchange, linking and native polling.
        # Never expose its legacy callback, which can return a JWT in a URL.
        try {
            if len(self.path)>8192 { self.send_error(414);return; }
            values=parse_qs(urlsplit(self.path).query,keep_blank_values=True,max_num_fields=20);
            if any(len(values.get(k,[]))>1 for k in ['code','state','error']) { self.send_error(400);return; }
            state=values.get('state',[''])[0];
            if len(state)!=43 { self.send_error(400);return; }
            query={k:values[k][0] for k in ['code','state','error'] if k in values};
            (status,raw,location)=sso_callback_upstream(query);
            if status in [302,303,307] {
                target=urlsplit(location);expected=urlsplit(os.environ.get('STACK_SSO_CALLBACK_URL',''));
                if target.scheme!=expected.scheme or target.netloc!=expected.netloc or target.path!='/auth/google' or target.fragment {
                    self.send_error(400);return;
                }
                returned=parse_qs(target.query,keep_blank_values=True,max_num_fields=8);
                if set(returned)-{'code','state','error'} or returned.get('state')!=[state] { self.send_error(400);return; }
                self.send_response(303);self.send_header('Location',location);self.end_headers();return;
            }
            # Native completion returns fixed text with no session token.
            message='Google sign-in finished. Return to Stack on your iPhone.' if status==200 and b'Sign-in completed.' in raw else 'Google sign-in was cancelled or could not finish. Return to Stack and try again.';
            page=('<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Stack Google sign-in</title><body><h1>Stack Google sign-in</h1><p>'+message+'</p><a href="/">Return to Stack</a></body></html>').encode();
            self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(page)));self.end_headers();self.wfile.write(page);
        } except Exception { self.send_error(400,'Google sign-in could not finish'); }
    }
    def do_POST(self: Handler) -> any {
        path = urlsplit(self.path).path;
        function = path.removeprefix('/function/')
            if path.startswith('/function/')
            else '';
        if (
            (path not in IDENTITY)
            and (path not in SSO)
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
                auth_limited=path in IDENTITY or (path in SSO and path!='/sso/google/poll');
                key = (address, now, 'sso-poll' if path=='/sso/google/poll' else auth_limited);
                _rates[key] = _rates.get(key, 0) + 1;
                if (_rates[key] > (20 if auth_limited else 300)) {
                    self.send_error(429);
                    return;
                }
            }
            body = self.rfile.read(length);
            authorization = self.headers.get('Authorization', '');
            if ((function in PERSONAL and function!='agent_admission') or path == '/browser/stream' or (path=='/sso/google/begin' and authorization)) {
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
