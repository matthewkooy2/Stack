"""Resumable local collector. All leases, quotas, and catalog writes live in Jac."""
import os;
import time;
import from pathlib { Path }
import argparse;
import from discovery.worker { call, batch }
with entry:__main__ {
    parser=argparse.ArgumentParser(description="Resumable public listing collector");
    parser.add_argument("--once",action="store_true",help="Finish one claimed batch and exit");
    parser.add_argument("--source",`default="",help="Claim only this configured source");
    args=parser.parse_args();
    token=Path("storage/discovery/worker-token").read_text().strip();
    analyzed=False;
    while True {
        try {
            if not analyzed { progress=call("discovery_analyze",{"token":token});analyzed=progress["complete"];if not analyzed { continue; } }
            work=batch(token,args.source);
            if work.get("idle") { if args.once { break; } time.sleep(15); continue; }
            result=work["result"];error=work["error"];
            print(work["id"]+": "+(error or str(len(result.get("jobs",[])))+" listings"),flush=True);
            if args.once { if error { raise SystemExit(1); } break; }
            time.sleep(2);
        } except KeyboardInterrupt { break; }
        except Exception { if args.once { raise; } print("Collector waiting for the local API; persisted work will resume.",flush=True);time.sleep(10); }
    }
}
