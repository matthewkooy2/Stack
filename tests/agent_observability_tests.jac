import json;
import os;
import tempfile;
import time;
import from pathlib { Path }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }
import from agents { provider, local_cli, worker }
import from agents.tracing { trace_data }

def rpc(client: JacTestClient, name: str, args: dict[str, any] | None = None) -> dict[str, any] {
    response=client.post("/function/"+name,json=args if args is not None else {});
    assert response.ok,response.text;
    return response.data["result"];
}

test "traces and feedback are persistent private and bound to reviewed output" {
    with tempfile.TemporaryDirectory(prefix="stack-traces-") as directory {
        path=Path(directory)/"config.json";path.write_text("{}");
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":"trace-test-worker"}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                registered=client.register_user("trace-owner","Trace-password-123");assert registered.ok;
                token=registered.data["token"];owner=rpc(client,"agent_settings")["account_id"];
                path.write_text(json.dumps({"provider":"codex-cli","local_cli_owner":owner,"local_cli_daily_limit":10,"capture_agent_content":True}));
                rpc(client,"agent_save_policy",{"policy":{"enabled":True,"expires_at":time.time()+3600,"actions":["model"]}});
                session=rpc(client,"prep_create",{"problem_id":"project"});
                session=rpc(client,"prep_save",{"id":session["id"],"revision":session["revision"],"data":{**session["data"],"answer":"Synthetic project answer"}});
                run=rpc(client,"agent_start",{"kind":"prep","target_id":session["id"]});
                client.clear_auth();work=rpc(client,"agent_claim",{"token":"trace-test-worker"});
                auth={"token":"trace-test-worker","id":run["id"],"owner":owner,"lease":work["lease"]};
                assert "error" in rpc(client,"agent_trace",{**auth,"token":"wrong","event":"model_request","data":{}});
                assert "error" in rpc(client,"agent_trace",{**auth,"lease":"wrong","event":"model_request","data":{}});
                def observe(event: str, data: dict[str, any]) -> None {
                    result=rpc(client,"agent_trace",{**auth,"event":event,"data":trace_data(data)});
                    assert result.get("saved"),result;
                }
                artifact={"summary":"Specific ownership; add a tradeoff.","rubric":[{"criterion":"Structure","score":3,"feedback":"Clear."}],"next_exercises":[],"followup_questions":[],"evidence":[]};
                def fake_cli(name: str, model: str, system: str, prompt: str, schema: dict[str, any], observe: any = None) -> dict[str, any] {
                    assert "Synthetic project answer" in prompt;
                    observe("model_response",{"text":json.dumps(artifact),"exit_code":0});
                    return artifact;
                }
                with patch.object(local_cli,"generate",side_effect=fake_cli) {
                    result=worker.dispatch(work,"trace-test-worker",observe=observe);
                }
                done=rpc(client,"agent_finish",{**auth,"result":result});assert done["status"]=="completed",done;
                assert "error" in rpc(client,"agent_trace",{**auth,"event":"model_response","data":{}});
                client.set_auth_token(token);
                events=rpc(client,"agent_traces",{"id":run["id"]})["events"];
                assert [e["event"] for e in events]==["stage_start","model_request","model_response","model_validation","stage_end"],events;
                assert len({e["attempt"] for e in events})==1;
                assert events[0]["data"]["context"]["session"]["answer"]=="Synthetic project answer";
                assert events[-1]["data"]["duration_ms"]>=0 and events[-2]["data"]["valid"];
                assert "trace-test-worker" not in json.dumps(events) and work["lease"] not in json.dumps(events);
                feedback={"id":run["id"],"output_version":done["output_version"],"rating":"mixed","note":"Useful, but too generic."};
                saved=rpc(client,"agent_feedback",feedback);assert len(saved["feedback"])==1,saved;
                assert len(rpc(client,"agent_feedback",feedback)["feedback"])==1;
                for bad in [{"rating":"invalid"},{"note":" "},{"note":"x"*4001},{"output_version":"stale"}] {
                    assert "error" in rpc(client,"agent_feedback",{**feedback,**bad});
                }
                client.reload();client.set_auth_token(token);
                assert rpc(client,"agent_run",{"id":run["id"]})["feedback"][0]["note"]==feedback["note"];
                assert len(rpc(client,"agent_traces",{"id":run["id"]})["events"])==5;
                assert rpc(client,"prep_get",{"id":session["id"]})["feedback"][0]["run_id"]==run["id"];
                exported=rpc(client,"agent_export");assert exported["feedback"][0]["snapshot"]["artifacts"]["coach"]==artifact;
                other=client.register_user("trace-other","Trace-password-456");assert other.ok;
                assert "error" in rpc(client,"agent_run",{"id":run["id"]});
                assert "error" in rpc(client,"agent_traces",{"id":run["id"]});
                assert "error" in rpc(client,"agent_feedback",feedback);
                client.clear_auth();assert client.post("/function/agent_traces",json={"id":run["id"]}).status_code==401;
                client.set_auth_token(token);
                # Capture is deployment opt-in; metadata remains useful without prompts.
                path.write_text(json.dumps({"provider":"codex-cli","local_cli_owner":owner,"local_cli_daily_limit":10}));
                next_session=rpc(client,"prep_create",{"problem_id":"disagreement"});
                next_run=rpc(client,"agent_start",{"kind":"prep","target_id":next_session["id"]});
                client.clear_auth();next_work=rpc(client,"agent_claim",{"token":"trace-test-worker"});
                next_auth={**auth,"id":next_run["id"],"lease":next_work["lease"]};
                rpc(client,"agent_trace",{**next_auth,"event":"model_request","data":{"provider":"codex-cli","input":"do not store"}});
                paused=rpc(client,"agent_finish",{**next_auth,"result":{"needs_input":True,"message":"Subscription unavailable"}});assert paused.get("status")=="needs_input",paused;
                client.set_auth_token(token);next_events=rpc(client,"agent_traces",{"id":next_run["id"]})["events"];
                assert "do not store" not in json.dumps(next_events);
                assert next_events[-1]["data"].get("outcome")=="needs_input",next_events;
                assert rpc(client,"agent_run",{"id":next_run["id"]})["status"]=="needs_input";
            } finally { client.close(); }
        }
    }
}

