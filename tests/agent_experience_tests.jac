"""Agent access, review gates and monitoring, with controlled worker results and no external IO."""
import json;
import base64;
import os;
import time;
import hashlib;
import secrets;
import tempfile;
import from pathlib { Path }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }
import from agents.contracts { digest }
import from agents.worker { dispatch }

glob WORKER: str = "experience-test-token";

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post("/function/"+name,json=args);
    assert response.status_code==200, response.text;
    return response.data["result"];
}
def work(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    client.clear_auth();return rpc(client,name,{"token":WORKER,**args});
}
def finish(client: any, claim: dict[str, any], result: dict[str, any]) -> dict[str, any] {
    return work(client,"agent_finish",{"id":claim["id"],"owner":claim["owner"],"lease":claim["lease"],"result":result});
}
def authorize(client: any, claim: dict[str, any], payload_hash: str) -> dict[str, any] {
    return work(client,"agent_authorize",{"id":claim["id"],"owner":claim["owner"],"lease":claim["lease"],"payload_hash":payload_hash});
}
"""Publish one active Lever-hosted catalog job through the real discovery endpoints."""
def lever_job(client: any, token: str, discovery: str) -> str {
    marker="ExperienceTest"+secrets.token_hex(4);url="https://example.com/"+marker;
    source="career:"+hashlib.sha256(url.encode()).hexdigest()[:32];
    client.set_auth_token(token);rpc(client,"import_job_url",{"url":url});
    client.clear_auth();claim=rpc(client,"discovery_claim",{"token":discovery,"preferred_id":source});
    assert claim["id"]==source, claim;
    job_id="job_"+hashlib.sha256((url+"/0").encode()).hexdigest()[:32];now=time.time();
    job={"id":job_id,"identity":url+"/0","canonical_url":url+"/0","url":"https://jobs.lever.co/stacktest/"+marker,"title":marker+" Analyst","company":"Review Test Co","description":"Analyze data.","country":"US","location":"Detroit, MI","locations":["Detroit, MI"],"mode":"Remote","employment_type":"Full-time","seniority":"Entry-level","occupation":"Business","compensation":{},"salary":"Pay not listed","salary_note":"","source":"smartrecruiters","source_id":source,"source_name":"Test","source_job_id":"0","attribution":{},"posted":"Today","posted_at":now,"checked_at":now,"discovered_at":now,"expires_at":0,"snippet":False,"requirements":[],"qualifications":"","eligibility":"","remote_eligibility":"","initial":"R","color":"#EDF2FF","tags":[],"reason":"Test","demo":False};
    rpc(client,"discovery_complete",{"token":discovery,"id":source,"lease":claim["lease"],"result":{"jobs":[job],"complete":True}});
    return job_id;
}

