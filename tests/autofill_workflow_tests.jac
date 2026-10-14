"""Authenticated autofill lifecycle and fences with synthetic catalog/worker results only."""
import json;
import base64;
import os;
import sys;
import time;
import secrets;
import hashlib;
import tempfile;
import from pathlib { Path }
import from io { BytesIO }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }
import from agents.browser_control { BrowserControl }
import from reportlab.pdfgen.canvas { Canvas }

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post("/function/"+name,json=args);
    assert response.status_code==200,response.text;return response.data["result"];
}

def saved_job(client: any, user: str, url: str) -> str {
    marker=secrets.token_hex(5);source_url="https://example.com/autofill-"+marker;
    source="career:"+hashlib.sha256(source_url.encode()).hexdigest()[:32];
    client.set_auth_token(user);rpc(client,"import_job_url",{"url":source_url});
    client.clear_auth();claim=rpc(client,"discovery_claim",{"token":"autofill-discovery","preferred_id":source});
    assert claim.get("id")==source,claim;
    job_id="job_"+hashlib.sha256((source_url+"/0").encode()).hexdigest()[:32];now=time.time();
    job={"id":job_id,"identity":source_url+"/0","canonical_url":source_url+"/0","url":url,"title":"Synthetic analyst","company":"Fixture","description":"Analyze data.","country":"US","location":"Detroit, MI","locations":["Detroit, MI"],"mode":"Remote","employment_type":"Full-time","seniority":"Entry-level","occupation":"Business","compensation":{},"salary":"Pay not listed","salary_note":"","source":"smartrecruiters","source_id":source,"source_name":"Test","source_job_id":"0","attribution":{},"posted":"Today","posted_at":now,"checked_at":now,"discovered_at":now,"expires_at":0,"snippet":False,"requirements":[],"qualifications":"","eligibility":"","remote_eligibility":"","initial":"F","color":"#EDF2FF","tags":[],"reason":"Test","demo":False};
    rpc(client,"discovery_complete",{"token":"autofill-discovery","id":source,"lease":claim["lease"],"result":{"jobs":[job],"complete":True}});
    client.set_auth_token(user);state=rpc(client,"swipe",{"job_id":job_id,"action":"apply"});
    return [a["id"] for a in state["applications"] if a["job_id"]==job_id][0];
}

