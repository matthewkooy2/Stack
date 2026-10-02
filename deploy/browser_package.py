"""Public source-only browser context shared by packager and trusted receiver."""
import hashlib
import json

SOURCE_FILES = frozenset({
    "agents/browser.jac", "agents/browser_service.jac", "agents/contracts.jac",
    "agents/linkedin.jac", "discovery/transport.py", "deploy/browser-service.jac",
    "agents/browser_control.py", "agents/browser_stream.py",
})
OPTIONAL_FILES = frozenset({"agents/browser_control.py", "agents/browser_stream.py"})
CONTRACT_FILES = frozenset({
    "deploy/browser.Dockerfile", "deploy/browser.jac.toml",
    "deploy/browser-entrypoint", "deploy/install-browser.jac",
    "deploy/browser-requirements.txt", "deploy/browser-seccomp.json",
})


def fingerprint(files):
    return hashlib.sha256((json.dumps(files, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest()


def allowed_browser(path):
    return (path.startswith("browser/source/") and path[15:] in SOURCE_FILES or
            path.startswith("browser/contract/") and path[17:] in CONTRACT_FILES)


def browser_metadata(payload):
    sha = lambda data: hashlib.sha256(data).hexdigest()
    source = {n: sha(payload["browser/source/" + n]) for n in sorted(SOURCE_FILES)
              if "browser/source/" + n in payload}
    contract = {n: sha(payload["browser/contract/" + n]) for n in sorted(CONTRACT_FILES)}
    assert SOURCE_FILES - OPTIONAL_FILES <= source.keys(), "Incomplete browser source"
    # The host and image must receive identical copies of shared modules.
    for n in source.keys() & payload.keys():
        assert payload[n] == payload["browser/source/" + n], "Browser/backend source differs"
    return {"files": source, "contract": contract, "fingerprint": fingerprint(source)}
