"""Bounded diagnostic content; never include credentials or binary artifacts."""
import json;
import os;
import re;
import from pathlib { Path }

def capture_enabled() -> bool {
    path = Path(os.environ.get("STACK_AGENT_CONFIG", "storage/agents/config.json"));
    return path.exists() and json.loads(path.read_text()).get("capture_agent_content") is True;
}

def _clean(value: any, secrets: list[str]) -> any {
    if isinstance(value, dict) {
        return {str(k): "[redacted]" if re.search(r"(?i)(password|authorization|credential|secret|api.?key|access.?token|refresh.?token|worker.?token|lease|sealed)", str(k)) else
            "[binary omitted]" if str(k) in ["base64", "content_base64", "audio", "image"] or (str(k)=="content" and value.get("name","").lower().endswith((".pdf", ".docx"))) else _clean(v, secrets) for (k, v) in value.items()};
    }
    if isinstance(value, list) { return [_clean(v, secrets) for v in value]; }
    if isinstance(value, str) {
        if value.lstrip().startswith(("{", "[")) {
            try { return json.dumps(_clean(json.loads(value), secrets), ensure_ascii=False); }
            except ValueError { ; }
        }
        for secret in secrets { value = value.replace(secret, "[redacted]"); }
        value = re.sub(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer [redacted]", value);
        value = re.sub(r"\bsk-[A-Za-z0-9_-]{12,}", "[redacted]", value);
        return value;
    }
    return value;
}

def trace_data(data: dict[str, any]) -> dict[str, any] {
    secrets = [v for (k, v) in os.environ.items() if len(v) >= 8 and re.search(r"(?i)(token|secret|password|api_key|session_key|encryption_key)", k)];
    token = Path("storage/agents/worker-token");
    if token.exists() { secrets.append(token.read_text().strip()); }
    cleaned = _clean(data, [s for s in secrets if s]);
    encoded = json.dumps(cleaned, ensure_ascii=False);
    if len(encoded.encode()) > 262144 {
        return {"truncated": True, "original_bytes": len(encoded.encode()), "preview": encoded.encode()[:262144].decode(errors="ignore")};
    }
    return cleaned;
}
