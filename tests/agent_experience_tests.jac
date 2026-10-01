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
import agents.resume_processing as resume_processor;
import from functools { partial }

glob WORKER: str = "experience-test-token";

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post("/function/"+name,json=args);
    assert response.status_code==200, response.text;
    result=response.data["result"];
    # Existing workflow scenarios consume completed files. Explicitly drive the
    # separate durable resume lane before asserting downstream behavior.
    if name in ["upload_resume","upload_resume_source","use_resume_template"] and not result.get("error") {
        saved=client._auth_token;
        client.clear_auth();claim=client.post("/function/resume_processing_claim",json={"token":WORKER}).data["result"];
        while not claim.get("idle") {
            with patch.object(resume_processor,"call",side_effect=partial(worker_call,client)) {
                processed=resume_processor.process(claim,WORKER);
            }
            client.clear_auth();client.post("/function/resume_processing_finish",json={"token":WORKER,**{k:claim[k] for k in ["id","owner","lease"]},"result":processed});
            client.clear_auth();claim=client.post("/function/resume_processing_claim",json={"token":WORKER}).data["result"];
        }
        client.set_auth_token(saved);
        result=client.post("/function/bootstrap",json={}).data["result"];
        if name=="upload_resume_source" {
            status=[r for r in result["resumes"] if r["id"]==args["id"]][0]["processing"]["source"];
            if status.get("error") { return {"error":status["error"]}; }
        }
    }
    return result;
}
def work(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    client.clear_auth();return rpc(client,name,{"token":WORKER,**args});
}
"""The worker's API call, routed through the in-process test client."""
def worker_call(client: any, name: str, args: dict[str, any]) -> dict[str, any] {
    value=work(client,name,args);
    if value.get("error") { raise ValueError(value["error"]); }
    return value;
}
"""A stand-in model: rewrites the first bullet of the supplied resume structure without new facts."""
def propose(step: str, context: dict[str, any], configuration: any = None, observe: any = None, record: any = None) -> dict[str, any] {
    first=[b for s in context["resume_structure"] for e in s["entries"] for b in e["bullets"]][0];
    return {"artifact":{"summary":"Focused on analysis.","ranking":[first["id"]],"entry_order":[],"omit":[],"evidence":[],
        "rewrites":[{"id":first["id"],"text":"Rewritten: "+first["text"],"reason":"Leads with the most relevant work."}]},"cost_cents":0,"provider_id":""};
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

                # Tailoring needs LaTeX: here Jake's template, filled from confirmed details. The job was saved first and uses the default resume.
                resume_id=rpc(client,"upload_resume",{"name":"Candidate.pdf","content":base64.b64encode(Path("tests/fixtures/openresume-laverne.pdf").read_bytes()).decode()})["resumes"][0]["id"];
                parsed=rpc(client,"agent_extract_resume",{"id":resume_id});
                assert rpc(client,"resume_save_details",{"id":resume_id,"revision":parsed["revision"],"values":{f["key"]:f["value"] for section in parsed["sections"] for f in section["fields"]},"confirm":True})["confirmed"];
                assert rpc(client,"use_resume_template",{"id":resume_id,"template":"jake"})["resumes"][0]["format"]["kind"]=="builtin";

                # Application: inspect, fit and tailor run; the fill waits for review.
                run=rpc(client,"agent_start",{"kind":"application","target_id":application["id"]});
                assert run["title"]=="Prepare & apply" and "Review Test Co" in run["context_label"] and run["step_total"]==6;
                claim=work(client,"agent_claim");assert claim["step"]=="inspect", claim;
                fields=[{"label":"Email","type":"email","tag":"input","key":"email","required":True,"name":"email","id":"email","options":[],"value":""},{"label":"Resume/CV","type":"file","tag":"input","key":"answer:resume","required":True,"name":"resume","id":"resume","options":[],"value":""}];
                finish(client,claim,{"artifact":{"adapter":"lever","fields":fields,"schema_hash":"schema"}});
                claim=work(client,"agent_claim");assert claim["step"]=="fit", claim;finish(client,claim,{"artifact":{"summary":"Fit","strengths":[],"gaps":[],"unknowns":[],"evidence":[]}});
                change={"id":"s1.e0.b0","kind":"rewrite","where":"Experience","before":"Built a tool.","after":"Built an analysis tool.","reason":"Role focus"};
                claim=work(client,"agent_claim");assert claim["step"]=="tailor", claim;finish(client,claim,{"artifact":{"summary":"Tailored","changes":[change],"rejected":[],"dropped":[],"plan":{},"source_digest":"d","evidence":[],"pdf":{"name":"Tailored resume.pdf","content":"JVBERi0=","pages":1,"diff":"+ Analyst"}}});
                # Resume changes are reviewed before anything uses them; approving shares nothing.
                assert work(client,"agent_claim").get("idle");
                client.set_auth_token(a);pending=rpc(client,"agent_run",{"id":run["id"]});
                assert pending["status"]=="review" and pending["review"]["step"]=="approve_resume" and pending["review"]["changes"]==[change], pending;
                assert "error" in rpc(client,"agent_approve",{"id":run["id"],"step":"approve_resume","review_hash":pending["review"]["hash"],"edits":{"rejected":["unknown"]}});
                approved=rpc(client,"agent_approve",{"id":run["id"],"step":"approve_resume","review_hash":pending["review"]["hash"],"edits":{"rejected":["s1.e0.b0"]}});
                assert approved["status"]=="queued" and approved["artifacts"]["tailor"]["rejected"]==["s1.e0.b0"], approved;
                claim=work(client,"agent_claim");assert claim["step"]=="approve_resume", claim;
                finish(client,claim,{"artifact":{"summary":"Applied 0 of 1 changes.","tailor":{"final":True,"pdf":{"name":"Tailored resume.pdf","content":"JVBERi0x","pages":1,"diff":""}}}});
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
                assert pending["status"]=="review" and pending["review"]["step"]=="submit" and pending["step_number"]==6;
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

test "tailoring refuses a PDF-only resume, then tailors a chosen built-in template and persists a preview" {
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
                # A PDF alone is never tailored: no task is created and no model request is reserved.
                assert "Upload the LaTeX for Candidate.pdf" in rpc(client,"agent_start",{"kind":"resume","target_id":application["id"]}).get("error","");
                assert rpc(client,"agent_activity")["runs"]==[] and not [a for a in rpc(client,"bootstrap")["applications"] if a["id"]==application["id"]][0]["tailor"]["ready"];
                review=rpc(client,"agent_extract_resume",{"id":resume_id});
                values={f["key"]:f["value"] for section in review["sections"] for f in section["fields"]};
                assert not review["confirmed"];
                confirmed=rpc(client,"resume_save_details",{"id":resume_id,"revision":review["revision"],"values":values,"confirm":True});assert confirmed["confirmed"];
                # Confirmed details alone are still not LaTeX; choosing Jake's template makes them LaTeX.
                assert "error" in rpc(client,"agent_start",{"kind":"resume","target_id":application["id"]});
                rpc(client,"use_resume_template",{"id":resume_id,"template":"jake"});
                run=rpc(client,"agent_start",{"kind":"resume","target_id":application["id"]});
                claim=work(client,"agent_claim");assert claim["id"]==run["id"] and claim["step"]=="tailor";
                # Stack fills the chosen Jake's template from the confirmed details and edits that LaTeX.
                with patch("agents.provider.generate",side_effect=propose) {
                    with patch.dict(dispatch.__globals__,{"call":partial(worker_call,client)}) { result=dispatch(claim,WORKER) as dict[str, any]; }
                }
                assert "artifact" in result, result;
                proposal=result["artifact"];pdf=proposal["pdf"];
                assert base64.b64decode(pdf["content"]).startswith(b"%PDF-") and pdf["pages"]==1 and pdf["checks"]["fits"], pdf["pages"];
                assert proposal["format"]=="builtin" and not proposal["final"] and "\\resumeItem{Rewritten:" in proposal["tex"];
                # Scored before and after for this job, without a model.
                assert proposal["score"]["before"]["match"] is not None and proposal["score"]["after"]["quality"] is not None, proposal["score"];
                assert [c["kind"] for c in proposal["changes"]]==["rewrite"] and "Rewritten:" in pdf["text"] and "Rewritten:" not in pdf["original_text"];
                finish(client,claim,result);assert work(client,"agent_claim").get("idle");client.set_auth_token(token);
                pending=rpc(client,"agent_run",{"id":run["id"]});
                assert pending["status"]=="review" and pending["review"]["step"]=="approve_resume" and pending["subscription_calls"]==1, pending;
                change=pending["review"]["changes"][0]["id"];
                rpc(client,"agent_approve",{"id":run["id"],"step":"approve_resume","review_hash":pending["review"]["hash"],"edits":{"rejected":[change]}});
                claim=work(client,"agent_claim");assert claim["step"]=="approve_resume", claim;
                with patch.dict(dispatch.__globals__,{"call":partial(worker_call,client)}) { result=dispatch(claim,WORKER) as dict[str, any]; }
                assert result["artifact"]["summary"]=="Applied 0 of 1 changes.", result;
                finish(client,claim,result);client.set_auth_token(token);
                done=rpc(client,"agent_run",{"id":run["id"]});final=done["artifacts"]["tailor"];
                assert done["status"]=="completed" and done["subscription_calls"]==1, done;
                assert final["final"] and final["pdf"]["pages"]==1;
                assert "Rewritten:" not in final["pdf"]["text"] and "Rewritten:" not in final["tex"] and final["changes"][0]["id"]==change;
                client.reload();client.set_auth_token(token);
                assert rpc(client,"agent_run",{"id":run["id"]})["artifacts"]["tailor"]["pdf"]["content"]==final["pdf"]["content"];
                # The approved resume is saved apart from uploads, labelled with its job, and read back by the parser.
                state=rpc(client,"bootstrap");saved=state["tailored_resumes"];
                assert [r["id"] for r in state["resumes"]]==[resume_id] and len(saved)==1, saved;
                assert saved[0]["run_id"]==run["id"] and saved[0]["company"]=="Review Test Co" and "Analyst" in saved[0]["job_title"] and saved[0]["source_name"]=="Candidate.pdf", saved;
                assert saved[0]["parse"]["ok"] and saved[0]["parse"]["total"]>=5, saved[0]["parse"];
                assert saved[0]["score"]["before"]==proposal["score"]["before"] and saved[0]["score"]["after"]["match"] is not None, saved[0]["score"];
                opened=rpc(client,"read_tailored_resume",{"id":saved[0]["id"]});
                assert base64.b64decode(opened["pdf"]["content"])==base64.b64decode(final["pdf"]["content"]) and opened["pdf"]["name"].startswith("Resume - Review Test Co") and "\\documentclass" in opened["tex"];
                assert rpc(client,"check_tailored_resume",{"id":saved[0]["id"]})["tailored_resumes"][0]["parse"]["ok"];
                other=client.register_user("tailored-other","Tailored-test-password-2");client.set_auth_token(other.data["token"]);
                assert "error" in rpc(client,"read_tailored_resume",{"id":saved[0]["id"]}) and "error" in rpc(client,"delete_tailored_resume",{"id":saved[0]["id"]});
                client.set_auth_token(token);
                assert rpc(client,"delete_tailored_resume",{"id":saved[0]["id"]})["tailored_resumes"]==[] and len(rpc(client,"bootstrap")["resumes"])==1;
            } finally {
                if resume_id { client.set_auth_token(token);rpc(client,"change_resume",{"id":resume_id,"action":"delete"}); }
                client.close();
            }
        }
    }
}

