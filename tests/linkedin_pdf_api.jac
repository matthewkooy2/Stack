import from core.automation { linkedin_pdf_review, agent_run, agent_retry, agent_cancel, agent_activity, agent_claim, agent_save_model, agent_settings, agent_model_log, agent_model_logs, agent_lease_active, _agent_complete }

def:pub agent_finish(token: str, id: str, owner: str, lease: str, result: dict[str, any]) -> dict[str, any] {
    value=_agent_complete(token,id,owner,lease,result);commit();return value;
}
