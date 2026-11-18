"""Deterministic Stack contracts shared with its released workers and clients."""
import json
from pathlib import Path
import sys
root=Path(sys.argv[1]).resolve()
sys.path[:0]=[str(root),str(root/"score-docs")]
from agents import contracts as c, experience as e, tracing

def perform(a):
    r = a.get("run", {})
    op = a["op"]
    if op=="linkedin_pdf":
        from agents.linkedin_pdf import parse_encoded
        return parse_encoded(a["name"],a["content"])
    if op == "enqueue":
        ctx = {**a["context"],"prompt_version":c.VERSION}
        ctx["facts"] = c.context_facts(a["facts"],ctx)
        kind = a["kind"]
        if kind not in c.STEPS:
            raise ValueError("Unknown agent.")
        if kind == "resume" and ctx.get("resume_format") == "records":
            from agents.memory_tailoring import VERSION
            ctx["tailoring_version"] = VERSION
        identity = a["nonce"] or ("once" if kind=="network" else ctx)
        return {"context":ctx,"key":c.digest([kind,a["target"],identity,a["selection"]]),"steps":c.STEPS[kind]}
    if op == "display":
        return {"presentation":e.present(r["kind"],r["status"],r["index"],r["steps"],r["context"],r["next_at"]),
                "output_version":c.digest(r["artifacts"])}
    if op == "facts":
        overrides=r["context"].get("fact_overrides",[])
        keys={f["key"] for f in overrides}
        return c.context_facts([f for f in a["facts"] if f["key"] not in keys]+overrides,r["context"])
    if op == "validate_facts":
        return c.validate_facts(a["values"])
    if op == "trace":
        data=a["data"]
        if not tracing.capture_enabled() and a.get("model_event"):
            data={k:v for k,v in data.items() if k in ["provider","requested_model","reported_models","exit_code","valid","model_attempt"]}
        if not tracing.capture_enabled() and a.get("stage_context"):
            data={**data,"context":{"content_capture":False}}
        if a.get("stage_result"):
            result=data["result"]
            if result.get("error") and "browser_diagnostic" in result:
                from agents.browser_control import BROWSER_ERROR_MESSAGE, sanitize_browser_diagnostic
                diagnostic=sanitize_browser_diagnostic(result["browser_diagnostic"])
                result={"error":BROWSER_ERROR_MESSAGE}
                if diagnostic and diagnostic["operation"]==a["stage_result"]:
                    result["browser_diagnostic"]=diagnostic
            elif not tracing.capture_enabled():
                result={"error":result.get("error",""),"message":result.get("message","")}
            data={**data,"result":result}
        return tracing.trace_data(data)
    if op == "approve" or op == "review":
        step=a["step"]
        artifacts=r["artifacts"]
        edits=a.get("edits")
        if op=="approve" and isinstance(edits,dict) and edits:
            if step=="approve_resume":
                changes={x["id"] for x in artifacts["tailor"].get("changes",[])}
                rejected=edits.get("rejected",[])
                if not isinstance(rejected,list) or not all(isinstance(x,str) and x in changes for x in rejected):
                    raise ValueError("Choose changes from this review.")
                artifacts["tailor"]["rejected"]=sorted(set(rejected))
            elif step=="send":
                subject=str(edits.get("subject","")).strip()
                body=str(edits.get("body","")).strip()
                if not subject or not body or len(subject)>200 or len(body)>10000 or "\n" in subject or "\r" in subject:
                    raise ValueError("Enter a one-line subject under 200 characters and a message under 10,000 characters.")
                artifacts["draft"].update(subject=subject,body=body,edited_by_user=True)
            else:
                raise ValueError("Only email subject and body can be edited here.")
        review=e.review_summary(step,r["context"],artifacts)
        review["hash"]=c.digest(e.review_payload(step,r["context"],artifacts))
        return {"review":review, "artifacts":artifacts}
    if op=="config":
        cfg=c.config(r["model_selection"])
        if a["step"] in c.MODEL_STEPS or a["step"]=="linkedin_scan":
            c.model_access(cfg,a["owner"])
        return {"hash":c.digest(cfg),"provider":cfg["provider"],"model":cfg["model"] or "provider default",
                "seconds":300 if r["context"].get("manual_scan") else 900 if a["step"]=="tailor" else 600 if cfg.get("fallback_enabled") and cfg["provider"] in c.LOCAL_PROVIDERS else 180}
    if op=="policy":
        action=c.EXTERNAL[a["step"]]
        c.authorize(a["policy"], action, r["context"].get("contact",{}).get("email","") if a["step"]=="send" else "")
        return {"action":action,"cap":c.config()["action_daily_limits"].get(action,0)}
    if op=="memory":
        from agents.memory_access import collect
        return collect(a["owner"],a["resumes"],a["facts"],a["stories"])
    if op=="interview":
        from agents.interview import apply
        return apply(a["session"]["data"],a["session"]["revision"],a["step"],a["artifact"],r["context"])
    if op=="artifact_hash":
        return c.digest(a["artifacts"])
    if op=="coaching":
        from agents.coaching import stored
        return stored(a["artifact"])
    raise ValueError("Unsupported lifecycle operation.")

try:
    print(json.dumps(perform(json.load(sys.stdin))))
except (ValueError, KeyError, TypeError) as ex:
    print(json.dumps({"error":str(ex)}))
