import json;
import os;
import time;
import tempfile;
import from pathlib { Path }
import from uuid { UUID }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }
import from jaclang.runtime.runtime { JacRuntime }
import core.automation as a;

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post("/function/"+name,json=args);
    assert response.status_code==200, response.text;
    return response.data["result"];
}

test "subscription claims are account bound capped and separate from API money" {
    with tempfile.TemporaryDirectory(prefix="stack-provider-test-") as directory {
        path=Path(directory)/"provider.json";
        path.write_text(json.dumps({}));
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":"provider-test-token"}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                first=client.register_user("provider-owner","Test-provider-password-123");assert first.ok,first.text;
                a=first.data["token"];owner=rpc(client,"agent_settings")["account_id"];
                second=client.register_user("provider-other","Test-provider-password-456");assert second.ok,second.text;
                b=second.data["token"];
                path.write_text(json.dumps({"provider":"codex-cli","local_cli_owner":str(UUID(owner)),"local_cli_daily_limit":1}));
                client.set_auth_token(a);
                assert rpc(client,"agent_settings")["activity"]["model_provider"]["configured"];
                runs=[];
                for token in [a,b] {
                    client.set_auth_token(token);
                    rpc(client,"agent_save_policy",{"policy":{"enabled":True,"expires_at":time.time()+3600,"actions":["model"]}});
                    session=rpc(client,"prep_create",{"problem_id":"project"});
                    run=rpc(client,"agent_start",{"kind":"prep","target_id":session["id"]});
                    runs.append(run["id"]);
                }
                client.clear_auth();claim=rpc(client,"agent_claim",{"token":"provider-test-token"});
                assert claim["owner"]==owner and claim["reservation_cents"]==0;
                rpc(client,"agent_finish",{"token":"provider-test-token","id":claim["id"],"owner":owner,"lease":claim["lease"],"result":{"artifact":{"summary":"Controlled result"}}});
                assert rpc(client,"agent_claim",{"token":"provider-test-token"}).get("idle");
                client.set_auth_token(b);other=rpc(client,"agent_run",{"id":runs[1]});
                assert other["status"]=="blocked" and other["subscription_calls"]==0;
                client.set_auth_token(a);done=rpc(client,"agent_run",{"id":runs[0]});
                assert done["status"]=="completed" and done["cost_cents"]==0 and done["subscription_calls"]==1;
                next_session=rpc(client,"prep_create",{"problem_id":"disagreement"});
                next_run=rpc(client,"agent_start",{"kind":"prep","target_id":next_session["id"]});
                client.clear_auth();assert rpc(client,"agent_claim",{"token":"provider-test-token"}).get("idle");
                client.set_auth_token(a);blocked=rpc(client,"agent_run",{"id":next_run["id"]});
                assert blocked["status"]=="blocked" and "daily request limit" in blocked["message"];
                assert blocked["cost_cents"]==0 and blocked["subscription_calls"]==0;
            } finally { client.close(); }
        }
    }
}

test "provider-aware task reuse preserves terminal and active selections" {
    for terminal_status in ["failed","completed"] {
        with tempfile.TemporaryDirectory(prefix="stack-provider-dedupe-") as directory {
            previous=JacRuntime.peek_context();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
            try {
                memory=a._agent_memory();memory.model_selection="codex-cli";commit();
                context={"profile":{"name":"Example"}};
                first=a._agent_start("profile","self",context);first_id=first["id"];
                first_node=a._owned_run(first_id) as a.AgentRun;first_node.status=terminal_status;
                # Existing stored runs still carry the pre-provider idempotency key.
                first_node.key=a.digest(["profile","self",first_node.context]);commit();
                same_provider=a._agent_start("profile","self",context);
                assert same_provider["id"]==first_id;

                memory.model_selection="local";commit();
                switched=a._agent_start("profile","self",context);
                assert switched["id"]!=first_id;
                assert switched["model_selection"]=="local";
                assert first_node.model_selection=="codex-cli" and first_node.status==terminal_status;
                assert a._agent_start("profile","self",context)["id"]==switched["id"];
            } finally {
                ctx.close();
                if previous is not None { JacRuntime.set_context(previous); }
            }
        }
    }

    with tempfile.TemporaryDirectory(prefix="stack-provider-active-") as directory {
        previous=JacRuntime.peek_context();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
        try {
            memory=a._agent_memory();memory.model_selection="codex-cli";commit();
            context={"profile":{"name":"Example"}};
            active=a._agent_start("profile","self",context);active_node=a._owned_run(active["id"]) as a.AgentRun;
            memory.model_selection="local";commit();
            newly_selected=a._agent_start("profile","self",context);
            assert newly_selected["id"]!=active["id"];
            assert active_node.model_selection=="codex-cli" and active_node.status=="queued";
            assert newly_selected["model_selection"]=="local";
        } finally {
            ctx.close();
            if previous is not None { JacRuntime.set_context(previous); }
        }
    }
}
