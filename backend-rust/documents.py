"""Run Stack's bounded, deterministic document reader in a short-lived process."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
sys.path[:0] = [str(root), str(root / "score-docs")]
from agents.record_resume import import_records, validate_upload
from agents import resume_details


def read(name, content):
    validate_upload(name, content)
    try:
        records = import_records(name, content)
    except ValueError as error:
        return {"processing_error": str(error)}
    import hashlib
    digest = hashlib.sha256(content).hexdigest()
    try:
        details = {"details": resume_details.parse(name, content)}
    except ValueError as error:
        details = {"details_error": str(error)}
    review, _ = resume_details.attach_import({}, details, records, digest)
    return {"review": review}


try:
    action, name = sys.argv[2:4]
    if action == "import":
        result = read(name, sys.stdin.buffer.read(10 * 1024 * 1024 + 1))
    elif action == "validate":
        validate_upload(name, sys.stdin.buffer.read(10 * 1024 * 1024 + 1))
        result = {}
    else:
        args = json.load(sys.stdin)
        review = args["review"]
        if action == "save":
            review = resume_details.save(review, args["values"], args["confirm"], args["revision"], args["now"], name)
        result = {"view": resume_details.view(review)}
        if action == "save":
            result.update(review=review, facts=resume_details.facts_for(args["id"], name, review.get("values", {})) if args["confirm"] else [])
    print(json.dumps(result))
except ValueError as error:
    print(json.dumps({"error": str(error)}))
