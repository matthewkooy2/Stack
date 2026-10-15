import json;
import os;
import tempfile;
import from pathlib { Path }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post("/function/"+name,json=args);
    assert response.status_code==200, response.text;
    return response.data["result"];
}

test "subscription claims need neither account binding permission nor stack caps" {
    with tempfile.TemporaryDirectory(prefix="stack-provider-test-") as directory {
        path=Path(directory)/"provider.json";
        path.write_text(json.dumps({}));
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":"provider-test-token"}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                first=client.register_user("provider-owner","Test-provider-password-123");assert first.ok,first.text;
                a=first.data["token"];
                second=client.register_user("provider-other","Test-provider-password-456");assert second.ok,second.text;
                b=second.data["token"];
                path.write_text(json.dumps({"provider":"codex-cli"}));
                runs={};
                for token in [a,b] {
                    client.set_auth_token(token);
                    owner=rpc(client,"agent_settings")["account_id"];
                    assert rpc(client,"agent_settings")["activity"]["model_provider"]["configured"];
                    session=rpc(client,"prep_create",{"problem_id":"project"});
                    run=rpc(client,"agent_start",{"kind":"prep","target_id":session["id"]});
                    runs[owner]={"token":token,"id":run["id"]};
                }
                client.clear_auth();
                for ignored in [0,1] {
                    claim=rpc(client,"agent_claim",{"token":"provider-test-token"});
                    assert claim["owner"] in runs and claim["reservation_cents"]==0;
                    rpc(client,"agent_finish",{"token":"provider-test-token","id":claim["id"],"owner":claim["owner"],"lease":claim["lease"],"result":{"artifact":{"summary":"Controlled result"}}});
                }
                for (owner,item) in runs.items() {
                    client.set_auth_token(item["token"]);done=rpc(client,"agent_run",{"id":item["id"]});
                    assert done["status"]=="completed" and done["cost_cents"]==0 and done["subscription_calls"]==0;
                }
                client.set_auth_token(a);
                next_session=rpc(client,"prep_create",{"problem_id":"disagreement"});
                rpc(client,"agent_start",{"kind":"prep","target_id":next_session["id"]});
                client.clear_auth();assert not rpc(client,"agent_claim",{"token":"provider-test-token"}).get("idle");
            } finally { client.close(); }
        }
    }
}

test "provider-aware task reuse preserves terminal and active selections" {
    with tempfile.TemporaryDirectory(prefix="stack-provider-dedupe-") as directory {
        path=Path(directory)/"provider.json";path.write_text(json.dumps({}));
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":"dedupe-test-worker"}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                created=client.register_user("dedupe-owner","Test-dedupe-password-123");assert created.ok,created.text;
                token=created.data["token"];client.set_auth_token(token);
                path.write_text(json.dumps({"provider":"codex-cli","model_options":{"local":{"provider":"ollama","model":"test-only","local_model_url":"http://127.0.0.1:11434"}}}));

                rpc(client,"agent_save_model",{"selection":"codex-cli"});
                completed=rpc(client,"agent_start",{"kind":"profile","target_id":"self"});
                assert rpc(client,"agent_start",{"kind":"profile","target_id":"self"})["id"]==completed["id"];
                client.clear_auth();claimed=rpc(client,"agent_claim",{"token":"dedupe-test-worker"});
                assert claimed["id"]==completed["id"] and claimed["model_selection"]=="codex-cli";
                rpc(client,"agent_finish",{"token":"dedupe-test-worker","id":claimed["id"],"owner":claimed["owner"],"lease":claimed["lease"],"result":{"artifact":{"summary":"Synthetic completion"}}});
                client.set_auth_token(token);
                assert rpc(client,"agent_start",{"kind":"profile","target_id":"self"})["id"]==completed["id"];

                rpc(client,"agent_save_model",{"selection":"local"});
                active=rpc(client,"agent_start",{"kind":"profile","target_id":"self"});
                assert active["id"]!=completed["id"];
                assert rpc(client,"agent_start",{"kind":"profile","target_id":"self"})["id"]==active["id"];
                client.clear_auth();local_claim=rpc(client,"agent_claim",{"token":"dedupe-test-worker"});
                assert local_claim["id"]==active["id"] and local_claim["model_selection"]=="local";

                client.set_auth_token(token);
                session=rpc(client,"prep_create",{"problem_id":"project"});
                rpc(client,"agent_save_model",{"selection":"codex-cli"});
                switched=rpc(client,"agent_start",{"kind":"prep","target_id":session["id"]});
                assert switched["id"]!=active["id"];
                client.clear_auth();new_claim=rpc(client,"agent_claim",{"token":"dedupe-test-worker"});
                assert new_claim["id"]==switched["id"] and new_claim["model_selection"]=="codex-cli";
            } finally { client.close(); }
        }
    }
}
