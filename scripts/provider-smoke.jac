"""Opt-in live subscription check; uses synthetic data and an isolated account store."""
import argparse;
import json;
import os;
import tempfile;
import time;
import from pathlib { Path }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }
import from agents.worker { dispatch }

def rpc(client: JacTestClient, name: str, args: dict[str, any] | None = None) -> dict[str, any] {
    response = client.post("/function/" + name, json=args if args is not None else {});
    assert response.ok, response.text;
    result = response.data["result"];
    assert not result.get("error"), result;
    return result;
}

with entry:__main__ {
    parser = argparse.ArgumentParser(description="Makes one real subscription request; no paid API fallback.");
    parser.add_argument("provider", choices=["codex-cli", "claude-cli"]);
    args = parser.parse_args();
    with tempfile.TemporaryDirectory(prefix="stack-live-coaching-") as directory {
        path = Path(directory) / "provider.json";
        path.write_text(json.dumps({}));
        with patch.dict(os.environ, {"STACK_AGENT_CONFIG": str(path), "STACK_AGENT_WORKER_TOKEN": "isolated-smoke-worker"}) {
            client = JacTestClient.from_file(str(Path("main.jac").resolve()), base_path=directory);
            try {
                registered = client.register_user("coaching-smoke", "Synthetic-smoke-password-123");
                assert registered.ok, registered.text;
                token = registered.data["token"];
                owner = rpc(client, "agent_settings")["account_id"];
                path.write_text(json.dumps({"provider": args.provider, "local_cli_owner": owner, "local_cli_daily_limit": 1}));
                rpc(client, "agent_save_policy", {"policy": {"enabled": True, "expires_at": time.time() + 3600, "actions": ["model"]}});
                session = rpc(client, "prep_create", {"problem_id": "project"});
                data = session["data"];
                data["answer"] = "In a class project, our team was missing deadlines. I made a task list, asked each teammate to own one task, and scheduled a short weekly check-in. We delivered the project on time. Next time I would agree on responsibilities at kickoff.";
                session = rpc(client, "prep_save", {"id": session["id"], "revision": session["revision"], "data": data});
                run = rpc(client, "agent_start", {"kind": "prep", "target_id": session["id"]});
                client.clear_auth();
                work = rpc(client, "agent_claim", {"token": "isolated-smoke-worker"});
                assert work.get("id") == run["id"], work;
                print("Requesting live coaching through " + args.provider, flush=True);
                result = dispatch(work, "isolated-smoke-worker");
                assert result.get("artifact", {}).get("rubric"), result;
                rpc(client, "agent_finish", {"token": "isolated-smoke-worker", "id": work["id"], "owner": owner, "lease": work["lease"], "result": result});
                client.set_auth_token(token);
                done = rpc(client, "agent_run", {"id": run["id"]});
                assert done["status"] == "completed", done;
                assert done["cost_cents"] == 0 and done["subscription_calls"] == 1, done;
                client.reload();
                client.set_auth_token(token);
                saved = rpc(client, "prep_get", {"id": session["id"]});
                assert len(saved["feedback"]) == 1, saved;
                feedback = saved["feedback"][0];
                assert feedback["revision"] == session["revision"], feedback;
                assert feedback["data"] == result["artifact"], feedback;
                print(json.dumps({"provider": args.provider, "status": done["status"], "subscription_calls": done["subscription_calls"], "api_cost_cents": done["cost_cents"], "persisted_after_reload": True, "summary": feedback["data"]["summary"]}, indent=2));
            } finally { client.close(); }
        }
    }
}
