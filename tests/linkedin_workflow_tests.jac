"""Owner-scoped LinkedIn sign-in/resume workflow with controlled browser/model results."""
import json;
import os;
import time;
import http.client;
import from http.server { ThreadingHTTPServer }
import from threading { Thread }
import agents.gateway as gateway;
import tempfile;
import from pathlib { Path }
import from io { BytesIO }
import from unittest.mock { patch }

import from jaclang.testing.testing { JacTestClient }
import from agents.linkedin { snapshot }
import from agents.browser_control { BrowserControl }
import core.automation as automation;
import from jaclang.runtime.runtime { JacRuntime }
import from tests.test_local_models { service }

glob TOKEN: str = "linkedin-workflow-test";
glob URL: str = "https://www.linkedin.com/in/candidate/";
def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    if getattr(client,"gateway_port",0) and name in ['agent_linkedin_start','agent_linkedin_profile','agent_run','agent_browser','agent_browser_control','agent_browser_subscribe','agent_respond','agent_retry','agent_cancel'] {
        connection=http.client.HTTPConnection('127.0.0.1',client.gateway_port);
        connection.request('POST','/function/'+name,body=json.dumps(args),headers={'Content-Type':'application/json','Authorization':'Bearer '+client.fixture_token});
        public_response=connection.getresponse();body=public_response.read();connection.close();
        assert public_response.status==200,body;return json.loads(body)['data']['result'];
    }
    response=client.post("/function/"+name,json=args);assert response.status_code==200,response.text;return response.data["result"];
}
def browser_rpc(control: any, frame: dict[str, any], capture: dict[str, any], transport: any) -> any {
    sessions=set();
    def response(request: any, **kwargs: any) -> any {
        if not request.full_url.startswith("http://browser.invalid/") { return transport(request,**kwargs); }
        assert "Authorization" not in request.headers;
        assert "/linkedin/" in request.full_url;
        data=json.loads(request.data);key=(data["owner"],data["id"]);control.relax(key);result: any={};
        if request.full_url.endswith("/linkedin_scan") {
            if key not in sessions {
                sessions.add(key);result={"needs_input":True,"message":"Sign in in the browser.","requests":[{"key":"browser","label":"Sign in here"}]};
            } else { result={"artifact":capture}; }
        } elif request.full_url.endswith("/subscribe") {
            result={"ticket":json.dumps(key)};
        } elif request.full_url.endswith("/control") {
            result=control.transition(key,data["action"],data.get("generation",-1),data.get("controller",""),data.get("instance"));
        } else { assert request.full_url.endswith("/frame");result=frame; }
        return BytesIO(json.dumps(result).encode());
    }
    return response;
}
def authenticate(client: any, token: str) -> None { client.fixture_token=token;client.set_auth_token(token); }
test "Public LinkedIn login and both continuation actions need no worker or browser credentials" {
    with tempfile.TemporaryDirectory(prefix="stack-linkedin-test-") as directory {
        path=Path(directory)/"agents.json";path.write_text(json.dumps({"provider":"codex-cli"}));
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":"",
            "STACK_BROWSER_URL":"http://browser.invalid","STACK_BROWSER_TOKEN":""}) {
            client: any=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            server=ThreadingHTTPServer(('127.0.0.1',0),gateway.Handler);
            setattr(client,'gateway_port',server.server_port);
            def upstream(path: any, body: any, authorization: any = '', **kwargs: any) -> any {
                response=client.post(path,json=json.loads(body),headers={'Authorization':authorization});
                return (response.status_code,json.dumps({'ok':response.status_code==200,'data':response.data}).encode());
            }
            mocked=patch.object(gateway,'upstream',side_effect=upstream);mocked.start();
            thread=Thread(target=server.serve_forever,daemon=True);thread.start();
            try {
                a=client.register_user("linkedin-owner","Password-test-only-1").data["token"];
                b=client.register_user("linkedin-other","Password-test-only-2").data["token"];
                authenticate(client,a);rpc(client,"agent_save_model",{"selection":"local"});
                text="## Profile coaching\nClearer headline. {No JSON schema required.}";
                capture=snapshot(URL,{"intro":"Candidate Software engineer","about":"I build tools."});
                raw=json.dumps({"choices":[{"message":{"content":text}}]}).encode();
                with service("lmstudio",raw=raw) as (url,requests) {
                    configuration: any={"provider":"codex-cli","invite_only":True,"local_cli_owner":"unbound","local_cli_daily_limit":0,
                        "model_options":{"local":{"provider":"lmstudio","model":"fixture-local","local_model_url":url}}};
                    path.write_text(json.dumps(configuration));
                    with gateway._rate_lock { gateway._rates[('127.0.0.1',int(time.time()/60),False)]=10000; }
                    import urllib.request;
                    transport=urllib.request.urlopen;control=BrowserControl();
                    with patch("urllib.request.urlopen",side_effect=browser_rpc(control,{"image":"fixture","private_login":True},capture,transport)) {
                        run=rpc(client,"agent_linkedin_start",{"url":URL});
                        assert run["status"]=="needs_input" and run["kind"]=="linkedin";
                        viewer=rpc(client,"agent_browser_subscribe",{"id":run["id"]});
                        assert viewer["linkedin"] and viewer["url"]=="http://browser.invalid/linkedin/stream";
                        assert json.loads(viewer["ticket"] as str)[1]==run["id"];
                        assert rpc(client,"agent_browser",{"id":run["id"],"event":{"type":"snapshot"}})["image"]=="fixture";
                        taken=rpc(client,"agent_browser_control",{"id":run["id"],"action":"take","generation":-100,"controller":"x","instance":"old"});
                        assert taken["status"]=="paused";
                        done=rpc(client,"agent_browser_control",{"id":run["id"],"action":"resume","generation":-100,"controller":"different","instance":"old"});
                        assert done["status"]=="completed" and done["artifacts"]["linkedin_review"]["summary"]==text;
                        again=rpc(client,"agent_linkedin_start",{"url":URL});assert again["id"]!=run["id"];
                        assert rpc(client,"agent_respond",{"id":again["id"],"target_role":"Data analyst"})["status"]=="completed";
                        retry_run=rpc(client,"agent_linkedin_start",{"url":URL});
                        with service("lmstudio",status=503) as (unavailable,unused_requests) {
                            configuration["model_options"]["local"]["local_model_url"]=unavailable;path.write_text(json.dumps(configuration));
                            failed=rpc(client,"agent_respond",{"id":retry_run["id"]});
                        }
                        configuration["model_options"]["local"]["local_model_url"]=url;path.write_text(json.dumps(configuration));
                        assert failed["status"]=="failed" and failed["artifacts"]["linkedin_scan"]==capture;
                        assert rpc(client,"agent_retry",{"id":retry_run["id"]})["status"]=="completed";
                    }
                    assert len(requests as list)==3;
                    assert "response_format" not in requests[0][1];
                    assert json.loads(requests[1][1]["messages"][1]["content"] as str)["target_role"]=="Data analyst";
                    assert json.loads(requests[0][1]["messages"][1]["content"] as str)["profile"]==capture["sections"];
                    assert done["cost_cents"]==0 and done["subscription_calls"]==0;
                    configuration["invite_only"]=False;path.write_text(json.dumps(configuration));gateway._rates.clear();
                    authenticate(client,b);
                    assert "error" in rpc(client,"agent_run",{"id":run["id"]});
                    assert "error" in rpc(client,"agent_browser",{"id":run["id"],"event":{}});
                    assert "error" in rpc(client,"agent_respond",{"id":run["id"]});
                    client.close();client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
                    setattr(client,'gateway_port',server.server_port);authenticate(client,a);
                    assert rpc(client,"agent_run",{"id":run["id"]})["artifacts"]["linkedin_review"]["summary"]==text;
                }
            } finally { server.shutdown();server.server_close();thread.join();mocked.stop();client.close();gateway._rates.clear(); }
        }
    }
}
test "LinkedIn analysis ignores every saved task state, lease, attempts and account-policy flag" {
    with tempfile.TemporaryDirectory(prefix="stack-linkedin-state-") as directory {
        previous=JacRuntime.peek_context();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
        try {
            root ++> automation.AgentMemory(deleted=True,admitted=False,policy={"enabled":False});commit();
            capture=snapshot(URL,{"profile":"Candidate"});
            with patch.object(automation.browser_worker,"browser_call",return_value={"artifact":capture}) as browser,
                patch.object(automation.linkedin,"model_config",return_value={"provider":"fixture"}),
                patch.object(automation.linkedin,"review",return_value={"artifact":{"summary":"Raw output"}}),
                patch.object(automation,"config",side_effect=AssertionError("Shared policy/config gate called")) {
                for status in ["queued","running","needs_input","paused","failed","completed","cancelled","blocked","review","uncertain"] {
                    r=root ++> automation.AgentRun(kind="linkedin",workflow_version=2,target_id="self",context={"linkedin_url":URL},
                        created_at=1.0,key=status,status=status,index=999,lease="obsolete",lease_until=time.time()+99999,
                        attempts=999,next_at=time.time()+99999);
                    id=jid(r);commit();
                    endpoint=automation.agent_respond if status in ["queued","running","needs_input","paused"] else automation.agent_retry;
                    result=endpoint(id);
                    assert result["status"]=="completed" and result["artifacts"]["linkedin_review"]["summary"]=="Raw output",result;
                }
                assert browser.call_count==10;

            }
        } finally { ctx.close();if previous is not None { JacRuntime.set_context(previous); } }
    }
}