test "an uploaded LaTeX source is checked, compiled, and tailored without confirmed details" {
    with tempfile.TemporaryDirectory(prefix="stack-latex-test-") as directory {
        path=Path(directory)/"agents.json";path.write_text(json.dumps({}));
        discovery=Path("storage/discovery/worker-token").read_text().strip();
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":WORKER}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);resume_id="";
            try {
                signed=client.register_user("latex-owner","Latex-test-password-1");assert signed.ok,signed.text;
                token=signed.data["token"];owner=rpc(client,"bootstrap")["user_id"];
                path.write_text(json.dumps({"provider":"codex-cli","local_cli_owner":owner,"local_cli_daily_limit":20}));
                rpc(client,"agent_save_policy",{"policy":{"enabled":True,"expires_at":time.time()+3600,"actions":["model"]}});
                # The job is saved before any resume exists, so it has no resume of its own.
                job=lever_job(client,token,discovery);client.set_auth_token(token);
                application=rpc(client,"swipe",{"job_id":job,"action":"apply"})["applications"][0];assert application["resume_id"]=="";
                assert "Upload your resume" in rpc(client,"agent_start",{"kind":"resume","target_id":application["id"]}).get("error","");
                uploaded=rpc(client,"upload_resume",{"name":"Candidate.pdf","content":base64.b64encode(Path("tests/fixtures/openresume-laverne.pdf").read_bytes()).decode()});
                resume_id=uploaded["resumes"][0]["id"];
                assert uploaded["resumes"][0]["format"]["label"]=="No LaTeX yet";
                # The job now uses the default resume, but it is only a PDF: tailoring is refused and readiness says why.
                assert "Upload the LaTeX for Candidate.pdf" in rpc(client,"agent_start",{"kind":"resume","target_id":application["id"]}).get("error","");
                assert rpc(client,"agent_activity")["runs"]==[];
                # A PDF-only resume can still be scored for the job, from what the parser reads.
                pdf_score=rpc(client,"score_resume",{"application_id":application["id"]});
                assert pdf_score.get("source")=="pdf" and pdf_score["resume_name"]=="Candidate.pdf" and pdf_score["score"]["quality"] is not None, pdf_score;
                readiness=[c for f in rpc(client,"agent_features")["features"] if f["key"]=="tailoring" for c in f["checks"] if c["key"]=="facts"][0];
                assert not readiness["ok"] and "Candidate.pdf" in readiness["fix"], readiness;
                # Built-in templates need confirmed details; unsafe or broken sources are refused.
                assert "Confirm your resume details" in rpc(client,"use_resume_template",{"id":resume_id,"template":"jake"}).get("error","");
                tex=Path("tests/fixtures/jake-resume.tex").read_text();
                unsafe=tex.replace("\\begin{document}","\\begin{document}\\immediate\\write18{ls}");
                assert "write18" in rpc(client,"upload_resume_source",{"id":resume_id,"name":"resume.tex","content":base64.b64encode(unsafe.encode()).decode()}).get("error","");
                broken=tex.replace("\\section{Projects}","\\section{Projects}\\undefinedmacro");
                assert "could not compile" in rpc(client,"upload_resume_source",{"id":resume_id,"name":"resume.tex","content":base64.b64encode(broken.encode()).decode()}).get("error","");
                state=rpc(client,"upload_resume_source",{"id":resume_id,"name":"resume.tex","content":base64.b64encode(tex.encode()).decode()});
                shown=state["resumes"][0]["format"];
                assert shown["kind"]=="upload" and shown["pages"]==1 and shown["summary"]["bullets"]==20 and shown["summary"]["sections"]==4, shown;
                source=rpc(client,"read_resume_source",{"id":resume_id});
                assert source["tex"]==tex and base64.b64decode(source["preview"]["content"]).startswith(b"%PDF-");
                exported=rpc(client,"account_export")["resumes"][0];
                assert exported["id"]==resume_id and exported["source"]["files"],exported;
                assert [c for f in rpc(client,"agent_features")["features"] if f["key"]=="tailoring" for c in f["checks"] if c["key"]=="facts"][0]["ok"];
                latex_score=rpc(client,"score_resume",{"application_id":application["id"]});
                assert latex_score["source"]=="latex" and latex_score["score"]["match"] is not None and latex_score["score"]["match_components"], latex_score;
                # The user's own LaTeX needs no parsed-details confirmation.
                run=rpc(client,"agent_start",{"kind":"resume","target_id":application["id"]});
                assert [a for a in rpc(client,"bootstrap")["applications"] if a["id"]==application["id"]][0]["resume_id"]==resume_id;
                claim=work(client,"agent_claim");assert claim["id"]==run["id"] and claim["step"]=="tailor", claim;
                with patch("agents.provider.generate",side_effect=propose) {
                    with patch.dict(dispatch.__globals__,{"call":partial(worker_call,client)}) { result=dispatch(claim,WORKER) as dict[str, any]; }
                }
                proposal=result["artifact"];
                assert proposal["format"]=="latex" and proposal["pdf"]["pages"]==1 and proposal["changes"][0]["kind"]=="rewrite", proposal["changes"];
                # Only content changed: the uploaded preamble is byte-for-byte the same.
                preamble=tex[:tex.index("\\begin{document}")];
                assert proposal["tex"].startswith(preamble) and "\\resumeItem{Rewritten: Developed a REST API" in proposal["tex"];
                finish(client,claim,result);assert work(client,"agent_claim").get("idle");client.set_auth_token(token);
                # Other accounts cannot read this source.
                other=client.register_user("latex-other","Latex-test-password-2");client.set_auth_token(other.data["token"]);
                assert "error" in rpc(client,"read_resume_source",{"id":resume_id}) and "error" in rpc(client,"upload_resume_source",{"id":resume_id,"name":"resume.tex","content":base64.b64encode(tex.encode()).decode()});
                assert "error" in rpc(client,"score_resume",{"application_id":application["id"]});
                client.set_auth_token(token);
                assert rpc(client,"agent_run",{"id":run["id"]})["review"]["step"]=="approve_resume";
                # LaTeX removed after a task started (as when preview data is replaced): the task pauses on the
                # LaTeX step, not a generic question, and continues once LaTeX is back.
                job2=lever_job(client,token,discovery);client.set_auth_token(token);
                app2=[a for a in rpc(client,"swipe",{"job_id":job2,"action":"apply"})["applications"] if a["job_id"]==job2][0];
                second=rpc(client,"agent_start",{"kind":"resume","target_id":app2["id"]});
                removed=rpc(client,"use_resume_template",{"id":resume_id,"template":""});
                assert removed["resumes"][0]["format"]["kind"]=="";
                claim=work(client,"agent_claim");assert claim["id"]==second["id"] and claim["step"]=="tailor", claim;
                with patch.dict(dispatch.__globals__,{"call":partial(worker_call,client)}) { result=dispatch(claim,WORKER) as dict[str, any]; }
                assert result.get("needs_input") and "Upload the LaTeX for Candidate.pdf" in result["message"], result;
                finish(client,claim,result);client.set_auth_token(token);
                paused=rpc(client,"agent_run",{"id":second["id"]});
                assert paused["status"]=="needs_input" and paused["needs_resume_review"], paused;
                assert "Upload the LaTeX" in rpc(client,"agent_continue_tailoring",{"id":second["id"]}).get("error","");
                rpc(client,"upload_resume_source",{"id":resume_id,"name":"resume.tex","content":base64.b64encode(tex.encode()).decode()});
                assert rpc(client,"agent_continue_tailoring",{"id":second["id"]})["status"]=="queued";
                claim=work(client,"agent_claim");assert claim["id"]==second["id"] and claim["step"]=="tailor", claim;
            } finally {
                if resume_id { client.set_auth_token(token);rpc(client,"change_resume",{"id":resume_id,"action":"delete"}); }
                client.close();
            }
        }
    }
}
