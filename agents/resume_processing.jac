"""Dedicated resume lane. No model calls; all scratch files and caches live in this checkout."""
import base64;
import json;
import logging;
import time;
import from agents.worker { call }
import agents.latex as latex;
import from agents.resume_templates { fill }

def process(work: dict[str, any], token: str) -> dict[str, any] {
    auth={"token":token,**{k:work[k] for k in ["id","owner","lease"]}};
    result: dict[str, any] = {"parse_ms":0.0,"compile_ms":0.0};start=time.perf_counter();
    try {
        raw=base64.b64decode(work["content"],validate=True);
        if work["kind"]=="import" {
            import from agents.record_resume { import_records }
            result["records"]=import_records(work["name"],raw);
            result["parse_ms"]=(time.perf_counter()-start)*1000.0;
        } elif work["kind"]=="pdf" {
            raise ValueError("PDF detail extraction is temporarily unavailable.");
        } else {
            if work["input_key"].endswith(".json") {
                data=json.loads(raw);source=fill(data["template"],data["values"]);
                template={"kind":"builtin","builtin":data["template"]};
            } else {
                source=latex.load(work["name"],raw);
                template={"kind":"upload","name":work["name"],"main":source["main"],"skipped":source["skipped"][:20]};
            }
            structure=latex.parse(source);
            if not structure["bullets"] and template["kind"]=="upload" { raise ValueError("Stack could not find bullet points. Use \\item or \\resumeItem bullets, or choose a built-in template."); }
            result["parse_ms"]=(time.perf_counter()-start)*1000.0;
            call("resume_processing_stage",{**auth,"parse_ms":result["parse_ms"]});
            start=time.perf_counter();
            try { compiled=latex.compile(source); }
            finally { result["compile_ms"]=(time.perf_counter()-start)*1000.0; }
            result["template"]={**template,"pages":compiled["pages"],"summary":latex.summary(structure)};
            files={".pdf":compiled["pdf"]};
            if template["kind"]=="upload" { files[".zip"]=latex.pack(source); }
            result["files"]={suffix:base64.b64encode(data).decode() for (suffix,data) in files.items()};
        }
    } except Exception as e {
        if not result["parse_ms"] { result["parse_ms"]=(time.perf_counter()-start)*1000.0; }
        result["error"]=str(e)[:500] if isinstance(e,ValueError) else "Resume processing failed ("+`type(e).__name__+"). Retry processing.";
    }
    return result;
}
def run_once(token: str) -> bool {
    work=call("resume_processing_claim",{"token":token});
    if work.get("idle") { return False; }
    result=process(work,token);
    call("resume_processing_finish",{"token":token,**{k:work[k] for k in ["id","owner","lease"]},"result":result});
    return True;
}
def main(token: str) -> None {
    while True {
        try {
            if not run_once(token) { time.sleep(1); }
        } except Exception {
            logging.getLogger("stack.resume").warning("Resume worker waiting for API; saved work will resume.");
            time.sleep(3);
        }
    }
}
