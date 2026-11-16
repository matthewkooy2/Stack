"""Correlate gateway requests using bounded, non-secret metadata."""
import contextvars
import json
import re
import time
import uuid
from datetime import datetime, timezone

current = contextvars.ContextVar("stack_request_trace", default=None)
_ID = re.compile(r"[a-f0-9]{32}")
_RAY = re.compile(r"[a-f0-9]{16,32}(?:-[A-Z]{3})?")
_CLIENT_VALUE = re.compile(r"[A-Za-z0-9 ._()+-]{1,64}")
_CLIENT_FIELDS = ("platform", "device", "os", "version", "build")
_MAX_INSPECT_BYTES = 2 * 1024 * 1024


def _failed(envelope):
    return isinstance(envelope, dict) and (envelope.get("ok") is False or bool(envelope.get("error")))


def response_outcome(status, content_type, body):
    if status >= 400:
        return "http_error"
    if not 200 <= status < 300 or content_type.partition(";")[0].strip().lower() != "application/json":
        return "response"
    if len(body) > _MAX_INSPECT_BYTES:
        return "inspection_skipped"
    try:
        envelope = json.loads(body)
    except (ValueError, RecursionError):
        return "inspection_skipped"
    if _failed(envelope):
        return "application_error"
    data = envelope.get("data") if isinstance(envelope, dict) else None
    return "application_error" if isinstance(data, dict) and _failed(data.get("result")) else "response"


def valid_request_id(value):
    return isinstance(value, str) and _ID.fullmatch(value) is not None


def _client(value):
    if len(value) > 480:
        return {}
    try:
        data = json.loads(value)
    except ValueError:
        return {}
    if not isinstance(data, dict):
        return {}
    return {key: data[key] for key in _CLIENT_FIELDS
            if isinstance(data.get(key), str) and _CLIENT_VALUE.fullmatch(data[key])}


class RequestTrace:
    def __init__(self, headers, route):
        supplied = headers.get("X-Request-Id", "")
        self.id = supplied if valid_request_id(supplied) else uuid.uuid4().hex
        ray = headers.get("CF-Ray", "")
        self.ray = ray if _RAY.fullmatch(ray) else None
        self.client = _client(headers.get("X-Stack-Client", ""))
        self.route = route
        self.status = None
        self.backend_id = None
        self.started = time.monotonic()

    def log(self, event, **fields):
        print(json.dumps({
            "time": datetime.now(timezone.utc).isoformat(), "layer": "gateway",
            "event": event, "request_id": self.id, "cf_ray": self.ray,
            "route": self.route, "elapsed_ms": round((time.monotonic() - self.started) * 1000),
            **fields,
        }), flush=True)

    def upstream_response(self, path, response, body):
        backend_id = response.headers.get("X-Trace-Id", "")
        if valid_request_id(backend_id):
            self.backend_id = backend_id
        outcome = response_outcome(response.status, response.headers.get("Content-Type", ""), body)
        self.log("upstream_response", upstream_route=path, status=response.status, outcome=outcome,
                 backend_trace_id=backend_id if valid_request_id(backend_id) else None)
