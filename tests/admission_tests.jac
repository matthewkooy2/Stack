"""Admission through real API/worker endpoints, isolated accounts, no external IO."""
import json;
import time;
import os;
import tempfile;
import from pathlib { Path }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }

glob WORKER = "synthetic-admission-worker";

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post("/function/"+name,json=args);
    assert response.status_code==200, response.text;
    return response.data["result"];
}
def work(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    client.clear_auth();return rpc(client,name,{"token":WORKER,**args});
}
def deny(client: any, name: str, args: dict[str, any] = {}) -> None {
    response=client.post("/function/"+name,json=args);
    assert response.status_code!=200 or response.data["result"].get("error"), response.text;
    assert "secret-marker" not in response.text;
}
def code_run(client: any) -> dict[str, any] {
    session=rpc(client,"prep_create",{"problem_id":"two-sum","language":"python"});
    return rpc(client,"agent_start",{"kind":"code","target_id":session["id"]});
}

test "closed defaults preserve invitations public opt in and worker ownership" {
    with tempfile.TemporaryDirectory(prefix="stack-admission-") as directory {
        path=Path(directory)/"private-marker.json";
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(path),"STACK_AGENT_WORKER_TOKEN":WORKER,"JAC_DB_RO_UNITS":"1"}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                first=client.register_user("admission-invited","Synthetic-password-1");assert first.ok,first.text;a=first.data["token"];
                second=client.register_user("admission-other","Synthetic-password-2");assert second.ok,second.text;b=second.data["token"];
                for settings in [None,{}, {"invite_only":True},{"invite_only":0},{"invite_only":"false"}] {
                    if settings is not None { path.write_text(json.dumps(settings)); }
                    for token in [a,b] {
                        client.set_auth_token(token);
                        assert rpc(client,"agent_admission")=={"admitted":False};
                        deny(client,"prep_create",{"problem_id":"two-sum"});
                    }
                }
                invite=work(client,"agent_invite")["invite"];
                deny(client,"agent_accept_invite",{"invite":invite});
                client.set_auth_token(a);accepted=rpc(client,"agent_accept_invite",{"invite":invite});assert accepted.get("admitted"),accepted;
                client.set_auth_token(b);assert "error" in rpc(client,"agent_accept_invite",{"invite":invite});
                client.set_auth_token(b);
                assert "error" in rpc(client,"agent_accept_invite",{"invite":"invalid-synthetic-token"});
                assert not rpc(client,"agent_admission")["admitted"];
                path.unlink();
                client.set_auth_token(a);assert rpc(client,"agent_admission")["admitted"];
                assert rpc(client,"agent_settings")["activity"]["admitted"];
                client.set_auth_token(b);assert not rpc(client,"agent_admission")["admitted"];

                # Explicit public access permits either account, never cross-account resources.
                path.write_text('{"invite_only":false}');
                client.set_auth_token(a);owned=code_run(client);
                client.set_auth_token(b);assert rpc(client,"agent_admission")["admitted"];
                assert "error" in rpc(client,"agent_run",{"id":owned["id"]});
                other=code_run(client);
                saved=rpc(client,"agent_save_policy",{"policy":{"enabled":True,"expires_at":time.time()+3600,"actions":["model"],"analyze_top_matches":True}});
                assert saved["policy"]["enabled"] and saved["policy"]["analyze_top_matches"];
                path.unlink();
                app=client.server.module;
                with patch.object(app,"search_jobs",return_value={"jobs":[{"id":"synthetic-job"}]}),
                     patch.object(app,"_catalog_job",return_value={"id":"synthetic-job"}) {
                    assert work(client,"agent_schedule")=={"scheduled":0};
                }
                claim=work(client,"agent_claim");assert claim["id"]==owned["id"],claim;
                assert "error" in work(client,"agent_worker_resume_source",{"id":claim["id"],"owner":claim["owner"],"lease":"wrong"});
                done=work(client,"agent_finish",{**{k:claim[k] for k in ["id","owner","lease"]},"result":{"artifact":{"passed":1,"total":1}}});
                assert done["status"]=="completed",done;
                assert work(client,"agent_claim").get("idle");
                path.write_text('{"invite_only":false}');client.set_auth_token(b);
                blocked=rpc(client,"agent_run",{"id":other["id"]});
                assert blocked["status"]=="blocked" and "invitation" in blocked["message"],blocked;

                # Removing admission while a lease is active blocks worker reads and writes.
                running=code_run(client);claim=work(client,"agent_claim");assert claim["id"]==running["id"],claim;
                args={k:claim[k] for k in ["id","owner","lease"]};
                path.unlink();
                for (name,extra) in [
                    ("agent_worker_resume_source",{}),
                    ("agent_authorize",{"payload_hash":"synthetic"}),
                    ("agent_worker_connection",{}),
                    ("agent_finish",{"result":{"artifact":{"passed":1,"total":1}}})
                ] {
                    denied=work(client,name,{**args,**extra});
                    assert "invitation" in denied.get("error",""), {"endpoint":name,"result":denied};
                }
                # Recovery after a legitimate invitation retains the same owned lease.
                invite=work(client,"agent_invite")["invite"];client.set_auth_token(b);
                assert rpc(client,"agent_accept_invite",{"invite":invite})["admitted"];
                done=work(client,"agent_finish",{**args,"result":{"artifact":{"passed":1,"total":1}}});
                assert done["status"]=="completed",done;

                # Invalid config returns a safe denial and blocks queued worker work.
                for text in ['{"secret-marker":', '[]', '{"invite_only":false,"monthly_cents":"secret-marker"}'] {
                    path.write_text('{}');client.set_auth_token(a);queued=code_run(client);
                    path.write_text(text);
                    assert not rpc(client,"agent_admission")["admitted"];
                    deny(client,"agent_settings");
                    assert work(client,"agent_claim").get("idle");
                    path.write_text('{}');client.set_auth_token(a);
                    failed=rpc(client,"agent_run",{"id":queued["id"]});
                    assert failed["status"]=="blocked" and "Check STACK_AGENT_CONFIG" in failed["message"];
                    assert "secret-marker" not in failed["message"] and str(path) not in failed["message"];
                    rpc(client,"agent_cancel",{"id":queued["id"]});
                }
                # Public admission and a valid invite do not revive deleted accounts.
                last_invite=work(client,"agent_invite")["invite"];client.set_auth_token(a);
                deleted=rpc(client,"account_delete",{"username":"admission-invited","password":"Synthetic-password-1"});
                assert deleted["deleted"];path.write_text('{"invite_only":false}');
                response=client.post("/function/agent_admission",json={});
                assert response.status_code!=200 or not response.data["result"].get("admitted");
                deny(client,"agent_accept_invite",{"invite":last_invite});
            } finally { client.close(); }
        }
    }
}
