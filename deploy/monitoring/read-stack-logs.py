#!/usr/bin/env python3
"""Collect sanitized Stack request traces and production tunnel errors."""
import datetime
import json
from pathlib import Path
import re
import subprocess
import time
from urllib.request import Request, urlopen

STATE = Path("/var/lib/stack-monitoring-log-reader")
SOURCES_BY_ENV = {"production": ("gateway", "api", "tunnel"), "staging": ("gateway", "api")}
TUNNEL_REASONS = {
    "connection refused": "origin_connection_refused",
    "unable to reach the origin service": "origin_unreachable",
    "context canceled": "request_canceled",
    "deadline exceeded": "deadline_exceeded",
    "timeout": "timeout",
}
APPLE_STAGES = {
    "configuration", "client_credentials", "challenge_store", "challenge_validation",
    "apple_keys", "identity_verification", "token_exchange", "account_resolution",
    "grant_storage", "session_issue",
}
APPLE = {
    "/function/auth_apple_begin",
    "/function/auth_apple_web_begin",
    "/function/auth_apple_finish",
}
LOG_TIME = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z")
ROUTE = re.compile(r"/(?:(?:function|user)/[A-Za-z0-9_]{1,80}|sso/google/(?:begin|finish|poll|callback)|browser/stream)")
ACCESS = re.compile(
    r'^\S+ "(?:GET|POST) (/[A-Za-z0-9_/]+)(?:\?[^"\s]*)? HTTP/[\d.]+"\s+'
    r'(\d{3})\s+\d+\s+(\d+(?:\.\d+)?)ms\s+([a-f0-9]{32})\s*$'
)
POLLING = {
    "/function/health", "/function/agent_claim", "/function/agent_notification_claim",
    "/function/resume_processing_claim", "/function/transcription_processing_claim",
    "/function/transcription_processing_runtime",
}
SAFE_FIELDS = {
    "request_id": re.compile(r"[a-f0-9]{32}"),
    "backend_trace_id": re.compile(r"[a-f0-9]{32}"),
    "upstream_route": ROUTE,
    "cf_ray": re.compile(r"[0-9a-f]{16,32}(?:-[A-Z]{3})?", re.I),
    "error_type": re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,70}"),
}


def sanitize(service, body):
    if service == "api":
        if body.startswith("{"):
            try:
                failure = json.loads(body)
            except ValueError:
                return None
            if isinstance(failure, dict) and failure.get("event") == "apple_auth_failure":
                step = failure.get("step")
                mode = failure.get("mode")
                stage = failure.get("stage")
                error_type = failure.get("error_type", "")
                if (step in ("begin", "finish") and mode in ("native", "web", "unknown")
                        and isinstance(stage, str) and stage in APPLE_STAGES
                        and isinstance(error_type, str)
                        and SAFE_FIELDS["error_type"].fullmatch(error_type)):
                    safe = {"event": "apple_auth_failure", "step": step, "mode": mode,
                            "stage": stage, "error_type": error_type}
                    status = failure.get("provider_status")
                    if type(status) is int and 400 <= status <= 599:
                        safe["provider_status"] = status
                    request_id = failure.get("request_id")
                    if isinstance(request_id, str) and SAFE_FIELDS["request_id"].fullmatch(request_id):
                        safe["request_id"] = request_id
                    return safe
            return None
        match = ACCESS.fullmatch(body)
        if not match:
            return None
        route, status, duration, request_id = match.groups()
        code = int(status)
        if not ROUTE.fullmatch(route) or (route in POLLING and code < 400):
            return None
        return {"event": "http_response", "route": route, "status": code,
                "elapsed_ms": float(duration), "request_id": request_id}

    try:
        row = json.loads(body)
    except ValueError:
        return None
    if not isinstance(row, dict):
        return None
    route, event = row.get("route"), row.get("event")
    if not isinstance(route, str) or not ROUTE.fullmatch(route):
        return None
    if event not in ("received", "upstream_started", "upstream_response", "completed", "error"):
        return None
    safe = {"event": event, "route": route}
    if row.get("outcome") in ("application_error", "http_error", "inspection_skipped", "response"):
        safe["outcome"] = row["outcome"]
    for field in ("status", "elapsed_ms"):
        if type(row.get(field)) is int:
            safe[field] = row[field]
    for field, pattern in SAFE_FIELDS.items():
        if isinstance(row.get(field), str) and pattern.fullmatch(row[field]):
            safe[field] = row[field]
    return safe


def tunnel_entries(output, since, until):
    values = []
    for line in output.splitlines():
        try:
            row = json.loads(line)
            micros = int(row["__REALTIME_TIMESTAMP"])
            message = row["MESSAGE"].lower()
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        if not since * 1_000_000 <= micros < until * 1_000_000:
            continue
        if not re.search(r"\b(?:err|wrn)\b", message):
            continue
        reason = next((label for phrase, label in TUNNEL_REASONS.items() if phrase in message), None)
        status = re.search(r"\b(?:statuscode|status_code|http_status|status)=(5[0-9]{2})\b", message)
        if reason or status:
            entry = {"event": "tunnel_error"}
            if reason:
                entry["reason"] = reason
            if status:
                entry["reported_status"] = int(status[1])
            route = next((path for path in APPLE if path in message), None)
            if route:
                entry["route"] = route
            values.append((str(micros * 1000), json.dumps(entry, separators=(",", ":"))))
    return sorted(values)


def collect(environment, service, since, until):
    if service == "tunnel":
        command = (f"sudo -n journalctl -u stack-production-tunnel --since @{since} "
                   f"--until @{until} --output=json --no-pager")
    else:
        command = f"sudo -n docker logs --timestamps --since {since} --until {until} stack-{service}-1 2>&1"
    output = subprocess.check_output(
        ["/usr/local/sbin/stack-vm-ssh", environment, command],
        stderr=subprocess.DEVNULL,
        timeout=65,
        text=True,
        errors="replace",
    )
    if service == "tunnel":
        return tunnel_entries(output, since, until)
    values = []
    for line in output.splitlines():
        stamp, _, body = line.partition(" ")
        timestamp = LOG_TIME.fullmatch(stamp)
        if not timestamp:
            continue
        entry = sanitize(service, body)
        if entry:
            seconds = int(datetime.datetime.fromisoformat(timestamp[1] + "+00:00").timestamp())
            if since <= seconds < until:
                fraction = (timestamp[2] or "").ljust(9, "0")
                values.append((f"{seconds}{fraction}", json.dumps(entry, separators=(",", ":"))))
    return sorted(values)


def main():
    until = int(time.time()) - 5
    for environment, services in SOURCES_BY_ENV.items():
        for service in services:
            cursor = STATE / f"{environment}-{service}"
            try:
                since = int(cursor.read_text()) if cursor.exists() else until - 12 * 3600
                if until <= since:
                    continue
                values = collect(environment, service, since, until)
                if values:
                    payload = {"streams": [{
                        "stream": {"job": "stack", "environment": environment, "service": service},
                        "values": values,
                    }]}
                    request = Request(
                        "http://127.0.0.1:13100/loki/api/v1/push",
                        data=json.dumps(payload).encode(),
                        headers={"Content-Type": "application/json"},
                    )
                    with urlopen(request, timeout=12) as response:
                        if response.status != 204:
                            raise RuntimeError("Loki did not accept the batch")
                    print(environment, service, "imported", len(values), "entries", flush=True)
                temp = cursor.with_suffix(".tmp")
                temp.write_text(str(until))
                temp.replace(cursor)
            except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
                print(environment, service, "collection failed:", type(error).__name__, flush=True)


if __name__ == "__main__":
    main()
