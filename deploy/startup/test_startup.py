"""Disposable tests. All systemctl and application HTTP operations are mocked."""
import contextlib
import importlib.util
import io
import http.server
import json
import pathlib
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("startup", pathlib.Path(__file__).with_name("stack-startup.py"))
startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(startup)


class Fixture:
    def __init__(self):
        self.now = 0
        self.starts = []
        self.pids = {}
        self.calls = []
        self.failed = None
        self.missing = None
        self.delay = 0
        self.http_calls = 0

    def command(self, args, **kwargs):
        self.calls.append(args)
        assert kwargs["timeout"] <= 5
        if "--property=SystemState" in args:
            value = "running"
        elif args[1] == "start":
            self.starts.append(args[3:])
            for unit in args[3:]:
                self.pids.setdefault(unit, len(self.pids) + 100)
            value = ""
        else:
            unit = args[2]
            value = (f"LoadState={'not-found' if unit == self.missing else 'loaded'}\n"
                     f"ActiveState={'failed' if unit == self.failed else 'active' if unit in self.pids else 'inactive'}\n"
                     f"MainPID={self.pids.get(unit, 0)}")
        return subprocess.CompletedProcess(args, 0, value, "")

    def http(self, url, body=None, token=None):
        self.http_calls += 1
        if self.now < self.delay:
            raise OSError("synthetic-secret-response")
        if ":8000" in url:
            assert body == b"{}"
            return {"data": {"result": {"status": "ok"}}}
        if ":8011" in url:
            assert token == "x" * 32
            return {"ready": True}
        return True

    def sleep(self, seconds):
        self.now += seconds


class Tests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        for target, replacement in [("subprocess.run", self.fixture.command),
                                    ("time.monotonic", lambda: self.fixture.now),
                                    ("time.sleep", self.fixture.sleep),
                                    ("browser_token", lambda path: "x" * 32)]:
            # Module loaded by file: patch the actual objects rather than import lookup.
            obj = startup
            pieces = target.split('.')
            for piece in pieces[:-1]:
                obj = getattr(obj, piece)
            p = patch.object(obj, pieces[-1], replacement)
            p.start()
            self.addCleanup(p.stop)
        self.http_patch = patch.object(startup.Startup, "http", lambda instance, *a, **kw: self.fixture.http(*a, **kw))
        self.http_patch.start()
        self.addCleanup(self.http_patch.stop)

    def test_order_and_repeated_start_preserves_instances(self):
        result = startup.Startup(30).run()
        pids = dict(self.fixture.pids)
        startup.Startup(30).run()
        self.assertEqual(pids, self.fixture.pids)
        self.assertEqual(result["phone_acceptance"], "not_run")
        self.assertEqual(self.fixture.starts[:3], [
            ("postgresql@16-main.service", "docker.service"), ("stack-api.service",),
            ("stack-gateway.service", "stack-browser.service", "stack-worker.service")])
        self.assertFalse(any("restart" in command or "reset-failed" in command or "enable" in command for command in self.fixture.calls))

    def test_dependency_failure_prevents_api(self):
        self.fixture.failed = "docker.service"
        with self.assertRaises(startup.StartupFailure):
            startup.Startup(30).run()
        self.assertEqual(self.fixture.starts, [])

    def test_missing_unit_not_silently_ignored(self):
        self.fixture.missing = "stack-browser.service"
        with self.assertRaises(startup.StartupFailure):
            startup.Startup(30).run()

    def test_delayed_readiness_retries(self):
        self.fixture.delay = 4
        self.assertEqual(startup.Startup(30).run()["status"], "ready")
        self.assertGreaterEqual(self.fixture.now, 4)

    def test_unavailable_readiness_is_bounded(self):
        self.fixture.delay = 100
        with self.assertRaises(startup.StartupFailure):
            startup.Startup(3).run()
        self.assertEqual(self.fixture.now, 3)

    def test_failure_diagnostics_are_sanitized(self):
        self.fixture.failed = "docker.service"
        with patch("sys.argv", ["startup", "--timeout", "3"]), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(startup.main(), 1)
        report = json.loads(out.getvalue())
        self.assertEqual(report, {"status": "failed", "stage": "dependencies", "scope": "wsl-local"})

    def test_api_gate_does_not_start_services(self):
        self.fixture.delay = 2
        self.assertEqual(startup.Startup(5).check_api()["scope"], "api-gate")
        self.assertEqual(self.fixture.calls, [])


class CredentialTests(unittest.TestCase):
    def test_existing_token_only_and_duplicate_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "browser.env"
            content = 'STACK_BROWSER_TOKEN="' + 'x' * 32 + '"\nOTHER=untouched\n'
            path.write_text(content)
            self.assertEqual(startup.browser_token(path), "x" * 32)
            self.assertEqual(path.read_text(), content)
            path.write_text(content * 2)
            with self.assertRaises(startup.StartupFailure):
                startup.browser_token(path)


class HttpDeadlineTests(unittest.TestCase):
    def test_socket_timeout_remains_retryable(self):
        probe = startup.Startup(30)
        failure = TimeoutError("synthetic-secret-response")
        ready = {"data": {"result": {"status": "ok"}}}
        with patch.object(probe, "_http", side_effect=[failure, ready]) as request, \
                patch.object(startup.time, "sleep"):
            self.assertEqual(probe.check_api()["status"], "ready")
        self.assertEqual(request.call_count, 2)

    def test_socket_timeout_is_not_a_wall_deadline(self):
        probe = startup.Startup(30)
        failure = TimeoutError("synthetic-secret-response")
        with patch.object(probe, "_http", side_effect=failure):
            with self.assertRaises(TimeoutError) as caught:
                probe.http("http://127.0.0.1/health")
        self.assertIs(caught.exception, failure)

    def test_trickling_http_body_has_wall_deadline(self):
        stop = threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                raw = b'{"ready":true}'
                self.send_response(200)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                try:
                    for byte in raw:
                        self.wfile.write(bytes([byte]))
                        self.wfile.flush()
                        # Keep the body incomplete beyond the wall deadline.
                        if stop.wait(0.3):
                            return
                except ConnectionError:
                    pass

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = False
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        clock = time.monotonic()
        try:
            probe = startup.Startup(0.4)
            open_request = probe.opener.open
            # Isolate the wall deadline from the competing socket inactivity timer.
            # A hosted runner can oversleep between bytes; socket timeout must not
            # satisfy this regression. Without the wall guard, the read takes 3.6s.
            with patch.object(probe.opener, "open", side_effect=lambda request, timeout: open_request(request, timeout=5)):
                with self.assertRaisesRegex(startup.StartupFailure, "^http-deadline$"):
                    probe.http(f"http://127.0.0.1:{server.server_port}/health")
            # Generous slack for slow hosted runners; still far below the undeadlined read.
            self.assertLess(time.monotonic() - clock, 2.0)
        finally:
            stop.set()
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
