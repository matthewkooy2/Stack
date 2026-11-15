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
        self.id = supplied if _ID.fullmatch(supplied) else uuid.uuid4().hex
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

    def upstream_response(self, path, response):
        request_id = response.headers.get("X-Trace-Id", "")
        if _ID.fullmatch(request_id):
            self.backend_id = request_id
        self.log("upstream_response", upstream_route=path, status=response.status)
