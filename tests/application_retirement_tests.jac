"""Retired application tasks remain readable but cannot execute or restart."""
import tempfile;
import time;
import os;
import from unittest.mock { patch }
import from jaclang.runtime.runtime { JacRuntime }
import core.automation as a;
import from agents.contracts { STEPS, EXTERNAL, workflow_steps, validate_policy, default_policy }
import from agents.worker { dispatch }
import from agents.browser { BrowserPool }
import from agents.experience { FEATURES }

test "application execution and permissions are removed" {
    assert "application" not in STEPS;
    assert not [f for f in FEATURES if "application" in f["kinds"]];
    for step in ["inspect","fill","submit"] {
        assert step not in EXTERNAL and not hasattr(BrowserPool,step);
        with testraises(ValueError) { dispatch({"step":step,"context":{},"artifacts":{},"id":"old","owner":"old","lease":"old"},"synthetic"); }
    }
    for action in ["browser_fill","submit_application"] {
        with testraises(ValueError) { validate_policy({"actions":[action]}); }
    }
}

test "both stored workflow versions retire without losing results or allowing retries" {
    with tempfile.TemporaryDirectory(prefix="stack-application-retirement-") as directory {
        previous=JacRuntime.peek_context();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
        try {
            root ++> a.AgentMemory(policy=default_policy());commit();ids=[];
            assert "error" in a._agent_start("application","saved-job",{});
            for version in [1,2] {
                for status in ["queued","running","review","blocked","needs_input","paused","failed","completed","cancelled"] {
                    r=root ++> a.AgentRun(kind="application",workflow_version=version,target_id="saved-job",context={},created_at=1.0,key=str(version)+status,status=status,index=0,lease="old",lease_until=time.time()+180,artifacts={"tailor":{"pdf":{"content":"saved"}}});
                    ids.append(jid(r));root.shared ++> a.AgentTicket(owner=jid(root),run_id=jid(r));
                }
            }
            commit();owner=jid(root);
            # A stale worker is refused even before the migration runs.
            with testraises(ValueError) { a._agent_leased(ids[1],owner,"old"); }
            for id in ids {
                assert "error" in a.agent_retry(id);
                assert "error" in a.agent_respond(id);
                assert "error" in a.agent_approve(id,"fill","old");
            }
            assert a._upgrade_legacy_runs()==12;
            assert a._upgrade_legacy_runs()==0;
            for id in ids {
                r=a._owned_run(id) as a.AgentRun;
                assert r.status in ["cancelled","failed","completed"];
                view=a._run_view(r,True);
                assert view["artifacts"]["tailor"]["pdf"]["content"]=="saved";
                assert not view["browser"]["supported"];
            }
            # Both reconciliation outcomes retain evidence and never queue new work.
            for version in [1,2] {
                for outcome in ["confirmed","not_sent"] {
                    r=root ++> a.AgentRun(kind="application",workflow_version=version,target_id="saved-job",context={},created_at=1.0,key=str(version)+outcome,status="running",index=workflow_steps("application",version).index("submit"));
                    action=root ++> a.AgentAction(run_id=jid(r),step="submit",key=jid(r),payload_hash="old",policy_revision=0,created_at=1.0);
                    id=jid(r);action_id=jid(action);commit();
                    assert a._upgrade_legacy_runs()==1;
                    assert a._run_view(a._owned_run(id) as a.AgentRun)["status"]=="uncertain";
                    result=a.agent_reconcile(id,outcome,"Synthetic receipt evidence");
                    assert result["status"] in ["completed","cancelled"], result;
                    stored=[x for x in [root -->][?:a.AgentAction] if jid(x)==action_id][0];
                    assert stored.status==outcome and stored.receipt["evidence"]=="Synthetic receipt evidence";
                }
            }
            commit();ctx.close();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
            assert a._upgrade_legacy_runs()==0;
            assert (a._owned_run(ids[0]) as a.AgentRun).status=="cancelled";
            queued=root ++> a.AgentRun(kind="application",workflow_version=2,target_id="saved-job",context={},created_at=1.0,key="queue-check");
            queued_id=jid(queued);root.shared ++> a.AgentTicket(owner=jid(root),run_id=queued_id);commit();
            with patch.dict(os.environ,{"STACK_AGENT_WORKER_TOKEN":"retirement-test-worker"}) {
                assert a.agent_claim("retirement-test-worker")=={"idle":True};
            }
            assert (a._owned_run(queued_id) as a.AgentRun).status=="cancelled";
        } finally {
            ctx.close();if previous is not None { JacRuntime.set_context(previous); }
        }
    }
}
