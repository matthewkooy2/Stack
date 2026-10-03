"""Private owner-scoped recordings and worker-only lease endpoints."""
import from core.automation { _agent_access, _agent_system }
import from agents.transcription_store { Store }

def:priv transcription_upload(client_id: str, content: str) -> dict[str, any] {
    _agent_access();
    try { return Store().upload(jid(root),client_id,content); }
    except ValueError as e { return {"error":str(e)}; }
}
def:priv transcription_list() -> dict[str, any] {
    _agent_access();return {"recordings":Store().list(jid(root)),"runtime":Store().runtime_status()};
}
def:priv transcription_get(id: str) -> dict[str, any] {
    _agent_access();
    try { return Store().get(jid(root),id); }
    except ValueError as e { return {"error":str(e)}; }
}
def:priv transcription_audio(id: str) -> dict[str, any] {
    _agent_access();
    try { return Store().audio(jid(root),id); }
    except ValueError as e { return {"error":str(e)}; }
}
def:priv transcription_action(id: str, action: str, text: str = "", revision: int = 0) -> dict[str, any] {
    _agent_access();
    try { return Store().action(jid(root),id,action,text,revision); }
    except ValueError as e { return {"error":str(e)}; }
}
def:priv transcription_transfer_complete(id: str, elapsed_ms: float) -> dict[str, any] {
    _agent_access();
    try { return Store().transfer(jid(root),id,elapsed_ms); }
    except ValueError as e { return {"error":str(e)}; }
}
def:pub transcription_processing_claim(token: str) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    return Store().claim();
}
def:pub transcription_processing_progress(token: str, id: str, owner: str, lease: str, stage: str, percent: any = None, timings: dict[str, any] = {}) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    try { return Store().progress(id,owner,lease,stage,percent,timings); }
    except ValueError as e { return {"error":str(e)}; }
}
def:pub transcription_processing_finish(token: str, id: str, owner: str, lease: str, result: dict[str, any]) -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    try { return Store().finish(id,owner,lease,result); }
    except ValueError as e { return {"error":str(e)}; }
}

def:priv transcription_retry_setup() -> dict[str, any] {
    _agent_access();
    try { return Store().runtime_retry(jid(root)); }
    except ValueError as e { return {"error":str(e)}; }
}
def:pub transcription_processing_runtime(token: str, action: str = "get", result: dict[str, any] = {}, generation: str = "") -> dict[str, any] {
    if not _agent_system(token) { return {"error":"Worker authorization required."}; }
    try { return Store().runtime_worker(action,result,generation); }
    except ValueError as e { return {"error":str(e)}; }
}
