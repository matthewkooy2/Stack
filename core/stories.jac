"""Private story-bank CRUD and agent kickoff. Sources are resolved by main.jac."""
import time;
import from uuid { uuid4 }
import from core.automation { BehavioralStory, _agent_access, _agent_fresh, _agent_start }
import from core.catalog { _catalog_lock }
import from agents.stories { corrected, missing, TOPICS }

def _story(id: str) -> BehavioralStory | None {
    for s in [root -->][?:BehavioralStory] { if jid(s)==id { return s; } }
    return None;
}
def _story_view(s: BehavioralStory) -> dict[str, any] {
    return {"id":jid(s),"title":s.title,"source":s.source,"content":s.content,"revision":s.revision,"history":s.history,"missing":missing(s.content),"updated_at":s.updated_at,"recommendation_basis":"Suggested question types, not an assessment of performance."};
}
def:priv story_get(id: str) -> dict[str, any] {
    _agent_access();s=_story(id);return _story_view(s) if s is not None else {"error":"Story not found."};
}
def:priv story_list(topic: str = "") -> dict[str, any] {
    _agent_access();
    if topic and topic not in TOPICS { return {"error":"Choose ownership, conflict, decisions or learning."}; }
    return {"stories":[_story_view(s) for s in [root --> [?:BehavioralStory, -updated_at]] if not topic or topic in s.content["topics"]]};
}
def:priv story_save(id: str, revision: int, fields: dict[str, any]) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();s=_story(id);
        if s is None { return {"error":"Story not found."}; }
        if s.revision!=revision { return {"error":"The story changed. Reopen it before saving."}; }
        try { content=corrected(s.content,fields,revision+1); } except ValueError as e { return {"error":str(e)}; }
        s.history=s.history+[{"revision":s.revision,"content":s.content,"at":time.time(),"kind":"user_correction"}];
        s.content=content;s.revision+=1;s.updated_at=time.time();commit();return _story_view(s);
    }
}
def:priv story_generate(id: str, revision: int) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();s=_story(id);
        if s is None { return {"error":"Story not found."}; }
        if s.revision!=revision { return {"error":"The story changed. Reopen it before generating."}; }
        # Corrections are user-confirmed evidence. Require a new story to generate
        # from its original source again, so regeneration cannot undo a correction.
        if any(v["source"].startswith("user-confirmed:") for v in s.content["fields"].values()) { return {"error":"This story has your corrections. Create a separate story for another AI draft."}; }
        return _agent_start("stories",id,{"story_source":s.source,"story_revision":s.revision},str(uuid4()));
    }
}
def:priv story_delete(id: str, revision: int) -> dict[str, any] {
    _agent_access();
    with _catalog_lock {
        _agent_fresh();s=_story(id);
        if s is None { return {"error":"Story not found."}; }
        if s.revision!=revision { return {"error":"The story changed. Reopen it before deleting."}; }
        del s;commit();return {"deleted":True};
    }
}
