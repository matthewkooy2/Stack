#!/usr/bin/env python3
"""Bounded startup of existing units; no install, reset, migration or data writes."""
import argparse
import json
import pathlib
import queue
import shlex
import subprocess
import threading
import time
import urllib.request


class StartupFailure(Exception):
    pass


class Startup:
    def __init__(self, seconds, discovery=False):
        self.deadline = time.monotonic() + seconds
        self.discovery = discovery
        self.stage = "systemd"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def budget(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise StartupFailure("deadline")
        return min(5, remaining)

    def command(self, *args):
        result = subprocess.run(args, capture_output=True, text=True, timeout=self.budget())
        if result.returncode:
            raise StartupFailure("command")
        return result.stdout

    def wait(self, check):
        while True:
            self.budget()
            try:
                if check():
                    return
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass
            time.sleep(min(1, self.budget()))

    def properties(self, unit):
        raw = self.command("/usr/bin/systemctl", "show", unit, "--no-pager",
                           "-p", "LoadState", "-p", "ActiveState", "-p", "MainPID")
        props = dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)
        if props.get("LoadState") != "loaded" or props.get("ActiveState") == "failed":
            raise StartupFailure("unit-unavailable-or-failed")
        return props

    def active(self, unit, process=False):
        props = self.properties(unit)
        return props.get("ActiveState") == "active" and (not process or int(props.get("MainPID", "0")) > 0)

    def start(self, units):
        for unit in units:
            self.properties(unit)
        self.command("/usr/bin/systemctl", "start", "--no-block", *units)
        self.wait(lambda: all(self.active(unit) for unit in units))

    def http(self, url, body=None, token=None):
        # Socket timeouts only bound inactivity. A trickling response must not
        # extend the startup deadline or an ExecStartPre gate indefinitely.
        seconds = self.budget()
        result = queue.Queue(maxsize=1)

        def request():
            try:
                result.put((True, self._http(url, body, token, seconds)))
            except Exception as exc:
                result.put((False, exc))

        threading.Thread(target=request, daemon=True).start()
        try:
            ok, value = result.get(timeout=seconds)
        except queue.Empty:
            raise StartupFailure("http-deadline") from None
        if not ok:
            raise value
        return value

    def _http(self, url, body, token, seconds):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(url, data=body, headers=headers)
        with self.opener.open(request, timeout=seconds) as response:
            if response.status != 200:
                return None
            raw = response.read(65536)
            if url.endswith("/health"):
                return json.loads(raw)
            return response.headers.get("Content-Type", "").startswith("text/html")

    def run(self):
        self.wait(lambda: self.command("/usr/bin/systemctl", "show", "--property=SystemState", "--value").strip() in {"running", "degraded"})
        self.stage = "dependencies"
        self.start(["postgresql@16-main.service", "docker.service"])
        self.stage = "api"
        self.start(["stack-api.service"])
        self.wait(lambda: (self.http("http://127.0.0.1:8000/function/health", b"{}") or {}).get("data", {}).get("result", {}).get("status") == "ok")
        self.stage = "services"
        units = ["stack-gateway.service", "stack-browser.service", "stack-worker.service"]
        if self.discovery:
            units.append("stack-discovery.service")
        self.start(units)
        self.stage = "gateway"
        self.wait(lambda: self.http("http://127.0.0.1:8080/") is True)
        self.stage = "browser"
        token = browser_token(pathlib.Path("/etc/stack/browser.env"))
        self.wait(lambda: (self.http("http://127.0.0.1:8011/health", token=token) or {}).get("ready") is True)
        self.stage = "final-services"
        self.wait(lambda: all(self.active(unit, process=True) for unit in ["stack-api.service", *units]))
        return {"status": "ready", "scope": "wsl-local", "phone_acceptance": "not_run"}

    def check_api(self):
        self.stage = "api-gate"
        self.wait(lambda: (self.http("http://127.0.0.1:8000/function/health", b"{}") or {}).get("data", {}).get("result", {}).get("status") == "ok")
        return {"status": "ready", "scope": "api-gate"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def browser_token(path):
    tokens = []
    for line in path.read_text().splitlines():
        if line.strip().startswith("STACK_BROWSER_TOKEN="):
            value = shlex.split(line.strip().split("=", 1)[1], comments=True)
            if len(value) != 1:
                raise StartupFailure("browser-credential")
            tokens.append(value[0])
    if len(tokens) != 1 or len(tokens[0]) < 32:
        raise StartupFailure("browser-credential")
    return tokens[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--discovery", action="store_true", help="Require discovery only if installed and approved")
    parser.add_argument("--check-api-only", action="store_true", help="Unprivileged systemd ExecStartPre gate")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 900:
        parser.error("timeout must be between 1 and 900 seconds")
    startup = Startup(args.timeout, args.discovery)
    try:
        print(json.dumps(startup.check_api() if args.check_api_only else startup.run()))
        return 0
    except Exception:
        # Command/HTTP exceptions can contain secrets: emit only a known stage.
        print(json.dumps({"status": "failed", "stage": startup.stage, "scope": "wsl-local"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
