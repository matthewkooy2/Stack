"""Regression for #108: job collection, background sweeps and each account have separate write turns."""
import tempfile;
import time;
import threading;
import from unittest.mock { patch }
import from jaclang.runtime.runtime { JacRuntime }
import core.automation as a;
import core.catalog as catalog;
import core.locks as locks;
import main as app;

obj BusyTurn {
    has owner: str = "";
    def __enter__() -> any { raise AssertionError("Waited for another subsystem's write turn: " + self.owner); }
    def __exit__(kind: any, value: any, traceback: any) -> bool { return False; }
}
def busy_collector -> any { return BusyTurn(owner="collector"); }
def busy_sweep -> any { return BusyTurn(owner="sweep"); }
def busy_account(owner: str = "") -> any { return BusyTurn(owner="account " + owner); }

def account_context(directory: str) -> any {
    ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
    root ++> a.AgentMemory();
    root ++> app.Profile(onboarded=True);
    root ++> app.MatchPreferences();
    root ++> app.Settings(tailored_backfilled=True);commit();
    return ctx;
}

test "account saves never wait for job collection or background sweeps" {
    with tempfile.TemporaryDirectory(prefix="stack-lock-split-") as directory {
        previous=JacRuntime.peek_context();ctx=account_context(directory);
        try {
            with patch.object(locks,"collector",busy_collector), patch.object(locks,"sweep",busy_sweep) {
                saved=app.save_profile("Fixture","Software engineer","United States","Any",False);
                assert saved["profile"]["role"]=="Software engineer";
                contact=app.bootstrap()["contacts"][0] if app.bootstrap()["contacts"] else {"id":jid(root ++> app.Contact(person_id="fixture-person"))};
                assert not app.save_contact(contact["id"],True,"Draft","Note").get("error");
                reminder=app.save_reminder("","contact",contact["id"],"Follow up",2000000000.0);
                assert any(r["title"]=="Follow up" for r in reminder["reminders"]);
                assert not catalog.save_search("Data analyst",{}).get("error");
                assert not a.agent_save_policy({"enabled":True,"actions":["model"],"expires_at":time.time()+3600}).get("error");
            }
        } finally { ctx.close();if previous is not None { JacRuntime.set_context(previous); } }
    }
}

test "one account holding its write turn does not block another account" {
    assert locks.account("owner-a") is locks.account("owner-a");
    assert locks.account("owner-a") is not locks.account("owner-b");
    held=threading.Event();release=threading.Event();
    def hold -> None { with locks.account("someone-else") { held.set();release.wait(10); } }
    worker=threading.Thread(target=hold);worker.start();
    try {
        assert held.wait(10);
        with tempfile.TemporaryDirectory(prefix="stack-lock-other-") as directory {
            previous=JacRuntime.peek_context();ctx=account_context(directory);
            try {
                # A blocked turn would hang here; acquire with a timeout instead of waiting forever.
                turn=locks.account();
                assert turn.acquire(timeout=2);turn.release();
                assert app.save_profile("Fixture","Analyst","United States","Any",False)["profile"]["role"]=="Analyst";
            } finally { ctx.close();if previous is not None { JacRuntime.set_context(previous); } }
        }
    } finally { release.set();worker.join(10); }
}

test "job collection never takes an account or sweep write turn" {
    sid="greenhouse:lock-split-fixture";
    source=root.shared ++> catalog.JobSource(key=sid,config={"adapter":"greenhouse","name":"Lock split fixture"},lease="claimed",status="collecting");
    with patch.object(catalog,"_worker_allowed",return_value=True),patch.object(catalog,"_fresh",return_value=None),patch.object(catalog,"commit",return_value=None),
         patch.object(locks,"account",busy_account), patch.object(locks,"sweep",busy_sweep) {
        assert catalog.discovery_complete("fixture",sid,"claimed",{"complete":True}).get("saved") is True;
        assert source.status=="ready" and source.lease=="";
    }
}
