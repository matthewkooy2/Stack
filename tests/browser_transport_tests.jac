"""Exercise the prepared API's real browser transport without importing or mocking agents.worker."""
import json;
import os;
import time;
import tempfile;
import from io { BytesIO }
import from pathlib { Path }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post("/function/"+name,json=args);
    assert response.status_code==200,response.text;
    return response.data["result"];
}
test "cold API imports the browser transport and sends owner-scoped requests" {
    with tempfile.TemporaryDirectory(prefix="stack-browser-transport-") as directory {
        config=Path(directory)/"agents.json";config.write_text("{}");
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(config),"STACK_BROWSER_URL":"http://browser.invalid","STACK_BROWSER_TOKEN":"synthetic-browser-token"}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                token=client.register_user("browser-owner","Test-only-password-1").data["token"];
                client.set_auth_token(token);owner=rpc(client,"bootstrap")["user_id"];
                config.write_text(json.dumps({"provider":"codex-cli","local_cli_owner":owner,"local_cli_daily_limit":10}));
                rpc(client,"agent_save_policy",{"policy":{"enabled":True,"expires_at":time.time()+3600,"actions":["model"]}});
                run=rpc(client,"agent_linkedin_start",{"url":"https://www.linkedin.com/in/test-profile/"});
                with patch("urllib.request.urlopen",return_value=BytesIO(b'{"image":"fixture-frame"}')) as transport {
                    frame=rpc(client,"agent_browser",{"id":run["id"],"event":{"type":"snapshot"}});
                    assert frame.get("image")=="fixture-frame",frame;
                    request=transport.call_args[0][0];
                    assert request.full_url=="http://browser.invalid/frame";
                    payload=json.loads(request.data);
                    assert payload["owner"]==owner and payload["id"]==run["id"];
                }
            } finally { client.close(); }
        }
    }
}
