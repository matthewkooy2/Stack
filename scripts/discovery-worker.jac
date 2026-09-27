"""Resumable local collector. All leases, quotas, and catalog writes live in Jac."""
import os;
import time;
import json;
import from pathlib { Path }
import urllib.request;
import from discovery.sources { collect }

def _call(name: str, args: dict[str, any]) -> dict[str, any] {
    request=urllib.request.Request(os.environ.get("STACK_WORKER_API","http://127.0.0.1:8000")+"/function/"+name,data=json.dumps(args).encode(),headers={"Content-Type":"application/json"});
    with urllib.request.urlopen(request,timeout=90) as response { result=json.loads(response.read())["data"]["result"]; }
    if result.get("error") { raise ValueError(result["error"]); }
    return result;
}
with entry:__main__ {
    token=Path("storage/discovery/worker-token").read_text().strip();
    analyzed=False;
    while True {
        try {
            if not analyzed { progress=_call("discovery_analyze",{"token":token});analyzed=progress["complete"];if not analyzed { continue; } }
            work=_call("discovery_claim",{"token":token});
            if work.get("idle") { time.sleep(15); continue; }
            result={};error="";
            try { result=collect(work["config"],work["checkpoint"]); }
            except Exception as e {
                # Transport errors contain no keys; unexpected exception text might.
                error=str(e) if isinstance(e,ValueError) else "Source could not be collected ("+type(e).__name__+").";
            }
            _call("discovery_complete",{"token":token,"id":work["id"],"lease":work["lease"],"result":result,"error":error});
            print(work["id"]+": "+(error or str(len(result.get("jobs",[])))+" listings"),flush=True);
            time.sleep(2);
        } except KeyboardInterrupt { break; }
        except Exception { print("Collector waiting for the local API; persisted work will resume.",flush=True);time.sleep(10); }
    }
}