test "agents never launch implicitly and outbound steps wait for review of the exact payload" {
    with tempfile.TemporaryDirectory(prefix="stack-experience-test-") as directory {
        path=Path(directory)/"agents.json";path.write_text(json.dumps({}));
        discovery_file=Path("storage/discovery/worker-token");discovery_file.parent.mkdir(parents=True,exist_ok=True);
        if not discovery_file.exists() { discovery_file.write_text(secrets.token_urlsafe(32)); }
        discovery=discovery_file.read_text().strip();
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":WORKER}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                first=client.register_user("experience-owner","Test-experience-password-1");assert first.ok,first.text;a=first.data["token"];
                second=client.register_user("experience-other","Test-experience-password-2");assert second.ok,second.text;b=second.data["token"];
                client.set_auth_token(a);state=rpc(client,"bootstrap");owner=state["user_id"];
                # Before any setup, every feature explains itself and what is missing.
                features={f["key"]:f for f in state["agents"]["features"]};
                assert len(features)==11 and features["coaching"]["state"]=="unavailable", features["coaching"];
                assert [c for c in features["networking"]["checks"] if c["key"]=="rules" and c["action"]=="rules" and not c["ok"]];
                assert features["code"]["alternative"] and features["applications"]["review"];
                assert state["agents"]["active"]==0 and state["agents"]["attention"]==0;
                path.write_text(json.dumps({"provider":"codex-cli","local_cli_owner":owner,"local_cli_daily_limit":20,"certified_adapters":["lever"],"action_daily_limits":{"browser_fill":5,"submit_application":5,"send_email":5}}));
                limits={"browser_fill":5,"submit_application":5,"send_email":5,"calendar_write":5};
                policy={"enabled":True,"expires_at":time.time()+3600,"actions":["model","browser_fill","submit_application","send_email","gmail_read","calendar_write"],"domains":["jobs.lever.co","example.com"],"daily_limits":limits,"followup_limit":1};
                assert not rpc(client,"agent_save_policy",{"policy":policy}).get("error");
                rpc(client,"agent_save_facts",{"facts":[{"key":"email","value":"owner@example.com","verified":True},{"key":"resume.project","value":"Built an analysis tool.","verified":True}]});
                features={f["key"]:f for f in rpc(client,"agent_features")["features"]};
                assert features["coaching"]["state"]=="ready" and features["code"]["state"]=="unavailable";

                # A right swipe saves the job even when an old client asks to start an agent.
                job_id=lever_job(client,a,discovery);client.set_auth_token(a);
                saved=rpc(client,"swipe",{"job_id":job_id,"action":"apply","start_agent":True});
                application=[x for x in saved["applications"] if x["job_id"]==job_id][0];
                assert application["status"]=="Ready to apply" and saved["agents"]["runs"]==[] and saved["agents"]["active"]==0;

                # Saving a selected contact with send permission does not start outreach.
                contacts=rpc(client,"agent_save_contact",{"data":{"name":"Casey","email":"casey@example.com","company":"Example","selected":True}})["contacts"];
                assert len(contacts)==1 and rpc(client,"agent_activity")["runs"]==[];

                # Application: inspect, fit and tailor run; the fill waits for review.
                run=rpc(client,"agent_start",{"kind":"application","target_id":application["id"]});
                assert run["title"]=="Prepare & apply" and "Review Test Co" in run["context_label"] and run["step_total"]==5;
                claim=work(client,"agent_claim");assert claim["step"]=="inspect", claim;
                fields=[{"label":"Email","type":"email","tag":"input","key":"email","required":True,"name":"email","id":"email","options":[],"value":""},{"label":"Resume/CV","type":"file","tag":"input","key":"answer:resume","required":True,"name":"resume","id":"resume","options":[],"value":""}];
                finish(client,claim,{"artifact":{"adapter":"lever","fields":fields,"schema_hash":"schema"}});
                claim=work(client,"agent_claim");assert claim["step"]=="fit", claim;finish(client,claim,{"artifact":{"summary":"Fit","strengths":[],"gaps":[],"unknowns":[],"evidence":[]}});
                claim=work(client,"agent_claim");assert claim["step"]=="tailor", claim;finish(client,claim,{"artifact":{"summary":"Tailored","ordered_fact_keys":[],"suggested_edits":[],"evidence":[],"pdf":{"name":"Tailored resume.pdf","content":"JVBERi0=","pages":1,"diff":"+ Analyst"}}});
                assert work(client,"agent_claim").get("idle");
                client.set_auth_token(a);pending=rpc(client,"agent_run",{"id":run["id"]});
                assert pending["status"]=="review" and pending["attention"] and pending["next_action"]=="review", pending;
                review=pending["review"];
                assert review["step"]=="fill" and review["answers"]==[{"label":"Email","value":"owner@example.com"}], review;
                assert review["documents"][0]["name"]=="Tailored resume.pdf" and review["destination"]=="jobs.lever.co";
                summary=rpc(client,"agent_activity");assert summary["attention"]==1 and summary["runs"][0]["status"]=="review";

                # Approval is owned and bound to the version reviewed.
                client.set_auth_token(b);assert "error" in rpc(client,"agent_approve",{"id":run["id"],"step":"fill","review_hash":review["hash"]});
                assert "error" in rpc(client,"agent_retry",{"id":run["id"]}) and "error" in rpc(client,"agent_dismiss",{"id":run["id"]});
                client.set_auth_token(a);
                assert "error" in rpc(client,"agent_approve",{"id":run["id"],"step":"fill","review_hash":"stale"});
                assert "error" in rpc(client,"agent_approve",{"id":run["id"],"step":"fill","review_hash":review["hash"],"edits":{"subject":"x","body":"y"}});
                approved=rpc(client,"agent_approve",{"id":run["id"],"step":"fill","review_hash":review["hash"]});assert approved.get("status")=="queued", approved;
                claim=work(client,"agent_claim");assert claim["step"]=="fill", claim;
                assert "match what you approved" in authorize(client,claim,"tampered").get("error","");
                assert authorize(client,claim,digest([claim["context"],claim["artifacts"]])).get("authorized");
                finish(client,claim,{"artifact":{"verified":True,"form_hash":"filled"}});

                # Submission is reviewed separately, then completes with a receipt.
                assert work(client,"agent_claim").get("idle");
                client.set_auth_token(a);pending=rpc(client,"agent_run",{"id":run["id"]});
                assert pending["status"]=="review" and pending["review"]["step"]=="submit" and pending["step_number"]==5;
                rpc(client,"agent_approve",{"id":run["id"],"step":"submit","review_hash":pending["review"]["hash"]});
                claim=work(client,"agent_claim");assert claim["step"]=="submit";
                assert authorize(client,claim,digest([claim["context"],claim["artifacts"]])).get("authorized");
                done=finish(client,claim,{"artifact":{"receipt":"Thank you for applying","url":"https://jobs.lever.co/x","at":time.time(),"adapter":"lever"}});
                assert done["status"]=="completed", done;
                client.set_auth_token(a);state=rpc(client,"bootstrap");
                assert [x for x in state["applications"] if x["id"]==application["id"]][0]["status"]=="Submitted";
                assert "error" in rpc(client,"agent_retry",{"id":run["id"]});
                assert rpc(client,"agent_dismiss",{"id":run["id"]})["dismissed"];

                # Outreach: the draft is reviewed and may be edited; only the approved text is authorized.
                outreach=rpc(client,"agent_start",{"kind":"network","target_id":contacts[0]["id"]});
                claim=work(client,"agent_claim");assert claim["step"]=="research";finish(client,claim,{"artifact":{"summary":"","text":"","url":""}});
                claim=work(client,"agent_claim");assert claim["step"]=="draft";finish(client,claim,{"artifact":{"subject":"Hello","body":"Model draft","selected_fact_keys":[],"evidence":[]}});
                assert work(client,"agent_claim").get("idle");
                client.set_auth_token(a);pending=rpc(client,"agent_run",{"id":outreach["id"]});
                assert pending["status"]=="review" and pending["review"]["to"]=="casey@example.com" and pending["review"]["body"]=="Model draft", pending;
                # Without Gmail sending, the draft stays reviewable (to copy) but cannot be approved for sending.
                assert "Gmail sending is not connected" in pending["review"]["blocked"];
                refused=rpc(client,"agent_approve",{"id":outreach["id"],"step":"send","review_hash":pending["review"]["hash"],"edits":{"subject":"Hello again","body":"My own words"}});
                assert "Gmail sending is not connected" in refused.get("error",""), refused;
                assert rpc(client,"agent_run",{"id":outreach["id"]})["status"]=="review";
                assert rpc(client,"agent_cancel",{"id":outreach["id"]})["status"]=="cancelled";
                assert work(client,"agent_claim").get("idle");

                # Setup problems surface as paused tasks that can be retried after fixing them.
                client.set_auth_token(a);session=rpc(client,"prep_create",{"problem_id":"project"});
                policy["actions"]=[x for x in policy["actions"] if x!="model"];client.set_auth_token(a);rpc(client,"agent_save_policy",{"policy":policy});
                coach=rpc(client,"agent_start",{"kind":"prep","target_id":session["id"]});
                assert rpc(client,"agent_activity")["active"]>=1;
                work(client,"agent_claim");client.set_auth_token(a);blocked=rpc(client,"agent_run",{"id":coach["id"]});
                assert blocked["status"]=="blocked" and blocked["next_action"]=="retry" and blocked["attention"], blocked;
                assert "error" in rpc(client,"agent_dismiss",{"id":coach["id"]});
                policy["actions"]=policy["actions"]+["model"];client.set_auth_token(a);rpc(client,"agent_save_policy",{"policy":policy});
                client.set_auth_token(a);assert rpc(client,"agent_retry",{"id":coach["id"]})["status"]=="queued";
                claim=work(client,"agent_claim");assert claim["id"]==coach["id"] and claim["step"]=="coach";
                finish(client,claim,{"artifact":{"summary":"Specific and clear.","rubric":[],"next_exercises":[],"followup_questions":[],"evidence":[]}});
                client.set_auth_token(a);assert rpc(client,"agent_run",{"id":coach["id"]})["status"]=="completed";
                assert rpc(client,"prep_get",{"id":session["id"]})["feedback"][0]["data"]["summary"]=="Specific and clear.";
                client.set_auth_token(b);assert rpc(client,"agent_activity")["runs"]==[];
            } finally { client.close(); }
        }
    }
}