test "autofill is model-free account-owned paused and resumable without submission" {
    with tempfile.TemporaryDirectory(prefix="stack-autofill-api-") as directory {
        config=Path(directory)/"agents.json";config.write_text('{"invite_only":false}');
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(config),"STACK_AGENT_WORKER_TOKEN":"autofill-worker","STACK_BROWSER_URL":"http://browser.invalid","STACK_BROWSER_TOKEN":"synthetic-browser-token"}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                owner_token=client.register_user("autofill-owner","Synthetic-password-1").data["token"];
                other_token=client.register_user("autofill-other","Synthetic-password-2").data["token"];
                catalog=[module for (name,module) in sys.modules.items() if str(name).startswith("_jac_app_") and str(name).endswith(".core.catalog")][-1];
                with patch.object(catalog,"_worker_allowed",return_value=True) {
                    app=saved_job(client,owner_token,"https://jobs.lever.co/fixture/test/apply");
                }
                owner=rpc(client,"bootstrap")["user_id"];
                rpc(client,"save_profile",{"name":"Synthetic Person","role":"Analyst","location":"Detroit","mode":"Any","notifications":False});
                rpc(client,"agent_save_facts",{"facts":[{"key":"email","value":"synthetic@example.test","verified":True}]});
                pdf=BytesIO();canvas=Canvas(pdf);canvas.drawString(50,700,"Synthetic resume fixture");canvas.save();encoded=base64.b64encode(pdf.getvalue()).decode();
                uploaded=rpc(client,"upload_resume",{"name":"fixture.pdf","content":encoded});resume_id=uploaded["resumes"][0]["id"];
                rpc(client,"change_resume",{"id":resume_id,"action":"rename","name":"Engineering resume"});
                run=rpc(client,"agent_start",{"kind":"autofill","target_id":app});
                assert run["kind"]=="autofill" and run["browser"]["supported"],run;
                assert rpc(client,"agent_start",{"kind":"autofill","target_id":app})["id"]==run["id"];
                assert "error" in rpc(client,"agent_start",{"kind":"application","target_id":app});
                client.set_auth_token(other_token);
                assert "error" in rpc(client,"agent_start",{"kind":"autofill","target_id":app});
                assert "error" in rpc(client,"agent_browser_subscribe",{"id":run["id"]});
                client.clear_auth();claim=rpc(client,"agent_claim",{"token":"autofill-worker"});
                assert claim["step"]=="browser_autofill" and claim["context"]["facts"][0]["key"]=="email",claim;
                assert "Synthetic Person" in [f["value"] for f in claim["context"]["facts"]];
                auth={"token":"autofill-worker","owner":owner,"id":run["id"],"lease":claim["lease"]};
                waiting=rpc(client,"agent_finish",{**auth,"result":{"needs_input":True,"message":"Review this page.","requests":[{"key":"browser","label":"Review"},{"key":"answer:test","label":"Synthetic question"}],"artifact":{"filled":1,"submission":"user_only"}}});
                assert waiting["status"]=="needs_input" and waiting["artifacts"]["browser_autofill"]["filled"]==1;
                assert waiting["subscription_calls"]==0 and waiting["cost_cents"]==0;
                authority=BrowserControl();key=(owner,run["id"]);
                def transport(request: any, **kwargs: any) -> any {
                    body=json.loads(request.data);assert body["owner"]==owner;
                    if request.full_url.endswith("/control") { result=authority.transition(key,body["action"],body.get("generation",-1),body.get("controller",""),body.get("instance")); }
                    else {
                        if body["event"].get("type")=="upload_resume" {
                            assert body["event"]["document"]=={"name":"Engineering resume.pdf","content":encoded};
                        }
                        try { authority.begin(key,body["event"]);authority.end(key);result={"image":"fixture"}; }
                        except ValueError as e { result={"error":str(e)}; }
                    }
                    return BytesIO(json.dumps(result).encode());
                }
                client.set_auth_token(owner_token);
                with patch("urllib.request.urlopen",side_effect=transport) {
                    took=rpc(client,"agent_browser_control",{"id":run["id"],"action":"take","generation":0,"instance":authority.instance,"controller":"viewer-autofill-fixture"});
                    assert took["status"]=="paused",took;
                    event={"type":"text","text":"manual field","generation":1,"instance":authority.instance,"controller":"viewer-autofill-fixture","sequence":1};
                    assert rpc(client,"agent_browser",{"id":run["id"],"event":event})["image"]=="fixture";
                    assert "error" in rpc(client,"agent_browser",{"id":run["id"],"event":event});
                    upload={**event,"type":"upload_resume","sequence":2,"upload_token":"fixture-upload","resume_id":"other-account","document":{"name":"attacker.docx","content":"invalid"}};
                    assert rpc(client,"agent_browser",{"id":run["id"],"event":upload})["image"]=="fixture";
                    rpc(client,"change_resume",{"id":resume_id,"action":"rename","name":"Engineering resume.docx"});
                    assert rpc(client,"agent_browser",{"id":run["id"],"event":{**upload,"sequence":3}})["image"]=="fixture";
                    client.set_auth_token(other_token);assert "error" in rpc(client,"agent_browser",{"id":run["id"],"event":{**upload,"sequence":4}});client.set_auth_token(owner_token);
                    # User ownership must reject a stale worker finish.
                    client.clear_auth();assert "error" in rpc(client,"agent_finish",{**auth,"result":{"artifact":{}}});
                    client.set_auth_token(owner_token);
                    rpc(client,"agent_save_facts",{"facts":[{"key":"phone","value":"5550100000","verified":True}]});
                    resumed=rpc(client,"agent_browser_control",{"id":run["id"],"action":"resume","generation":1,"instance":authority.instance,"controller":"viewer-autofill-fixture"});
                    # Unknown question requests must not strand autofill in needs_input after takeover.
                    assert resumed["status"]=="queued",resumed;
                    client.clear_auth();next_claim=rpc(client,"agent_claim",{"token":"autofill-worker"});
                    assert next_claim["context"]["browser_generation"]==2;
                    assert "phone" in [f["key"] for f in next_claim["context"]["facts"]];
                    client.set_auth_token(owner_token);stopped=rpc(client,"agent_browser_control",{"id":run["id"],"action":"stop"});
                    assert stopped["status"]=="cancelled",stopped;
                }
                state=rpc(client,"bootstrap");assert [a for a in state["applications"] if a["id"]==app][0]["status"]=="Ready to apply";
            } finally { client.close(); }
        }
    }
}
