"""Authenticated browser control and grants; mock only private HTTP, never real sites."""
import json;
import os;
import time;
import tempfile;
import from io { BytesIO }
import from pathlib { Path }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }
import from agents.browser_control { BrowserControl }

def _rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post("/function/"+name,json=args);
    assert response.status_code==200,response.text;return response.data["result"];
}
test "browser authority is owner scoped, explicit, ordered and resumable" {
    with tempfile.TemporaryDirectory(prefix="browser-viewer-fixture-") as directory {
        config=Path(directory)/"config.json";config.write_text("{}");authority=BrowserControl();
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(config),"STACK_BROWSER_URL":"http://browser.invalid","STACK_BROWSER_TOKEN":"synthetic-private-worker-token"}) {
            client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
            try {
                token=client.register_user("viewer-owner","Synthetic-password-1").data["token"];client.set_auth_token(token);
                owner=_rpc(client,"bootstrap")["user_id"];
                config.write_text(json.dumps({"provider":"codex-cli","local_cli_owner":owner,"local_cli_daily_limit":10}));
                _rpc(client,"agent_save_policy",{"policy":{"enabled":True,"expires_at":time.time()+3600,"actions":["model"]}});
                run=_rpc(client,"agent_linkedin_start",{"url":"https://www.linkedin.com/in/synthetic-profile/"});key=(owner,run["id"]);controller="viewer-synthetic-owner";
                def transport(request: any, **kwargs: any) -> any {
                    body=json.loads(request.data);assert body["owner"]==owner;
                    if request.full_url.endswith("/control") {
                        result=authority.transition(key,body["action"],body.get("generation",-1),body.get("controller",""),body.get("instance"));
                    } elif request.full_url.endswith("/subscribe") { result={"ticket":authority.grant(key)}; }
                    else {
                        try { authority.begin(key,body["event"]);authority.end(key);result={"image":"synthetic-frame"}; }
                        except ValueError as e { result={"error":str(e)}; }
                    }
                    return BytesIO(json.dumps(result).encode());
                }
                with patch("urllib.request.urlopen",side_effect=transport) {
                    denied=_rpc(client,"agent_browser",{"id":run["id"],"event":{"type":"text","text":"synthetic"}});assert "error" in denied;
                    grant=_rpc(client,"agent_browser_subscribe",{"id":run["id"]});assert grant["url"]=="http://browser.invalid/stream";
                    assert authority.consume(grant["ticket"])==key;
                    took=_rpc(client,"agent_browser_control",{"id":run["id"],"action":"take","generation":0,"instance":authority.instance,"controller":controller});assert took["status"]=="paused",took;
                    assert took["control"]["mode"]=="user";
                    event={"type":"text","text":"synthetic input","generation":1,"instance":authority.instance,"controller":controller,"sequence":1};
                    assert _rpc(client,"agent_browser",{"id":run["id"],"event":event})["image"]=="synthetic-frame";
                    assert "error" in _rpc(client,"agent_browser",{"id":run["id"],"event":event});
                    resumed=_rpc(client,"agent_browser_control",{"id":run["id"],"action":"resume","generation":1,"instance":authority.instance,"controller":controller});assert resumed["status"]=="queued",resumed;
                    assert resumed["control"]["generation"]==2;
                    other=client.register_user("viewer-other","Synthetic-password-2").data["token"];client.set_auth_token(other);
                    assert "error" in _rpc(client,"agent_browser_subscribe",{"id":run["id"]});
                    assert "error" in _rpc(client,"agent_browser_control",{"id":run["id"],"action":"stop"});
                    client.set_auth_token(token);
                    stopped=_rpc(client,"agent_browser_control",{"id":run["id"],"action":"stop"});assert stopped["status"]=="cancelled",stopped;
                    assert "error" in _rpc(client,"agent_browser_subscribe",{"id":run["id"]});
                    assert "synthetic-private-worker-token" not in json.dumps([grant,took,resumed,stopped]);
                }
            } finally { client.close(); }
        }
    }
}
