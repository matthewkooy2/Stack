"""Legacy records exercise the same stored nodes and upgrade helpers as the API."""
import tempfile;
import from jaclang.runtime.runtime { JacRuntime }
import core.automation as a;
import from agents.contracts { workflow_steps }

test "legacy step mapping and migration preserve receipts and terminal records across restart" {
    with tempfile.TemporaryDirectory(prefix="stack-upgrade-") as directory {
        previous=JacRuntime.peek_context();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);
        JacRuntime.set_context(ctx);
        try {
            ids=[];
            for kind in ["resume","application"] {
                for index in range(len(workflow_steps(kind,1))) {
                    r=root ++> a.AgentRun(kind=kind,target_id="saved-job",context={"resume_format":"latex"},created_at=1.0,key=kind+str(index),index=index,status="running",lease="old-lease",artifacts={"tailor":{"pdf":{"content":"legacy"}}});
                    ids.append(jid(r));
                    root.shared ++> a.AgentTicket(owner=jid(root),run_id=jid(r));
                }
            }
            terminal=[];
            for status in ["completed","cancelled","failed"] {
                r=root ++> a.AgentRun(kind="application",target_id="saved-job",context={},created_at=1.0,key=status,index=4,status=status,artifacts={"submit":{"receipt":"kept"}});
                terminal.append(jid(r));
            }
            uncertain=root ++> a.AgentRun(kind="application",target_id="saved-job",context={},created_at=1.0,key="uncertain",index=4,status="running",lease="dispatched");
            receipt=root ++> a.AgentAction(run_id=jid(uncertain),step="submit",key="external-action",payload_hash="old-payload",policy_revision=1,created_at=1.0);
            commit();
            assert a._upgrade_legacy_runs()==7;
            assert a._upgrade_legacy_runs()==0;
            for id in ids {
                r=a._owned_run(id) as a.AgentRun;assert r.workflow_version==1 and not r.lease;
                assert r.status==("blocked" if r.kind=="resume" else "cancelled");
                assert r.upgrade_pending==(r.kind=="resume");
                assert a._run_view(r)["step"]==workflow_steps(r.kind,1)[r.index];
                assert r.artifacts["tailor"]["pdf"]["content"]=="legacy";
            }
            for id in terminal {
                r=a._owned_run(id) as a.AgentRun;assert not r.upgrade_pending and r.artifacts=={"submit":{"receipt":"kept"}};
            }
            assert uncertain.status=="uncertain";
            resumed=a._owned_run(ids[0]) as a.AgentRun;a._continue_legacy(resumed);
            assert resumed.workflow_version==2 and resumed.index==0 and resumed.artifacts=={} and resumed.context["resume_format"]=="";
            assert a._steps(resumed)==["tailor","approve_resume"];
            commit();ctx.close();
            ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
            assert (a._owned_run(ids[0]) as a.AgentRun).workflow_version==2;
            assert a._upgrade_legacy_runs()==0;
        } finally {
            ctx.close();
            if previous is not None { JacRuntime.set_context(previous); }
        }
    }
}
