import tempfile;
import from jaclang.runtime.runtime { JacRuntime }
import core.automation as a;

test "provider-aware task reuse preserves terminal and active selections" {
    for terminal_status in ["failed","completed"] {
        with tempfile.TemporaryDirectory(prefix="stack-provider-dedupe-") as directory {
            previous=JacRuntime.peek_context();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
            try {
                memory=a._agent_memory();memory.model_selection="codex-cli";commit();
                context={"profile":{"name":"Example"}};
                first=a._agent_start("profile","self",context);first_id=first["id"];
                first_node=a._owned_run(first_id) as a.AgentRun;first_node.status=terminal_status;
                # Existing stored runs still carry the pre-provider idempotency key.
                first_node.key=a.digest(["profile","self",first_node.context]);commit();
                same_provider=a._agent_start("profile","self",context);
                assert same_provider["id"]==first_id;

                memory.model_selection="local";commit();
                switched=a._agent_start("profile","self",context);
                assert switched["id"]!=first_id;
                assert switched["model_selection"]=="local";
                assert first_node.model_selection=="codex-cli" and first_node.status==terminal_status;
                assert a._agent_start("profile","self",context)["id"]==switched["id"];
            } finally {
                ctx.close();
                if previous is not None { JacRuntime.set_context(previous); }
            }
        }
    }

    with tempfile.TemporaryDirectory(prefix="stack-provider-active-") as directory {
        previous=JacRuntime.peek_context();ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
        try {
            memory=a._agent_memory();memory.model_selection="codex-cli";commit();
            context={"profile":{"name":"Example"}};
            active=a._agent_start("profile","self",context);active_node=a._owned_run(active["id"]) as a.AgentRun;
            memory.model_selection="local";commit();
            newly_selected=a._agent_start("profile","self",context);
            assert newly_selected["id"]!=active["id"];
            assert active_node.model_selection=="codex-cli" and active_node.status=="queued";
            assert newly_selected["model_selection"]=="local";
        } finally {
            ctx.close();
            if previous is not None { JacRuntime.set_context(previous); }
        }
    }
}