test "trace redaction and size limits preserve nonsecret diagnostic content" {
    with patch.dict(os.environ,{"MODEL_API_KEY":"synthetic-secret-key"}) {
        data=trace_data({"password":"hidden","nested":{"Authorization":"Bearer hidden"},"text":"synthetic-secret-key Bearer abc.def sk-abcdefghijklmnop", "raw":json.dumps({"refresh_token":"hidden","summary":"Keep this"}),"pdf":{"name":"Resume.pdf","content":"binary"}});
        text=json.dumps(data);assert "synthetic-secret-key" not in text and "hidden" not in text and "abc.def" not in text and "sk-abcdefghijklmnop" not in text;
        assert "Keep this" in text and data["pdf"]["content"]=="[binary omitted]";
        assert trace_data({"text":"x"*300000})["truncated"];
    }
}

test "invalid provider output is traced before source validation rejects it" {
    events=[];
    def observe(event: str, data: dict[str, any]) -> None { events.append({"event":event,"data":data}); }
    response={"status":"completed","model":"test-model","output":[{"content":[{"type":"output_text","text":json.dumps({"summary":"Bad","evidence":[{"source":"listing","quote":"invented","claim":"wrong"}]})}]}]};
    with patch.dict(os.environ,{"OPENAI_API_KEY":"synthetic-key"}), patch.object(provider,"http",return_value=response) {
        with testraises(ValueError, `match="validated") { provider.generate("fit",{}, {"provider":"openai","model":"test-model","max_output_tokens":256},observe=observe); }
    }
    assert [e["event"] for e in events]==["model_request","model_response","model_validation"];
    assert events[1]["data"]["response"]==response and events[2]["data"]["valid"] is False;
}
