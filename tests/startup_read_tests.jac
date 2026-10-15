"""Manual regression: established accounts open while discovery owns the write lock."""
import tempfile;
import from unittest.mock { patch }
import from jaclang.runtime.runtime { JacRuntime }
import core.automation as a;
import main as app;

obj UnavailableWriteTurn {
    def __enter__() -> any { raise AssertionError("Startup waited for the catalog writer"); }
    def __exit__(kind: any, value: any, traceback: any) -> bool { return False; }
}

test "established account admission and bootstrap do not need a catalog write turn" {
    with tempfile.TemporaryDirectory(prefix="stack-startup-read-") as directory {
        previous=JacRuntime.peek_context();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
        try {
            root ++> a.AgentMemory();
            root ++> app.Profile();
            root ++> app.MatchPreferences();
            root ++> app.Settings(tailored_backfilled=True);commit();
            old=root ++> a.AgentRun(kind="resume",workflow_version=1,target_id="saved",context={},created_at=1.0,key="old",status="running");
            commit();assert a._upgrade_legacy_runs()==1;commit();
            assert old.upgrade_pending and old.status=="blocked";
            with patch.object(a,"_catalog_lock",UnavailableWriteTurn()), patch.object(app,"_write_lock",UnavailableWriteTurn()) {
                assert a.agent_admission()=={"admitted":True};
                snapshot=app.bootstrap();
                assert snapshot["user_id"]==jid(root);
                assert len(snapshot["agents"]["runs"])==1;
                assert snapshot["agents"]["runs"][0]["status"]=="blocked";
            }
        } finally { ctx.close();if previous is not None { JacRuntime.set_context(previous); } }
    }
}

test "admission still rejects an established deleted account without a catalog write turn" {
    with tempfile.TemporaryDirectory(prefix="stack-startup-deleted-") as directory {
        previous=JacRuntime.peek_context();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
        try {
            root ++> a.AgentMemory(deleted=True);commit();
            with patch.object(a,"_catalog_lock",UnavailableWriteTurn()) {
                assert a.agent_admission()=={"admitted":False};
            }
        } finally { ctx.close();if previous is not None { JacRuntime.set_context(previous); } }
    }
}
