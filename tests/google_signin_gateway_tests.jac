import json;
import os;
import tempfile;
import threading;
import urllib.request;
import urllib.error;
import from pathlib { Path }
import from unittest.mock { patch }
import from http.server { ThreadingHTTPServer }
import agents.gateway as gateway;

def request(base: str, path: str, body: dict[str, any] | None = None, auth: str = '') -> any {
    headers={'Content-Type':'application/json'};
    if auth { headers['Authorization']=auth; }
    req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers=headers);
    try { response=urllib.request.build_opener(gateway.NoRedirect()).open(req,timeout=5); }
    except urllib.error.HTTPError as e { response=e; }
    with response { return (response.status,response.headers,response.read().decode()); }
}

test "Google sign-in gateway permits only PKCE endpoints and retains admission checks" {
    with tempfile.TemporaryDirectory() as directory {
        Path(directory,'index.html').write_text('fixture-app');
        with patch.dict(os.environ,{'STACK_WEB_DIST':directory,'STACK_SSO_CALLBACK_URL':'https://stack.example/auth/google'}) {
            gateway._rates.clear();server=ThreadingHTTPServer(('127.0.0.1',0),gateway.Handler);
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();base='http://127.0.0.1:'+str(server.server_port);
            try {
                with patch.object(gateway,'upstream',return_value=(200,b'{"data":{"ok":true,"result":{"ok":true}}}')) as upstream {
                    for path in ['/sso/google/begin','/sso/google/finish','/sso/google/poll'] {
                        (status,headers,body)=request(base,path,{'fixture':True});assert status==200;
                        assert headers['Cache-Control']=='no-store' and headers['Referrer-Policy']=='no-referrer';
                    }
                    for path in ['/sso/github/begin','/sso/google/login','/sso/google/register','/sso/google/callback'] {
                        (status,headers,body)=request(base,path,{});assert status==404;
                    }
                    (status,headers,body)=request(base,'/function/agent_admission',{},'Bearer fixture');assert status==200;
                    (status,headers,body)=request(base,'/function/bootstrap',{},'Bearer fixture');assert status==403;
                    (status,headers,body)=request(base,'/sso/google/begin',{},'Bearer fixture');assert status==403;
                }
                (status,headers,body)=request(base,'/auth/google?code=private-code');assert status==200 and body=='fixture-app';
                state='s'*43;location='https://stack.example/auth/google?code=fixture-code&state='+state+'&error=';
                with patch.object(gateway,'sso_callback_upstream',return_value=(303,b'',location)) as upstream {
                    (status,headers,body)=request(base,'/sso/google/callback?state='+state+'&code=fixture-code');
                    assert status==303 and headers['Location']==location;
                    assert headers['Referrer-Policy']=='no-referrer';
                    assert upstream.call_args.args[0]=={'state':state,'code':'fixture-code'};
                }
                for location in ['https://attacker.example/auth/google?state='+state,'https://stack.example/auth/google?token=private-jwt&state='+state] {
                    with patch.object(gateway,'sso_callback_upstream',return_value=(303,b'',location)) {
                        (status,headers,body)=request(base,'/sso/google/callback?state='+state+'&code=fixture-code');assert status==400;
                        assert 'private-jwt' not in body and 'attacker' not in body;
                    }
                }
                with patch.object(gateway,'sso_callback_upstream',return_value=(200,b'Sign-in completed. Return to the app to continue.','')) {
                    (status,headers,body)=request(base,'/sso/google/callback?state='+state+'&code=fixture-code');
                    assert status==200 and 'iPhone' in body and 'fixture-code' not in body and state not in body;
                }
            } finally { server.shutdown();server.server_close();thread.join(timeout=5); }
        }
    }
}