test "tailoring pauses without quota use then confirms renders and persists a preview" {
    with tempfile.TemporaryDirectory(prefix="stack-tailoring-test-") as directory {
        path=Path(directory)/"agents.json";path.write_text(json.dumps({}));
        discovery=Path("storage/discovery/worker-token").read_text().strip();
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":WORKER}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);resume_id="";
            try {
                signed=client.register_user("tailoring-owner","Tailoring-test-password-1");assert signed.ok,signed.text;
                token=signed.data["token"];owner=rpc(client,"bootstrap")["user_id"];
                path.write_text(json.dumps({"provider":"codex-cli","local_cli_owner":owner,"local_cli_daily_limit":20}));
                rpc(client,"agent_save_policy",{"policy":{"enabled":True,"expires_at":time.time()+3600,"actions":["model"]}});
                uploaded=rpc(client,"upload_resume",{"name":"Candidate.pdf","content":base64.b64encode(Path("tests/fixtures/openresume-laverne.pdf").read_bytes()).decode()});
                resume_id=uploaded["resumes"][0]["id"];
                job=lever_job(client,token,discovery);client.set_auth_token(token);
                application=rpc(client,"swipe",{"job_id":job,"action":"apply"})["applications"][0];
                run=rpc(client,"agent_start",{"kind":"resume","target_id":application["id"]});
                assert work(client,"agent_claim").get("idle");
                client.set_auth_token(token);paused=rpc(client,"agent_run",{"id":run["id"]});
                assert paused["status"]=="needs_input" and paused["needs_resume_review"];
                assert paused["resume_id"]==resume_id and paused["subscription_calls"]==0 and paused["artifacts"]=={};
                # Repeated attempts before confirmation must not reserve a model request.
                rpc(client,"agent_respond",{"id":run["id"]});assert work(client,"agent_claim").get("idle");
                client.set_auth_token(token);assert rpc(client,"agent_run",{"id":run["id"]})["subscription_calls"]==0;
                review=rpc(client,"agent_extract_resume",{"id":resume_id});
                values={f["key"]:f["value"] for section in review["sections"] for f in section["fields"]};
                assert not review["confirmed"];
                confirmed=rpc(client,"resume_save_details",{"id":resume_id,"revision":review["revision"],"values":values,"confirm":True});assert confirmed["confirmed"];
                rpc(client,"agent_respond",{"id":run["id"],"values":[],"reuse":False});
                claim=work(client,"agent_claim");assert claim["id"]==run["id"] and claim["step"]=="tailor";
                keys=[f["key"] for f in claim["context"]["facts"] if f.get("verified") and f["key"].startswith("resume.")];
                suggestion="Consider adding a measured result after verifying it.";
                with patch("agents.provider.generate",return_value={"artifact":{"summary":"Reordered for the role.","ordered_fact_keys":list(reversed(keys)),"suggested_edits":[suggestion],"evidence":[]}}) {
                    result=dispatch(claim,WORKER) as dict[str, any];
                }
                pdf=result["artifact"]["pdf"];
                assert base64.b64decode(pdf["content"]).startswith(b"%PDF-");
                assert pdf["original_text"]==claim["context"]["resume_text"] and pdf["order_changed"];
                assert pdf["checks"]["text_preserved"] and pdf["pages"]>0 and suggestion not in pdf["text"];
                finish(client,claim,result);client.set_auth_token(token);
                done=rpc(client,"agent_run",{"id":run["id"]});assert done["status"]=="completed" and done["subscription_calls"]==1;
                client.reload();client.set_auth_token(token);
                assert rpc(client,"agent_run",{"id":run["id"]})["artifacts"]["tailor"]["pdf"]["content"]==pdf["content"];
            } finally {
                if resume_id { client.set_auth_token(token);rpc(client,"change_resume",{"id":resume_id,"action":"delete"}); }
                client.close();
            }
        }
    }
}
