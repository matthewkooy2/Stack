import json;
import os;
import tempfile;
import threading;
import urllib.request;
import urllib.error;
import from urllib.parse { urlencode }
import from pathlib { Path }
import from unittest.mock { patch }
import from http.server { ThreadingHTTPServer }
import agents.gateway as gateway;

def request(base: str, path: str, body: dict[str, any] | None = None, auth: str = '', cookie: str = '') -> any {
    headers={'Content-Type':'application/json'};
    if auth { headers['Authorization']=auth; }
    if cookie { headers['Cookie']=cookie; }
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
                    assert status==200 and 'iPhone' in body and 'fixture-code' not in body;
                    assert 'href="com.matthewkooy.stack://auth/google?state='+state+'"' in body;
                }
                provider='https://accounts.google.com/o/oauth2/v2/auth?'+urlencode({'scope':'openid email profile','state':state,'response_type':'code','code_challenge_method':'S256','redirect_uri':'https://stack.example/sso/google/callback'});
                (status,headers,body)=request(base,'/auth/google/start?'+urlencode({'url':provider}));
                assert status==303 and headers['Location']==provider;
                cookie=headers['Set-Cookie'];assert 'Secure; HttpOnly; SameSite=Lax' in cookie;
                for upstream_status in [200,400] {
                    with patch.object(gateway,'sso_callback_upstream',return_value=(upstream_status,b'Sign-in completed.','')) {
                        (status,headers,body)=request(base,'/sso/google/callback?state='+state+'&code=private-code',cookie=cookie);
                        assert status==303 and headers['Location']=='com.matthewkooy.stack://auth/google?state='+state;
                        assert 'private-code' not in headers['Location'] and 'Max-Age=0' in headers['Set-Cookie'];
                        (status,headers,body)=request(base,'/sso/google/callback?state='+state+'&code=private-code',cookie='stack_native_signin=other');
                        assert status==200 and 'private-code' not in body;
                        assert 'href="com.matthewkooy.stack://auth/google?state='+state+'"' in body;
                    }
                }
                (status,headers,body)=request(base,'/.well-known/apple-app-site-association');
                assert status==200 and headers['Content-Type']=='application/json';
                assert json.loads(body)['applinks']['details'][0]['appIDs']==['38BZ2B7677.com.matthewkooy.stack'];
                (status,headers,body)=request(base,'/open/resume');
                assert status==200 and 'com.matthewkooy.stack://open/resume' in body;
                (status,headers,body)=request(base,'/about');
                assert status==200 and 'href="/privacy"' in body and 'career tools' in body;
                (status,headers,body)=request(base,'/privacy');
                assert status==200 and 'Google sign-in' in body and 'optional connections' in body;
            } finally { server.shutdown();server.server_close();thread.join(timeout=5); }
        }
    }
}
