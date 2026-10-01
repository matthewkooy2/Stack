"""Owner-scoped LinkedIn sign-in/resume workflow with controlled browser/model results."""
import json;
import os;
import time;
import tempfile;
import from pathlib { Path }
import from io { BytesIO }
import from unittest.mock { patch }

import from jaclang.testing.testing { JacTestClient }
import from agents.linkedin { snapshot }

glob TOKEN: str = "linkedin-workflow-test";
glob URL: str = "https://www.linkedin.com/in/candidate/";
def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post("/function/"+name,json=args);assert response.status_code==200,response.text;return response.data["result"];
}
def claim(client: any) -> dict[str, any] { client.clear_auth();return rpc(client,"agent_claim",{"token":TOKEN}); }
def finish(client: any, work: dict[str, any], result: dict[str, any]) -> dict[str, any] {
    client.clear_auth();return rpc(client,"agent_finish",{"token":TOKEN,"id":work["id"],"owner":work["owner"],"lease":work["lease"],"result":result});
}
test "LinkedIn profile capture waits for sign-in and remains private to its owner" {
    with tempfile.TemporaryDirectory(prefix="stack-linkedin-test-") as directory {
        path=Path(directory)/"agents.json";path.write_text("{}");
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":TOKEN,"STACK_BROWSER_URL":"http://browser.invalid","STACK_BROWSER_TOKEN":"test"}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                a=client.register_user("linkedin-owner","Password-test-only-1").data["token"];
                b=client.register_user("linkedin-other","Password-test-only-2").data["token"];
                client.set_auth_token(a);owner=rpc(client,"bootstrap")["user_id"];
                saved=rpc(client,"agent_linkedin_profile");assert saved.get("url")=="",saved;
                assert "error" in rpc(client,"agent_linkedin_profile",{"url":"https://evil.example.com/in/a"});
                assert rpc(client,"agent_linkedin_profile",{"url":URL+"?trk=fixture"})["url"]==URL;
                client.set_auth_token(b);saved=rpc(client,"agent_linkedin_profile");assert saved.get("url")=="",saved;
                client.set_auth_token(a);assert rpc(client,"agent_linkedin_profile")["url"]==URL;
                assert rpc(client,"agent_linkedin_profile",{"target_role":"Software engineer"})["target_role"]=="Software engineer";
                client.reload();client.set_auth_token(a);assert rpc(client,"agent_linkedin_profile")["target_role"]=="Software engineer";
                assert "error" in rpc(client,"agent_linkedin_start",{"url":URL});
                path.write_text(json.dumps({"provider":"codex-cli","local_cli_owner":owner,"local_cli_daily_limit":10,"web_url":"https://stack.example.com"}));
                rpc(client,"agent_save_policy",{"policy":{"enabled":True,"expires_at":time.time()+3600,"actions":["model"]}});
                assert "error" in rpc(client,"agent_linkedin_start",{"url":"https://evil.example.com/in/a"});
                with patch.dict(os.environ,{"STACK_BROWSER_URL":""}) { assert "error" in rpc(client,"agent_linkedin_start",{"url":URL}); }
                run=rpc(client,"agent_linkedin_start",{"url":URL,"target_role":"Software engineer"});
                assert run["kind"]=="linkedin" and run["step_total"]==2,run;
                assert rpc(client,"agent_linkedin_start",{"url":URL,"target_role":"Software engineer"})["id"]==run["id"];
                work=claim(client);assert work["step"]=="linkedin_scan";
                client.set_auth_token(a);
                with patch("urllib.request.urlopen",return_value=BytesIO(b'{"image":"live-frame"}')) as watching {
                    assert rpc(client,"agent_browser",{"id":run["id"],"event":{"type":"snapshot"}})["image"]=="live-frame";
                    assert watching.call_args[0][0].full_url.endswith("/frame");
                    assert "error" in rpc(client,"agent_browser",{"id":run["id"],"event":{"type":"text","text":"no-control-while-working"}});
                    assert watching.call_count==1;
                }
                finish(client,work,{"needs_input":True,"message":"Sign in and confirm your profile.","requests":[{"key":"browser","label":"Sign in here"}]});
                assert claim(client).get("idle");
                client.set_auth_token(b);
                assert "error" in rpc(client,"agent_run",{"id":run["id"]});
                assert "error" in rpc(client,"agent_browser",{"id":run["id"],"event":{}});
                assert "error" in rpc(client,"agent_respond",{"id":run["id"],"values":[]});
                client.set_auth_token(a);
                with patch("urllib.request.urlopen",return_value=BytesIO(b'{"image":"fixture","private_login":true}')) as browser {
                    assert rpc(client,"agent_browser",{"id":run["id"],"event":{"type":"snapshot"}})["private_login"];
                    assert json.loads(browser.call_args[0][0].data)["owner"]==owner;
                }
                with patch("urllib.request.urlopen",return_value=BytesIO(b'{"pending":true}')) {
                    assert rpc(client,"agent_browser",{"id":run["id"],"event":{"type":"snapshot"}}).get("expired");
                }
                with patch("urllib.request.urlopen",side_effect=[BytesIO(b'{"closed":true}'),BytesIO(b'{"needs_input":true}'),BytesIO(b'{"image":"reopened"}')]) as reopened {
                    assert rpc(client,"agent_browser",{"id":run["id"],"event":{"type":"reopen"}}).get("image")=="reopened";
                    assert [c[0][0].full_url for c in reopened.call_args_list]==["http://browser.invalid/close","http://browser.invalid/linkedin_scan","http://browser.invalid/frame"];
                    assert json.loads(reopened.call_args_list[1][0][0].data)["context"]=={"linkedin_url":URL};
                }
                assert "error" in rpc(client,"agent_respond",{"id":run["id"],"values":[{"key":"password","value":"never-save-this"}]});
                resumed=rpc(client,"agent_respond",{"id":run["id"],"values":[]});assert resumed.get("status")=="queued",resumed;
                work=claim(client);assert work["step"]=="linkedin_scan";
                capture=snapshot(URL,{"intro":"Candidate — Software engineer","about":"I build tools."});
                finish(client,work,{"artifact":capture});
                work=claim(client);assert work["step"]=="linkedin_review" and work["artifacts"]["linkedin_scan"]["sections"]["about"]=="I build tools.";
                log_auth={"token":TOKEN,"id":work["id"],"owner":work["owner"],"lease":work["lease"]};
                diagnostic={"attempt_id":"attempt-one","provider":"codex-cli","model":"fixture","status":"received","raw_response":"  {invalid original response}  ","response_format":"model_json","token":"must-not-be-retained"};
                assert "error" in rpc(client,"agent_model_log",{**log_auth,"token":"wrong","record":diagnostic});
                assert "error" in rpc(client,"agent_model_log",{**log_auth,"lease":"stale","record":diagnostic});
                assert rpc(client,"agent_model_log",{**log_auth,"record":diagnostic})["saved"];
                assert rpc(client,"agent_model_log",{**log_auth,"record":{**diagnostic,"status":"rejected","error":"Invalid JSON"}})["saved"];
                finish(client,work,{"blocked":True,"message":"The AI analysis did not pass source checks.","requests":[]});
                client.set_auth_token(a);paused=rpc(client,"agent_run",{"id":run["id"]});
                assert paused["status"]=="blocked" and paused["requests"]==[];
                assert paused["artifacts"]["linkedin_scan"]==capture;
                logged=rpc(client,"agent_model_logs",{"id":run["id"]})["attempts"];
                assert len(logged)==1 and logged[0]["status"]=="rejected",logged;
                assert logged[0]["raw_response"]==diagnostic["raw_response"] and logged[0]["error"]=="Invalid JSON";
                assert "token" not in logged[0] and "lease" not in logged[0];
                assert "model_logs" not in paused and "linkedin_review" not in paused["artifacts"];
                client.set_auth_token(b);assert "error" in rpc(client,"agent_model_logs",{"id":run["id"]});
                client.set_auth_token(a);assert rpc(client,"agent_export")["model_logs"]==logged;

                assert rpc(client,"agent_retry",{"id":run["id"]})["status"]=="queued";
                work=claim(client);assert work["step"]=="linkedin_review" and work["artifacts"]["linkedin_scan"]==capture;
                log_auth={"token":TOKEN,"id":work["id"],"owner":work["owner"],"lease":work["lease"]};
                assert rpc(client,"agent_model_log",{**log_auth,"record":{**diagnostic,"attempt_id":"attempt-two","status":"accepted","raw_response":"{successful response}"}})["saved"];
                finish(client,work,{"artifact":{"summary":"Clarify your impact.","findings":[],"rewrites":[],"limitations":capture["limitations"]}});
                client.set_auth_token(a);done=rpc(client,"agent_run",{"id":run["id"]});
                assert done["status"]=="completed" and done["artifacts"]["linkedin_review"]["summary"]=="Clarify your impact.";
                history=rpc(client,"agent_model_logs",{"id":run["id"]})["attempts"];
                assert len(history)==2 and history[0]["raw_response"]==diagnostic["raw_response"];
                assert history[1]["status"]=="accepted" and history[1]["raw_response"]=="{successful response}";
                client.clear_auth();assert "error" in rpc(client,"agent_model_log",{**log_auth,"record":diagnostic});
                client.set_auth_token(a);
                assert "error" in rpc(client,"agent_browser",{"id":run["id"],"event":{}});
                assert rpc(client,"agent_settings")["facts"]==[];
                again=rpc(client,"agent_linkedin_start",{"target_role":"Software engineer"});assert again["id"]!=run["id"];
                with patch("urllib.request.urlopen",return_value=BytesIO(b'{"closed":true}')) as browser {
                    assert rpc(client,"agent_cancel",{"id":again["id"]})["status"]=="cancelled";
                    assert browser.call_args[0][0].full_url.endswith("/close");
                }
                assert claim(client).get("idle");
                # Reopen the API against the same isolated store: these are durable records.
                client.close();client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
                client.set_auth_token(a);assert rpc(client,"agent_model_logs",{"id":run["id"]})["attempts"]==history;
                with patch("urllib.request.urlopen",return_value=BytesIO(b'{"purged":true}')) {
                    assert rpc(client,"account_delete",{"username":"linkedin-owner","password":"Password-test-only-1"})["deleted"];
                }
                client.set_auth_token(b);assert rpc(client,"agent_export")["model_logs"]==[];
            } finally { client.close(); }
        }
    }
}
